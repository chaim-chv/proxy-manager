import Foundation
import ServiceManagement

enum ProxyHelperError: Error, LocalizedError {
    /// A generic, non-transport failure (for example invalid snapshot data).
    case message(String)
    /// The daemon is absent, not registered, or the XPC connection failed.
    /// Callers may fall back to the prompt-free direct path.
    case unavailable(String)
    /// The daemon answered but rejected/failed the command. This is a real
    /// command error, not a reason to fall back (it would mask signing or input
    /// bugs as "helper unusable").
    case remote(String)
    /// No reply within the deadline. Treated like `.unavailable`.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .unavailable(let text): return "Privileged helper unavailable: \(text)"
        case .remote(let text): return text
        case .timedOut: return "Privileged helper did not respond in time."
        }
    }

    /// True for failures where the prompt-free direct path is a sensible retry.
    var isTransportFailure: Bool {
        switch self {
        case .unavailable, .timedOut: return true
        case .message, .remote: return false
        }
    }
}

/// What the app can do with the privileged helper right now.
enum HelperState: Equatable {
    /// Registered, running, and answering XPC.
    case ready
    /// Not registered yet (or the bundled plist is missing).
    case notInstalled
    /// Registered but waiting for the user to approve it in System Settings.
    case requiresApproval
    /// Registered but not usable, with a reason.
    case unavailable(String)

    var isReady: Bool { self == .ready }
}

/// App-side client for the privileged `ProxyManagerHelper` LaunchDaemon.
///
/// Uses `SMAppService.daemon` (macOS 13+) to register the daemon, and NSXPC to
/// talk to it. Registration is a **foreground, user-initiated** action only: the
/// client never registers itself from a background mutation or the watchdog.
final class HelperXPCClient {
    static let machServiceName = "com.proxymanager.helper"
    static let plistName = "com.proxymanager.helper.plist"

    private let daemon = SMAppService.daemon(plistName: HelperXPCClient.plistName)

    /// Current helper health. `ready` requires a live XPC round trip, so a
    /// registered-but-rejecting daemon is reported as unavailable instead of
    /// being sent commands that then fall through to an admin prompt.
    var state: HelperState {
        switch daemon.status {
        case .enabled:
            return ping() ? .ready : .unavailable("the helper is registered but not responding")
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .notInstalled
        @unknown default:
            return .unavailable("unknown helper status")
        }
    }

    /// True only when the helper is registered **and** answering. Never
    /// registers.
    var isRegistered: Bool { state == .ready }

    /// Registers the daemon. Must only be called from an explicit user action in
    /// an interactive session (Settings/Onboarding button). Never from
    /// `SystemProxyManager` or a background queue.
    func registerFromUser() throws {
        if daemon.status == .enabled { return }
        guard SessionState.shared.canPrompt else {
            throw ProxyHelperError.unavailable(
                "administrator approval needs an unlocked, active session")
        }
        Log.system.notice("helper: registering from a user action")
        try daemon.register()
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Live round trip used as a health check. Never registers.
    func ping() -> Bool {
        let conn = NSXPCConnection(machServiceName: HelperXPCClient.machServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: ProxyManagerHelperProtocol.self)
        defer { conn.invalidate() }
        let state = CallState()
        conn.interruptionHandler = { state.finish(error: ProxyHelperError.unavailable("connection interrupted")) }
        conn.invalidationHandler = { state.finish(error: ProxyHelperError.unavailable("connection invalidated")) }
        conn.resume()
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
            state.finish(error: ProxyHelperError.unavailable("helper connection error: \(error.localizedDescription)"))
        }) as? ProxyManagerHelperProtocol else {
            return false
        }
        proxy.ping { ok in
            if ok {
                state.finishSuccess()
            } else {
                state.finish(error: ProxyHelperError.remote("helper ping failed"))
            }
        }
        if case .failure = state.wait(timeout: .now() + 2) { return false }
        return true
    }

    func applyProxy(services: [String], port: Int, host: String) throws {
        try withProxy { proxy, state in
            try sync(state) { proxy.applyProxy(services: services, port: port, host: host, withReply: $0) }
        }
    }

    func clearProxy(services: [String]) throws {
        try withProxy { proxy, state in
            try sync(state) { proxy.clearProxy(services: services, withReply: $0) }
        }
    }

    func restoreProxy(snapshot: SystemProxySnapshot) throws {
        try withProxy { proxy, state in
            try sync(state) { proxy.restoreProxy(snapshot: snapshot.xpcDictionary, withReply: $0) }
        }
    }

    // MARK: - Internals

    private func withProxy(_ body: (ProxyManagerHelperProtocol, CallState) throws -> Void) throws {
        let conn = NSXPCConnection(machServiceName: HelperXPCClient.machServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: ProxyManagerHelperProtocol.self)
        defer { conn.invalidate() }
        let state = CallState()
        // Every terminal event wakes the same wait. The connection's
        // invalidate() in `defer` is ignored once the call has an outcome.
        conn.interruptionHandler = { state.finish(error: ProxyHelperError.unavailable("connection interrupted")) }
        conn.invalidationHandler = { state.finish(error: ProxyHelperError.unavailable("connection invalidated")) }
        conn.resume()
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
            state.finish(error: ProxyHelperError.unavailable("helper connection error: \(error.localizedDescription)"))
        }) as? ProxyManagerHelperProtocol else {
            state.finish(error: ProxyHelperError.unavailable("could not connect to helper"))
            throw ProxyHelperError.unavailable("could not connect to helper")
        }
        try body(proxy, state)
        if let error = state.error { throw error }
    }

    /// Synchronous XPC bridge (blocks the calling — background — thread). The
    /// wait is woken by a reply, a remote-object error, interruption, or
    /// invalidation; the 15 s deadline only applies to a genuinely silent peer.
    private func sync(_ state: CallState, _ call: @escaping (@escaping (Bool, String?) -> Void) -> Void) throws {
        call { ok, message in
            if ok {
                state.finishSuccess()
            } else {
                state.finish(error: ProxyHelperError.remote(message ?? "helper error"))
            }
        }
        if case .failure(let error) = state.wait(timeout: .now() + 15) {
            throw error
        }
    }

    /// First terminal outcome wins: late replies, invalidations, and interruptions
    /// cannot overwrite it or signal the semaphore twice.
    private final class CallState {
        enum Outcome {
            case success
            case failure(Error)
        }

        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var outcome: Outcome?
        private var signaled = false

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            if case let .failure(error)? = outcome { return error }
            return nil
        }

        func finish(_ outcome: Outcome) {
            lock.lock()
            guard self.outcome == nil else { lock.unlock(); return }
            self.outcome = outcome
            let needsSignal = !signaled
            signaled = true
            lock.unlock()
            if needsSignal { semaphore.signal() }
        }

        func finishSuccess() { finish(.success) }

        func finish(error: Error) { finish(.failure(error)) }

        /// Waits for the first outcome. On timeout, records and returns a timeout
        /// failure (unless a real outcome raced in, which wins).
        func wait(timeout: DispatchTime) -> Outcome {
            lock.lock()
            if let outcome { lock.unlock(); return outcome }
            lock.unlock()
            _ = semaphore.wait(timeout: timeout)
            lock.lock()
            defer { lock.unlock() }
            if let outcome { return outcome }
            let timedOut = Outcome.failure(ProxyHelperError.timedOut)
            outcome = timedOut
            return timedOut
        }
    }
}
