import Foundation
import Darwin

// Standalone harness for the integration router (no XCTest / SPM).
//
//   xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
//     Sources/Config/ConfigModels.swift Sources/Config/Presets.swift \
//     Sources/Integration/*.swift Sources/Support/Log.swift \
//     Tests/IntegrationHarness/main.swift -o /tmp/integration && /tmp/integration
//
// Every assertion here is a contract the URL, App Intents and XPC adapters rely
// on. A failing check means one of them can be bypassed or misled.

setbuf(stdout, nil)

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

func checkEqual<T: Equatable>(_ name: String, _ lhs: T, _ rhs: T) {
    checks += 1
    if lhs == rhs {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name) — \(lhs) != \(rhs)")
    }
}

// MARK: - Fake host

final class FakeHost: IntegrationHost {
    var state = "off"
    var intended = false
    var tunnelUp = true
    var targets: [IntegrationTarget] = []
    var appsEnabled = false
    var appsDefault: AppRoutingMode = .targets
    var appRules: [IntegrationAppRule] = []
    var activated = 0
    var lastPane: (pane: String, section: String?, revealPattern: String?)?

    func integrationSnapshot() -> IntegrationSnapshot {
        IntegrationSnapshot(
            state: state,
            routingIntended: intended,
            tunnelUp: tunnelUp,
            bindHost: "127.0.0.1",
            port: 8888,
            lastError: nil,
            onboardingComplete: true,
            authorizationDeferred: false,
            targets: targets,
            appsEnabled: appsEnabled,
            appsDefaultMode: appsDefault,
            appsRecordInTelemetry: true,
            appRules: appRules
        )
    }

    func setRoutingIntent(_ enabled: Bool) {
        intended = enabled
        state = enabled ? "on" : "off"
    }

    func toggleRoutingIntent() {
        if state == "on" || state == "degraded" { setRoutingIntent(false) }
        else if state == "off" { setRoutingIntent(true) }
    }

    func retryRoutingIntent() {
        state = intended ? "on" : "off"
    }

    func addTarget(pattern: String, enabled: Bool) -> (id: UUID, added: Bool) {
        if let existing = targets.first(where: { $0.pattern == pattern }) {
            return (existing.id, false)
        }
        let target = IntegrationTarget(id: UUID(), pattern: pattern, enabled: enabled)
        targets.append(target)
        return (target.id, true)
    }

    func removeTargetRule(id: UUID) -> Bool {
        let before = targets.count
        targets.removeAll { $0.id == id }
        return targets.count != before
    }

    func removeTargetRule(pattern: String) -> Bool {
        let before = targets.count
        targets.removeAll { $0.pattern == pattern }
        return targets.count != before
    }

