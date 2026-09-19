import Foundation

// Standalone regression harness (no XCTest / SPM).
//
// Build + run (see Tests/run-all.sh):
//   xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
//     Sources/Config/ConfigModels.swift Sources/Routing/RoutingEngine.swift \
//     Sources/Proxy/Atomic.swift Sources/Proxy/HTTPParser.swift \
//     Sources/System/HelperProtocol.swift \
//     Tests/RegressionHarness/main.swift -o /tmp/regression && /tmp/regression
//
// Every assertion corresponds to a hard requirement or a fixed bug. A failing
// line here is a real regression — do not "fix" the test to match the bug.

var failures = 0
var checks = 0

func check(_ name: String, _ condition: Bool) {
    checks += 1
    if condition {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)")
    }
}

print("== Routing engine ==")
check("exact match", RoutingEngine.matches(pattern: "api.example.com", host: "api.example.com"))
check("case-insensitive pattern", RoutingEngine.matches(pattern: "API.example.com", host: "api.example.com"))
check("wildcard subdomain", RoutingEngine.matches(pattern: "*.example.com", host: "a.example.com"))
check("wildcard apex", RoutingEngine.matches(pattern: "*.example.com", host: "example.com"))
check("leading-dot == wildcard", RoutingEngine.matches(pattern: ".example.com", host: "a.example.com"))
check("wildcard does NOT overmatch evil-example.com", !RoutingEngine.matches(pattern: "*.example.com", host: "evil-example.com"))
check("wildcard does NOT overmatch example.com.evil.com", !RoutingEngine.matches(pattern: "*.example.com", host: "example.com.evil.com"))
check("trailing dot stripped in pattern", RoutingEngine.matches(pattern: "example.com.", host: "example.com"))
check("normalize strips port", RoutingEngine.normalize("example.com:8443") == "example.com")
check("normalize lowercases", RoutingEngine.normalize("ExAmPlE.CoM") == "example.com")
// `matches` requires an already-normalized host (decide() normalizes first).
// Callers that forget normalization silently fail to match. Assert the
// normalized path works and document the trap.
check("normalized host matches case-insensitively", RoutingEngine.matches(pattern: "api.example.com", host: RoutingEngine.normalize("API.EXAMPLE.COM")))
check("normalized host matches with trailing dot", RoutingEngine.matches(pattern: "example.com", host: RoutingEngine.normalize("example.com.")))
check("TRAP: matches does not normalize the host itself", !RoutingEngine.matches(pattern: "example.com", host: "example.com."))

// Fail-open by design: unknown host -> direct.
check("unknown host routes direct", RoutingEngine().decide(host: "nope.test") == .direct)
// IPv6 literals are normalized (brackets + port stripped) so rules can match
// them instead of silently falling through to direct.
check("normalize strips brackets+port", RoutingEngine.normalize("[2001:db8::1]:443") == "2001:db8::1")
let ipv6Engine = RoutingEngine()
ipv6Engine.update(rules: [TargetRule(pattern: "2001:db8::1")])
check("IPv6 literal tunnels when listed", ipv6Engine.decide(host: "[2001:db8::1]:443") == .tunnel)
check("IPv6 literal direct when unlisted", RoutingEngine().decide(host: "[2001:db8::1]:443") == .direct)
check("normalize strips numeric port", RoutingEngine.normalize("host.example:8443") == "host.example")
check("normalize keeps IPv6 colons", RoutingEngine.normalize("2001:db8::1") == "2001:db8::1")

print("== SSRF host classification ==")
// The proxy has no auth, so non-loopback clients must not reach private
// destinations. But the fc/fd (IPv6 ULA) check must not swallow ordinary
// hostnames that merely start with those letters.
for host in ["127.0.0.1", "10.0.0.1", "192.168.1.1", "172.16.0.1", "169.254.1.1",
             "0.0.0.0", "localhost", "foo.local", "foo.localhost", "::1",
             "fc00::1", "fd00::1", "fe80::1"] {
    check("private: \(host)", HostClassifier.isPrivateOrLoopback(host))
}
for host in ["example.com", "fcdn.example.com", "fdroid.org", "fc.example.com",
             "8.8.8.8", "172.32.0.1", "172.15.0.1", "11.0.0.1", "169.253.0.1"] {
    check("not private: \(host)", !HostClassifier.isPrivateOrLoopback(host))
}

