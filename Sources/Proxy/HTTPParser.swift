import Foundation

struct HTTPRequest {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]
    /// Header lines in wire order with duplicates and original casing intact.
    /// `headers` is a dictionary, so it collapses same-named lines and treats
    /// differently-cased names as distinct; framing validation and forwarding
    /// need the unmodified list.
    var rawHeaders: [(name: String, value: String)]

    var headerNamed: (String) -> String? = { _ in nil }

    init(method: String, target: String, version: String, headers: [String: String],
         rawHeaders: [(name: String, value: String)] = []) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.rawHeaders = rawHeaders.isEmpty
            ? headers.map { (name: $0.key, value: $0.value) }
            : rawHeaders
        let lower = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.headerNamed = { lower[$0.lowercased()] }
    }

    /// Header lines in wire order (falls back to `headers` for requests built
    /// without them).
    var orderedHeaders: [(name: String, value: String)] {
        rawHeaders
    }

    private func headerValues(_ name: String) -> [String] {
        orderedHeaders.compactMap { pair in
            pair.name.lowercased() == name ? pair.value.trimmingCharacters(in: .whitespaces) : nil
        }
    }

    /// True when the request's body framing is ambiguous or unsupported:
    /// `Transfer-Encoding` together with `Content-Length`, differing duplicate
    /// `Content-Length` values, or a transfer coding this proxy does not
    /// understand. The proxy forwards the body verbatim, so forwarding an
    /// ambiguous request would hand the origin two ways to frame it (request
    /// smuggling). Malformed input must never trap.
    var hasConflictingFraming: Bool {
        let transferEncoding = headerValues("transfer-encoding")
        let contentLength = headerValues("content-length")

        if !transferEncoding.isEmpty && !contentLength.isEmpty { return true }

        if !contentLength.isEmpty {
            if Set(contentLength).count > 1 { return true }
            for value in contentLength where value.isEmpty || !value.allSatisfy({ $0.isNumber }) {
                return true
            }
        }

        if !transferEncoding.isEmpty {
            var tokens: [String] = []
            for value in transferEncoding {
                for part in value.split(separator: ",", omittingEmptySubsequences: false) {
                    let token = part.trimmingCharacters(in: .whitespaces).lowercased()
                    if token.isEmpty { return true }
                    tokens.append(token)
                }
            }
            for token in tokens where token != "chunked" && token != "identity" {
                return true
            }
            if tokens.filter({ $0 == "chunked" }).count > 1 { return true }
            if tokens.contains("chunked") && tokens.last != "chunked" { return true }
        }

        return false
    }

    var isConnect: Bool { method.uppercased() == "CONNECT" }

    /// True when the client requests a protocol upgrade (e.g. a WebSocket
    /// handshake): an `Upgrade` header is present **and** `Connection` lists the
    /// `upgrade` token, per RFC 7230 §6.7. The token list is comma-separated and
    /// case-insensitive (`Connection: keep-alive, Upgrade`).
    var isUpgrade: Bool {
        guard let upgrade = headerNamed("upgrade"), !upgrade.isEmpty else { return false }
        guard let connection = headerNamed("connection") else { return false }
        return connection
            .split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "upgrade" }
    }

    /// Splits `host`, `host:port`, `[ipv6]`, or `[ipv6]:port` into host + optional port.
    /// Handles bracketed IPv6 literals; strips the port only when it is numeric.
    static func splitHostPort(_ value: String) -> (host: String, port: UInt16?) {
        var host = value
        var port: UInt16?

        if value.hasPrefix("[") {
            if let closing = value.firstIndex(of: "]") {
                host = String(value[value.index(after: value.startIndex)..<closing])
                let rest = value[value.index(after: closing)...]
                if rest.hasPrefix(":") {
                    port = UInt16(rest.dropFirst())
                }
            }
            return (host, port)
        }

        if let idx = value.lastIndex(of: ":") {
            let portPart = value[value.index(after: idx)...]
            if !portPart.isEmpty, portPart.allSatisfy({ $0.isNumber }) {
                host = String(value[..<idx])
                port = UInt16(portPart)
            }
        }
        return (host, port)
    }

    var host: String {
        if isConnect {
            return Self.splitHostPort(target).host
        }
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            if let url = URL(string: target), let host = url.host {
                return host
            }
        }
        if let h = headerNamed("host") {
            return Self.splitHostPort(h).host
        }
        return ""
    }

    var port: UInt16 {
        let defaultPort: UInt16 = isConnect ? 443 : (target.hasPrefix("https://") ? 443 : 80)
        if isConnect {
            return Self.splitHostPort(target).port ?? defaultPort
        }
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            if let url = URL(string: target), let p = url.port, let valid = UInt16(exactly: p) { return valid }
            return defaultPort
        }
        if let h = headerNamed("host") {
            return Self.splitHostPort(h).port ?? defaultPort
        }
        return defaultPort
    }

    var scheme: String {
        isConnect ? "https" : (target.hasPrefix("https://") ? "https" : "http")
    }

    /// Authority to emit as `Host` after rewriting to origin-form.
    ///
    /// `host` is deliberately host-only, so using it here silently dropped a
    /// non-default port and IPv6 brackets. Absolute-form requests are
    /// normalized from the URL; origin-form requests keep the client's
    /// authority verbatim.
    var hostHeader: String {
        if isConnect { return target }
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            if let url = URL(string: target), let urlHost = url.host, !urlHost.isEmpty {
                var authority = urlHost.contains(":") ? "[\(urlHost)]" : urlHost
                let defaultPort = scheme == "https" ? 443 : 80
                if let p = url.port, p != defaultPort { authority += ":\(p)" }
                return authority
            }
        }
        if let h = headerNamed("host") {
            let trimmed = h.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return host
    }

    var path: String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            if let url = URL(string: target) {
                var p = url.path.isEmpty ? "/" : url.path
                if let q = url.query { p += "?" + q }
                return p
            }
        }
        return target
    }
}

