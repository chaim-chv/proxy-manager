import Foundation
import Darwin

/// Outcome of a bounded child-process run.
struct BoundedProcessResult {
    let pid: pid_t
    let status: Int32
    let stdoutData: Data
    let stderrData: Data
    let timedOut: Bool
    let launchError: String?

    var stdout: String { String(data: stdoutData, encoding: .utf8) ?? "" }
    var stderr: String { String(data: stderrData, encoding: .utf8) ?? "" }

    var succeeded: Bool {
        launchError == nil && !timedOut && status == 0
    }
}

/// Runs short-lived helpers (`launchctl`, `networksetup`, `ps`, `osascript`)
/// without ever blocking the caller indefinitely.
///
/// The child is started normally, stdout/stderr are drained concurrently via
/// `readabilityHandler` (so a full pipe can never stall it), and the wait uses
/// `terminationHandler` + a timed semaphore instead of `waitUntilExit()` (so it
/// is safe on the main thread). On timeout the child gets SIGTERM and then
/// SIGKILL; with `killTreeOnTimeout` its descendants are signalled too, so a
/// timed-out `osascript` cannot leave `sh`/`networksetup` running behind it.
/// Reader joins after exit are bounded, so a stuck descendant that still holds
/// a pipe cannot hang the caller.
enum BoundedProcess {
    @discardableResult
    static func run(executable: String,
                    arguments: [String],
                    timeout: TimeInterval,
                    environment: [String: String]? = nil,
                    killTreeOnTimeout: Bool = false,
                    terminateGracePeriod: TimeInterval = 0.5,
                    readerJoinTimeout: TimeInterval = 2.0) -> BoundedProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exited = DispatchSemaphore(value: 0)
        let statusLock = NSLock()
        var terminationStatus: Int32 = -1
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            statusLock.lock()
            terminationStatus = status
            statusLock.unlock()
            exited.signal()
        }

        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            return BoundedProcessResult(pid: 0, status: -1, stdoutData: Data(), stderrData: Data(),
                                        timedOut: false,
                                        launchError: error.localizedDescription)
        }

        let pid = process.processIdentifier
        let out = StreamCapture(handle: outPipe.fileHandleForReading)
        let err = StreamCapture(handle: errPipe.fileHandleForReading)
        out.start()
        err.start()

        var timedOut = false
        if exited.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            timedOut = true
            terminate(pid: pid, exited: exited, killTree: killTreeOnTimeout,
                      grace: terminateGracePeriod)
        }

        let joinDeadline = DispatchTime.now() + max(0, readerJoinTimeout)
        out.waitUntilEOF(deadline: joinDeadline)
        err.waitUntilEOF(deadline: joinDeadline)
        out.stop()
        err.stop()

        statusLock.lock()
        let status = terminationStatus
        statusLock.unlock()
        return BoundedProcessResult(pid: pid, status: status,
                                    stdoutData: out.data, stderrData: err.data,
                                    timedOut: timedOut, launchError: nil)
    }

    // MARK: - Termination

    private static func terminate(pid: pid_t, exited: DispatchSemaphore,
                                  killTree: Bool, grace: TimeInterval) {
        let graceDeadline = DispatchTime.now() + max(0, grace)
        var descendants: [pid_t] = killTree ? childPIDs(recursiveFrom: pid) : []

        for child in descendants.reversed() { signal(child, SIGTERM) }
        signal(pid, SIGTERM)
        _ = exited.wait(timeout: graceDeadline)

        if killTree {
            // Descendants share the same grace window as the root. Polling here
            // is bounded by the grace deadline and only runs on the timeout path.
            while DispatchTime.now() < graceDeadline,
                  descendants.contains(where: isAlive) {
                Thread.sleep(forTimeInterval: 0.01)
            }
            // Catch children spawned between the first scan and SIGTERM.
            descendants.append(contentsOf: childPIDs(recursiveFrom: pid))
            for child in Set(descendants) where child != pid && isAlive(child) {
                signal(child, SIGKILL)
            }
        }

        if isAlive(pid) {
            signal(pid, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
    }

    private static func signal(_ pid: pid_t, _ sig: Int32) {
        guard pid > 1, pid != getpid() else { return }
        kill(pid, sig)
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        errno = 0
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// All descendants of `pid`, breadth-first (parents before children).
    /// `proc_listchildpids` returns a pid count; a fixed-size buffer is grown
    /// until it fits (a zero-size probe is not reliable on macOS).
    private static func childPIDs(recursiveFrom root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var seen = Set<pid_t>([root])
        var frontier = [root]
        while let parent = frontier.popLast() {
            for child in directChildPIDs(of: parent) where seen.insert(child).inserted {
                result.append(child)
                frontier.append(child)
            }
        }
        return result
    }

    private static func directChildPIDs(of parent: pid_t) -> [pid_t] {
        var capacity = 64
        while capacity <= 16_384 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let written = buffer.withUnsafeMutableBytes { raw -> Int32 in
                proc_listchildpids(parent, raw.baseAddress, Int32(raw.count))
            }
            guard written > 0 else { return [] }
            if Int(written) < capacity {
                return Array(buffer.prefix(Int(written))).filter { $0 > 1 }
            }
            capacity *= 2
        }
        return []
    }
}

/// Drains one pipe as data becomes available. `readabilityHandler` never blocks
/// a thread waiting for the child, and the caller waits for EOF only up to a
/// deadline after the child exits.
private final class StreamCapture {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private let eof = DispatchSemaphore(value: 0)

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 65_536)
            } catch {
                chunk = nil
            }
            if let chunk, !chunk.isEmpty {
                self.lock.lock()
                self.buffer.append(chunk)
                self.lock.unlock()
            } else {
                handle.readabilityHandler = nil
                self.eof.signal()
            }
        }
    }

    func waitUntilEOF(deadline: DispatchTime) {
        _ = eof.wait(timeout: deadline)
    }

    func stop() {
        handle.readabilityHandler = nil
    }

    var data: Data {
        lock.lock()
        let copy = buffer
        lock.unlock()
        return copy
    }
}
