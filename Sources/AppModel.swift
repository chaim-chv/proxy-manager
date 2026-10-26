import Foundation
import SwiftUI
import AppKit
import Combine
import ServiceManagement
import Network

enum AppState: String, Equatable {
    case off, starting, on, degraded, stopping

    var label: String {
        switch self {
        case .off: return "OFF"
        case .starting: return "Starting…"
        case .on: return "ON"
        case .degraded: return "DEGRADED"
        case .stopping: return "Stopping…"
        }
    }

    var isActive: Bool { self == .on || self == .degraded }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var state: AppState = .off
    @Published var config: AppConfig
    @Published var tunnelUp: Bool = false
    @Published var lastError: String?
    @Published var showOnboarding: Bool = false
    @Published var sshRunning: Bool = false
    @Published var sshError: String?
    /// Live privileged-helper health, shown in Settings. `.notInstalled` until
    /// the (background) probe answers.
    @Published var helperState: HelperState = .notInstalled
    /// True when a proxy mutation deferred because the session could not show
    /// an authorization dialog. The UI offers a user-initiated retry.
    @Published var authorizationDeferred: Bool = false

    /// Navigation requests from the dashboard inspector: which Settings section
    /// to reveal and (optionally) which target rule to highlight.
    @Published var settingsSelection: SettingsSection?
    @Published var revealTargetID: UUID?
    @Published var revealAppRuleID: UUID?

    let configStore: ConfigStore
    let telemetry: TelemetryStore
    let proxyServer: ProxyServer
    let tunnelSupervisor: TunnelSupervisor
    let sshTunnel: SSHTunnelRunner
    let systemProxyManager: SystemProxyManager
    let shellEnvInjector: ShellEnvInjector
    let guiEnvInjector: GuiEnvInjector

    /// External control runtime (routing, targets, per-app rules and window
    /// navigation only). Lazy so `configStore` is ready; demo builds no-op.
    lazy var integration = IntegrationCoordinator(host: self,
                                                  supportDir: configStore.supportDir)

    // The system-proxy snapshot of the user's ORIGINAL settings. Only ever
    // touched on `workQueue` (also persisted to disk via ConfigStore).
    private var snapshot: SystemProxySnapshot?
    private var cancellables = Set<AnyCancellable>()
    private let workQueue = DispatchQueue(label: "com.proxymanager.work", qos: .userInitiated)
    private let wasOnKey = "routingWasOn"

    // WorkQueue-only: the bind host/port currently applied to the system proxy.
    private var appliedPort: UInt16 = 0
    private var appliedBindHost: String = ""
    // WorkQueue-only: whether we have published proxy env to the GUI session.
    private var appliedGuiEnv = false
    // WorkQueue-only: the rc files whose marker blocks we installed, and
    // whether shell env was last applied at all (LC-15).
    private var appliedShellRCFiles: [String] = []
    private var appliedShellEnvEnabled = false

    private var saveDebounce: DispatchWorkItem?
    private let onboardingKey = "hasCompletedOnboarding"

    // Short-lived App Nap tokens around system-proxy mutations only. There is
    // deliberately no session-lifetime token: the app must be able to nap while
    // the proxy is idle (see docs/tasks/authd-unlock-deadlock/04-app-nap.md).
    private let activity = ActivityController()
    private let pathMonitor = NWPathMonitor()
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Main-thread-only: a mutation that deferred because the session could not
    /// prompt. Retried (still prompt-free) when the session becomes interactive.
    private var deferredIntent: DeferredIntent?
    /// Main-thread-only: launch auto-enable is waiting for an interactive session.
    private var pendingAutoEnable = false
    /// Listener for "session became interactive", registered once per app run.
    private var sessionObserver: UUID?
    /// Main-thread: bounded re-check while an auto-enable or deferred mutation is
    /// pending, so a missed unlock notification cannot strand it. Never prompts.
    private var deferredRetryTimer: DispatchSourceTimer?
    /// Main-thread: backoff retry after a failed *background* enable (no network
    /// services yet, a transient `networksetup` failure). A user-initiated
    /// failure is surfaced in the UI instead and is never retried behind them.
    private var enableRetry: DispatchWorkItem?
    /// Main-thread: grows 5 s → 5 min and resets after a successful enable.
    private var enableRetryDelay: TimeInterval = 5
    private enum DeferredIntent { case enable, disable }
    // Serializes managed-tunnel side effects (Keychain delete, SSH apply/stop)
    // so concurrent callers cannot interleave an auth change with a spawn.
    // Tunnel state below is owned by this queue only (LC-20).
    private let tunnelSyncQueue = DispatchQueue(label: "com.proxymanager.tunnelsync")
    private var lastTunnelMode: TunnelMode?
    private var lastManagedAuth: SSHAuthMethod?
    // Main-thread-only: the last recovery attempt (enable rollback / disable
    // restore) failed, so `.degraded` must not be read as "tunnel down" (LC-21).
    private var recoveryFailed = false

    init() {
        let store = ConfigStore.shared
        self.configStore = store
        self.config = store.config
        self.telemetry = TelemetryStore(dbURL: store.telemetryURL,
                                        maxRows: store.config.monitor.maxRows,
                                        retentionDays: store.config.monitor.retentionDays)
        self.proxyServer = ProxyServer(telemetry: telemetry)
        self.tunnelSupervisor = TunnelSupervisor(configStore: store)
        self.sshTunnel = SSHTunnelRunner()
        self.systemProxyManager = SystemProxyManager()
        self.shellEnvInjector = ShellEnvInjector(configStore: store)
        self.guiEnvInjector = GuiEnvInjector(snapshotURL: store.guiEnvSnapshotURL)

        showOnboarding = !UserDefaults.standard.bool(forKey: onboardingKey)

        proxyServer.isTunnelUp = { [weak self] in self?.tunnelSupervisor.isTunnelUp ?? false }
        syncProxySettings()

        tunnelSupervisor.$tunnelUp
            .receive(on: DispatchQueue.main)
            .sink { [weak self] up in
                self?.tunnelUp = up
                self?.recomputeStateAfterTunnelChange(up: up)
            }
            .store(in: &cancellables)

        sshTunnel.$running
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in self?.sshRunning = running }
            .store(in: &cancellables)

