import Foundation

/// Turns the proxy's internal error text into a small, stable vocabulary that
/// the UI can explain and the database can group by.
///
/// `SocketError`/`SOCKS5Error` used to be persisted via
/// `error.localizedDescription`, which Foundation renders as
/// "The operation couldn't be completed. (ProxyManager.SocketError error 0.)"
/// for any plain `Error` enum — erasing the only useful part (DNS failure vs
/// timeout vs refused vs peer abort). The proxy now stores
/// `connect_failed: <code>` and this type is the single place that maps a code
/// (new row) or a legacy string (old row) to a human sentence.
enum ErrorText {
    enum Kind: String {
        case dns
        case resolverBusy = "dns_busy"
        case timeout
        case refused
        case unreachable
        case reset
        case closed
        case socksAuth = "socks_auth"
        case socksRejected = "socks_rejected"
        case socksTimeout = "socks_timeout"
        case blockedPrivate = "blocked_private_destination"
        case tunnelDown = "tunnel_down"
        case badRequest = "bad_request"
        case unknown

        var isFailure: Bool { self != .tunnelDown }
    }

    /// Stored form: a stable code, prefixed like the historical strings so old
    /// and new rows read the same in the inspector.
    static func code(for error: Error) -> String {
        "connect_failed: \(kind(for: error).rawValue)"
    }

    static func kind(for error: Error) -> Kind {
        // Both `SocketError` and `SOCKS5Error` now conform to `LocalizedError`,
        // so `localizedDescription` carries the original message (DNS, timeout,
        // refused, ...). Keeping this generic also makes the classifier usable
        // without linking the socket layer.
        classify(error.localizedDescription)
    }

    /// Classifies both a bare message ("connect(host:port) failed: …") and an
    /// already-stored string.
    static func classify(_ text: String) -> Kind {
        let t = text.lowercased()
        if t.contains("blocked_private_destination") { return .blockedPrivate }
        if t.contains("tunnel_down") { return .tunnelDown }
        if t.contains("conflicting_request_framing") || t.contains("malformed") { return .badRequest }
        if t.contains("socks5 server did not accept") || t.contains("method negotiation") { return .socksAuth }
        if t.contains("socks5 request rejected") { return .socksRejected }
        if t.contains("socks5") && (t.contains("timed out") || t.contains("timeout")) { return .socksTimeout }
        if t.contains("resolver busy") { return .resolverBusy }
        if t.contains("getaddrinfo") { return .dns }
        if t.contains("timed out") || t.contains("timeout") { return .timeout }
        if t.contains("refused") { return .refused }
        if t.contains("no route to host") || t.contains("unreachable") || t.contains("network is down") {
            return .unreachable
        }
        if t.contains("reset by peer") { return .reset }
        if t.contains("connection closed") || t.contains("closed by") { return .closed }
        return .unknown
    }

    static func kind(ofStored stored: String?) -> Kind {
        guard let stored, !stored.isEmpty else { return .unknown }
        return classify(stored)
    }

    /// One short sentence for the feed and the inspector. Returns nil when the
    /// row has no error.
    static func describe(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        // New rows carry the code; accept the raw message too (old rows, tests).
        if stored.hasPrefix("connect_failed:") {
            let value = stored.dropFirst("connect_failed:".count)
                .trimmingCharacters(in: .whitespaces)
            if let kind = Kind(rawValue: value) { return sentence(kind) }
            return sentence(classify(value))
        }
        if let kind = Kind(rawValue: stored) { return sentence(kind) }
        let kind = classify(stored)
        if kind != .unknown { return sentence(kind) }
        // Legacy Foundation boilerplate: never show it verbatim.
        if stored.contains("The operation couldn") || stored.contains("ProxyManager.SocketError")
            || stored.contains("ProxyManager.SOCKS5Error") {
            return "Connection failed"
        }
        return stored
    }

    static func sentence(_ kind: Kind) -> String {
        switch kind {
        case .dns: return "DNS lookup failed"
        case .resolverBusy: return "DNS resolver busy"
        case .timeout: return "Timed out"
        case .refused: return "Connection refused"
        case .unreachable: return "Host unreachable"
        case .reset: return "Connection reset"
        case .closed: return "Closed by peer"
        case .socksAuth: return "Tunnel rejected the connection"
        case .socksRejected: return "Tunnel refused this host"
        case .socksTimeout: return "Tunnel handshake timed out"
        case .blockedPrivate: return "Blocked: private address"
        case .tunnelDown: return "Tunnel down — sent direct"
        case .badRequest: return "Malformed request"
        case .unknown: return "Connection failed"
        }
    }
}