    func updateTargetRule(id: UUID, pattern: String?, enabled: Bool?) -> Bool {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return false }
        let old = targets[index]
        targets[index] = IntegrationTarget(
            id: old.id,
            pattern: pattern ?? old.pattern,
            enabled: enabled ?? old.enabled
        )
        return true
    }

    func clearTargetRules() {
        targets.removeAll()
    }

    func applyTargetPreset(idOrName: String) -> Int? {
        guard let preset = TargetPreset.all.first(where: {
            $0.id == idOrName || $0.name.caseInsensitiveCompare(idOrName) == .orderedSame
        }) else { return nil }
        var added = 0
        for rule in preset.rules {
            let key = rule.pattern.lowercased()
            guard !targets.contains(where: { $0.pattern == key }) else { continue }
            targets.append(IntegrationTarget(id: UUID(), pattern: key, enabled: true))
            added += 1
        }
        return added
    }

    func setAppsEnabled(_ enabled: Bool) {
        appsEnabled = enabled
    }

    func setAppsDefaultMode(_ mode: AppRoutingMode) {
        appsDefault = mode
    }

    func setAppRule(key: String, kind: AppRuleKeyKind,
                       mode: AppRoutingMode, enabled: Bool) -> UUID {
        if let index = appRules.firstIndex(where: { $0.key == key && $0.keyKind == kind }) {
            let old = appRules[index]
            appRules[index] = IntegrationAppRule(id: old.id, key: key, keyKind: kind,
                                                 mode: mode, enabled: enabled)
            return old.id
        }
        let rule = IntegrationAppRule(id: UUID(), key: key, keyKind: kind,
                                      mode: mode, enabled: enabled)
        appRules.append(rule)
        return rule.id
    }

    func deleteAppRule(id: UUID) -> Bool {
        let before = appRules.count
        appRules.removeAll { $0.id == id }
        return appRules.count != before
    }

    func deleteAppRule(key: String, kind: AppRuleKeyKind) -> Bool {
        let before = appRules.count
        appRules.removeAll { $0.key == key && $0.keyKind == kind }
        return appRules.count != before
    }

    func explain(host: String, bundleID: String?) -> IntegrationExplanation {
        let normalized = host.lowercased()
        if let match = targets.first(where: { target in
            target.pattern == normalized
                || (target.pattern.hasPrefix("*.")
                    && (normalized == String(target.pattern.dropFirst(2))
                        || normalized.hasSuffix(String(target.pattern.dropFirst(1)))))
        }) {
            return IntegrationExplanation(host: normalized, decision: "tunnel",
                                          matchedPattern: match.pattern,
                                          matchedTargetID: match.id,
                                          appMode: nil, appRuleKey: nil)
        }
        return IntegrationExplanation(host: normalized, decision: "direct",
                                      matchedPattern: nil, matchedTargetID: nil,
                                      appMode: nil, appRuleKey: nil)
    }

    func resolveApp(bundleID: String?, path: String?, pid: Int32?) -> IntegrationAppResolution? {
        guard bundleID == "com.example.app" else { return nil }
        return IntegrationAppResolution(bundleID: bundleID, executablePath: "/tmp/Example.app",
                                        displayName: "Example", mode: .tunnel, ruleID: nil)
    }

    func openPane(_ pane: String, section: String?,
                  revealPattern: String?, revealAppRuleID: UUID?) {
        lastPane = (pane, section, revealPattern)
    }

    func activateApp() {
        activated += 1
    }
}

// MARK: - Helpers

let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

func makeRouter(_ host: FakeHost, audit: IntegrationAudit? = nil,
                limiter: IntegrationRateLimiter = IntegrationRateLimiter()) -> IntegrationRouter {
    IntegrationRouter(host: host, audit: audit, limiter: limiter, now: { fixedDate })
}

func connectControl(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    ControlSocket.setNoSigPipe(fd)
    guard ControlSocket.connect(fd, path: path) else {
        close(fd)
        return nil
    }
    return fd
}

func args(_ pairs: [String: IntegrationValue]) -> [String: IntegrationValue] { pairs }

func perform(_ router: IntegrationRouter, _ action: String,
             _ pairs: [String: IntegrationValue] = [:],
             source: IntegrationSource = .test) -> IntegrationResult {
    router.perform(action: action, args: pairs, source: source)
}

// MARK: - Registry

print("== Registry ==")
check("23 actions", IntegrationActions.all.count == 23)
check("unique ids", Set(IntegrationActions.all.map(\.id)).count == IntegrationActions.all.count)
check("byID covers all", IntegrationActions.byID.count == IntegrationActions.all.count)
check("every url-exposed action is deliberate",
      IntegrationActions.all.filter(\.urlExposed).map(\.id).sorted() == [
        "app.activate", "routing.disable", "routing.enable",
        "routing.retry", "routing.toggle", "ui.open",
      ])
check("no admin-risk action", IntegrationActions.all.allSatisfy { $0.risk != .policy || $0.risk.requiredScope == .control })
check("every action has a summary", IntegrationActions.all.allSatisfy { !$0.summary.isEmpty })

// MARK: - Authorization

print("== Authorization ==")
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let result = perform(router, "targets.add", ["pattern": .string("x.com")],
                         source: .urlScheme(senderPID: nil))
    checkEqual("URL cannot add targets", result.error?.code, .forbidden)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let result = perform(router, "routing.enable",
                         source: .xpc(pid: 1, bundleID: "com.x", teamID: nil, scope: .read))
    checkEqual("read scope cannot enable routing", result.error?.code, .unauthorized)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let result = perform(router, "routing.enable",
                         source: .xpc(pid: 1, bundleID: "com.x", teamID: nil, scope: .control))
    check("control scope can enable routing", result.ok)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let result = perform(router, "status", source: .urlScheme(senderPID: nil))
    checkEqual("URL cannot read status", result.error?.code, .forbidden)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let result = perform(router, "ui.open", ["pane": .string("settings")],
                         source: .urlScheme(senderPID: nil))
    check("URL can open a pane", result.ok)
}

