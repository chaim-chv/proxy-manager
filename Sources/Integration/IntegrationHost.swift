import Foundation

// MARK: - Snapshots returned to the router

struct IntegrationTarget: Equatable {
    let id: UUID
    let pattern: String
    let enabled: Bool
}

struct IntegrationAppRule: Equatable {
    let id: UUID
    let key: String
    let keyKind: AppRuleKeyKind
    let mode: AppRoutingMode
    let enabled: Bool
}

struct IntegrationSnapshot: Equatable {
    let state: String
    let routingIntended: Bool
    let tunnelUp: Bool
    let bindHost: String
    let port: UInt16
    let lastError: String?
    let onboardingComplete: Bool
    let authorizationDeferred: Bool
    let targets: [IntegrationTarget]
    let appsEnabled: Bool
    let appsDefaultMode: AppRoutingMode
    let appsRecordInTelemetry: Bool
    let appRules: [IntegrationAppRule]

    var isOn: Bool { state == "on" || state == "degraded" }
}

struct IntegrationExplanation: Equatable {
    let host: String
    let decision: String
    let matchedPattern: String?
    let matchedTargetID: UUID?
    let appMode: String?
    let appRuleKey: String?
}

struct IntegrationAppResolution: Equatable {
    let bundleID: String?
    let executablePath: String?
    let displayName: String?
    let mode: AppRoutingMode
    let ruleID: UUID?
}

// MARK: - Host

/// Everything the router is allowed to do to the app. Implemented by
/// `AppModel` (see `AppModel+Integration.swift`); the harness supplies a fake.
///
/// Mutations are synchronous by design: the app's target/app edits already
/// commit synchronously, and routing enable/disable is a fire-and-forget state
/// transition that the caller observes through `status`. This keeps the router
/// free of its own concurrency model.
protocol IntegrationHost: AnyObject {
    func integrationSnapshot() -> IntegrationSnapshot

    // Routing
    func setRoutingIntent(_ enabled: Bool)
    func toggleRoutingIntent()
    func retryRoutingIntent()

    // Targets
    @discardableResult
    func addTarget(pattern: String, enabled: Bool) -> (id: UUID, added: Bool)
    @discardableResult
    func removeTargetRule(id: UUID) -> Bool
    @discardableResult
    func removeTargetRule(pattern: String) -> Bool
    @discardableResult
    func updateTargetRule(id: UUID, pattern: String?, enabled: Bool?) -> Bool
    func clearTargetRules()
    /// Returns how many rules the preset added, or `nil` when the name is unknown.
    @discardableResult
    func applyTargetPreset(idOrName: String) -> Int?

    // Per-app routing
    func setAppsEnabled(_ enabled: Bool)
    func setAppsDefaultMode(_ mode: AppRoutingMode)
    @discardableResult
    func setAppRule(key: String, kind: AppRuleKeyKind,
                       mode: AppRoutingMode, enabled: Bool) -> UUID
    @discardableResult
    func deleteAppRule(id: UUID) -> Bool
    @discardableResult
    func deleteAppRule(key: String, kind: AppRuleKeyKind) -> Bool

    // Reads that need app services
    func explain(host: String, bundleID: String?) -> IntegrationExplanation
    func resolveApp(bundleID: String?, path: String?, pid: Int32?) -> IntegrationAppResolution?

    // Windows
    func openPane(_ pane: String, section: String?,
                  revealPattern: String?, revealAppRuleID: UUID?)
    func activateApp()
}
