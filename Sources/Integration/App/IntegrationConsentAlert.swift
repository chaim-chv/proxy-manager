import AppKit

/// The per-identity approval sheet.
///
/// Every unknown code identity is asked once; the answer is stored by designated
/// requirement, so a different binary claiming the same bundle id does not
/// inherit the grant. The sheet never appears while the session is locked: a
/// modal that nobody can answer would wedge the caller and the login UI.
final class IntegrationConsentAlert: IntegrationConsentProviding {
    func ask(for identity: ControlIdentity) -> IntegrationScope? {
        guard !DemoMode.isEnabled else { return nil }
        guard SessionState.shared.isInteractive else {
            Log.integration.notice("control: consent deferred; session is not interactive")
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow “\(identity.displayName)” to control Proxy Manager?"

        var details = identity.bundleID ?? identity.path ?? "An unsigned process"
        if let team = identity.teamID {
            details += " · Team \(team)"
        }
        if identity.requirement.isEmpty {
            details += "\nThis process is not code signed; approval is tied to its path."
        }
        alert.informativeText = """
        \(details)

        Control can turn routing on or off and edit targets and per-app rules.
        Read only can see status. The caller never gets an administrator prompt.
        """

        alert.addButton(withTitle: "Allow Control")
        alert.addButton(withTitle: "Read Only")
        alert.addButton(withTitle: "Deny")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .control
        case .alertSecondButtonReturn: return .read
        default: return nil
        }
    }
}