// MARK: - Routing

print("== Routing ==")
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let first = perform(router, "routing.enable")
    check("enable starts routing", first.ok && first.changed)
    let second = perform(router, "routing.enable")
    check("enable is idempotent", second.ok && !second.changed)
    let off = perform(router, "routing.disable")
    check("disable changes state", off.ok && off.changed)
    let offAgain = perform(router, "routing.disable")
    check("disable is idempotent", offAgain.ok && !offAgain.changed)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let result = perform(router, "routing.toggle")
    checkEqual("toggle reports the new state", result.data["state"], .string("on"))
}

// MARK: - Targets

print("== Targets ==")
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let added = perform(router, "targets.add", ["pattern": .string("API.Example.com:443")])
    check("add normalizes host and strips port",
          added.ok && added.data["pattern"] == .string("api.example.com"))
    let again = perform(router, "targets.add", ["pattern": .string("api.example.com")])
    check("add dedupes case-insensitively", again.ok && !again.changed)
    check("one rule on disk", host.targets.count == 1)

    let listed = perform(router, "targets.list")
    check("list returns the rule", listed.data["count"] == .int(1))
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    for bad in ["*", "bad host", "a/b", "exa mple.com", ""] {
        let result = perform(router, "targets.add", ["pattern": .string(bad)])
        check("rejects pattern '\(bad)'", result.error?.code == .invalidArgument)
    }
    check("wildcard accepted",
          perform(router, "targets.add", ["pattern": .string("*.Example.com")]).ok)
    check("invalid wildcard rejected",
          perform(router, "targets.add", ["pattern": .string("a*b.com")]).error?.code == .invalidArgument)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let added = perform(router, "targets.add", ["pattern": .string("example.com")])
    let id = added.data["id"]!.stringValue!
    let removed = perform(router, "targets.remove", ["id": .string(id)])
    check("remove by id", removed.ok && removed.changed)
    checkEqual("remove by id is not idempotent-success",
               perform(router, "targets.remove", ["id": .string(id)]).error?.code, .notFound)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let none = perform(router, "targets.remove", [:])
    checkEqual("remove needs a selector", none.error?.code, .invalidArgument)
    let both = perform(router, "targets.remove",
                       ["id": .string(UUID().uuidString), "pattern": .string("x.com")])
    checkEqual("remove rejects both selectors", both.error?.code, .invalidArgument)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    checkEqual("clear needs confirm",
               perform(router, "targets.clear").error?.code, .invalidArgument)
    checkEqual("clear needs confirm=true",
               perform(router, "targets.clear", ["confirm": .bool(false)]).error?.code,
               .invalidArgument)
    check("clear with confirm", perform(router, "targets.clear", ["confirm": .bool(true)]).ok)
}
do {
    let host = FakeHost()
    host.targets = (0..<500).map {
        IntegrationTarget(id: UUID(), pattern: "host\($0).example.com", enabled: true)
    }
    let router = makeRouter(host)
    let result = perform(router, "targets.add", ["pattern": .string("one-more.example.com")])
    checkEqual("500-rule cap", result.error?.code, .conflict)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let id = perform(router, "targets.add", ["pattern": .string("example.com")])
        .data["id"]!.stringValue!
    let noop = perform(router, "targets.update",
                       ["id": .string(id), "enabled": .bool(true)])
    check("update to the same value is not a change", noop.ok && !noop.changed)
    let toggle = perform(router, "targets.update",
                         ["id": .string(id), "enabled": .bool(false)])
    check("update changes enabled", toggle.ok && toggle.changed)
    checkEqual("update requires a field",
               perform(router, "targets.update", ["id": .string(id)]).error?.code,
               .invalidArgument)
}

// MARK: - Presets

print("== Presets ==")
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let listed = perform(router, "presets.list")
    check("presets are listed", (listed.data["presets"]?.arrayValue?.count ?? 0) == TargetPreset.all.count)
    let applied = perform(router, "presets.apply", ["name": .string("openai")])
    check("preset applies", applied.ok && (applied.data["added"]?.intValue ?? 0) > 0)
    let again = perform(router, "presets.apply", ["name": .string("openai")])
    check("preset apply is idempotent", again.ok && !again.changed)
    checkEqual("unknown preset", perform(router, "presets.apply", ["name": .string("nope")]).error?.code,
               .notFound)
}

