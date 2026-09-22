import Foundation

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