        sshTunnel.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in self?.sshError = error }
            .store(in: &cancellables)

        // NOTE: telemetry deliberately does NOT forward its `objectWillChange`
        // to `AppModel`. `AppModel` is the environment object for every window
        // (including the retained, offscreen Settings window), so forwarding the
        // 10 Hz telemetry tick here invalidated the whole view tree — including
        // views that never display telemetry — and kept an invisible Settings
        // window re-laying-out forever. The dashboard observes `TelemetryStore`
        // directly instead; see `DashboardWindowController`.

        // Demo mode (screenshot builds only) must not probe the tunnel, touch
        // the Keychain, observe network changes, or auto-enable routing.
        if !DemoMode.isEnabled {
            tunnelSupervisor.start()
            syncManagedTunnel(config)
            observeSystemEvents()
            refreshHelperState()

            if UserDefaults.standard.bool(forKey: wasOnKey) {
                Log.app.notice("launch: routing intent=on")
                scheduleAutoEnableWhenInteractive()
            } else {
                Log.app.notice("launch: routing intent=off")
                recoverDanglingProxyIfNeeded()
            }
        }

        AppWindowTracker.shared.onChange = { [weak self] in
            self?.applyIconMode()
            self?.updateTelemetryFlusherMode()
        }
        updateTelemetryFlusherMode()

        Log.app.notice("ProxyManager initialized (config v\(self.config.version))")
        applyAppearance()
        applyIconMode()
        updateTelemetryFlusherMode()
        DemoMode.apply(to: self)

        // The coordinator builds the socket lazily; deferring to the next main
        // run-loop turn keeps `init` free of a self-capturing lazy access, and
        // reading the config there applies whatever the user already changed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.integration.apply(self.config.integration)
        }
    }

    /// Applies the configured light/dark appearance (nil = follow the system).
    /// Runs on main so it is safe to call from `init`/`commitConfig`.
    private func applyAppearance() {
        let appearance: NSAppearance?
        switch config.system.appearanceMode {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        DispatchQueue.main.async { NSApp.appearance = appearance }
    }

    /// Applies the icon placement: menu-bar-only uses the `.accessory`
    /// activation policy (no Dock icon) unless the Dashboard or Settings window
    /// is open; the other modes are always `.regular`. The status item's own
    /// visibility is owned by `StatusMenuController`, which observes `config`;
    /// this only switches the Dock presence.
    private func applyIconMode() {
        let showDock = config.system.iconMode.dockIconVisible(
            hasOpenAppWindow: AppWindowTracker.shared.hasOpenWindow)
        let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        DispatchQueue.main.async { NSApp.setActivationPolicy(policy) }
    }

    // MARK: - System events (sleep/wake, network change) & App Nap

    /// After sleep/wake or an interface change, re-apply the proxy to the
    /// current service list (new services otherwise bypass it) and make sure the
    /// listener is still running.
    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        let wake = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Let the network stack settle first; the re-apply is still
            // prompt-free (the screen is often still locked right after wake).
            self?.scheduleReapply(reason: "wake", after: 3)
        }
        workspaceObservers.append(wake)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            // The monitor calls back on its own queue; hop to main so the
            // reapply captures `state`/`config` on the thread that owns them.
            DispatchQueue.main.async {
                self?.reapplyAfterSystemChange(reason: "network change")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.proxymanager.pathmonitor"))

        // Unlock/wake retries a deferred (locked-session) mutation and the
        // launch auto-enable — both without a prompt.
        sessionObserver = SessionState.shared.onBecameInteractive { [weak self] in
            self?.sessionBecameInteractive()
        }
    }

    private func scheduleReapply(reason: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // A wake can also be the first moment the login session is usable
            // again; let the deferred/auto-enable paths re-check (still
            // prompt-free).
            self?.sessionBecameInteractive()
            self?.reapplyAfterSystemChange(reason: reason)
        }
    }

    /// Runs on main when the session becomes interactive (unlock/wake/activate).
    private func sessionBecameInteractive() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.sessionBecameInteractive() }
            return
        }
        // A launch auto-enable, a failed background attempt, or a deferred
        // enable all leave `routingIntended` true with the state off. This is
        // the one prompt-free retry that survives a missed unlock/wake event.
        if state == .off, SessionState.shared.isInteractive, routingIntended {
            if pendingAutoEnable {
                Log.app.notice("auto-enable: session is interactive; enabling prompt-free")
            }
            pendingAutoEnable = false
            ensureDeferredRetryTimer()
            enable(userInitiated: false)
            return
        }
        retryDeferredGrant(promptAllowed: false)
    }

    /// Runs on main; everything the work item needs is captured here so the
    /// item never touches `state` or `config` (LC-20). A `disable()` captured
    /// later sets `.stopping` synchronously on main *before* enqueueing its
    /// work item, so this capture cannot miss a stop that should have won.
    private func reapplyAfterSystemChange(reason: String) {
        // Once the app is off it used to stay off: nothing brought it back even
        // though the user never turned routing off. A wake/network change is the
        // best moment to repair that (the network stack is usable again).
        guard state.isActive else {
            if state == .off, routingIntended {
                Log.app.notice("\(reason): routing is off but was requested on; re-enabling")
                enable(userInitiated: false)
            }
            return
        }
        let port = config.proxy.port
        let bindHost = config.proxy.bindHost
        let watchdog = config.system.crashWatchdog
        Log.app.notice("re-applying proxy after \(reason)")
        workQueue.async { [weak self] in
            guard let self else { return }
            guard let services = self.systemProxyManager.listServicesChecked(), !services.isEmpty else {
                let message = "cannot read the network service list; keeping the current proxy state"
                self.setLastError("Failed to re-apply proxy after \(reason): \(message)")
                Log.app.error("re-apply after \(reason): \(message)")
                return
            }
            if !self.proxyServer.isRunning {
                do { try self.proxyServer.start() } catch {
                    Log.app.error("re-apply: proxy restart failed: \(error.localizedDescription)")
                }
            }
            do {
                if watchdog {
                    WatchdogController.installIfNeeded()
                    WatchdogController.arm(port: port)
                }
                try self.ensureSnapshotCovers(services)
                try self.withApplyActivity("Re-applying proxy after \(reason)") {
                    try self.systemProxyManager.applyProxy(
                        services: services, port: port,
                        host: self.systemProxyHost(bindHost),
                        allowAdminPrompt: false)
                }
                self.appliedPort = port
                self.appliedBindHost = bindHost
                self.clearDeferredState(only: .enable)
            } catch {
                self.noteDeferredIfNeeded(error, intent: .enable)
                self.setLastError("Failed to re-apply proxy after \(reason): \(error.localizedDescription)")
                Log.app.error("re-apply after \(reason) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Holds a short-lived App Nap token for exactly one proxy mutation. Never
    /// held while idle, so macOS can nap the menu-bar process.
    private func withApplyActivity<T>(_ reason: String, _ body: () throws -> T) rethrows -> T {
        try activity.withActivity(reason, body)
    }

    // MARK: - Snapshot coverage

    /// Ensures every service that is about to be proxied has its original state
    /// in the snapshot, so disable/quit/crash recovery can restore it.
    ///
    /// A USB/Thunderbolt Ethernet, dock, or VPN interface can appear after
    /// `enable()`; re-applying to it without capturing it would leave that
    /// (often primary) service pointing at a dead listener after disable.
    /// WorkQueue-only. Persists before returning so the apply is always covered,
    /// and throws if the recovery contract could not be written.
    private func ensureSnapshotCovers(_ services: [String]) throws {
        if snapshot == nil, let persisted = configStore.loadSnapshot(), !persisted.isEmpty {
            snapshot = persisted
        }
        if snapshot == nil {
            // Never capture our own dangling proxy as the user's "original":
            // clear it first (prompt-free), and refuse to guess when the state
            // cannot be read.
            switch systemProxyManager.proxyCheck(port: 0) {
            case .clean:
                break
            case .ours:
                Log.app.notice("snapshot: clearing a dangling local system proxy before capturing the original state")
                do {
                    try systemProxyManager.clearLocalProxies(port: 0)
                } catch {
                    throw NSError(domain: "ProxyManager", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "cannot clear the dangling local system proxy before capturing your original settings: \(error.localizedDescription)"])
                }
            case .unknown:
                throw NSError(domain: "ProxyManager", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "cannot determine the current system proxy state; refusing to change it without a recovery snapshot"])
            }
            let captured = try systemProxyManager.captureSnapshot(services: services)
            guard !captured.isEmpty else {
                throw NSError(domain: "ProxyManager", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "cannot capture your original system proxy settings; refusing to change the proxy"])
            }
            try persist(snapshot: captured)
            snapshot = captured
            Log.app.notice("snapshot: captured \(captured.count) service(s) before apply")
            return
        }
        let known = Set((snapshot ?? [:]).keys)
        let added = services.filter { !known.contains($0) }
        guard !added.isEmpty else { return }
        let captured = try systemProxyManager.captureSnapshot(services: added)
        guard !captured.isEmpty else { return }
        var merged = snapshot ?? [:]
        for (svc, state) in captured { merged[svc] = state }
        try persist(snapshot: merged)
        snapshot = merged
        Log.app.notice("snapshot: added new service(s) before apply: \(captured.keys.sorted().joined(separator: ", "))")
    }

    /// Persists the recovery contract before the system proxy is changed. An
    /// unwritable snapshot means the app must not route: without it neither a
    /// crash nor quit can restore the user's settings.
    private func persist(snapshot value: SystemProxySnapshot) throws {
        guard configStore.saveSnapshot(value) else {
            throw NSError(domain: "ProxyManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "cannot save the system-proxy recovery snapshot; refusing to change the proxy"])
        }
    }

    /// Best-effort snapshot cleanup after a successful restore/disable/quit.
    /// If the file cannot be removed, quarantine it so a later enable cannot
    /// load a stale "original" over the user's current settings (LC-08).
    private func clearSnapshotBestEffort() {
        snapshot = nil
        if !configStore.clearSnapshot() {
            Log.app.error("snapshot: could not remove the persisted recovery snapshot; quarantining it")
            if !configStore.quarantineSnapshot() {
                Log.app.error("snapshot: could not quarantine the stale recovery snapshot")
            }
        }
    }

    // MARK: - Toggle

    /// The user's last deliberate choice: routing should be on. This is the
    /// launch auto-enable intent, the Settings master switch, and the retry
    /// gate. Only an explicit "off" (or `revert.sh`) clears it — a failed
    /// attempt must not silently flip the user's preference.
    var routingIntended: Bool { UserDefaults.standard.bool(forKey: wasOnKey) }

    /// Explicit user toggle (status menu, dashboard). This is the only place
    /// that may allow an admin prompt.
    func toggle() {
        SessionState.shared.noteUserAction()
        switch state {
        case .off: setRoutingEnabled(true)
        case .on, .degraded: setRoutingEnabled(false)
        default: break
        }
    }

    /// The Settings master switch. Turning off always clears the intent, even
    /// when the app already reports off (e.g. a previous attempt failed), so a
    /// pending retry cannot turn routing back on behind the user's back.
    func setRoutingEnabled(_ enabled: Bool) {
        if DemoMode.isEnabled { return }
        SessionState.shared.noteUserAction()
        if enabled {
            UserDefaults.standard.set(true, forKey: wasOnKey)
            if state == .off { enable(userInitiated: true) }
        } else {
            UserDefaults.standard.set(false, forKey: wasOnKey)
            cancelEnableRetry()
            if state.isActive { disable(userInitiated: true) }
        }
    }

    /// Routing intent from an external caller.
    ///
    /// Deliberately parallel to `setRoutingEnabled`: it never records a user
    /// action and never allows an authorization prompt. An integration caller
    /// is not a present user, and a remote `enable` that could raise the admin
    /// dialog would be a phishing primitive.
    func setRoutingIntentFromIntegration(_ enabled: Bool) {
        if DemoMode.isEnabled { return }
        if enabled {
            UserDefaults.standard.set(true, forKey: wasOnKey)
            pendingAutoEnable = false
            if state == .off { enable(userInitiated: false) }
        } else {
            UserDefaults.standard.set(false, forKey: wasOnKey)
            cancelEnableRetry()
            if state.isActive { disable(userInitiated: false) }
        }
    }

    /// Repairs the case where the system proxy still points at our port while
    /// the launch intent reads off (an interrupted quit or a lost preferences
    /// file). Without this the machine would keep sending traffic to a listener
    /// nothing started. A persisted recovery snapshot is required as proof that
    /// *we* applied the proxy — never hijack a user's own local proxy that
    /// happens to use the same port on a clean first run.
    private func recoverDanglingProxyIfNeeded() {
        let port = config.proxy.port
        workQueue.async { [weak self] in
            guard let self else { return }
            guard let snap = self.configStore.loadSnapshot(), !snap.isEmpty else { return }
            guard self.systemProxyManager.proxyCheck(port: port) == .ours else { return }
            DispatchQueue.main.async {
                guard self.state == .off else { return }
                Log.app.notice("launch: the system proxy still points at us; restoring routing")
                UserDefaults.standard.set(true, forKey: self.wasOnKey)
                self.enable(userInitiated: false)
            }
        }
    }

    /// Bounded exponential backoff (5 s → 5 min) for a background enable that
    /// failed for a transient reason. Only called for background attempts; a
    /// user-initiated failure is surfaced in the UI instead.
    private func scheduleEnableRetry() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !DemoMode.isEnabled else { return }
            guard self.state == .off, self.routingIntended, self.deferredIntent == nil else { return }
            self.enableRetry?.cancel()
            let delay = self.enableRetryDelay
            self.enableRetryDelay = min(self.enableRetryDelay * 2, 300)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.enableRetry = nil
                guard self.state == .off, self.routingIntended else { return }
                guard SessionState.shared.isInteractive else {
                    self.scheduleEnableRetry()
                    return
                }
                Log.app.notice("routing: retrying enable after a failed attempt")
                self.enable(userInitiated: false)
            }
            self.enableRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelEnableRetry(resetBackoff: Bool = false) {
        let apply = { [weak self] in
            guard let self else { return }
            self.enableRetry?.cancel()
            self.enableRetry = nil
            if resetBackoff { self.enableRetryDelay = 5 }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// The host the system proxy must point at to reach the local listener.
    /// A loopback or wildcard bind is reachable on `127.0.0.1`; a specific
    /// non-loopback bind is only reachable at that address (the listener bound
    /// it successfully, so it is local and `networksetup` accepts it).
    private func systemProxyHost(_ bindHost: String) -> String {
        let trimmed = bindHost.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "0.0.0.0" || trimmed == "::" { return "127.0.0.1" }
        return trimmed
    }

    /// - Parameter userInitiated: true only from an explicit user action. A
    ///   background enable (login, wake, retry) passes false and defers instead
    ///   of prompting.
    func enable(userInitiated: Bool = false) {
        guard state == .off else { return }
        if userInitiated { SessionState.shared.noteUserAction() }
        // Record the intent before trying: a transient failure (no services yet
        // right after wake, a locked keychain, a `networksetup` hiccup) must not
        // erase the user's "keep routing on" choice.
        UserDefaults.standard.set(true, forKey: wasOnKey)
        pendingAutoEnable = false
        ensureDeferredRetryTimer()
        setState(.starting)
        let cfg = config
        let port = cfg.proxy.port
        let bindHost = cfg.proxy.bindHost
        Log.app.notice("enable(): starting on \(bindHost):\(port)")

        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.syncManagedTunnel(cfg)
            var services: [String] = []
            var touchedSystemProxy = false
            var startedListener = false
            do {
                let listed = self.systemProxyManager.listServicesChecked()
                guard let listed, !listed.isEmpty else {
                    let message = listed == nil
                        ? "cannot read the network service list; refusing to enable routing"
                        : "no enabled network services; refusing to enable routing"
                    throw NSError(domain: "ProxyManager", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: message])
                }
                services = listed
                let listenerWasRunning = self.proxyServer.isRunning
                try self.proxyServer.start()
                startedListener = !listenerWasRunning

                // Persist the user's ORIGINAL proxy state before touching it, so
                // a later crash/relaunch can still restore correctly. Throws (and
                // aborts before apply) if the recovery contract cannot be saved.
                try self.ensureSnapshotCovers(services)

                // Arm the crash watchdog *before* touching the system proxy: if
                // we die at any point past here, the watchdog restores it.
                if cfg.system.crashWatchdog {
                    WatchdogController.installIfNeeded()
                    WatchdogController.arm(port: port)
                }

                // Persist the intent *before* mutating the system proxy: a crash
                // after apply but before the success path below must still make
                // the next launch auto-enable and repair a dangling proxy.
                UserDefaults.standard.set(true, forKey: self.wasOnKey)
                // Set before applyProxy: a networksetup failure can happen partway
                // through (some services already modified), so the catch below must
                // roll back whenever we've started touching the system proxy.
                touchedSystemProxy = true
                try self.withApplyActivity("Enabling proxy routing") {
                    try self.systemProxyManager.applyProxy(services: services, port: port,
                                                           host: self.systemProxyHost(bindHost),
                                                           allowAdminPrompt: userInitiated)
                }

                self.appliedPort = port
                self.appliedBindHost = bindHost
                self.syncShellEnv(tunnelHost: cfg.tunnel.effectiveHost,
                                  injectEnabled: cfg.system.injectShellEnv,
                                  rcFiles: cfg.system.managedShellRcs)
                self.syncGuiEnv(enabled: cfg.system.injectGuiEnv, tunnelHost: cfg.tunnel.effectiveHost)
                self.clearDeferredState()
                self.cancelEnableRetry(resetBackoff: true)
                self.finalizeState(self.tunnelSupervisor.isTunnelUp ? .on : .degraded, recoveryFailed: false)
                Log.app.notice("enable(): routing enabled (tunnelUp=\(self.tunnelSupervisor.isTunnelUp))")
            } catch {
                // Roll back so we never leave the system proxy dangling. Recovery
                // never prompts, even when the user's own enable may have.
                Log.app.error("enable() failed, rolling back: \(error.localizedDescription)")
                self.noteDeferredIfNeeded(error, intent: .enable)
                if touchedSystemProxy {
                    var rolledBack = true
                    if let snap = self.snapshot {
                        do {
                            try self.withApplyActivity("Rolling back the system proxy") {
                                try self.systemProxyManager.restore(snapshot: snap, allowAdminPrompt: false)
                            }
                        } catch {
                            rolledBack = false
                            Log.app.error("enable() rollback restore failed: \(error.localizedDescription)")
                        }
                    } else {
                        do {
                            try self.withApplyActivity("Clearing the system proxy") {
                                try self.systemProxyManager.clearProxy(services: services, allowAdminPrompt: false)
                            }
                        } catch {
                            rolledBack = false
                            Log.app.error("enable() rollback clear failed: \(error.localizedDescription)")
                        }
                    }
                    self.removeAppliedShellEnv(currentRCFiles: cfg.system.managedShellRcs)
                    if self.appliedGuiEnv {
                        self.guiEnvInjector.remove()
                        self.appliedGuiEnv = false
                    }
                    if rolledBack {
                        self.clearSnapshotBestEffort()
                        self.appliedPort = 0
                        self.appliedBindHost = ""
                        // Keep `wasOnKey`: this was a failed *attempt*, not an
                        // explicit "off". A wake/network change, the next launch,
                        // or the bounded retry below will try again.
                        WatchdogController.disarm()
                        self.proxyServer.stop()
                        // A successful rollback leaves the system proxy exactly
                        // as we found it: nothing is left to recover.
                        self.finalizeState(.off, recoveryFailed: false)
                    } else {
                        // Recovery state must survive: keep the snapshot on disk and
                        // the watchdog armed, and keep the listener running so the
                        // machine still has connectivity. The watchdog repairs the
                        // dangling proxy when this process exits.
                        // Never persist an empty snapshot: the watchdog treats "no
                        // usable snapshot" as nothing to restore, which would leave
                        // the proxy dangling after this process exits.
                        if let snap = self.snapshot, !snap.isEmpty {
                            if !self.configStore.saveSnapshot(snap) {
                                Log.app.error("enable(): could not persist the recovery snapshot after a failed rollback")
                            }
                        } else {
                            Log.app.error("enable(): rollback has no snapshot to persist")
                        }
                        // Leave the intent set so the next launch auto-enables and
                        // repairs the still-dangling proxy.
                        UserDefaults.standard.set(true, forKey: self.wasOnKey)
                        // The proxy may still point at us: record that the last
                        // recovery failed so a tunnel flap cannot show ON (LC-21).
                        self.finalizeState(.degraded, recoveryFailed: true)
                    }
                } else {
                    // This call never touched the system proxy, so any recovery
                    // state left by an earlier crash/instance is still the only
                    // way to restore it: never clear the snapshot, disarm the
                    // watchdog, or clear the launch intent here.
                    if self.snapshot == nil, let persisted = self.configStore.loadSnapshot(), !persisted.isEmpty {
                        self.snapshot = persisted
                    }
                    let hasRecoverySnapshot = !(self.snapshot?.isEmpty ?? true)
                    if !hasRecoverySnapshot {
                        if startedListener { self.proxyServer.stop() }
                    }
                    // A listener kept alive here may be serving a dangling proxy
                    // from a previous crash, so report degraded rather than off.
                    // This call attempted no recovery, so the flag is untouched.
                    self.finalizeState(hasRecoverySnapshot ? .degraded : .off)
                    Log.app.error("enable(): failed before touching the system proxy; recovery state preserved")
                }
                self.setLastError(error.localizedDescription)
                // A user-initiated failure is visible in Settings/menu and must
                // not re-enable behind their back; a background attempt retries
                // with backoff so a transient wake-time failure self-heals.
                if !userInitiated { self.scheduleEnableRetry() }
            }
        }
    }

    /// - Parameter userInitiated: true only from an explicit user action. A
    ///   background disable (deferred retry, quit) passes false and defers
    ///   instead of prompting.
    func disable(userInitiated: Bool = false) {
        guard state.isActive else { return }
        if userInitiated {
            SessionState.shared.noteUserAction()
            // The user asked for off: clear the intent even if the restore
            // below fails, so no retry/launch path turns routing back on.
            UserDefaults.standard.set(false, forKey: wasOnKey)
            cancelEnableRetry()
        }
        setState(.stopping)
        let cfg = config
        Log.app.notice("disable(): stopping")

        workQueue.async { [weak self] in
            guard let self = self else { return }
            let sweepPort = self.appliedPort != 0 ? self.appliedPort : cfg.proxy.port
            do {
                if let snap = self.snapshot {
                    try self.activity.withActivity("Disabling the system proxy") {
                        try self.systemProxyManager.restore(snapshot: snap, allowAdminPrompt: userInitiated)
                    }
                    // A service that appeared after enable may have been proxied
                    // without ever entering the snapshot; clear only those.
                    self.systemProxyManager.clearUnsnapshottedLocalProxies(snapshot: snap, port: sweepPort)
                } else {
                    // Without a snapshot the only proof that nothing is left
                    // behind is a successful read: an unreadable or empty list
                    // must not count as "cleared".
                    guard let services = self.systemProxyManager.listServicesChecked(), !services.isEmpty else {
                        throw NSError(domain: "ProxyManager", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "cannot read the network service list; cannot confirm the system proxy was cleared"])
                    }
                    try self.activity.withActivity("Clearing the system proxy") {
                        try self.systemProxyManager.clearProxy(services: services,
                                                              allowAdminPrompt: userInitiated)
                    }
                }
                self.clearSnapshotBestEffort()
                WatchdogController.disarm()
                self.appliedPort = 0
                self.appliedBindHost = ""
                self.removeAppliedShellEnv(currentRCFiles: cfg.system.managedShellRcs)
                self.syncGuiEnv(enabled: false, tunnelHost: "")
                UserDefaults.standard.set(false, forKey: self.wasOnKey)
                self.proxyServer.stop()
                self.clearDeferredState()
                self.finalizeState(.off, recoveryFailed: false)
                Log.app.notice("disable(): routing disabled")
            } catch {
                // Restore failed: keep the proxy running, the snapshot, and the
                // watchdog so the machine keeps working and can still recover.
                self.noteDeferredIfNeeded(error, intent: .disable)
                self.setLastError(error.localizedDescription)
                // The system proxy may still point at us: a later tunnel flap
                // must not promote this to ON (LC-21).
                self.finalizeState(.degraded, recoveryFailed: true)
                Log.app.error("disable() failed; keeping proxy + snapshot: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Config

    func commitConfig() {
        if DemoMode.isEnabled { return }
        // One main-thread snapshot for the whole commit: the work items below
        // must never read `config` themselves (LC-20).
        let cfg = config
        syncProxySettings()
        syncManagedTunnel(cfg)
        integration.apply(cfg.integration)
        scheduleSave()
        applyAppearance()
        applyIconMode()
        if !cfg.system.crashWatchdog {
            WatchdogController.uninstall()
        }
        // If routing is active and the bind port/host changed, re-apply live.
        if state.isActive {
            let port = cfg.proxy.port
            let bindHost = cfg.proxy.bindHost
            let watchdog = cfg.system.crashWatchdog
            let guiEnabled = cfg.system.injectGuiEnv
            let tunnelHost = cfg.tunnel.effectiveHost
            let shellEnabled = cfg.system.injectShellEnv
            let shellRcs = cfg.system.managedShellRcs
            workQueue.async { [weak self] in
                guard let self = self else { return }
                self.reapplyIfPortChanged(port: port, bindHost: bindHost, watchdog: watchdog)
                self.syncGuiEnv(enabled: guiEnabled, tunnelHost: tunnelHost)
                self.syncShellEnv(tunnelHost: tunnelHost, injectEnabled: shellEnabled, rcFiles: shellRcs)
            }
        } else {
            // Retract any GUI env left behind by a degraded stop.
            workQueue.async { [weak self] in self?.syncGuiEnv(enabled: false, tunnelHost: "") }
        }
    }

    private func scheduleSave() {
        saveDebounce?.cancel()
        let cfg = config
        let store = configStore
        let work = DispatchWorkItem {
            store.config = cfg
        }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func syncProxySettings() {
        var runtime = ProxyRuntimeSettings()
        runtime.bindHost = config.proxy.bindHost
        runtime.port = config.proxy.port
        runtime.tunnelHost = config.tunnel.effectiveHost
        runtime.tunnelPort = config.tunnel.effectivePort
        runtime.failClosed = config.policy.failClosedWhenTunnelDown
        runtime.recordPaths = config.monitor.recordPaths
        runtime.recordAppInTelemetry = config.apps.enabled && config.apps.recordInTelemetry
        proxyServer.update(settings: runtime)
        telemetry.setLimits(maxRows: config.monitor.maxRows,
                            retentionDays: config.monitor.retentionDays)
        proxyServer.routingEngine.update(rules: config.targets,
                                         appRules: config.apps.rules,
                                         appEnabled: config.apps.enabled,
                                         defaultMode: config.apps.defaultMode)
    }

    /// Starts/stops the app-managed SSH tunnel to match `cfg`.
    ///
    /// Called from main (`commitConfig`) and from `workQueue` (`enable`), so the
    /// config is always a caller-captured snapshot and every side effect runs on
    /// `tunnelSyncQueue`: two callers can no longer interleave "delete the
    /// credential" with "spawn with it" (LC-20).
    private func syncManagedTunnel(_ cfg: AppConfig) {
        if DemoMode.isEnabled { return }
        let mode = cfg.tunnel.mode
        let auth = cfg.tunnel.managed.auth
        let managed = cfg.tunnel.managed
        tunnelSyncQueue.async { [weak self] in
            guard let self else { return }
            let modeChanged = self.lastTunnelMode != mode
            let authChanged = self.lastManagedAuth != auth
            self.lastTunnelMode = mode
            self.lastManagedAuth = auth

            if mode == .managed {
                // Switching away from password auth must not leave the credential
                // in the Keychain.
                if auth == .key && (authChanged || modeChanged) {
                    SSHKeychain.shared.delete()
                }
                self.sshTunnel.apply(managed)
            } else {
                if modeChanged {
                    SSHKeychain.shared.delete()
                }
                self.sshTunnel.stop()
            }
        }
    }

    /// Runs on `workQueue` when a bind port/host change is detected while active.
    /// Rolls back to the last-good listener/port if the rebind fails, so the
    /// system proxy is never left pointing at a dead listener.
    private func reapplyIfPortChanged(port: UInt16, bindHost: String, watchdog: Bool) {
        guard port != appliedPort || bindHost != appliedBindHost else { return }
        let oldPort = appliedPort
        let oldBindHost = appliedBindHost
        // Read before stopping the old listener: an unreadable/empty list means
        // we cannot move the system proxy, so leave everything as it is.
        guard let services = systemProxyManager.listServicesChecked(), !services.isEmpty else {
            let message = "cannot read the network service list; keeping \(oldBindHost):\(oldPort)"
            setLastError("Failed to apply proxy change: \(message)")
            Log.app.error("reapply: \(message)")
            return
        }
        do {
            proxyServer.stop()
            try proxyServer.start()
            try ensureSnapshotCovers(services)
            // Re-arm with the new port before applying, so a crash mid-rebind is
            // still covered by the watchdog (it matches the configured port).
            if watchdog {
                WatchdogController.installIfNeeded()
                WatchdogController.arm(port: port)
            }
            try activity.withActivity("Applying a proxy port change") {
                try systemProxyManager.applyProxy(services: services, port: port,
                                                  host: systemProxyHost(bindHost),
                                                  allowAdminPrompt: false)
            }
            appliedPort = port
            appliedBindHost = bindHost
        } catch {
            self.noteDeferredIfNeeded(error, intent: .enable)
            Log.app.error("reapply failed, rolling back to \(oldBindHost):\(oldPort): \(error.localizedDescription)")
            proxyServer.stop()
            var s = proxyServer.snapshot()
            if oldPort != 0 { s.port = oldPort }
            if !oldBindHost.isEmpty { s.bindHost = oldBindHost }
            proxyServer.update(settings: s)
            do {
                try proxyServer.start()
                if oldPort != 0 {
                    // Never apply an empty list: `services` was verified
                    // non-empty before the rebind started.
                    try ensureSnapshotCovers(services)
                    try activity.withActivity("Restoring the previous proxy port") {
                        try systemProxyManager.applyProxy(services: services, port: oldPort,
                                                          host: systemProxyHost(oldBindHost),
                                                          allowAdminPrompt: false)
                    }
                    if watchdog { WatchdogController.arm(port: oldPort) }
                    appliedPort = oldPort
                    appliedBindHost = oldBindHost
                }
            } catch {
                self.noteDeferredIfNeeded(error, intent: .enable)
                setLastError("Failed to apply proxy change and rollback failed: \(error.localizedDescription)")
                Log.app.error("reapply rollback failed: \(error.localizedDescription)")
                return
            }
            setLastError("Failed to apply proxy change: \(error.localizedDescription)")
        }
    }

    /// Publishes or retracts the GUI-session proxy env to match the current
    /// config. Runs on `workQueue`; idempotent (the injector skips an unchanged
    /// value set). `appliedPort == 0` means routing is not applied, so only a
    /// retraction is possible.
    private func syncGuiEnv(enabled: Bool, tunnelHost: String) {
        if enabled && appliedPort != 0 {
            appliedGuiEnv = guiEnvInjector.apply(port: appliedPort, bindHost: appliedBindHost,
                                                 tunnelHost: tunnelHost)
        } else if appliedGuiEnv {
            guiEnvInjector.remove()
            appliedGuiEnv = false
        }
    }

    /// Reconciles shell env with the live config. Runs on `workQueue`; the env
    /// file always uses the *applied* port/host so a failed rebind cannot leave
    /// CLI tools pointing at a dead listener. Removal is safe and unconditional
    /// (LC-15): turning injection off, or a failed enable, must clean up every
    /// file that may have been touched.
    private func syncShellEnv(tunnelHost: String, injectEnabled: Bool, rcFiles: [String]) {
        guard appliedPort != 0 else { return }
        if injectEnabled {
            shellEnvInjector.writeEnvFile(port: appliedPort, bindHost: appliedBindHost,
                                          tunnelHost: tunnelHost)
            shellEnvInjector.install(rcFiles: rcFiles)
            let stale = appliedShellRCFiles.filter { !rcFiles.contains($0) }
            if !stale.isEmpty {
                shellEnvInjector.remove(rcFiles: stale)
            }
            if !appliedShellEnvEnabled {
                Log.system.notice("shell env: applied to \(rcFiles.count) rc file(s)")
            }
            appliedShellRCFiles = rcFiles
            appliedShellEnvEnabled = true
        } else {
            removeAppliedShellEnv(currentRCFiles: rcFiles)
        }
    }

    /// Removes the env file and marker blocks from every rc file we may have
    /// touched: the last applied list, the current list, and the shell default.
    /// Runs on `workQueue`.
    private func removeAppliedShellEnv(currentRCFiles: [String]) {
        var rcFiles = appliedShellRCFiles
        for rc in currentRCFiles where !rcFiles.contains(rc) {
            rcFiles.append(rc)
        }
        for rc in ShellEnvInjector.defaultRCFiles where !rcFiles.contains(rc) {
            rcFiles.append(rc)
        }
        shellEnvInjector.remove(rcFiles: rcFiles)
        shellEnvInjector.removeEnvFile()
        if appliedShellEnvEnabled || !appliedShellRCFiles.isEmpty {
            Log.system.notice("shell env: removed")
        }
        appliedShellRCFiles = []
        appliedShellEnvEnabled = false
    }

    func resetAll() {
        configStore.reset()
        config = configStore.config
        commitConfig()
        telemetry.purge()
    }

    /// Set only by the app's own deliberate quit affordances: the menu-bar
    /// status menu, the app-menu "Quit Proxy Manager" item (a click, not ⌘Q),
    /// Settings → General, Restart, and Sparkle just before it installs an
    /// update. `AppDelegate.applicationShouldTerminate` reads it so an
    /// incidental quit request (the Dock menu's Quit, a stray Apple event)
    /// closes the front window instead of killing the tunnel.
    private(set) var isTerminationAllowed = false

    /// Marks the next termination as deliberate. Everything that means "the
    /// user asked to quit" must go through here (or `quitApp()`).
    func allowTermination() {
        isTerminationAllowed = true
    }

    /// Deliberately quits the app. The status menu, the app-menu Quit item, and
    /// the Settings button all route through here so the terminate is honored.
    func quitApp() {
        allowTermination()
        NSApp.terminate(nil)
    }

    /// Relaunches the app. A detached shell waits for this process to exit (so
    /// the system proxy is restored and port 8888 is released) before reopening
    /// the bundle as a fresh instance.
    func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        Log.app.notice("restartApp(): relaunching in place")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"\(bundlePath)\""]
        do {
            try helper.run()
        } catch {
            Log.app.error("restartApp(): could not schedule relaunch: \(error.localizedDescription)")
            setLastError("Couldn't restart: \(error.localizedDescription)")
            return
        }
        allowTermination()
        NSApp.terminate(nil)
    }

    // MARK: - Onboarding

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: onboardingKey)
        showOnboarding = false
    }

    func replayOnboarding() {
        showOnboarding = true
        OnboardingWindowController.shared.show()
    }

    // MARK: - Targets / presets

    func applyPreset(_ preset: TargetPreset) {
        var existing = Set(config.targets.map { $0.pattern.lowercased() })
        for rule in preset.rules {
            let key = rule.pattern.lowercased()
            guard !existing.contains(key) else { continue }
            config.targets.append(rule)
            existing.insert(key)
        }
        commitConfig()
    }

    func clearTargets() {
        config.targets = []
        commitConfig()
    }

    /// Adds a host as an exact target (normalized, deduplicated).
    func addTarget(_ host: String) {
        let pattern = RoutingEngine.normalize(host)
        guard !pattern.isEmpty else { return }
        let key = pattern.lowercased()
        guard !config.targets.contains(where: { $0.pattern.lowercased() == key }) else { return }
        config.targets.append(TargetRule(pattern: pattern))
        commitConfig()
    }

    func removeTarget(id: UUID) {
        config.targets.removeAll { $0.id == id }
        commitConfig()
    }

    /// Opens Settings → Targets and highlights the given rule (used by the
    /// inspector when a host is covered by a wildcard rather than an exact rule).
    func revealTargetInSettings(_ rule: TargetRule) {
        revealTargetID = rule.id
        settingsSelection = .targets
        openSettings()
    }

    // MARK: - Apps

    /// Adds an app rule, or returns the existing one's id if the key already
    /// exists. Does not enable per-app routing on its own.
    @discardableResult
    func addAppRule(key: String, keyKind: AppRuleKeyKind, mode: AppRoutingMode) -> UUID? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = config.apps.rules.first(where: { $0.key == trimmed && $0.keyKind == keyKind }) {
            return existing.id
        }
        let rule = AppRule(key: trimmed, keyKind: keyKind, mode: mode)
        config.apps.rules.append(rule)
        commitConfig()
        return rule.id
    }

    func removeAppRule(id: UUID) {
        config.apps.rules.removeAll { $0.id == id }
        commitConfig()
    }

    /// Creates or updates the rule for an app key and turns per-app routing on.
    /// Used by the menu-bar control, where choosing a mode is a deliberate act.
    func upsertAppRule(key: String, keyKind: AppRuleKeyKind, mode: AppRoutingMode) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = config.apps.rules.firstIndex(where: { $0.key == trimmed && $0.keyKind == keyKind }) {
            config.apps.rules[index].mode = mode
            config.apps.rules[index].enabled = true
        } else {
            config.apps.rules.append(AppRule(key: trimmed, keyKind: keyKind, mode: mode))
        }
        config.apps.enabled = true
        commitConfig()
    }

    func removeAppRule(key: String, keyKind: AppRuleKeyKind) {
        config.apps.rules.removeAll { $0.key == key && $0.keyKind == keyKind }
        commitConfig()
    }

    func appRule(forKey key: String, keyKind: AppRuleKeyKind) -> AppRule? {
        config.apps.rules.first { $0.key == key && $0.keyKind == keyKind }
    }

    /// Opens Settings → Apps and highlights the given rule.
    func revealAppInSettings(_ id: UUID) {
        revealAppRuleID = id
        settingsSelection = .apps
        openSettings()
    }

    /// Opens the SwiftUI Settings window (reusing the menu-item sendAction
    /// dance, since `showSettingsWindow:` is a no-op).
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        guard let item = Self.settingsMenuItem(), let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.title.contains("Settings") }) {
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    private static func settingsMenuItem() -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            if let match = submenu.items.first(where: {
                $0.action != nil && ($0.title == "Settings…" || $0.title.hasPrefix("Settings"))
            }) {
                return match
            }
        }
        return nil
    }

    // MARK: - Tunnel

    func restartTunnel() {
        if config.tunnel.mode == .managed {
            sshTunnel.restart()
        } else {
            tunnelSupervisor.restartTunnel()
        }
    }

    /// Synchronous SOCKS5 health probe on a background queue (for the
    /// onboarding "Test connection" button). Reports via `completion` on main.
    func testTunnel(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { completion(false); return }
        DispatchQueue.global(qos: .utility).async {
            let up = (try? SOCKS5Client.probe(serverHost: h, serverPort: port)) != nil
            DispatchQueue.main.async { completion(up) }
        }
    }

    // MARK: - Managed tunnel (SSH)

    func saveManagedPassword(_ password: String) {
        if password.isEmpty {
            SSHKeychain.shared.delete()
        } else {
            SSHKeychain.shared.save(password)
        }
    }

    func loadManagedPassword() -> String {
        SSHKeychain.shared.load() ?? ""
    }

    // MARK: - SwiftUI binding helpers

    func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { value in
                self.config[keyPath: keyPath] = value
                self.commitConfig()
            }
        )
    }

    func portBinding(_ keyPath: WritableKeyPath<AppConfig, UInt16>) -> Binding<Int> {
        Binding(
            get: { Int(self.config[keyPath: keyPath]) },
            set: { value in
                self.config[keyPath: keyPath] = UInt16(clamping: value)
                self.commitConfig()
            }
        )
    }

    /// What quit should do with the system proxy / recovery state. Chosen
    /// before touching anything so a stale snapshot can never be restored over
    /// the user's current settings (LC-08).
    private enum QuitAction {
        case restore
        case discardStale
        case keepRecovery
        case nothing
    }

    /// Best-effort restore invoked on quit. Uses the persisted snapshot (disk)
    /// so it is correct even if quit races the background enable/disable.
    ///
    /// Serialized on `workQueue` so an in-flight `enable()`/`disable()` cannot
    /// apply the proxy *after* this restore. The snapshot and the armed watchdog
    /// are only cleared once a restore has actually succeeded; otherwise they
    /// stay so the watchdog repairs the proxy moments after the process exits.
    func shutdownForQuit() {
        // Demo/screenshot builds never touched the system proxy, the watchdog,
        // or the SSH runner, so quit must not either (disarming here would
        // clear the real app's watchdog marker).
        if DemoMode.isEnabled { return }
        integration.stop()
        // A queued backoff retry must never run during/after quit.
        enableRetry?.cancel()
        enableRetry = nil
        // Flush the debounced config write before blocking main on
        // `workQueue`: `scheduleSave`'s item runs on main, so the synchronous
        // block below would otherwise strand an edit made in the last 500 ms
        // and the process would exit with the previous config on disk (TC-18).
        saveDebounce?.cancel()
        saveDebounce = nil
        if configStore.loadFailed {
            let reason = configStore.loadError ?? "unknown error"
            Log.app.error("shutdownForQuit(): config was not loaded successfully; the store will refuse to overwrite it: \(reason, privacy: .public)")
        }
        configStore.config = config
        // Captured on main, before blocking on `workQueue`: main may mutate
        // `config` while quit is in flight (LC-20).
        let cfg = config
        workQueue.sync {
            var snap = configStore.loadSnapshot() ?? snapshot
            if snap?.isEmpty == true { snap = nil }
            let appliedThisSession = appliedPort != 0
            // Never delegate to a watchdog that was never installed (LC-12).
            let canDelegateToWatchdog = cfg.system.crashWatchdog && WatchdogController.isInstalled

            // Decide ownership *before* touching anything: only this session's
            // apply, or a proxy that provably points at us, justifies a restore.
            let action: QuitAction
            if appliedThisSession {
                action = .restore
            } else if snap != nil {
                switch systemProxyManager.proxyCheck(port: 0) {
                case .ours:
                    action = .restore
                    Log.app.notice("shutdownForQuit(): found our proxy from an earlier session; recovering")
                case .clean:
                    action = .discardStale
                    Log.app.notice("shutdownForQuit(): proxy is clean and this session never applied routing; discarding the stale snapshot")
                case .unknown:
                    action = .keepRecovery
                    Log.app.error("shutdownForQuit(): cannot determine the system proxy state; keeping snapshot + watchdog armed")
                }
            } else {
                switch systemProxyManager.proxyCheck(port: 0) {
                case .clean:
                    action = .nothing
                case .ours, .unknown:
                    // No snapshot to restore from; leave recovery to the
                    // watchdog rather than touching a possible user proxy.
                    action = .keepRecovery
                    Log.app.notice("shutdownForQuit(): local/unknown proxy without a snapshot; leaving the watchdog armed")
                }
            }

            var restored = false
            if case .restore = action {
                // `restoreOnQuit` only controls the synchronous quit-path
                // restore; an installed watchdog restores moments after exit.
                // Without one, skipping the restore would leave the machine
                // pointing at a dead 127.0.0.1.
                if cfg.system.restoreOnQuit || !canDelegateToWatchdog {
                    Log.app.notice("shutdownForQuit(): restoring system proxy")
                    do {
                        if let snap {
                            // Prompt-free: no admin dialog during quit/logout.
                            try systemProxyManager.restoreWithoutPrompt(snapshot: snap)
                            let sweepPort = appliedPort != 0 ? appliedPort : cfg.proxy.port
                            systemProxyManager.clearUnsnapshottedLocalProxies(snapshot: snap, port: sweepPort)
                            restored = true
                        } else if let services = systemProxyManager.listServicesChecked(), !services.isEmpty {
                            try systemProxyManager.clearWithoutPrompt(services: services)
                            restored = true
                        } else {
                            Log.app.error("shutdownForQuit(): cannot read the network service list; not clearing the system proxy")
                        }
                    } catch {
                        Log.app.error("shutdownForQuit(): restore failed; keeping snapshot + watchdog armed: \(error.localizedDescription)")
                    }
                } else {
                    Log.app.notice("shutdownForQuit(): delegating restore to the installed watchdog")
                }
            }

            self.removeAppliedShellEnv(currentRCFiles: cfg.system.managedShellRcs)
            // `remove()` is a no-op unless a snapshot exists, so it can never
            // clobber a proxy env we did not publish.
            guiEnvInjector.remove()
            appliedGuiEnv = false

            switch action {
            case .restore where restored:
                clearSnapshotBestEffort()
                WatchdogController.disarm()
                // Keep `wasOnKey` so the next launch re-enables routing if it was
                // on when we quit. Only an explicit `disable()` clears it.
                proxyServer.stop()
            case .restore:
                // Restore failed, or it was delegated: leave the snapshot and
                // the armed watchdog so the proxy is repaired after exit.
                if snap != nil { UserDefaults.standard.set(true, forKey: self.wasOnKey) }
                Log.app.notice("shutdownForQuit(): leaving snapshot + watchdog armed to restore")
            case .discardStale, .nothing:
                // The proxy is provably clean (or nothing was applied): the old
                // "original" must not survive to overwrite a later user change.
                // Keep the intent, though: only an explicit "off" clears it, and
                // a background enable that failed before applying should retry
                // on the next launch.
                clearSnapshotBestEffort()
                WatchdogController.disarm()
                proxyServer.stop()
            case .keepRecovery:
                if snap != nil { UserDefaults.standard.set(true, forKey: self.wasOnKey) }
                Log.app.notice("shutdownForQuit(): keeping recovery state; leaving watchdog armed")
            }

            telemetry.flushNow()
            // Drain any queued tunnel reconcile before the synchronous stop, so a
            // pending `apply` cannot respawn ssh after quit began (LC-20).
            tunnelSyncQueue.sync {}
            sshTunnel.stopNow()
        }
    }

    // MARK: - Login item

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            config.system.launchAtLogin = enabled
            commitConfig()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Enables/disables the crash watchdog. Installing/uninstalling the
    /// LaunchAgent is done here (not via the generic `binding`) so it happens
    /// once per toggle rather than on every keystroke.
    func setCrashWatchdog(_ enabled: Bool) {
        config.system.crashWatchdog = enabled
        if enabled {
            if state.isActive {
                WatchdogController.installIfNeeded()
                WatchdogController.arm(port: appliedPort != 0 ? appliedPort : config.proxy.port)
            }
        } else {
            WatchdogController.uninstall()
        }
        commitConfig()
    }

    // MARK: - Deferred authorization / helper status

    /// Clears a pending deferred retry after a successful mutation. With
    /// `only`, the state is cleared only when that intent is pending (a
    /// successful re-apply must not discard a pending disable).
    private func clearDeferredState(only intent: DeferredIntent? = nil) {
        let clear = { [weak self] in
            guard let self else { return }
            if let intent, self.deferredIntent != intent { return }
            self.deferredIntent = nil
            self.authorizationDeferred = false
            self.ensureDeferredRetryTimer()
        }
        if Thread.isMainThread { clear() } else { DispatchQueue.main.async(execute: clear) }
    }

    /// Records a deferral and exposes it to the UI. Automatic retries stay
    /// prompt-free; only the explicit Retry button may prompt.
    private func noteDeferredIfNeeded(_ error: Error, intent: DeferredIntent) {
        guard (error as? ProxyAuthorizationError)?.isDeferred == true else { return }
        let note = { [weak self] in
            guard let self else { return }
            // An explicit disable should not be overwritten by a deferred
            // rollback of the same operation.
            if self.deferredIntent == nil { self.deferredIntent = intent }
            self.authorizationDeferred = true
            Log.app.notice("deferred auth intent=\(intent == .enable ? "enable" : "disable")")
            self.ensureDeferredRetryTimer()
        }
        if Thread.isMainThread { note() } else { DispatchQueue.main.async(execute: note) }
    }

    private func retryDeferredGrant(promptAllowed: Bool) {
        guard let intent = deferredIntent else { return }
        guard SessionState.shared.isInteractive else {
            if promptAllowed {
                setLastError("Unlock the screen (and wake the Mac) to authorize this change.")
            }
            return
        }
        deferredIntent = nil
        authorizationDeferred = false
        ensureDeferredRetryTimer()
        Log.app.notice("deferred retry intent=\(intent == .enable ? "enable" : "disable") prompt=\(promptAllowed)")
        switch intent {
        case .enable:
            if state == .off {
                enable(userInitiated: promptAllowed)
            } else if state.isActive {
                reapplyAfterSystemChange(reason: "deferred retry")
            }
        case .disable:
            if state.isActive { disable(userInitiated: promptAllowed) }
        }
    }

    /// Starts a 2 s re-check while an auto-enable or deferred mutation is
    /// pending; stops as soon as neither is. This only ever calls the
    /// prompt-free `sessionBecameInteractive()` path, so it cannot raise a
    /// dialog while the screen is locked.
    private func ensureDeferredRetryTimer() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.ensureDeferredRetryTimer() }
            return
        }
        guard pendingAutoEnable || deferredIntent != nil else {
            deferredRetryTimer?.cancel()
            deferredRetryTimer = nil
            return
        }
        guard deferredRetryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.deferredRetryTick() }
        timer.resume()
        deferredRetryTimer = timer
    }

    private func deferredRetryTick() {
        guard pendingAutoEnable || deferredIntent != nil else {
            ensureDeferredRetryTimer()
            return
        }
        guard SessionState.shared.isInteractive else { return }
        sessionBecameInteractive()
        ensureDeferredRetryTimer()
    }

    /// Explicit user retry (menu/dashboard). This is the only deferred path that
    /// may prompt, and only because the user just clicked it.
    func retryDeferredApply() {
        SessionState.shared.noteUserAction()
        retryDeferredGrant(promptAllowed: true)
    }

    /// Prompt-free retry for an external caller. Same recovery, no user-action
    /// stamp and no prompt.
    func retryDeferredFromIntegration() {
        retryDeferredGrant(promptAllowed: false)
    }

    /// Launches auto-enable only when the session is interactive; otherwise it
    /// waits for unlock/wake instead of prompting at login.
    private func scheduleAutoEnableWhenInteractive() {
        guard !DemoMode.isEnabled else { return }
        if SessionState.shared.isInteractive {
            Log.app.notice("auto-enable: session is interactive")
            enable(userInitiated: false)
            return
        }
        pendingAutoEnable = true
        Log.app.notice("auto-enable: waiting for an interactive session")
        ensureDeferredRetryTimer()
    }

    /// Re-probes the privileged helper (XPC round trip) off the main thread.
    func refreshHelperState() {
        workQueue.async { [weak self] in
            guard let self else { return }
            let state = self.systemProxyManager.currentHelperState()
            DispatchQueue.main.async { self.helperState = state }
        }
    }

    /// Foreground Install Helper action (Settings). Never called from a
    /// background path: registration may show the SMAppService approval UI.
    func installHelper() {
        SessionState.shared.noteUserAction()
        do {
            try systemProxyManager.registerHelperFromUser()
            refreshHelperState()
        } catch {
            lastError = error.localizedDescription
            refreshHelperState()
        }
    }

    func openLoginItemsSettings() {
        systemProxyManager.openLoginItemsSettings()
    }

    /// 10 Hz telemetry flushing is only useful while something can observe it.
    /// When routing is off and no window is open, slow the flusher so App Nap
    /// can coalesce the wakeups.
    private func updateTelemetryFlusherMode() {
        let active = state.isActive || AppWindowTracker.shared.hasOpenWindow
        telemetry.setFlusherIdle(!active)
    }

    // MARK: - Internal

    /// Pure state transition for a tunnel up/down change.
    ///
    /// `.degraded` means one of two things: the tunnel is down, or a recovery
    /// (enable rollback / disable restore) failed. Only the first may be
    /// repaired by a tunnel flap; promoting a failed recovery to `.on` would
    /// claim ON while the system proxy is still inconsistent (LC-21).
    static func nextState(current: AppState, tunnelUp: Bool, recoveryFailed: Bool) -> AppState {
        switch current {
        case .on:
            return tunnelUp ? .on : .degraded
        case .degraded:
            return tunnelUp && !recoveryFailed ? .on : .degraded
        default:
            return current
        }
    }

    /// Main-thread-only: reads the published state and `recoveryFailed`
    /// together. The sink in `init` already delivers on main.
    private func recomputeStateAfterTunnelChange(up: Bool) {
        let next = Self.nextState(current: state, tunnelUp: up, recoveryFailed: recoveryFailed)
        if next != state { state = next }
    }

    private func setState(_ newState: AppState) {
        finalizeState(newState)
    }

    /// Publishes the state and (optionally) the recovery flag in one main-queue
    /// item, so they are never observed half-updated. `recoveryFailed: nil`
    /// keeps the current flag. Off-main callers are hopped to main; never use
    /// `DispatchQueue.main.sync` here (quit can hold main inside `workQueue`).
    private func finalizeState(_ newState: AppState, recoveryFailed: Bool? = nil) {
        let apply = { [weak self] in
            guard let self else { return }
            if let recoveryFailed { self.recoveryFailed = recoveryFailed }
            self.state = newState
            self.updateTelemetryFlusherMode()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func setLastError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.lastError = message }
    }
}
