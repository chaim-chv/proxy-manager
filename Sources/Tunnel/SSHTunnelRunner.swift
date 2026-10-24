import Foundation
import Darwin

/// Keeps only the last `capacity` bytes of a child's stderr.
///
/// A hostile/verbose server, a broken `ProxyCommand`, or a rekey loop can write
/// arbitrarily much to stderr; retaining the whole stream (and splitting it at
/// exit) grows memory without bound. Fatal markers are at the end, so a bounded
/// tail is enough. Appends race with the exit drain, hence the lock.
final class StderrTail {
    static let defaultCapacity = 64 * 1024

    let capacity: Int
    private let lock = NSLock()
    private var buffer = Data()

    init(capacity: Int = StderrTail.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        // Trim an oversized chunk before appending so the buffer never spans
        // more than the cap plus one chunk.
        if chunk.count >= capacity {
            buffer = Data(chunk.suffix(capacity))
        } else {
            buffer.append(chunk)
            let overflow = buffer.count - capacity
            if overflow > 0 { buffer.removeFirst(overflow) }
        }
    }

    var byteCount: Int {
        lock.lock(); defer { lock.unlock() }; return buffer.count
    }

    /// Decoded lazily on read; invalid UTF-8 becomes replacement characters
    /// rather than discarding the whole tail (fatal markers are ASCII).
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Identity of an ssh child, as persisted in `ssh.pid`.
///
/// A bare PID cannot prove identity after a crash: PID reuse can make both
/// `kill(pid, 0)` and `ps -o comm=` match an unrelated `ssh` (e.g. the user's
/// own session). The process start time disambiguates them, so a file without
/// one is never acted on (TC-14).
struct PidRecord: Equatable {
    let pid: Int32
    let startSec: UInt64
    let startUsec: UInt64

    var serialized: String { "\(pid) \(startSec) \(startUsec)" }

    /// Returns nil for anything that is not a well-formed three-field record,
    /// which includes the legacy pid-only format (never trusted, never killed).
    static func parse(_ raw: String) -> PidRecord? {
        let fields = raw.split(whereSeparator: {
            $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
        })
        guard fields.count == 3,
              let pid = Int64(fields[0]), pid > 0, pid <= Int64(Int32.max),
              let startSec = UInt64(fields[1]),
              let startUsec = UInt64(fields[2]), startUsec < 1_000_000 else {
            return nil
        }
        return PidRecord(pid: Int32(pid), startSec: startSec, startUsec: startUsec)
    }
}

/// Runs and supervises an SSH SOCKS5 tunnel ("run the tunnel for me" mode).
///
/// Spawns `ssh -N -D <host:port> <user>@<host>` as a foreground child, drains
/// its stderr asynchronously (so the pipe never deadlocks), and restarts it
/// with exponential backoff when it dies for a non-fatal reason (network flap).
/// Auth failures / bad host keys / bad key files / port conflicts are treated as
/// fatal (no retry) and surfaced to the UI. Settings changes are coalesced so a
/// typed hostname produces one spawn (and one auth attempt), not one per key.
///
/// Passwords are read from the Keychain and fed to ssh via an `SSH_ASKPASS`
/// helper + `SSH_ASKPASS_REQUIRE=force` — never argv or env. The helper deletes
/// its secret file after the single prompt so it does not linger on crash.
final class SSHTunnelRunner: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.proxymanager.ssh", qos: .userInitiated)
    private let stateLock = NSLock()
    private var runningValue = false

    private var process: Process?
    private var generation = 0
    private var attempt = 0
    private var currentSettings: ManagedTunnelSettings?
    private var startTime: Date?
    private var tempDir: URL?

    // Keystroke bursts are coalesced into one spawn. All of these are touched
    // only on `queue`.
    private var pendingApply: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var lastRequestedSettings: ManagedTunnelSettings?
    private var lastSpawnSettings: ManagedTunnelSettings?
    /// The settings whose child exited fatally; sticky until they change or an
    /// explicit restart, so unrelated config commits cannot retry auth.
    private var fatalSettings: ManagedTunnelSettings?

    init() {
        // A crash/force-quit before ssh ever prompted leaves the plaintext
        // secret in the temp dir. Sweep old ones at startup so they don't
        // accumulate (TC-08).
        Self.sweepStaleAskpassDirs()
    }

