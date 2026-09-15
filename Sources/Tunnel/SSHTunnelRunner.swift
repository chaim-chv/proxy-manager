import Foundation
import Darwin

/// Runs and supervises an SSH SOCKS5 tunnel ("run the tunnel for me" mode).
///
/// Spawns `ssh -N -D <host:port> <user>@<host>` as a foreground child, drains
/// its stderr asynchronously (so the pipe never deadlocks), and restarts it
/// with exponential backoff when it dies for a non-fatal reason (network flap).
/// Auth failures / bad host keys / bad key files / port conflicts are treated as
/// fatal (no retry) and surfaced to the UI.
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

    /// Idempotent: (re)starts the tunnel only if settings changed or it's not
    /// running. Called whenever managed-tunnel settings change.
    func apply(_ settings: ManagedTunnelSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.runningValue && self.currentSettings == settings { return }
            self.currentSettings = settings
            self.spawn()
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
    func restart() {
        queue.async { [weak self] in
            guard let self, self.currentSettings != nil else { return }
            self.spawn()
        }
    }

    // MARK: - Internals (queue)

    private func stopLocked() {
        generation += 1
        currentSettings = nil
        terminateProcess(process)
        process = nil
        cleanupTemp()
        removePidFile()
        setRunning(false)
    }

    private func spawn() {
        guard let s = currentSettings else { return }
        guard !s.sshHost.trimmingCharacters(in: .whitespaces).isEmpty,
              !s.username.trimmingCharacters(in: .whitespaces).isEmpty else {
            setError("Enter the SSH host and username first.")
            return
        }

        generation += 1
        let gen = generation
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
            setupAskpass(password: pw, env: &env)
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
            setError("Failed to start ssh: \(error.localizedDescription)")
            cleanupTemp()
        }
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
            setError(shortMessage(stderr) ?? "ssh exited with code \(code)")
            return
        }

        setError(shortMessage(stderr) ?? "ssh exited with code \(code)")
        let delay = min(60.0, pow(2.0, Double(attempt)))
        attempt += 1
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            // Re-check on the serial queue so a stop()/mode change cannot be
            // undone by an in-flight backoff restart.
            self?.queue.async {
                guard let self, self.generation == gen, self.currentSettings != nil else { return }
                self.spawn()
            }
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

    /// Writes a one-shot askpass helper (which cats a 0600 secret file and then
    /// deletes it) and points `SSH_ASKPASS`/`SSH_ASKPASS_REQUIRE` at it.
    private func setupAskpass(password: String, env: inout [String: String]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxymanager-ssh-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch { return }

        let secret = dir.appendingPathComponent("secret")
        try? password.write(to: secret, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)

        let helper = dir.appendingPathComponent("askpass.sh")
        let quotedSecret = "'" + secret.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\n/bin/cat \(quotedSecret); /bin/rm -f \(quotedSecret)\n"
        try? script.write(to: helper, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        env["SSH_ASKPASS"] = helper.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        tempDir = dir
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
    private func killStaleProcess() {
        let url = Self.pidFileURL
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard pid != getpid(), kill(pid, 0) == 0, isSSHProcess(pid) else { return }
        Log.tunnel.notice("reaping stale ssh process \(pid)")
        kill(pid, SIGKILL)
    }

    private func isSSHProcess(_ pid: Int32) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let comm = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
