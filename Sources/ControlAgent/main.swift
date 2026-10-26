import Foundation
import AppKit
import Security
import Darwin

// The control agent is a per-user LaunchAgent that exposes a Mach service to
// other apps and relays their requests to the running app over the local
// control socket. It owns no state: the app decides consent and executes.
//
// It exists because a GUI app cannot own a launchd Mach service by itself.
// Keeping the transport in a separate process also means the app can quit
// without unregistering the service.

signal(SIGPIPE, SIG_IGN)

enum AgentPaths {
    static let bundleID = "com.proxymanager.app"
    static let machService = "com.proxymanager.control"

    static var supportDir: URL {
        if let override = ProcessInfo.processInfo.environment["PROXYMANAGER_SUPPORT_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("ProxyManager", isDirectory: true)
    }

    static var socketPath: String { supportDir.appendingPathComponent("control.sock").path }
    static var tokenPath: String { supportDir.appendingPathComponent("control.token").path }
}

// MARK: - Protocol

@objc protocol ControlAgentProtocol {
    func ping(withReply reply: @escaping (Bool) -> Void)
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

// MARK: - Identity

enum ControlIdentityResolver {
    static func identity(for connection: NSXPCConnection) -> ControlIdentity {
        let pid = connection.processIdentifier
        // NSXPCConnection does not expose its audit token. A PID lookup can race
        // with PID reuse, but the consent decision is keyed by the resulting
        // designated requirement, so a reused PID presents a different identity
        // and is re-prompted rather than inheriting a grant.
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            return fallback(pid: pid, path: nil)
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return fallback(pid: pid, path: nil)
        }

        var info: CFDictionary?
        var team: String?
        var identifier: String?
        if SecCodeCopySigningInformation(staticCode,
                                         SecCSFlags(rawValue: kSecCSSigningInformation),
                                         &info) == errSecSuccess,
           let dictionary = info as? [String: Any] {
            team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
            identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        }

        var pathURL: CFURL?
        var path: String?
        if SecCodeCopyPath(staticCode, [], &pathURL) == errSecSuccess {
            path = (pathURL as URL?)?.path
        }

        var requirementString: String?
        var requirement: SecRequirement?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
           let requirement {
            var string: CFString?
            if SecRequirementCopyString(requirement, [], &string) == errSecSuccess {
                requirementString = string as String?
            }
        }

        return ControlIdentity(
            pid: pid,
            bundleID: identifier,
            teamID: team,
            requirement: requirementString ?? "",
            displayName: displayName(path: path, identifier: identifier),
            path: path
        )
    }

    private static func displayName(path: String?, identifier: String?) -> String {
        guard let path else { return identifier ?? "an unsigned process" }
        if let bundle = Bundle(path: path) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
                return name
            }
        }
        return identifier ?? URL(fileURLWithPath: path).lastPathComponent
    }

    private static func fallback(pid: Int32, path: String?) -> ControlIdentity {
        ControlIdentity(
            pid: pid,
            bundleID: nil,
            teamID: nil,
            requirement: "",
            displayName: path.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "pid \(pid)",
            path: path
        )
    }
}

// MARK: - Relay

enum ControlRelay {
    private static let queue = DispatchQueue(
        label: "com.proxymanager.control-agent.relay", attributes: .concurrent
    )

    static func send(_ request: IntegrationRequest,
                     identity: ControlIdentity,
                     completion: @escaping (IntegrationResult) -> Void) {
        queue.async {
            completion(sendSync(request, identity: identity))
        }
    }

    private static func sendSync(_ request: IntegrationRequest,
                                 identity: ControlIdentity) -> IntegrationResult {
        let deadline = Date().addingTimeInterval(30)
        var launched = false

        while Date() < deadline {
            if let token = readToken(), let fd = connect() {
                defer { close(fd) }
                do {
                    let envelope = ControlRequest(
                        token: token, identity: identity, request: request
                    )
                    try ControlFraming.writeFrame(fd, ControlFraming.encode(envelope))
                    let reply = try ControlFraming.decode(
                        ControlResponse.self,
                        from: ControlFraming.readFrame(fd, timeoutMs: 25_000)
                    )
                    return reply.result
                } catch {
                    // The app may have quit between connect and read; fall
                    // through and retry after relaunching it.
                    Log.integration.debug("agent: relay failed: \(String(describing: error), privacy: .public)")
                }
            }

            if !launched {
                launched = true
                launchApp()
            }
            usleep(400_000)
        }

        return IntegrationResult(
            id: request.id, action: request.action, ok: false,
            error: IntegrationError(.unavailable, "Proxy Manager is not running")
        )
    }

    private static func readToken() -> String? {
        guard let token = try? String(contentsOfFile: AgentPaths.tokenPath,
                                      encoding: .utf8) else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        ControlSocket.setNoSigPipe(fd)
        guard ControlSocket.connect(fd, path: AgentPaths.socketPath) else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func launchApp() {
        guard let bundle = appBundleURL() else {
            Log.integration.error("agent: could not locate the app bundle")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            if let error {
                Log.integration.error("agent: could not launch the app: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func appBundleURL() -> URL? {
        var url = Bundle.main.bundleURL
        if url.pathExtension == "app" { return url }
        url = Bundle.main.executableURL ?? url
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

// MARK: - Service

final class ControlAgentService: NSObject, ControlAgentProtocol {
    private let identity: ControlIdentity

    init(identity: ControlIdentity) {
        self.identity = identity
    }

    func ping(withReply reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard let decoded = try? ControlFraming.decode(IntegrationRequest.self, from: request) else {
            let failure = IntegrationResult(
                id: "", action: "", ok: false,
                error: IntegrationError(.badRequest, "malformed request")
            )
            reply((try? ControlFraming.encode(failure)) ?? Data())
            return
        }

        ControlRelay.send(decoded, identity: identity) { result in
            reply((try? ControlFraming.encode(result)) ?? Data())
        }
    }
}

final class ControlAgentDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let identity = ControlIdentityResolver.identity(for: connection)
        connection.exportedInterface = NSXPCInterface(with: ControlAgentProtocol.self)
        connection.exportedObject = ControlAgentService(identity: identity)
        connection.resume()
        Log.integration.debug("agent: accepted \(identity.displayName, privacy: .public)")
        return true
    }
}

let delegate = ControlAgentDelegate()
let listener = NSXPCListener(machServiceName: AgentPaths.machService)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
