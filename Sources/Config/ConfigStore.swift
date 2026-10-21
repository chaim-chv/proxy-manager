import Foundation

final class ConfigStore {
    static let shared = ConfigStore()

    private let fileManager = FileManager.default

    var config: AppConfig = AppConfig() {
        didSet { save(config) }
    }

    var supportDir: URL {
        #if SCREENSHOT_MODE
        if let override = DemoMode.supportDirOverride { return override }
        #endif
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProxyManager", isDirectory: true)
    }

    var configURL: URL { supportDir.appendingPathComponent("config.json") }
    var envDir: URL {
        #if SCREENSHOT_MODE
        if let override = DemoMode.envDirOverride { return override }
        #endif
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/proxy-manager", isDirectory: true)
    }
    var envFileURL: URL { envDir.appendingPathComponent("env.sh") }
    var telemetryURL: URL { supportDir.appendingPathComponent("telemetry.sqlite") }
    var snapshotURL: URL { supportDir.appendingPathComponent("system-proxy-snapshot.json") }
    var guiEnvSnapshotURL: URL { supportDir.appendingPathComponent("gui-env-snapshot.json") }

    private init() {
        ensureDirectories()
        if let loaded = ConfigStore.load(from: configURL) {
            self.config = loaded
        } else {
            self.config = AppConfig()
            save(config)
        }
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: envDir, withIntermediateDirectories: true)
        // Owner-only: these hold config, the proxy snapshot, and env.sh.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: envDir.path)
    }

    private static func load(from url: URL) -> AppConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            let corrupt = url.deletingLastPathComponent()
                .appendingPathComponent("config.json.corrupt")
            try? FileManager.default.removeItem(at: corrupt)
            try? FileManager.default.copyItem(at: url, to: corrupt)
            NSLog("ProxyManager: config decode failed (\(error.localizedDescription)); backing up to .corrupt")
            return nil
        }
    }

    func save(_ config: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        writeOwnerOnly(data, to: configURL)
    }

    /// Atomic write, then restrict to the owner. `.atomic` replaces the inode,
    /// so the permission fix must run after the write, not before. Returns
    /// whether the data itself was written; a permission fix failing is logged
    /// but does not invalidate the recovery contract.
    @discardableResult
    private func writeOwnerOnly(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.system.error("write failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.system.error("could not restrict permissions for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    // MARK: - System-proxy snapshot (persisted so a crash can't lose the
    // user's original proxy settings; see AppModel enable/disable/quit).

    /// Persists the recovery contract. Returns false when the snapshot could
    /// not be encoded/written (or is empty); callers must abort before touching
    /// the system proxy rather than route without a recovery path.
    func saveSnapshot(_ snapshot: SystemProxySnapshot) -> Bool {
        guard !snapshot.isEmpty else {
            Log.system.error("refusing to persist an empty system-proxy snapshot")
            return false
        }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot) else {
            Log.system.error("could not encode the system-proxy snapshot")
            return false
        }
        guard writeOwnerOnly(data, to: snapshotURL) else { return false }
        return true
    }

    func loadSnapshot() -> SystemProxySnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(SystemProxySnapshot.self, from: data)
    }

    /// Removes the recovery contract. Idempotent (a missing file is success).
    /// Returns false when an existing file could not be removed; the caller
    /// should quarantine it so a later enable cannot load a stale "original".
    func clearSnapshot() -> Bool {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return true }
        do {
            try fileManager.removeItem(at: snapshotURL)
            return true
        } catch {
            Log.system.error("could not remove the system-proxy snapshot: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Moves an unremovable snapshot aside (rename within the support dir) so it
    /// can never be mistaken for the user's current original settings.
    @discardableResult
    func quarantineSnapshot() -> Bool {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return true }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let destination = supportDir.appendingPathComponent("system-proxy-snapshot.stale-\(stamp).json")
        do {
            try fileManager.moveItem(at: snapshotURL, to: destination)
            Log.system.notice("quarantined stale system-proxy snapshot as \(destination.lastPathComponent, privacy: .public)")
            return true
        } catch {
            Log.system.error("could not quarantine the stale system-proxy snapshot: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func reset() {
        config = AppConfig()
    }
}