enum HTTPParser {
    /// Parses the leading request line + headers from raw bytes.
    /// Returns nil if the header block is not yet complete.
    static func parse(_ bytes: [UInt8]) -> HTTPRequest? {
        guard let range = findHeaderEnd(in: bytes) else { return nil }
        let headerBytes = bytes[0..<range.startIndex]
        guard let text = String(bytes: headerBytes, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 3 else { return nil }
        let method = parts[0]
        let target = parts[1]
        let version = parts[2]

        var headers: [String: String] = [:]
        var rawHeaders: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
            rawHeaders.append((name: key, value: value))
        }
        return HTTPRequest(method: method, target: target, version: version,
                           headers: headers, rawHeaders: rawHeaders)
    }

    static func findHeaderEnd(in bytes: [UInt8]) -> Range<Int>? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i..<(i + 4)
        }
        return nil
    }

    /// Rewrites a proxied absolute-form request to origin-form, stripping
    /// hop-by-hop / proxy headers.
    ///
    /// Framing headers (`Content-Length`, `Transfer-Encoding`, `Trailer`) are
    /// preserved: the proxy forwards the body byte-for-byte, so the origin must
    /// receive the same framing the client used. Stripping `Transfer-Encoding`
    /// (the old behavior) left a chunked body with no framing at the origin.
    /// Each framing header is emitted at most once (case-insensitive); a
    /// request with genuinely conflicting values is rejected before reaching
    /// this function.
    ///
    /// A protocol upgrade (plaintext WebSocket, `ws://`) is the one case where
    /// `Connection` and `Upgrade` are **not** stripped: forwarding them is what
    /// lets the origin answer `101 Switching Protocols` and switch the socket to
    /// full-duplex framing. Dropping them (the old behavior) made the origin see
    /// an ordinary HTTP request, so `ws://` never upgraded. `Connection: Upgrade`
    /// is re-emitted (never `close`) for upgrades; the relay then carries the
    /// upgraded byte stream in both directions. `wss://` never reaches this path
    /// (it is an opaque `CONNECT` tunnel).
    static func rewrite(_ request: HTTPRequest) -> String {
        let isUpgrade = request.isUpgrade
        var lines: [String] = []
        lines.append("\(request.method) \(request.path) \(request.version)")
        let hopByHop: Set<String> = ["proxy-connection", "proxy-authorization", "proxy-authenticate",
                                     "connection", "keep-alive", "te", "upgrade"]
        let framing: Set<String> = ["content-length", "transfer-encoding", "trailer"]
        var emittedFraming: Set<String> = []
        for pair in request.orderedHeaders {
            let lk = pair.name.lowercased()
            if lk == "host" { continue }
            if hopByHop.contains(lk) { continue }
            if framing.contains(lk) {
                if emittedFraming.contains(lk) { continue }
                emittedFraming.insert(lk)
            }
            lines.append("\(pair.name): \(pair.value)")
        }
        lines.append("Host: \(request.hostHeader)")
        if isUpgrade {
            lines.append("Connection: Upgrade")
            lines.append("Upgrade: \(request.headerNamed("upgrade") ?? "websocket")")
        } else {
            lines.append("Connection: close")
        }
        lines.append("")
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
