import Foundation

// MARK: - Proxy state models (shared between the app and the helper)

struct ServiceProxyState: Codable, Equatable {
    var webEnabled: Bool = false
    var webServer: String = ""
    var webPort: String = ""
    var webAuthenticated: Bool = false
    var secureEnabled: Bool = false
    var secureServer: String = ""
    var securePort: String = ""
    var secureAuthenticated: Bool = false
    var pacEnabled: Bool = false
    var pacURL: String = ""
    var autoDiscoveryEnabled: Bool = false
    var bypassDomains: [String] = []

    private enum CodingKeys: String, CodingKey {
        case webEnabled, webServer, webPort, webAuthenticated
        case secureEnabled, secureServer, securePort, secureAuthenticated
        case pacEnabled, pacURL, autoDiscoveryEnabled, bypassDomains
    }

    /// `networksetup -getautoproxyurl` prints `URL: (null)` when no PAC is set;
    /// treat that (and empty) as "no PAC" so it never invalidates a service.
    static func normalizePAC(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "(null)" || t == "(nil)" || t.lowercased() == "null" { return "" }
        return t
    }

    /// XPC-plist-compatible dictionary (all values strings).
    var dictionary: [String: String] {
        [
            "webEnabled": webEnabled ? "1" : "0",
            "webServer": webServer,
            "webPort": webPort,
            "webAuthenticated": webAuthenticated ? "1" : "0",
            "secureEnabled": secureEnabled ? "1" : "0",
            "secureServer": secureServer,
            "securePort": securePort,
            "secureAuthenticated": secureAuthenticated ? "1" : "0",
            "pacEnabled": pacEnabled ? "1" : "0",
            "pacURL": Self.normalizePAC(pacURL),
            "autoDiscoveryEnabled": autoDiscoveryEnabled ? "1" : "0",
            "bypassDomains": bypassDomains.joined(separator: "\n"),
        ]
    }

    init() {}

    init(dictionary: [String: String]) {
        webEnabled = dictionary["webEnabled"] == "1"
        webServer = dictionary["webServer"] ?? ""
        webPort = dictionary["webPort"] ?? ""
        webAuthenticated = dictionary["webAuthenticated"] == "1"
        secureEnabled = dictionary["secureEnabled"] == "1"
        secureServer = dictionary["secureServer"] ?? ""
        securePort = dictionary["securePort"] ?? ""
        secureAuthenticated = dictionary["secureAuthenticated"] == "1"
        pacEnabled = dictionary["pacEnabled"] == "1"
        pacURL = Self.normalizePAC(dictionary["pacURL"] ?? "")
        autoDiscoveryEnabled = dictionary["autoDiscoveryEnabled"] == "1"
        bypassDomains = (dictionary["bypassDomains"] ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    // Tolerant decode so snapshots persisted by an older build (which lacked
    // `bypassDomains`) still load — a failed snapshot decode would defeat crash
    // recovery and risk re-capturing a dangling proxy.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        webEnabled = try c.decodeIfPresent(Bool.self, forKey: .webEnabled) ?? false
        webServer = try c.decodeIfPresent(String.self, forKey: .webServer) ?? ""
        webPort = try c.decodeIfPresent(String.self, forKey: .webPort) ?? ""
        webAuthenticated = try c.decodeIfPresent(Bool.self, forKey: .webAuthenticated) ?? false
        secureEnabled = try c.decodeIfPresent(Bool.self, forKey: .secureEnabled) ?? false
        secureServer = try c.decodeIfPresent(String.self, forKey: .secureServer) ?? ""
        securePort = try c.decodeIfPresent(String.self, forKey: .securePort) ?? ""
        secureAuthenticated = try c.decodeIfPresent(Bool.self, forKey: .secureAuthenticated) ?? false
        pacEnabled = try c.decodeIfPresent(Bool.self, forKey: .pacEnabled) ?? false
        pacURL = Self.normalizePAC(try c.decodeIfPresent(String.self, forKey: .pacURL) ?? "")
        autoDiscoveryEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoDiscoveryEnabled) ?? false
        bypassDomains = try c.decodeIfPresent([String].self, forKey: .bypassDomains) ?? []
    }
}

typealias SystemProxySnapshot = [String: ServiceProxyState]

extension SystemProxySnapshot {
    var xpcDictionary: [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for (svc, state) in self { out[svc] = state.dictionary }
        return out
    }

    static func from(xpcDictionary: [String: [String: String]]) -> SystemProxySnapshot {
        var out: SystemProxySnapshot = [:]
        for (svc, dict) in xpcDictionary { out[svc] = ServiceProxyState(dictionary: dict) }
        return out
    }
}

extension ServiceProxyState {
    /// Validates snapshot values before they reach root `networksetup` (defense
    /// in depth — the client is also code-signing-authorized). PAC URLs are
    /// sanitized per-field in `restore`, so they never drop the whole service.
    var isValid: Bool {
        for p in [webPort, securePort] {
            if !p.isEmpty {
                guard let v = Int(p), (1...65535).contains(v) else { return false }
            }
        }
        for s in [webServer, secureServer] {
            if !s.isEmpty && !NetworksetupCommands.isValidProxyServer(s) { return false }
        }
        return true
    }
}

// MARK: - networksetup command builder (shared; runs argv directly, no shell)

enum NetworksetupCommands {
    static let bypass = ["*.local", "169.254/16", "localhost", "127.0.0.1", "::1"]

