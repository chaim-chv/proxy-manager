import Foundation
import Darwin

// Standalone regression harness for the crash watchdog.
//
// Build (from the repo root):
//   xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
//     -framework AppKit -framework ServiceManagement \
//     Sources/Config/ConfigModels.swift Sources/Config/ConfigStore.swift \
//     Sources/Support/Log.swift Sources/Support/Watchdog.swift \
//     Sources/System/HelperProtocol.swift Sources/System/HelperXPCClient.swift \
//     Sources/System/SystemProxyManager.swift Sources/System/ShellEnvInjector.swift \
//     Sources/Socks/Socket.swift \
//     Tests/WatchdogHarness/main.swift -o /tmp/watchdog-harness && /tmp/watchdog-harness

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  PASS  \(message)")
    } else {
        failures += 1
        print("  FAIL  \(message)")
    }
}

// Same dispatch as the app: when launched as a LaunchAgent we must become the
// watchdog, not re-run the tests.
if CommandLine.arguments.contains("--watchdog") {
    Watchdog.run()
}

// Isolate any path-based work (the engine's directory watch) from the real app.
let tmpSupport = NSTemporaryDirectory() + "watchdog-harness-\(getpid())"
setenv("PROXYMANAGER_SUPPORT_DIR", tmpSupport, 1)
defer { try? FileManager.default.removeItem(atPath: tmpSupport) }

/// Mutable fake environment for the engine hooks.
final class Box {
    var state = WatchdogArmedState.disarmed
    var alive = true
    var snapshot: SystemProxySnapshot? = ["Wi-Fi": ServiceProxyState()]
    var proxyCheckResult: ProxyCheck = .ours
    var checkedPorts: [UInt16] = []
    var restoreError: Error?
    var restoreCalls = 0
    var clearError: Error?
    var clearCalls = 0
    var clearedPorts: [UInt16] = []
    var clearSnapshotCalls = 0
    var disarmCalls = 0
    var envRemoved = 0
    var restoreSem = DispatchSemaphore(value: 0)

    func hooks() -> WatchdogHooks {
        WatchdogHooks(
            readState: { [self] in state },
            isAlive: { [self] _ in alive },
            proxyCheck: { [self] port in
                checkedPorts.append(port)
                return proxyCheckResult
            },
            loadSnapshot: { [self] in snapshot },
            restore: { [self] _ in
                restoreCalls += 1
                if let restoreError { throw restoreError }
                restoreSem.signal()
            },
            clearLocalProxy: { [self] port in
                clearCalls += 1
                clearedPorts.append(port)
                if let clearError { throw clearError }
            },
            clearSnapshot: { [self] in clearSnapshotCalls += 1 },
            removeEnv: { [self] in envRemoved += 1 },
            disarm: { [self] in
                disarmCalls += 1
                state = .disarmed
            },
            log: { _ in }
        )
    }
}

func armed(pid: Int32, port: UInt16 = 8888) -> WatchdogArmedState {
    WatchdogArmedState(armed: true, pid: pid, port: port, updatedAt: 0)
}

print("watchdog: decision logic")
do {
    let box = Box()
    box.state = armed(pid: 999_999)
    box.alive = false
    let engine = WatchdogEngine(hooks: box.hooks())
    let restored = engine.tick()
    check(restored, "armed + app dead + localhost proxy -> restores")
    check(box.restoreCalls == 1, "restore called exactly once")
    check(box.envRemoved == 1, "shell env removed on restore")
    check(box.clearSnapshotCalls == 1, "clears the stale snapshot after a successful restore")
    check(box.disarmCalls == 1, "disarms after restore")
}

do {
    let box = Box()
    box.state = armed(pid: 1234)
    box.alive = true
    let engine = WatchdogEngine(hooks: box.hooks())
    check(!engine.tick(), "armed + app alive -> no restore")
    check(box.restoreCalls == 0, "restore not called while alive")
    check(box.disarmCalls == 0, "stays armed while alive")
}

do {
    let box = Box()
    box.state = .disarmed
    box.alive = false
    let engine = WatchdogEngine(hooks: box.hooks())
    check(!engine.tick(), "disarmed -> no restore")
    check(box.restoreCalls == 0, "restore not called when disarmed")
}

