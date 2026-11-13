import AppKit

/// Applies the Dock/activation policy only when it actually changes.
///
/// `NSApp.setActivationPolicy(_:)` runs a process-type transform even when the
/// policy is unchanged, and a transform deactivates the app. Applying a
/// redundant `.accessory` (e.g. while pruning a closed Dashboard entry) made
/// the Dock icon flash and left the just-opened Dashboard behind the previously
/// active app, so every transition goes through `apply`.
enum ActivationPolicy {
    /// The policy for an icon mode with the given window state.
    static func policy(iconMode: AppIconMode,
                       hasOpenWindow: Bool) -> NSApplication.ActivationPolicy {
        iconMode.dockIconVisible(hasOpenAppWindow: hasOpenWindow) ? .regular : .accessory
    }

    /// Applies `policy` on the main thread and reports whether a transform ran.
    /// Main-thread only: `setActivationPolicy` must not be called elsewhere.
    @discardableResult
    static func apply(_ policy: NSApplication.ActivationPolicy) -> Bool {
        guard NSApp.activationPolicy() != policy else { return false }
        NSApp.setActivationPolicy(policy)
        return true
    }
}
