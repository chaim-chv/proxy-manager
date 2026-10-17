import AppKit

/// Tracks the app's primary windows (the Dashboard and Settings) so a Dock icon
/// can be shown while one is open, even in `.menuBarOnly` mode.
///
/// Onboarding, sheets, the About panel, and Sparkle's windows are deliberately
/// not tracked: only the Dashboard and Settings should force the Dock icon.
final class AppWindowTracker: NSObject {
    static let shared = AppWindowTracker()

    private final class Entry {
        weak var window: NSWindow?
        var isOpen: Bool
        let observers: [NSObjectProtocol]

        init(window: NSWindow, isOpen: Bool, observers: [NSObjectProtocol]) {
            self.window = window
            self.isOpen = isOpen
            self.observers = observers
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var settingsWindowID: ObjectIdentifier?

    /// Called on the main queue whenever an open tracked window appears or closes.
    var onChange: (() -> Void)?

    var hasOpenWindow: Bool {
        entries.values.contains { entry in
            entry.window != nil && entry.isOpen
        }
    }

    private override init() {
        super.init()
    }

    func trackDashboardWindow(_ window: NSWindow) {
        track(window)
    }

    /// Called when the SwiftUI Settings view attaches to (or leaves) its window.
    func settingsWindowChanged(_ window: NSWindow?) {
        if let old = settingsWindowID, entries[old]?.window !== window {
            untrack(id: old)
        }
        guard let window else {
            settingsWindowID = nil
            return
        }
        settingsWindowID = ObjectIdentifier(window)
        track(window)
    }

    /// The frontmost open Dashboard/Settings window, if any.
    func frontmostOpenWindow() -> NSWindow? {
        let open = entries.values.compactMap { entry -> NSWindow? in
            guard entry.isOpen, let window = entry.window else { return nil }
            return window
        }
        guard !open.isEmpty else { return nil }
        return NSApp.orderedWindows.first { candidate in
            open.contains { $0 === candidate }
        } ?? open.first
    }

    private func track(_ window: NSWindow) {
        pruneDeadEntries()
        let id = ObjectIdentifier(window)
        guard entries[id] == nil else { return }

        // `isVisible` is KVO-compliant and fires on show, close, order-out, and
        // minimize, unlike the (nonexistent) "did become visible" notification.
        window.addObserver(self, forKeyPath: "visible", options: [.new], context: nil)
        window.addObserver(self, forKeyPath: "miniaturized", options: [.new], context: nil)

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.setOpen(false, for: window)
        }

        entries[id] = Entry(window: window,
                            isOpen: window.isVisible || window.isMiniaturized,
                            observers: [observer])
        onChange?()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == "visible" || keyPath == "miniaturized",
              let window = object as? NSWindow
        else { return }

        let open = window.isVisible || window.isMiniaturized
        // Hiding the app can order windows off screen; that does not close them.
        if !open && NSApp.isHidden { return }
        setOpen(open, for: window)
    }

    private func setOpen(_ open: Bool, for window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard let entry = entries[id], entry.isOpen != open else { return }
        entry.isOpen = open
        onChange?()
    }

    private func pruneDeadEntries() {
        let dead = entries.filter { $0.value.window == nil }.map { $0.key }
        for id in dead { untrack(id: id) }
    }

    private func untrack(id: ObjectIdentifier) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let window = entry.window {
            window.removeObserver(self, forKeyPath: "visible")
            window.removeObserver(self, forKeyPath: "miniaturized")
        }
        for observer in entry.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        onChange?()
    }
}
