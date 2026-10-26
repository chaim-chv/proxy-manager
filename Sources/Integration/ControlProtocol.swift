import Foundation
import Darwin

/// Identity of the process on the other end of the control connection.
///
/// The agent derives it from the XPC audit token. The app trusts the agent for
/// this (both run as the same user and share the per-launch token file); the
/// trust boundary is the user account, not the signature. See `docs/integration.md`.
struct ControlIdentity: Codable, Equatable {
    var pid: Int32
    var bundleID: String?
    var teamID: String?
    /// Designated requirement string. This is the stable consent key.
    var requirement: String
    var displayName: String
    var path: String?
}

struct ControlRequest: Codable, Equatable {
    var v: Int
    var token: String
    var identity: ControlIdentity
    var request: IntegrationRequest

    init(token: String, identity: ControlIdentity, request: IntegrationRequest,
         v: Int = IntegrationProtocol.version) {
        self.v = v
        self.token = token
        self.identity = identity
        self.request = request
    }
}

struct ControlResponse: Codable, Equatable {
    var v: Int
    var result: IntegrationResult

    init(result: IntegrationResult, v: Int = IntegrationProtocol.version) {
        self.v = v
        self.result = result
    }
}

enum ControlTransportError: Error {
    case closed
    case timeout
    case frameTooLarge
    case malformed
}

/// Length-prefixed JSON frames shared by the app, the agent and the CLI.
///
/// A 4-byte big-endian length keeps partial reads simple and lets both sides
/// reject an oversized frame before allocating it.
enum ControlFraming {
    static let maxFrameBytes = 256 * 1024
    static let defaultTimeoutMs: Int32 = 5_000
    private static let headerBytes = 4

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ControlTransportError.malformed
        }
    }

    static func readFrame(_ fd: Int32, timeoutMs: Int32 = defaultTimeoutMs) throws -> Data {
        let header = try readExactly(fd, headerBytes, timeoutMs: timeoutMs)
        var length: UInt32 = 0
        for byte in header { length = (length << 8) | UInt32(byte) }
        guard length > 0, length <= UInt32(maxFrameBytes) else {
            throw ControlTransportError.frameTooLarge
        }
        return try readExactly(fd, Int(length), timeoutMs: timeoutMs)
    }

    static func writeFrame(_ fd: Int32, _ payload: Data,
                           timeoutMs: Int32 = defaultTimeoutMs) throws {
        guard payload.count <= maxFrameBytes else {
            throw ControlTransportError.frameTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        try writeExactly(fd, frame, timeoutMs: timeoutMs)
    }

    // MARK: - Byte plumbing

    private static func readExactly(_ fd: Int32, _ count: Int,
                                    timeoutMs: Int32) throws -> Data {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var data = Data(capacity: count)
        while data.count < count {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard remaining > 0 else { throw ControlTransportError.timeout }
            try wait(fd, events: Int16(POLLIN), timeoutMs: remaining)

            var buffer = [UInt8](repeating: 0, count: count - data.count)
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if n == 0 { throw ControlTransportError.closed }
            if n < 0 {
                if errno == EINTR { continue }
                throw ControlTransportError.closed
            }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    private static func writeExactly(_ fd: Int32, _ data: Data,
                                     timeoutMs: Int32) throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var offset = 0
        while offset < data.count {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard remaining > 0 else { throw ControlTransportError.timeout }
            try wait(fd, events: Int16(POLLOUT), timeoutMs: remaining)

            let n = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw ControlTransportError.closed
            }
            offset += n
        }
    }

    private static func wait(_ fd: Int32, events: Int16, timeoutMs: Int32) throws {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let rc = poll(&descriptor, 1, timeoutMs)
        if rc == 0 { throw ControlTransportError.timeout }
        if rc < 0 {
            if errno == EINTR { return try wait(fd, events: events, timeoutMs: timeoutMs) }
            throw ControlTransportError.closed
        }
        // POLLHUP arrives together with POLLIN when the peer writes and closes
        // immediately (a one-shot request/reply server does exactly that).
        // Treat it as readable and let read() drain the buffered bytes or
        // report EOF; only ERR/NVAL are unconditionally fatal.
        if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
            throw ControlTransportError.closed
        }
    }
}

enum ControlSocket {
    static func setNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one,
                   socklen_t(MemoryLayout<Int32>.size))
    }

    /// Same-UID only. Peer credentials are the real gate for the local socket;
    /// the token file is a second, accidental-access guard.
    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }

    static func fill(_ address: inout sockaddr_un, path: String) -> Bool {
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return true
    }

    static func bind(_ fd: Int32, path: String) -> Bool {
        var address = sockaddr_un()
        guard fill(&address, path: path) else { return false }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, size) == 0
            }
        }
    }

    static func connect(_ fd: Int32, path: String) -> Bool {
        var address = sockaddr_un()
        guard fill(&address, path: path) else { return false }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size) == 0
            }
        }
    }

    /// Constant-time comparison; the token is a shared secret, not a display value.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

/// The app asks; another app answers. Implemented by the Alert UI in the app
/// and by a stub in the harness.
protocol IntegrationConsentProviding: AnyObject {
    func ask(for identity: ControlIdentity) -> IntegrationScope?
}
