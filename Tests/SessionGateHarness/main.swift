import Foundation
import AppKit

// Regression harness for the authd-unlock-deadlock safety invariants:
//   * a background mutation can never spawn /usr/bin/osascript;
//   * a user-initiated mutation still defers when the session is locked/asleep;
//   * a user-initiated mutation in an interactive session is allowed to prompt;
//   * the watchdog's prompt-free restore/clear paths never prompt;
//   * no lifetime App Nap token is held (short tokens are paired).

setbuf(stdout, nil)

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name)")
        failures += 1
    }
}

func expectDeferred(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        check(false, "\(name) (expected ProxyAuthorizationError.deferred, got success)")
    } catch let error as ProxyAuthorizationError where error.isDeferred {
        check(true, name)
    } catch {
        check(false, "\(name) (got \(error))")
    }
}

func expectThrow(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        check(false, "\(name) (expected an error)")
    } catch {
        check(true, name)
    }
}

// MARK: - Fake process runner

final class Runner {
    var invoked: [(String, [String])] = []
    var networksetupFails = false
    var networkServices = ["Wi-Fi"]

    var osascriptCount: Int {
        invoked.filter { $0.0 == "/usr/bin/osascript" }.count
    }

    func failed(_ message: String) -> BoundedProcessResult {
        BoundedProcessResult(pid: 1, status: 1,
                             stdoutData: Data(),
                             stderrData: Data(message.utf8),
                             timedOut: false, launchError: nil)
    }

    func succeeded(_ stdout: String = "") -> BoundedProcessResult {
        BoundedProcessResult(pid: 1, status: 0,
                             stdoutData: Data(stdout.utf8),
                             stderrData: Data(),
                             timedOut: false, launchError: nil)
    }

    var processRunner: ProcessRunner {
        ProcessRunner { [weak self] executable, arguments, _, _ in
            guard let self else {
                return BoundedProcessResult(pid: 0, status: -1, stdoutData: Data(),
                                            stderrData: Data(), timedOut: false,
                                            launchError: "runner released")
            }
            self.invoked.append((executable, arguments))
            if executable == "/usr/bin/osascript" { return self.succeeded() }
            if arguments.first == "-listallnetworkservices" {
                return self.succeeded(self.networkServices.joined(separator: "\n") + "\n")
            }
            if self.networksetupFails { return self.failed("networksetup: permission denied") }
            return self.succeeded()
        }
    }
}

// MARK: - Session gating

let session = SessionState.shared

session.isInteractiveOverride = true
session.canPromptOverride = true
check(session.canPrompt, "interactive session can prompt")

session.canPromptOverride = nil
session.isInteractiveOverride = false
session.noteUserAction()
check(!session.canPrompt, "a recent user action alone cannot prompt while locked")

session.isInteractiveOverride = true
session.canPromptOverride = false
check(!session.canPrompt, "explicit canPrompt override wins")

do {
    let deferred = ProxyAuthorizationError.deferred(reason: "locked")
    check(deferred.localizedDescription.contains("retry"),
          "deferred error has a user-facing retry message")
}

// 1. Background (allowAdminPrompt: false) never prompts — even if it could.
do {
    let runner = Runner()
    runner.networksetupFails = true
    session.isInteractiveOverride = true
    session.canPromptOverride = true
    let manager = SystemProxyManager(runner: runner.processRunner, session: session,
                                     helperReady: { false })
    expectDeferred("background apply defers instead of prompting") {
        try manager.applyProxy(services: ["Wi-Fi"], port: 8888, allowAdminPrompt: false)
    }
    check(runner.osascriptCount == 0, "background apply spawned no osascript")
}

