import Foundation

// Standalone harness for GuiEnvInjector (no XCTest / SPM).
//
// Build + run (see Tests/run-all.sh). It never touches the real GUI session:
// a fake `launchctl` runner keeps the environment in memory, so the test can
// assert exactly what would be set/unset and that the user's original values
// are snapshotted and restored.

setbuf(stdout, nil)

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

final class FakeLaunchctl {
    var env: [String: String] = [:]
    var calls: [[String]] = []

    func run(_ args: [String]) -> GuiEnvInjector.LaunchctlResult {
        calls.append(args)
        guard let verb = args.first else { return .init(status: 1, stdout: "") }
        switch verb {
        case "getenv":
            let key = args.count > 1 ? args[1] : ""
            return .init(status: 0, stdout: (env[key] ?? "") + "\n")
        case "setenv":
            if args.count >= 3 { env[args[1]] = args[2] }
            return .init(status: 0, stdout: "")
        case "unsetenv":
            if args.count >= 2 { env.removeValue(forKey: args[1]) }
            return .init(status: 0, stdout: "")
        default:
            return .init(status: 1, stdout: "")
        }
    }
}

let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("guienv-harness-\(getpid())", isDirectory: true)
let snapshotURL = tmpDir.appendingPathComponent("gui-env-snapshot.json")
try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmpDir) }

let managed = Set(GuiEnvInjector.managedKeys)
check("managed keys are the expected set",
      managed == Set(["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "WSS_PROXY", "NO_PROXY", "PROXY_MANAGER_ACTIVE"]))

print("== apply with a clean environment ==")
do {
    let fake = FakeLaunchctl()
    let injector = GuiEnvInjector(snapshotURL: snapshotURL, runner: fake.run)
    let ok = injector.apply(port: 8888, bindHost: "127.0.0.1", tunnelHost: "localhost")
    check("apply succeeds", ok)
    check("HTTP_PROXY set", fake.env["HTTP_PROXY"] == "http://127.0.0.1:8888")
    check("HTTPS_PROXY set", fake.env["HTTPS_PROXY"] == "http://127.0.0.1:8888")
    check("ALL_PROXY set", fake.env["ALL_PROXY"] == "http://127.0.0.1:8888")
    check("WSS_PROXY set (WebSocket clients)", fake.env["WSS_PROXY"] == "http://127.0.0.1:8888")
    check("NO_PROXY set", fake.env["NO_PROXY"] == "127.0.0.1,localhost,::1")
    check("PROXY_MANAGER_ACTIVE set", fake.env["PROXY_MANAGER_ACTIVE"] == "1")
    check("snapshot persisted", FileManager.default.fileExists(atPath: snapshotURL.path))

    injector.remove()
    check("remove unsets HTTP_PROXY", fake.env["HTTP_PROXY"] == nil)
    check("remove unsets WSS_PROXY", fake.env["WSS_PROXY"] == nil)
    check("remove unsets NO_PROXY", fake.env["NO_PROXY"] == nil)
    check("remove clears snapshot", !FileManager.default.fileExists(atPath: snapshotURL.path))
}

print("== pre-existing user proxy is restored ==")
do {
    let fake = FakeLaunchctl()
    fake.env = ["HTTPS_PROXY": "http://corp:3128", "NO_PROXY": "corp.local"]
    let injector = GuiEnvInjector(snapshotURL: snapshotURL, runner: fake.run)
    injector.apply(port: 8888, bindHost: "127.0.0.1", tunnelHost: "127.0.0.1")
    check("overwrites the user's HTTPS_PROXY while active",
          fake.env["HTTPS_PROXY"] == "http://127.0.0.1:8888")
    injector.remove()
    check("restores the user's HTTPS_PROXY", fake.env["HTTPS_PROXY"] == "http://corp:3128")
    check("restores the user's NO_PROXY", fake.env["NO_PROXY"] == "corp.local")
    check("unsets a var that had no prior value", fake.env["HTTP_PROXY"] == nil)
}

print("== a second apply never recaptures our own values ==")
do {
    let fake = FakeLaunchctl()
    fake.env = ["HTTPS_PROXY": "http://corp:3128"]
    let injector = GuiEnvInjector(snapshotURL: snapshotURL, runner: fake.run)
    injector.apply(port: 8888, bindHost: "127.0.0.1", tunnelHost: "")
    injector.apply(port: 9999, bindHost: "127.0.0.1", tunnelHost: "")
    check("second apply updates the live value", fake.env["HTTPS_PROXY"] == "http://127.0.0.1:9999")
    injector.remove()
    check("snapshot still holds the original, not ours",
          fake.env["HTTPS_PROXY"] == "http://corp:3128")
}

print("== remove without a snapshot is a no-op ==")
do {
    let fake = FakeLaunchctl()
    fake.env = ["HTTPS_PROXY": "http://user:1"]
    let injector = GuiEnvInjector(snapshotURL: snapshotURL, runner: fake.run)
    injector.remove()
    check("does not touch a proxy we never set", fake.env["HTTPS_PROXY"] == "http://user:1")
    check("makes no launchctl calls", fake.calls.isEmpty)
}

print("== invalid bind host is rejected ==")
do {
    let fake = FakeLaunchctl()
    let injector = GuiEnvInjector(snapshotURL: snapshotURL, runner: fake.run)
    let ok = injector.apply(port: 8888, bindHost: "bad; rm -rf /", tunnelHost: "")
    check("apply returns false", !ok)
    check("sets nothing", fake.env.isEmpty)
    check("writes no snapshot", !FileManager.default.fileExists(atPath: snapshotURL.path))
}

print("== wildcard bind + non-loopback tunnel host ==")
do {
    let fake = FakeLaunchctl()
    let injector = GuiEnvInjector(snapshotURL: snapshotURL, runner: fake.run)
    injector.apply(port: 8888, bindHost: "0.0.0.0", tunnelHost: "proxy.example")
    check("wildcard bind maps to 127.0.0.1", fake.env["HTTP_PROXY"] == "http://127.0.0.1:8888")
    check("tunnel host added to NO_PROXY",
          fake.env["NO_PROXY"] == "127.0.0.1,localhost,::1,proxy.example")
    injector.remove()
}

print("== an unchanged value set is not re-published ==")
do {
    let fake = FakeLaunchctl()
    let injector = GuiEnvInjector(snapshotURL: snapshotURL, runner: fake.run)
    injector.apply(port: 8888, bindHost: "127.0.0.1", tunnelHost: "")
    let afterFirst = fake.calls.count
    injector.apply(port: 8888, bindHost: "127.0.0.1", tunnelHost: "")
    check("second identical apply makes no calls", fake.calls.count == afterFirst)
    injector.remove()
}

print("")
if failures == 0 { print("PASS: gui env"); exit(0) }
else { print("FAIL: \(failures) gui-env check(s) failed"); exit(1) }
