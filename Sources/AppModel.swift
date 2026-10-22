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

    // Held while routing is enabled so macOS App Nap cannot suspend the proxy.
    private var activityToken: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var workspaceObservers: [NSObjectProtocol] = []
    private let keychainStateLock = NSLock()
    private var lastTunnelMode: TunnelMode?
    private var lastManagedAuth: SSHAuthMethod?

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
            syncManagedTunnel()
            observeSystemEvents()

            if UserDefaults.standard.bool(forKey: wasOnKey) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.enable()
                }
            }
        }

        AppWindowTracker.shared.onChange = { [weak self] in
            self?.applyIconMode()
        }

        Log.app.notice("ProxyManager initialized (config v\(self.config.version))")
        applyAppearance()
        applyIconMode()
        DemoMode.apply(to: self)
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
            self?.reapplyAfterSystemChange(reason: "wake")
        }
        workspaceObservers.append(wake)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            self?.reapplyAfterSystemChange(reason: "network change")
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.proxymanager.pathmonitor"))
    }

    private func reapplyAfterSystemChange(reason: String) {
        guard state.isActive else { return }
        let port = config.proxy.port
        let bindHost = config.proxy.bindHost
        let watchdog = config.system.crashWatchdog
        Log.app.notice("re-applying proxy after \(reason)")
        workQueue.async { [weak self] in
            guard let self, self.state.isActive else { return }
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
                try self.systemProxyManager.applyProxy(services: services, port: port,
                                                       host: self.systemProxyHost(bindHost))
                self.appliedPort = port
                self.appliedBindHost = bindHost
            } catch {
                self.setLastError("Failed to re-apply proxy after \(reason): \(error.localizedDescription)")
                Log.app.error("re-apply after \(reason) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Prevents App Nap from suspending the proxy while routing is active.
    private func beginProxyActivity() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activityToken == nil else { return }
            self.activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Proxy routing is enabled")
        }
    }

    private func endProxyActivity() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let token = self.activityToken else { return }
            ProcessInfo.processInfo.endActivity(token)
            self.activityToken = nil
        }
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

    func toggle() {
        switch state {
        case .off: enable()
        case .on, .degraded: disable()
        default: break
        }
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

    func enable() {
        guard state == .off else { return }
        setState(.starting)
        beginProxyActivity()
        let cfg = config
        let port = cfg.proxy.port
        let bindHost = cfg.proxy.bindHost
        Log.app.notice("enable(): starting on \(bindHost):\(port)")

        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.syncManagedTunnel()
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
                try self.systemProxyManager.applyProxy(services: services, port: port,
                                                       host: self.systemProxyHost(bindHost))

                self.appliedPort = port
                self.appliedBindHost = bindHost
                self.syncShellEnv(tunnelHost: cfg.tunnel.effectiveHost,
                                  injectEnabled: cfg.system.injectShellEnv,
                                  rcFiles: cfg.system.managedShellRcs)
                self.syncGuiEnv(enabled: cfg.system.injectGuiEnv, tunnelHost: cfg.tunnel.effectiveHost)
                self.setState(self.tunnelSupervisor.isTunnelUp ? .on : .degraded)
                Log.app.notice("enable(): routing enabled (tunnelUp=\(self.tunnelSupervisor.isTunnelUp))")
            } catch {
                // Roll back so we never leave the system proxy dangling.
                Log.app.error("enable() failed, rolling back: \(error.localizedDescription)")
                if touchedSystemProxy {
                    var rolledBack = true
                    if let snap = self.snapshot {
                        do { try self.systemProxyManager.restore(snapshot: snap) }
                        catch {
                            rolledBack = false
                            Log.app.error("enable() rollback restore failed: \(error.localizedDescription)")
                        }
                    } else {
                        do { try self.systemProxyManager.clearProxy(services: services) }
                        catch {
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
                        UserDefaults.standard.set(false, forKey: self.wasOnKey)
                        WatchdogController.disarm()
                        self.proxyServer.stop()
                        self.endProxyActivity()
                        self.setState(.off)
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
                        self.setState(.degraded)
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
                        self.endProxyActivity()
                    }
                    // A listener kept alive here may be serving a dangling proxy
                    // from a previous crash, so report degraded rather than off.
                    self.setState(hasRecoverySnapshot ? .degraded : .off)
                    Log.app.error("enable(): failed before touching the system proxy; recovery state preserved")
                }
                self.setLastError(error.localizedDescription)
            }
        }
    }

    func disable() {
        guard state.isActive else { return }
        setState(.stopping)
        let cfg = config
        Log.app.notice("disable(): stopping")

        workQueue.async { [weak self] in
            guard let self = self else { return }
            let sweepPort = self.appliedPort != 0 ? self.appliedPort : cfg.proxy.port
            do {
                if let snap = self.snapshot {
                    try self.systemProxyManager.restore(snapshot: snap)
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
                    try self.systemProxyManager.clearProxy(services: services)
                }
                self.clearSnapshotBestEffort()
                WatchdogController.disarm()
                self.appliedPort = 0
                self.appliedBindHost = ""
                self.removeAppliedShellEnv(currentRCFiles: cfg.system.managedShellRcs)
                self.syncGuiEnv(enabled: false, tunnelHost: "")
                UserDefaults.standard.set(false, forKey: self.wasOnKey)
                self.proxyServer.stop()
                self.endProxyActivity()
                self.setState(.off)
                Log.app.notice("disable(): routing disabled")
            } catch {
                // Restore failed: keep the proxy running, the snapshot, and the
                // watchdog so the machine keeps working and can still recover.
                self.setLastError(error.localizedDescription)
                self.setState(.degraded)
                Log.app.error("disable() failed; keeping proxy + snapshot: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Config

    func commitConfig() {
        if DemoMode.isEnabled { return }
        syncProxySettings()
        syncManagedTunnel()
        scheduleSave()
        applyAppearance()
        applyIconMode()
        if !config.system.crashWatchdog {
            WatchdogController.uninstall()
        }
        // If routing is active and the bind port/host changed, re-apply live.
        if state.isActive {
            let port = config.proxy.port
            let bindHost = config.proxy.bindHost
            let watchdog = config.system.crashWatchdog
            let guiEnabled = config.system.injectGuiEnv
            let tunnelHost = config.tunnel.effectiveHost
            let shellEnabled = config.system.injectShellEnv
            let shellRcs = config.system.managedShellRcs
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

    /// Starts/stops the app-managed SSH tunnel to match the configured mode.
    private func syncManagedTunnel() {
        if DemoMode.isEnabled { return }
        let mode = config.tunnel.mode
        let auth = config.tunnel.managed.auth
        keychainStateLock.lock()
        let modeChanged = lastTunnelMode != mode
        let authChanged = lastManagedAuth != auth
        lastTunnelMode = mode
        lastManagedAuth = auth
        keychainStateLock.unlock()

        if mode == .managed {
            // Switching away from password auth must not leave the credential
            // in the Keychain.
            if auth == .key && (authChanged || modeChanged) {
                SSHKeychain.shared.delete()
            }
            sshTunnel.apply(config.tunnel.managed)
        } else {
            if modeChanged {
                SSHKeychain.shared.delete()
            }
            sshTunnel.stop()
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
            try systemProxyManager.applyProxy(services: services, port: port,
                                              host: systemProxyHost(bindHost))
            appliedPort = port
            appliedBindHost = bindHost
        } catch {
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
                    try systemProxyManager.applyProxy(services: services, port: oldPort,
                                                      host: systemProxyHost(oldBindHost))
                    if watchdog { WatchdogController.arm(port: oldPort) }
                    appliedPort = oldPort
                    appliedBindHost = oldBindHost
                }
            } catch {
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
        workQueue.sync {
            var snap = configStore.loadSnapshot() ?? snapshot
            if snap?.isEmpty == true { snap = nil }
            let appliedThisSession = appliedPort != 0
            // Never delegate to a watchdog that was never installed (LC-12).
            let canDelegateToWatchdog = config.system.crashWatchdog && WatchdogController.isInstalled

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
                if config.system.restoreOnQuit || !canDelegateToWatchdog {
                    Log.app.notice("shutdownForQuit(): restoring system proxy")
                    do {
                        if let snap {
                            // Prompt-free: no admin dialog during quit/logout.
                            try systemProxyManager.restoreWithoutPrompt(snapshot: snap)
                            let sweepPort = appliedPort != 0 ? appliedPort : config.proxy.port
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

            self.removeAppliedShellEnv(currentRCFiles: config.system.managedShellRcs)
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
                clearSnapshotBestEffort()
                WatchdogController.disarm()
                UserDefaults.standard.set(false, forKey: self.wasOnKey)
                proxyServer.stop()
            case .keepRecovery:
                if snap != nil { UserDefaults.standard.set(true, forKey: self.wasOnKey) }
                Log.app.notice("shutdownForQuit(): keeping recovery state; leaving watchdog armed")
            }

            telemetry.flushNow()
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

    // MARK: - Internal

    private func recomputeStateAfterTunnelChange(up: Bool) {
        switch state {
        case .on:
            if !up { setState(.degraded) }
        case .degraded:
            if up { setState(.on) }
        default:
            break
        }
    }

    private func setState(_ newState: AppState) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { [weak self] in self?.state = newState }
        }
    }

    private func setLastError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.lastError = message }
    }
}
