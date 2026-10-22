import Foundation
import Darwin

enum SocketError: Error {
    case message(String)
}

/// Thread-safe counter for the resolver diagnostics: the DNS-timeout regression
/// probe uses it to prove that timed-out lookups neither leak `addrinfo` lists
/// nor leave unbounded resolver threads behind. Production code only increments
/// or decrements it; nothing reads it outside the probes.
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

    /// Resolver threads currently inside `getaddrinfo` (or the test `delay`
    /// seam). Bounded by `maxResolverThreads`; a timed-out caller returns while
    /// the orphan finishes, so this is the value that must stay bounded.
    static let liveResolverThreads = SocketResolutionCounter()

    /// Monotonic count of resolver threads actually spawned. The numeric fast
    /// path never touches it, so the E2E harness can prove a literal IP opens a
    /// socket without paying for `getaddrinfo`.
    static let resolverStarts = SocketResolutionCounter()

    /// Bound on concurrent `getaddrinfo` calls. Without it a blackholed resolver
    /// lets timed-out callers spawn detached threads without limit.
    private static let maxResolverThreads = 8
    private static let resolverSemaphore = DispatchSemaphore(value: maxResolverThreads)

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
        guard resolverSemaphore.wait(timeout: .now() + 0.05) == .success else {
            throw SocketError.message("resolver busy: \(maxResolverThreads) lookups already in flight")
        }
        let box = ResolutionBox()
        let sem = DispatchSemaphore(value: 0)
        let portStr = String(port)
        liveResolverThreads.inc()
        resolverStarts.inc()
        Thread.detachNewThread {
            // Release exactly once when getaddrinfo finishes, even if the caller
            // timed out and already returned.
            defer {
                Socket.liveResolverThreads.dec()
                Socket.resolverSemaphore.signal()
            }
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
    ///
    /// `allowPrivate == false` rejects the connection when **any** resolved
    /// candidate is loopback/private, before connecting to any of them. The
    /// check uses the same `addrinfo` list as the connect loop, so a DNS answer
    /// cannot change between the policy decision and the connection.
    static func connect(host: String, port: UInt16, timeout: TimeInterval = 10,
                        allowPrivate: Bool = true) throws -> Int32 {
        let budget = max(0.1, timeout)
        let deadline = Date().addingTimeInterval(budget)

        // A literal IPv4/IPv6 address needs no DNS. Building the sockaddr here
        // avoids both a detached resolver thread and the `getaddrinfo` syscall,
        // which is most tunneled connections in practice.
        if let numeric = numericAddress(host: host, port: port) {
            do {
                return try numeric.withSockaddr { address, length in
                    if !allowPrivate, HostClassifier.isPrivateOrLoopback(address, length) {
                        throw SocketError.message("blocked_private_destination")
                    }
                    return try connectSocket(family: numeric.family, socktype: SOCK_STREAM,
                                             proto: IPPROTO_TCP, address: address,
                                             length: length, deadline: deadline)
                }
            } catch let e as ConnectAttemptError {
                throw SocketError.message("connect(\(host):\(port)) failed: \(e.message)")
            }
        }

        let info = try resolve(host: host, port: port, timeout: budget)
        defer { freeaddrinfo(info); Socket.liveResolutions.dec() }

        if !allowPrivate {
            var candidate: UnsafeMutablePointer<addrinfo>? = info
            while let entry = candidate {
                if let sa = entry.pointee.ai_addr,
                   HostClassifier.isPrivateOrLoopback(sa, entry.pointee.ai_addrlen) {
                    throw SocketError.message("blocked_private_destination")
                }
                candidate = entry.pointee.ai_next
            }
        }

        var lastError = "no addresses"
        var ptr: UnsafeMutablePointer<addrinfo>? = info
        while let addr = ptr {
            let next = addr.pointee.ai_next
            if let sa = addr.pointee.ai_addr {
                do {
                    return try connectSocket(family: addr.pointee.ai_family,
                                             socktype: addr.pointee.ai_socktype,
                                             proto: addr.pointee.ai_protocol,
                                             address: sa,
                                             length: addr.pointee.ai_addrlen,
                                             deadline: deadline)
                } catch let e as ConnectAttemptError {
                    lastError = e.message
                }
            }
            ptr = next
        }
        throw SocketError.message("connect(\(host):\(port)) failed: \(lastError)")
    }

    /// One resolved/literal address, kept in a value so the socket call and the
    /// SSRF check share the exact same bytes.
    private enum NumericAddress {
        case v4(sockaddr_in)
        case v6(sockaddr_in6)

        var family: Int32 {
            switch self {
            case .v4: return AF_INET
            case .v6: return AF_INET6
            }
        }

        var length: socklen_t {
            switch self {
            case .v4: return socklen_t(MemoryLayout<sockaddr_in>.size)
            case .v6: return socklen_t(MemoryLayout<sockaddr_in6>.size)
            }
        }

        func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
            switch self {
            case .v4(var sa):
                return try withUnsafePointer(to: &sa) { ptr in
                    try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        try body($0, length)
                    }
                }
            case .v6(var sa):
                return try withUnsafePointer(to: &sa) { ptr in
                    try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        try body($0, length)
                    }
                }
            }
        }
    }

    /// Parse a numeric literal only (`inet_pton`), so shorthand/integer forms
    /// such as `127.1` still go through `getaddrinfo` as before.
    private static func numericAddress(host: String, port: UInt16) -> NumericAddress? {
        var h = host
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") {
            h = String(h[h.index(after: h.startIndex)..<close])
        }
        var v4 = in_addr()
        if h.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = port.bigEndian
            sa.sin_addr = v4
            return .v4(sa)
        }
        var v6 = in6_addr()
        if h.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            var sa = sockaddr_in6()
            sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sa.sin6_family = sa_family_t(AF_INET6)
            sa.sin6_port = port.bigEndian
            sa.sin6_flowinfo = 0
            sa.sin6_addr = v6
            sa.sin6_scope_id = 0
            return .v6(sa)
        }
        return nil
    }

    /// Failure for a single candidate address; the caller tries the next one and
    /// reports the last message. Kept separate from `SocketError` so the connect
    /// loop can distinguish a per-address failure from a policy rejection.
    private struct ConnectAttemptError: Error {
        let message: String
    }

    /// Non-blocking connect + poll + `SO_ERROR`, then restore blocking mode. The
    /// descriptor is always closed on failure.
    private static func connectSocket(family: Int32, socktype: Int32, proto: Int32,
                                      address: UnsafePointer<sockaddr>, length: socklen_t,
                                      deadline: Date) throws -> Int32 {
        let fd = socket(family, socktype, proto)
        guard fd >= 0 else {
            throw ConnectAttemptError(message: String(cString: strerror(errno)))
        }
        setNoSIGPIPE(fd)
        guard setNonBlocking(fd, on: true) else {
            close(fd)
            throw ConnectAttemptError(message: "could not set non-blocking")
        }
        var res: Int32 = -1
        repeat {
            res = Darwin.connect(fd, address, length)
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
                        let err = optval != 0 ? optval : errno
                        close(fd)
                        throw ConnectAttemptError(message: String(cString: strerror(err)))
                    }
                } else {
                    close(fd)
                    throw ConnectAttemptError(message: "connect timed out")
                }
            } else {
                let err = errno
                close(fd)
                throw ConnectAttemptError(message: String(cString: strerror(err)))
            }
        }
        if res == 0 {
            if setNonBlocking(fd, on: false) { return fd }
            close(fd)
            throw ConnectAttemptError(message: "could not restore blocking mode")
        }
        close(fd)
        throw ConnectAttemptError(message: "connect failed")
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

    /// Builds a `timeval` for `SO_RCVTIMEO`/`SO_SNDTIMEO`.
    ///
    /// On macOS `{0,0}` means "block forever", not "return immediately", so a
    /// short positive budget must never collapse to it: anything at or below
    /// one microsecond becomes a 1 µs floor. Values are clamped *before* the
    /// `Int` conversion so a huge finite `TimeInterval` cannot trap, and a
    /// non-finite value falls back to the floor rather than an infinite wait.
    static func timeval(for timeout: TimeInterval) -> timeval {
        let maxSeconds: TimeInterval = 86_400
        let clamped = timeout.isFinite ? min(max(timeout, 0), maxSeconds) : 0
        let sec = Int(clamped)
        var usec = Int32(((clamped - Double(sec)) * 1_000_000).rounded(.down))
        if usec > 999_999 { usec = 999_999 }
        if sec == 0 && usec == 0 { usec = 1 }
        return Darwin.timeval(tv_sec: sec, tv_usec: usec)
    }

    static func setTimeouts(_ fd: Int32, receive: TimeInterval, send: TimeInterval) {
        var r = timeval(for: receive)
        var s = timeval(for: send)
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
