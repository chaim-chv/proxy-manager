import Foundation
import AppKit
import Darwin

// MARK: - Armed state (written by the app, read by the watchdog)

/// Persisted "routing is on; if this process dies, restore the proxy" marker.
/// Written atomically by the app around `applyProxy`, read by the watchdog.
struct WatchdogArmedState: Codable {
    var armed: Bool
    var pid: Int32
    var port: UInt16
    var updatedAt: Double

    static let disarmed = WatchdogArmedState(armed: false, pid: 0, port: 0, updatedAt: 0)
}

// MARK: - Paths

/// Paths the watchdog needs. Deliberately independent of `ConfigStore` so the
/// watchdog process never loads config/telemetry. `PROXYMANAGER_SUPPORT_DIR`
/// overrides the base directory (test harness isolation).
enum WatchdogPaths {
    static var supportDir: URL {
        if let override = ProcessInfo.processInfo.environment["PROXYMANAGER_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProxyManager", isDirectory: true)
    }

    static var armedFile: URL { supportDir.appendingPathComponent("watchdog.json") }
    static var snapshotFile: URL { supportDir.appendingPathComponent("system-proxy-snapshot.json") }

    static var launchAgentsDir: URL {
        if let override = ProcessInfo.processInfo.environment["PROXYMANAGER_LAUNCHAGENTS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static var plistFile: URL {
        launchAgentsDir.appendingPathComponent("com.proxymanager.watchdog.plist")
    }

    static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ProxyManager-watchdog.log")
    }

    static func readArmedState() -> WatchdogArmedState {
        guard let data = try? Data(contentsOf: armedFile),
              let state = try? JSONDecoder().decode(WatchdogArmedState.self, from: data) else {
            return .disarmed
        }
        return state
    }

    static func writeArmedState(_ state: WatchdogArmedState) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? data.write(to: armedFile, options: .atomic)
    }
}

// MARK: - Controller (app side)

/// Installs/arms the watchdog LaunchAgent. All operations are best-effort: a
/// failure to install must never block enabling routing.
enum WatchdogController {
    static let label = "com.proxymanager.watchdog"

    private static var installedThisSession = false

    /// Registers the `--watchdog` LaunchAgent (once per app session). Requires
    /// no admin — a user LaunchAgent is loaded via `launchctl bootstrap gui/$UID`.
    static func installIfNeeded() {
        guard !installedThisSession else { return }

        let executable = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        guard !executable.isEmpty else {
            Log.app.error("watchdog: cannot resolve executable path; not installing")
            return
        }
        do {
            try FileManager.default.createDirectory(at: WatchdogPaths.launchAgentsDir,
                                                    withIntermediateDirectories: true)
            try plist(executablePath: executable).write(to: WatchdogPaths.plistFile, atomically: true, encoding: .utf8)
        } catch {
            // Do not latch: a later enable() may retry once the filesystem is OK.
            Log.app.error("watchdog: failed to write LaunchAgent plist: \(error.localizedDescription)")
            return
        }

        let uid = getuid()
        // Replace any stale registration, then load the fresh one.
        _ = launchctl(["bootout", "gui/\(uid)/\(label)"])
        if launchctl(["bootstrap", "gui/\(uid)", WatchdogPaths.plistFile.path]) {
            installedThisSession = true
            Log.app.notice("watchdog: LaunchAgent installed")
        } else {
            // Leave the latch unset so a later enable() retries the bootstrap.
            Log.app.error("watchdog: LaunchAgent bootstrap failed")
        }
    }