do {
    // LC-05: no snapshot is NOT evidence of a clean machine. If a local proxy is
    // still applied we must clear only the local services and then disarm.
    let box = Box()
    box.state = armed(pid: 999_999)
    box.alive = false
    box.snapshot = nil
    box.proxyCheckResult = .ours
    let engine = WatchdogEngine(hooks: box.hooks())
    check(engine.tick(), "no snapshot + local proxy -> clears and restores connectivity")
    check(box.checkedPorts == [0], "no snapshot path probes any local port")
    check(box.clearCalls == 1, "clears our local proxy exactly once")
    check(box.clearedPorts == [0], "clear hook asked for any local port")
    check(box.restoreCalls == 0, "no snapshot -> restore not called")
    check(box.clearSnapshotCalls == 1, "clears any stale snapshot after a successful local clear")
    check(box.disarmCalls == 1, "disarms after a successful clear")
    check(box.envRemoved == 1, "shell env removed after clear")
}

do {
    // LC-05: an unreadable proxy state must never disarm the watchdog.
    let box = Box()
    box.state = armed(pid: 999_999)
    box.alive = false
    box.snapshot = nil
    box.proxyCheckResult = .unknown
    let engine = WatchdogEngine(hooks: box.hooks())
    check(!engine.tick(), "no snapshot + unknown -> no restore")
    for _ in 0..<6 { _ = engine.tick() }
    check(box.clearCalls == 0, "does not clear on unknown state")
    check(box.clearSnapshotCalls == 0, "does not clear the snapshot on unknown state")
    check(box.disarmCalls == 0, "never disarms on unknown state")
    check(box.state.armed, "stays armed after repeated unknown reads")
}

do {
    // No snapshot + provably clean -> nothing to do, safe to disarm.
    let box = Box()
    box.state = armed(pid: 999_999)
    box.alive = false
    box.snapshot = nil
    box.proxyCheckResult = .clean
    let engine = WatchdogEngine(hooks: box.hooks())
    check(!engine.tick(), "no snapshot + clean -> nothing to restore")
    check(box.clearCalls == 0, "does not clear a clean proxy")
    check(box.restoreCalls == 0, "does not restore without a snapshot")
    check(box.clearSnapshotCalls == 1, "clears the snapshot after a proven clean state")
    check(box.disarmCalls == 1, "disarms when no snapshot and proxy is clean")
}

do {
    // LC-05: a failed clear leaves the machine broken; keep the watchdog armed.
    let box = Box()
    box.state = armed(pid: 999_999)
    box.alive = false
    box.snapshot = nil
    box.proxyCheckResult = .ours
    box.clearError = SocketError.message("networksetup failed")
    let engine = WatchdogEngine(hooks: box.hooks())
    check(!engine.tick(), "no snapshot + failed clear -> no success")
    for _ in 0..<6 { _ = engine.tick() }
    check(box.clearCalls == 7, "retries the clear")
    check(box.clearSnapshotCalls == 0, "keeps the snapshot when the clear keeps failing")
    check(box.disarmCalls == 0, "stays armed while the clear keeps failing")
    check(box.state.armed, "still armed after max clear attempts")
}

do {
    // LC-07: the applied proxy may be on the OLD port (9999 armed, 8888 live).
    // Probing only the armed port would look "clean"; any-port must restore.
    let box = Box()
    box.state = armed(pid: 999_999, port: 9999)
    box.alive = false
    box.snapshot = ["Wi-Fi": ServiceProxyState()]
    box.proxyCheckResult = .ours
    let engine = WatchdogEngine(hooks: box.hooks())
    check(engine.tick(), "armed on old port + any-port local proxy -> restores")
    check(box.checkedPorts == [0], "snapshot path probes any local port, not the armed port")
    check(box.restoreCalls == 1, "restore called despite the armed-port mismatch")
    check(box.clearSnapshotCalls == 1, "clears the snapshot after the successful restore")
    check(box.disarmCalls == 1, "disarms after the successful restore")
}

