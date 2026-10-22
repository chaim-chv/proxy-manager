import Foundation
import Darwin

// Standalone regression harness for the single-instance lock (LC-14).
//
// Build (from the repo root):
//   xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
//     Sources/Support/Log.swift Sources/Support/SingleInstanceLock.swift \
//     Tests/SingleInstanceHarness/main.swift -o /tmp/single-instance-harness && \
//     /tmp/single-instance-harness

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  PASS  \(message)")
    } else {
        failures += 1
        print("  FAIL  \(message)")
    }
}

let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("single-instance-harness-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let dirA = root.appendingPathComponent("support-a", isDirectory: true)
let dirB = root.appendingPathComponent("support-b", isDirectory: true)

print("single instance: exclusive lock")
do {
    let first = SingleInstanceLock(directory: dirA)
    check(first.acquire(), "first lock acquires in an empty support directory")

    let second = SingleInstanceLock(directory: dirA)
    check(!second.acquire(), "second lock against the same directory fails")
    check(!second.acquire(), "a failing lock stays failed while the first still holds it")

    first.release()
    let third = SingleInstanceLock(directory: dirA)
    check(third.acquire(), "a new lock acquires after the first is released")

    second.release()
    check(third.acquire(), "holding lock survives a failed sibling's release")

    let other = SingleInstanceLock(directory: dirB)
    check(other.acquire(), "a different directory does not conflict")

    let lockFile = dirA.appendingPathComponent(SingleInstanceLock.fileName)
    let attrs = try? FileManager.default.attributesOfItem(atPath: lockFile.path)
    let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue
    check(mode == 0o600, "lock file is created with 0600 permissions")

    third.release()
    other.release()
}

print("single instance: reacquisition")
do {
    let lock = SingleInstanceLock(directory: dirA)
    check(lock.acquire(), "acquires")
    check(lock.acquire(), "acquiring an already-held lock is idempotent")
    lock.release()
    check(lock.acquire(), "the same instance can reacquire after release")
    lock.release()
}

print("")
if failures == 0 {
    print("✅ all single-instance tests passed")
    exit(0)
} else {
    print("❌ \(failures) single-instance test(s) failed")
    exit(1)
}
