import Foundation

/// Append-only JSONL safety trail for every integration request.
///
/// Writes happen on a private serial queue so a slow disk can never delay a
/// request. A write failure is logged and degrades the audit flag; it never
/// blocks the mutation (availability over logging), which is why the router
/// also emits the outcome to the unified log.
final class IntegrationAudit {
    static let fileName = "integration-audit.jsonl"

    private let directory: URL
    private let fileURL: URL
    private let maxBytes: Int
    private let maxArchives: Int
    private let queue = DispatchQueue(label: "com.proxymanager.integration.audit")
    private var handle: FileHandle?
    private var size: Int = 0
    private var degraded = false

    /// Safe to read from any thread; used by `status` once the audit is wired.
    var isDegraded: Bool { queue.sync { degraded } }

    private static let redactedKeys: Set<String> = [
        "password", "secret", "token", "credential", "credentials",
        "keychain", "apitoken", "api_token",
    ]

    init(directory: URL, maxBytes: Int = 2 * 1024 * 1024, maxArchives: Int = 5) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.maxBytes = maxBytes
        self.maxArchives = maxArchives
    }

    // MARK: - Write

    func record(_ entry: IntegrationAuditEntry) {
        queue.async { [weak self] in self?.append(entry) }
    }

    /// Blocks until pending writes land. Tests and shutdown only.
    func flush() {
        queue.sync {}
    }

    private func append(_ entry: IntegrationAuditEntry) {
        guard let data = try? JSONEncoder().encode(entry) else {
            degraded = true
            return
        }
        ensureOpen()
        guard self.handle != nil else {
            degraded = true
            return
        }
        if size + data.count + 1 > maxBytes {
            rotate()
            ensureOpen()
        }
        guard let current = self.handle else {
            degraded = true
            return
        }
        var line = data
        line.append(0x0A)
        do {
            try current.write(contentsOf: line)
            size += line.count
        } catch {
            degraded = true
            Log.integration.error("audit write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureOpen() {
        guard handle == nil else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            let h = try FileHandle(forWritingTo: fileURL)
            size = Int((try? h.seekToEnd()) ?? 0)
            handle = h
        } catch {
            degraded = true
            Log.integration.error("audit open failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        size = 0
        let fm = FileManager.default
        guard maxArchives > 0 else {
            try? fm.removeItem(at: fileURL)
            return
        }
        try? fm.removeItem(at: archiveURL(maxArchives))
        for index in stride(from: maxArchives - 1, through: 1, by: -1) {
            let from = archiveURL(index)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.moveItem(at: from, to: archiveURL(index + 1))
        }
        guard fm.fileExists(atPath: fileURL.path) else { return }
        try? fm.moveItem(at: fileURL, to: archiveURL(1))
    }

    private func archiveURL(_ index: Int) -> URL {
        directory.appendingPathComponent("\(Self.fileName).\(index)")
    }

    // MARK: - Read (tests, support)

    func readAll() -> [IntegrationAuditEntry] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            let decoder = JSONDecoder()
            return data.split(separator: 0x0A).compactMap {
                try? decoder.decode(IntegrationAuditEntry.self, from: Data($0))
            }
        }
    }

    // MARK: - Redaction

    static func redact(_ args: [String: IntegrationValue]) -> [String: IntegrationValue] {
        var out: [String: IntegrationValue] = [:]
        for (key, value) in args {
            if redactedKeys.contains(key.lowercased()) {
                out[key] = .string("***")
            } else {
                out[key] = redact(value)
            }
        }
        return out
    }

    private static func redact(_ value: IntegrationValue) -> IntegrationValue {
        switch value {
        case .object(let object):
            return .object(redact(object))
        case .array(let array):
            return .array(array.map { redact($0) })
        default:
            return value
        }
    }
}