// MARK: - Apps

print("== Apps ==")
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let set = perform(router, "apps.rule.set", [
        "key": .string("com.example.app"),
        "keyKind": .string("BUNDLE"),
        "mode": .string("TUNNEL"),
    ])
    check("app rule is created", set.ok && set.changed)
    let again = perform(router, "apps.rule.set", [
        "key": .string("com.example.app"),
        "keyKind": .string("BUNDLE"),
        "mode": .string("TUNNEL"),
    ])
    check("app rule upsert is idempotent", again.ok && !again.changed)
    check("app rule does not enable per-app routing", !host.appsEnabled)

    let badBundle = perform(router, "apps.rule.set", [
        "key": .string("not a bundle"),
        "keyKind": .string("BUNDLE"),
        "mode": .string("TUNNEL"),
    ])
    checkEqual("invalid bundle id", badBundle.error?.code, .invalidArgument)
    checkEqual("bad mode", perform(router, "apps.rule.set", [
        "key": .string("com.example.app"),
        "keyKind": .string("BUNDLE"),
        "mode": .string("SIDEWAYS"),
    ]).error?.code, .invalidArgument)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let id = perform(router, "apps.rule.set", [
        "key": .string("com.example.app"), "keyKind": .string("BUNDLE"),
        "mode": .string("DIRECT"),
    ]).data["id"]!.stringValue!
    check("remove app rule", perform(router, "apps.rule.remove", ["id": .string(id)]).ok)
    checkEqual("remove missing app rule",
               perform(router, "apps.rule.remove", ["id": .string(id)]).error?.code, .notFound)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    checkEqual("resolve needs one selector",
               perform(router, "apps.resolve", [:]).error?.code, .invalidArgument)
    checkEqual("resolve rejects two selectors", perform(router, "apps.resolve", [
        "bundleID": .string("com.example.app"), "pid": .int(1),
    ]).error?.code, .invalidArgument)
    let resolved = perform(router, "apps.resolve", ["bundleID": .string("com.example.app")])
    check("resolve returns a mode", resolved.ok && resolved.data["mode"] == .string("TUNNEL"))
    checkEqual("resolve unknown app",
               perform(router, "apps.resolve", ["bundleID": .string("com.other.app")]).error?.code,
               .notFound)
}

// MARK: - Explain / UI

print("== Explain / UI ==")
do {
    let host = FakeHost()
    let router = makeRouter(host)
    _ = perform(router, "targets.add", ["pattern": .string("*.example.com")])
    let match = perform(router, "routing.explain", ["host": .string("api.example.com")])
    check("explain finds the wildcard", match.data["decision"] == .string("tunnel"))
    let direct = perform(router, "routing.explain", ["host": .string("other.com")])
    check("explain falls back to direct", direct.data["decision"] == .string("direct"))
    checkEqual("explain rejects a bad host",
               perform(router, "routing.explain", ["host": .string("bad host")]).error?.code,
               .invalidArgument)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    check("open settings section", perform(router, "ui.open", [
        "pane": .string("settings"), "section": .string("targets"),
    ]).ok)
    checkEqual("section needs settings", perform(router, "ui.open", [
        "pane": .string("dashboard"), "section": .string("targets"),
    ]).error?.code, .invalidArgument)
    check("activate", perform(router, "app.activate").ok && host.activated == 1)
}

// MARK: - Validation

