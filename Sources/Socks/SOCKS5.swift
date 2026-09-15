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

    /// Opens a TCP connection to the SOCKS5 server and establishes a tunnel to
    /// `targetHost:targetPort`, returning the connected socket fd.
    func connect(targetHost: String, targetPort: UInt16) throws -> Int32 {
        let fd = try Socket.connect(host: serverHost, port: serverPort, timeout: connectTimeout)
        Socket.setTimeouts(fd, receive: handshakeTimeout, send: handshakeTimeout)
        do {
            try handshake(fd: fd, targetHost: targetHost, targetPort: targetPort)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    /// Lightweight synchronous health probe (greeting + no-auth reply).
    static func probe(serverHost: String, serverPort: UInt16) throws {
        let fd = try Socket.connect(host: serverHost, port: serverPort, timeout: 5)
        defer { close(fd) }
        Socket.setTimeouts(fd, receive: 5, send: 5)
        try Socket.sendAll(fd, [0x05, 0x01, 0x00])
        let reply = try Socket.recvExact(fd, count: 2)
        guard reply.count == 2, reply[0] == 0x05, reply[1] == 0x00 else {
            throw SOCKS5Error.message("SOCKS5 server did not accept no-auth method")
        }
    }

    private func handshake(fd: Int32, targetHost: String, targetPort: UInt16) throws {
        try Socket.sendAll(fd, [0x05, 0x01, 0x00])
        let methodReply = try Socket.recvExact(fd, count: 2)
        guard methodReply.count == 2, methodReply[0] == 0x05, methodReply[1] == 0x00 else {
            throw SOCKS5Error.message("SOCKS5 method negotiation failed")
        }

        let hostBytes = Array(targetHost.utf8)
        guard hostBytes.count <= 255 else { throw SOCKS5Error.message("target host too long") }
        var request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)]
        request.append(contentsOf: hostBytes)
        request.append(UInt8((targetPort >> 8) & 0xFF))
        request.append(UInt8(targetPort & 0xFF))
        try Socket.sendAll(fd, request)

        let header = try Socket.recvExact(fd, count: 4)
        guard header.count == 4, header[0] == 0x05 else {
            throw SOCKS5Error.message("invalid SOCKS5 reply")
        }
        let rep = header[1]
        guard rep == 0x00 else {
            throw SOCKS5Error.message("SOCKS5 request rejected (REP=\(rep))")
        }
        switch header[3] {
        case 0x01: _ = try Socket.recvExact(fd, count: 4)
        case 0x03:
            let len = try Socket.recvExact(fd, count: 1)
            _ = try Socket.recvExact(fd, count: Int(len[0]))
        case 0x04: _ = try Socket.recvExact(fd, count: 16)
        default: throw SOCKS5Error.message("invalid SOCKS5 address type")
        }
        _ = try Socket.recvExact(fd, count: 2)
    }
}
