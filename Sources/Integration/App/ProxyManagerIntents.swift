import AppIntents
import Foundation

// App Intents are the OS-facing surface: Shortcuts, Siri, Spotlight and (on
// newer systems) Control Center. They run in the app's process and go through
// the same router as the socket and the URL scheme, so validation, rate limits
// and auditing are identical.
//
// A Shortcut is composed by the user, so these intents may reach any action the
// `appIntent` transport exposes. Destructive or policy-changing intents ask for
// confirmation; the router still refuses if external control is off.

// MARK: - Enums

enum RoutingModeAppEnum: String, AppEnum {
    case tunnel = "TUNNEL"
    case targets = "TARGETS"
    case direct = "DIRECT"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Routing mode"
    static var caseDisplayRepresentations: [RoutingModeAppEnum: DisplayRepresentation] = [
        .tunnel: DisplayRepresentation(title: "Tunnel all"),
        .targets: DisplayRepresentation(title: "Use target rules"),
        .direct: DisplayRepresentation(title: "Direct all"),
    ]
}

enum PaneAppEnum: String, AppEnum {
    case dashboard
    case settings
    case targets
    case apps

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Window"
    static var caseDisplayRepresentations: [PaneAppEnum: DisplayRepresentation] = [
        .dashboard: DisplayRepresentation(title: "Dashboard"),
        .settings: DisplayRepresentation(title: "Settings"),
        .targets: DisplayRepresentation(title: "Targets"),
        .apps: DisplayRepresentation(title: "Apps"),
    ]

    var integrationPane: String {
        self == .targets || self == .apps ? "settings" : rawValue
    }

    var integrationSection: String? {
        switch self {
        case .targets: return "targets"
        case .apps: return "apps"
        default: return nil
        }
    }
}

// MARK: - Errors

extension AppIntent {
    /// A confirmation with a specific message where the OS supports it, and the
    /// generic prompt on macOS 14 (the detailed overload is macOS 15+).
    func confirm(_ message: String) async throws {
        if #available(macOS 15.0, *) {
            try await requestConfirmation(dialog: IntentDialog(stringLiteral: message))
        } else {
            try await requestConfirmation()
        }
    }
}

struct IntegrationIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum IntentRunner {
    static func perform(_ action: String,
                        _ args: [String: IntegrationValue] = [:]) -> IntegrationResult {
        if let result = AppModel.shared.integration.performIntent(action, args: args) {
            return result
        }
        return IntegrationResult(
            id: UUID().uuidString, action: action, ok: false,
            error: IntegrationError(
                .requiresUserAction,
                "Turn on Settings → Integration → Allow other apps to control Proxy Manager first."
            )
        )
    }

    static func requireSuccess(_ result: IntegrationResult) throws -> [String: IntegrationValue] {
        guard result.ok else {
            throw IntegrationIntentError(
                message: result.error?.message ?? "Proxy Manager refused the request."
            )
        }
        return result.data
    }

    static func statusLine(_ result: IntegrationResult) throws -> String {
        let data = try requireSuccess(result)
        let state = data["state"]?.stringValue ?? "unknown"
        let tunnel = data["tunnelUp"]?.boolValue == true ? "up" : "down"
        return "Routing is \(state). The tunnel is \(tunnel)."
    }
}

// MARK: - Routing

struct SetRoutingIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Proxy Manager Routing"
    static var description = IntentDescription("Turn Proxy Manager routing on or off.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Enabled")
    var enabled: Bool

    init() {}

    init(enabled: Bool) {
        self.enabled = enabled
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = IntentRunner.perform(enabled ? "routing.enable" : "routing.disable")
        _ = try IntentRunner.requireSuccess(result)
        return .result(dialog: enabled ? "Routing is on." : "Routing is off.")
    }
}

struct ToggleRoutingIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Proxy Manager Routing"
    static var description = IntentDescription("Flip routing and report the new state.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = IntentRunner.perform("routing.toggle")
        let data = try IntentRunner.requireSuccess(result)
        let state = data["state"]?.stringValue ?? "unknown"
        return .result(dialog: "Routing is now \(state).")
    }
}

struct RoutingStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Proxy Manager Status"
    static var description = IntentDescription("Read the current routing state.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = IntentRunner.perform("status")
        return .result(dialog: IntentDialog(stringLiteral: try IntentRunner.statusLine(result)))
    }
}

// MARK: - Targets

