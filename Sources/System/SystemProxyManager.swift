import Foundation

/// Tri-state result of inspecting the system proxy. `.unknown` means at least
/// one required `networksetup` read failed, so "no match" is not evidence of a
/// clean machine.
enum ProxyCheck {
    case ours
    case clean
    case unknown
}

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
        listServicesChecked() ?? []
    }

    /// `nil` when the service list could not be read. Callers that make safety
    /// decisions must use this instead of `listServices()` (which maps a read
    /// failure to an empty, apparently-clean list).
    func listServicesChecked() -> [String]? {
        guard var lines = runRead(["-listallnetworkservices"]) else { return nil }
        if lines.first?.hasPrefix("An asterisk") == true { lines.removeFirst() }
        return lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") } // skip disabled services
    }

    /// Like `listServicesChecked()`, but keeps disabled services (name with the
    /// leading `*` stripped). Restore filtering must distinguish "temporarily
    /// disabled" from "deleted" — a disabled service still exists. `nil` when
    /// the list could not be read.
    func listServiceNamesIncludingDisabled() -> [String]? {
        guard var lines = runRead(["-listallnetworkservices"]) else { return nil }
        if lines.first?.hasPrefix("An asterisk") == true { lines.removeFirst() }
        return lines
            .map { NetworksetupCommands.normalizeServiceName($0) }
            .filter { !$0.isEmpty }
    }

    /// Captures the original proxy state for every service that is about to be
    /// proxied.
    ///
    /// Every field is required: a failed read must abort the capture rather than
    /// record a defaulted `off`/empty state, because restoring that later would
    /// turn the user's working proxy off.
    func captureSnapshot(services: [String]) throws -> SystemProxySnapshot {
        var snapshot = SystemProxySnapshot()
        for svc in services {
            guard let web = runRead(["-getwebproxy", svc]),
                  let sec = runRead(["-getsecurewebproxy", svc]),
                  let pac = runRead(["-getautoproxyurl", svc]),
                  let discovery = runRead(["-getproxyautodiscovery", svc]),
                  let bypass = runRead(["-getproxybypassdomains", svc]) else {
                throw SocketError.message("cannot read the current proxy settings for \(svc); refusing to capture a partial snapshot")
            }
            var state = ServiceProxyState()
            parseProxyOutput(web, enabled: &state.webEnabled, server: &state.webServer,
                             port: &state.webPort, authenticated: &state.webAuthenticated)
            parseProxyOutput(sec, enabled: &state.secureEnabled, server: &state.secureServer,
                             port: &state.securePort, authenticated: &state.secureAuthenticated)
            state.pacEnabled = pac.contains(where: { $0.hasPrefix("Enabled:") && $0.lowercased().contains("yes") })
            for line in pac where line.hasPrefix("URL:") {
                state.pacURL = ServiceProxyState.normalizePAC(String(line.dropFirst("URL:".count)))
            }
            state.autoDiscoveryEnabled = parseAutoDiscovery(discovery)
            state.bypassDomains = bypass
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("there aren't any") }
            snapshot[svc] = state
        }
        return snapshot
    }

    /// Inspects every enabled service for an HTTP(S) proxy at `127.0.0.1` on
    /// `port` (0 = any port). The crash watchdog uses this to confirm the
    /// dangling proxy is ours before restoring, so it never clobbers a proxy the
    /// user set themselves. Any read failure yields `.unknown`, never `.clean`.
    func proxyCheck(port: UInt16) -> ProxyCheck {
        guard let services = listServicesChecked() else { return .unknown }
        var sawOurs = false
        var sawUnknown = false
        for svc in services {
            for args in [["-getwebproxy", svc], ["-getsecurewebproxy", svc]] {
                switch proxyStatus(args, port: port) {
                case .ours: sawOurs = true
                case .unknown: sawUnknown = true
                case .clean: break
                }
            }
        }
        if sawOurs { return .ours }
        if sawUnknown { return .unknown }
        return .clean
    }

    private func proxyStatus(_ args: [String], port: UInt16) -> ProxyCheck {
        guard let lines = runRead(args) else { return .unknown }
        return statePointsAtLocalhost(lines, port: port) ? .ours : .clean
    }

    private func parseProxyOutput(_ lines: [String], enabled: inout Bool, server: inout String,
                                  port: inout String, authenticated: inout Bool) {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Enabled:") {
                enabled = trimmed.lowercased().contains("yes")
            } else if trimmed.hasPrefix("Server:") {
                server = String(trimmed.dropFirst("Server:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Port:") {
                port = String(trimmed.dropFirst("Port:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Authenticated Proxy Enabled:") {
                authenticated = String(trimmed.dropFirst("Authenticated Proxy Enabled:".count))
                    .trimmingCharacters(in: .whitespaces) == "1"
            }
        }
    }

    /// `-getproxyautodiscovery` prints `Auto Proxy Discovery: On|Off`.
    private func parseAutoDiscovery(_ lines: [String]) -> Bool {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("auto proxy discovery:") else { continue }
            let value = String(trimmed.dropFirst("Auto Proxy Discovery:".count))
                .trimmingCharacters(in: .whitespaces)
            return value.lowercased() == "on"
        }
        return false
    }

    // MARK: - Mutations (helper → direct-as-user → osascript)

    func applyProxy(services: [String], port: UInt16, host: String = "127.0.0.1") throws {
        guard !services.isEmpty else {
            throw SocketError.message("refusing to apply the system proxy with no network services")
        }
        guard NetworksetupCommands.isValidProxyServer(host) else {
            throw SocketError.message("invalid system proxy host '\(host)'")
        }
        try runMutations(commands: NetworksetupCommands.applyProxy(services: services, port: Int(port), host: host)) {
            try helper.applyProxy(services: services, port: Int(port), host: host)
        }
    }

    func clearProxy(services: [String]) throws {
        let targets = existingOnly(services)
        guard !targets.isEmpty else { return }
        try runMutations(commands: NetworksetupCommands.clearProxy(services: targets),
                         tolerateMissingServices: true) {
            try helper.clearProxy(services: targets)
        }
    }

    /// Restricts `services` to names that still exist, when the list can be
    /// read. A read failure returns the input unchanged: skipping a service we
    /// cannot verify is worse than letting `networksetup` report it missing
    /// (which the tolerant runners now skip).
    private func existingOnly(_ services: [String]) -> [String] {
        guard !services.isEmpty else { return services }
        guard let current = listServiceNamesIncludingDisabled() else {
            Log.system.warning("cannot read network services; not filtering \(services.count) service(s)")
            return services
        }
        let existing = Set(current)
        return services.filter { existing.contains($0) }
    }

    private func existingSnapshot(_ snapshot: SystemProxySnapshot) -> SystemProxySnapshot {
        guard let current = listServiceNamesIncludingDisabled() else {
            Log.system.warning("cannot read network services; restoring full snapshot")
            return snapshot
        }
        return NetworksetupCommands.filterSnapshot(snapshot, toExisting: current)
    }

    /// Clears only services that are provably pointing at our local proxy on
    /// `port` (0 = any port). Throws when any required read fails, so the
    /// watchdog can keep itself armed instead of disarming on unknown state.
    /// Services with a non-local or different-port proxy are never touched.
    func clearLocalProxies(port: UInt16) throws {
        guard let services = listServicesChecked() else {
            throw SocketError.message("cannot read network services")
        }
        var targets: [String] = []
        for svc in services {
            var local = false
            for args in [["-getwebproxy", svc], ["-getsecurewebproxy", svc]] {
                guard let lines = runRead(args) else {
                    throw SocketError.message("cannot read proxy state for \(svc)")
                }
                if statePointsAtLocalhost(lines, port: port) { local = true }
            }
            if local { targets.append(svc) }
        }
        guard !targets.isEmpty else { return }
        try clearWithoutPrompt(services: targets)
    }

    /// Clears services without any chance of an admin prompt. Used by the crash
    /// watchdog, which runs as a background LaunchAgent with no UI: the
    /// `osascript` fallback in `clearProxy` must never run there.
    func clearWithoutPrompt(services: [String]) throws {
        if helper.isRegistered {
            do {
                try helper.clearProxy(services: services)
                return
            } catch {
                Log.system.warning("watchdog clear via helper failed, using direct: \(error.localizedDescription)")
            }
        }
        try runDirect(NetworksetupCommands.clearProxy(services: services), tolerateMissingServices: true)
    }

    /// Last-resort sweep after a successful restore: a service that appeared
    /// after enable was proxied but may not be in the snapshot (if coverage
    /// failed, or it appeared through a path that did not re-apply). Clear only
    /// services absent from the snapshot whose HTTP/HTTPS proxy is enabled at
    /// `127.0.0.1` on `port`, prompt-free. Best effort: read failures are logged
    /// and skipped so they can never turn a successful disable into a failure.
    func clearUnsnapshottedLocalProxies(snapshot: SystemProxySnapshot, port: UInt16) {
        guard let services = listServicesChecked() else {
            Log.system.warning("post-restore sweep: cannot read network services; skipping")
            return
        }
        var targets: [String] = []
        for svc in services where snapshot[svc] == nil {
            guard let web = runRead(["-getwebproxy", svc]),
                  let secure = runRead(["-getsecurewebproxy", svc]) else {
                Log.system.warning("post-restore sweep: cannot read proxy state for \(svc); skipping")
                continue
            }
            if statePointsAtLocalhost(web, port: port) || statePointsAtLocalhost(secure, port: port) {
                targets.append(svc)
            }
        }
        guard !targets.isEmpty else { return }
        Log.system.notice("post-restore sweep: clearing unsnapshotted service(s): \(targets.joined(separator: ", "))")
        do {
            try clearWithoutPrompt(services: targets)
        } catch {
            Log.system.error("post-restore sweep failed: \(error.localizedDescription)")
        }
    }

    private func statePointsAtLocalhost(_ lines: [String], port: UInt16) -> Bool {
        var enabled = false
        var server = ""
        var foundPort = ""
        var authenticated = false
        parseProxyOutput(lines, enabled: &enabled, server: &server, port: &foundPort,
                         authenticated: &authenticated)
        guard enabled && server == "127.0.0.1" else { return false }
        return port == 0 || foundPort == String(port)
    }

    func restore(snapshot: SystemProxySnapshot) throws {
        try Self.checkRestorable(snapshot)
        // A genuinely empty snapshot means there is nothing of ours to restore.
        guard !snapshot.isEmpty else { return }
        let filtered = existingSnapshot(snapshot)
        let commands = NetworksetupCommands.restore(snapshot: filtered)
        guard !commands.isEmpty else {
            throw SocketError.message("snapshot has no restorable commands (all services filtered or invalid)")
        }
        try runMutations(commands: commands, tolerateMissingServices: true) {
            try helper.restoreProxy(snapshot: filtered)
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
        guard !snapshot.isEmpty else { return }
        let filtered = existingSnapshot(snapshot)
        let commands = NetworksetupCommands.restore(snapshot: filtered)
        guard !commands.isEmpty else {
            throw SocketError.message("snapshot has no restorable commands (all services filtered or invalid)")
        }
        if helper.isRegistered {
            do {
                try helper.restoreProxy(snapshot: filtered)
                return
            } catch {
                Log.system.warning("watchdog restore via helper failed, using direct: \(error.localizedDescription)")
            }
        }
        try runDirect(commands, tolerateMissingServices: true)
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
    private func runMutations(commands: [[String]], tolerateMissingServices: Bool = false,
                              viaHelper: () throws -> Void) throws {
        guard !commands.isEmpty else {
            throw SocketError.message("refusing to run an empty networksetup command list")
        }
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
            try runDirect(commands, tolerateMissingServices: tolerateMissingServices)
        } catch {
            Log.system.warning("networksetup as user failed, escalating to admin: \(error.localizedDescription)")
            try runAdmin(commands.map { shell($0) })
        }
    }

    /// Runs `networksetup` argv arrays as the current user (no elevation).
    /// argv-only — no shell, so service names can't inject commands.
    ///
    /// With `tolerateMissingServices`, a failure caused by a service that no
    /// longer exists is skipped and processing continues (the rest of the
    /// snapshot still restores). The first real error is thrown after the whole
    /// list has been attempted; if every failure was a missing service, this
    /// succeeds because there is nothing left to restore.
    private func runDirect(_ commands: [[String]], tolerateMissingServices: Bool = false) throws {
        guard !commands.isEmpty else {
            throw SocketError.message("refusing to run an empty networksetup command list")
        }
        var firstRealError: String?
        for args in commands {
            let result = BoundedProcess.run(executable: "/usr/sbin/networksetup",
                                            arguments: args,
                                            timeout: 20)
            if let error = result.launchError {
                throw SocketError.message("networksetup launch failed: \(error)")
            }
            if result.timedOut {
                throw SocketError.message("networksetup timed out")
            }
            if result.status != 0 {
                let text = String(data: result.stderrData, encoding: .utf8) ?? "networksetup failed"
                let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if tolerateMissingServices && NetworksetupCommands.isMissingServiceError(message) {
                    Log.system.notice("networksetup: skipping missing service \(args.count > 1 ? args[1] : "?")")
                    continue
                }
                if !tolerateMissingServices {
                    throw SocketError.message(message)
                }
                if firstRealError == nil { firstRealError = message }
            }
        }
        if let firstRealError { throw SocketError.message(firstRealError) }
    }

    /// Converts a `networksetup` argv array into a single-quoted shell command.
    private func shell(_ args: [String]) -> String {
        "/usr/sbin/networksetup " + args.map(quote).joined(separator: " ")
    }

    // MARK: - Helpers

    private func runRead(_ args: [String]) -> [String]? {
        let result = BoundedProcess.run(executable: "/usr/sbin/networksetup",
                                        arguments: args,
                                        timeout: 20)
        // Launch failure, timeout, and a non-zero exit are all failed reads,
        // not empty results: treating them as data would let a safety check
        // mistake a broken read for "clean".
        guard result.launchError == nil, !result.timedOut, result.status == 0,
              let text = String(data: result.stdoutData, encoding: .utf8) else { return nil }
        return text.components(separatedBy: .newlines)
    }

    /// Runs the commands as root via `osascript`. The script is passed inline
    /// (properly escaped) rather than written to a user-writable temp file, which
    /// closed a TOCTOU root-escalation window.
    private func runAdmin(_ commands: [String]) throws {
        guard !commands.isEmpty else { return }
        // `set -e` so any individual networksetup failure fails the whole run.
        let shellLine = "set -e; " + commands.joined(separator: "; ")
        let appleScript = "do shell script \"\(appleScriptEscape(shellLine))\" with administrator privileges"
        // On timeout, kill osascript's whole tree: `do shell script` runs a
        // shell, which in turn spawns `networksetup`. Killing only osascript
        // would let the remaining commands finish (and mutate) in the
        // background after we have already reported the failure.
        let result = BoundedProcess.run(executable: "/usr/bin/osascript",
                                        arguments: ["-e", appleScript],
                                        timeout: 180,
                                        killTreeOnTimeout: true)
        if let error = result.launchError {
            throw SocketError.message("osascript launch failed: \(error)")
        }
        if result.timedOut {
            throw SocketError.message("osascript timed out")
        }

        guard result.status == 0 else {
            let errText = String(data: result.stderrData, encoding: .utf8) ?? "unknown error"
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