    /// Removes the LaunchAgent and disarms. Idempotent.
    static func uninstall() {
        guard installedThisSession || FileManager.default.fileExists(atPath: WatchdogPaths.plistFile.path) else { return }
        let uid = getuid()
        _ = launchctl(["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: WatchdogPaths.plistFile)
        writeArmedState(.disarmed)
        installedThisSession = false
        Log.app.notice("watchdog: LaunchAgent uninstalled")
    }

    /// Marks routing active for `port`; the watchdog will restore on crash.
    static func arm(port: UInt16) {
        writeArmedState(WatchdogArmedState(armed: true, pid: getpid(), port: port,
                                           updatedAt: Date().timeIntervalSince1970))
    }

    static func disarm() {
        writeArmedState(.disarmed)
    }

    static func writeArmedState(_ state: WatchdogArmedState) {
        WatchdogPaths.writeArmedState(state)
    }

    private static func plist(executablePath: String) -> String {
        let log = WatchdogPaths.logFile.path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscape(executablePath))</string>
                <string>--watchdog</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>10</integer>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(xmlEscape(log))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(log))</string>
        </dict>
        </plist>
        """
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

// MARK: - Engine

/// Injectable dependencies so the decision logic is unit-testable without
/// touching the real system proxy.
struct WatchdogHooks {
    var readState: () -> WatchdogArmedState
    var isAlive: (pid_t) -> Bool
    var proxyPointsAtLocalhost: (UInt16) -> Bool
    var loadSnapshot: () -> SystemProxySnapshot?
    var restore: (SystemProxySnapshot) throws -> Void
    var removeEnv: () -> Void
    var disarm: () -> Void
    var log: (String) -> Void
}

/// The watchdog's core. `tick()` is one reconcile pass (pure decision + hooks);
/// `run()` adds the kqueue event loop that wakes `tick()` without polling.
final class WatchdogEngine {
    private let hooks: WatchdogHooks
    private var attempts = 0
    private let maxAttempts = 5
    private let tickArmed: Int
    private let tickDisarmed: Int

    init(hooks: WatchdogHooks, tickArmed: Int = 15, tickDisarmed: Int = 120) {
        self.hooks = hooks
        self.tickArmed = tickArmed
        self.tickDisarmed = tickDisarmed
    }

    /// One reconcile pass. Returns true if it restored the system proxy.
    @discardableResult
    func tick() -> Bool {
        let state = hooks.readState()
        guard state.armed, !hooks.isAlive(state.pid) else { return false }
        return performRestore(port: state.port)
    }

    private func performRestore(port: UInt16) -> Bool {
        // A snapshot only exists while routing is (or was) applied, so it is
        // safe evidence that we — not the user — set the current proxy.
        guard let snapshot = hooks.loadSnapshot() else {
            hooks.log("no snapshot; nothing to restore")
            hooks.disarm()
            attempts = 0
            return false
        }
        guard hooks.proxyPointsAtLocalhost(port) else {
            hooks.log("system proxy already clean; disarming")
            hooks.disarm()
            attempts = 0
            return false
        }
        do {
            try hooks.restore(snapshot)
            hooks.removeEnv()
            hooks.disarm()
            attempts = 0
            hooks.log("restored system proxy after app exit (port \(port))")
            return true
        } catch {
            attempts += 1
            hooks.log("restore failed (attempt \(attempts)): \(error.localizedDescription)")
            if attempts >= maxAttempts {
                // Do NOT disarm: the machine is still broken, so keep retrying on
                // the next safety tick rather than giving up permanently.
                attempts = 0
                hooks.log("restore still failing after \(maxAttempts) attempts; will keep retrying (run ./revert.sh to fix manually)")
            }
            return false
        }
    }

    /// Event-driven loop: blocks in `kevent` until the app exits, the armed file
    /// changes, or the adaptive safety timeout elapses. No polling when idle.
    func run() -> Never {
        let kq = kqueue()
        guard kq >= 0 else {
            // kqueue unavailable: degrade to a low-frequency poll rather than dying.
            hooks.log("kqueue unavailable (\(errno)); polling")
            while true {
                _ = tick()
                sleep(5)
            }
        }

        var dirFd: Int32 = -1
        do {
            try FileManager.default.createDirectory(at: WatchdogPaths.supportDir, withIntermediateDirectories: true)
            dirFd = open(WatchdogPaths.supportDir.path, O_EVTONLY)
        } catch {
            dirFd = -1
        }
        if dirFd >= 0 {
            var ev = kevent(ident: UInt(dirFd), filter: Int16(EVFILT_VNODE),
                            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
                            fflags: UInt32(NOTE_WRITE | NOTE_DELETE | NOTE_RENAME),
                            data: 0, udata: nil)
            _ = kevent(kq, &ev, 1, nil, 0, nil)
        }

        var watchedPid: pid_t = 0

        while true {
            let state = hooks.readState()

            // Keep the process-exit watch in sync with the armed pid.
            if state.armed, state.pid != watchedPid {
                if watchedPid > 0 { removeProcWatch(kq, pid: watchedPid) }
                watchedPid = addProcWatch(kq, pid: state.pid) ? state.pid : 0
            } else if !state.armed, watchedPid > 0 {
                removeProcWatch(kq, pid: watchedPid)
                watchedPid = 0
            }

            // Fast path: already dead (also covers a missed NOTE_EXIT).
            if state.armed, !hooks.isAlive(state.pid) {
                _ = performRestore(port: state.port)
                if watchedPid > 0 {
                    removeProcWatch(kq, pid: watchedPid)
                    watchedPid = 0
                }
            }

            // Safety tick: short while armed (fast fallback), long while idle.
            let timeout = hooks.readState().armed ? tickArmed : tickDisarmed
            var ts = timespec(tv_sec: timeout, tv_nsec: 0)
            var events: [kevent] = Array(repeating: kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil), count: 8)
            let n = kevent(kq, nil, 0, &events, Int32(events.count), &ts)
            if n < 0, errno != EINTR {
                hooks.log("kevent error \(errno); backing off")
                sleep(1)
            }
        }
    }

    private func addProcWatch(_ kq: Int32, pid: pid_t) -> Bool {
        var ev = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC),
                        flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
                        fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        return kevent(kq, &ev, 1, nil, 0, nil) == 0
    }

    private func removeProcWatch(_ kq: Int32, pid: pid_t) {
        var ev = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC),
                        flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)
        _ = kevent(kq, &ev, 1, nil, 0, nil)
    }
}

// MARK: - Entry point

enum Watchdog {
    /// Runs the watchdog process. Never returns.
    static func run() -> Never {
        Log.app.notice("watchdog: started (pid \(getpid()))")
        WatchdogEngine(hooks: defaultHooks()).run()
    }

    /// Liveness check that is resilient to PID reuse: the pid must exist *and*
    /// still be the ProxyManager app.
    static func isAppAlive(_ pid: pid_t) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.proxymanager.app"
    }

    static func defaultHooks() -> WatchdogHooks {
        let proxy = SystemProxyManager()
        let store = ConfigStore.shared
        return WatchdogHooks(
            readState: { WatchdogPaths.readArmedState() },
            isAlive: { isAppAlive($0) },
            proxyPointsAtLocalhost: { proxy.currentProxyPointsAtLocalhost(port: $0) },
            loadSnapshot: { store.loadSnapshot() },
            restore: { try proxy.restoreWithoutPrompt(snapshot: $0) },
            removeEnv: {
                guard store.config.system.injectShellEnv else { return }
                let injector = ShellEnvInjector(configStore: store)
                injector.remove(rcFiles: store.config.system.managedShellRcs)
                injector.removeEnvFile()
            },
            disarm: { WatchdogController.disarm() },
            log: { Log.app.notice("watchdog: \($0, privacy: .public)") }
        )
    }
}
