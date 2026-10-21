import Foundation
import Darwin

// Standalone regression harness (no XCTest / SPM).
//
// Build + run (see Tests/run-all.sh):
//   xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
//     Sources/Config/ConfigModels.swift Sources/Routing/RoutingEngine.swift \
//     Sources/Routing/AppIdentity.swift \
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
// String normalization: a single trailing dot must not defeat the guard, and
// numeric IPv6 (bracketed or not) is classified, including IPv4-mapped forms.
for host in ["localhost.", "  LOCALHOST.  ", "foo.localhost.", "[::1]", "::1",
             "::ffff:127.0.0.1", "fe80::1"] {
    check("private (normalized): \(host)", HostClassifier.isPrivateOrLoopback(host))
}
for host in ["example.com.", "[2001:4860:4860::8888]", "::ffff:8.8.8.8"] {
    check("not private (normalized): \(host)", !HostClassifier.isPrivateOrLoopback(host))
}

// Address-based classification is the authoritative check: the proxy resolves,
// then inspects every candidate sockaddr before connecting.
func classifyIPv4(_ s: String) -> Bool {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    _ = inet_pton(AF_INET, s, &a.sin_addr)
    return withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            HostClassifier.isPrivateOrLoopback($0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}
func classifyIPv6(_ s: String) -> Bool {
    var a = sockaddr_in6()
    a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    a.sin6_family = sa_family_t(AF_INET6)
    _ = inet_pton(AF_INET6, s, &a.sin6_addr)
    return withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            HostClassifier.isPrivateOrLoopback($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
    }
}

print("== SSRF resolved-address classification ==")
for ip in ["0.0.0.0", "0.1.2.3", "10.0.0.1", "100.64.0.1", "100.127.255.255",
           "127.0.0.1", "127.255.255.255", "169.254.1.1", "172.16.0.1", "172.31.255.255",
           "192.0.0.1", "192.0.2.1", "192.168.1.1", "198.18.0.1", "198.19.255.255",
           "198.51.100.1", "203.0.113.1", "224.0.0.1", "239.255.255.255", "240.0.0.1",
           "255.255.255.255"] {
    check("addr private v4: \(ip)", classifyIPv4(ip))
}
for ip in ["8.8.8.8", "1.1.1.1", "11.0.0.1", "100.63.255.255", "100.128.0.1",
           "169.253.0.1", "172.15.0.1", "172.32.0.1", "198.17.255.255", "198.20.0.1",
           "223.255.255.255"] {
    check("addr public v4: \(ip)", !classifyIPv4(ip))
}
for ip in ["::", "::1", "fe80::1", "fc00::1", "fd00::1", "ff02::1",
           "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:192.168.0.1"] {
    check("addr private v6: \(ip)", classifyIPv6(ip))
}
for ip in ["2001:4860:4860::8888", "2606:4700::1111", "::ffff:8.8.8.8"] {
    check("addr public v6: \(ip)", !classifyIPv6(ip))
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

// The rewritten Host must be the full authority: `request.host` is host-only,
// so using it dropped non-default ports and IPv6 brackets (PS-04).
func hostLines(_ raw: String) -> [String] {
    raw.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("host:") }
}
let portReq = "GET http://example.com:8080/api?x=1 HTTP/1.1\r\nHost: example.com:8080\r\n\r\n"
let portOut = rewrite(portReq)
check("absolute non-default port: request line", portOut.hasPrefix("GET /api?x=1 HTTP/1.1\r\n"))
check("absolute non-default port: exactly one Host", hostLines(portOut) == ["Host: example.com:8080"])

let http80Out = rewrite("GET http://example.com:80/x HTTP/1.1\r\nHost: example.com:80\r\n\r\n")
check("http default port 80 omitted from Host", hostLines(http80Out) == ["Host: example.com"])
let https443Out = rewrite("GET https://example.com:443/x HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
check("https default port 443 omitted from Host", hostLines(https443Out) == ["Host: example.com"])
let httpsPortOut = rewrite("GET https://example.com:8443/x HTTP/1.1\r\nHost: example.com:8443\r\n\r\n")
check("https non-default port kept in Host", hostLines(httpsPortOut) == ["Host: example.com:8443"])

let ipv6Out = rewrite("GET http://[::1]:8080/x HTTP/1.1\r\nHost: [::1]:8080\r\n\r\n")
check("IPv6 absolute-form Host keeps brackets+port", hostLines(ipv6Out) == ["Host: [::1]:8080"])
let ipv6DefaultOut = rewrite("GET http://[::1]/x HTTP/1.1\r\nHost: [::1]\r\n\r\n")
check("IPv6 absolute-form default port Host keeps brackets", hostLines(ipv6DefaultOut) == ["Host: [::1]"])

let originPortOut = rewrite("GET /x HTTP/1.1\r\nHost: example.com:8080\r\n\r\n")
check("origin-form preserves client Host verbatim", hostLines(originPortOut) == ["Host: example.com:8080"])
check("origin-form request line unchanged", originPortOut.hasPrefix("GET /x HTTP/1.1\r\n"))
let originIPv6Out = rewrite("GET /x HTTP/1.1\r\nHost: [::1]:8080\r\n\r\n")
check("origin-form preserves bracketed IPv6 Host", hostLines(originIPv6Out) == ["Host: [::1]:8080"])

let queryOnlyOut = rewrite("GET http://example.com?x=1 HTTP/1.1\r\nHost: example.com\r\n\r\n")
check("query-only absolute URL keeps slash", queryOnlyOut.hasPrefix("GET /?x=1 HTTP/1.1\r\n"))
check("query-only absolute URL Host", hostLines(queryOnlyOut) == ["Host: example.com"])

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

print("== Icon placement ==")
check("menu bar only hides the Dock icon with no app windows",
      !AppIconMode.menuBarOnly.dockIconVisible(hasOpenAppWindow: false))
check("menu bar only shows the Dock icon while a Dashboard/Settings window is open",
      AppIconMode.menuBarOnly.dockIconVisible(hasOpenAppWindow: true))
check("menu bar + Dock always shows the Dock icon",
      AppIconMode.menuBarAndDock.dockIconVisible(hasOpenAppWindow: false))
check("Dock only always shows the Dock icon",
      AppIconMode.dockOnly.dockIconVisible(hasOpenAppWindow: false))
check("open windows never hide the menu bar item",
      AppIconMode.menuBarOnly.showsMenuBarIcon &&
      AppIconMode.menuBarAndDock.showsMenuBarIcon &&
      !AppIconMode.dockOnly.showsMenuBarIcon)

print("== Per-app config ==")
// Absent `apps` block defaults to off (legacy config decoded above).
check("legacy config defaults apps off", legacyDecoded?.apps.enabled == false)
check("legacy config defaults app mode to targets", legacyDecoded?.apps.defaultMode == .targets)
check("legacy config has no app rules", legacyDecoded?.apps.rules.isEmpty == true)

let appsJSON = """
{"version":2,"apps":{"enabled":true,"defaultMode":"DIRECT","recordInTelemetry":false,"rules":[{"id":"00000000-0000-0000-0000-000000000010","key":"com.google.Chrome","keyKind":"BUNDLE","mode":"TUNNEL","enabled":true},{"id":"00000000-0000-0000-0000-000000000011","key":"/usr/local/bin/node","keyKind":"EXECUTABLE","mode":"DIRECT"}]}}
""".data(using: .utf8)!
let appsDecoded = try? JSONDecoder().decode(AppConfig.self, from: appsJSON)
check("apps config decodes", appsDecoded != nil)
check("apps enabled decoded", appsDecoded?.apps.enabled == true)
check("apps defaultMode decoded", appsDecoded?.apps.defaultMode == .direct)
check("apps recordInTelemetry decoded", appsDecoded?.apps.recordInTelemetry == false)
check("apps rules decoded", appsDecoded?.apps.rules.count == 2)
check("app rule keyKind decoded", appsDecoded?.apps.rules.first?.keyKind == .bundle)
check("app rule mode decoded", appsDecoded?.apps.rules.first?.mode == .tunnel)
check("app rule missing enabled defaults true", appsDecoded?.apps.rules.last?.enabled == true)

// An unknown enum value written by a future build must not wipe the config.
let weirdApp = """
{"targets":[{"pattern":"keep.example.com"}],"apps":{"defaultMode":"NOPE","rules":[{"key":"x","keyKind":"NOPE","mode":"NOPE"}]}}
""".data(using: .utf8)!
let weirdDecoded = try? JSONDecoder().decode(AppConfig.self, from: weirdApp)
check("unknown app enum values do not wipe config", weirdDecoded != nil)
check("unknown app enum keeps other data", weirdDecoded?.targets.count == 1)
check("unknown app mode falls back to targets", weirdDecoded?.apps.rules.first?.mode == .targets)
check("unknown app routing disables the rule", weirdDecoded?.apps.rules.first?.enabled == false)

print("== Tolerant config decode (TC-01) ==")
func decodeConfig(_ json: String) -> AppConfig? {
    try? JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
}

// One bad value must never wipe every other setting. This fixture combines an
// unknown enum, a wrong JSON type, an out-of-range port, a malformed UUID and a
// malformed array entry.
let hostileJSON = """
{
  "version": 1,
  "proxy": {"bindHost": 123, "port": 70000},
  "tunnel": {
    "mode": "FUTURE",
    "host": 42,
    "port": -1,
    "managed": {"sshPort": 0, "socksPort": "abc", "auth": "FUTURE", "sshHost": 7}
  },
  "policy": {"failClosedWhenTunnelDown": "yes"},
  "system": {
    "appearanceMode": "FUTURE",
    "iconMode": "FUTURE",
    "managedShellRcs": "nope",
    "crashWatchdog": "yes",
    "injectShellEnv": 1
  },
  "monitor": {"retentionDays": 99999, "maxRows": -5},
  "targets": [
    {"id": "not-a-uuid", "pattern": "keep.example.com"},
    {"id": "00000000-0000-0000-0000-000000000002", "pattern": 123},
    "not-an-object",
    {"id": "00000000-0000-0000-0000-000000000003", "pattern": "keep2.example.com", "enabled": "yes"}
  ],
  "apps": {
    "enabled": true,
    "defaultMode": "FUTURE",
    "rules": [
      {"id": "bad", "key": "com.example.future", "keyKind": "FUTURE", "mode": "FUTURE"},
      {"key": "/usr/bin/ok", "keyKind": "EXECUTABLE", "mode": "DIRECT"},
      {"key": 123, "keyKind": "BUNDLE", "mode": "TUNNEL"},
      "junk"
    ]
  },
  "unknownTopLevel": {"x": 1}
}
"""
let hostile = decodeConfig(hostileJSON)
check("hostile config decodes", hostile != nil)
check("wrong-typed bindHost falls back", hostile?.proxy.bindHost == "127.0.0.1")
check("port 70000 clamps to 65535", hostile?.proxy.port == 65535)
check("unknown tunnel mode falls back to manual", hostile?.tunnel.mode == .manual)
check("wrong-typed tunnel host falls back", hostile?.tunnel.host == "127.0.0.1")
check("port -1 uses the documented default", hostile?.tunnel.port == 1080)
check("ssh port 0 uses the documented default", hostile?.tunnel.managed.sshPort == 22)
check("wrong-typed socks port uses the default", hostile?.tunnel.managed.socksPort == 1080)
check("unknown SSH auth falls back to key", hostile?.tunnel.managed.auth == .key)
check("wrong-typed sshHost falls back", hostile?.tunnel.managed.sshHost == "")
check("unknown appearance mode falls back to system", hostile?.system.appearanceMode == .system)
check("unknown icon mode falls back", hostile?.system.iconMode == .menuBarAndDock)
check("wrong-typed managedShellRcs falls back", hostile?.system.managedShellRcs == ["~/.zshrc"])
check("wrong-typed system bools fall back",
      hostile?.system.crashWatchdog == true && hostile?.system.injectShellEnv == true)
check("wrong-typed policy bool falls back", hostile?.policy.failClosedWhenTunnelDown == false)
check("retentionDays clamps to 3650", hostile?.monitor.retentionDays == 3650)
check("maxRows clamps to 0", hostile?.monitor.maxRows == 0)
check("valid targets survive invalid entries",
      hostile?.targets.map(\.pattern) == ["keep.example.com", "keep2.example.com"])
check("malformed target UUID is regenerated", hostile?.targets.first?.id != nil)
check("wrong-typed target enabled falls back", hostile?.targets.last?.enabled == true)
check("unknown app defaultMode falls back", hostile?.apps.defaultMode == .targets)
check("invalid app rules are skipped", hostile?.apps.rules.count == 2)
check("unknown app routing keeps a disabled rule", hostile?.apps.rules.first?.enabled == false)
check("unknown app routing rule keeps its key", hostile?.apps.rules.first?.key == "com.example.future")
check("valid app rule survives",
      hostile?.apps.rules.last?.key == "/usr/bin/ok" && hostile?.apps.rules.last?.mode == .direct)
check("unknown top-level keys are ignored", hostile?.version == 1)

let nullsJSON = """
{"version": null, "proxy": null, "tunnel": null, "policy": null, "system": null,
 "targets": null, "monitor": null, "lock": null, "apps": null}
"""
let nulls = decodeConfig(nullsJSON)
check("null fields decode to defaults", nulls != nil)
check("null proxy uses defaults", nulls?.proxy.port == 8888)
check("null targets yields an empty allow-list", nulls?.targets.isEmpty == true)
check("null apps block defaults off", nulls?.apps.enabled == false)
check("null version defaults to 1", nulls?.version == 1)

let negProxy = decodeConfig("{\"proxy\":{\"port\":-1}}")
check("proxy port -1 uses the documented default", negProxy?.proxy.port == 8888)

print("== Per-app routing precedence ==")
func appIdentity(bundle: String? = nil, path: String = "/usr/bin/x",
                 name: String = "x") -> AppIdentity {
    AppIdentity(pid: 1, bundleId: bundle, executablePath: path,
                executableName: name, displayName: name)
}

// Feature off -> pure host rules, even with rules configured.
let appDisabled = RoutingEngine()
appDisabled.update(rules: [TargetRule(pattern: "api.example.com")],
                   appRules: [AppRule(key: "com.google.Chrome", keyKind: .bundle, mode: .direct)],
                   appEnabled: false, defaultMode: .direct)
check("app routing off ignores app rules",
      appDisabled.decide(host: "api.example.com", app: appIdentity(bundle: "com.google.Chrome")) == .tunnel)
check("app routing off needs no identity", appDisabled.needsAppIdentity == false)

// Tunnel all overrides an unlisted host.
let appTunnel = RoutingEngine()
appTunnel.update(rules: [], appRules: [AppRule(key: "com.google.Chrome", keyKind: .bundle, mode: .tunnel)],
                 appEnabled: true, defaultMode: .targets)
check("Tunnel all tunnels an unlisted host",
      appTunnel.decide(host: "other.example", app: appIdentity(bundle: "com.google.Chrome")) == .tunnel)
check("identity required when a rule exists", appTunnel.needsAppIdentity == true)

// Direct all overrides an allow-listed host.
let appDirect = RoutingEngine()
appDirect.update(rules: [TargetRule(pattern: "api.example.com")],
                 appRules: [AppRule(key: "com.google.Chrome", keyKind: .bundle, mode: .direct)],
                 appEnabled: true, defaultMode: .targets)
check("Direct all blocks an allow-listed host",
      appDirect.decide(host: "api.example.com", app: appIdentity(bundle: "com.google.Chrome")) == .direct)

// Use target rules falls through to the allow-list.
let appTargets = RoutingEngine()
appTargets.update(rules: [TargetRule(pattern: "api.example.com")],
                  appRules: [AppRule(key: "com.google.Chrome", keyKind: .bundle, mode: .targets)],
                  appEnabled: true, defaultMode: .targets)
check("Use target rules follows allow-list (tunnel)",
      appTargets.decide(host: "api.example.com", app: appIdentity(bundle: "com.google.Chrome")) == .tunnel)
check("Use target rules follows allow-list (direct)",
      appTargets.decide(host: "other.example", app: appIdentity(bundle: "com.google.Chrome")) == .direct)

// Default mode for apps with no matching rule.
let appDefaultDirect = RoutingEngine()
appDefaultDirect.update(rules: [TargetRule(pattern: "api.example.com")],
                        appRules: [AppRule(key: "com.google.Chrome", keyKind: .bundle, mode: .tunnel)],
                        appEnabled: true, defaultMode: .direct)
check("default Direct all sends an unlisted app direct",
      appDefaultDirect.decide(host: "api.example.com", app: appIdentity(bundle: "com.other.App")) == .direct)
check("default Direct all does not leak an allow-listed host for an unresolved app",
      appDefaultDirect.decide(host: "api.example.com", app: nil) == .direct)

let appDefaultTunnel = RoutingEngine()
appDefaultTunnel.update(rules: [], appRules: [AppRule(key: "com.google.Chrome", keyKind: .bundle, mode: .tunnel)],
                        appEnabled: true, defaultMode: .tunnel)
check("default Tunnel all tunnels an unlisted app",
      appDefaultTunnel.decide(host: "other.example", app: appIdentity(bundle: "com.other.App")) == .tunnel)

// Matching by executable path and name.
let appExecPath = RoutingEngine()
appExecPath.update(rules: [], appRules: [AppRule(key: "/usr/local/bin/node", keyKind: .executable, mode: .tunnel)],
                   appEnabled: true, defaultMode: .direct)
check("executable path rule matches",
      appExecPath.decide(host: "h", app: appIdentity(path: "/usr/local/bin/node", name: "node")) == .tunnel)
check("executable path rule does not match another path",
      appExecPath.decide(host: "h", app: appIdentity(path: "/opt/node", name: "node")) == .direct)

let appExecName = RoutingEngine()
appExecName.update(rules: [], appRules: [AppRule(key: "node", keyKind: .executableName, mode: .tunnel)],
                   appEnabled: true, defaultMode: .direct)
check("executable name rule matches any path",
      appExecName.decide(host: "h", app: appIdentity(path: "/anything/node", name: "node")) == .tunnel)

// Disabled rules ignored; bundle match wins over executable.
let appMixed = RoutingEngine()
appMixed.update(rules: [], appRules: [
    AppRule(key: "com.google.Chrome", keyKind: .bundle, mode: .tunnel),
    AppRule(key: "com.other", keyKind: .bundle, mode: .direct, enabled: false),
], appEnabled: true, defaultMode: .direct)
check("disabled app rule is ignored",
      appMixed.decide(host: "h", app: appIdentity(bundle: "com.other")) == .direct)
check("bundle rule wins over executable",
      appMixed.decide(host: "h", app: appIdentity(bundle: "com.google.Chrome", path: "/x/node", name: "node")) == .tunnel)

// No rules -> identity not required, but the default mode still applies.
let appNoRules = RoutingEngine()
appNoRules.update(rules: [TargetRule(pattern: "api.example.com")], appRules: [],
                  appEnabled: true, defaultMode: .direct)
check("no rules -> identity not required", appNoRules.needsAppIdentity == false)
check("no rules -> default Direct all applies",
      appNoRules.decide(host: "api.example.com", app: nil) == .direct)

let appNoRulesTargets = RoutingEngine()
appNoRulesTargets.update(rules: [TargetRule(pattern: "api.example.com")], appRules: [],
                         appEnabled: true, defaultMode: .targets)
check("no rules + default targets -> host allow-list",
      appNoRulesTargets.decide(host: "api.example.com", app: nil) == .tunnel)
check("no rules + default targets -> direct otherwise",
      appNoRulesTargets.decide(host: "other", app: nil) == .direct)

// First rule wins for a duplicate key.
let appDup = RoutingEngine()
appDup.update(rules: [], appRules: [
    AppRule(key: "com.a", keyKind: .bundle, mode: .tunnel),
    AppRule(key: "com.a", keyKind: .bundle, mode: .direct),
], appEnabled: true, defaultMode: .targets)
check("first duplicate app rule wins",
      appDup.decide(host: "h", app: appIdentity(bundle: "com.a")) == .tunnel)

print("== Routing explanation ==")
let expHost = RoutingEngine()
expHost.update(rules: [TargetRule(pattern: "api.example.com"), TargetRule(pattern: "*.wild.test")])
let exactExp = expHost.explain(host: "api.example.com", app: nil)
check("explain exact target", exactExp.reason == .targetExact && exactExp.route == .tunnel)
check("explain exact matched pattern", exactExp.matched == "api.example.com")
let wildExp = expHost.explain(host: "a.wild.test", app: nil)
check("explain wildcard target", wildExp.reason == .targetWildcard && wildExp.route == .tunnel)
check("explain wildcard matched pattern", wildExp.matched == "*.wild.test")
let noneExp = expHost.explain(host: "other.test", app: nil)
check("explain no match", noneExp.reason == .noMatch && noneExp.route == .direct)

let expApp = RoutingEngine()
expApp.update(rules: [TargetRule(pattern: "api.example.com")],
              appRules: [AppRule(key: "com.google.Chrome", keyKind: .bundle, mode: .tunnel)],
              appEnabled: true, defaultMode: .direct)
let appExp = expApp.explain(host: "other.test", app: appIdentity(bundle: "com.google.Chrome"))
check("explain app Tunnel all", appExp.reason == .appTunnel && appExp.route == .tunnel)
check("explain app Tunnel all matched key", appExp.matched == "com.google.Chrome")
let defExp = expApp.explain(host: "other.test", app: appIdentity(bundle: "com.other"))
check("explain app default Direct", defExp.reason == .appDefaultDirect && defExp.route == .direct)

let expAppTargets = RoutingEngine()
expAppTargets.update(rules: [TargetRule(pattern: "api.example.com")],
                     appRules: [AppRule(key: "com.google.Chrome", keyKind: .bundle, mode: .targets)],
                     appEnabled: true, defaultMode: .targets)
let atExp = expAppTargets.explain(host: "api.example.com", app: appIdentity(bundle: "com.google.Chrome"))
check("explain app Use target rules -> exact",
      atExp.reason == .targetExact && atExp.appRuleMode == .targets)

let expOff = RoutingEngine()
expOff.update(rules: [TargetRule(pattern: "api.example.com")])
let offExp = expOff.explain(host: "api.example.com", app: appIdentity(bundle: "com.google.Chrome"))
check("explain app routing off -> host rules", offExp.reason == .targetExact)

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

print("== system proxy host (LC-11) ==")
// The system proxy must point at the host the listener actually bound. A bare
// loopback apply against a LAN listener sends browser/system traffic to a dead
// port while the UI still reports ON.
let lanApply = NetworksetupCommands.applyProxy(services: ["Wi-Fi"], port: 8888, host: "192.168.1.10")
check("apply uses the configured host (web)",
      lanApply.contains(["-setwebproxy", "Wi-Fi", "192.168.1.10", "8888"]))
check("apply uses the configured host (secure)",
      lanApply.contains(["-setsecurewebproxy", "Wi-Fi", "192.168.1.10", "8888"]))
let defaultApply = NetworksetupCommands.applyProxy(services: ["Wi-Fi"], port: 8888)
check("apply defaults to loopback (web)",
      defaultApply.contains(["-setwebproxy", "Wi-Fi", "127.0.0.1", "8888"]))
check("apply defaults to loopback (secure)",
      defaultApply.contains(["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "8888"]))
check("default apply never emits the non-loopback host",
      !defaultApply.contains(["-setwebproxy", "Wi-Fi", "192.168.1.10", "8888"]))
check("apply keeps the bypass list",
      lanApply.contains(["-setproxybypassdomains", "Wi-Fi"] + NetworksetupCommands.bypass))

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
check("old snapshot web auth defaults false", oldDecoded?["Wi-Fi"]?.webAuthenticated == false)
check("old snapshot secure auth defaults false", oldDecoded?["Wi-Fi"]?.secureAuthenticated == false)
check("old snapshot auto-discovery defaults false", oldDecoded?["Wi-Fi"]?.autoDiscoveryEnabled == false)

print("== Restore fidelity (LC-16) ==")

// An originally empty bypass list must clear the app's bypass entries, using
// the documented `networksetup` form for "no domains".
let emptyBypassCmds = NetworksetupCommands.restore(snapshot: ["Wi-Fi": ServiceProxyState()])
check("empty bypass clears the list",
      emptyBypassCmds.contains(["-setproxybypassdomains", "Wi-Fi", "Empty"]))
check("non-empty bypass restored verbatim",
      NetworksetupCommands.restore(snapshot: ["Wi-Fi": {
          var st = ServiceProxyState()
          st.bypassDomains = ["*.local", "10.0.0.0/8"]
          return st
      }()]).contains(["-setproxybypassdomains", "Wi-Fi", "*.local", "10.0.0.0/8"]))

// PAC enabled with no URL must never be enabled (that breaks connectivity) and
// must not emit a URL command at all.
var pacNoURL = ServiceProxyState()
pacNoURL.pacEnabled = true
let pacNoURLCmds = NetworksetupCommands.restore(snapshot: ["Wi-Fi": pacNoURL])
check("PAC on with empty URL is disabled",
      pacNoURLCmds.contains(["-setautoproxystate", "Wi-Fi", "off"]))
check("PAC on with empty URL sets no URL",
      !pacNoURLCmds.contains(where: { $0.first == "-setautoproxyurl" }))

// PAC enabled with a valid URL restores the URL and turns PAC on.
var pacURLState = ServiceProxyState()
pacURLState.pacEnabled = true
pacURLState.pacURL = "http://pac.corp/proxy.pac"
let pacURLCmds = NetworksetupCommands.restore(snapshot: ["Wi-Fi": pacURLState])
check("PAC valid URL restored",
      pacURLCmds.contains(["-setautoproxyurl", "Wi-Fi", "http://pac.corp/proxy.pac"]))
check("PAC valid URL enabled",
      pacURLCmds.contains(["-setautoproxystate", "Wi-Fi", "on"]))

// A valid but disabled PAC URL is restored without turning PAC on.
var pacOffState = ServiceProxyState()
pacOffState.pacURL = "https://pac.corp/proxy.pac"
let pacOffCmds = NetworksetupCommands.restore(snapshot: ["Wi-Fi": pacOffState])
check("disabled PAC URL restored",
      pacOffCmds.contains(["-setautoproxyurl", "Wi-Fi", "https://pac.corp/proxy.pac"]))
check("disabled PAC stays off",
      pacOffCmds.contains(["-setautoproxystate", "Wi-Fi", "off"]))
check("non-HTTP PAC URL is not applied",
      !NetworksetupCommands.restore(snapshot: ["Wi-Fi": {
          var st = ServiceProxyState()
          st.pacURL = "ftp://pac.corp/proxy.pac"
          return st
      }()]).contains(where: { $0.first == "-setautoproxyurl" }))

// Auto Proxy Discovery must be restored both ways.
var discoveryOn = ServiceProxyState()
discoveryOn.autoDiscoveryEnabled = true
check("auto-discovery on restored",
      NetworksetupCommands.restore(snapshot: ["Wi-Fi": discoveryOn])
        .contains(["-setproxyautodiscovery", "Wi-Fi", "on"]))
check("auto-discovery off restored",
      NetworksetupCommands.restore(snapshot: ["Wi-Fi": ServiceProxyState()])
        .contains(["-setproxyautodiscovery", "Wi-Fi", "off"]))

// The authenticated-proxy flag must round-trip on web/secure commands.
var authState = ServiceProxyState()
authState.webEnabled = true
authState.webServer = "proxy.corp"
authState.webPort = "3128"
authState.webAuthenticated = true
authState.secureEnabled = true
authState.secureServer = "proxy.corp"
authState.securePort = "3129"
authState.secureAuthenticated = false
let authCmds = NetworksetupCommands.restore(snapshot: ["Wi-Fi": authState])
check("web auth on restored",
      authCmds.contains(["-setwebproxy", "Wi-Fi", "proxy.corp", "3128", "on"]))
check("secure auth off restored",
      authCmds.contains(["-setsecurewebproxy", "Wi-Fi", "proxy.corp", "3129", "off"]))
check("auth flags survive the XPC dictionary round-trip",
      ServiceProxyState(dictionary: authState.dictionary).webAuthenticated
      && !ServiceProxyState(dictionary: authState.dictionary).secureAuthenticated)
var discoveryRoundTrip = ServiceProxyState()
discoveryRoundTrip.autoDiscoveryEnabled = true
check("auto-discovery survives the XPC dictionary round-trip",
      ServiceProxyState(dictionary: discoveryRoundTrip.dictionary).autoDiscoveryEnabled)

print("== Missing-service tolerance ==")
// A deleted USB/dock/VPN service makes `networksetup` exit 8 with this text.
// Treating it as a real failure aborts the whole restore and escalates to an
// admin prompt, so disable/quit/watchdog can never repair the proxy.
check("missing service error positive", NetworksetupCommands.isMissingServiceError("Unable to find item in network database"))
check("missing service error case-insensitive", NetworksetupCommands.isMissingServiceError("ERROR: UNABLE TO FIND ITEM IN NETWORK DATABASE"))
check("permission error is not missing service", !NetworksetupCommands.isMissingServiceError("You must be root to run this tool."))
check("timeout is not missing service", !NetworksetupCommands.isMissingServiceError("networksetup timed out"))
check("empty error is not missing service", !NetworksetupCommands.isMissingServiceError(""))

// Restore iterates a dictionary; command order must be deterministic so one
// stale service cannot change which services get restored on each attempt.
var zetaState = ServiceProxyState()
zetaState.webEnabled = true
zetaState.webServer = "proxy.corp"
zetaState.webPort = "3128"
let twoServiceSnapshot: SystemProxySnapshot = ["Zeta": zetaState, "Alpha": ServiceProxyState()]
let orderedRestore = NetworksetupCommands.restore(snapshot: twoServiceSnapshot)
let lastAlphaIndex = orderedRestore.lastIndex { $0.count > 1 && $0[1] == "Alpha" }
let firstZetaIndex = orderedRestore.firstIndex { $0.count > 1 && $0[1] == "Zeta" }
check("restore deterministic: Alpha commands first",
      lastAlphaIndex != nil && firstZetaIndex != nil && lastAlphaIndex! < firstZetaIndex!)
check("restore deterministic: every service present",
      orderedRestore.contains { $0.count > 1 && $0[1] == "Alpha" }
      && orderedRestore.contains { $0.count > 1 && $0[1] == "Zeta" })

// Filtering to still-existing services must keep a disabled service (the `*`
// prefix from -listallnetworkservices is cosmetic) and drop a deleted one.
var filterState = ServiceProxyState()
filterState.webEnabled = true
filterState.webServer = "proxy.corp"
filterState.webPort = "3128"
let filterInput: SystemProxySnapshot = [
    "Wi-Fi": filterState,
    "USB 10/100/1000 LAN": filterState,
    "Deleted Dock": filterState,
]
let filtered = NetworksetupCommands.filterSnapshot(filterInput, toExisting: ["Wi-Fi", "*USB 10/100/1000 LAN"])
check("filter keeps existing service", filtered["Wi-Fi"] != nil)
check("filter keeps `*`-disabled service", filtered["USB 10/100/1000 LAN"] != nil)
check("filter drops deleted service", filtered["Deleted Dock"] == nil)
check("filter drops nothing else", filtered.count == 2)
check("filter empty when no service exists",
      NetworksetupCommands.filterSnapshot(filterInput, toExisting: []).isEmpty)

print("== ConfigStore load states (TC-02) ==")
let configFm = FileManager.default
let configTmp = configFm.temporaryDirectory
    .appendingPathComponent("pm-config-tests-\(UUID().uuidString)", isDirectory: true)
try? configFm.createDirectory(at: configTmp, withIntermediateDirectories: true)

// Isolation contract: PROXYMANAGER_SUPPORT_DIR redirects the default store so
// a harness run can never touch the real Application Support directory.
setenv("PROXYMANAGER_SUPPORT_DIR", configTmp.path, 1)
let isolatedStore = ConfigStore()
check("PROXYMANAGER_SUPPORT_DIR redirects the config path",
      isolatedStore.configURL.path.hasPrefix(configTmp.path + "/"))
check("missing config is created with defaults",
      configFm.fileExists(atPath: isolatedStore.configURL.path)
      && isolatedStore.config.targets.isEmpty)
check("missing config is not a failed load", isolatedStore.loadFailed == false)
let isolatedPerms = (try? configFm.attributesOfItem(atPath: isolatedStore.configURL.path))?[.posixPermissions] as? NSNumber
check("created config is owner-only", isolatedPerms?.intValue == 0o600)
unsetenv("PROXYMANAGER_SUPPORT_DIR")

// Corrupt file -> timestamped backup, then defaults.
let corruptDir = configTmp.appendingPathComponent("corrupt", isDirectory: true)
try? configFm.createDirectory(at: corruptDir, withIntermediateDirectories: true)
let corruptURL = corruptDir.appendingPathComponent("config.json")
let garbage = Data("not json {{{".utf8)
try? garbage.write(to: corruptURL)
let corruptStore = ConfigStore(configURL: corruptURL)
let corruptFiles = (try? configFm.contentsOfDirectory(atPath: corruptDir.path)) ?? []
let backups = corruptFiles.filter { $0.hasPrefix("config.json.corrupt-") }
check("corrupt config creates a timestamped backup", backups.count == 1)
let backupBytes = backups.first.flatMap {
    try? Data(contentsOf: corruptDir.appendingPathComponent($0))
}
check("corrupt backup preserves the original bytes", backupBytes == garbage)
check("corrupt config starts from defaults",
      corruptStore.config.targets.isEmpty && corruptStore.loadFailed == false)
let replaced = try? JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: corruptURL))
check("corrupt config is replaced by valid defaults", replaced != nil)

let garbage2 = Data("also not json".utf8)
try? garbage2.write(to: corruptURL)
_ = ConfigStore(configURL: corruptURL)
let afterSecond = (try? configFm.contentsOfDirectory(atPath: corruptDir.path)) ?? []
check("a newer corrupt backup never replaces an older one",
      afterSecond.filter { $0.hasPrefix("config.json.corrupt-") }.count == 2)

// Unreadable file -> keep it, use in-memory defaults, refuse to save.
let unreadableDir = configTmp.appendingPathComponent("unreadable", isDirectory: true)
try? configFm.createDirectory(at: unreadableDir, withIntermediateDirectories: true)
let unreadableURL = unreadableDir.appendingPathComponent("config.json")
let originalConfig = Data("{\"targets\":[{\"pattern\":\"keep.me\"}]}".utf8)
try? originalConfig.write(to: unreadableURL)
try? configFm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableURL.path)
let unreadableStore = ConfigStore(configURL: unreadableURL)
try? configFm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableURL.path)
let preserved = try? Data(contentsOf: unreadableURL)
check("unreadable config is not overwritten", preserved == originalConfig)
check("unreadable config sets loadFailed", unreadableStore.loadFailed)
check("unreadable config runs on in-memory defaults", unreadableStore.config.targets.isEmpty)
unreadableStore.save(AppConfig())
let afterSave = try? Data(contentsOf: unreadableURL)
check("save refuses to overwrite an unreadable config", afterSave == originalConfig)
unreadableStore.reset()
let afterReset = try? Data(contentsOf: unreadableURL)
check("reset clears the failed-load latch", unreadableStore.loadFailed == false)
check("reset explicitly saves defaults",
      afterReset != originalConfig
      && (try? JSONDecoder().decode(AppConfig.self, from: afterReset ?? Data())) != nil)

try? configFm.removeItem(at: configTmp)

print("")
if failures == 0 {
    print("PASS: \(checks) checks")
    exit(0)
} else {
    print("FAIL: \(failures)/\(checks) checks failed")
    exit(1)
}
