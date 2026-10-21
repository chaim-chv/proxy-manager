import Foundation

final class ConfigStore {
    static let shared = ConfigStore()

    private let fileManager = FileManager.default

    // Injected paths (tests). `nil` means "compute the production default".
    private let supportDirOverride: URL?
    private let envDirOverride: URL?
    private let configURLOverride: URL?
    private let snapshotURLOverride: URL?

    /// Set when the on-disk config exists but could not be read, or when a
    /// corrupt config could not be backed up. The store then runs on in-memory
    /// defaults and refuses to write over the user's file (TC-02).
    private(set) var loadFailed = false
    private(set) var loadError: String?

    private var suppressSave = false

    var config: AppConfig = AppConfig() {
        didSet {
            guard !suppressSave else { return }
            save(config)
        }
    }

    var supportDir: URL {
        if let override = supportDirOverride { return override }
        #if SCREENSHOT_MODE
        if let override = DemoMode.supportDirOverride { return override }
        #endif
        if let override = ProcessInfo.processInfo.environment["PROXYMANAGER_SUPPORT_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProxyManager", isDirectory: true)
    }

    var configURL: URL {
        configURLOverride ?? supportDir.appendingPathComponent("config.json")
    }
    var envDir: URL {
        #if SCREENSHOT_MODE
        if let override = DemoMode.envDirOverride { return override }
        #endif
        if let override = envDirOverride { return override }
        if let override = ProcessInfo.processInfo.environment["PROXYMANAGER_SUPPORT_DIR"],
           !override.isEmpty {
            // Test/dev isolation: keep injected state together instead of
            // touching the user's ~/.config.
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("env", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/proxy-manager", isDirectory: true)
    }
    var envFileURL: URL { envDir.appendingPathComponent("env.sh") }
    var telemetryURL: URL { supportDir.appendingPathComponent("telemetry.sqlite") }
    var snapshotURL: URL {
        snapshotURLOverride ?? supportDir.appendingPathComponent("system-proxy-snapshot.json")
    }
    var guiEnvSnapshotURL: URL { supportDir.appendingPathComponent("gui-env-snapshot.json") }

    /// Production/default paths. `PROXYMANAGER_SUPPORT_DIR` isolates tests the
    /// same way it does for `WatchdogPaths`.
    init(supportDir: URL? = nil) {
        self.supportDirOverride = supportDir
        self.envDirOverride = supportDir?.appendingPathComponent("env", isDirectory: true)
        self.configURLOverride = nil
        self.snapshotURLOverride = nil
        loadOrCreate()
    }

    /// Injectable paths for tests. The snapshot defaults to the config's folder
    /// and the shell-env file stays inside the same temp directory.
    init(configURL: URL, snapshotURL: URL? = nil) {
        let dir = configURL.deletingLastPathComponent()
        self.supportDirOverride = dir
        self.envDirOverride = dir.appendingPathComponent("env", isDirectory: true)
        self.configURLOverride = configURL
        self.snapshotURLOverride = snapshotURL
        loadOrCreate()
    }

    private enum LoadOutcome {
        case missing
        case decoded(AppConfig)
        case unreadable(Error)
        case corrupt(Error, backupCreated: Bool)
    }

    private func loadOrCreate() {
        ensureDirectories()
        suppressSave = true
        defer { suppressSave = false }

        switch ConfigStore.load(from: configURL) {
        case .missing:
            config = AppConfig()
            loadFailed = false
            loadError = nil
            save(config)
        case .decoded(let loaded):
            config = loaded
            loadFailed = false
            loadError = nil
        case .unreadable(let error):
            // The file exists and may still be intact: never overwrite it.
            config = AppConfig()
            loadFailed = true
            loadError = error.localizedDescription
            Log.system.error("config exists but could not be read; keeping it and using in-memory defaults: \(error.localizedDescription, privacy: .public)")
        case .corrupt(let error, let backupCreated):
            config = AppConfig()
            if backupCreated {
                loadFailed = false
                loadError = nil
                save(config)
            } else {
                // No backup means we cannot safely replace the only copy.
                loadFailed = true
                loadError = error.localizedDescription
                Log.system.error("config could not be decoded or backed up; keeping it: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: envDir, withIntermediateDirectories: true)
        // Owner-only: these hold config, the proxy snapshot, and env.sh.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: envDir.path)
    }

    private static func load(from url: URL) -> LoadOutcome {
        // Only a truly absent file may be treated as "create defaults".
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(error)
        }
        do {
            return .decoded(try JSONDecoder().decode(AppConfig.self, from: data))
        } catch {
            let backupCreated = backupCorruptConfig(at: url)
            NSLog("ProxyManager: config decode failed (\(error.localizedDescription)); backup \(backupCreated ? "created" : "FAILED")")
            return .corrupt(error, backupCreated: backupCreated)
        }
    }

    /// Copies a corrupt config to `config.json.corrupt-<ms>` next to it. Never
    /// overwrites an older backup: a same-millisecond collision gets `-1`,
    /// `-2`, ... appended.
    private static func backupCorruptConfig(at url: URL) -> Bool {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var destination = dir.appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        var suffix = 1
        while fm.fileExists(atPath: destination.path) {
            destination = dir.appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)-\(suffix)")
            suffix += 1
        }
        do {
            try fm.copyItem(at: url, to: destination)
            return true
        } catch {
            Log.system.error("could not back up the corrupt config: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func save(_ config: AppConfig) {
        // A failed load must not destroy a file that may still be recoverable.
        if loadFailed && fileManager.fileExists(atPath: configURL.path) {
            Log.system.error("refusing to overwrite \(self.configURL.lastPathComponent, privacy: .public) after a failed load")
            return
        }
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

    /// Explicit user reset: clears the failed-load latch and writes defaults,
    /// even if the old file was unreadable.
    func reset() {
        loadFailed = false
        loadError = nil
        suppressSave = true
        config = AppConfig()
        suppressSave = false
        save(config)
    }
}
