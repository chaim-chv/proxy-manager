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
        let result = run(NetworksetupCommands.clearProxy(services: valid))
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
        let commands = NetworksetupCommands.restore(snapshot: snap)
        guard !commands.isEmpty else {
            reply(false, "no valid network services")
            return
        }
        let result = run(commands)
        reply(result.0, result.1)
    }

    /// Runs a list of `networksetup` argv arrays. Stops at the first failure.
    private func run(_ commands: [[String]]) -> (Bool, String?) {
        for args in commands {
            let result = runOne(args)
            if !result.0 { return result }
        }
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