do {
    // LC-05 with a snapshot: unknown state proves nothing, so do not restore
    // (the snapshot may be unrelated) and never disarm.
    let box = Box()
    box.state = armed(pid: 999_999)
    box.alive = false
    box.snapshot = ["Wi-Fi": ServiceProxyState()]
    box.proxyCheckResult = .unknown
    let engine = WatchdogEngine(hooks: box.hooks())
    check(!engine.tick(), "snapshot + unknown -> no restore")
    for _ in 0..<6 { _ = engine.tick() }
    check(box.restoreCalls == 0, "does not restore on unknown state")
    check(box.clearSnapshotCalls == 0, "does not clear the snapshot on unknown state")
    check(box.disarmCalls == 0, "never disarms on unknown state with a snapshot")
    check(box.state.armed, "stays armed after repeated unknown reads")
}

do {
    // Idempotency: the proxy was already restored (e.g. the app died mid-disable).
    let box = Box()
    box.state = armed(pid: 999_999)
    box.alive = false
    box.proxyCheckResult = .clean
    let engine = WatchdogEngine(hooks: box.hooks())
    check(!engine.tick(), "proxy already clean -> no clobber")
    check(box.restoreCalls == 0, "does not restore over a non-localhost proxy")
    check(box.clearSnapshotCalls == 1, "clears the stale snapshot after finding a clean proxy")
    check(box.disarmCalls == 1, "disarms after finding a clean proxy")
}

do {
    // Retry on failure, and keep retrying (never give up permanently) so a
    // broken machine is not abandoned.
    let box = Box()
    box.state = armed(pid: 999_999)
    box.alive = false
    box.restoreError = SocketError.message("boom")
    let engine = WatchdogEngine(hooks: box.hooks())
    for _ in 0..<4 { _ = engine.tick() }
    check(box.restoreCalls == 4, "retries restore")
    check(box.disarmCalls == 0, "stays armed while retrying")
    _ = engine.tick()
    check(box.restoreCalls == 5, "5th attempt made")
    check(box.disarmCalls == 0, "does NOT disarm after max attempts")
    _ = engine.tick()
    check(box.restoreCalls == 6, "keeps retrying after max attempts")
    check(box.clearSnapshotCalls == 0, "never clears the snapshot while the restore fails")
    check(box.state.armed, "stays armed after failed restores")
}

print("watchdog: kqueue NOTE_EXIT detection")
do {
    let box = Box()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    box.state = armed(pid: child.processIdentifier)
    box.alive = true
    box.snapshot = ["Wi-Fi": ServiceProxyState()]

    // A 10 s safety tick: a restore faster than that can only come from the
    // kernel NOTE_EXIT event, not from polling.
    let realEngine = WatchdogEngine(hooks: WatchdogHooks(
        readState: { box.state },
        isAlive: { _ in box.alive },
        proxyCheck: { _ in .ours },
        loadSnapshot: { box.snapshot },
        restore: { _ in box.restoreCalls += 1; box.restoreSem.signal() },
        clearLocalProxy: { _ in box.clearCalls += 1 },
        clearSnapshot: { box.clearSnapshotCalls += 1 },
        removeEnv: { box.envRemoved += 1 },
        disarm: { box.disarmCalls += 1; box.state = .disarmed },
        log: { _ in }
    ), tickArmed: 10)
    Thread.detachNewThread { realEngine.run() }

    usleep(500_000)                         // let the loop register its watches
    box.alive = false                       // the app is gone...
    kill(child.processIdentifier, SIGKILL)  // ...and the kernel confirms it
    let got = box.restoreSem.wait(timeout: .now() + 2)
    check(got == .success, "NOTE_EXIT triggers restore well before the 10 s tick")
    check(box.restoreCalls == 1, "restore called once after the app dies")
    check(box.clearSnapshotCalls == 1, "snapshot cleared after the NOTE_EXIT restore")
    child.waitUntilExit()
}

