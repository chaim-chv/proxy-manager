import Foundation
import Darwin

enum SOCKS5Error: Error {
    case message(String)
}

/// RFC 1928 SOCKS5 client (no-auth, ATYP=0x03 domain so DNS resolves on the
/// tunnel side). Raw BSD sockets — bypasses the system proxy (no loop-back).
struct SOCKS5Client {
    let serverHost: String
    let serverPort: UInt16
    var connectTimeout: TimeInterval = 10
    var handshakeTimeout: TimeInterval = 5
    /// Timeouts applied to the socket after the handshake so the relay does not
    /// inherit the handshake's short per-call deadline.
    var idleTimeout: TimeInterval = 120

    /// Opens a TCP connection to the SOCKS5 server and establishes a tunnel to
    /// `targetHost:targetPort`, returning the connected socket fd.
    func connect(targetHost: String, targetPort: UInt16) throws -> Int32 {
        // One monotonic deadline for the whole handshake: a server dribbling a
        // byte just under each per-call timeout can no longer stretch it to tens
        // of seconds while holding a proxy permit (PS-12). The TCP connect is
        // bounded by the same budget (but never extended beyond `connectTimeout`).
        let deadline = DispatchTime.now() + .nanoseconds(Self.nanoseconds(handshakeTimeout))
        let fd = try Socket.connect(host: serverHost, port: serverPort,
                                    timeout: min(connectTimeout, handshakeTimeout),
                                    allowPrivate: true)
        do {
            try handshake(fd: fd, targetHost: targetHost, targetPort: targetPort, deadline: deadline)
            // The relay must not inherit the handshake's per-call budget.
            Socket.setTimeouts(fd, receive: idleTimeout, send: idleTimeout)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    /// Lightweight synchronous health probe (greeting + no-auth reply).
    static func probe(serverHost: String, serverPort: UInt16) throws {
        let fd = try Socket.connect(host: serverHost, port: serverPort, timeout: 5,
                                    allowPrivate: true)
        defer { close(fd) }
        Socket.setTimeouts(fd, receive: 5, send: 5)
        try Socket.sendAll(fd, [0x05, 0x01, 0x00])
        let reply = try Socket.recvExact(fd, count: 2)
        guard reply.count == 2, reply[0] == 0x05, reply[1] == 0x00 else {
            throw SOCKS5Error.message("SOCKS5 server did not accept no-auth method")
        }
    }

    private func handshake(fd: Int32, targetHost: String, targetPort: UInt16,
                           deadline: DispatchTime) throws {
        try sendBytes(fd: fd, [0x05, 0x01, 0x00], deadline: deadline)
        let methodReply = try recvBytes(fd: fd, count: 2, deadline: deadline)
        guard methodReply.count == 2, methodReply[0] == 0x05, methodReply[1] == 0x00 else {
            throw SOCKS5Error.message("SOCKS5 method negotiation failed")
        }

        let hostBytes = Array(targetHost.utf8)
        guard hostBytes.count <= 255 else { throw SOCKS5Error.message("target host too long") }
        var request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)]
        request.append(contentsOf: hostBytes)
        request.append(UInt8((targetPort >> 8) & 0xFF))
        request.append(UInt8(targetPort & 0xFF))
        try sendBytes(fd: fd, request, deadline: deadline)

        let header = try recvBytes(fd: fd, count: 4, deadline: deadline)
        guard header.count == 4, header[0] == 0x05 else {
            throw SOCKS5Error.message("invalid SOCKS5 reply")
        }
        let rep = header[1]
        guard rep == 0x00 else {
            throw SOCKS5Error.message("SOCKS5 request rejected (REP=\(rep))")
        }
        switch header[3] {
        case 0x01: _ = try recvBytes(fd: fd, count: 4, deadline: deadline)
        case 0x03:
            let len = try recvBytes(fd: fd, count: 1, deadline: deadline)
            _ = try recvBytes(fd: fd, count: Int(len[0]), deadline: deadline)
        case 0x04: _ = try recvBytes(fd: fd, count: 16, deadline: deadline)
        default: throw SOCKS5Error.message("invalid SOCKS5 address type")
        }
        _ = try recvBytes(fd: fd, count: 2, deadline: deadline)
    }

    /// Remaining handshake budget, or a clear timeout error once the monotonic
    /// deadline has passed. Every socket call is bounded by this value (and by
    /// the 5 s per-call cap), so no single blocking call can outlive the budget.
    private func remainingBudget(_ deadline: DispatchTime) throws -> TimeInterval {
        let now = DispatchTime.now()
        guard now < deadline else {
            throw SOCKS5Error.message("SOCKS5 handshake timed out")
        }
        return Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
    }

    private func recvBytes(fd: Int32, count: Int, deadline: DispatchTime) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let budget = try remainingBudget(deadline)
            Socket.setTimeouts(fd, receive: min(budget, 5), send: min(budget, 5))
            let n = Darwin.recv(fd, &buf, count - out.count, 0)
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
                continue
            }
            if n == 0 { throw SocketError.message("connection closed") }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                // The per-call timeout was min(remaining, 5); surface the overall
                // deadline when it has passed (the dribble case).
                _ = try remainingBudget(deadline)
                throw SocketError.message("read timeout")
            }
            throw SocketError.message("recv failed: \(String(cString: strerror(errno)))")
        }
        return out
    }

    private func sendBytes(fd: Int32, _ bytes: [UInt8], deadline: DispatchTime) throws {
        guard !bytes.isEmpty else { return }
        var sent = 0
        while sent < bytes.count {
            let budget = try remainingBudget(deadline)
            Socket.setTimeouts(fd, receive: min(budget, 5), send: min(budget, 5))
            let n = bytes.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return Darwin.send(fd, base + sent, bytes.count - sent, 0)
            }
            if n > 0 {
                sent += n
                continue
            }
            if n == 0 { throw SocketError.message("connection closed") }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                let wait = try remainingBudget(deadline)
                if Socket.waitForWritable(fd, timeout: min(wait, 5)) { continue }
                throw SocketError.message("send timeout")
            }
            throw SocketError.message("send failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Converts a timeout to `DispatchTime` nanoseconds without trapping on a
    /// huge or non-finite value.
    private static func nanoseconds(_ timeout: TimeInterval) -> Int {
        guard timeout.isFinite, timeout > 0 else { return 0 }
        let maxSeconds: TimeInterval = 86_400
        return Int(min(timeout, maxSeconds) * 1_000_000_000)
    }
}
