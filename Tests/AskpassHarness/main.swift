import Foundation
import Darwin

// Standalone regression harness for the managed-tunnel askpass lifecycle (TC-08)
// and the bounded stderr tail / exit drain (TC-09, TC-11).
//
// Build (from the repo root):
//   xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
//     Sources/Config/ConfigModels.swift Sources/Support/Log.swift \
//     Sources/Tunnel/SSHKeychain.swift Sources/Tunnel/SSHTunnelRunner.swift \
//     -framework Security Tests/AskpassHarness/main.swift -o /tmp/askpass-harness
//
// Everything happens under an isolated temp root: no real ssh, no app data.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  PASS  \(message)")
    } else {
        failures += 1
        print("  FAIL  \(message)")
    }
}

let fm = FileManager.default
let root = fm.temporaryDirectory
    .appendingPathComponent("askpass-harness-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                            isDirectory: true)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func makeDir(_ name: String, age: TimeInterval) -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try! fm.createDirectory(at: url, withIntermediateDirectories: true)
    try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                          ofItemAtPath: url.path)
    return url
}

func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

print("== stale askpass dir sweep ==")
let oldDir = makeDir("proxymanager-ssh-old-\(UUID().uuidString)", age: 600)
let freshDir = makeDir("proxymanager-ssh-new-\(UUID().uuidString)", age: 0)
let currentDir = makeDir("proxymanager-ssh-current-\(UUID().uuidString)", age: 600)
let unrelatedDir = makeDir("unrelated-old-\(UUID().uuidString)", age: 600)
let prefixedFile = root.appendingPathComponent("proxymanager-ssh-file-\(UUID().uuidString)")
try! Data("not a dir".utf8).write(to: prefixedFile)
try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-600)],
                      ofItemAtPath: prefixedFile.path)

SSHTunnelRunner.sweepStaleAskpassDirs(olderThan: 300, in: root, excluding: currentDir)

check(!exists(oldDir), "old proxymanager-ssh dir removed")
check(exists(freshDir), "fresh proxymanager-ssh dir kept")
check(exists(currentDir), "current dir is never swept (excluded)")
check(exists(unrelatedDir), "unrelated old dir kept")
check(exists(prefixedFile), "non-directory with the prefix kept")

print("== generated askpass script ==")
let oddPath = root.appendingPathComponent("it's a dir").appendingPathComponent("secret")
let script = SSHTunnelRunner.askpassScript(secretPath: oddPath.path)
let quoted = "'" + oddPath.path.replacingOccurrences(of: "'", with: "'\\''") + "'"

check(script.hasPrefix("#!/bin/sh\n"), "script is POSIX sh")
check(script.contains("secret=\(quoted)"), "secret path is single-quote escaped and assigned")
check(script.contains("trap 'rm -f \"$secret\"' EXIT INT TERM"), "trap removes the secret on EXIT/INT/TERM")
check(script.contains("/bin/cat \"$secret\""), "script cats the secret")
check(script.contains("'\\''"), "embedded single quote is escaped")

