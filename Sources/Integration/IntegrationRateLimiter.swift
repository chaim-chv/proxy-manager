import Foundation

/// Per-identity token buckets. A denied request is a `busy` error with a retry
/// hint; nothing is queued, since a client that floods the API should back off
/// rather than grow an unbounded backlog inside the app.
final class IntegrationRateLimiter {
    struct Bucket {
        let capacity: Double
        let refillPerSecond: Double
    }

    static let read = Bucket(capacity: 40, refillPerSecond: 4)          // 240/min
    static let mutation = Bucket(capacity: 5, refillPerSecond: 0.5)     // 30/min
    static let routingToggle = Bucket(capacity: 3, refillPerSecond: 0.1) // 6/min

    private struct State {
        var tokens: Double
        var last: Date
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]

    func allow(_ key: String, bucket: Bucket, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        pruneIfNeeded(now: now)

        var state = states[key] ?? State(tokens: bucket.capacity, last: now)
        let elapsed = max(0, now.timeIntervalSince(state.last))
        state.tokens = min(bucket.capacity, state.tokens + elapsed * bucket.refillPerSecond)
        state.last = now

        if state.tokens >= 1 {
            state.tokens -= 1
            states[key] = state
            return true
        }
        states[key] = state
        return false
    }

    func reset() {
        lock.lock()
        states.removeAll()
        lock.unlock()
    }

    /// Keeps the table bounded if a machine accumulates many caller identities.
    private func pruneIfNeeded(now: Date) {
        guard states.count > 512 else { return }
        states = states.filter { now.timeIntervalSince($0.value.last) < 600 }
    }
}
