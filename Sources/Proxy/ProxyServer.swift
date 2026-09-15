import Foundation
import Darwin

struct ProxyRuntimeSettings {
    var bindHost: String = "127.0.0.1"
    var port: UInt16 = 8888
    var tunnelHost: String = "127.0.0.1"
    var tunnelPort: UInt16 = 1080
    var failClosed: Bool = false
    var idleTimeout: TimeInterval = 120
    var connectTimeout: TimeInterval = 10
    var maxConcurrent: Int = 256
    var recordPaths: Bool = true
}

/// Domain-aware HTTP CONNECT / forward proxy.
///
/// Performance model:
///  - One thread per active connection (not per direction). A connection's
///    lifetime is: read request header (blocking, short) → open upstream
///    (blocking, short) → bidirectional relay via a single-threaded `poll()`
///    loop with bounded buffers and backpressure.
///  - Upstream connections use raw BSD sockets so they bypass the macOS system
///    proxy (avoiding a routing loop back into this proxy).
///  - Concurrency is bounded by `maxConcurrent`.
final class ProxyServer {
    let routingEngine = RoutingEngine()
    let telemetry: TelemetryStore

    var isTunnelUp: () -> Bool = { true }

    private let lock = NSLock()
    private var settings = ProxyRuntimeSettings()

    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "com.proxymanager.proxy.accept")
    private var running = false

    private let active = AtomicInt()
    private let semaphore: DispatchSemaphore

    init(telemetry: TelemetryStore) {
        self.telemetry = telemetry
        self.semaphore = DispatchSemaphore(value: 256)
    }

    func update(settings: ProxyRuntimeSettings) {
        lock.lock(); self.settings = settings; lock.unlock()
    }

    func snapshot() -> ProxyRuntimeSettings {
        lock.lock(); defer { lock.unlock() }; return settings
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func start() throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        let s = settings
        lock.unlock()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.message("socket() failed") }
        Socket.setNoSIGPIPE(fd)
        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = s.port.bigEndian
        if s.bindHost == "0.0.0.0" || s.bindHost.isEmpty {
            addr.sin_addr.s_addr = INADDR_ANY
        } else {
            addr.sin_addr.s_addr = inet_addr(s.bindHost)
        }
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw SocketError.message("bind(\(s.bindHost):\(s.port)) failed: \(msg)")
        }
        guard listen(fd, 1024) == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw SocketError.message("listen failed: \(msg)")
        }

        listenFD = fd
        lock.lock(); running = true; lock.unlock()

        Log.proxy.notice("listening on \(s.bindHost):\(s.port)")
        if s.bindHost != "127.0.0.1" && s.bindHost != "localhost" {
            Log.proxy.warning("proxy is listening on a non-loopback address (\(s.bindHost)) and has no authentication")
        }

        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
        Log.proxy.notice("stopped listening")
    }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &len)
                }
            }
            guard cfd >= 0 else {
                if isRunning { usleep(50_000); continue }
                break
            }
            Socket.setNoSIGPIPE(cfd)
            let clientIsLoopback = Socket.isLoopbackPeer(cfd)
            semaphore.wait()
            let current = active.inc()
            telemetry.setActiveConnections(current)
            // Use a detached thread (not GCD's global queue) — GCD's global pool
            // caps concurrent blocking tasks at ~64 threads, which starves the
            // proxy under load. A dedicated thread per connection (bounded by
            // the semaphore) scales to `maxConcurrent`.
            // Capture `self` strongly for the connection's lifetime: the permit
            // taken above must be returned before the server can deallocate,
            // otherwise libdispatch traps disposing `semaphore` while a permit
            // is still outstanding ("Semaphore object deallocated while in use").
            Thread.detachNewThread { [self] in
                defer {
                    self.semaphore.signal()
                    self.telemetry.setActiveConnections(self.active.dec())
                }
                self.handleConnection(cfd, clientIsLoopback: clientIsLoopback)
            }
        }
    }

    private func handleConnection(_ cfd: Int32, clientIsLoopback: Bool) {
        let s = snapshot()
        let start = DispatchTime.now()
        // Requests are attributed to the moment the proxy accepted them, not to
        // when the (possibly long-lived) connection finally closed.
        let startTs = Int64(Date().timeIntervalSince1970 * 1000)
        let srcPort = Socket.peerPort(cfd)

        var host = ""
        var port: UInt16 = 443
        var method = "CONNECT"
        var scheme = "https"
        var path = ""
        var route: Route = .direct
        var status = 0
        var errMsg: String?
        var bytesIn: Int64 = 0
        var bytesOut: Int64 = 0

        Socket.setTimeouts(cfd, receive: s.idleTimeout, send: s.idleTimeout)

        defer { close(cfd) }

        do {
            let (header, leftover) = try readHeader(cfd, maxBytes: 65_536, deadline: Date().addingTimeInterval(15))
            guard let request = HTTPParser.parse(header) else {
                throw SocketError.message("malformed request")
            }
            host = request.host
            port = request.port
            method = request.method.uppercased()
            scheme = request.scheme
            path = s.recordPaths ? request.path : ""

            // SSRF guard: the proxy has no authentication, so a non-loopback
            // client must never use it to reach loopback/link-local/private
            // destinations. Loopback clients (the normal case) are unaffected.
            if !clientIsLoopback && HostClassifier.isPrivateOrLoopback(host) {
                route = .block
                errMsg = "blocked_private_destination"
                status = 403
                try sendResponse(cfd, status: 403, reason: "Forbidden")
                record(startTs: startTs, srcPort: srcPort, host: host, port: port, method: method, scheme: scheme,
                       path: path, route: route, status: status, bytesIn: bytesIn, bytesOut: bytesOut, error: errMsg)
                return
            }

            let decision = routingEngine.decide(host: host)
            route = decision.route

            if decision == .tunnel && !isTunnelUp() {
                if s.failClosed {
                    route = .block
                    errMsg = "tunnel_down"
                    try sendResponse(cfd, status: 502, reason: "Bad Gateway")
                    status = 502
                    record(startTs: startTs, srcPort: srcPort, host: host, port: port, method: method, scheme: scheme,
                           path: path, route: route, status: status, bytesIn: bytesIn, bytesOut: bytesOut, error: errMsg)
                    return
                } else {
                    route = .direct
                    errMsg = "tunnel_down"
                }
            }

            let upstream: Int32
            do {
                upstream = try connectUpstream(host: host, port: port, route: route, settings: s)
            } catch {
                status = 502
                errMsg = "connect_failed: \(error.localizedDescription)"
                try sendResponse(cfd, status: 502, reason: "Bad Gateway")
                record(startTs: startTs, srcPort: srcPort, host: host, port: port, method: method, scheme: scheme,
                       path: path, route: route, status: status, bytesIn: bytesIn, bytesOut: bytesOut, error: errMsg)
                return
            }
            defer { close(upstream) }

            if request.isConnect {
                try Socket.sendAll(cfd, Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                status = 200
                // The tunnel is now established: surface it in the live feed
                // immediately instead of only when the connection closes
                // minutes later (keep-alive / streaming).
                let sessionId = telemetry.beginSession(event(startTs: startTs, srcPort: srcPort,
                                                             scheme: scheme, method: method, host: host, port: port,
                                                             path: path, route: route, status: status, error: nil))
                let counts = relay(cfd, upstream, initial: leftover, idle: s.idleTimeout,
                                   progress: { [weak self] in self?.telemetry.updateSession(sessionId, bytesIn: $0, bytesOut: $1) })
                bytesOut = counts.0
                bytesIn = counts.1
                telemetry.endSession(sessionId, event(id: sessionId, startTs: startTs, srcPort: srcPort,
                                                      scheme: scheme, method: method, host: host, port: port,
                                                      path: path, route: route, status: status, error: errMsg,
                                                      bytesIn: bytesIn, bytesOut: bytesOut,
                                                      durationMs: elapsedMs(from: start)))
                return
            } else {
                try Socket.sendAll(upstream, Array(HTTPParser.rewrite(request).utf8))
                if !leftover.isEmpty {
                    try Socket.sendAll(upstream, leftover)
                }
                status = 0
                let sessionId = telemetry.beginSession(event(startTs: startTs, srcPort: srcPort,
                                                             scheme: scheme, method: method, host: host, port: port,
                                                             path: path, route: route, status: 0, error: nil))
                let counts = relay(cfd, upstream, initial: [], idle: s.idleTimeout,
                                   progress: { [weak self] in self?.telemetry.updateSession(sessionId, bytesIn: $0, bytesOut: $1) })
                bytesOut = counts.0
                bytesIn = counts.1
                telemetry.endSession(sessionId, event(id: sessionId, startTs: startTs, srcPort: srcPort,
                                                      scheme: scheme, method: method, host: host, port: port,
                                                      path: path, route: route, status: 0, error: errMsg,
                                                      bytesIn: bytesIn, bytesOut: bytesOut,
                                                      durationMs: elapsedMs(from: start)))
                return
            }
        } catch let e as SocketError {
            errMsg = errMsg ?? e.localizedDescription
        } catch {
            errMsg = errMsg ?? "\(error)"
        }

        record(startTs: startTs, srcPort: srcPort, host: host, port: port, method: method, scheme: scheme,
               path: path, route: route, status: status, bytesIn: bytesIn, bytesOut: bytesOut, error: errMsg)
    }

    private func elapsedMs(from start: DispatchTime) -> Int64 {
        Int64(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    /// Event factory for a single connection; `ts` is always the request start
    /// time so history/charts attribute the request to when it happened.
    private func event(id: UUID = UUID(), startTs: Int64, srcPort: Int, scheme: String, method: String, host: String,
                       port: UInt16, path: String, route: Route, status: Int, error: String?,
                       bytesIn: Int64 = 0, bytesOut: Int64 = 0, durationMs: Int64 = 0) -> RequestEvent {
        RequestEvent(id: id, ts: startTs, scheme: scheme, method: method, host: host, port: port,
                     path: path, route: route, status: status, bytesIn: bytesIn, bytesOut: bytesOut,
                     durationMs: durationMs, error: error, srcPort: srcPort)
    }

    private func record(startTs: Int64, srcPort: Int, host: String, port: UInt16, method: String, scheme: String,
                        path: String, route: Route, status: Int, bytesIn: Int64, bytesOut: Int64, error: String?) {
        telemetry.record(event(startTs: startTs, srcPort: srcPort, scheme: scheme, method: method,
                               host: host, port: port, path: path, route: route, status: status, error: error,
                               bytesIn: bytesIn, bytesOut: bytesOut))
    }

    private func connectUpstream(host: String, port: UInt16, route: Route, settings: ProxyRuntimeSettings) throws -> Int32 {
        if route == .tunnel {
            var client = SOCKS5Client(serverHost: settings.tunnelHost, serverPort: settings.tunnelPort)
            client.connectTimeout = settings.connectTimeout
            client.handshakeTimeout = 5
            return try client.connect(targetHost: host, targetPort: port)
        }
        let fd = try Socket.connect(host: host, port: port, timeout: settings.connectTimeout)
        // The direct path has no SOCKS5 handshake to set timeouts, so a
        // forwarded request to a stalled upstream could block forever.
        Socket.setTimeouts(fd, receive: settings.idleTimeout, send: settings.idleTimeout)
        return fd
    }

    private func readHeader(_ fd: Int32, maxBytes: Int, deadline: Date) throws -> ([UInt8], [UInt8]) {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < maxBytes {
            // `SO_RCVTIMEO` is per-call, so a slowloris client could otherwise
            // hold a thread + semaphore permit forever. Bound the whole header.
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw SocketError.message("header read timeout") }
            Socket.setTimeouts(fd, receive: min(remaining, 5), send: min(remaining, 5))
            // Never read past the cap: a single `recv` of the full chunk could
            // otherwise overshoot `maxBytes` by up to `chunk.count - 1`.
            let want = min(chunk.count, maxBytes - buffer.count)
            let n = Darwin.recv(fd, &chunk, want, 0)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw SocketError.message("header read timeout")
                }
                throw SocketError.message("recv failed: \(String(cString: strerror(errno)))")
            }
            if n == 0 { throw SocketError.message("client closed") }
            buffer.append(contentsOf: chunk[0..<n])
            if let range = HTTPParser.findHeaderEnd(in: buffer) {
                let header = Array(buffer[0..<range.upperBound])
                let leftover = Array(buffer[range.upperBound...])
                return (header, leftover)
            }
        }
        throw SocketError.message("header too large")
    }

    private func sendResponse(_ fd: Int32, status: Int, reason: String) throws {
        let body = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        try Socket.sendAll(fd, Array(body.utf8))
    }

    /// Single-threaded bidirectional relay using `poll()`. Returns
    /// (clientToUpstreamBytes, upstreamToClientBytes). `progress` is invoked
    /// (from this thread) whenever bytes moved in either direction — one call
    /// per poll iteration, (upstreamToClient, clientToUpstream) deltas — so the
    /// live feed can tick without any main-thread work per chunk.
    private func relay(_ client: Int32, _ upstream: Int32, initial: [UInt8], idle: TimeInterval,
                       progress: ((Int64, Int64) -> Void)? = nil) -> (Int64, Int64) {
        Socket.setNonBlocking(client, on: true)
        Socket.setNonBlocking(upstream, on: true)

        var c2u = initial
        var u2c = [UInt8]()
        var c2uTotal: Int64 = 0
        var u2cTotal: Int64 = 0
        var clientReadDone = false
        var upstreamReadDone = false
        var clientFinPropagated = false
        var upstreamFinPropagated = false

        let chunk = 16_384
        let maxBuf = 256 * 1024
        let grace: TimeInterval = 3
        var readBuf = [UInt8](repeating: 0, count: chunk)
        var halfClosed = false

        while true {
            // Propagate half-close (FIN) only once the corresponding buffer is
            // drained, so we never cut off pending data.
            if clientReadDone && c2u.isEmpty && !clientFinPropagated {
                Darwin.shutdown(upstream, Int32(SHUT_WR))
                clientFinPropagated = true
            }
            if upstreamReadDone && u2c.isEmpty && !upstreamFinPropagated {
                Darwin.shutdown(client, Int32(SHUT_WR))
                upstreamFinPropagated = true
            }

            // End only when BOTH directions are drained, so a half-close
            // (client sends FIN but keeps reading) still flushes the response.
            if clientReadDone && upstreamReadDone && c2u.isEmpty && u2c.isEmpty {
                break
            }

            // Poll only descriptors that still have work: a finished direction
            // (events == 0) is left out of the set entirely. POSIX says
            // POLLHUP/POLLERR/POLLNVAL are reported regardless of the requested
            // mask (macOS in fact skips events==0 fds — verified), so this is the
            // portable-correct form and avoids a per-iteration heap array.
            var clientEvents: Int16 = 0
            var upstreamEvents: Int16 = 0
            if !clientReadDone && c2u.count < maxBuf { clientEvents |= Int16(POLLIN) }
            if !u2c.isEmpty { clientEvents |= Int16(POLLOUT) }
            if !upstreamReadDone && u2c.count < maxBuf { upstreamEvents |= Int16(POLLIN) }
            if !c2u.isEmpty { upstreamEvents |= Int16(POLLOUT) }

            if clientEvents == 0 && upstreamEvents == 0 { break }

            let timeout = halfClosed ? grace : idle
            var clientRevents: Int16 = 0
            var upstreamRevents: Int16 = 0
            let rc: Int32 = withUnsafeTemporaryAllocation(of: pollfd.self, capacity: 2) { buf in
                var nfds: nfds_t = 0
                var clientIdx = -1
                var upstreamIdx = -1
                if clientEvents != 0 {
                    buf[Int(nfds)] = pollfd(fd: client, events: clientEvents, revents: 0)
                    clientIdx = Int(nfds); nfds += 1
                }
                if upstreamEvents != 0 {
                    buf[Int(nfds)] = pollfd(fd: upstream, events: upstreamEvents, revents: 0)
                    upstreamIdx = Int(nfds); nfds += 1
                }
                // Clamp before narrowing: a large (future, configurable) timeout
                // would otherwise overflow `Int32` and produce a negative wait.
                let ms = Int32(min(Double(Int32.max), max(0, timeout) * 1000))
                let r = poll(buf.baseAddress!, nfds, ms)
                if r > 0 {
                    if clientIdx >= 0 { clientRevents = buf[clientIdx].revents }
                    if upstreamIdx >= 0 { upstreamRevents = buf[upstreamIdx].revents }
                }
                return r
            }
            if rc < 0 {
                if errno == EINTR { continue }
                break
            }
            if rc == 0 { break } // idle/grace timeout

            let iterC2u = c2uTotal
            let iterU2c = u2cTotal

            // Client socket: hard error → client gone (drop undeliverable u2c).
            if clientRevents & Int16(POLLERR | POLLNVAL) != 0 {
                clientReadDone = true
                u2c.removeAll()
            }
            // client → upstream. Only recv while we haven't seen the client's
            // EOF; after that POLLHUP just re-fires the level-triggered hangup
            // and recv returns 0/EAGAIN forever (a busy-spin) if we keep asking.
            if !clientReadDone && (clientRevents & Int16(POLLIN | POLLHUP) != 0) {
                let n = readBuf.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) -> Int in
                    Darwin.recv(client, b.baseAddress!, chunk, 0)
                }
                if n > 0 {
                    c2u.append(contentsOf: readBuf[0..<n])
                    c2uTotal += Int64(n)
                } else if n == 0 {
                    clientReadDone = true
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    clientReadDone = true
                }
            }
            if !u2c.isEmpty {
                if clientRevents & Int16(POLLOUT) != 0 {
                    let n = u2c.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Int in
                        Darwin.send(client, b.baseAddress!, u2c.count, 0)
                    }
                    if n > 0 {
                        u2c.removeFirst(n)
                    } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                        clientReadDone = true
                        u2c.removeAll()
                    }
                } else if clientRevents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    // Client hung up and is not writable (POLLHUP is mutually
                    // exclusive with POLLOUT once the peer is gone): buffered
                    // data is undeliverable. Leaving it would make poll() return
                    // instantly forever (level-triggered POLLHUP) → 100% CPU spin.
                    u2c.removeAll()
                }
            }

            // Upstream socket: hard error → upstream gone (drop undeliverable c2u).
            if upstreamRevents & Int16(POLLERR | POLLNVAL) != 0 {
                upstreamReadDone = true
                c2u.removeAll()
            }
            // upstream → client (POLLHUP means peer closed; recv returns 0).
            if !upstreamReadDone && (upstreamRevents & Int16(POLLIN | POLLHUP) != 0) {
                let n = readBuf.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) -> Int in
                    Darwin.recv(upstream, b.baseAddress!, chunk, 0)
                }
                if n > 0 {
                    u2c.append(contentsOf: readBuf[0..<n])
                    u2cTotal += Int64(n)
                } else if n == 0 {
                    upstreamReadDone = true
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    upstreamReadDone = true
                }
            }
            if !c2u.isEmpty {
                if upstreamRevents & Int16(POLLOUT) != 0 {
                    let n = c2u.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Int in
                        Darwin.send(upstream, b.baseAddress!, c2u.count, 0)
                    }
                    if n > 0 {
                        c2u.removeFirst(n)
                    } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                        upstreamReadDone = true
                        c2u.removeAll()
                    }
                } else if upstreamRevents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    // Symmetric to the client: undeliverable → drop to avoid spin.
                    c2u.removeAll()
                }
            }

            if clientReadDone || upstreamReadDone { halfClosed = true }

            if let progress {
                let bytesIn = u2cTotal - iterU2c
                let bytesOut = c2uTotal - iterC2u
                if bytesIn != 0 || bytesOut != 0 {
                    progress(bytesIn, bytesOut)
                }
            }
        }

        return (c2uTotal, u2cTotal)
    }
}