    /// Thread-safe read for the app (e.g. AppModel lifecycle).
    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return runningValue
    }

    /// Where we record the ssh child pid so an orphan (after a crash/force-quit)
    /// can be reaped on the next launch — otherwise it holds the SOCKS port and
    /// managed mode can never recover.
    private static var pidFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProxyManager", isDirectory: true).appendingPathComponent("ssh.pid")
    }

    // MARK: - Public API

    /// Settings changes are debounced for 500 ms so typing a host or
    /// port spawns (and authenticates) once, after the burst. Identical
    /// requests are ignored while already running, retrying, or while the same
    /// settings are in a sticky fatal state.
    func apply(_ settings: ManagedTunnelSettings) {
        queue.async { [weak self] in
            guard let self else { return }

            // Same intent, still pending or already settled: no new work.
            if self.lastRequestedSettings == settings, self.pendingApply != nil { return }
            if self.lastRequestedSettings == settings, !self.shouldSpawn(settings) { return }

            if self.lastRequestedSettings != settings {
                // A changed setting is new intent: it supersedes a fatal exit
                // and the retry scheduled for the old settings.
                self.fatalSettings = nil
                self.retryWorkItem?.cancel()
                self.retryWorkItem = nil
            }
            self.lastRequestedSettings = settings
            self.pendingApply?.cancel()

            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingApply = nil
                // A stop()/restart()/newer apply() cancels this item; re-check
                // the intent because the child's own exit handler may have run
                // in the meantime (it must not win over newer settings).
                guard self.lastRequestedSettings == settings else { return }
                self.currentSettings = settings
                guard self.shouldSpawn(settings) else { return }
                self.spawn()
            }
            self.pendingApply = item
            self.queue.asyncAfter(deadline: .now() + 0.5, execute: item)
        }
    }

    /// Graceful stop (async).
    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    /// Synchronous stop, for app quit (call from a non-`queue` thread).
    func stopNow() {
        queue.sync { self.stopLocked() }
    }

    /// Force restart with the current settings (used by the UI restart button).
    /// Explicit restart is how a fatal state is left without changing settings.
    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            let settings = self.lastRequestedSettings ?? self.currentSettings
            guard let settings else { return }
            self.pendingApply?.cancel()
            self.pendingApply = nil
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.fatalSettings = nil
            self.lastRequestedSettings = settings
            self.currentSettings = settings
            self.spawn()
        }
    }

    // MARK: - Internals (queue)

    private func stopLocked() {
        pendingApply?.cancel()
        pendingApply = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        fatalSettings = nil
        lastRequestedSettings = nil
        lastSpawnSettings = nil
        generation += 1
        currentSettings = nil
        terminateProcess(process)
        process = nil
        cleanupTemp()
        removePidFile()
        setRunning(false)
    }

    /// Spawn only when this is new intent: not the sticky fatal settings, not
    /// waiting on the retry scheduled for those same settings, and not already
    /// running them.
    private func shouldSpawn(_ settings: ManagedTunnelSettings) -> Bool {
        if fatalSettings == settings { return false }
        if retryWorkItem != nil && lastSpawnSettings == settings { return false }
        if runningValue && lastSpawnSettings == settings { return false }
        return true
    }

    private func spawn() {
        guard let s = currentSettings else { return }
        guard !s.sshHost.trimmingCharacters(in: .whitespaces).isEmpty,
              !s.username.trimmingCharacters(in: .whitespaces).isEmpty else {
            setError("Enter the SSH host and username first.")
            return
        }

        // This spawn supersedes any pending retry; cancel it before adding a
        // child so only one attempt (and one child) is ever in flight.
        retryWorkItem?.cancel()
        retryWorkItem = nil
        fatalSettings = nil
        lastSpawnSettings = s

        generation += 1
        let gen = generation
        // The replacement can fail before `run()` succeeds, so drop the old
        // child's running state up front instead of inheriting it (TC-04).
        setRunning(false)
        // Sweep crash leftovers before creating this run's dir; never touch the
        // dir this instance is still using (cleanupTemp removes it next).
        Self.sweepStaleAskpassDirs(excluding: tempDir)
        cleanupTemp()
        terminateProcess(process)
        process = nil
        killStaleProcess()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = makeArguments(s)
        p.standardInput = FileHandle.nullDevice

        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        if s.auth == .password, let pw = SSHKeychain.shared.load(), !pw.isEmpty {
            do {
                try setupAskpass(password: pw, env: &env)
            } catch {
                // Never launch ssh with an unusable askpass: it would hang or
                // fail auth with no actionable error. Abort this spawn (TC-08).
                cleanupTemp()
                setRunning(false)
                Log.tunnel.error("could not prepare the password helper: \(error.localizedDescription)")
                setError("Could not prepare the password helper. \(error.localizedDescription)")
                return
            }
        }
        p.environment = env

        let errHandle = errPipe.fileHandleForReading
        let errTail = StderrTail()
        // Serializes the async callback and the exit drain so they never read
        // the descriptor concurrently (which could reorder or drop bytes).
        let errReadLock = NSLock()

        errHandle.readabilityHandler = { handle in
            errReadLock.lock(); defer { errReadLock.unlock() }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errTail.append(chunk)
            }
        }

        p.terminationHandler = { [weak self] proc in
            // The fatal line is usually written immediately before exit and the
            // readability callback is asynchronous, so stop it and drain the
            // pipe to EOF ourselves before classifying. The wait is bounded: a
            // grandchild may hold the write end open.
            errHandle.readabilityHandler = nil
            let deadline = Date().addingTimeInterval(1.0)
            if errReadLock.lock(before: deadline) {
                let eof = Self.drainToEOF(errHandle, into: errTail, until: deadline)
                errReadLock.unlock()
                // A writer that outlives the child (an inherited fd) must not
                // keep the read end open; best effort to unblock/discard it.
                if !eof { try? errHandle.close() }
            } else {
                // A callback is stuck reading; close the read end so it cannot
                // block a thread forever, then classify with what we captured.
                try? errHandle.close()
            }
            let err = errTail.string
            self?.queue.async { self?.handleExit(proc, stderr: err, generation: gen) }
        }

        do {
            try p.run()
            process = p
            startTime = Date()
            writePidFile(p.processIdentifier)
            setRunning(true)
            setError(nil)
        } catch {
            process = nil
            setRunning(false)
            cleanupTemp()
            Log.tunnel.error("failed to start ssh: \(error.localizedDescription)")

            guard lastRequestedSettings == s else {
                setError("Failed to start ssh: \(error.localizedDescription)")
                return
            }
            let delay = min(60.0, pow(2.0, Double(attempt)))
            attempt += 1
            setError("Failed to start ssh: \(error.localizedDescription) Retrying in \(Int(delay))s.")
            scheduleRetry(after: delay, generation: gen)
        }
    }

    /// One cancelable retry per failed attempt. Cancelling the item before it
    /// runs (stop/config change/restart) prevents a stopped tunnel reviving.
    private func scheduleRetry(after delay: TimeInterval, generation gen: Int) {
        retryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            // Same generation guard as handleExit: stop()/apply() wins.
            guard self.generation == gen, self.currentSettings != nil else { return }
            self.spawn()
        }
        retryWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func handleExit(_ proc: Process, stderr: String, generation gen: Int) {
        guard gen == generation else { return }
        process = nil
        cleanupTemp()
        removePidFile()
        setRunning(false)

        let code = proc.terminationStatus
        let uptime = Date().timeIntervalSince(startTime ?? Date())

        // A long-lived run resets the backoff so transient flaps don't ratchet
        // the delay up to 60 s forever.
        if uptime >= 60 { attempt = 0 }

        if Self.isFatal(stderr, code: code) {
            attempt = 0
            // Sticky until the settings change or an explicit restart, so an
            // unrelated config commit cannot retry a failing auth.
            fatalSettings = lastSpawnSettings
            setError(Self.shortMessage(stderr) ?? "ssh exited with code \(code)")
            return
        }

        setError(Self.shortMessage(stderr) ?? "ssh exited with code \(code)")
        let delay = min(60.0, pow(2.0, Double(attempt)))
        attempt += 1
        // If the user changed the settings while this child was dying, the
        // pending debounced apply owns the next spawn; don't race it.
        if lastRequestedSettings == lastSpawnSettings {
            scheduleRetry(after: delay, generation: gen)
        }
    }

    /// Reads `handle` to EOF (or until `deadline`) into `tail`, without ever
    /// blocking past the deadline. `poll` with short slices lets us notice both
    /// EOF and a writer that stays open (e.g. an inherited fd in a grandchild).
    /// Returns false when the timeout expired before EOF.
    @discardableResult
    static func drainToEOF(_ handle: FileHandle, into tail: StderrTail, until deadline: Date) -> Bool {
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return true }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }

            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let slice = Int32(max(1, min(remaining, 0.25) * 1000))
            let ready = poll(&descriptor, 1, slice)
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            if ready == 0 { continue }

            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                tail.append(Data(bytes: buffer, count: count))
                continue
            }
            if count == 0 { return true }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { continue }
            return (descriptor.revents & Int16(POLLHUP)) != 0
        }
    }

    static func isFatal(_ stderr: String, code: Int32) -> Bool {
        let lower = stderr.lowercased()
        let fatalMarkers = [
            "permission denied",
            "authentication failed",
            "too many authentication failures",
            "host key verification failed",
            "could not resolve hostname",
            "no such file or directory",
            "identity file",
            "bad permissions",
            "invalid format",
            "load key",
            "address already in use",
            "cannot listen to port",
        ]
        return fatalMarkers.contains { lower.contains($0) }
    }

    /// Last non-empty line, scanned without materializing every line of the
    /// (bounded) tail. Line separators other than `\n` are treated as text.
    static func shortMessage(_ stderr: String) -> String? {
        var last: String?
        stderr.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { last = trimmed }
        }
        return last
    }

    // MARK: - Process construction

    private func makeArguments(_ s: ManagedTunnelSettings) -> [String] {
        var args = [
            "-N",
            "-D", "\(s.socksHost):\(s.socksPort)",
            "-p", String(s.sshPort),
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            // Keep real errors (fatal classification depends on them) but quiet
            // the noise. `-q` would suppress everything, including auth errors.
            "-o", "LogLevel=ERROR",
            // Ignore the user's ssh config multiplexing so the child owns the
            // forward and we can always control/kill it.
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        if s.auth == .key {
            if !s.keyPath.isEmpty {
                args += ["-i", expandTilde(s.keyPath)]
                args += ["-o", "IdentitiesOnly=yes"]
            }
            // Never prompt interactively for a passphrase — fail cleanly instead
            // of hanging the unattended process.
            args += ["-o", "BatchMode=yes"]
        } else {
            // Password auth must not burn auth attempts on agent keys first.
            args += ["-o", "PubkeyAuthentication=no"]
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
        }
        args.append("\(s.username)@\(s.sshHost)")
        return args
    }

    private func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        }
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return path
    }

    private struct AskpassSetupError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Writes a one-shot askpass helper (which cats a 0600 secret file and then
    /// deletes it on any exit) and points `SSH_ASKPASS`/`SSH_ASKPASS_REQUIRE`
    /// at it. Throws on any failure so the caller never launches ssh with a
    /// half-built helper or a lingering partial temp dir.
    private func setupAskpass(password: String, env: inout [String: String]) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("proxymanager-ssh-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

            let secret = dir.appendingPathComponent("secret")
            try password.write(to: secret, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)

            let helper = dir.appendingPathComponent("askpass.sh")
            try Self.askpassScript(secretPath: secret.path)
                .write(to: helper, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

            env["SSH_ASKPASS"] = helper.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            tempDir = dir
        } catch {
            try? fm.removeItem(at: dir)
            throw AskpassSetupError(reason: error.localizedDescription)
        }
    }

    /// POSIX-sh askpass script. The EXIT/INT/TERM trap removes the secret even
    /// if `cat` fails or the shell is interrupted, so it can never outlive a
    /// single prompt. The path is single-quote escaped for `sh`.
    static func askpassScript(secretPath: String) -> String {
        let quoted = "'" + secretPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "#!/bin/sh\n"
            + "secret=\(quoted)\n"
            + "trap 'rm -f \"$secret\"' EXIT INT TERM\n"
            + "/bin/cat \"$secret\"\n"
    }

    /// Removes askpass dirs left behind by a crash or force-quit: only entries
    /// named `proxymanager-ssh-*` that are directories and older than
    /// `olderThan` (so a live sibling's fresh dir is never touched). Unrelated
    /// temp entries and the currently active dir (`excluding`) are skipped.
    static func sweepStaleAskpassDirs(olderThan: TimeInterval = 300,
                                      in root: URL = FileManager.default.temporaryDirectory,
                                      excluding: URL? = nil) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let excludedPath = excluding?.standardizedFileURL.path
        let cutoff = Date().addingTimeInterval(-olderThan)
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix("proxymanager-ssh-") {
            if let excludedPath, entry.standardizedFileURL.path == excludedPath { continue }
            guard let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            ), values.isDirectory == true,
                  let modified = values.contentModificationDate, modified < cutoff else {
                continue
            }
            do {
                try fm.removeItem(at: entry)
                removed += 1
            } catch {
                Log.tunnel.error("failed to remove stale askpass dir \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if removed > 0 {
            Log.tunnel.notice("removed \(removed) stale askpass dir(s)")
        } else {
            Log.tunnel.debug("askpass sweep found no stale dirs")
        }
    }

    private func cleanupTemp() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
            self.tempDir = nil
        }
    }

    /// SIGTERM, then SIGKILL if the child does not exit promptly, so "Stop" and
    /// app quit cannot leave an ssh holding the SOCKS port.
    private func terminateProcess(_ p: Process?) {
        guard let p, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    private func writePidFile(_ pid: Int32) {
        let url = Self.pidFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The child only exists after `run()`, so its start time can only be read
        // here. Never guess one: a pid-only fallback is written for diagnostics,
        // but the reaper refuses to kill it (TC-14).
        guard let start = Self.processStartTime(pid) else {
            Log.tunnel.notice("could not read the ssh start time; writing a pid-only file the reaper will not kill")
            writePidContents(String(pid), to: url)
            return
        }
        writePidContents(PidRecord(pid: pid, startSec: start.sec, startUsec: start.usec).serialized,
                         to: url)
    }

    private func writePidContents(_ contents: String, to url: URL) {
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.tunnel.error("failed to write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(at: Self.pidFileURL)
    }

    /// Pure reap policy: only a PID whose recorded start time still matches and
    /// that is still an `ssh` may be killed.
    static func shouldReap(record: PidRecord,
                           currentStart: (sec: UInt64, usec: UInt64)?,
                           isSSH: Bool) -> Bool {
        guard isSSH, let currentStart else { return false }
        return currentStart.sec == record.startSec && currentStart.usec == record.startUsec
    }

    /// Kills an ssh left over from a previous run (crash/force-quit), but only
    /// when the pid file proves it is still that child: a recycled PID (such as
    /// the user's own ssh) is never signalled.
    /// Static so the crash watchdog (a separate process) can reap the orphan
    /// even when the app is gone (LC-18).
    static func reapStaleProcess() {
        let url = pidFileURL
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        // The file describes one run only; it is never reused after inspection.
        defer { try? FileManager.default.removeItem(at: url) }

        guard let record = PidRecord.parse(raw) else {
            // Legacy pid-only file or garbage: identity cannot be proven, so do
            // not signal anything. A surviving orphan holds the SOCKS port and
            // surfaces as a port conflict instead of risking an unrelated kill.
            Log.tunnel.notice("stale ssh pid file has no verifiable start time; skipping reap")
            return
        }
        guard record.pid != getpid(), let currentStart = processStartTime(record.pid) else {
            Log.tunnel.debug("stale ssh pid \(record.pid) is gone or cannot be inspected; not killing")
            return
        }
        // Only pay for the `ps` spawn once the start time already matches.
        let startMatches = currentStart.sec == record.startSec
            && currentStart.usec == record.startUsec
        guard shouldReap(record: record,
                         currentStart: currentStart,
                         isSSH: startMatches && isSSHProcess(record.pid)) else {
            Log.tunnel.notice("stale ssh pid \(record.pid) was reused by another process; not killing it")
            return
        }
        Log.tunnel.notice("reaping stale ssh process \(record.pid)")
        kill(record.pid, SIGKILL)
    }

    private func killStaleProcess() {
        Self.reapStaleProcess()
    }

    /// Kernel start time of a process. Used to prove a PID is still the child we
    /// recorded: PID reuse otherwise makes a bare PID unsafe to signal (TC-14).
    private static func processStartTime(_ pid: Int32) -> (sec: UInt64, usec: UInt64)? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, Int32(PROC_PIDTBSDINFO), 0, $0, size)
        }
        // A short read would leave parts of the struct zeroed: refuse to treat
        // that as a real start time.
        guard rc == size else { return nil }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    private static func isSSHProcess(_ pid: Int32) -> Bool {
        let result = BoundedProcess.run(executable: "/bin/ps",
                                        arguments: ["-p", String(pid), "-o", "comm="],
                                        timeout: 5)
        guard result.launchError == nil, !result.timedOut, result.status == 0 else { return false }
        let comm = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return comm.hasSuffix("/ssh") || comm == "ssh"
    }

    // MARK: - State publishing

    private func setRunning(_ value: Bool) {
        stateLock.lock(); runningValue = value; stateLock.unlock()
        DispatchQueue.main.async { self.running = value }
    }

    private func setError(_ message: String?) {
        DispatchQueue.main.async { self.lastError = message }
    }
}
