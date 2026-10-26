import Foundation

/// How much a caller can affect the app. The classes are ordered: a caller with
/// a higher class may run every lower one.
enum IntegrationRisk: String, Codable, Comparable {
    case read
    case ui
    case policy

    var requiredScope: IntegrationScope {
        switch self {
        case .read, .ui: return .read
        case .policy: return .control
        }
    }

    private var order: Int {
        switch self {
        case .read: return 0
        case .ui: return 1
        case .policy: return 2
        }
    }

    static func < (lhs: IntegrationRisk, rhs: IntegrationRisk) -> Bool {
        lhs.order < rhs.order
    }
}

enum IntegrationArgType: Equatable {
    case string(maxLength: Int)
    case boolean
    case integer(min: Int, max: Int)
    case uuid
    case enumeration([String])
}

struct IntegrationArgSpec {
    let name: String
    let type: IntegrationArgType
    let required: Bool
    let defaultValue: IntegrationValue?

    init(_ name: String, _ type: IntegrationArgType,
         required: Bool = false, default defaultValue: IntegrationValue? = nil) {
        self.name = name
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
    }
}

struct IntegrationActionSpec {
    let id: String
    let summary: String
    let risk: IntegrationRisk
    let args: [IntegrationArgSpec]
    let urlExposed: Bool
    let intentExposed: Bool
    let requiresConfirmation: Bool
}

enum IntegrationPanes {
    static let all = ["dashboard", "settings", "onboarding", "about"]
}

enum IntegrationSettingsSections {
    static let all = ["general", "appearance", "tunnel", "proxy", "targets",
                      "apps", "system", "monitoring", "about"]
}

enum IntegrationActions {
    private static let appRuleKeyKinds = AppRuleKeyKind.allCases.map { $0.rawValue }
    private static let appModes = AppRoutingMode.allCases.map { $0.rawValue }

