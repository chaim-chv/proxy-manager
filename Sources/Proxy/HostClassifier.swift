import Foundation
import Darwin

/// Classifies a request host (or a resolved socket address) as loopback /
/// link-local / private so the proxy can refuse to be used as an SSRF pivot by
/// non-loopback clients.
///
/// The string form is a fast pre-check only: `getaddrinfo` also accepts numeric
/// integer/hex/shorthand IPv4 and DNS names, so the authoritative decision is
/// made on the resolved addresses (`isPrivateOrLoopback(_:_:)`).
///
/// Dependency-free (and `internal`, not `private`) so the standalone regression
/// harness can compile and exercise it directly.
enum HostClassifier {
    static func isPrivateOrLoopback(_ host: String) -> Bool {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.isEmpty { return false }
        // Numeric IPv6 may arrive bracketed (`[::1]`) from an authority.
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") {
            h = String(h[h.index(after: h.startIndex)..<close])
        }
        if h.hasSuffix(".") { h.removeLast() }
        if h.isEmpty { return false }
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }

        var v6 = in6_addr()
        if h.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return withUnsafeBytes(of: v6) { isPrivateIPv6(Array($0)) }
        }
        // IPv6 literals only: requiring a colon keeps ordinary hostnames such as
        // `fcdn.example.com` or `fdroid.org` from matching the fc/fd ULA prefix.
        // Also covers zone-id forms (`fe80::1%en0`) that `inet_pton` rejects.
        if h.contains(":") && (h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd")) {
            return true
        }
        let parts = h.split(separator: ".")
        if parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
           let c = Int(parts[2]), let d = Int(parts[3]),
           (0...255).contains(a), (0...255).contains(b), (0...255).contains(c), (0...255).contains(d) {
            return isPrivateIPv4(UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d))
        }
        return false
    }

    /// Authoritative SSRF check for a `getaddrinfo` result. Uses the raw address
    /// bytes, never string formatting, so it is safe on the connection path.
    ///
    /// Takes the address by pointer, not by value: `sockaddr` is only 16 bytes
    /// on Darwin and a by-value copy truncates `sockaddr_in6` (28 bytes).
    static func isPrivateOrLoopback(_ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Bool {
        switch Int32(addr.pointee.sa_family) {
        case AF_INET:
            guard len >= socklen_t(MemoryLayout<sockaddr_in>.size) else { return false }
            return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                isPrivateIPv4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
            }
        case AF_INET6:
            guard len >= socklen_t(MemoryLayout<sockaddr_in6>.size) else { return false }
            return addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { isPrivateIPv6(Array($0)) }
            }
        default:
            return false
        }
    }

    private static func isPrivateIPv4(_ raw: UInt32) -> Bool {
        let a = UInt8((raw >> 24) & 0xFF)
        let b = UInt8((raw >> 16) & 0xFF)
        let c = UInt8((raw >> 8) & 0xFF)
        switch a {
        case 0, 10, 127: return true                    // 0/8, 10/8, 127/8
        case 100: return (64...127).contains(b)         // 100.64/10
        case 169: return b == 254                       // 169.254/16
        case 172: return (16...31).contains(b)          // 172.16/12
        case 192:
            return b == 168                             // 192.168/16
                || (b == 0 && c == 0)                   // 192.0.0/24
                || (b == 0 && c == 2)                   // 192.0.2/24
        case 198:
            return (18...19).contains(b)                // 198.18/15
                || (b == 51 && c == 100)                // 198.51.100/24
        case 203: return b == 0 && c == 113             // 203.0.113/24
        case 224...239: return true                     // multicast 224/4
        case 240...255: return true                     // reserved 240/4 + broadcast
        default: return false
        }
    }

    private static func isPrivateIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b.allSatisfy({ $0 == 0 }) { return true }                       // ::
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true } // ::1
        // ::ffff:0:0/96 — classify the embedded IPv4.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
            let v4 = UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])
            return isPrivateIPv4(v4)
        }
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }           // fe80::/10
        if (b[0] & 0xFE) == 0xFC { return true }                           // fc00::/7
        if b[0] == 0xFF { return true }                                    // ff00::/8
        return false
    }
}
