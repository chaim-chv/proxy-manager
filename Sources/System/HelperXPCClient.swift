import Foundation
import ServiceManagement

enum ProxyHelperError: Error {
    case message(String)
}

/// App-side client for the privileged `ProxyManagerHelper` LaunchDaemon.
///
/// Uses `SMAppService.daemon` (macOS 13+) to register the daemon, and NSXPC to
/// talk to it. When the daemon is unavailable (e.g. unsigned/ad-hoc build),
/// `isRegistered` is false and callers fall back to `osascript`.
final class HelperXPCClient {
    static let machServiceName = "com.proxymanager.helper"
    static let plistName = "com.proxymanager.helper.plist"

    private let daemon = SMAppService.daemon(plistName: HelperXPCClient.plistName)

    var isRegistered: Bool {
        daemon.status == .enabled
    }

    /// Registers the daemon. Prompts for admin approval once. Throws if the
    /// daemon cannot be registered (e.g. the app is not properly signed).
    func register() throws {
        if daemon.status == .enabled { return }
        try daemon.register()
    }

    func applyProxy(services: [String], port: Int) throws {
        try withProxy { proxy, state in
            try sync(state) { proxy.applyProxy(services: services, port: port, withReply: $0) }
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
        conn.interruptionHandler = { state.finish(error: ProxyHelperError.message("connection interrupted")) }
        conn.invalidationHandler = { state.finish(error: ProxyHelperError.message("connection invalidated")) }
        conn.resume()
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
            state.finish(error: ProxyHelperError.message("helper connection error: \(error.localizedDescription)"))
        }) as? ProxyManagerHelperProtocol else {
            state.finish(error: ProxyHelperError.message("could not connect to helper"))
            throw ProxyHelperError.message("could not connect to helper")
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
                state.finish(error: ProxyHelperError.message(message ?? "helper error"))
            }
        }
        if case let .failure(error) = state.wait(timeout: .now() + 15) {
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
            let timedOut = Outcome.failure(ProxyHelperError.message("helper request timed out"))
            outcome = timedOut
            return timedOut
        }
    }
}
