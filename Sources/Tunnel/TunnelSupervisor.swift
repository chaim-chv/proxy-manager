import Foundation

final class TunnelSupervisor: ObservableObject {
    @Published var tunnelUp: Bool = false

    private let configStore: ConfigStore
    private var timer: Timer?
    private var probing = false

    private let stateLock = NSLock()
    private var upState = false

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    /// Thread-safe read for the proxy core (called from connection handlers).
    var isTunnelUp: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return upState
    }

    func start(interval: TimeInterval = 10) {
        guard timer == nil else { return }
        probe()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.probe()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func probeNow() {
        probe()
    }

    private func probe() {
        stateLock.lock()
        if probing { stateLock.unlock(); return }
        probing = true
        stateLock.unlock()
        let cfg = configStore.config
        let host = cfg.tunnel.effectiveHost
        let port = cfg.tunnel.effectivePort

        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                self?.stateLock.lock(); self?.probing = false; self?.stateLock.unlock()
            }
            let up = (try? SOCKS5Client.probe(serverHost: host, serverPort: port)) != nil
            self?.stateLock.lock()
            self?.upState = up
            self?.stateLock.unlock()
            DispatchQueue.main.async {
                self?.tunnelUp = up
            }
        }
    }

    /// Restarts the tunnel via launchd (if supervised and a job label is set).
    /// Never called automatically — only from the "Restart tunnel" UI. Runs off
    /// the main thread with drained pipes so a slow/hung `launchctl` cannot freeze
    /// the UI or deadlock on a full pipe buffer.
    func restartTunnel() {
        let cfg = configStore.config
        let job = cfg.tunnel.launchdLabel.trimmingCharacters(in: .whitespaces)
        guard cfg.tunnel.supervised, !job.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(job)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                Log.tunnel.error("launchctl kickstart failed to launch: \(error.localizedDescription)")
                return
            }
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                Log.tunnel.error("launchctl kickstart exited \(process.terminationStatus)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.probeNow()
            }
        }
    }
}
