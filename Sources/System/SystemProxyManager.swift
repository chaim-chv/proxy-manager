import Foundation

/// Manages the macOS system proxy (HTTP + HTTPS) on all network services.
///
/// Mutations use the least privilege that works: the privileged helper daemon
/// when it's registered, then `networksetup` run directly as the current user
/// (prompt-free), and only fall back to `osascript ... with administrator
/// privileges` (a native admin dialog) when direct access genuinely fails.
/// Read operations run directly.
final class SystemProxyManager {
    private let helper = HelperXPCClient()

    /// Cached tri-state: nil = not yet determined.
    private var helperUsable: Bool?

    init() {}

    // MARK: - Read (no admin)

    func listServices() -> [String] {
        let output = runRead(["-listallnetworkservices"])
        guard var lines = output else { return [] }
        if lines.first?.hasPrefix("An asterisk") == true { lines.removeFirst() }
        return lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") } // skip disabled services
    }

    func captureSnapshot(services: [String]) -> SystemProxySnapshot {
        var snapshot = SystemProxySnapshot()
        for svc in services {
            var state = ServiceProxyState()
            if let web = runRead(["-getwebproxy", svc]) {
                parseProxyOutput(web, enabled: &state.webEnabled, server: &state.webServer, port: &state.webPort)
            }
            if let sec = runRead(["-getsecurewebproxy", svc]) {
                parseProxyOutput(sec, enabled: &state.secureEnabled, server: &state.secureServer, port: &state.securePort)
            }
            if let pac = runRead(["-getautoproxyurl", svc]) {
                state.pacEnabled = pac.contains(where: { $0.hasPrefix("Enabled:") && $0.lowercased().contains("yes") })
                for line in pac where line.hasPrefix("URL:") {
                    state.pacURL = ServiceProxyState.normalizePAC(String(line.dropFirst("URL:".count)))
                }
            }
            if let bypass = runRead(["-getproxybypassdomains", svc]) {
                state.bypassDomains = bypass
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("there aren't any") }
            }
            snapshot[svc] = state
        }
        return snapshot
    }

    /// True if any enabled service points HTTP(S) at a local `127.0.0.1` proxy
    /// on `port` (0 = any port). The crash watchdog uses this to confirm the
    /// dangling proxy is ours before restoring, so it never clobbers a proxy the
    /// user set themselves (e.g. another local proxy on a different port).
    func currentProxyPointsAtLocalhost(port: UInt16) -> Bool {
        for svc in listServices() {
            if proxyEnabled(["-getwebproxy", svc], port: port) { return true }
            if proxyEnabled(["-getsecurewebproxy", svc], port: port) { return true }
        }
        return false
    }

    private func proxyEnabled(_ args: [String], port: UInt16) -> Bool {
        guard let lines = runRead(args) else { return false }
        var enabled = false
        var server = ""
        var foundPort = ""
        parseProxyOutput(lines, enabled: &enabled, server: &server, port: &foundPort)
        guard enabled && server == "127.0.0.1" else { return false }
        return port == 0 || foundPort == String(port)
    }

    private func parseProxyOutput(_ lines: [String], enabled: inout Bool, server: inout String, port: inout String) {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Enabled:") {
                enabled = trimmed.lowercased().contains("yes")
            } else if trimmed.hasPrefix("Server:") {
                server = String(trimmed.dropFirst("Server:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Port:") {
                port = String(trimmed.dropFirst("Port:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
    }

    // MARK: - Mutations (helper → direct-as-user → osascript)

    func applyProxy(services: [String], port: UInt16) throws {
        try runMutations(commands: NetworksetupCommands.applyProxy(services: services, port: Int(port))) {
            try helper.applyProxy(services: services, port: Int(port))
        }
    }

    func clearProxy(services: [String]) throws {
        try runMutations(commands: NetworksetupCommands.clearProxy(services: services)) {
            try helper.clearProxy(services: services)
        }
    }

    func restore(snapshot: SystemProxySnapshot) throws {
        try Self.checkRestorable(snapshot)
        try runMutations(commands: NetworksetupCommands.restore(snapshot: snapshot)) {
            try helper.restoreProxy(snapshot: snapshot)
        }
    }

    /// Pre-flight guard: a non-empty snapshot in which **no** service has
    /// structurally-valid state would make restore a no-op that still reports
    /// success, so the caller would clear the snapshot and disarm the watchdog
    /// while the proxy stays dangling. Partially-invalid services are fine:
    /// `NetworksetupCommands.restore` sanitizes per field (turning a bad field
    /// off rather than dropping the whole service).
    private static func checkRestorable(_ snapshot: SystemProxySnapshot) throws {
        guard !snapshot.isEmpty else { return }
        let invalid = snapshot.filter { !$0.value.isValid }.keys.sorted()
        if !invalid.isEmpty {
            Log.system.error("restore: invalid service state for \(invalid.joined(separator: ", "))")
        }
        guard snapshot.contains(where: { $0.value.isValid }) else {
            throw ProxyHelperError.message("snapshot has no valid services to restore")
        }
    }

    /// Restores the user's original proxy state without any chance of an admin
    /// prompt. Used by the crash watchdog (a background process has no UI, so
    /// the `osascript` fallback must never run): it uses the privileged helper
    /// only if already registered, otherwise `networksetup` directly as the user.
    func restoreWithoutPrompt(snapshot: SystemProxySnapshot) throws {
        try Self.checkRestorable(snapshot)
        if helper.isRegistered {
            do {
                try helper.restoreProxy(snapshot: snapshot)
                return
            } catch {
                Log.system.warning("watchdog restore via helper failed, using direct: \(error.localizedDescription)")
            }
        }
        try runDirect(NetworksetupCommands.restore(snapshot: snapshot))
    }

    private func useHelper() -> Bool {
        if let usable = helperUsable { return usable }
        let usable: Bool
        do {
            try helper.register()
            usable = helper.isRegistered
        } catch {
            usable = false
        }
        helperUsable = usable
        return usable
    }

    /// Executes a `networksetup` mutation with the least privilege that works:
    ///
    /// 1. **Helper daemon (root)** — used when registered (signed installs);
    ///    registration is a one-time admin grant, so toggles never re-prompt.
    /// 2. **`networksetup` as the current user** — HTTP(S)/PAC proxy settings
    ///    for the logged-in user's services are per-user and need no root, so
    ///    this path is prompt-free (this is also why `./revert.sh` never asks).
    /// 3. **`osascript ... with administrator privileges`** — only when direct
    ///    access genuinely fails (non-admin account, MDM-managed services),
    ///    since it pops a native password dialog on every call.
    private func runMutations(commands: [[String]], viaHelper: () throws -> Void) throws {
        if useHelper() {
            do {
                try viaHelper()
                return
            } catch {
                // Helper failed at runtime — don't trust it again this session.
                helperUsable = false
            }
        }
        do {
            try runDirect(commands)
        } catch {
            Log.system.warning("networksetup as user failed, escalating to admin: \(error.localizedDescription)")
            try runAdmin(commands.map { shell($0) })
        }
    }

    /// Runs `networksetup` argv arrays as the current user (no elevation).
    /// Stops at the first failing service and throws its stderr so callers can
    /// escalate. argv-only — no shell, so service names can't inject commands.
    private func runDirect(_ commands: [[String]]) throws {
        for args in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            process.arguments = args
            let errPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                throw SocketError.message("networksetup launch failed: \(error.localizedDescription)")
            }
            guard waitForExit(process, timeout: 20) else {
                throw SocketError.message("networksetup timed out")
            }
            guard process.terminationStatus == 0 else {
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? "networksetup failed"
                throw SocketError.message(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// Converts a `networksetup` argv array into a single-quoted shell command.
    private func shell(_ args: [String]) -> String {
        "/usr/sbin/networksetup " + args.map(quote).joined(separator: " ")
    }

    // MARK: - Helpers

    private func runRead(_ args: [String]) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            guard waitForExit(process, timeout: 20) else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return text.components(separatedBy: .newlines)
        } catch {
            return nil
        }
    }

    /// Bounded wait so a hung `networksetup` cannot block the app (or quit).
    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        return true
    }

    /// Runs the commands as root via `osascript`. The script is passed inline
    /// (properly escaped) rather than written to a user-writable temp file, which
    /// closed a TOCTOU root-escalation window.
    private func runAdmin(_ commands: [String]) throws {
        guard !commands.isEmpty else { return }
        // `set -e` so any individual networksetup failure fails the whole run.
        let shellLine = "set -e; " + commands.joined(separator: "; ")
        let appleScript = "do shell script \"\(appleScriptEscape(shellLine))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw SocketError.message("osascript launch failed: \(error.localizedDescription)")
        }

        // Bound the wait so a stuck admin prompt can't hang the app (or quit).
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw SocketError.message("osascript timed out")
        }

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw SocketError.message(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
