import Foundation
import AppKit
import CoreGraphics

/// Tracks whether the GUI session can safely show an authorization dialog.
///
/// A privileged `osascript … with administrator privileges` request from a
/// locked, asleep, or inactive session can wedge macOS `authd` and freeze the
/// login UI (see `docs/tasks/authd-unlock-deadlock/`). Every admin path must ask
/// this type first.
///
/// Safe to read from any thread: the event flags are lock-guarded and the
/// CoreGraphics session query is thread-safe. Notification observers update on
/// the main queue.
final class SessionState {
    static let shared = SessionState()

    /// How long after an explicit UI action the app still counts as
    /// user-present. Menu-bar menus do not always make the app frontmost, so
    /// `isActive` alone would refuse a prompt the user just asked for.
    static let userActionWindow: TimeInterval = 60

    private let lock = NSLock()
    private var asleep = false
    private var sessionInactive = false
    private var lastUserActionAt: Date?
    private var interactiveObservers: [UUID: () -> Void] = [:]

    /// Test seam: when set, `canPrompt` returns this value verbatim.
    /// Never set by the app.
    var canPromptOverride: Bool?

    /// Test seam: when set, `isInteractive` uses this instead of the real
    /// session dictionary.
    var isInteractiveOverride: Bool?

    private init() {
        let wc = NSWorkspace.shared.notificationCenter
        observer(wc, NSWorkspace.willSleepNotification) { $0.set(asleep: true) }
        observer(wc, NSWorkspace.didWakeNotification) { $0.set(asleep: false) }
        observer(wc, NSWorkspace.screensDidSleepNotification) { $0.set(asleep: true) }
        observer(wc, NSWorkspace.screensDidWakeNotification) { $0.set(asleep: false) }
        observer(wc, NSWorkspace.sessionDidResignActiveNotification) { $0.set(sessionInactive: true) }
        observer(wc, NSWorkspace.sessionDidBecomeActiveNotification) { $0.set(sessionInactive: false) }

        // A plain lock→unlock does not post the NSWorkspace session notifications
        // above (they cover sleep and fast user switching). These distributed
        // notifications are only a *trigger* to re-read the authoritative
        // CoreGraphics session flags; a missed one is covered by AppModel's
        // short-lived deferred-retry timer.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.screenLockChanged(locked: true)
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.screenLockChanged(locked: false)
        }
    }

    private func screenLockChanged(locked: Bool) {
        if locked { Log.system.notice("session: screen locked") } else { Log.system.notice("session: screen unlocked") }
        if !locked { notifyBecameInteractive() }
    }

    private func observer(_ center: NotificationCenter, _ name: NSNotification.Name,
                          _ handler: @escaping (SessionState) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            handler(self)
        }
    }

    private func set(asleep value: Bool) {
        lock.lock()
        asleep = value
        lock.unlock()
        Log.system.notice("\(value ? "session: asleep" : "session: awake")")
        if !value { notifyBecameInteractive() }
    }

    private func set(sessionInactive value: Bool) {
        lock.lock()
        sessionInactive = value
        lock.unlock()
        Log.system.notice("session: \(value ? "inactive" : "active")")
        if !value { notifyBecameInteractive() }
    }

    /// Registers a handler run (on the main queue) whenever the session becomes
    /// interactive — unlock, wake, or session activation. Returns a token for
    /// `removeInteractiveObserver`.
    func onBecameInteractive(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        interactiveObservers[id] = handler
        lock.unlock()
        return id
    }

    func removeInteractiveObserver(_ id: UUID) {
        lock.lock()
        interactiveObservers.removeValue(forKey: id)
        lock.unlock()
    }

    private func notifyBecameInteractive() {
        guard isInteractive else { return }
        lock.lock()
        let handlers = Array(interactiveObservers.values)
        lock.unlock()
        guard !handlers.isEmpty else { return }
        let run = { handlers.forEach { $0() } }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    /// Records an explicit user action (toggle, Install Helper, Retry). Only
    /// user-initiated paths may call this; it is never a substitute for the
    /// session check.
    func noteUserAction(at date: Date = Date()) {
        lock.lock()
        lastUserActionAt = date
        lock.unlock()
    }

    /// The session is on console, unlocked, awake, and active.
    var isInteractive: Bool {
        if let override = isInteractiveOverride { return override }
        let flags = currentSessionFlags()
        lock.lock()
        let asleep = self.asleep
        let inactive = self.sessionInactive
        lock.unlock()
        return flags.onConsole && !flags.locked && !asleep && !inactive
    }

    /// The session can safely show a SecurityAgent/admin dialog. Besides an
    /// interactive session the app must be frontmost (or the user must have
    /// acted in our UI moments ago) so the dialog is not hidden behind another
    /// app while the proxy waits on it.
    var canPrompt: Bool {
        if let override = canPromptOverride { return override }
        guard isInteractive else { return false }
        if NSRunningApplication.current.isActive { return true }
        lock.lock()
        let last = lastUserActionAt
        lock.unlock()
        guard let last else { return false }
        return Date().timeIntervalSince(last) <= Self.userActionWindow
    }

    /// `CGSessionCopyCurrentDictionary` keys. Declared as literals because the
    /// `kCGSSession…` symbols are not exposed to Swift on every SDK.
    static let onConsoleKey = "kCGSSessionOnConsoleKey"
    static let screenLockedKey = "CGSSessionScreenIsLocked"

    private func currentSessionFlags() -> (onConsole: Bool, locked: Bool) {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // No session dictionary: treat as non-interactive (fail safe).
            return (false, true)
        }
        let onConsole = dict[SessionState.onConsoleKey] as? Bool ?? false
        let locked = dict[SessionState.screenLockedKey] as? Bool ?? false
        return (onConsole, locked)
    }
}
