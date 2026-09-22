import Foundation
import Darwin

// Standalone harness for the per-app identity layer (no XCTest / SPM).
//
// Build + run (see Tests/run-all.sh):
//   xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
//     Sources/Routing/AppResolver.swift Sources/Support/Log.swift \
//     Tests/AppIdentityHarness/main.swift -o /tmp/appidentity && /tmp/appidentity
//
// Validates the mechanism the per-app feature depends on: mapping an accepted
// loopback TCP connection to its originating PID (libproc scan) and turning that
// PID into an app identity (bundle id / executable path), including helper ->
// parent-app attribution. It does NOT touch the proxy or the system proxy.

setbuf(stdout, nil)

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

func tcpListen() -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var opt: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    let br = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    precondition(br == 0, "bind failed")
    precondition(listen(fd, 16) == 0, "listen failed")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return (fd, UInt16(bigEndian: addr.sin_port))
}

func peerPort(_ fd: Int32) -> UInt16 {
    var addr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
    }
    return UInt16(bigEndian: addr.sin_port)
}

/// Accept with a timeout so a failed client spawn cannot hang the harness.
func acceptWithTimeout(_ lfd: Int32, seconds: Int32) -> Int32? {
    var pfd = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
    let rc = poll(&pfd, 1, seconds * 1000)
    guard rc > 0 else { return nil }
    var addr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let cfd = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(lfd, $0, &len) }
    }
    return cfd >= 0 ? cfd : nil
}

func makeBundle(root: String, bundleId: String, name: String) {
    let contents = root + "/Contents"
    try? FileManager.default.createDirectory(atPath: contents + "/MacOS", withIntermediateDirectories: true)
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>\(bundleId)</string>
    <key>CFBundleName</key><string>\(name)</string>
    </dict></plist>
    """
    try? plist.write(toFile: contents + "/Info.plist", atomically: true, encoding: .utf8)
}

// MARK: - Client mode (spawned by the tests below)

if let idx = CommandLine.arguments.firstIndex(of: "--client"), idx + 1 < CommandLine.arguments.count {
    let port = UInt16(CommandLine.arguments[idx + 1])!
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if rc != 0 { exit(2) }
    Thread.sleep(forTimeInterval: 3)
    close(fd)
    exit(0)
}

let tmp = NSTemporaryDirectory() + "AppIdentityHarness-\(getpid())"
try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: tmp) }

print("== enclosingBundle (pure) ==")
let fooApp = tmp + "/Foo.app"
makeBundle(root: fooApp, bundleId: "com.example.foo", name: "Foo")
let fooInfo = AppResolver.enclosingBundle(path: fooApp + "/Contents/MacOS/foo")
check("plain app bundle resolved", fooInfo?.bundleId == "com.example.foo")
check("bundle display name resolved", fooInfo?.displayName == "Foo")

let barApp = tmp + "/Bar.app"
makeBundle(root: barApp, bundleId: "com.example.bar", name: "Bar")
let helperApp = barApp + "/Contents/Frameworks/Bar Helper.app"
makeBundle(root: helperApp, bundleId: "com.example.bar.helper", name: "Bar Helper")
let nested = AppResolver.enclosingBundle(path: helperApp + "/Contents/MacOS/Bar Helper")
check("nested helper resolves to outermost app", nested?.bundleId == "com.example.bar")

let cloneApp = tmp + "/Clone.app.bundle"
makeBundle(root: cloneApp, bundleId: "com.example.clone", name: "Clone")
let cloneInfo = AppResolver.enclosingBundle(path: cloneApp + "/Contents/MacOS/clone")
check("code-sign-clone .app.bundle resolved", cloneInfo?.bundleId == "com.example.clone")

check("CLI path has no bundle", AppResolver.enclosingBundle(path: "/usr/bin/curl") == nil)

print("== helper path classification ==")
check("Frameworks helper is a helper",
      AppResolver.isHelperPath("/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"))
check("XPC service is a helper",
      AppResolver.isHelperPath("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"))
check("top-level app binary is not a helper",
      !AppResolver.isHelperPath("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))

print("== responsible-process API ==")
print("  responsible-process API available: \(AppResolver.responsibleProcessAPIAvailable)")
if AppResolver.responsibleProcessAPIAvailable {
    check("self is responsible for self", AppResolver.responsiblePid(getpid()) == getpid())
}

print("== libproc scan -> PID -> identity ==")
let resolver = AppResolver()
let exePath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
let exeName = (exePath as NSString).lastPathComponent

// 1. A bundle-less client: identity is the executable, no bundle id.
let plain = tcpListen()
let plainChild = Process()
plainChild.executableURL = URL(fileURLWithPath: exePath)
plainChild.arguments = ["--client", "\(plain.port)"]
try? plainChild.run()
if let cfd = acceptWithTimeout(plain.fd, seconds: 5) {
    let clientPort = peerPort(cfd)
    let identity = resolver.resolve(localPort: clientPort, proxyPort: plain.port)
    check("scan found the client PID", identity?.pid == plainChild.processIdentifier)
    check("executable name resolved", identity?.executableName == exeName)
    check("bundle-less client has no bundle id", identity?.bundleId == nil)
    check("display name falls back to executable name", identity?.displayName == exeName)
    let again = resolver.identity(forPid: plainChild.processIdentifier)
    check("cached identity is stable", again == identity)
    close(cfd)
} else {
    check("bundle-less client accepted", false)
}
plainChild.waitUntilExit()
close(plain.fd)

// 2. A client inside a fake .app: identity carries the bundle id.
let fakeExe = tmp + "/FakeClient.app/Contents/MacOS/FakeClient"
try? FileManager.default.createDirectory(atPath: (fakeExe as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
try? FileManager.default.copyItem(atPath: exePath, toPath: fakeExe)
makeBundle(root: tmp + "/FakeClient.app", bundleId: "com.example.fakeclient", name: "Fake Client")

let bundled = tcpListen()
let bundledChild = Process()
bundledChild.executableURL = URL(fileURLWithPath: fakeExe)
bundledChild.arguments = ["--client", "\(bundled.port)"]
try? bundledChild.run()
if let cfd = acceptWithTimeout(bundled.fd, seconds: 5) {
    let identity = resolver.resolve(localPort: peerPort(cfd), proxyPort: bundled.port)
    check("bundled client PID found", identity?.pid == bundledChild.processIdentifier)
    check("bundled client bundle id resolved", identity?.bundleId == "com.example.fakeclient")
    check("bundled client display name resolved", identity?.displayName == "Fake Client")
    close(cfd)
} else {
    check("bundled client accepted", false)
}
bundledChild.waitUntilExit()
close(bundled.fd)

print("== negative cases ==")
check("unmatched port pair resolves nil", resolver.resolve(localPort: 1, proxyPort: 1) == nil)
check("dead PID resolves nil", resolver.identity(forPid: 999_999) == nil)

print("")
if failures == 0 { print("All checks passed.") } else { print("\(failures) check(s) FAILED.") }
exit(failures == 0 ? 0 : 1)
