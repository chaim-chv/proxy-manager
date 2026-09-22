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

/// Why a route was (or would be) chosen — for the request inspector's explanation.
enum RouteReason: Equatable {
    case appTunnel          // a matching app rule set to Tunnel all
    case appDirect          // a matching app rule set to Direct all
    case appDefaultTunnel   // no app rule; the default for apps is Tunnel all
    case appDefaultDirect   // no app rule; the default for apps is Direct all
    case targetExact        // a host target rule matched exactly
    case targetWildcard     // a host wildcard target rule matched
    case noMatch            // nothing matched -> direct
}

/// A route decision plus the deciding rule, evaluated against the *current*
/// configuration. Used by the inspector to explain a request (and to note when
/// the current rules would now route it differently).
struct RouteExplanation: Equatable {
    let route: RoutingDecision
    let reason: RouteReason
    /// The matched target pattern, or the app rule's key.
    let matched: String?
    /// The matched app rule's key/mode, when an app rule applied (even if it
    /// deferred to the target rules).
    let appRuleKey: String?
    let appRuleMode: AppRoutingMode?
}

final class RoutingEngine {
    private let lock = NSLock()
    // Precompiled at `update` time so `decide` allocates nothing per request.
    private var exact: [String: TargetRule] = [:]
    private var wildcards: [(base: String, rule: TargetRule)] = []

    // Per-app rules, compiled the same way (first enabled rule for a key wins).
    private var appRulesActive = false
    private var appIdentityRequired = false
    private var appDefaultMode: AppRoutingMode = .targets
    private var appBundleRules: [String: AppRule] = [:]
    private var appExecutableRules: [String: AppRule] = [:]
    private var appExecutableNameRules: [String: AppRule] = [:]

    func update(rules: [TargetRule]) {
        update(rules: rules, appRules: [], appEnabled: false, defaultMode: .targets)
    }

    func update(rules: [TargetRule], appRules: [AppRule], appEnabled: Bool,
                defaultMode: AppRoutingMode) {
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

        var bundleRules: [String: AppRule] = [:]
        var executableRules: [String: AppRule] = [:]
        var executableNameRules: [String: AppRule] = [:]
        for rule in appRules where rule.enabled {
            let key = rule.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            switch rule.keyKind {
            case .bundle:
                if bundleRules[key] == nil { bundleRules[key] = rule }
            case .executable:
                if executableRules[key] == nil { executableRules[key] = rule }
            case .executableName:
                if executableNameRules[key] == nil { executableNameRules[key] = rule }
            }
        }
        // Identity resolution (a per-connection libproc scan) is only worth its
        // cost when at least one rule could match; a default mode alone needs no
        // identity.
        let identityRequired = appEnabled
            && !(bundleRules.isEmpty && executableRules.isEmpty && executableNameRules.isEmpty)

        lock.lock()
        self.exact = exact
        self.wildcards = wildcards
        self.appRulesActive = appEnabled
        self.appIdentityRequired = identityRequired
        self.appDefaultMode = defaultMode
        self.appBundleRules = bundleRules
        self.appExecutableRules = executableRules
        self.appExecutableNameRules = executableNameRules
        lock.unlock()
    }

    /// True when per-app routing is enabled *and* at least one app rule exists,
    /// so the proxy must resolve the originating app per connection.
    var needsAppIdentity: Bool {
        lock.lock(); defer { lock.unlock() }
        return appIdentityRequired
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

    /// Decides the route for a request, taking the originating app into account
    /// when per-app routing is enabled. With per-app routing off (the default),
    /// this is exactly `decide(host:)`. With it on, a matching app rule's mode
    /// wins; otherwise the configured default mode applies (so an unresolved app
    /// still honours a `Direct all` / `Tunnel all` default rather than leaking
    /// through the host allow-list).
    func decide(host: String, app: AppIdentity?) -> RoutingDecision {
        lock.lock()
        let active = appRulesActive
        let defaultMode = appDefaultMode
        lock.unlock()
        guard active else { return decide(host: host) }
        if let app, let rule = appRule(for: app) {
            return decision(for: rule.mode, host: host)
        }
        return decision(for: defaultMode, host: host)
    }

    private func decision(for mode: AppRoutingMode, host: String) -> RoutingDecision {
        switch mode {
        case .tunnel: return .tunnel
        case .direct: return .direct
        case .targets: return decide(host: host)
        }
    }

    /// Explains how `host` (from `app`, if known) would be routed by the
    /// *current* configuration. Pure-ish: takes a snapshot under the lock and
    /// evaluates off-lock. Called once per inspected request, not on the hot path.
    func explain(host: String, app: AppIdentity?) -> RouteExplanation {
        lock.lock()
        let active = appRulesActive
        let defaultMode = appDefaultMode
        lock.unlock()
        guard active else { return hostExplanation(host) }
        if let app, let rule = appRule(for: app) {
            switch rule.mode {
            case .tunnel:
                return RouteExplanation(route: .tunnel, reason: .appTunnel, matched: rule.key,
                                        appRuleKey: rule.key, appRuleMode: .tunnel)
            case .direct:
                return RouteExplanation(route: .direct, reason: .appDirect, matched: rule.key,
                                        appRuleKey: rule.key, appRuleMode: .direct)
            case .targets:
                let hostExp = hostExplanation(host)
                return RouteExplanation(route: hostExp.route, reason: hostExp.reason,
                                        matched: hostExp.matched, appRuleKey: rule.key,
                                        appRuleMode: .targets)
            }
        }
        switch defaultMode {
        case .tunnel:
            return RouteExplanation(route: .tunnel, reason: .appDefaultTunnel, matched: nil,
                                    appRuleKey: nil, appRuleMode: nil)
        case .direct:
            return RouteExplanation(route: .direct, reason: .appDefaultDirect, matched: nil,
                                    appRuleKey: nil, appRuleMode: nil)
        case .targets:
            return hostExplanation(host)
        }
    }

    private func hostExplanation(_ host: String) -> RouteExplanation {
        let normalized = RoutingEngine.normalize(host)
        guard !normalized.isEmpty else {
            return RouteExplanation(route: .direct, reason: .noMatch, matched: nil,
                                    appRuleKey: nil, appRuleMode: nil)
        }
        if let rule = matchingRule(for: normalized) {
            let wildcard = RoutingEngine.isWildcard(rule.pattern)
            return RouteExplanation(route: .tunnel,
                                    reason: wildcard ? .targetWildcard : .targetExact,
                                    matched: rule.pattern, appRuleKey: nil, appRuleMode: nil)
        }
        return RouteExplanation(route: .direct, reason: .noMatch, matched: nil,
                                appRuleKey: nil, appRuleMode: nil)
    }

    /// First enabled rule matching the identity, in bundle → executable path →
    /// executable name order.
    private func appRule(for app: AppIdentity) -> AppRule? {
        lock.lock(); defer { lock.unlock() }
        if let bundleId = app.bundleId, let rule = appBundleRules[bundleId] { return rule }
        if let rule = appExecutableRules[app.executablePath] { return rule }
        if let rule = appExecutableNameRules[app.executableName] { return rule }
        return nil
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