struct AddTargetIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Proxy Manager Target"
    static var description = IntentDescription("Send a host or wildcard through the tunnel.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Host or wildcard")
    var host: String

    init() {}

    init(host: String) {
        self.host = host
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntegrationIntentError(message: "Enter a host, for example api.example.com.")
        }
        try await confirm("Add \(trimmed) to the targets that go through the tunnel?")
        let data = try IntentRunner.requireSuccess(
            IntentRunner.perform("targets.add", ["pattern": .string(trimmed)])
        )
        let pattern = data["pattern"]?.stringValue ?? trimmed
        return .result(dialog: "Added \(pattern) to the tunnel targets.")
    }
}

struct RemoveTargetIntent: AppIntent {
    static var title: LocalizedStringResource = "Remove Proxy Manager Target"
    static var description = IntentDescription("Stop sending a host through the tunnel.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Host or wildcard")
    var host: String

    init() {}

    init(host: String) {
        self.host = host
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntegrationIntentError(message: "Enter a host, for example api.example.com.")
        }
        let data = try IntentRunner.requireSuccess(
            IntentRunner.perform("targets.remove", ["pattern": .string(trimmed)])
        )
        let removed = data["removed"]?.intValue ?? 0
        return .result(dialog: "Removed \(removed) target rule.")
    }
}

struct ListTargetsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Proxy Manager Targets"
    static var description = IntentDescription("List the hosts that go through the tunnel.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let data = try IntentRunner.requireSuccess(IntentRunner.perform("targets.list"))
        let patterns = (data["targets"]?.arrayValue ?? []).compactMap {
            $0.objectValue?["pattern"]?.stringValue
        }
        let dialog: IntentDialog
        if patterns.isEmpty {
            dialog = "There are no target rules."
        } else {
            let preview = patterns.prefix(8).joined(separator: ", ")
            let suffix = patterns.count > 8 ? " and \(patterns.count - 8) more" : ""
            dialog = IntentDialog(stringLiteral: "\(patterns.count) targets: \(preview)\(suffix).")
        }
        return .result(value: patterns, dialog: dialog)
    }
}

// MARK: - Per-app routing

struct SetAppRoutingIntent: AppIntent {
    static var title: LocalizedStringResource = "Set App Routing in Proxy Manager"
    static var description = IntentDescription(
        "Route one app through the tunnel, through the target rules, or directly."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Bundle identifier")
    var bundleIdentifier: String
    @Parameter(title: "Mode")
    var mode: RoutingModeAppEnum

    init() {}

    init(bundleIdentifier: String, mode: RoutingModeAppEnum) {
        self.bundleIdentifier = bundleIdentifier
        self.mode = mode
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let bundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else {
            throw IntegrationIntentError(
                message: "Enter a bundle identifier, for example com.example.app."
            )
        }
        try await confirm("Set \(bundle) to \(mode.rawValue.lowercased()) and turn on per-app routing?")
        _ = try IntentRunner.requireSuccess(IntentRunner.perform("apps.setEnabled", [
            "enabled": .bool(true),
        ]))
        _ = try IntentRunner.requireSuccess(IntentRunner.perform("apps.rule.set", [
            "key": .string(bundle),
            "keyKind": .string(AppRuleKeyKind.bundle.rawValue),
            "mode": .string(mode.rawValue),
        ]))
        return .result(dialog: "Per-app routing is on for \(bundle).")
    }
}

// MARK: - Windows

struct OpenProxyManagerIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Proxy Manager"
    static var description = IntentDescription("Open the dashboard or a Settings pane.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Window")
    var pane: PaneAppEnum

    init() {}

    init(pane: PaneAppEnum) {
        self.pane = pane
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var args: [String: IntegrationValue] = ["pane": .string(pane.integrationPane)]
        if let section = pane.integrationSection {
            args["section"] = .string(section)
        }
        _ = try IntentRunner.requireSuccess(IntentRunner.perform("ui.open", args))
        return .result(dialog: "Opened Proxy Manager.")
    }
}

// MARK: - Shortcuts

struct ProxyManagerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRoutingIntent(),
            phrases: [
                "Toggle \(.applicationName) routing",
                "Turn \(.applicationName) on or off",
            ],
            shortTitle: "Toggle routing",
            systemImageName: "arrow.triangle.branch"
        )
        AppShortcut(
            intent: RoutingStatusIntent(),
            phrases: ["Check \(.applicationName) status"],
            shortTitle: "Routing status",
            systemImageName: "circle.dashed"
        )
        AppShortcut(
            intent: AddTargetIntent(),
            phrases: ["Add a \(.applicationName) target"],
            shortTitle: "Add target",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: OpenProxyManagerIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Proxy Manager",
            systemImageName: "macwindow"
        )
    }
}
