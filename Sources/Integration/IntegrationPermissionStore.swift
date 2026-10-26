import Foundation
import CryptoKit

struct IntegrationPermission: Codable, Equatable {
    var key: String
    var requirement: String
    var bundleID: String?
    var teamID: String?
    var displayName: String
    var path: String?
    var scope: IntegrationScope
    var firstSeen: String
    var lastSeen: String
}

/// Remembers which code identities the user approved, and at what scope.
///
/// Keyed by the code-signing designated requirement rather than the bundle id:
/// a different binary claiming the same bundle id must not inherit a grant.
/// The store is a 0600 JSON file next to the config, so revoking in Settings is
/// durable and a reset can remove it.
final class IntegrationPermissionStore {
    private let fileURL: URL
    private let lock = NSLock()
    private var permissions: [String: IntegrationPermission] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func scope(for identity: ControlIdentity) -> IntegrationScope? {
        let key = Self.key(for: identity)
        lock.lock()
        defer { lock.unlock() }
        return permissions[key]?.scope
    }

    @discardableResult
    func grant(_ identity: ControlIdentity, scope: IntegrationScope) -> IntegrationPermission {
        let key = Self.key(for: identity)
        let now = Self.timestamp()
        lock.lock()
        var permission = permissions[key] ?? IntegrationPermission(
            key: key,
            requirement: identity.requirement,
            bundleID: identity.bundleID,
            teamID: identity.teamID,
            displayName: identity.displayName,
            path: identity.path,
            scope: scope,
            firstSeen: now,
            lastSeen: now
        )
        permission.scope = scope
        permission.lastSeen = now
        permission.displayName = identity.displayName
        permission.bundleID = identity.bundleID
        permission.teamID = identity.teamID
        permission.path = identity.path
        permissions[key] = permission
        lock.unlock()
        persist()
        return permission
    }

    func revoke(key: String) {
        lock.lock()
        permissions.removeValue(forKey: key)
        lock.unlock()
        persist()
    }

    func all() -> [IntegrationPermission] {
        lock.lock()
        defer { lock.unlock() }
        return permissions.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([IntegrationPermission].self, from: data) else {
            return
        }
        // A hand-edited file can repeat a key; the last entry wins rather than
        // trapping at launch.
        var loaded: [String: IntegrationPermission] = [:]
        for permission in stored { loaded[permission.key] = permission }
        permissions = loaded
    }

    private func persist() {
        lock.lock()
        let values = Array(permissions.values)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(values) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            Log.integration.error("permissions: could not save: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Identity key

    /// A stable, non-reversible key for the caller's designated requirement.
    /// Unsigned processes fall back to their executable path, which the consent
    /// sheet must call out.
    static func key(for identity: ControlIdentity) -> String {
        let source = identity.requirement.isEmpty
            ? "unsigned:\(identity.path ?? identity.bundleID ?? "unknown")"
            : identity.requirement
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}
