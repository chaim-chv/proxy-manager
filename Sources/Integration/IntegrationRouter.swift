import Foundation

/// The single entry point for every external request.
///
/// Adapters parse their transport, build an `IntegrationRequest`, and call
/// `perform`. Everything else — authorization, rate limiting, validation,
/// execution and auditing — happens here, so a new adapter cannot bypass a
/// rule that another adapter enforces.
///
/// `perform` is synchronous and main-thread-only: the app's state is main-thread
/// state, and adapters hop to the main queue before calling. Keeping the router
/// free of its own async machinery removes a whole class of ordering bugs.
final class IntegrationRouter {
    private struct Outcome {
        var data: [String: IntegrationValue]
        var changed: Bool
    }

    private let host: IntegrationHost
    private let audit: IntegrationAudit?
    private let limiter: IntegrationRateLimiter
    private let now: () -> Date

    init(host: IntegrationHost,
         audit: IntegrationAudit? = nil,
         limiter: IntegrationRateLimiter = IntegrationRateLimiter(),
         now: @escaping () -> Date = Date.init) {
        self.host = host
        self.audit = audit
        self.limiter = limiter
        self.now = now
    }

    // MARK: - Entry point

    func perform(_ request: IntegrationRequest,
                 source: IntegrationSource) -> IntegrationResult {
        assert(Thread.isMainThread, "IntegrationRouter.perform must run on the main thread")

        let start = now()
        let auditId = UUID().uuidString
        var validated: [String: IntegrationValue] = [:]
        var changed = false
        var data: [String: IntegrationValue] = [:]
        var failure: IntegrationError?

        do {
            guard request.v <= IntegrationProtocol.version else {
                throw IntegrationError(.unsupported,
                                       "protocol version \(request.v) is newer than \(IntegrationProtocol.version)")
            }
            guard let spec = IntegrationActions.byID[request.action] else {
                throw IntegrationError(.unknownAction,
                                       "unknown action '\(request.action)'")
            }
            try authorize(spec, source: source)

            let snapshot = host.integrationSnapshot()
            validated = try IntegrationValidator.validate(
                request: request, spec: spec, snapshot: snapshot,
                coerce: source.kind == "url"
            )

            // Rate limit after validation: a client fixing a typo must not burn
            // its mutation budget, and invalid input is already rejected cheaply.
            let bucket = spec.risk == .read
                ? IntegrationRateLimiter.read
                : IntegrationRateLimiter.mutation
            guard limiter.allow("\(source.identityKey)#readwrite", bucket: bucket, now: start) else {
                throw IntegrationError(.busy, "too many requests; retry shortly")
            }
            if spec.id == "routing.toggle" {
                guard limiter.allow("\(source.identityKey)#toggle",
                                    bucket: IntegrationRateLimiter.routingToggle, now: start) else {
                    throw IntegrationError(.busy, "routing.toggle is rate limited; retry shortly")
                }
            }

            let outcome = try execute(spec: spec, args: validated, snapshot: snapshot)
            data = outcome.data
            changed = outcome.changed
        } catch let error as IntegrationError {
            failure = error
        } catch {
            failure = IntegrationError(.internalError, error.localizedDescription)
        }

        let durationMs = Int(now().timeIntervalSince(start) * 1000)
        let result = IntegrationResult(
            id: request.id,
            action: request.action,
            ok: failure == nil,
            changed: changed,
            data: data,
            error: failure,
            auditId: auditId,
            durationMs: durationMs
        )

        audit?.record(IntegrationAuditEntry(
            id: request.id,
            auditId: auditId,
            source: source.auditSource,
            action: request.action,
            args: IntegrationAudit.redact(validated.isEmpty ? request.args : validated),
            ok: result.ok,
            changed: changed,
            errorCode: failure?.code.rawValue,
            durationMs: durationMs
        ))

        if result.ok {
            Log.integration.debug("\(request.action, privacy: .public) ok changed=\(changed)")
        } else {
            Log.integration.notice("\(request.action, privacy: .public) failed \(failure?.code.rawValue ?? "?", privacy: .public): \(failure?.message ?? "", privacy: .public)")
        }
        return result
    }

    func perform(action: String,
                 args: [String: IntegrationValue] = [:],
                 source: IntegrationSource) -> IntegrationResult {
        perform(IntegrationRequest(action: action, args: args), source: source)
    }

    // MARK: - Authorization