func runScript(_ script: String, secretPath: String) -> (status: Int32, stdout: Data) {
    let dir = URL(fileURLWithPath: secretPath).deletingLastPathComponent()
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let helper = dir.appendingPathComponent("askpass.sh")
    try! script.write(to: helper, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [helper.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try! p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

print("== script behaviour (no ssh) ==")
let okDir = root.appendingPathComponent("run-ok-\(UUID().uuidString)", isDirectory: true)
let okSecret = okDir.appendingPathComponent("secret")
try! fm.createDirectory(at: okDir, withIntermediateDirectories: true)
try! Data("hunter2".utf8).write(to: okSecret)
try! fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: okSecret.path)
let okResult = runScript(SSHTunnelRunner.askpassScript(secretPath: okSecret.path), secretPath: okSecret.path)
check(okResult.status == 0, "helper exits 0 when the secret is readable")
check(String(data: okResult.stdout, encoding: .utf8) == "hunter2", "helper prints the secret")
check(!exists(okSecret), "helper deletes the secret after a successful cat")

let badDir = root.appendingPathComponent("run-bad-\(UUID().uuidString)", isDirectory: true)
let badSecret = badDir.appendingPathComponent("secret")
try! fm.createDirectory(at: badDir, withIntermediateDirectories: true)
try! Data("x".utf8).write(to: badSecret)
try! fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: badSecret.path)
if geteuid() == 0 {
    print("  SKIP  unreadable secret (running as root)")
} else {
    let badResult = runScript(SSHTunnelRunner.askpassScript(secretPath: badSecret.path), secretPath: badSecret.path)
    check(badResult.status != 0, "helper reports failure when cat fails")
    check(!exists(badSecret), "helper still deletes the secret when cat fails")
}

print("== bounded stderr tail (TC-09) ==")
let ring = StderrTail(capacity: 8)
ring.append(Data("abcd".utf8))
ring.append(Data("efgh".utf8))
ring.append(Data("ijkl".utf8))
check(ring.byteCount == 8, "ring keeps exactly its capacity")
check(ring.string == "efghijkl", "ring keeps the most recent bytes")

let smallTail = StderrTail()
smallTail.append(Data("debug noise\nPermission denied (publickey).\n".utf8))
check(SSHTunnelRunner.shortMessage(smallTail.string) == "Permission denied (publickey).",
      "shortMessage returns the last non-empty line")
check(SSHTunnelRunner.isFatal(smallTail.string, code: 255), "small output still classifies as fatal")

let cap = StderrTail.defaultCapacity
let marker = "host key verification failed\n"
let bigTail = StderrTail()
bigTail.append(Data(String(repeating: "x", count: cap).utf8))
bigTail.append(Data(marker.utf8))
let expectedTail = String((String(repeating: "x", count: cap) + marker).suffix(cap))
check(bigTail.byteCount == cap, "default cap is \(cap) bytes")
check(bigTail.string == expectedTail, "retains exactly the last 64 KiB")
check(bigTail.string.hasSuffix(marker), "fatal marker in the tail is retained")
check(SSHTunnelRunner.isFatal(bigTail.string, code: 255), "classification uses the capped tail")

let streamed = StderrTail()
var full = ""
for i in 0..<100 {
    let chunk = String(repeating: "\(i % 10)", count: 1024)
    full += chunk
    streamed.append(Data(chunk.utf8))
}
check(streamed.byteCount == cap, "chunked appends stay capped")
check(streamed.string == String(full.suffix(cap)), "chunked tail content matches the last 64 KiB")

print("== stderr drain before classification (TC-11) ==")
let immediate = Pipe()
let immediateTail = StderrTail()
try! immediate.fileHandleForWriting.write(contentsOf: Data("debug\nPermission denied (publickey).\n".utf8))
try! immediate.fileHandleForWriting.close()
let immediateEOF = SSHTunnelRunner.drainToEOF(immediate.fileHandleForReading,
                                              into: immediateTail,
                                              until: Date().addingTimeInterval(1.0))
check(immediateEOF, "drain reaches EOF")
check(SSHTunnelRunner.isFatal(immediateTail.string, code: 255),
      "fatal line written just before EOF is classified without a sleep")
check(SSHTunnelRunner.shortMessage(immediateTail.string) == "Permission denied (publickey).",
      "drained short message is the last non-empty line")
try? immediate.fileHandleForReading.close()

let held = Pipe()
let heldTail = StderrTail()
try! held.fileHandleForWriting.write(contentsOf: Data("partial diagnostic\n".utf8))
let heldStart = Date()
let heldEOF = SSHTunnelRunner.drainToEOF(held.fileHandleForReading,
                                         into: heldTail,
                                         until: Date().addingTimeInterval(0.3))
let heldElapsed = Date().timeIntervalSince(heldStart)
check(!heldEOF, "drain reports timeout while the write end stays open")
check(heldElapsed >= 0.25 && heldElapsed < 2.0,
      String(format: "drain returns within its bounded budget (%.2fs)", heldElapsed))
check(heldTail.string.contains("partial diagnostic"), "bytes received before the timeout are kept")
try? held.fileHandleForWriting.close()
try? held.fileHandleForReading.close()

print("")
if failures == 0 {
    print("✅ all askpass tests passed")
    exit(0)
} else {
    print("❌ \(failures) askpass test(s) failed")
    exit(1)
}