    /// The single source of truth for validation, `capabilities`, the adapters
    /// and the documentation.
    static let all: [IntegrationActionSpec] = [
        // MARK: Meta / reads

        IntegrationActionSpec(
            id: "ping",
            summary: "Protocol version and liveness.",
            risk: .read, args: [],
            urlExposed: false, intentExposed: false, requiresConfirmation: false
        ),
        IntegrationActionSpec(
            id: "capabilities",
            summary: "Every action with its arguments and exposure.",
            risk: .read, args: [],
            urlExposed: false, intentExposed: false, requiresConfirmation: false
        ),
        IntegrationActionSpec(
            id: "status",
            summary: "Routing state, tunnel health and listener details.",
            risk: .read, args: [],
            urlExposed: false, intentExposed: true, requiresConfirmation: false
        ),
        IntegrationActionSpec(
            id: "routing.explain",
            summary: "Why a host is routed where it is.",
            risk: .read,
            args: [
                IntegrationArgSpec("host", .string(maxLength: 253), required: true),
                IntegrationArgSpec("bundleID", .string(maxLength: 255)),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: false
        ),

        // MARK: Routing

        IntegrationActionSpec(
            id: "routing.enable",
            summary: "Turn routing on. Never prompts for authorization.",
            risk: .policy, args: [],
            urlExposed: true, intentExposed: true, requiresConfirmation: false
        ),
        IntegrationActionSpec(
            id: "routing.disable",
            summary: "Turn routing off and clear the launch intent.",
            risk: .policy, args: [],
            urlExposed: true, intentExposed: true, requiresConfirmation: false
        ),
        IntegrationActionSpec(
            id: "routing.toggle",
            summary: "Flip routing and return the new state.",
            risk: .policy, args: [],
            urlExposed: true, intentExposed: true, requiresConfirmation: false
        ),
        IntegrationActionSpec(
            id: "routing.retry",
            summary: "Retry a routing apply that deferred.",
            risk: .policy, args: [],
            urlExposed: true, intentExposed: true, requiresConfirmation: false
        ),

        // MARK: Targets

        IntegrationActionSpec(
            id: "targets.list",
            summary: "List target rules.",
            risk: .read,
            args: [
                IntegrationArgSpec("enabledOnly", .boolean, default: .bool(false)),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: false
        ),
        IntegrationActionSpec(
            id: "targets.add",
            summary: "Add a host or wildcard target.",
            risk: .policy,
            args: [
                IntegrationArgSpec("pattern", .string(maxLength: 253), required: true),
                IntegrationArgSpec("enabled", .boolean, default: .bool(true)),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: true
        ),
        IntegrationActionSpec(
            id: "targets.remove",
            summary: "Remove a target by id or pattern.",
            risk: .policy,
            args: [
                IntegrationArgSpec("id", .uuid),
                IntegrationArgSpec("pattern", .string(maxLength: 253)),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: true
        ),
        IntegrationActionSpec(
            id: "targets.update",
            summary: "Rename, enable or disable a target.",
            risk: .policy,
            args: [
                IntegrationArgSpec("id", .uuid, required: true),
                IntegrationArgSpec("pattern", .string(maxLength: 253)),
                IntegrationArgSpec("enabled", .boolean),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: true
        ),
        IntegrationActionSpec(
            id: "targets.clear",
            summary: "Remove every target. Requires confirm=true.",
            risk: .policy,
            args: [
                IntegrationArgSpec("confirm", .boolean, required: true),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: true
        ),
        IntegrationActionSpec(
            id: "presets.list",
            summary: "List the built-in target presets.",
            risk: .read, args: [],
            urlExposed: false, intentExposed: true, requiresConfirmation: false
        ),
        IntegrationActionSpec(
            id: "presets.apply",
            summary: "Merge a preset's rules into the target list.",
            risk: .policy,
            args: [
                IntegrationArgSpec("name", .string(maxLength: 128), required: true),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: true
        ),

        // MARK: Per-app routing

        IntegrationActionSpec(
            id: "apps.list",
            summary: "Per-app routing state and rules.",
            risk: .read, args: [],
            urlExposed: false, intentExposed: true, requiresConfirmation: false
        ),
        IntegrationActionSpec(
            id: "apps.setEnabled",
            summary: "Turn per-app routing on or off.",
            risk: .policy,
            args: [
                IntegrationArgSpec("enabled", .boolean, required: true),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: true
        ),
        IntegrationActionSpec(
            id: "apps.setDefault",
            summary: "Set the mode for apps without a rule.",
            risk: .policy,
            args: [
                IntegrationArgSpec("mode", .enumeration(appModes), required: true),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: true
        ),
        IntegrationActionSpec(
            id: "apps.rule.set",
            summary: "Create or update an app rule.",
            risk: .policy,
            args: [
                IntegrationArgSpec("key", .string(maxLength: 1024), required: true),
                IntegrationArgSpec("keyKind", .enumeration(appRuleKeyKinds), required: true),
                IntegrationArgSpec("mode", .enumeration(appModes), required: true),
                IntegrationArgSpec("enabled", .boolean, default: .bool(true)),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: true
        ),
        IntegrationActionSpec(
            id: "apps.rule.remove",
            summary: "Remove an app rule by id or key.",
            risk: .policy,
            args: [
                IntegrationArgSpec("id", .uuid),
                IntegrationArgSpec("key", .string(maxLength: 1024)),
                IntegrationArgSpec("keyKind", .enumeration(appRuleKeyKinds)),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: true
        ),
        IntegrationActionSpec(
            id: "apps.resolve",
            summary: "Resolve a running app or bundle to its effective mode.",
            risk: .read,
            args: [
                IntegrationArgSpec("bundleID", .string(maxLength: 255)),
                IntegrationArgSpec("path", .string(maxLength: 1024)),
                IntegrationArgSpec("pid", .integer(min: 1, max: Int(Int32.max))),
            ],
            urlExposed: false, intentExposed: true, requiresConfirmation: false
        ),

        // MARK: Windows

        IntegrationActionSpec(
            id: "ui.open",
            summary: "Open a window or a specific Settings pane.",
            risk: .ui,
            args: [
                IntegrationArgSpec("pane", .enumeration(IntegrationPanes.all), required: true),
                IntegrationArgSpec("section", .enumeration(IntegrationSettingsSections.all)),
                IntegrationArgSpec("revealPattern", .string(maxLength: 253)),
                IntegrationArgSpec("revealAppRuleID", .uuid),
            ],
            urlExposed: true, intentExposed: true, requiresConfirmation: false
        ),
        IntegrationActionSpec(
            id: "app.activate",
            summary: "Bring the app to the front.",
            risk: .ui,
            args: [
                IntegrationArgSpec("pane", .enumeration(IntegrationPanes.all)),
            ],
            urlExposed: true, intentExposed: true, requiresConfirmation: false
        ),
    ]

    /// Built without `Dictionary(uniqueKeysWithValues:)` so a duplicate id is a
    /// test failure rather than a launch trap.
    static let byID: [String: IntegrationActionSpec] = {
        var out: [String: IntegrationActionSpec] = [:]
        for spec in all { out[spec.id] = spec }
        return out
    }()
}
