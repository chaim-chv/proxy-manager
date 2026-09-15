import Foundation
import Darwin

// Crash probe: writing to a peer that has reset the connection must not raise
// SIGPIPE and kill the process. The proxy relays and the SOCKS5 handshake call
// `Socket.sendAll`, which relies on `SO_NOSIGPIPE` / `signal(SIGPIPE, SIG_IGN)`.
//
// Compiled with Sources/Socks/Socket.swift. Exit code 0 = survived;
// 141 = 128+SIGPIPE = process killed.
func makeResetPeer(_ ready: DispatchSemaphore, _ portOut: inout UInt16) -> Int32 {
    let lfd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var a = addr
    _ = withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    listen(lfd, 1)
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(lfd, $0, &len) }
    }
    portOut = UInt16(bigEndian: a.sin_port)
    ready.signal()
    return accept(lfd, nil, nil)
}

let ready = DispatchSemaphore(value: 0)
var port: UInt16 = 0
var serverFd: Int32 = -1
Thread.detachNewThread {
    serverFd = makeResetPeer(ready, &port)
    var l = linger(l_onoff: 1, l_linger: 0) // close() -> RST
    setsockopt(serverFd, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
    close(serverFd)
}
ready.wait()

let cfd = socket(AF_INET, SOCK_STREAM, 0)
Socket.setNoSIGPIPE(cfd) // the app sets this on every socket it creates/accepts
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
var a = addr
_ = withUnsafePointer(to: &a) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(cfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
usleep(150_000) // let the peer RST

do {
    try Socket.sendAll(cfd, [1, 2, 3, 4, 5, 6, 7, 8])
    print("PROBE: sendAll returned normally (no crash)")
} catch {
    print("PROBE: sendAll threw \(error) (no crash)")
}
exit(0)