print("watchdog: idle efficiency (must not busy-poll)")
do {
    let box = Box()
    box.state = armed(pid: getpid())   // alive for the whole measurement
    box.alive = true
    let engine = WatchdogEngine(hooks: box.hooks())
    Thread.detachNewThread { engine.run() }

    usleep(300_000)                    // settle
    func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + sys
    }
    let before = cpuSeconds()
    usleep(1_200_000)
    let after = cpuSeconds()
    let delta = after - before
    print(String(format: "  (idle CPU over 1.2 s: %.4f s)", delta))
    check(delta < 0.20, "idle watchdog consumes < 0.20 s CPU over 1.2 s")
}

print("watchdog: install detection")
do {
    // LC-12: quit may only delegate to a watchdog whose LaunchAgent is on disk
    // AND is armed for this process (a stale plist or another pid's state means
    // no running agent to delegate to).
    let dir = NSTemporaryDirectory() + "wd-installed-\(getpid())"
    setenv("PROXYMANAGER_LAUNCHAGENTS_DIR", dir, 1)
    WatchdogPaths.writeArmedState(.disarmed)
    check(!WatchdogController.isInstalled, "isInstalled is false when no plist exists")

    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let plist = URL(fileURLWithPath: dir).appendingPathComponent("com.proxymanager.watchdog.plist")
    try? "test".write(to: plist, atomically: true, encoding: .utf8)
    check(!WatchdogController.isInstalled, "isInstalled is false when the plist exists but state is disarmed")

    WatchdogPaths.writeArmedState(armed(pid: getpid(), port: 8888))
    check(WatchdogController.isInstalled, "isInstalled is true when the plist exists and state is armed for this pid")

    WatchdogPaths.writeArmedState(armed(pid: getpid() + 1, port: 8888))
    check(!WatchdogController.isInstalled, "isInstalled is false when the armed state belongs to another pid")

    WatchdogPaths.writeArmedState(armed(pid: getpid(), port: 8888))
    try? FileManager.default.removeItem(atPath: plist.path)
    check(!WatchdogController.isInstalled, "isInstalled is false when the plist is removed")

    WatchdogPaths.writeArmedState(.disarmed)
    try? FileManager.default.removeItem(atPath: dir)
    unsetenv("PROXYMANAGER_LAUNCHAGENTS_DIR")
}

print("watchdog: config backward compatibility")
do {
    let legacy = #"{"injectShellEnv":false,"launchAtLogin":true,"restoreOnQuit":true,"managedShellRcs":["~/.zshrc"]}"#
    let decoded = try? JSONDecoder().decode(SystemSettings.self, from: Data(legacy.utf8))
    check(decoded?.crashWatchdog == true, "legacy config defaults crashWatchdog to true")
    check(decoded?.launchAtLogin == true, "legacy config still decodes other fields")
}

// Touches launchd, so opt-in. Uses a temp LaunchAgents dir so the real
// ~/Library/LaunchAgents is never modified:
//   WD_TEST_AGENT=1 /tmp/watchdog-build/harness
if ProcessInfo.processInfo.environment["WD_TEST_AGENT"] == "1" {
    print("watchdog: LaunchAgent install/uninstall")
    func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
    let agentDir = NSTemporaryDirectory() + "wd-agent-\(getpid())"
    setenv("PROXYMANAGER_LAUNCHAGENTS_DIR", agentDir, 1)
    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    let plist = URL(fileURLWithPath: agentDir).appendingPathComponent("com.proxymanager.watchdog.plist")

    WatchdogController.installIfNeeded()
    check(FileManager.default.fileExists(atPath: plist.path), "plist written")
    check(runLaunchctl(["print", "gui/\(getuid())/com.proxymanager.watchdog"]) == 0,
          "agent bootstrapped")

    WatchdogController.uninstall()
    check(!FileManager.default.fileExists(atPath: plist.path), "plist removed on uninstall")
    check(runLaunchctl(["print", "gui/\(getuid())/com.proxymanager.watchdog"]) != 0,
          "agent booted out")
    try? FileManager.default.removeItem(atPath: agentDir)
}

print("")
if failures == 0 {
    print("✅ all watchdog tests passed")
    exit(0)
} else {
    print("❌ \(failures) watchdog test(s) failed")
    exit(1)
}
