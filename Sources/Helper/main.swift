import Foundation
import Security
import Darwin

// Same belt-and-suspenders as the app: never die on a peer reset.
signal(SIGPIPE, SIG_IGN)

/// Entry point for the `ProxyManagerHelper` LaunchDaemon.
///
/// Installed and launched by `SMAppService.daemon` (macOS 13+). Exposes
/// `com.proxymanager.helper` over XPC to the app. Incoming connections are
/// authorized by code-signing Team ID before anything is exported.
final class HelperServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard Self.isAuthorized(newConnection.processIdentifier) else {
            NSLog("ProxyManagerHelper: rejected unauthorized connection from pid \(newConnection.processIdentifier)")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: ProxyManagerHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }

    /// Require the connecting process to be signed by the same (non-empty) Team
    /// ID as this helper daemon. Rejects arbitrary local processes.
    static func isAuthorized(_ pid: pid_t) -> Bool {
        guard let ourTeam = ownTeamIdentifier(), !ourTeam.isEmpty else { return false }
        guard let clientTeam = teamIdentifier(forProcessIdentifier: pid), !clientTeam.isEmpty else { return false }
        return ourTeam == clientTeam
    }

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code else { return nil }
        return teamIdentifier(forCode: code)
    }

    private static func teamIdentifier(forProcessIdentifier pid: pid_t) -> String? {
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code = code else { return nil }
        return teamIdentifier(forCode: code)
    }

    private static func teamIdentifier(forCode code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

let delegate = HelperServiceDelegate()
let listener = NSXPCListener(machServiceName: "com.proxymanager.helper")
listener.delegate = delegate
listener.resume()

RunLoop.current.run()
