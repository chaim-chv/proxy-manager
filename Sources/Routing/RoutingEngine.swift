import Foundation

enum RoutingDecision: Equatable {
    case tunnel
    case direct

    var route: Route {
        switch self {
        case .tunnel: return .tunnel
        case .direct: return .direct
        }
    }
}

final class RoutingEngine {
    private let lock = NSLock()
    // Precompiled at `update` time so `decide` allocates nothing per request.
    private var exact: [String: TargetRule] = [:]
    private var wildcards: [(base: String, rule: TargetRule)] = []

    func update(rules: [TargetRule]) {
        var exact: [String: TargetRule] = [:]
        var wildcards: [(base: String, rule: TargetRule)] = []
        for rule in rules where rule.enabled {
            let p = Self.normalizePattern(rule.pattern)
            if p.isEmpty { continue }
            if p.hasPrefix("*.") {
                let base = String(p.dropFirst(2))
                if !base.isEmpty { wildcards.append((base, rule)) }
            } else if p.hasPrefix(".") {
                let base = String(p.dropFirst())
                if !base.isEmpty { wildcards.append((base, rule)) }
            } else {
                exact[p] = rule
            }
        }
        lock.lock()
        self.exact = exact
        self.wildcards = wildcards
        lock.unlock()
    }

    /// Normalizes a host for matching: lowercase, strip brackets/port for IPv6
    /// literals, strip a numeric `:port` suffix, strip trailing dots.
    static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("[") {
            if let close = h.firstIndex(of: "]") {
                h = String(h[h.index(after: h.startIndex)..<close])
            }
        } else if h.filter({ $0 == ":" }).count == 1, let idx = h.lastIndex(of: ":") {
            let port = h[h.index(after: idx)...]
            if !port.isEmpty, port.allSatisfy({ $0.isNumber }) { h = String(h[..<idx]) }
        }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    private static func normalizePattern(_ pattern: String) -> String {
        var p = pattern.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasSuffix(".") && p != "*" { p.removeLast() }
        return p
    }

    /// Decides whether `host` should be tunneled. Pure and unit-testable.
    func decide(host: String) -> RoutingDecision {
        let normalized = RoutingEngine.normalize(host)
        guard !normalized.isEmpty else { return .direct }
        lock.lock()
        let exact = self.exact
        let wildcards = self.wildcards
        lock.unlock()
        if exact[normalized] != nil { return .tunnel }
        for w in wildcards where normalized == w.base || normalized.hasSuffix("." + w.base) {
            return .tunnel
        }
        return .direct
    }

    /// Returns the first matching rule for the host (for the preview UI), if any.
    func matchingRule(for host: String) -> TargetRule? {
        let normalized = RoutingEngine.normalize(host)
        guard !normalized.isEmpty else { return nil }
        lock.lock()
        let exact = self.exact
        let wildcards = self.wildcards
        lock.unlock()
        if let rule = exact[normalized] { return rule }
        for w in wildcards where normalized == w.base || normalized.hasSuffix("." + w.base) {
            return w.rule
        }
        return nil
    }

    /// True if a pattern is a wildcard (`*.example.com` or `.example.com`) that
    /// can match more than a single host, as opposed to an exact name.
    static func isWildcard(_ pattern: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.hasPrefix("*.") || p.hasPrefix(".")
    }

    /// True if `pattern` matches `host`. `host` must already be normalized (as
    /// `decide`/`matchingRule` do); callers that pass a raw host must normalize
    /// it first or matching may fail silently.
    static func matches(pattern: String, host: String) -> Bool {
        let p = normalizePattern(pattern)
        if p.isEmpty { return false }
        if p.hasPrefix("*.") {
            let base = String(p.dropFirst(2))
            if base.isEmpty { return false }
            return host == base || host.hasSuffix("." + base)
        }
        if p.hasPrefix(".") {
            let base = String(p.dropFirst())
            if base.isEmpty { return false }
            return host == base || host.hasSuffix("." + base)
        }
        return host == p
    }
}
