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

    private static let integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        // `ByteCountFormatter` renders 0 as "Zero KB"; a plain 0 is clearer in a
        // stat box or a table cell.
        guard value != 0 else { return "0" }
        return byteFormatter.string(fromByteCount: value)
    }

    /// Grouped integer ("12,392") for counts. The strip, the chart legend and
    /// the feed header all use it so they agree.
    static func count(_ value: Int) -> String {
        integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func time(_ ts: Int64) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: Double(ts) / 1000))
    }

    /// Connection lifetime ("open for"). Never used for latency — see
    /// `latency` for the time-to-upstream value.
    static func duration(_ ms: Int64) -> String {
        if ms < 1000 { return "\(ms)ms" }
        if ms < 60_000 { return String(format: "%.1fs", Double(ms) / 1000) }
        if ms < 3_600_000 { return String(format: "%.1fm", Double(ms) / 60_000) }
        return String(format: "%.1fh", Double(ms) / 3_600_000)
    }

    /// Time from accept to upstream-established. `0` means "not measured"
    /// (legacy rows, or a connection that never opened), not "instant".
    static func latency(_ ms: Int64) -> String {
        guard ms > 0 else { return "—" }
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000)
    }
}