print("== HTTP parser safety ==")
let dup = Array("GET / HTTP/1.1\r\nHost: a.com\r\nhost: b.com\r\nX: 1\r\nX: 2\r\n\r\n".utf8)
check("duplicate-case headers do not crash", HTTPParser.parse(dup) != nil)
if let r = HTTPParser.parse(Array("CONNECT [2001:db8::1]:443 HTTP/1.1\r\n\r\n".utf8)) {
    check("IPv6 CONNECT host parsed", r.host == "2001:db8::1")
    check("IPv6 CONNECT port parsed", r.port == 443)
} else {
    check("IPv6 CONNECT parsed", false)
}
if let r = HTTPParser.parse(Array("CONNECT example.com:443 HTTP/1.1\r\n\r\n".utf8)) {
    check("normal CONNECT host", r.host == "example.com")
    check("normal CONNECT port", r.port == 443)
} else {
    check("normal CONNECT parsed", false)
}
check("header block detection", HTTPParser.findHeaderEnd(in: Array("A: 1\r\n\r\n".utf8)) != nil)

print("== HTTP rewrite / WebSocket upgrade ==")
func rewrite(_ raw: String) -> String {
    guard let req = HTTPParser.parse(Array(raw.utf8)) else { return "" }
    return HTTPParser.rewrite(req)
}
func parsed(_ raw: String) -> HTTPRequest? { HTTPParser.parse(Array(raw.utf8)) }

// A browser/app sends an absolute-form ws:// request to an HTTP forward proxy
// with `Connection: Upgrade` (possibly inside a token list) + `Upgrade: websocket`.
let wsReq = "GET http://ws.example.com/chat HTTP/1.1\r\nHost: ws.example.com\r\n" +
    "Connection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n" +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n" +
    "Proxy-Connection: keep-alive\r\n\r\n"
let wsOut = rewrite(wsReq)
check("ws upgrade keeps Upgrade header", wsOut.lowercased().contains("upgrade: websocket"))
check("ws upgrade sets Connection: Upgrade", wsOut.contains("Connection: Upgrade"))
check("ws upgrade never forces close", !wsOut.lowercased().contains("connection: close"))
check("ws upgrade keeps Sec-WebSocket-Key", wsOut.contains("Sec-WebSocket-Key:"))
check("ws upgrade keeps Sec-WebSocket-Version", wsOut.contains("Sec-WebSocket-Version: 13"))
check("ws upgrade strips Proxy-Connection", !wsOut.lowercased().contains("proxy-connection"))
check("ws upgrade rewrites to origin-form", wsOut.hasPrefix("GET /chat HTTP/1.1\r\n"))
check("ws upgrade re-adds Host", wsOut.contains("Host: ws.example.com\r\n"))

// Without the Connection: Upgrade token the same headers stay hop-by-hop and
// must still be stripped (no behavior change for ordinary HTTP).
let plainReq = "GET http://plain.example.com/a HTTP/1.1\r\nHost: plain.example.com\r\n" +
    "Connection: keep-alive\r\nUpgrade: websocket\r\n\r\n"
let plainOut = rewrite(plainReq)
check("plain request still strips Upgrade", !plainOut.lowercased().contains("upgrade:"))
check("plain request still forces Connection: close", plainOut.lowercased().contains("connection: close"))

check("isUpgrade true for Connection: Upgrade", parsed(wsReq)?.isUpgrade == true)
check("isUpgrade true when Upgrade token leads the list",
      parsed("GET / HTTP/1.1\r\nHost: h\r\nConnection: Upgrade, keep-alive\r\nUpgrade: websocket\r\n\r\n")?.isUpgrade == true)
check("isUpgrade token is case-insensitive",
      parsed("GET / HTTP/1.1\r\nHost: h\r\nConnection: UPGRADE\r\nUpgrade: WebSocket\r\n\r\n")?.isUpgrade == true)
check("isUpgrade false without Upgrade header",
      parsed("GET / HTTP/1.1\r\nHost: h\r\nConnection: Upgrade\r\n\r\n")?.isUpgrade == false)
check("isUpgrade false without Connection token",
      parsed("GET / HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\n\r\n")?.isUpgrade == false)
check("isUpgrade false for a normal request",
      parsed("GET http://h/ HTTP/1.1\r\nHost: h\r\nConnection: keep-alive\r\n\r\n")?.isUpgrade == false)

