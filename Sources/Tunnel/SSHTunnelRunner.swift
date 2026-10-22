import Foundation
import Darwin

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

        var errData = Data()
        let errLock = NSLock()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errLock.lock(); errData.append(chunk); errLock.unlock()
            }
        }

        p.terminationHandler = { [weak self] proc in
            // Give the readability handler a moment to drain the final bytes
            // (the real error is usually written just before exit).
            Thread.sleep(forTimeInterval: 0.05)
            errLock.lock(); let err = String(data: errData, encoding: .utf8) ?? ""; errLock.unlock()
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

        if isFatal(stderr, code: code) {
            attempt = 0
            // Sticky until the settings change or an explicit restart, so an
            // unrelated config commit cannot retry a failing auth.
            fatalSettings = lastSpawnSettings
            setError(shortMessage(stderr) ?? "ssh exited with code \(code)")
            return
        }

        setError(shortMessage(stderr) ?? "ssh exited with code \(code)")
        let delay = min(60.0, pow(2.0, Double(attempt)))
        attempt += 1
        // If the user changed the settings while this child was dying, the
        // pending debounced apply owns the next spawn; don't race it.
        if lastRequestedSettings == lastSpawnSettings {
            scheduleRetry(after: delay, generation: gen)
        }
    }

    private func isFatal(_ stderr: String, code: Int32) -> Bool {
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

    private func shortMessage(_ stderr: String) -> String? {
        let line = stderr.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last
        return line
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
        try? String(pid).write(to: url, atomically: true, encoding: .utf8)
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(at: Self.pidFileURL)
    }

    /// Kills an ssh left over from a previous run (crash/force-quit). Verifies
    /// the pid is actually `ssh` before signalling so PID reuse is safe.
    /// Static so the crash watchdog (a separate process) can reap the orphan
    /// even when the app is gone (LC-18).
    static func reapStaleProcess() {
        let url = pidFileURL
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard pid != getpid(), kill(pid, 0) == 0, isSSHProcess(pid) else { return }
        Log.tunnel.notice("reaping stale ssh process \(pid)")
        kill(pid, SIGKILL)
    }

    private func killStaleProcess() {
        Self.reapStaleProcess()
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