// 2. User-initiated but locked/asleep still defers.
do {
    let runner = Runner()
    runner.networksetupFails = true
    session.isInteractiveOverride = false
    session.canPromptOverride = false
    let manager = SystemProxyManager(runner: runner.processRunner, session: session,
                                     helperReady: { false })
    expectDeferred("user-initiated apply defers while the session is locked") {
        try manager.applyProxy(services: ["Wi-Fi"], port: 8888, allowAdminPrompt: true)
    }
    check(runner.osascriptCount == 0, "locked-session apply spawned no osascript")
}

// 3. User-initiated in an interactive session still reaches the admin path.
do {
    let runner = Runner()
    runner.networksetupFails = true
    session.isInteractiveOverride = true
    session.canPromptOverride = true
    let manager = SystemProxyManager(runner: runner.processRunner, session: session,
                                     helperReady: { false })
    do {
        try manager.applyProxy(services: ["Wi-Fi"], port: 8888, allowAdminPrompt: true)
        check(true, "user-initiated interactive apply succeeds via the admin fallback")
    } catch {
        check(false, "user-initiated interactive apply failed: \(error)")
    }
    check(runner.osascriptCount == 1, "admin fallback ran osascript exactly once")
}

// 4. Direct success never escalates, even for a user-initiated toggle.
do {
    let runner = Runner()
    session.isInteractiveOverride = true
    session.canPromptOverride = true
    let manager = SystemProxyManager(runner: runner.processRunner, session: session,
                                     helperReady: { false })
    do {
        try manager.applyProxy(services: ["Wi-Fi"], port: 8888, allowAdminPrompt: true)
        check(true, "direct apply succeeds prompt-free")
    } catch {
        check(false, "direct apply threw: \(error)")
    }
    check(runner.osascriptCount == 0, "direct apply spawned no osascript")
}

// 5. Watchdog restore/clear paths are prompt-free by construction.
do {
    let runner = Runner()
    runner.networksetupFails = true
    session.isInteractiveOverride = true
    session.canPromptOverride = true
    let manager = SystemProxyManager(runner: runner.processRunner, session: session,
                                     helperReady: { false })
    var snapshot = SystemProxySnapshot()
    snapshot["Wi-Fi"] = ServiceProxyState()
    expectThrow("prompt-free restore surfaces its error") {
        try manager.restoreWithoutPrompt(snapshot: snapshot)
    }
    expectThrow("prompt-free clear surfaces its error") {
        try manager.clearWithoutPrompt(services: ["Wi-Fi"])
    }
    check(runner.osascriptCount == 0, "watchdog restore/clear spawned no osascript")
}

