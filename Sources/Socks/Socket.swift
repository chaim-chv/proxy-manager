import Foundation
import Darwin

enum SocketError: Error {
    case message(String)
}

enum Socket {
    /// macOS has no `MSG_NOSIGNAL`; `SO_NOSIGPIPE` is the per-socket equivalent.
    /// Without it a `send()` to a reset peer raises SIGPIPE and kills the app.
    static func setNoSIGPIPE(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private final class ResolutionBox {
        var result: UnsafeMutablePointer<addrinfo>?
        var rc: Int32 = 0
    }

    /// Resolve `host` with a hard timeout. `getaddrinfo` itself is unbounded, so
    /// it runs on a detached thread and the caller waits with a deadline; a
    /// hung resolver can otherwise pin a connection thread forever.
    private static func resolve(host: String, port: UInt16, timeout: TimeInterval) throws -> UnsafeMutablePointer<addrinfo> {
        let box = ResolutionBox()
        let sem = DispatchSemaphore(value: 0)
        let portStr = String(port)
        Thread.detachNewThread {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            box.rc = getaddrinfo(host, portStr, &hints, &box.result)
            sem.signal()
        }
        if sem.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
            throw SocketError.message("getaddrinfo(\(host)) timed out")
        }
        guard box.rc == 0, let info = box.result else {
            throw SocketError.message("getaddrinfo(\(host)): \(String(cString: gai_strerror(box.rc)))")
        }
        return info
    }

    /// Resolve `host`/`port` and open a connected TCP socket, returning its file
    /// descriptor. `timeout` is an overall budget for DNS + all connect attempts.
    static func connect(host: String, port: UInt16, timeout: TimeInterval = 10) throws -> Int32 {
        let budget = max(0.1, timeout)
        let deadline = Date().addingTimeInterval(budget)
        let info = try resolve(host: host, port: port, timeout: budget)
        defer { freeaddrinfo(info) }

        var lastError = "no addresses"
        var ptr: UnsafeMutablePointer<addrinfo>? = info
        while let addr = ptr {
            let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if fd >= 0 {
                setNoSIGPIPE(fd)
                setNonBlocking(fd, on: true)
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
                if res == 0 {
                    setNonBlocking(fd, on: false)
                    return fd
                }
                close(fd)
            }
            ptr = addr.pointee.ai_next
        }
        throw SocketError.message("connect(\(host):\(port)) failed: \(lastError)")
    }

    static func setNonBlocking(_ fd: Int32, on: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags != -1 else { return }
        _ = fcntl(fd, F_SETFL, on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK))
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
                    throw SocketError.message("send timeout")
                }
                throw SocketError.message("send failed: \(String(cString: strerror(errno)))")
            }
            sent += n
        }
    }
}
