import Foundation

/// Owns the integration runtime: the permission store, the router and the local
/// control socket. `AppModel` only calls `apply(_:)` with the current settings,
/// so the coordinator (not the model) decides what is running.
final class IntegrationCoordinator {
    private weak var host: IntegrationHost?
    private let supportDir: URL
    private let permissions: IntegrationPermissionStore
    private let consent: IntegrationConsentProviding

    private var router: IntegrationRouter?
    private var routerUsesAudit: Bool?
    private var server: ControlSocketServer?
    private var applied: IntegrationSettings?

    init(host: IntegrationHost, supportDir: URL,
         consent: IntegrationConsentProviding? = nil) {
        self.host = host
        self.supportDir = supportDir
        self.permissions = IntegrationPermissionStore(
            fileURL: supportDir.appendingPathComponent("integration-permissions.json")
        )
        self.consent = consent ?? IntegrationConsentAlert()
    }

    var socketPath: String { supportDir.appendingPathComponent("control.sock").path }
    var tokenPath: String { supportDir.appendingPathComponent("control.token").path }
    var isRunning: Bool { server?.isRunning ?? false }
    var permissionsSnapshot: [IntegrationPermission] { permissions.all() }

    func revoke(_ key: String) {
        permissions.revoke(key: key)
    }

    /// Idempotent: called from every `commitConfig`, so it must do nothing when
    /// the settings did not change.
    func apply(_ settings: IntegrationSettings) {
        guard !DemoMode.isEnabled else { return }
        guard settings != applied else { return }
        applied = settings

        guard settings.enabled, settings.xpcEnabled else {
            stopServer()
            return
        }
        guard let host else { return }

        let audit = settings.auditEnabled ? IntegrationAudit(directory: supportDir) : nil
        if router == nil || routerUsesAudit != settings.auditEnabled {
            router = IntegrationRouter(host: host, audit: audit)
            routerUsesAudit = settings.auditEnabled
        }
        guard let router else { return }
        startServer(router: router)
    }

    func stop() {
        stopServer()
        applied = nil
    }

    // MARK: - Server

    private func startServer(router: IntegrationRouter) {
        if let server, server.isRunning { return }
        server?.stop()

        let server = ControlSocketServer(
            socketPath: socketPath,
            tokenPath: tokenPath
        ) { [weak self] identity, request in
            guard let self else {
                return IntegrationResult(
                    id: request.id, action: request.action, ok: false,
                    error: IntegrationError(.unavailable, "control is unavailable")
                )
            }
            return self.handle(identity, request)
        }

        if server.start() {
            Log.integration.notice("control: listening on the local socket")
        } else {
            Log.integration.error("control: the local socket could not start")
        }
        self.server = server
    }

    private func stopServer() {
        guard let server else { return }
        server.stop()
        self.server = nil
        Log.integration.notice("control: stopped")
    }

    // MARK: - Requests

    private func handle(_ identity: ControlIdentity,
                        _ request: IntegrationRequest) -> IntegrationResult {
        guard let router else {
            return IntegrationResult(
                id: request.id, action: request.action, ok: false,
                error: IntegrationError(.unavailable, "control is not running")
            )
        }

        let scope: IntegrationScope
        if let remembered = permissions.scope(for: identity) {
            scope = remembered
        } else if let granted = consent.ask(for: identity) {
            permissions.grant(identity, scope: granted)
            scope = granted
            Log.integration.notice("control: granted \(granted.rawValue, privacy: .public) to \(identity.displayName, privacy: .public)")
        } else {
            Log.integration.notice("control: denied \(identity.displayName, privacy: .public)")
            return IntegrationResult(
                id: request.id, action: request.action, ok: false,
                error: IntegrationError(.unauthorized,
                                       "\(identity.displayName) is not allowed to control Proxy Manager")
            )
        }

        return router.perform(request, source: .xpc(
            pid: identity.pid,
            bundleID: identity.bundleID,
            teamID: identity.teamID,
            scope: scope
        ))
    }
}
