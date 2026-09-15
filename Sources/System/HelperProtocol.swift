import Foundation

// MARK: - Proxy state models (shared between the app and the helper)

struct ServiceProxyState: Codable, Equatable {
    var webEnabled: Bool = false
    var webServer: String = ""
    var webPort: String = ""
    var secureEnabled: Bool = false
    var secureServer: String = ""
    var securePort: String = ""
    var pacEnabled: Bool = false
    var pacURL: String = ""
    var bypassDomains: [String] = []

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
            "secureEnabled": secureEnabled ? "1" : "0",
            "secureServer": secureServer,
            "securePort": securePort,
            "pacEnabled": pacEnabled ? "1" : "0",
            "pacURL": Self.normalizePAC(pacURL),
            "bypassDomains": bypassDomains.joined(separator: "\n"),
        ]
    }

    init() {}

    init(dictionary: [String: String]) {
        webEnabled = dictionary["webEnabled"] == "1"
        webServer = dictionary["webServer"] ?? ""
        webPort = dictionary["webPort"] ?? ""
        secureEnabled = dictionary["secureEnabled"] == "1"
        secureServer = dictionary["secureServer"] ?? ""
        securePort = dictionary["securePort"] ?? ""
        pacEnabled = dictionary["pacEnabled"] == "1"
        pacURL = Self.normalizePAC(dictionary["pacURL"] ?? "")
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
        secureEnabled = try c.decodeIfPresent(Bool.self, forKey: .secureEnabled) ?? false
        secureServer = try c.decodeIfPresent(String.self, forKey: .secureServer) ?? ""
        securePort = try c.decodeIfPresent(String.self, forKey: .securePort) ?? ""
        pacEnabled = try c.decodeIfPresent(Bool.self, forKey: .pacEnabled) ?? false
        pacURL = Self.normalizePAC(try c.decodeIfPresent(String.self, forKey: .pacURL) ?? "")
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

    /// The system proxy is always pointed at loopback: it is a same-machine
    /// setting, so only a loopback bind is reachable. A non-loopback `bindHost`
    /// is for other clients (SSRF-guarded) and is intentionally not used here.
    static func applyProxy(services: [String], port: Int) -> [[String]] {
        var cmds: [[String]] = []
        for svc in services {
            cmds.append(["-setwebproxy", svc, "127.0.0.1", String(port)])
            cmds.append(["-setsecurewebproxy", svc, "127.0.0.1", String(port)])
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
        for (svc, state) in snapshot {
            if !state.webServer.isEmpty, validPort(state.webPort) {
                cmds.append(["-setwebproxy", svc, state.webServer, state.webPort])
                cmds.append(["-setwebproxystate", svc, state.webEnabled ? "on" : "off"])
            } else {
                cmds.append(["-setwebproxystate", svc, "off"])
            }
            if !state.secureServer.isEmpty, validPort(state.securePort) {
                cmds.append(["-setsecurewebproxy", svc, state.secureServer, state.securePort])
                cmds.append(["-setsecurewebproxystate", svc, state.secureEnabled ? "on" : "off"])
            } else {
                cmds.append(["-setsecurewebproxystate", svc, "off"])
            }
            if !state.pacURL.isEmpty, isHTTPURL(state.pacURL) {
                cmds.append(["-setautoproxyurl", svc, state.pacURL])
            }
            cmds.append(["-setautoproxystate", svc, state.pacEnabled ? "on" : "off"])
            if !state.bypassDomains.isEmpty {
                cmds.append(["-setproxybypassdomains", svc] + state.bypassDomains)
            }
        }
        return cmds
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
    func applyProxy(services: [String], port: Int, withReply reply: @escaping (Bool, String?) -> Void)
    func clearProxy(services: [String], withReply reply: @escaping (Bool, String?) -> Void)
    func restoreProxy(snapshot: [String: [String: String]], withReply reply: @escaping (Bool, String?) -> Void)
}
