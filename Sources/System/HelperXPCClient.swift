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
        try withProxy { proxy in
            try sync { proxy.applyProxy(services: services, port: port, withReply: $0) }
        }
    }

    func clearProxy(services: [String]) throws {
        try withProxy { proxy in
            try sync { proxy.clearProxy(services: services, withReply: $0) }
        }
    }

    func restoreProxy(snapshot: SystemProxySnapshot) throws {
        try withProxy { proxy in
            try sync { proxy.restoreProxy(snapshot: snapshot.xpcDictionary, withReply: $0) }
        }
    }

    // MARK: - Internals

    private func withProxy(_ body: (ProxyManagerHelperProtocol) throws -> Void) throws {
        let conn = NSXPCConnection(machServiceName: HelperXPCClient.machServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: ProxyManagerHelperProtocol.self)
        conn.resume()
        defer { conn.invalidate() }
        let errorBox = LockedError()
        conn.interruptionHandler = { errorBox.set(ProxyHelperError.message("connection interrupted")) }
        conn.invalidationHandler = { errorBox.set(ProxyHelperError.message("connection invalidated")) }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ errorBox.set($0) }) as? ProxyManagerHelperProtocol else {
            throw ProxyHelperError.message("could not connect to helper")
        }
        try body(proxy)
        if let err = errorBox.get() {
            throw ProxyHelperError.message("helper error: \(err.localizedDescription)")
        }
    }

    /// Synchronous XPC bridge (blocks the calling — background — thread) with a
    /// bounded timeout so a missing/hung daemon cannot deadlock the caller.
    private func sync(_ call: @escaping (@escaping (Bool, String?) -> Void) -> Void) throws {
        var result: (Bool, String?) = (false, nil)
        let semaphore = DispatchSemaphore(value: 0)
        call { ok, err in
            result = (ok, err)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            throw ProxyHelperError.message("helper request timed out")
        }
        if !result.0 {
            throw ProxyHelperError.message(result.1 ?? "helper error")
        }
    }

    private final class LockedError {
        private let lock = NSLock()
        private var value: Error?
        func set(_ e: Error) { lock.lock(); if value == nil { value = e }; lock.unlock() }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
