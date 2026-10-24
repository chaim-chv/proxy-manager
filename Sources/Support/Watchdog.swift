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

    static let maxLogBytes = 2 * 1024 * 1024

    /// Truncates a log in place when it exceeds `maxBytes`. launchd opens the
    /// log by path at spawn time, so replacing the file would leave the daemon
    /// writing to the unlinked inode; truncate keeps the same inode valid. If
    /// our own stdout/stderr is that file, rewind it too so the next write does
    /// not leave a sparse hole at the old offset.
    @discardableResult
    static func truncateIfLarger(_ url: URL, maxBytes: Int = maxLogBytes) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > maxBytes else { return false }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try? handle.synchronize()
        } catch {
            return false
        }
        rewindOwnStdioIfPointingAt(url)
        return true
    }

    private static func rewindOwnStdioIfPointingAt(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let targetDev = (attrs[.systemNumber] as? NSNumber)?.uint64Value,
              let targetIno = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { return }
        for fd in [STDOUT_FILENO, STDERR_FILENO] {
            var st = stat()
            guard fstat(fd, &st) == 0 else { continue }
            if UInt64(st.st_dev) == targetDev, UInt64(st.st_ino) == targetIno {
                _ = lseek(fd, 0, SEEK_SET)
            }
        }
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

    /// Whether a watchdog is installed **and** armed for this process. A plist
    /// alone is not enough: a failed/stale bootstrap leaves the file behind
    /// while no agent is running, and an armed state owned by another pid is
    /// stale from another instance. Quit must not delegate to either (LC-12).
    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: WatchdogPaths.plistFile.path) else { return false }
        let state = WatchdogPaths.readArmedState()
        return state.armed && state.pid == getpid()
    }

    /// Marks routing active for `port`; the watchdog will restore on crash.
    static func arm(port: UInt16) {
        writeArmedState(WatchdogArmedState(armed: true, pid: getpid(), port: port,
                                           updatedAt: Date().timeIntervalSince1970))
    }

    static func disarm() {
        writeArmedState(.disarmed)
    }

    /// Disarms only when the persisted state still belongs to the dead owner
    /// the watchdog restored. A relaunch/update may have armed a fresh pid/port
    /// in the meantime; that instance owns the state and must not be disarmed
    /// by the old restore (LC-13).
    static func disarmIfStill(pid: Int32, port: UInt16) {
        let state = WatchdogPaths.readArmedState()
        guard state.armed, state.pid == pid, state.port == port else {
            Log.app.notice("watchdog: not disarming; armed state changed (pid \(state.pid), port \(state.port))")
            return
        }
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
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
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
        let result = BoundedProcess.run(executable: "/bin/launchctl",
                                        arguments: args,
                                        timeout: 10)
        guard result.launchError == nil, !result.timedOut else { return false }
        return result.status == 0
    }
}

// MARK: - Engine

/// Injectable dependencies so the decision logic is unit-testable without
/// touching the real system proxy.
struct WatchdogHooks {
    var readState: () -> WatchdogArmedState
    var isAlive: (pid_t) -> Bool
    /// Tri-state so a failed `networksetup` read can never masquerade as clean.
    var proxyCheck: (UInt16) -> ProxyCheck
    var loadSnapshot: () -> SystemProxySnapshot?
    var restore: (SystemProxySnapshot) throws -> Void
    /// Clears only services provably pointing at our local proxy (no snapshot).
    var clearLocalProxy: (UInt16) throws -> Void
    /// Removes the persisted recovery snapshot once it is no longer needed.
    /// Called only after a proven clean state or a successful restore.
    var clearSnapshot: () -> Void
    /// Kills an `ssh -N -D` orphaned by a crash/force-quit. Only called once
    /// the proxy is provably safe (restored, cleared, or already clean).
    var reapTunnel: () -> Void
    var removeEnv: () -> Void
    /// Disarms only if the armed state still matches the dead owner.
    var disarmIfStill: (Int32, UInt16) -> Void
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
    private let now: () -> Date

