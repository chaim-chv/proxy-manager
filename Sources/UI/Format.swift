import Foundation

enum Format {
    // Static formatters are reused across all rows. They are only touched on
    // the main thread (in the dashboard rows), so this is safe.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }

    static func time(_ ts: Int64) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: Double(ts) / 1000))
    }

    static func duration(_ ms: Int64) -> String {
        if ms < 1000 { return "\(ms)ms" }
        if ms < 60_000 { return String(format: "%.1fs", Double(ms) / 1000) }
        return String(format: "%.1fm", Double(ms) / 60_000)
    }
}
