import Foundation

/// Classifies a request host as loopback / link-local / private so the proxy
/// can refuse to be used as an SSRF pivot by non-loopback clients.
///
/// Dependency-free (and `internal`, not `private`) so the standalone regression
/// harness can compile and exercise it directly.
enum HostClassifier {
    static func isPrivateOrLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.isEmpty { return false }
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        if h == "::1" || h == "0:0:0:0:0:0:0:1" { return true }
        // IPv6 literals only: requiring a colon keeps ordinary hostnames such as
        // `fcdn.example.com` or `fdroid.org` from matching the fc/fd ULA prefix.
        if h.contains(":") && (h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd")) {
            return true
        }
        let parts = h.split(separator: ".")
        if parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
           let c = Int(parts[2]), let d = Int(parts[3]),
           (0...255).contains(a), (0...255).contains(b), (0...255).contains(c), (0...255).contains(d) {
            if a == 127 || a == 10 || a == 0 { return true }
            if a == 172 && (16...31).contains(b) { return true }
            if a == 192 && b == 168 { return true }
            if a == 169 && b == 254 { return true }
        }
        return false
    }
}
