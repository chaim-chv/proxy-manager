import Foundation
import Darwin

// Unbuffered stdout so a crash (e.g. SIGPIPE) still shows which scenario died.
setbuf(stdout, nil)

// End-to-end proxy harness: real BSD sockets, mock origin + mock SOCKS5.
//
// Build + run (see Tests/run-all.sh). Covers the relay invariants the docs
// promise but had no harness for:
//   - direct CONNECT + response body
//   - tunneled CONNECT through a mock SOCKS5
//   - half-close: client sends FIN, still receives the full response
//   - concurrency: 200 parallel CONNECTs
//   - dead-peer reaping: RST peers must not leak relay threads/fds
//   - ws:// upgrade: 101 + full-duplex frames, direct and through mock SOCKS5
//
// All helpers use Thread.detachNewThread (never DispatchQueue.global) so the
// mock itself is not throttled by GCD's ~64-thread blocking cap.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

/// Process CPU time (user + sys) in seconds. Used to prove the relay does not
/// busy-spin: a spinning relay burns ~1s of CPU per wall second.
func cpuSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    let u = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1_000_000
    let s = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1_000_000
    return u + s
}

// MARK: - Socket helpers

/// The mock servers must not die from SIGPIPE either; the proxy's own sockets
/// are protected inside ProxyServer/Socket. Setting it here keeps the test
/// process alive so a missing proxy-side guard is reported as a failure.
func noSIGPIPE(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

func tcpListen(port: UInt16 = 0) -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    noSIGPIPE(fd)
    var opt: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    let br = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    precondition(br == 0, "bind failed")
    precondition(listen(fd, 128) == 0, "listen failed")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return (fd, UInt16(bigEndian: addr.sin_port))
}

func tcpConnect(host: String, port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    noSIGPIPE(fd)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr(host)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if r != 0 { close(fd); return nil }
    return fd
}

func recvAll(_ fd: Int32) -> [UInt8] {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

func sendAll(_ fd: Int32, _ bytes: [UInt8]) {
    var sent = 0
    while sent < bytes.count {
        let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: sent), bytes.count - sent, 0) }
        if n <= 0 { break }
        sent += n
    }
}

/// Bounds every test-client `recv` so a broken proxy reports a failure instead
/// of hanging the harness forever.
func setRecvTimeout(_ fd: Int32, _ seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

func readSome(_ fd: Int32) -> String {
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = recv(fd, &buf, buf.count, 0)
    return String(decoding: buf[0..<max(0, n)], as: UTF8.self)
}

func readExactly(_ fd: Int32, _ count: Int) -> String {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: count)
    while out.count < count {
        let n = recv(fd, &buf, count - out.count, 0)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return String(decoding: out, as: UTF8.self)
}

// MARK: - Mock origin

/// Reads the request until EOF, then writes `body` and closes. Reading to EOF
/// is what lets the half-close test prove FIN propagation.
final class MockOrigin {
    let fd: Int32
    let port: UInt16
    let body: [UInt8]
    private let stopLock = NSLock()
    private var stopped = false

    init(body: String = "HELLO-FROM-ORIGIN") {
        let l = tcpListen()
        self.fd = l.fd
        self.port = l.port
        self.body = Array(body.utf8)
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { break }
            noSIGPIPE(c)
            Thread.detachNewThread { [weak self] in
                guard let self else { close(c); return }
                _ = recvAll(c) // read request through EOF
                sendAll(c, self.body)
                close(c)
            }
        }
    }
}

// MARK: - Holding origin

/// Accepts a connection and holds it open, reading nothing and never closing.
/// This is the upstream half of the dead-peer spin regression: after the client
/// is reset, the relay still has a live, idle upstream fd, so a relay that keeps
/// the closed client fd in its poll set spins at 100% CPU until the origin
/// closes.
final class MockOriginHolding {
    let fd: Int32
    let port: UInt16
    private var clients: [Int32] = []
    private let lock = NSLock()