    /// Points the system proxy at `host`. Callers must pass an address the
    /// local listener actually bound: system proxy traffic goes to this exact
    /// host, so `127.0.0.1` when the listener is loopback or wildcard, else the
    /// non-loopback bind address.
    static func applyProxy(services: [String], port: Int, host: String = "127.0.0.1") -> [[String]] {
        var cmds: [[String]] = []
        for svc in services {
            cmds.append(["-setwebproxy", svc, host, String(port)])
            cmds.append(["-setsecurewebproxy", svc, host, String(port)])
            cmds.append(["-setwebproxystate", svc, "on"])
            cmds.append(["-setsecurewebproxystate", svc, "on"])
            cmds.append(["-setautoproxystate", svc, "off"])
            cmds.append(["-setproxybypassdomains", svc] + bypass)
        }
        return cmds
    }

    static func clearProxy(services: [String]) -> [[String]] {
        var cmds: [[String]] = []
        for svc in services {
            cmds.append(["-setwebproxystate", svc, "off"])
            cmds.append(["-setsecurewebproxystate", svc, "off"])
        }
        return cmds
    }

    static func restore(snapshot: SystemProxySnapshot) -> [[String]] {
        var cmds: [[String]] = []
        // Sorted so command order is deterministic: snapshot is a dictionary,
        // and a stale service must not make restore behave differently per run.
        for svc in snapshot.keys.sorted() {
            guard let state = snapshot[svc] else { continue }
            // `networksetup` keeps proxy credentials outside this state; pass
            // the captured authenticated flag but never invent a password. With
            // authentication on, the user may need to re-enter it in System
            // Settings after a restore.
            if !state.webServer.isEmpty, validPort(state.webPort) {
                cmds.append(["-setwebproxy", svc, state.webServer, state.webPort,
                             state.webAuthenticated ? "on" : "off"])
                cmds.append(["-setwebproxystate", svc, state.webEnabled ? "on" : "off"])
            } else {
                cmds.append(["-setwebproxystate", svc, "off"])
            }
            if !state.secureServer.isEmpty, validPort(state.securePort) {
                cmds.append(["-setsecurewebproxy", svc, state.secureServer, state.securePort,
                             state.secureAuthenticated ? "on" : "off"])
                cmds.append(["-setsecurewebproxystate", svc, state.secureEnabled ? "on" : "off"])
            } else {
                cmds.append(["-setsecurewebproxystate", svc, "off"])
            }
            // `-setautoproxyurl` also enables PAC, so only emit it for a real
            // http(s) URL and never leave PAC on without one (that breaks
            // connectivity); the explicit state command below wins.
            let pacValid = !state.pacURL.isEmpty && isHTTPURL(state.pacURL)
            if pacValid {
                cmds.append(["-setautoproxyurl", svc, state.pacURL])
            }
            cmds.append(["-setautoproxystate", svc, (state.pacEnabled && pacValid) ? "on" : "off"])
            cmds.append(["-setproxyautodiscovery", svc, state.autoDiscoveryEnabled ? "on" : "off"])
            // Always restore the bypass list. `man networksetup`: "Specify
            // "Empty" for <domain1> to clear all Domain Name entries" — so an
            // originally empty list clears the app's bypass entries instead of
            // leaving them in place.
            let bypass = state.bypassDomains.isEmpty ? ["Empty"] : state.bypassDomains
            cmds.append(["-setproxybypassdomains", svc] + bypass)
        }
        return cmds
    }

    /// `networksetup`'s message when a command names a service that no longer
    /// exists (deleted/renamed USB, dock, or VPN service). Restore must skip
    /// these instead of aborting the whole snapshot and escalating to admin.
    static func isMissingServiceError(_ text: String) -> Bool {
        text.lowercased().contains("unable to find item in network database")
    }

    /// Strips the `*` that `networksetup -listallnetworkservices` prefixes to
    /// disabled services. A temporarily disabled service still exists and its
    /// original proxy state must not be silently dropped from a restore.
    static func normalizeServiceName(_ service: String) -> String {
        var s = service.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("*") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Pure filter for restore: keep only snapshot entries whose service still
    /// exists. `services` may include `*`-disabled names (normalized here). An
    /// empty result means every snapshotted service is gone — nothing to
    /// restore, which is a success, not a failure.
    static func filterSnapshot(_ snapshot: SystemProxySnapshot, toExisting services: [String]) -> SystemProxySnapshot {
        let existing = Set(services.map(normalizeServiceName).filter { !$0.isEmpty })
        return snapshot.filter { existing.contains($0.key) }
    }

    static func validPort(_ p: String) -> Bool {
        guard let v = Int(p) else { return false }
        return (1...65535).contains(v)
    }

    static func isHTTPURL(_ s: String) -> Bool {
        guard let u = URL(string: s) else { return false }
        return u.scheme == "http" || u.scheme == "https"
    }

    /// Validates a proxy server host (hostname, IPv4, or IPv6 literal —
    /// bracketed or not) against a safe charset. Stricter than a hostname
    /// grammar on purpose; values still reach `networksetup` as argv.
    static func isValidProxyServer(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 255 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:[]_"))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Validates a service name against a safe charset (no shell metacharacters).
    /// Real macOS service names contain `/` (e.g. "USB 10/100/1000 LAN").
    static func isValidService(_ svc: String) -> Bool {
        guard !svc.isEmpty, svc.count <= 256 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-_()/"))
        return svc.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - XPC protocol (shared between app and helper)

/// Operations the app asks the privileged helper (running as root) to perform.
/// Arguments are passed as argv arrays by the helper — never through a shell.
@objc protocol ProxyManagerHelperProtocol {
    func applyProxy(services: [String], port: Int, host: String, withReply reply: @escaping (Bool, String?) -> Void)
    func clearProxy(services: [String], withReply reply: @escaping (Bool, String?) -> Void)
    func restoreProxy(snapshot: [String: [String: String]], withReply reply: @escaping (Bool, String?) -> Void)
}
