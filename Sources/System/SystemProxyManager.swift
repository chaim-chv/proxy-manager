import Foundation

/// Tri-state result of inspecting the system proxy. `.unknown` means at least
/// one required `networksetup` read failed, so "no match" is not evidence of a
/// clean machine.
enum ProxyCheck {
    case ours
    case clean
    case unknown
}

/// Admin authorization was needed but the session cannot safely show a dialog.
/// This is a **deferral**, not a failure: nothing was escalated, and the caller
/// may retry once the session is interactive again.
enum ProxyAuthorizationError: Error, LocalizedError {
    case deferred(reason: String?)

    var errorDescription: String? {
        "Administrator authorization is needed, but the session is locked or asleep. "
        + "Proxy Manager will retry when you return."
    }

    var reason: String? {
        if case .deferred(let reason) = self { return reason }
        return nil
    }

    var isDeferred: Bool { true }
}

/// Test seam for child-process execution. Production uses `BoundedProcess`.
struct ProcessRunner {
    var run: (_ executable: String, _ arguments: [String],
              _ timeout: TimeInterval, _ killTreeOnTimeout: Bool) -> BoundedProcessResult

    static let live = ProcessRunner { executable, arguments, timeout, killTree in
        BoundedProcess.run(executable: executable, arguments: arguments,
                           timeout: timeout, killTreeOnTimeout: killTree)
    }
}

/// Manages the macOS system proxy (HTTP + HTTPS) on all network services.
///
/// Mutations use the least privilege that works: the privileged helper daemon
/// when it is registered **and** answering, then `networksetup` run directly as
/// the current user (prompt-free). An `osascript ... with administrator
/// privileges` dialog is only ever shown for an explicit user action in an
/// interactive session; a background mutation defers instead. Read operations
/// run directly.
final class SystemProxyManager {
    private let helper = HelperXPCClient()
    private let runner: ProcessRunner
    private let session: SessionState
    /// Test seam: overrides the real helper probe. `nil` = probe the daemon.
    private let helperReadyOverride: (() -> Bool)?

    /// Cached tri-state: nil = not yet determined.
    private var helperUsable: Bool?

    init(runner: ProcessRunner = .live,
         session: SessionState = .shared,
         helperReady: (() -> Bool)? = nil) {
        self.runner = runner
        self.session = session
        self.helperReadyOverride = helperReady
    }

    // MARK: - Helper availability

    /// Whether the privileged helper can serve this session. Probe once (a ping
    /// costs an XPC round trip) and cache; a later Install Helper action calls
    /// `invalidateHelperCache()`.
    private func helperIsReady() -> Bool {
        if let helperReadyOverride { return helperReadyOverride() }
        if let usable = helperUsable { return usable }
        let usable = helper.state.isReady
        helperUsable = usable
        if usable {
            Log.system.notice("auth helper=ready")
        } else {
            Log.system.notice("auth helper=unavailable")
        }
        return usable
    }

    /// Drops the cached helper verdict so the next mutation re-probes.
    func invalidateHelperCache() {
        helperUsable = nil
    }

    func currentHelperState() -> HelperState {
        if let helperReadyOverride { return helperReadyOverride() ? .ready : .notInstalled }
        return helper.state
    }

    /// Foreground-only registration (Settings/Onboarding button).
    func registerHelperFromUser() throws {
        try helper.registerFromUser()
        invalidateHelperCache()
    }

    func openLoginItemsSettings() {
        helper.openSystemSettingsLoginItems()
    }

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

    // MARK: - Mutations (helper → direct-as-user → osascript, user-initiated only)

    func applyProxy(services: [String], port: UInt16, host: String = "127.0.0.1",
                    allowAdminPrompt: Bool = false) throws {
        guard !services.isEmpty else {
            throw SocketError.message("refusing to apply the system proxy with no network services")
        }
        guard NetworksetupCommands.isValidProxyServer(host) else {
            throw SocketError.message("invalid system proxy host '\(host)'")
        }
        try runMutations(commands: NetworksetupCommands.applyProxy(services: services, port: Int(port), host: host),
                         allowAdminPrompt: allowAdminPrompt) {
            try helper.applyProxy(services: services, port: Int(port), host: host)
        }
    }

