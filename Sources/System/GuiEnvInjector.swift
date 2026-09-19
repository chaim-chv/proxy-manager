import Foundation

/// Publishes the proxy environment (`HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`/
/// `WSS_PROXY`/`NO_PROXY`) to the **GUI session** via `launchctl setenv`, so
/// native apps launched from Finder/Dock — which never read shell rc files —
/// pick up the proxy. This covers apps that ignore the macOS system proxy for
/// some transports (e.g. Codex's WebSocket client, which only honors env vars).
///
/// Safety model (mirrors the system-proxy snapshot): the user's *existing*
/// values are captured to disk before we set anything, and only a `remove()`
/// that finds a snapshot will touch the environment. A crash therefore leaves
/// the values set (harmless: the proxy is still running) but never lets a later
/// cleanup clobber a pre-existing user proxy.
final class GuiEnvInjector {
    typealias Runner = (_ args: [String]) -> LaunchctlResult

    struct LaunchctlResult {
        let status: Int32
        let stdout: String
    }

    /// The variables we own. `WSS_PROXY` is honored by some WebSocket clients
    /// (e.g. Codex) that do not read `HTTPS_PROXY`.
    static let managedKeys = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "WSS_PROXY", "NO_PROXY", "PROXY_MANAGER_ACTIVE"]

    private let snapshotURL: URL
    private let run: Runner
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var lastApplied: [String: String]?

    init(snapshotURL: URL, runner: @escaping Runner = GuiEnvInjector.launchctlRunner) {
        self.snapshotURL = snapshotURL
        self.run = runner
    }

    /// Builds the managed values for a proxy on `bindHost:port`. Returns nil for
    /// an invalid bind host (never write env we can't safely quote).
    static func values(port: UInt16, bindHost: String, tunnelHost: String) -> [String: String]? {
        let rawHost = (bindHost.isEmpty || bindHost == "0.0.0.0") ? "127.0.0.1" : bindHost
        guard let host = ShellEnvInjector.sanitizedHost(rawHost) else { return nil }
        let proxy = "http://\(host):\(port)"
        var noProxy = "127.0.0.1,localhost,::1"
        let t = tunnelHost.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t != "127.0.0.1", t != "localhost", let th = ShellEnvInjector.sanitizedHost(t) {
            noProxy += ",\(th)"
        }
        return [
            "HTTP_PROXY": proxy,
            "HTTPS_PROXY": proxy,
            "ALL_PROXY": proxy,
            "WSS_PROXY": proxy,
            "NO_PROXY": noProxy,
            "PROXY_MANAGER_ACTIVE": "1",
        ]
    }

    /// Captures the user's original values (once), then sets the proxy vars.
    /// Returns false without touching anything if the bind host is invalid or
    /// the snapshot cannot be persisted.
    @discardableResult
    func apply(port: UInt16, bindHost: String, tunnelHost: String) -> Bool {
        guard let values = Self.values(port: port, bindHost: bindHost, tunnelHost: tunnelHost) else {
            Log.system.error("gui env: invalid bind host, not publishing proxy env")
            return false
        }

        lock.lock()
        if lastApplied == values {
            lock.unlock()
            return true
        }
        lock.unlock()

        // Capture the originals exactly once. If a snapshot already exists it
        // holds the user's values from a previous apply (the current `getenv`
        // would return ours), so never overwrite it.
        if loadSnapshot() == nil {
            let captured = captureCurrent()
            guard saveSnapshot(captured) else {
                Log.system.error("gui env: could not persist snapshot; not publishing proxy env")
                return false
            }
        }

        for key in Self.managedKeys {
            guard let value = values[key] else { continue }
            _ = run(["setenv", key, value])
        }
        lock.lock(); lastApplied = values; lock.unlock()
        Log.system.notice("gui env: published proxy env to the GUI session")
        return true
    }

    /// Restores the user's original values (or unsets the vars that were unset)
    /// and clears the snapshot. No-op when there is no snapshot, so it can never
    /// clobber a proxy we did not set.
    func remove() {
        guard let snapshot = loadSnapshot() else { return }
        for key in Self.managedKeys {
            if let prior = snapshot[key] {
                _ = run(["setenv", key, prior])
            } else {
                _ = run(["unsetenv", key])
            }
        }
        clearSnapshot()
        lock.lock(); lastApplied = nil; lock.unlock()
        Log.system.notice("gui env: restored GUI session proxy env")
    }

    // MARK: - Snapshot persistence

    private func captureCurrent() -> [String: String] {
        var captured: [String: String] = [:]
        for key in Self.managedKeys {
            let value = run(["getenv", key]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { captured[key] = value }
        }
        return captured
    }

    private func loadSnapshot() -> [String: String]? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private func saveSnapshot(_ snapshot: [String: String]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return false }
        do {
            try fileManager.createDirectory(at: snapshotURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try data.write(to: snapshotURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
            return true
        } catch {
            return false
        }
    }

    private func clearSnapshot() {
        try? fileManager.removeItem(at: snapshotURL)
    }

    // MARK: - launchctl

    static func launchctlRunner(_ args: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Log.system.error("gui env: launchctl \(args.first ?? "") failed to launch: \(error.localizedDescription)")
            return LaunchctlResult(status: -1, stdout: "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LaunchctlResult(status: process.terminationStatus,
                               stdout: String(data: data, encoding: .utf8) ?? "")
    }
}