print("== Validation ==")
do {
    let host = FakeHost()
    let router = makeRouter(host)
    checkEqual("unknown action", perform(router, "nope").error?.code, .unknownAction)
    checkEqual("unknown argument",
               perform(router, "targets.add", ["pattern": .string("x.com"), "typo": .int(1)]).error?.code,
               .invalidArgument)
    checkEqual("missing required argument",
               perform(router, "targets.add", [:]).error?.code, .invalidArgument)
    checkEqual("wrong type",
               perform(router, "apps.setEnabled", ["enabled": .string("yes")]).error?.code,
               .invalidArgument)
    checkEqual("bad enum",
               perform(router, "apps.setDefault", ["mode": .string("NOPE")]).error?.code,
               .invalidArgument)
    checkEqual("bad uuid",
               perform(router, "targets.update", ["id": .string("nope")]).error?.code,
               .invalidArgument)
}
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let request = IntegrationRequest(action: "status", v: IntegrationProtocol.version + 1)
    checkEqual("newer protocol is refused",
               router.perform(request, source: .test).error?.code, .unsupported)
}
do {
    // The URL transport coerces strings; XPC does not.
    let host = FakeHost()
    let router = makeRouter(host)
    let url = perform(router, "targets.list", ["enabledOnly": .string("true")],
                      source: .urlScheme(senderPID: nil))
    checkEqual("URL cannot call targets.list", url.error?.code, .forbidden)
    let coerced = perform(router, "ui.open", ["pane": .string("settings"),
                                              "revealPattern": .string("API.example.com")],
                          source: .urlScheme(senderPID: nil))
    check("URL coercion normalizes the reveal pattern", coerced.ok)
    checkEqual("host.lastPane", host.lastPane?.revealPattern, "api.example.com")
}

// MARK: - Rate limits

print("== Rate limits ==")
do {
    let host = FakeHost()
    let router = makeRouter(host)
    var results: [IntegrationResult] = []
    for _ in 0..<4 { results.append(perform(router, "routing.toggle")) }
    check("first three toggles allowed", results.prefix(3).allSatisfy(\.ok))
    checkEqual("fourth toggle is busy", results[3].error?.code, .busy)
}

// MARK: - Audit

print("== Audit ==")
do {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("integration-audit-\(UUID().uuidString)")
    let audit = IntegrationAudit(directory: directory)
    let host = FakeHost()
    let router = IntegrationRouter(host: host, audit: audit, now: { fixedDate })
    let result = perform(router, "targets.add", ["pattern": .string("api.example.com")])
    check("request succeeded", result.ok)
    audit.flush()
    let entries = audit.readAll()
    checkEqual("one audit entry", entries.count, 1)
    checkEqual("entry action", entries.first?.action, "targets.add")
    check("entry recorded the caller", entries.first?.source.kind == "test")
    check("entry recorded the outcome", entries.first?.ok == true)

    let redacted = IntegrationAudit.redact([
        "password": .string("hunter2"),
        "token": .string("abc"),
        "nested": .object(["secret": .string("x"), "keep": .string("y")]),
    ])
    checkEqual("password is redacted", redacted["password"], .string("***"))
    checkEqual("token is redacted", redacted["token"], .string("***"))
    checkEqual("nested secret is redacted",
               redacted["nested"]?.objectValue?["secret"], .string("***"))
    checkEqual("nested non-secret survives",
               redacted["nested"]?.objectValue?["keep"], .string("y"))
    try? FileManager.default.removeItem(at: directory)
}

// MARK: - Capabilities

print("== Capabilities ==")
do {
    let host = FakeHost()
    let router = makeRouter(host)
    let caps = perform(router, "capabilities")
    check("capabilities ok", caps.ok)
    checkEqual("capabilities lists every action",
               caps.data["actions"]?.arrayValue?.count, IntegrationActions.all.count)
    check("capabilities declares the protocol version",
          caps.data["protocolVersion"] == .int(IntegrationProtocol.version))
}

// MARK: - Permissions

print("== Permissions ==")
do {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("integration-permissions-\(UUID().uuidString)")
    let file = directory.appendingPathComponent("permissions.json")
    let store = IntegrationPermissionStore(fileURL: file)
    let identity = ControlIdentity(
        pid: 42, bundleID: "com.example.app", teamID: "TEAM123",
        requirement: "identifier \"com.example.app\" and anchor apple generic",
        displayName: "Example", path: "/Applications/Example.app"
    )

    check("unknown identity has no scope", store.scope(for: identity) == nil)
    store.grant(identity, scope: .control)
    checkEqual("grant is remembered", store.scope(for: identity), .control)
    checkEqual("grant survives a reload", IntegrationPermissionStore(fileURL: file).scope(for: identity), .control)
    checkEqual("store lists one identity", store.all().count, 1)

    var impostor = identity
    impostor.requirement = "identifier \"com.example.app\" and cdhash H\"deadbeef\""
    check("a different requirement is a different identity", store.scope(for: impostor) == nil)

    store.revoke(key: store.all()[0].key)
    check("revoke removes the grant", store.scope(for: identity) == nil)
    try? FileManager.default.removeItem(at: directory)
}

// MARK: - Framing

