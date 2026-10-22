import Foundation

// Standalone harness for ShellEnvInjector (no XCTest / SPM).
//
// Everything lives in a temporary directory: `ConfigStore(configURL:)` points
// `envDir` at that directory and every rc path is absolute, so the real
// `~/.zshrc` and `~/.config/proxy-manager` are never touched.

setbuf(stdout, nil)

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("shellenv-harness-\(getpid())", isDirectory: true)
try? fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

let store = ConfigStore(configURL: root.appendingPathComponent("config.json"))
let injector = ShellEnvInjector(configStore: store)
let envFile = store.envFileURL

func contents(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}
func isSymlink(_ path: String) -> Bool {
    (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
}
func modificationDate(_ path: String) -> Date? {
    (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}
func blockCount(_ text: String?) -> Int {
    guard let text else { return 0 }
    return text.components(separatedBy: ShellEnvInjector.blockStart).count - 1
}

check("env dir is isolated in the temp store", store.envDir.path.hasPrefix(root.path))

print("== install, remove, remove again ==")
do {
    let rc = root.appendingPathComponent("rc-basic")
    try "export EDITOR=vim\n".write(to: rc, atomically: true, encoding: .utf8)

    injector.writeEnvFile(port: 8888, bindHost: "127.0.0.1", tunnelHost: "localhost")
    injector.install(rcFiles: [rc.path])

    let env = contents(envFile)
    check("env.sh installed", fm.fileExists(atPath: envFile.path))
    check("env.sh uses the applied port", env?.contains("http://127.0.0.1:8888") == true)
    check("env.sh exports HTTPS_PROXY", env?.contains("export HTTPS_PROXY=") == true)
    check("env.sh keeps the marker line", env?.contains("PROXY_MANAGER_ACTIVE") == true)
    check("marker block installed", blockCount(contents(rc)) == 1)
    check("marker block contains the POSIX source line",
          contents(rc)?.contains("[ -f \"$HOME/.config/proxy-manager/env.sh\" ] && . \"$HOME/.config/proxy-manager/env.sh\"") == true)
    check("existing rc content preserved", contents(rc)?.contains("export EDITOR=vim") == true)

    injector.remove(rcFiles: [rc.path])
    check("marker block removed", blockCount(contents(rc)) == 0)
    check("existing rc content still present", contents(rc)?.contains("export EDITOR=vim") == true)
    check("env file removal is explicit", {
        injector.removeEnvFile()
        return !fm.fileExists(atPath: envFile.path)
    }())

    let before = contents(rc)
    let beforeDate = modificationDate(rc.path)
    Thread.sleep(forTimeInterval: 0.05)
    injector.remove(rcFiles: [rc.path])
    check("second remove does not change the content", contents(rc) == before)
    check("second remove does not rewrite the file", modificationDate(rc.path) == beforeDate)
}

print("== idempotent install ==")
do {
    let rc = root.appendingPathComponent("rc-idempotent")
    try "# existing\n".write(to: rc, atomically: true, encoding: .utf8)
    injector.install(rcFiles: [rc.path])
    injector.install(rcFiles: [rc.path])
    check("two installs leave exactly one block", blockCount(contents(rc)) == 1)
    injector.remove(rcFiles: [rc.path])
}

print("== symlinked rc file ==")
do {
    let target = root.appendingPathComponent("rc-target")
    try "alias ll='ls -l'\n".write(to: target, atomically: true, encoding: .utf8)
    let link = root.appendingPathComponent("rc-link")
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "rc-target")

    injector.install(rcFiles: [link.path])
    check("link is still a symlink after install", isSymlink(link.path))
    check("link still points at its target",
          (try? fm.destinationOfSymbolicLink(atPath: link.path)) == "rc-target")
    check("target received the block", blockCount(contents(target)) == 1)

    injector.remove(rcFiles: [link.path])
    check("target lost the block", blockCount(contents(target)) == 0)
    check("link is still a symlink after remove", isSymlink(link.path))
    check("target content preserved", contents(target)?.contains("alias ll='ls -l'") == true)
}

print("== dangling symlink ==")
do {
    let link = root.appendingPathComponent("rc-dangling")
    let missing = root.appendingPathComponent("rc-missing-target")
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "rc-missing-target")

    injector.install(rcFiles: [link.path])
    injector.remove(rcFiles: [link.path])
    check("dangling link is preserved", isSymlink(link.path))
    check("dangling target is not created", !fm.fileExists(atPath: missing.path))
}

print("== fish/csh rc files are left alone ==")
do {
    let fish = root.appendingPathComponent("config.fish")
    let fishContent = "set -gx EDITOR vim\nfunction fish_prompt; end\n"
    try fishContent.write(to: fish, atomically: true, encoding: .utf8)

    injector.install(rcFiles: [fish.path])
    check("fish config is unchanged", contents(fish) == fishContent)
    check("no POSIX block in fish config", blockCount(contents(fish)) == 0)

    injector.remove(rcFiles: [fish.path])
    check("remove leaves an untouched fish config unchanged", contents(fish) == fishContent)

    let tcsh = root.appendingPathComponent("login.tcsh")
    let tcshContent = "setenv EDITOR vim\n"
    try tcshContent.write(to: tcsh, atomically: true, encoding: .utf8)
    injector.install(rcFiles: [tcsh.path])
    check("tcsh config is unchanged", contents(tcsh) == tcshContent)
}

print("== shell detection ==")
check(".zshrc is supported", !ShellEnvInjector.isUnsupportedShell("/Users/x/.zshrc"))
check(".bashrc is supported", !ShellEnvInjector.isUnsupportedShell("/Users/x/.bashrc"))
check("config.fish is unsupported", ShellEnvInjector.isUnsupportedShell("/Users/x/.config/fish/config.fish"))
check("*.fish is unsupported", ShellEnvInjector.isUnsupportedShell("/Users/x/foo.fish"))
check("*.csh is unsupported", ShellEnvInjector.isUnsupportedShell("/Users/x/foo.csh"))
check("*.tcsh is unsupported", ShellEnvInjector.isUnsupportedShell("/Users/x/foo.tcsh"))

print("")
if failures == 0 { print("PASS: shell env"); exit(0) }
else { print("FAIL: \(failures) shell-env check(s) failed"); exit(1) }
