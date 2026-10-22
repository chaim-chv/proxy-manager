import Foundation
import Darwin

/// Process-lifetime exclusive lock on the support directory.
///
/// Two app instances share `config.json`, the proxy/GUI snapshots, `ssh.pid`
/// and `watchdog.json`; one instance's quit could otherwise restore and clear
/// the other's recovery state. `flock` is released automatically when the last
/// descriptor closes, so a crash never leaves a stale lock behind (LC-14).
final class SingleInstanceLock {
    static let fileName = "single-instance.lock"

    /// The app holds exactly one lock for the whole process lifetime.
    static let shared = SingleInstanceLock(directory: defaultSupportDir)

    /// Matches `ConfigStore`'s support directory resolution: the demo sandbox
    /// when screenshot mode is active, otherwise the env override, otherwise
    /// `~/Library/Application Support/ProxyManager`.
    static var defaultSupportDir: URL {
        #if SCREENSHOT_MODE
        if let demo = DemoMode.supportDirOverride { return demo }
        #endif
        if let override = ProcessInfo.processInfo.environment["PROXYMANAGER_SUPPORT_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProxyManager", isDirectory: true)
    }

    private let directory: URL
    private let lockURL: URL
    private let stateLock = NSLock()
    private var fd: Int32 = -1

    init(directory: URL) {
        self.directory = directory
        self.lockURL = directory.appendingPathComponent(Self.fileName)
    }

    /// Takes the lock without blocking. Returns false only when another
    /// descriptor (i.e. another instance) already owns it. Logs unexpected
    /// failures; contention is reported once by the caller.
    @discardableResult
    func acquire() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if fd >= 0 { return true }

        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
            } catch {
                Log.app.error("single-instance: cannot create support directory: \(error.localizedDescription)")
                return false
            }
        }

        let candidate = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard candidate >= 0 else {
            Log.app.error("single-instance: cannot open lock file (errno \(errno))")
            return false
        }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(candidate)
            if code != EWOULDBLOCK {
                Log.app.error("single-instance: flock failed (errno \(code))")
            }
            return false
        }

        // The file may have pre-existed with a wider mode.
        _ = fchmod(candidate, 0o600)
        fd = candidate
        return true
    }

    /// Releases the lock. Production keeps `shared` for the process lifetime;
    /// only the regression harness calls this.
    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit {
        release()
    }
}
