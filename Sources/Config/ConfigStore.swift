import Foundation

final class ConfigStore {
    static let shared = ConfigStore()

    private let fileManager = FileManager.default

    var config: AppConfig = AppConfig() {
        didSet { save(config) }
    }

    var supportDir: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProxyManager", isDirectory: true)
    }

    var configURL: URL { supportDir.appendingPathComponent("config.json") }
    var envDir: URL { fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/proxy-manager", isDirectory: true) }
    var envFileURL: URL { envDir.appendingPathComponent("env.sh") }
    var telemetryURL: URL { supportDir.appendingPathComponent("telemetry.sqlite") }
    var snapshotURL: URL { supportDir.appendingPathComponent("system-proxy-snapshot.json") }

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
        try? data.write(to: configURL, options: .atomic)
    }

    // MARK: - System-proxy snapshot (persisted so a crash can't lose the
    // user's original proxy settings; see AppModel enable/disable/quit).

    func saveSnapshot(_ snapshot: SystemProxySnapshot) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    func loadSnapshot() -> SystemProxySnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(SystemProxySnapshot.self, from: data)
    }

    func clearSnapshot() {
        try? fileManager.removeItem(at: snapshotURL)
    }

    func reset() {
        config = AppConfig()
    }
}