    /// Retry cadence for a persistently failing restore: 15 s, 1 min, then
    /// every 5 min. A machine that stays broken must eventually recover without
    /// hammering `networksetup` (LC-18).
    static let retryDelays: [TimeInterval] = [15, 60, 300]

    /// Pure schedule helper: attempt 1 -> 15 s, 2 -> 60 s, 3+ -> 300 s.
    static func restoreDelay(attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return retryDelays[0] }
        return retryDelays[min(attempt - 1, retryDelays.count - 1)]
    }

    private var nextRetryAt: Date?
    private var exhaustedLogged = false
    private var observedPid: pid_t?

    init(hooks: WatchdogHooks, tickArmed: Int = 15, tickDisarmed: Int = 120,
         now: @escaping () -> Date = Date.init) {
        self.hooks = hooks
        self.tickArmed = tickArmed
        self.tickDisarmed = tickDisarmed
        self.now = now
    }

    /// One reconcile pass. Returns true if it restored the system proxy.
    @discardableResult
    func tick() -> Bool {
        let state = hooks.readState()
        observe(state)
        guard state.armed, !hooks.isAlive(state.pid) else { return false }
        return performRestore(expected: state)
    }

    /// A new arming (different app pid) or a disarm starts a fresh retry
    /// schedule: a 5-minute backoff left over from an old failure must never
    /// delay recovery for a later crash.
    private func observe(_ state: WatchdogArmedState) {
        guard state.armed else {
            observedPid = nil
            resetRetrySchedule()
            return
        }
        if observedPid != state.pid {
            observedPid = state.pid
            resetRetrySchedule()
        }
    }

    private func resetRetrySchedule() {
        attempts = 0
        exhaustedLogged = false
        nextRetryAt = nil
    }

    private func performRestore(expected: WatchdogArmedState) -> Bool {
        if let nextRetryAt, now() < nextRetryAt {
            return false
        }
        let port = expected.port

        // Re-read right before acting: a relaunch/Sparkle update can arm a new
        // pid/port while an old restore is pending. That new instance owns the
        // apply now, so restoring and clearing would clobber it (LC-13).
        guard stillCurrent(expected) else {
            hooks.log("armed state changed before restore (pid \(expected.pid), port \(port)); leaving it alone")
            resetRetrySchedule()
            return false
        }

        // Probe ANY local port, not merely the armed one: a failed re-apply or
        // an in-flight port change can leave the old port applied while the
        // watchdog was armed for the new one (LC-07). `.unknown` means at least
        // one read failed, so it is never evidence of a clean machine (LC-05).
        switch hooks.proxyCheck(0) {
        case .unknown:
            noteRetry("cannot determine system proxy state")
            return false
        case .clean:
            // Reads can be slow (networksetup); check again before cleanup so a
            // freshly armed owner is never cleared/disarmed.
            guard stillCurrent(expected) else {
                hooks.log("armed state changed during proxy check; skipping cleanup")
                resetRetrySchedule()
                return false
            }
            hooks.log("system proxy already clean; disarming")
            hooks.clearSnapshot()
            hooks.reapTunnel()
            hooks.disarmIfStill(expected.pid, expected.port)
            resetRetrySchedule()
            return false
        case .ours:
            // The probe is unbounded in principle; re-check before restoring.
            guard stillCurrent(expected) else {
                hooks.log("armed state changed during proxy check; skipping restore")
                resetRetrySchedule()
                return false
            }
        }

        // A snapshot only exists while routing is (or was) applied, so it is
        // safe evidence that we — not the user — set the current proxy.
        if let snapshot = hooks.loadSnapshot() {
            do {
                try hooks.restore(snapshot)
            } catch {
                noteRetry("restore failed: \(error.localizedDescription)")
                return false
            }
            // If a new instance armed while we restored, it owns the snapshot,
            // env, tunnel and armed state now: do not clear or disarm any of it.
            guard stillCurrent(expected) else {
                hooks.log("armed state changed during restore (pid \(expected.pid), port \(port)); skipping cleanup for the new owner")
                resetRetrySchedule()
                return true
            }
            hooks.removeEnv()
            hooks.clearSnapshot()
            hooks.reapTunnel()
            hooks.disarmIfStill(expected.pid, expected.port)
            resetRetrySchedule()
            hooks.log("restored system proxy after app exit (armed port \(port))")
            return true
        }

        // No snapshot: we can still recover, but only by clearing services that
        // provably point at our local proxy. Keep armed on any read/clear error.
        do {
            try hooks.clearLocalProxy(0)
        } catch {
            noteRetry("no snapshot; clearing local proxy failed: \(error.localizedDescription)")
            return false
        }
        guard stillCurrent(expected) else {
            hooks.log("armed state changed during local clear (pid \(expected.pid), port \(port)); skipping cleanup for the new owner")
            resetRetrySchedule()
            return true
        }
        hooks.removeEnv()
        hooks.clearSnapshot()
        hooks.reapTunnel()
        hooks.disarmIfStill(expected.pid, expected.port)
        resetRetrySchedule()
        hooks.log("no snapshot; cleared local system proxy after app exit")
        return true
    }

    /// True while the persisted state still names the dead owner we are acting
    /// for (same pid *and* port). Any change means another instance re-armed.
    private func stillCurrent(_ expected: WatchdogArmedState) -> Bool {
        let current = hooks.readState()
        return current.armed && current.pid == expected.pid && current.port == expected.port
    }

    /// Counts a transient failure but never gives up permanently: the machine is
    /// still broken, so the next safety tick must try again. After five attempts
    /// the per-attempt log stops (one "still failing" notice), while the delay
    /// stays capped at 5 minutes so a broken machine is retried forever.
    private func noteRetry(_ what: String) {
        if attempts < maxAttempts { attempts += 1 }
        if !exhaustedLogged {
            hooks.log("\(what) (attempt \(attempts))")
        }
        if attempts >= maxAttempts, !exhaustedLogged {
            exhaustedLogged = true
            hooks.log("\(what) still failing after \(maxAttempts) attempts; will keep retrying (run ./revert.sh to fix manually)")
        }
        let delay = Self.restoreDelay(attempt: attempts)
        nextRetryAt = now().addingTimeInterval(delay)
        hooks.log("next restore retry in \(Int(delay))s")
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
            observe(state)

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
                _ = performRestore(expected: state)
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
        if WatchdogPaths.truncateIfLarger(WatchdogPaths.logFile) {
            Log.app.notice("watchdog: rotated log at startup")
        }
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
            proxyCheck: { proxy.proxyCheck(port: $0) },
            loadSnapshot: { store.loadSnapshot() },
            restore: { try proxy.restoreWithoutPrompt(snapshot: $0) },
            clearLocalProxy: { try proxy.clearLocalProxies(port: $0) },
            clearSnapshot: {
                // Best effort: if the file cannot be removed, move it aside so
                // a later enable cannot load it as the user's original state.
                if !store.clearSnapshot() {
                    _ = store.quarantineSnapshot()
                }
            },
            reapTunnel: {
                // A crash leaves the managed `ssh -N -D` child running; the
                // watchdog reaps it after the proxy is safe again.
                SSHTunnelRunner.reapStaleProcess()
            },
            removeEnv: {
                // Always remove our marker blocks + env file. The captured
                // config may be stale (the user could have changed or disabled
                // injection after this watchdog started), so never gate cleanup
                // on it; only *adding* is config-gated (LC-18).
                let injector = ShellEnvInjector(configStore: store)
                var rcFiles = ShellEnvInjector.defaultRCFiles
                for rc in store.config.system.managedShellRcs where !rcFiles.contains(rc) {
                    rcFiles.append(rc)
                }
                injector.remove(rcFiles: rcFiles)
                injector.removeEnvFile()
                // No-op unless we published it (guarded by the persisted snapshot).
                GuiEnvInjector(snapshotURL: store.guiEnvSnapshotURL).remove()
            },
            disarmIfStill: { pid, port in WatchdogController.disarmIfStill(pid: pid, port: port) },
            log: { Log.app.notice("watchdog: \($0, privacy: .public)") }
        )
    }
}
