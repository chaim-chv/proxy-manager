import Foundation
import Darwin

enum SocketError: Error {
    case message(String)
}

/// Thread-safe counter used only by the DNS-timeout regression probe to prove
/// that timed-out lookups do not leak `addrinfo` lists. Production code only
/// increments/decrements it; nothing reads it except the probe.
final class SocketResolutionCounter {
    private let lock = NSLock()
    private var count = 0
    func inc() { lock.lock(); count += 1; lock.unlock() }
    func dec() { lock.lock(); count -= 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

enum Socket {
    /// Diagnostic for the DNS-timeout regression probe: `addrinfo` lists
    /// allocated by `resolve` and not yet freed. Returns to 0 once every
    /// resolver thread and caller has drained.
    static let liveResolutions = SocketResolutionCounter()

    /// macOS has no `MSG_NOSIGNAL`; `SO_NOSIGPIPE` is the per-socket equivalent.
    /// Without it a `send()` to a reset peer raises SIGPIPE and kills the app.
    static func setNoSIGPIPE(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Carries the resolver's result across threads. If the caller times out
    /// before the detached `getaddrinfo` finishes, `cancel()` marks the box so
    /// whichever side runs last frees the `addrinfo` list exactly once — without
    /// it every timed-out lookup leaks the whole result (the detached thread
    /// still completes and allocates even though the caller has moved on).
    private final class ResolutionBox {
        private let lock = NSLock()
        private var result: UnsafeMutablePointer<addrinfo>?
        private var rc: Int32 = 0
        private var cancelled = false

        func finish(rc: Int32, result: UnsafeMutablePointer<addrinfo>?) {
            lock.lock()
            if cancelled {
                lock.unlock()
                if let result {
                    freeaddrinfo(result)
                    Socket.liveResolutions.dec()
                }
                return
            }
            self.rc = rc
            self.result = result
            lock.unlock()
        }

        /// Marks the box cancelled and returns any result already stored, so the
        /// caller can free it (the resolver will free its own if it finishes
        /// later). Exactly one of the two paths frees a given result.
        func cancelAndTake() -> UnsafeMutablePointer<addrinfo>? {
            lock.lock()
            cancelled = true
            let r = result
            result = nil
            lock.unlock()
            return r
        }

        func take() -> (Int32, UnsafeMutablePointer<addrinfo>?) {
            lock.lock(); defer { lock.unlock() }
            return (rc, result)
        }
    }

    /// Resolve `host` with a hard timeout. `getaddrinfo` itself is unbounded, so
    /// it runs on a detached thread and the caller waits with a deadline; a
    /// hung resolver can otherwise pin a connection thread forever.
    ///
    /// `internal` (not private) so the DNS-timeout regression probe can drive it.
    /// `delay` is a test seam: it makes the resolver thread outlive a short
    /// caller timeout deterministically (production always passes 0).
    static func resolve(host: String, port: UInt16, timeout: TimeInterval,
                        delay: TimeInterval = 0) throws -> UnsafeMutablePointer<addrinfo> {
        let box = ResolutionBox()
        let sem = DispatchSemaphore(value: 0)
        let portStr = String(port)
        Thread.detachNewThread {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            var result: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, portStr, &hints, &result)
            if result != nil { Socket.liveResolutions.inc() }
            box.finish(rc: rc, result: result)
            sem.signal()
        }
        if sem.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
            if let leaked = box.cancelAndTake() {
                freeaddrinfo(leaked)
                Socket.liveResolutions.dec()
            }
            throw SocketError.message("getaddrinfo(\(host)) timed out")
        }
        let (rc, info) = box.take()
        guard rc == 0, let info else {
            if let info { freeaddrinfo(info); Socket.liveResolutions.dec() }
            throw SocketError.message("getaddrinfo(\(host)): \(String(cString: gai_strerror(rc)))")
        }
        return info
    }

    /// Resolve `host`/`port` and open a connected TCP socket, returning its file
    /// descriptor. `timeout` is an overall budget for DNS + all connect attempts.
    static func connect(host: String, port: UInt16, timeout: TimeInterval = 10) throws -> Int32 {
        let budget = max(0.1, timeout)
        let deadline = Date().addingTimeInterval(budget)
        let info = try resolve(host: host, port: port, timeout: budget)
        defer { freeaddrinfo(info); Socket.liveResolutions.dec() }

        var lastError = "no addresses"
        var ptr: UnsafeMutablePointer<addrinfo>? = info
        while let addr = ptr {
            let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if fd >= 0 {
                setNoSIGPIPE(fd)
                if !setNonBlocking(fd, on: true) {
                    close(fd)
                    lastError = "could not set non-blocking"
                    ptr = addr.pointee.ai_next
                    continue
                }
                var res: Int32 = -1
                repeat {
                    res = Darwin.connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen)
                } while res != 0 && errno == EINTR
                if res != 0 {
                    if errno == EINPROGRESS {
                        let remaining = max(0.1, deadline.timeIntervalSinceNow)
                        if waitForWritable(fd, timeout: remaining) {
                            var optval: Int32 = 0
                            var optlen = socklen_t(MemoryLayout<Int32>.size)
                            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &optval, &optlen) == 0, optval == 0 {
                                res = 0
                            } else {
                                lastError = optval != 0 ? String(cString: strerror(optval))
                                                        : String(cString: strerror(errno))
                            }
                        } else {
                            lastError = "connect timed out"
                        }
                    } else {
                        lastError = String(cString: strerror(errno))
                    }
                }
                if res == 0, setNonBlocking(fd, on: false) {
                    return fd
                }
                if res == 0 { lastError = "could not restore blocking mode" }
                close(fd)
            }
            ptr = addr.pointee.ai_next
        }
        throw SocketError.message("connect(\(host):\(port)) failed: \(lastError)")
    }

    @discardableResult
    static func setNonBlocking(_ fd: Int32, on: Bool) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags != -1 else { return false }
        return fcntl(fd, F_SETFL, on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK)) != -1
    }

    /// Peer's ephemeral source port (0 if the peer is not an IPv4 TCP socket).
    static func peerPort(_ fd: Int32) -> Int {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &len)
            }
        }
        guard rc == 0, addr.sin_family == sa_family_t(AF_INET) else { return 0 }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// True if the connected peer is on loopback (127.0.0.0/8).
    static func isLoopbackPeer(_ fd: Int32) -> Bool {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &len)
            }
        }
        guard rc == 0, addr.sin_family == sa_family_t(AF_INET) else { return false }
        return (UInt32(bigEndian: addr.sin_addr.s_addr) >> 24) == 127
    }

    /// Wait until `fd` is writable (used to complete a non-blocking connect).
    static func waitForWritable(_ fd: Int32, timeout: TimeInterval) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(min(Double(Int32.max), max(0, timeout) * 1000))
        while true {
            let rc = poll(&pfd, 1, ms)
            if rc < 0 && errno == EINTR { continue }
            return rc > 0 && (pfd.revents & Int16(POLLOUT)) != 0
        }
    }

    static func setTimeouts(_ fd: Int32, receive: TimeInterval, send: TimeInterval) {
        func makeTimeval(_ t: TimeInterval) -> timeval {
            let clamped = t.isFinite ? max(0, t) : 0
            let sec = Int(clamped)
            let usec = Int32((clamped - Double(sec)) * 1_000_000)
            return timeval(tv_sec: sec, tv_usec: usec)
        }
        var r = makeTimeval(receive); var s = makeTimeval(send)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &r, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &s, socklen_t(MemoryLayout<timeval>.size))
    }

    static func recvExact(_ fd: Int32, count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: count)
        var received = 0
        try out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            while received < count {
                let n = Darwin.recv(fd, buf.baseAddress!.advanced(by: received), count - received, 0)
                if n <= 0 {
                    if n == 0 { throw SocketError.message("connection closed") }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw SocketError.message("read timeout")
                    }
                    throw SocketError.message("recv failed: \(String(cString: strerror(errno)))")
                }
                received += n
            }
        }
        return out
    }

    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return Darwin.send(fd, base + sent, bytes.count - sent, 0)
            }
            if n <= 0 {
                if n == 0 { throw SocketError.message("connection closed") }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // Either a non-blocking fd or a blocking fd whose
                    // `SO_SNDTIMEO` elapsed. Wait for writability and retry
                    // instead of failing the send outright.
                    if waitForWritable(fd, timeout: 30) { continue }
                    throw SocketError.message("send timeout")
                }
                throw SocketError.message("send failed: \(String(cString: strerror(errno)))")
            }
            sent += n
        }
    }
}
