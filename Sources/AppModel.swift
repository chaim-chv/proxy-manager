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

    let configStore: ConfigStore
    let telemetry: TelemetryStore
    let proxyServer: ProxyServer
    let tunnelSupervisor: TunnelSupervisor
    let sshTunnel: SSHTunnelRunner
    let systemProxyManager: SystemProxyManager
    let shellEnvInjector: ShellEnvInjector

    // The system-proxy snapshot of the user's ORIGINAL settings. Only ever
    // touched on `workQueue` (also persisted to disk via ConfigStore).
    private var snapshot: SystemProxySnapshot?
    private var cancellables = Set<AnyCancellable>()
    private let workQueue = DispatchQueue(label: "com.proxymanager.work", qos: .userInitiated)
    private let wasOnKey = "routingWasOn"

    // WorkQueue-only: the bind host/port currently applied to the system proxy.
    private var appliedPort: UInt16 = 0
    private var appliedBindHost: String = ""

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

        telemetry.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        tunnelSupervisor.start()
        syncManagedTunnel()
        observeSystemEvents()

        if UserDefaults.standard.bool(forKey: wasOnKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.enable()
            }
        }

        Log.app.notice("ProxyManager initialized (config v\(self.config.version))")
        applyAppearance()
        applyIconMode()
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
    /// activation policy (no Dock icon); the other modes are `.regular`. The
    /// status item's own visibility is owned by `StatusMenuController`, which
    /// observes `config`; this only switches the Dock presence.
    private func applyIconMode() {
        let policy: NSApplication.ActivationPolicy =
            config.system.iconMode == .menuBarOnly ? .accessory : .regular
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
                try self.systemProxyManager.applyProxy(services: self.systemProxyManager.listServices(), port: port)
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

    // MARK: - Toggle

    func toggle() {
        switch state {
        case .off: enable()
        case .on, .degraded: disable()
        default: break
        }
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
            let services = self.systemProxyManager.listServices()
            var proxyApplied = false
            do {
                try self.proxyServer.start()

                // Persist the user's ORIGINAL proxy state before touching it, so
                // a later crash/relaunch can still restore correctly.
                if let persisted = self.configStore.loadSnapshot() {
                    self.snapshot = persisted
                } else if self.snapshot == nil {
                    self.snapshot = self.systemProxyManager.captureSnapshot(services: services)
                    self.configStore.saveSnapshot(self.snapshot ?? [:])
                }

                // Arm the crash watchdog *before* touching the system proxy: if
                // we die at any point past here, the watchdog restores it.
                if cfg.system.crashWatchdog {
                    WatchdogController.installIfNeeded()
                    WatchdogController.arm(port: port)
                }

                // Set before applyProxy: a networksetup failure can happen partway
                // through (some services already modified), so the catch below must
                // roll back whenever we've started touching the system proxy.
                proxyApplied = true
                try self.systemProxyManager.applyProxy(services: services, port: port)

                if cfg.system.injectShellEnv {
                    self.shellEnvInjector.writeEnvFile(port: port, bindHost: bindHost, tunnelHost: cfg.tunnel.effectiveHost)
                    self.shellEnvInjector.install(rcFiles: cfg.system.managedShellRcs)
                }
                UserDefaults.standard.set(true, forKey: self.wasOnKey)
                self.appliedPort = port
                self.appliedBindHost = bindHost
                self.setState(self.tunnelSupervisor.isTunnelUp ? .on : .degraded)
                Log.app.notice("enable(): routing enabled (tunnelUp=\(self.tunnelSupervisor.isTunnelUp))")
            } catch {
                // Roll back so we never leave the system proxy dangling.
                Log.app.error("enable() failed, rolling back: \(error.localizedDescription)")
                var rolledBack = true
                if proxyApplied {
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
                    if cfg.system.injectShellEnv {
                        self.shellEnvInjector.remove(rcFiles: cfg.system.managedShellRcs)
                        self.shellEnvInjector.removeEnvFile()
                    }
                }
                if rolledBack {
                    self.snapshot = nil
                    self.configStore.clearSnapshot()
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
                    self.configStore.saveSnapshot(self.snapshot ?? [:])
                    self.setState(.degraded)
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
            let services = self.systemProxyManager.listServices()
            do {
                if let snap = self.snapshot {
                    try self.systemProxyManager.restore(snapshot: snap)
                } else {
                    try self.systemProxyManager.clearProxy(services: services)
                }
                self.snapshot = nil
                self.configStore.clearSnapshot()
                WatchdogController.disarm()
                self.appliedPort = 0
                self.appliedBindHost = ""
                if cfg.system.injectShellEnv {
                    self.shellEnvInjector.remove(rcFiles: cfg.system.managedShellRcs)
                    self.shellEnvInjector.removeEnvFile()
                }
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
            workQueue.async { [weak self] in
                self?.reapplyIfPortChanged(port: port, bindHost: bindHost, watchdog: watchdog)
            }
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
        proxyServer.update(settings: runtime)
        proxyServer.routingEngine.update(rules: config.targets)
    }

    /// Starts/stops the app-managed SSH tunnel to match the configured mode.
    private func syncManagedTunnel() {
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
        do {
            proxyServer.stop()
            try proxyServer.start()
            let services = systemProxyManager.listServices()
            // Re-arm with the new port before applying, so a crash mid-rebind is
            // still covered by the watchdog (it matches the configured port).
            if watchdog {
                WatchdogController.installIfNeeded()
                WatchdogController.arm(port: port)
            }
            try systemProxyManager.applyProxy(services: services, port: port)
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
                    try systemProxyManager.applyProxy(services: systemProxyManager.listServices(), port: oldPort)
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

    func resetAll() {
        configStore.reset()
        config = configStore.config
        commitConfig()
        telemetry.purge()
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

    /// Best-effort restore invoked on quit. Uses the persisted snapshot (disk)
    /// so it is correct even if quit races the background enable/disable.
    ///
    /// Serialized on `workQueue` so an in-flight `enable()`/`disable()` cannot
    /// apply the proxy *after* this restore. The snapshot and the armed watchdog
    /// are only cleared once a restore has actually succeeded; otherwise they
    /// stay so the watchdog repairs the proxy moments after the process exits.
    func shutdownForQuit() {
        workQueue.sync {
            let snap = configStore.loadSnapshot()
            guard snap != nil || proxyServer.isRunning else {
                WatchdogController.disarm()
                sshTunnel.stopNow()
                telemetry.flushNow()
                return
            }
            Log.app.notice("shutdownForQuit(): restoring system proxy")
            var restored = false
            if config.system.restoreOnQuit {
                do {
                    if let snap = snap {
                        try systemProxyManager.restore(snapshot: snap)
                    } else {
                        try systemProxyManager.clearProxy(services: systemProxyManager.listServices())
                    }
                    restored = true
                } catch {
                    Log.app.error("shutdownForQuit(): restore failed: \(error.localizedDescription)")
                }
            }
            if config.system.injectShellEnv {
                shellEnvInjector.remove(rcFiles: config.system.managedShellRcs)
                shellEnvInjector.removeEnvFile()
            }
            if restored {
                configStore.clearSnapshot()
                WatchdogController.disarm()
                UserDefaults.standard.set(false, forKey: wasOnKey)
                proxyServer.stop()
            } else {
                // Either restoreOnQuit is off or the restore failed: leave the
                // snapshot and the armed watchdog so the proxy is restored
                // moments after this process exits.
                Log.app.notice("shutdownForQuit(): leaving watchdog armed to restore")
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
                WatchdogController.arm(port: config.proxy.port)
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
