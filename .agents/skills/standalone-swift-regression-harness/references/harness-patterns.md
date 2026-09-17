# Harness patterns

Copy-paste building blocks. All mocks use detached threads.

## Check helper + exit code

```swift
var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}
// ... at the end:
exit(failures == 0 ? 0 : 1)
```

## Free port

```swift
func tcpListen(port: UInt16 = 0) -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
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
```

## RST peer (SIGPIPE probe)

```swift
var l = linger(l_onoff: 1, l_linger: 0) // close() sends RST
setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
close(fd)
usleep(150_000) // let the RST arrive before sending
```

## Mock origin that proves half-close

Read the request **through EOF** (client FIN) before replying. If the proxy fails
to propagate FIN, the read never returns and the test times out; if the proxy
truncates the response, the body check fails.

```swift
func recvAll(_ fd: Int32) -> [UInt8] {
    var out: [UInt8] = []; var buf = [UInt8](repeating: 0, count: 4096)
    while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; out.append(contentsOf: buf[0..<n]) }
    return out
}
```

## Mock SOCKS5 half-close bridge

The bridge must keep relaying the *other* direction after one side EOFs. A naive
`break` on EOF truncates the response and produces false failures.

```swift
var aReadDone = false, bReadDone = false
while !(aReadDone && bReadDone) {
    var fds = [pollfd(fd: a, events: 0, revents: 0), pollfd(fd: b, events: 0, revents: 0)]
    if !aReadDone { fds[0].events |= Int16(POLLIN) }
    if !bReadDone { fds[1].events |= Int16(POLLIN) }
    if poll(&fds, 2, 5000) <= 0 { break }
    if !aReadDone && fds[0].revents & Int16(POLLIN) != 0 {
        let n = recv(a, &buf, buf.count, 0)
        if n <= 0 { aReadDone = true; Darwin.shutdown(b, Int32(SHUT_WR)) } else { sendAll(b, Array(buf[0..<n])) }
    }
    // symmetric for b
}
```

## Crash-probe driver (bash)

```bash
"$BIN"
rc=$?
if [ $rc -ge 128 ]; then echo "CRASHED: signal $((rc-128))"; fi
# 133 = SIGTRAP (Swift trap), 141 = SIGPIPE
```

## e2e proxy setup

```swift
let telemetry = TelemetryStore(dbURL: tmpDBURL, maxRows: 1000, retentionDays: 1)
let proxy = ProxyServer(telemetry: telemetry)
proxy.isTunnelUp = { true }              // force tunnel route for tests
let probe = tcpListen(); let port = probe.port; close(probe.fd) // free port
var s = ProxyRuntimeSettings()
s.bindHost = "127.0.0.1"; s.port = port
s.tunnelHost = "127.0.0.1"; s.tunnelPort = socks.port
proxy.update(settings: s)
proxy.routingEngine.update(rules: [TargetRule(pattern: "example.test")])
try proxy.start()
```