// 6. Source invariants (no background prompt, no lifetime App Nap token).
//    Resolve paths from this file, not the process cwd, and treat an unreadable
//    file as a failure so a moved/renamed source cannot silently disable them.
/// Find the repository root by walking up from the compiled `#filePath` (when
/// absolute) or the current directory. Returns nil when the source tree is not
/// reachable, so the affected checks fail loudly instead of silently vanishing.
func findRepoRoot() -> URL? {
    var starts: [URL] = []
    if #filePath.hasPrefix("/") {
        starts.append(URL(fileURLWithPath: #filePath))
    }
    starts.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    for start in starts {
        var dir = start.hasDirectoryPath ? start : start.deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("Sources/System/SystemProxyManager.swift")
            if FileManager.default.fileExists(atPath: marker.path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
    }
    return nil
}

let repoRoot = findRepoRoot()
if repoRoot == nil { check(false, "could not locate the repository root for source checks") }

func source(_ relativePath: String) -> String {
    guard let repoRoot else { return "" }
    let url = repoRoot.appendingPathComponent(relativePath)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        check(false, "could not read \(relativePath) (looked in \(url.path))")
        return ""
    }
    return text
}

let managerSource = source("Sources/System/SystemProxyManager.swift")
check(managerSource.contains("error.isTransportFailure"),
      "SystemProxyManager only falls back on helper transport failures")
check(managerSource.contains("guard session.canPrompt"),
      "runAdmin is guarded by SessionState.canPrompt")
check(managerSource.contains("30, true"),
      "admin osascript uses a bounded 30 s timeout")
check(!managerSource.contains("try helper.register()"),
      "SystemProxyManager never registers the helper")

let appSource = source("Sources/AppModel.swift")
check(!appSource.contains("allowAdminPrompt: true"),
      "no unconditional admin prompt in AppModel")
check(!appSource.contains("beginActivity("),
      "AppModel holds no lifetime ProcessInfo activity token")
check(!appSource.contains("endProxyActivity"),
      "AppModel has no lifetime activity teardown left")
check(appSource.contains("allowAdminPrompt: userInitiated"),
      "call sites pass the explicit user-initiated intent")
check(appSource.contains("noteUserAction()"),
      "explicit user actions are recorded before prompting")
check(appSource.contains("ensureDeferredRetryTimer"),
      "a pending auto-enable/deferral has a bounded re-check")
check(appSource.contains("func setRoutingEnabled"),
      "the Settings master switch goes through one intent-aware path")
check(appSource.contains("scheduleEnableRetry"),
      "a failed background enable retries with backoff")
check(appSource.contains("recoverDanglingProxyIfNeeded"),
      "launch repairs a system proxy left pointing at us")
if let enableStart = appSource.range(of: "func enable(userInitiated: Bool = false)"),
   let disableStart = appSource.range(of: "func disable(userInitiated: Bool = false)") {
    let enableBody = appSource[enableStart.lowerBound..<disableStart.lowerBound]
    let intentWrite = enableBody.range(of: "set(true, forKey: wasOnKey)")
    let starting = enableBody.range(of: "setState(.starting)")
    check(intentWrite != nil && starting != nil && intentWrite!.lowerBound < starting!.lowerBound,
          "enable records the routing intent before changing state")
    check(!enableBody.contains("set(false, forKey:"),
          "a failed enable never clears the routing intent")
} else {
    check(false, "could not locate enable()/disable() for intent checks")
}

let watchdogSource = source("Sources/Support/Watchdog.swift")
check(!watchdogSource.contains("osascript"), "watchdog never references osascript")
check(!watchdogSource.contains("runAdmin"), "watchdog never references runAdmin")
check(watchdogSource.contains("restoreWithoutPrompt"),
      "watchdog still restores via the prompt-free path")

let sessionSource = source("Sources/System/SessionState.swift")
check(sessionSource.contains("com.apple.screenIsUnlocked"),
      "SessionState reacts to a plain lock-to-unlock")

// MARK: - Short-lived activity tokens

final class ActivityRecorder {
    var begins = 0
    var ends = 0
    var active = 0
    var doubleEnd = false
}

do {
    let recorder = ActivityRecorder()
    let factory = ActivityController.Factory(
        begin: { _ in
            recorder.begins += 1
            recorder.active += 1
            return NSObject()
        },
        end: { _ in
            if recorder.active <= 0 { recorder.doubleEnd = true }
            recorder.ends += 1
            recorder.active -= 1
        })
    let controller = ActivityController(factory: factory)
    check(!controller.isActive, "no token is held while idle")
    let value = controller.withActivity("test") { 42 }
    check(value == 42, "activity body returns its value")
    check(!controller.isActive, "token released after the body")
    check(recorder.begins == 1 && recorder.ends == 1, "begin/end paired exactly once")
    do {
        _ = try controller.withActivity("throwing") { () -> Int in
            throw NSError(domain: "test", code: 1)
        }
    } catch {}
    check(!controller.isActive && recorder.ends == 2 && !recorder.doubleEnd,
          "token released when the body throws")
}

// MARK: - Result

session.canPromptOverride = nil
session.isInteractiveOverride = nil

if failures == 0 {
    print("PASS: SessionGateHarness")
    exit(0)
} else {
    print("FAIL: SessionGateHarness (\(failures) failure(s))")
    exit(1)
}
