import Foundation

struct HTTPRequest {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]

    var headerNamed: (String) -> String? = { _ in nil }

    init(method: String, target: String, version: String, headers: [String: String]) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        let lower = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.headerNamed = { lower[$0.lowercased()] }
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

    var path: String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            if let url = URL(string: target) {
                var p = url.path
                if let q = url.query { p += "?" + q }
                return p.isEmpty ? "/" : p
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
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return HTTPRequest(method: method, target: target, version: version, headers: headers)
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
        for (key, value) in request.headers {
            let lk = key.lowercased()
            if ["proxy-connection", "proxy-authorization", "proxy-authenticate", "connection",
                "keep-alive", "te", "trailer", "transfer-encoding", "upgrade"].contains(lk) {
                continue
            }
            if lk == "host" { continue }
            lines.append("\(key): \(value)")
        }
        lines.append("Host: \(request.host)")
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