    private func authorize(_ spec: IntegrationActionSpec,
                           source: IntegrationSource) throws {
        switch source {
        case .urlScheme:
            // A URL is unauthenticated: only the curated, reversible subset is
            // reachable, regardless of the caller's claimed identity.
            guard spec.urlExposed else {
                throw IntegrationError(.forbidden,
                                       "\(spec.id) is not available through the URL scheme")
            }
        case .appIntent:
            guard spec.intentExposed else {
                throw IntegrationError(.forbidden,
                                       "\(spec.id) is not available as a Shortcut action")
            }
        case .xpc(_, _, _, let scope):
            guard spec.risk.requiredScope.rank <= scope.rank else {
                throw IntegrationError(.unauthorized,
                                       "\(spec.id) needs the \(spec.risk.requiredScope.rawValue) scope")
            }
        case .commandLine, .test:
            break
        }
    }

    // MARK: - Execution

    private func execute(spec: IntegrationActionSpec,
                         args: [String: IntegrationValue],
                         snapshot: IntegrationSnapshot) throws -> Outcome {
        switch spec.id {
        case "ping":
            return Outcome(data: [
                "protocolVersion": .int(IntegrationProtocol.version),
                "appVersion": .string(appVersion),
                "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            ], changed: false)

        case "capabilities":
            return Outcome(data: [
                "protocolVersion": .int(IntegrationProtocol.version),
                "actions": .array(capabilities()),
            ], changed: false)

        case "status":
            return Outcome(data: statusData(snapshot), changed: false)

        case "routing.enable":
            let alreadyOn = snapshot.isOn && snapshot.routingIntended
            if !alreadyOn { host.setRoutingEnabled(true) }
            let after = host.integrationSnapshot()
            return Outcome(data: ["state": .string(after.state)], changed: !alreadyOn)

        case "routing.disable":
            let alreadyOff = !snapshot.routingIntended && snapshot.state == "off"
            if !alreadyOff { host.setRoutingEnabled(false) }
            let after = host.integrationSnapshot()
            return Outcome(data: ["state": .string(after.state)], changed: !alreadyOff)

        case "routing.toggle":
            let before = snapshot.state
            host.toggleRouting()
            let after = host.integrationSnapshot().state
            return Outcome(data: ["state": .string(after)], changed: before != after)

        case "routing.retry":
            host.retryRouting()
            let after = host.integrationSnapshot()
            return Outcome(data: ["state": .string(after.state)], changed: true)

        case "routing.explain":
            let hostName = args["host"]!.stringValue!
            let bundleID = args["bundleID"]?.stringValue
            let explanation = host.explain(host: hostName, bundleID: bundleID)
            return Outcome(data: [
                "host": .string(explanation.host),
                "decision": .string(explanation.decision),
                "matchedPattern": explanation.matchedPattern.map(IntegrationValue.string) ?? .null,
                "matchedTargetID": explanation.matchedTargetID.map { .string($0.uuidString) } ?? .null,
                "appMode": explanation.appMode.map(IntegrationValue.string) ?? .null,
                "appRuleKey": explanation.appRuleKey.map(IntegrationValue.string) ?? .null,
            ], changed: false)

        case "targets.list":
            let enabledOnly = args["enabledOnly"]?.boolValue ?? false
            let rules = snapshot.targets
                .filter { !enabledOnly || $0.enabled }
                .map(targetValue)
            return Outcome(data: [
                "targets": .array(rules),
                "count": .int(rules.count),
            ], changed: false)

        case "targets.add":
            let pattern = args["pattern"]!.stringValue!
            let enabled = args["enabled"]?.boolValue ?? true
            if let existing = snapshot.targets.first(where: { $0.pattern == pattern }) {
                if existing.enabled == enabled {
                    return Outcome(data: [
                        "id": .string(existing.id.uuidString),
                        "pattern": .string(existing.pattern),
                    ], changed: false)
                }
                _ = host.updateTarget(id: existing.id, pattern: nil, enabled: enabled)
                return Outcome(data: [
                    "id": .string(existing.id.uuidString),
                    "pattern": .string(existing.pattern),
                ], changed: true)
            }
            let added = host.addTarget(pattern: pattern, enabled: enabled)
            return Outcome(data: [
                "id": .string(added.id.uuidString),
                "pattern": .string(pattern),
            ], changed: added.added)

        case "targets.remove":
            if let raw = args["id"]?.stringValue, let id = UUID(uuidString: raw) {
                guard host.removeTarget(id: id) else {
                    throw IntegrationError(.notFound, "no target with id \(raw)", field: "id")
                }
                return Outcome(data: ["removed": .int(1)], changed: true)
            }
            let pattern = args["pattern"]!.stringValue!
            guard host.removeTarget(pattern: pattern) else {
                throw IntegrationError(.notFound, "no target matching \(pattern)", field: "pattern")
            }
            return Outcome(data: ["removed": .int(1)], changed: true)

        case "targets.update":
            let raw = args["id"]!.stringValue!
            guard let id = UUID(uuidString: raw),
                  let existing = snapshot.targets.first(where: { $0.id == id }) else {
                throw IntegrationError(.notFound, "no target with id \(raw)", field: "id")
            }
            let pattern = args["pattern"]?.stringValue
            let enabled = args["enabled"]?.boolValue
            let changed = (pattern != nil && pattern != existing.pattern)
                || (enabled != nil && enabled != existing.enabled)
            if changed {
                guard host.updateTarget(id: id, pattern: pattern, enabled: enabled) else {
                    throw IntegrationError(.notFound, "no target with id \(raw)", field: "id")
                }
            }
            return Outcome(data: [
                "id": .string(id.uuidString),
                "pattern": .string(pattern ?? existing.pattern),
                "enabled": .bool(enabled ?? existing.enabled),
            ], changed: changed)

        case "targets.clear":
            guard !snapshot.targets.isEmpty else {
                return Outcome(data: ["removed": .int(0)], changed: false)
            }
            host.clearTargets()
            return Outcome(data: ["removed": .int(snapshot.targets.count)], changed: true)

        case "presets.list":
            return Outcome(data: [
                "presets": .array(TargetPreset.all.map { preset in
                    .object([
                        "id": .string(preset.id),
                        "name": .string(preset.name),
                        "summary": .string(preset.summary),
                        "count": .int(preset.rules.count),
                    ])
                }),
            ], changed: false)

        case "presets.apply":
            let name = args["name"]!.stringValue!
            guard let added = host.applyPreset(idOrName: name) else {
                throw IntegrationError(.notFound, "no preset named '\(name)'", field: "name")
            }
            return Outcome(data: ["added": .int(added)], changed: added > 0)

        case "apps.list":
            return Outcome(data: [
                "enabled": .bool(snapshot.appsEnabled),
                "defaultMode": .string(snapshot.appsDefaultMode.rawValue),
                "recordInTelemetry": .bool(snapshot.appsRecordInTelemetry),
                "rules": .array(snapshot.appRules.map(appRuleValue)),
            ], changed: false)

        case "apps.setEnabled":
            let enabled = args["enabled"]!.boolValue!
            let changed = enabled != snapshot.appsEnabled
            if changed { host.setAppsEnabled(enabled) }
            return Outcome(data: ["enabled": .bool(enabled)], changed: changed)

        case "apps.setDefault":
            let raw = args["mode"]!.stringValue!
            let mode = AppRoutingMode(rawValue: raw)!
            let changed = mode != snapshot.appsDefaultMode
            if changed { host.setAppsDefaultMode(mode) }
            return Outcome(data: ["defaultMode": .string(mode.rawValue)], changed: changed)

        case "apps.rule.set":
            let key = args["key"]!.stringValue!
            let kind = AppRuleKeyKind(rawValue: args["keyKind"]!.stringValue!)!
            let mode = AppRoutingMode(rawValue: args["mode"]!.stringValue!)!
            let enabled = args["enabled"]?.boolValue ?? true
            if let existing = snapshot.appRules.first(where: {
                $0.key == key && $0.keyKind == kind
            }) {
                if existing.mode == mode && existing.enabled == enabled {
                    return Outcome(data: ["id": .string(existing.id.uuidString)], changed: false)
                }
                _ = host.upsertAppRule(key: key, kind: kind, mode: mode, enabled: enabled)
                return Outcome(data: ["id": .string(existing.id.uuidString)], changed: true)
            }
            let id = host.upsertAppRule(key: key, kind: kind, mode: mode, enabled: enabled)
            return Outcome(data: ["id": .string(id.uuidString)], changed: true)

        case "apps.rule.remove":
            if let raw = args["id"]?.stringValue, let id = UUID(uuidString: raw) {
                guard host.removeAppRule(id: id) else {
                    throw IntegrationError(.notFound, "no app rule with id \(raw)", field: "id")
                }
                return Outcome(data: ["removed": .int(1)], changed: true)
            }
            let key = args["key"]!.stringValue!
            let kind = AppRuleKeyKind(rawValue: args["keyKind"]!.stringValue!)!
            guard host.removeAppRule(key: key, kind: kind) else {
                throw IntegrationError(.notFound, "no app rule for \(key)", field: "key")
            }
            return Outcome(data: ["removed": .int(1)], changed: true)

        case "apps.resolve":
            let resolution = host.resolveApp(
                bundleID: args["bundleID"]?.stringValue,
                path: args["path"]?.stringValue,
                pid: args["pid"]?.intValue.map { Int32($0) }
            )
            guard let resolution else {
                throw IntegrationError(.notFound, "could not resolve the app")
            }
            return Outcome(data: [
                "bundleID": resolution.bundleID.map(IntegrationValue.string) ?? .null,
                "path": resolution.executablePath.map(IntegrationValue.string) ?? .null,
                "displayName": resolution.displayName.map(IntegrationValue.string) ?? .null,
                "mode": .string(resolution.mode.rawValue),
                "ruleID": resolution.ruleID.map { .string($0.uuidString) } ?? .null,
            ], changed: false)

        case "ui.open":
            let pane = args["pane"]!.stringValue!
            let revealID = args["revealAppRuleID"]?.stringValue.flatMap(UUID.init(uuidString:))
            host.openPane(pane,
                          section: args["section"]?.stringValue,
                          revealPattern: args["revealPattern"]?.stringValue,
                          revealAppRuleID: revealID)
            return Outcome(data: ["pane": .string(pane)], changed: false)

        case "app.activate":
            host.activate()
            if let pane = args["pane"]?.stringValue {
                host.openPane(pane, section: nil, revealPattern: nil, revealAppRuleID: nil)
            }
            return Outcome(data: [:], changed: false)

        default:
            throw IntegrationError(.unknownAction, "unknown action '\(spec.id)'")
        }
    }

    // MARK: - Encoders

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "unknown"
    }

    private func statusData(_ snapshot: IntegrationSnapshot) -> [String: IntegrationValue] {
        [
            "state": .string(snapshot.state),
            "routingIntended": .bool(snapshot.routingIntended),
            "tunnelUp": .bool(snapshot.tunnelUp),
            "bindHost": .string(snapshot.bindHost),
            "port": .int(Int(snapshot.port)),
            "lastError": snapshot.lastError.map(IntegrationValue.string) ?? .null,
            "onboardingComplete": .bool(snapshot.onboardingComplete),
            "authorizationDeferred": .bool(snapshot.authorizationDeferred),
            "targetsCount": .int(snapshot.targets.count),
            "appRulesCount": .int(snapshot.appRules.count),
            "appVersion": .string(appVersion),
            "protocolVersion": .int(IntegrationProtocol.version),
        ]
    }

    private func targetValue(_ target: IntegrationTarget) -> IntegrationValue {
        .object([
            "id": .string(target.id.uuidString),
            "pattern": .string(target.pattern),
            "enabled": .bool(target.enabled),
        ])
    }

    private func appRuleValue(_ rule: IntegrationAppRule) -> IntegrationValue {
        .object([
            "id": .string(rule.id.uuidString),
            "key": .string(rule.key),
            "keyKind": .string(rule.keyKind.rawValue),
            "mode": .string(rule.mode.rawValue),
            "enabled": .bool(rule.enabled),
        ])
    }

    private func capabilities() -> [IntegrationValue] {
        IntegrationActions.all.map { spec in
            .object([
                "id": .string(spec.id),
                "summary": .string(spec.summary),
                "risk": .string(spec.risk.rawValue),
                "url": .bool(spec.urlExposed),
                "intent": .bool(spec.intentExposed),
                "confirmation": .bool(spec.requiresConfirmation),
                "args": .array(spec.args.map { arg in
                    var value: [String: IntegrationValue] = [
                        "name": .string(arg.name),
                        "required": .bool(arg.required),
                    ]
                    switch arg.type {
                    case .string(let maxLength):
                        value["type"] = .string("string")
                        value["maxLength"] = .int(maxLength)
                    case .boolean:
                        value["type"] = .string("bool")
                    case .integer(let min, let max):
                        value["type"] = .string("int")
                        value["min"] = .int(min)
                        value["max"] = .int(max)
                    case .uuid:
                        value["type"] = .string("uuid")
                    case .enumeration(let allowed):
                        value["type"] = .string("enum")
                        value["values"] = .array(allowed.map { .string($0) })
                    }
                    if let defaultValue = arg.defaultValue {
                        value["default"] = defaultValue
                    }
                    return .object(value)
                }),
            ])
        }
    }
}
