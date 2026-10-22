import Foundation
import Darwin

// Standalone harness for BoundedProcess (no XCTest / SPM).
//
// Only /bin/* helpers are used; nothing here touches networksetup, launchctl,
// osascript, the system proxy, or launchd. A timed-out `sleep` and a
// backgrounded child are killed and reaped here, so the harness leaves no
// processes behind.

setbuf(stdout, nil)

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

func isAlive(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return false }
    errno = 0
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

func waitUntilGone(_ pid: pid_t, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !isAlive(pid) { return true }
        usleep(20_000)
    }
    return !isAlive(pid)
}

print("== timeout returns promptly and kills the child ==")
do {
    let start = Date()
    let result = BoundedProcess.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.2)
    let elapsed = Date().timeIntervalSince(start)
    check("timedOut", result.timedOut)
    check("returns in under 1 s (actual \(String(format: "%.3f", elapsed)) s)", elapsed < 1)
    check("pid is valid", result.pid > 1)
    check("child is gone", waitUntilGone(result.pid, timeout: 1))
}

print("== normal exit captures stdout ==")
do {
    let result = BoundedProcess.run(executable: "/bin/echo", arguments: ["hello"], timeout: 5)
    check("exit status 0", result.status == 0)
    check("not timed out", !result.timedOut)
    check("stdout is hello", result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
}

print("== large stdout does not deadlock ==")
do {
    let start = Date()
    let script = "/usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' 'x'"
    let result = BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", script], timeout: 10)
    let elapsed = Date().timeIntervalSince(start)
    check("exit status 0", result.status == 0)
    check("not timed out", !result.timedOut)
    check("full 200000 bytes captured (actual \(result.stdoutData.count))", result.stdoutData.count == 200_000)
    check("returned well before the timeout (actual \(String(format: "%.3f", elapsed)) s)", elapsed < 5)
}

print("== timeout kills the whole process tree ==")
do {
    let result = BoundedProcess.run(executable: "/bin/sh",
                                    arguments: ["-c", "sleep 30 & echo $!; wait"],
                                    timeout: 0.3,
                                    killTreeOnTimeout: true)
    let firstLine = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
    let child = pid_t(firstLine) ?? 0
    check("timedOut", result.timedOut)
    check("child pid was printed (\(firstLine))", child > 1)
    check("backgrounded child is gone", waitUntilGone(child, timeout: 2))
}

print("== launch failure is reported, not thrown ==")
do {
    let result = BoundedProcess.run(executable: "/no/such/proxymanager-test-binary",
                                    arguments: [], timeout: 1)
    check("launchError is present", result.launchError != nil)
    check("status is -1", result.status == -1)
    check("not marked timedOut", !result.timedOut)
}

if failures == 0 {
    print("✅ all bounded-process tests passed")
    exit(0)
} else {
    print("❌ \(failures) bounded-process test(s) failed")
    exit(1)
}
