import Foundation

/// Short-lived `ProcessInfo` activity tokens.
///
/// ProxyManager must nap while it is idle and wake only for actual work. The
/// app therefore never holds a token for the routing session; it takes one
/// around a system-proxy mutation and releases it immediately. Injecting the
/// begin/end calls keeps the pairing testable without real power assertions.
final class ActivityController {
    struct Factory {
        var begin: (String) -> NSObjectProtocol
        var end: (NSObjectProtocol) -> Void

        static let live = Factory(
            begin: { reason in
                ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep],
                    reason: reason)
            },
            end: { token in ProcessInfo.processInfo.endActivity(token) }
        )
    }

    private let factory: Factory
    private let lock = NSLock()
    private var activeCount = 0

    init(factory: Factory = .live) {
        self.factory = factory
    }

    /// True while at least one activity token is held. Test seam.
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeCount > 0
    }

    /// Runs `body` under a short-lived activity token.
    ///
    /// `beginActivity`/`endActivity` must be paired on the same thread, so this
    /// is called synchronously from the work item doing the mutation.
    func withActivity<T>(_ reason: String, _ body: () throws -> T) rethrows -> T {
        let token = factory.begin(reason)
        lock.lock()
        activeCount += 1
        lock.unlock()
        defer {
            lock.lock()
            activeCount -= 1
            lock.unlock()
            factory.end(token)
        }
        return try body()
    }
}
