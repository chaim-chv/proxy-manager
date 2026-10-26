import Foundation
import Darwin

/// The app's local control endpoint.
///
/// The XPC agent (and tests/dev clients) connect over a Unix socket in the app
/// support directory. The socket is `0600`, owned by the current user, and every
/// connection must present the per-launch token from `control.token`. Handler
/// calls are hopped to the main thread so the router sees main-thread state.
///
/// The transport is deliberately independent of XPC: `SMAppService.agent`
/// cannot register in an ad-hoc build, and a socket keeps the router testable
/// without a signed, installed app.
final class ControlSocketServer {
    typealias Handler = (ControlIdentity, IntegrationRequest) -> IntegrationResult

    let socketPath: String
    let tokenPath: String
    private(set) var token: String

    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private let slots = DispatchSemaphore(value: 8)

    init(socketPath: String, tokenPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.tokenPath = tokenPath
        self.handler = handler
        self.token = Self.generateToken()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: - Lifecycle

    func start() -> Bool {
        lock.lock()
        guard !running else {
            lock.unlock()
            return true
        }
        lock.unlock()

        token = Self.generateToken()

        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        unlink(socketPath)
        unlink(tokenPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.integration.error("control socket: socket() failed")
            return false
        }
        ControlSocket.setNoSigPipe(fd)

        guard ControlSocket.bind(fd, path: socketPath) else {
            Log.integration.error("control socket: bind failed at \(self.socketPath, privacy: .public)")
            close(fd)
            return false
        }
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else {
            Log.integration.error("control socket: listen failed")
            close(fd)
            unlink(socketPath)
            return false
        }

        do {
            try writeToken()
        } catch {
            Log.integration.error("control socket: token write failed: \(error.localizedDescription, privacy: .public)")
            close(fd)
            unlink(socketPath)
            return false
        }

        lock.lock()
        listenFD = fd
        running = true
        lock.unlock()

        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        return true
    }

    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let fd = listenFD
        listenFD = -1
        lock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(socketPath)
        unlink(tokenPath)
    }

    // MARK: - Accept

    private func acceptLoop() {
        while isRunning {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if !isRunning { break }
                usleep(10_000)
                continue
            }
            if slots.wait(timeout: .now()) == .timedOut {
                close(fd)
                continue
            }
            Thread.detachNewThread { [weak self] in self?.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            close(fd)
            slots.signal()
        }
        ControlSocket.setNoSigPipe(fd)

        guard ControlSocket.peerUID(fd) == getuid() else {
            Log.integration.notice("control socket: rejected a connection from another user")
            return
        }

        do {
            let frame = try ControlFraming.readFrame(fd)
            let request = try ControlFraming.decode(ControlRequest.self, from: frame)
            guard ControlSocket.constantTimeEquals(request.token, token) else {
                Log.integration.notice("control socket: rejected a wrong token")
                return
            }
            let result = DispatchQueue.main.sync {
                handler(request.identity, request.request)
            }
            let payload = try ControlFraming.encode(ControlResponse(result: result))
            try ControlFraming.writeFrame(fd, payload)
        } catch {
            Log.integration.debug("control socket: connection ended: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Token

    private func writeToken() throws {
        try token.write(toFile: tokenPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tokenPath
        )
    }

    static func generateToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: 0...255, using: &generator))
        }.joined()
    }
}
