import Foundation

/// The object exported over XPC. Runs as root (LaunchDaemon), so `networksetup`
/// needs no per-call authorization. All arguments are validated before use.
final class HelperService: NSObject, ProxyManagerHelperProtocol {
    func applyProxy(services: [String], port: Int, withReply reply: @escaping (Bool, String?) -> Void) {
        guard port >= 1 && port <= 65535 else {
            reply(false, "invalid port")
            return
        }
        let valid = services.filter(NetworksetupCommands.isValidService)
        guard !valid.isEmpty else {
            reply(false, "no valid network services")
            return
        }
        let result = run(NetworksetupCommands.applyProxy(services: valid, port: port))
        reply(result.0, result.1)
    }

    func clearProxy(services: [String], withReply reply: @escaping (Bool, String?) -> Void) {
        let valid = services.filter(NetworksetupCommands.isValidService)
        guard !valid.isEmpty else {
            reply(false, "no valid network services")
            return
        }
        let result = run(NetworksetupCommands.clearProxy(services: valid), tolerateMissingServices: true)
        reply(result.0, result.1)
    }

    func restoreProxy(snapshot: [String: [String: String]], withReply reply: @escaping (Bool, String?) -> Void) {
        // An empty snapshot means there is nothing to restore. But a non-empty
        // snapshot that yields no commands (every service invalid) must be
        // reported as failure — otherwise the app thinks it restored and clears
        // its only recovery state while the proxy stays dangling.
        guard !snapshot.isEmpty else {
            reply(true, nil)
            return
        }
        let valid = snapshot.filter { NetworksetupCommands.isValidService($0.key) }
        let snap = SystemProxySnapshot.from(xpcDictionary: valid)
        // Defense in depth: refuse a snapshot where no service is restorable
        // (per-field sanitizing still handles partially-invalid services).
        guard snap.isEmpty || snap.contains(where: { $0.value.isValid }) else {
            reply(false, "snapshot has no valid services")
            return
        }
        let commands = NetworksetupCommands.restore(snapshot: snap)
        guard !commands.isEmpty else {
            reply(false, "no valid network services")
            return
        }
        let result = run(commands, tolerateMissingServices: true)
        reply(result.0, result.1)
    }

    /// Runs a list of `networksetup` argv arrays.
    ///
    /// With `tolerateMissingServices`, services that no longer exist are skipped
    /// so one deleted USB/dock/VPN service cannot make the whole restore fail.
    /// The first real error is returned after attempting the rest; if every
    /// failure was a missing service, the result is success (nothing to
    /// restore). Apply stays intolerant (the default).
    private func run(_ commands: [[String]], tolerateMissingServices: Bool = false) -> (Bool, String?) {
        var firstRealError: String?
        for args in commands {
            let result = runOne(args)
            guard !result.0 else { continue }
            let message = result.1 ?? "networksetup failed"
            if tolerateMissingServices && NetworksetupCommands.isMissingServiceError(message) {
                continue
            }
            if !tolerateMissingServices { return (false, message) }
            if firstRealError == nil { firstRealError = message }
        }
        if let firstRealError { return (false, firstRealError) }
        return (true, nil)
    }

    private func runOne(_ args: [String]) -> (Bool, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = args
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        guard waitForExit(process, timeout: 20) else {
            return (false, "networksetup timed out")
        }
        guard process.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: data, encoding: .utf8) ?? "networksetup failed"
            return (false, err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (true, nil)
    }

    /// Bounded wait so a hung `networksetup` cannot block the helper forever.
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
}