    init() {
        let l = tcpListen()
        self.fd = l.fd
        self.port = l.port
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { break }
            noSIGPIPE(c)
            lock.lock(); clients.append(c); lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        for c in clients { close(c) }
        clients.removeAll()
        lock.unlock()
        close(fd)
    }
}

// MARK: - Mock SOCKS5

/// Minimal RFC-1928 no-auth SOCKS5 server. It ignores the requested target and
/// always connects to `originPort` on 127.0.0.1, then relays bidirectionally.
final class MockSOCKS5 {
    let fd: Int32
    let port: UInt16
    let originPort: UInt16

    init(originPort: UInt16) {
        let l = tcpListen()
        self.fd = l.fd
        self.port = l.port
        self.originPort = originPort
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { break }
            noSIGPIPE(c)
            Thread.detachNewThread { [weak self] in self?.handle(c) }
        }
    }

    private func handle(_ c: Int32) {
        defer { close(c) }
        // greeting: VER NMETHODS METHODS...
        guard let greeting = try? recvN(c, 2), greeting[0] == 0x05 else { return }
        let nmethods = Int(greeting[1])
        _ = try? recvN(c, nmethods)
        sendAll(c, [0x05, 0x00]) // no auth
        // request: VER CMD RSV ATYP ...
        guard let req = try? recvN(c, 4) else { return }
        let atyp = req[3]
        switch atyp {
        case 0x01: _ = try? recvN(c, 4 + 2)           // IPv4 + port
        case 0x03:
            guard let lenB = try? recvN(c, 1) else { return }
            _ = try? recvN(c, Int(lenB[0]) + 2)
        case 0x04: _ = try? recvN(c, 16 + 2)
        default: return
        }
        guard let up = tcpConnect(host: "127.0.0.1", port: originPort) else {
            sendAll(c, [0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) // connection refused
            return
        }
        defer { close(up) }
        sendAll(c, [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) // success
        bridge(c, up)
    }

    private func recvN(_ fd: Int32, _ count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let n = recv(fd, &buf, count - out.count, 0)
            if n <= 0 { throw NSError(domain: "socks", code: 1) }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    private func bridge(_ a: Int32, _ b: Int32) {
        var buf = [UInt8](repeating: 0, count: 16_384)
        var aReadDone = false
        var bReadDone = false
        while !(aReadDone && bReadDone) {
            var fds = [pollfd(fd: a, events: 0, revents: 0),
                       pollfd(fd: b, events: 0, revents: 0)]
            if !aReadDone { fds[0].events |= Int16(POLLIN) }
            if !bReadDone { fds[1].events |= Int16(POLLIN) }
            if poll(&fds, 2, 5000) <= 0 { break }
            if !aReadDone && fds[0].revents & Int16(POLLIN) != 0 {
                let n = recv(a, &buf, buf.count, 0)
                if n <= 0 { aReadDone = true; Darwin.shutdown(b, Int32(SHUT_WR)) }
                else { sendAll(b, Array(buf[0..<n])) }
            }
            if !bReadDone && fds[1].revents & Int16(POLLIN) != 0 {
                let n = recv(b, &buf, buf.count, 0)
                if n <= 0 { bReadDone = true; Darwin.shutdown(a, Int32(SHUT_WR)) }
                else { sendAll(a, Array(buf[0..<n])) }
            }
        }
    }
}

// MARK: - Mock WebSocket origin

/// Minimal WebSocket origin for the `ws://` upgrade regression. It reads the
/// request headers, asserts the proxy forwarded the upgrade intent, replies
/// `101 Switching Protocols`, then echoes every subsequent byte. Echoing raw
/// bytes (no framing) is enough to prove the relay is full-duplex after the
/// protocol switch.
final class MockWebSocketOrigin {
    let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var lastRequest = ""

    init() {
        let l = tcpListen()
        self.fd = l.fd
        self.port = l.port
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func lastRequestHeaders() -> String {
        lock.lock(); defer { lock.unlock() }
        return lastRequest
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { break }
            noSIGPIPE(c)
            Thread.detachNewThread { [weak self] in self?.handle(c) }
        }
    }

    private func handle(_ c: Int32) {
        defer { close(c) }
        guard let header = readUntilDoubleCRLF(c) else { return }
        let text = String(decoding: header, as: UTF8.self)
        lock.lock(); lastRequest = text; lock.unlock()
        // Only complete the upgrade when the proxy actually forwarded the
        // upgrade headers; otherwise answer like a plain HTTP origin would.
        let lower = text.lowercased()
        guard lower.contains("upgrade: websocket"), lower.contains("connection: upgrade") else {
            sendAll(c, Array("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        sendAll(c, Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8))
        var buf = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = recv(c, &buf, buf.count, 0)
            if n <= 0 { break }
            sendAll(c, Array(buf[0..<n]))
        }
    }

    private func readUntilDoubleCRLF(_ c: Int32) -> [UInt8]? {
        var out: [UInt8] = []
        var one = [UInt8](repeating: 0, count: 1)
        while out.count < 65_536 {
            let n = recv(c, &one, 1, 0)
            if n <= 0 { return nil }
            out.append(one[0])
            if out.count >= 4, out.suffix(4) == [13, 10, 13, 10] { return out }
        }
        return nil
    }
}

// MARK: - Proxy setup

func makeProxy(tunnelPort: UInt16, tunnelHost: String = "127.0.0.1") -> (ProxyServer, UInt16) {
    let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pm-e2e-\(UUID().uuidString).sqlite")
    let telemetry = TelemetryStore(dbURL: dbURL, maxRows: 1000, retentionDays: 1)
    let proxy = ProxyServer(telemetry: telemetry)
    proxy.isTunnelUp = { true }

    // Bind an ephemeral port by probing a free one.
    let probe = tcpListen()
    let port = probe.port
    close(probe.fd)

    var s = ProxyRuntimeSettings()
    s.bindHost = "127.0.0.1"
    s.port = port
    s.tunnelHost = tunnelHost
    s.tunnelPort = tunnelPort
    s.failClosed = false
    proxy.update(settings: s)
    // Tunnel everything used by the tests.
    proxy.routingEngine.update(rules: [
        TargetRule(pattern: "example.test"),
        TargetRule(pattern: "*.tunnel.test"),
        TargetRule(pattern: "ws.example.test"),
    ])
    do { try proxy.start() } catch { fatalError("proxy start failed: \(error)") }
    return (proxy, port)
}

// MARK: - Tests

print("== E2E: direct CONNECT ==")
do {
    let origin = MockOrigin()
    let (proxy, proxyPort) = makeProxy(tunnelPort: 1)
    defer { proxy.stop() }
    guard let c = tcpConnect(host: "127.0.0.1", port: proxyPort) else { fatalError("connect proxy failed") }
    defer { close(c) }
    // 127.0.0.1 is not in the allow-list -> direct to the origin host:port.
    sendAll(c, Array("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
    var buf = [UInt8](repeating: 0, count: 1024)
    let n = recv(c, &buf, buf.count, 0)
    let head = String(decoding: buf[0..<max(0, n)], as: UTF8.self)
    check("direct CONNECT returns 200", head.contains("200"))
    // Client half-closes; origin replies after seeing FIN.
    Darwin.shutdown(c, Int32(SHUT_WR))
    let resp = String(decoding: recvAll(c), as: UTF8.self)
    check("direct half-close delivers full body", resp.contains("HELLO-FROM-ORIGIN"))
}

print("== E2E: tunneled CONNECT via mock SOCKS5 ==")
do {
    let origin = MockOrigin(body: "TUNNELED-BODY")
    let socks = MockSOCKS5(originPort: origin.port)
    let (proxy, proxyPort) = makeProxy(tunnelPort: socks.port)
    defer { proxy.stop() }
    guard let c = tcpConnect(host: "127.0.0.1", port: proxyPort) else { fatalError("connect proxy failed") }
    defer { close(c) }
    sendAll(c, Array("CONNECT example.test:443 HTTP/1.1\r\nHost: example.test\r\n\r\n".utf8))
    var buf = [UInt8](repeating: 0, count: 1024)
    let n = recv(c, &buf, buf.count, 0)
    let head = String(decoding: buf[0..<max(0, n)], as: UTF8.self)
    check("tunneled CONNECT returns 200", head.contains("200"))
    Darwin.shutdown(c, Int32(SHUT_WR))
    let resp = String(decoding: recvAll(c), as: UTF8.self)
    check("tunneled half-close delivers full body", resp.contains("TUNNELED-BODY"))
}

print("== E2E: concurrency (200 parallel CONNECTs) ==")
do {
    let origin = MockOrigin(body: "CONCURRENT")
    let (proxy, proxyPort) = makeProxy(tunnelPort: 1)
    defer { proxy.stop() }
    let lock = NSLock()
    var ok = 0
    let group = DispatchGroup()
    for _ in 0..<200 {
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            guard let c = tcpConnect(host: "127.0.0.1", port: proxyPort) else { return }
            defer { close(c) }
            sendAll(c, Array("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\n\r\n".utf8))
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = recv(c, &buf, buf.count, 0)
            let head = String(decoding: buf[0..<max(0, n)], as: UTF8.self)
            guard head.contains("200") else { return }
            Darwin.shutdown(c, Int32(SHUT_WR))
            let body = String(decoding: recvAll(c), as: UTF8.self)
            if body.contains("CONCURRENT") { lock.lock(); ok += 1; lock.unlock() }
        }
    }
    _ = group.wait(timeout: .now() + 30)
    check("200 parallel CONNECTs all succeeded (got \(ok))", ok == 200)
}

print("== E2E: dead-peer reaping (RST burst) ==")
do {
    let origin = MockOrigin(body: "REAP")
    let (proxy, proxyPort) = makeProxy(tunnelPort: 1)
    defer { proxy.stop() }
    // Open connections and reset them abruptly while the relay holds data.
    for _ in 0..<50 {
        guard let c = tcpConnect(host: "127.0.0.1", port: proxyPort) else { continue }
        sendAll(c, Array("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\n\r\n".utf8))
        var l = linger(l_onoff: 1, l_linger: 0)
        setsockopt(c, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
        close(c) // RST
    }
    Thread.sleep(forTimeInterval: 5) // > relay grace timeout (3s)
    // A fresh request must still work, proving no resource exhaustion.
    guard let c = tcpConnect(host: "127.0.0.1", port: proxyPort) else { fatalError("proxy died after RST burst") }
    sendAll(c, Array("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\n\r\n".utf8))
    var buf = [UInt8](repeating: 0, count: 1024)
    let n = recv(c, &buf, buf.count, 0)
    let head = String(decoding: buf[0..<max(0, n)], as: UTF8.self)
    check("proxy still serves after RST burst", head.contains("200"))
    close(c)
}

print("== E2E: dead-peer poll spin + teardown (client RST, upstream held open) ==")
do {
    let origin = MockOriginHolding()
    let (proxy, proxyPort) = makeProxy(tunnelPort: 1)
    defer { proxy.stop() }
    guard let c = tcpConnect(host: "127.0.0.1", port: proxyPort) else { fatalError("connect proxy failed") }
    sendAll(c, Array("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\n\r\n".utf8))
    var buf = [UInt8](repeating: 0, count: 1024)
    let n = recv(c, &buf, buf.count, 0)
    check("spin-test CONNECT returns 200", String(decoding: buf[0..<max(0, n)], as: UTF8.self).contains("200"))
    // Reset the client while the upstream stays open and idle. This is the shape
    // that would spin if a finished fd were kept in the poll set: the relay must
    // not busy-poll, and it must not tear down while a relay permit is
    // outstanding. (On macOS poll() skips events==0 fds entirely, so the
    // events-mask spin does not currently manifest; the assertion guards the
    // invariant and the held-open upstream exercises the permit/teardown path.)
    var l = linger(l_onoff: 1, l_linger: 0)
    setsockopt(c, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
    close(c) // RST

    let before = cpuSeconds()
    Thread.sleep(forTimeInterval: 2)
    let spent = cpuSeconds() - before
    check("relay does not spin on a dead peer (\(String(format: "%.3f", spent))s CPU / 2s)",
          spent < 0.5)

    // A fresh request must still work.
    guard let c2 = tcpConnect(host: "127.0.0.1", port: proxyPort) else { fatalError("proxy died after dead-peer test") }
    sendAll(c2, Array("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\n\r\n".utf8))
    let n2 = recv(c2, &buf, buf.count, 0)
    check("proxy still serves after dead-peer test", String(decoding: buf[0..<max(0, n2)], as: UTF8.self).contains("200"))
    close(c2)
    origin.stop()
}

print("== E2E: ws:// WebSocket upgrade (direct) ==")
do {
    let ws = MockWebSocketOrigin()
    let (proxy, proxyPort) = makeProxy(tunnelPort: 1)
    defer { proxy.stop() }
    guard let c = tcpConnect(host: "127.0.0.1", port: proxyPort) else { fatalError("connect proxy failed") }
    defer { close(c) }
    setRecvTimeout(c, 5)
    // Absolute-form ws:// handshake, exactly as a browser sends it to an HTTP
    // forward proxy. 127.0.0.1 is not allow-listed -> direct to the origin.
    let req = "GET http://127.0.0.1:\(ws.port)/chat HTTP/1.1\r\n" +
        "Host: 127.0.0.1:\(ws.port)\r\n" +
        "Connection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    sendAll(c, Array(req.utf8))
    check("ws direct upgrade returns 101", readSome(c).contains("101"))
    check("ws direct origin saw upgrade headers",
          ws.lastRequestHeaders().lowercased().contains("upgrade: websocket"))
    check("ws direct origin saw Connection: Upgrade",
          ws.lastRequestHeaders().lowercased().contains("connection: upgrade"))
    // Post-upgrade full-duplex: client -> origin -> client.
    sendAll(c, Array("PING-1".utf8))
    check("ws direct echoes first frame", readExactly(c, 6) == "PING-1")
    sendAll(c, Array("PING-2".utf8))
    check("ws direct echoes second frame", readExactly(c, 6) == "PING-2")
}

print("== E2E: ws:// WebSocket upgrade through tunnel (mock SOCKS5) ==")
do {
    let ws = MockWebSocketOrigin()
    let socks = MockSOCKS5(originPort: ws.port)
    let (proxy, proxyPort) = makeProxy(tunnelPort: socks.port)
    defer { proxy.stop() }
    guard let c = tcpConnect(host: "127.0.0.1", port: proxyPort) else { fatalError("connect proxy failed") }
    defer { close(c) }
    setRecvTimeout(c, 5)
    // `ws.example.test` is allow-listed, so the upstream is opened through the
    // mock SOCKS5 (which always reaches the mock origin). Direct DNS for that
    // name would fail, so a 101 here proves the tunnel route was used.
    let req = "GET http://ws.example.test/chat HTTP/1.1\r\n" +
        "Host: ws.example.test\r\n" +
        "Connection: Upgrade\r\nUpgrade: websocket\r\n" +
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    sendAll(c, Array(req.utf8))
    check("ws tunneled upgrade returns 101", readSome(c).contains("101"))
    sendAll(c, Array("TUN-1".utf8))
    check("ws tunneled echoes frame", readExactly(c, 5) == "TUN-1")
}

print("== E2E: per-app rules (identity resolved from this process) ==")
// The client here is this test process, so the proxy's libproc scan resolves our
// own executable. Two mock origins with distinct bodies make the route provable:
// the mock SOCKS5 always reaches `socksOrigin`, so a body of "DIRECT-APP" means
// the request bypassed the tunnel and "TUNNEL-APP" means it used it.
let appExeName = (CommandLine.arguments[0] as NSString).lastPathComponent
do {
    // App rule "Direct all" must override an allow-listed host.
    let directOrigin = MockOrigin(body: "DIRECT-APP")
    let socksOrigin = MockOrigin(body: "TUNNEL-APP")
    let socks = MockSOCKS5(originPort: socksOrigin.port)
    let (proxy, proxyPort) = makeProxy(tunnelPort: socks.port)
    defer { proxy.stop() }
    var recSettings = proxy.snapshot()
    recSettings.recordAppInTelemetry = true
    proxy.update(settings: recSettings)
    // `localhost` is allow-listed, so without the app rule this would tunnel.
    proxy.routingEngine.update(rules: [TargetRule(pattern: "localhost")],
                               appRules: [AppRule(key: appExeName, keyKind: .executableName, mode: .direct)],
                               appEnabled: true, defaultMode: .targets)
    check("app rules require identity resolution", proxy.routingEngine.needsAppIdentity)
    guard let c = tcpConnect(host: "127.0.0.1", port: proxyPort) else { fatalError("connect proxy failed") }
    defer { close(c) }
    setRecvTimeout(c, 5)
    sendAll(c, Array("CONNECT localhost:\(directOrigin.port) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
    check("per-app direct CONNECT returns 200", readSome(c).contains("200"))
    Darwin.shutdown(c, Int32(SHUT_WR))
    let directResp = String(decoding: recvAll(c), as: UTF8.self)
    check("app Direct all bypasses the tunnel", directResp.contains("DIRECT-APP"))
    check("app Direct all did not use the tunnel", !directResp.contains("TUNNEL-APP"))
    // The recorded event must carry the resolved app (the 10 Hz flusher
    // publishes to `recentRequests` on main, so pump the run loop briefly).
    let appDeadline = Date().addingTimeInterval(2)
    while Date() < appDeadline,
          !proxy.telemetry.recentRequests.contains(where: { $0.app == appExeName }) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    check("recorded event carries the app", proxy.telemetry.recentRequests.contains { $0.app == appExeName })
}
do {
    // App rule "Tunnel all" must tunnel an unlisted host (default mode direct).
    let directOrigin = MockOrigin(body: "DIRECT-APP")
    let socksOrigin = MockOrigin(body: "TUNNEL-APP")
    let socks = MockSOCKS5(originPort: socksOrigin.port)
    let (proxy, proxyPort) = makeProxy(tunnelPort: socks.port)
    defer { proxy.stop() }
    proxy.routingEngine.update(rules: [],
                               appRules: [AppRule(key: appExeName, keyKind: .executableName, mode: .tunnel)],
                               appEnabled: true, defaultMode: .direct)
    guard let c = tcpConnect(host: "127.0.0.1", port: proxyPort) else { fatalError("connect proxy failed") }
    defer { close(c) }
    setRecvTimeout(c, 5)
    // Unlisted host: host rules alone would go direct to `directOrigin`.
    sendAll(c, Array("CONNECT 127.0.0.1:\(directOrigin.port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
    check("per-app tunnel CONNECT returns 200", readSome(c).contains("200"))
    Darwin.shutdown(c, Int32(SHUT_WR))
    let tunnelResp = String(decoding: recvAll(c), as: UTF8.self)
    check("app Tunnel all uses the tunnel", tunnelResp.contains("TUNNEL-APP"))
    check("app Tunnel all did not go direct", !tunnelResp.contains("DIRECT-APP"))
}

print("")
if failures == 0 { print("PASS: proxy e2e"); exit(0) }
else { print("FAIL: \(failures) e2e check(s) failed"); exit(1) }