print("== Config schema migration ==")
// A config.json from an older build that lacks `policy`/`monitor`/`lock` must
// still decode (otherwise the user's whole config is silently wiped).
let legacy = """
{"version":1,"proxy":{"bindHost":"127.0.0.1","port":8888},"tunnel":{"mode":"MANUAL","host":"127.0.0.1","port":1080},"targets":[]}
""".data(using: .utf8)!
let legacyDecoded = try? JSONDecoder().decode(AppConfig.self, from: legacy)
check("legacy config (missing policy/monitor/lock) decodes", legacyDecoded != nil)
check("legacy config defaults injectGuiEnv to true", legacyDecoded?.system.injectGuiEnv == true)

// A newer config with an extra unknown key must not wipe data either.
let future = """
{"version":2,"proxy":{"bindHost":"127.0.0.1","port":8888,"extra":"x"},"tunnel":{"mode":"MANUAL","host":"127.0.0.1","port":1080},"targets":[{"id":"00000000-0000-0000-0000-000000000001","pattern":"api.example.com","enabled":true}]}
""".data(using: .utf8)!
let futureDecoded = try? JSONDecoder().decode(AppConfig.self, from: future)
check("future config (unknown keys) decodes", futureDecoded != nil)
check("future config preserves targets", futureDecoded?.targets.count == 1)

print("== networksetup argument validation ==")
check("plain service name valid", NetworksetupCommands.isValidService("Wi-Fi"))
check("spaces valid", NetworksetupCommands.isValidService("USB Ethernet"))
check("parens valid", NetworksetupCommands.isValidService("Ethernet (1)"))
// Real macOS service names contain '/': "USB 10/100/1000 LAN". Rejecting them
// silently drops the service from apply/restore on the helper path.
check("slash service name valid (USB 10/100/1000 LAN)", NetworksetupCommands.isValidService("USB 10/100/1000 LAN"))
check("shell metacharacter rejected", !NetworksetupCommands.isValidService("svc; rm -rf /"))
check("empty rejected", !NetworksetupCommands.isValidService(""))
check("backtick rejected", !NetworksetupCommands.isValidService("a`b`"))

print("== Snapshot validation (PAC) ==")
var s = ServiceProxyState()
s.webEnabled = true
s.webServer = "127.0.0.1"
s.webPort = "8888"
check("clean snapshot valid", s.isValid)
// `networksetup -getautoproxyurl` prints `URL: (null)` when no PAC is set.
// Storing that literal must not invalidate the whole service (which makes the
// helper restore a silent no-op and leaves the proxy dangling).
var pac = s
pac.pacURL = "(null)"
check("PAC '(null)' does not invalidate service", pac.isValid)
var badPort = s
badPort.webPort = "0"
check("port 0 rejected", !badPort.isValid)
var badPort2 = s
badPort2.webPort = "70000"
check("port 70000 rejected", !badPort2.isValid)
// Proxy servers may be IPv6 literals (the old check wrongly used the
// service-name charset and would have dropped them from a restore).
var ipv6Server = s
ipv6Server.webServer = "2001:db8::1"
check("IPv6 proxy server valid", ipv6Server.isValid)
var badServer = s
badServer.webServer = "evil; rm -rf /"
check("metachar proxy server rejected", !badServer.isValid)

print("== Snapshot migration ==")
// A snapshot persisted by a build before `bypassDomains` existed must still
// decode, or crash recovery silently fails.
let oldSnapshot = #"{"Wi-Fi":{"webEnabled":true,"webServer":"proxy.corp","webPort":"3128","secureEnabled":false,"secureServer":"","securePort":"","pacEnabled":false,"pacURL":"(null)"}}"#.data(using: .utf8)!
let oldDecoded = try? JSONDecoder().decode(SystemProxySnapshot.self, from: oldSnapshot)
check("old snapshot (no bypassDomains) decodes", oldDecoded != nil)
check("old snapshot PAC '(null)' normalized to empty", oldDecoded?["Wi-Fi"]?.pacURL == "")
check("old snapshot bypass defaults empty", oldDecoded?["Wi-Fi"]?.bypassDomains.isEmpty == true)

print("")
if failures == 0 {
    print("PASS: \(checks) checks")
    exit(0)
} else {
    print("FAIL: \(failures)/\(checks) checks failed")
    exit(1)
}