print("== Framing ==")
do {
    var fds: [Int32] = [-1, -1]
    check("socketpair", socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    let payload = Data("hello".utf8)
    try ControlFraming.writeFrame(fds[0], payload)
    let read = try ControlFraming.readFrame(fds[1])
    checkEqual("frame round-trips", read, payload)
    close(fds[0])
    close(fds[1])
}
do {
    var fds: [Int32] = [-1, -1]
    _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    let tooBig = UInt32(ControlFraming.maxFrameBytes + 1).bigEndian
    var header = withUnsafeBytes(of: tooBig) { Data($0) }
    header.append(Data(repeating: 0, count: 1))
    header.withUnsafeBytes { _ = Darwin.write(fds[0], $0.baseAddress, header.count) }
    var threw = false
    do { _ = try ControlFraming.readFrame(fds[1], timeoutMs: 500) }
    catch ControlTransportError.frameTooLarge { threw = true }
    catch { }
    check("oversized frame is rejected", threw)
    close(fds[0])
    close(fds[1])
}

// MARK: - Control socket

print("== Control socket ==")
do {
    // `sun_path` is 104 bytes on macOS, and the system temp directory is
    // already long; keep the socket path short.
    let directory = URL(fileURLWithPath: "/tmp/pmint-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socketPath = directory.appendingPathComponent("control.sock").path
    let tokenPath = directory.appendingPathComponent("control.token").path
    let host = FakeHost()
    let router = IntegrationRouter(host: host)
    let server = ControlSocketServer(socketPath: socketPath, tokenPath: tokenPath) { identity, request in
        router.perform(request, source: .xpc(
            pid: identity.pid, bundleID: identity.bundleID,
            teamID: identity.teamID, scope: .control
        ))
    }
    check("server starts", server.start())

    let token = (try? String(contentsOfFile: tokenPath, encoding: .utf8)) ?? ""
    check("token file has a token", token.count == 64)

    let attributes = try? FileManager.default.attributesOfItem(atPath: socketPath)
    check("socket is 0600",
          (attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    let identity = ControlIdentity(pid: 7, bundleID: "com.example.app", teamID: "TEAM123",
                                   requirement: "identifier \"com.example.app\"",
                                   displayName: "Example", path: "/Applications/Example.app")

    func roundTrip(token: String, action: String,
                   args: [String: IntegrationValue] = [:]) -> Result<IntegrationResult, Error> {
        guard let fd = connectControl(socketPath) else {
            return .failure(ControlTransportError.closed)
        }
        defer { close(fd) }
        do {
            let envelope = ControlRequest(
                token: token, identity: identity,
                request: IntegrationRequest(action: action, args: args)
            )
            try ControlFraming.writeFrame(fd, ControlFraming.encode(envelope))
            let reply = try ControlFraming.decode(
                ControlResponse.self, from: ControlFraming.readFrame(fd)
            )
            return .success(reply.result)
        } catch {
            return .failure(error)
        }
    }

    func runOffMain(_ work: @escaping () -> Void, seconds: TimeInterval = 5) {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            work()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(seconds)
        while done.wait(timeout: .now() + 0.05) == .timedOut, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    var outcome: Result<IntegrationResult, Error>?
    runOffMain { outcome = roundTrip(token: token, action: "routing.enable") }
    switch outcome {
    case .success(let result):
        check("request over the socket succeeds", result.ok)
        checkEqual("routing is on", host.state, "on")
    default:
        check("request over the socket succeeds", false)
    }

    var status: IntegrationResult?
    runOffMain {
        if case .success(let result) = roundTrip(token: token, action: "status") {
            status = result
        }
    }
    check("status over the socket", status?.ok == true)
    checkEqual("status reports the state", status?.data["state"], .string("on"))

    var denied: Result<IntegrationResult, Error>?
    runOffMain { denied = roundTrip(token: "not-the-token", action: "status") }
    if case .success = denied {
        check("wrong token is rejected", false)
    } else {
        check("wrong token is rejected", true)
    }

    server.stop()
    check("server stops", !server.isRunning)
    try? FileManager.default.removeItem(at: directory)
}

// MARK: - Result

print("")
if failures == 0 {
    print("PASS — \(checks) checks")
    exit(0)
} else {
    print("FAIL — \(failures)/\(checks) checks failed")
    exit(1)
}