    func clearProxy(services: [String], allowAdminPrompt: Bool = false) throws {
        let targets = existingOnly(services)
        guard !targets.isEmpty else { return }
        try runMutations(commands: NetworksetupCommands.clearProxy(services: targets),
                         tolerateMissingServices: true,
                         allowAdminPrompt: allowAdminPrompt) {
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
        if helperIsReady() {
            do {
                try helper.clearProxy(services: services)
                Log.system.notice("auth path=helper reason=watchdog-clear result=ok")
                return
            } catch {
                // The watchdog has no UI and must restore connectivity: try the
                // prompt-free direct path for any helper failure (a command
                // rejection here is still better served by a direct retry).
                helperUsable = false
                Log.system.warning("watchdog clear via helper failed, using direct: \(error.localizedDescription)")
            }
        }
        try runDirect(NetworksetupCommands.clearProxy(services: services), tolerateMissingServices: true)
        Log.system.notice("auth path=direct reason=watchdog-clear result=ok")
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

    func restore(snapshot: SystemProxySnapshot, allowAdminPrompt: Bool = false) throws {
        try Self.checkRestorable(snapshot)
        // A genuinely empty snapshot means there is nothing of ours to restore.
        guard !snapshot.isEmpty else { return }
        let filtered = existingSnapshot(snapshot)
        let commands = NetworksetupCommands.restore(snapshot: filtered)
        guard !commands.isEmpty else {
            throw SocketError.message("snapshot has no restorable commands (all services filtered or invalid)")
        }
        try runMutations(commands: commands, tolerateMissingServices: true,
                         allowAdminPrompt: allowAdminPrompt) {
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
    /// only if already registered and answering, otherwise `networksetup`
    /// directly as the user.
    func restoreWithoutPrompt(snapshot: SystemProxySnapshot) throws {
        try Self.checkRestorable(snapshot)
        guard !snapshot.isEmpty else { return }
        let filtered = existingSnapshot(snapshot)
        let commands = NetworksetupCommands.restore(snapshot: filtered)
        guard !commands.isEmpty else {
            throw SocketError.message("snapshot has no restorable commands (all services filtered or invalid)")
        }
        if helperIsReady() {
            do {
                try helper.restoreProxy(snapshot: filtered)
                Log.system.notice("auth path=helper reason=watchdog-restore result=ok")
                return
            } catch {
                // Prompt-free recovery must not be blocked by a helper error.
                helperUsable = false
                Log.system.warning("watchdog restore via helper failed, using direct: \(error.localizedDescription)")
            }
        }
        try runDirect(commands, tolerateMissingServices: true)
        Log.system.notice("auth path=direct reason=watchdog-restore result=ok")
    }

    /// Executes a `networksetup` mutation with the least privilege that works:
    ///
    /// 1. **Helper daemon (root)** — used when registered and answering (signed
    ///    installs); installation is a one-time user action, so toggles never
    ///    re-prompt.
    /// 2. **`networksetup` as the current user** — HTTP(S)/PAC proxy settings
    ///    for the logged-in user's services are per-user and need no root, so
    ///    this path is prompt-free (this is also why `./revert.sh` never asks).
    /// 3. **`osascript ... with administrator privileges`** — only when
    ///    `allowAdminPrompt` is true (an explicit user action) **and** the
    ///    session is interactive. Everything else defers: a background admin
    ///    prompt can deadlock macOS `authd` and freeze the lock screen.
    private func runMutations(commands: [[String]], tolerateMissingServices: Bool = false,
                              allowAdminPrompt: Bool,
                              viaHelper: () throws -> Void) throws {
        guard !commands.isEmpty else {
            throw SocketError.message("refusing to run an empty networksetup command list")
        }
        if helperIsReady() {
            do {
                try viaHelper()
                Log.system.notice("auth path=helper result=ok")
                return
            } catch let error as ProxyHelperError where error.isTransportFailure {
                // Helper went away mid-session — don't trust it again until the
                // user re-installs/re-probes it.
                helperUsable = false
                Log.system.warning("helper transport failed, using direct: \(error.localizedDescription)")
            } catch {
                // A real command/authorization error: propagate it. Falling back
                // would mask signing and input bugs as "helper unusable".
                Log.system.error("helper rejected the mutation: \(error.localizedDescription)")
                throw error
            }
        }
        do {
            try runDirect(commands, tolerateMissingServices: tolerateMissingServices)
            Log.system.notice("auth path=direct result=ok")
        } catch {
            let directError = error
            guard allowAdminPrompt, session.canPrompt else {
                let reason = allowAdminPrompt ? "session-not-interactive" : "background"
                Log.system.notice("auth path=deferred reason=\(reason, privacy: .public)")
                throw ProxyAuthorizationError.deferred(reason: directError.localizedDescription)
            }
            Log.system.notice("auth path=admin result=attempt")
            try runAdmin(commands.map { shell($0) })
            Log.system.notice("auth path=admin result=ok")
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
            let result = runner.run("/usr/sbin/networksetup", args, 20, false)
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
        let result = runner.run("/usr/sbin/networksetup", args, 20, false)
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
    ///
    /// Guarded by `SessionState.canPrompt` as defense in depth: even a mistaken
    /// `allowAdminPrompt: true` can never raise a SecurityAgent dialog while the
    /// screen is locked or the Mac is asleep.
    private func runAdmin(_ commands: [String]) throws {
        guard !commands.isEmpty else { return }
        guard session.canPrompt else {
            Log.system.notice("auth path=deferred reason=canPrompt-false")
            throw ProxyAuthorizationError.deferred(reason: "the session is locked, asleep, or not active")
        }
        // `set -e` so any individual networksetup failure fails the whole run.
        let shellLine = "set -e; " + commands.joined(separator: "; ")
        let appleScript = "do shell script \"\(appleScriptEscape(shellLine))\" with administrator privileges"
        // On timeout, kill osascript's whole tree: `do shell script` runs a
        // shell, which in turn spawns `networksetup`. Killing only osascript
        // would let the remaining commands finish (and mutate) in the
        // background after we have already reported the failure.
        let result = runner.run("/usr/bin/osascript", ["-e", appleScript], 30, true)
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
