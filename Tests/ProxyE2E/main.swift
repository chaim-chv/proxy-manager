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
//
// All helpers use Thread.detachNewThread (never DispatchQueue.global) so the
// mock itself is not throttled by GCD's ~64-thread blocking cap.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
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

print("")
if failures == 0 { print("PASS: proxy e2e"); exit(0) }
else { print("FAIL: \(failures) e2e check(s) failed"); exit(1) }
