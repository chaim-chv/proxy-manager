import Foundation

/// Whether the internet itself is reachable. This is deliberately separate from
/// the local link: Wi-Fi can be connected (and `NWPathMonitor` satisfied) while
/// the router's uplink is down.
enum ConnectivityStatus: Equatable {
    case checking
    case online
    case offline
}

/// A presentation-oriented rollup: `.unstable` means currently online, but the
/// internet dropped recently (the "works for a few minutes at a time" case).
enum ConnectivityHealth: Equatable {
    case checking
    case good
    case unstable
    case down
}

/// One completed reachability probe, kept for the recent-history strip.
struct ConnectivityCheck: Identifiable, Equatable {
    let id: Int
    let at: Date
    let ok: Bool
}

/// Immutable-style state for the internet monitor. `ConnectivityMonitor` owns
/// the network side; this type stays pure so the classification rules can be
/// regression-tested without touching the network (`Tests/ConnectivityHarness`).
struct ConnectivitySnapshot: Equatable {
    /// The history strip shows roughly the last 8 minutes at the online cadence.
    static let maxChecks = 60
    /// How long a drop keeps the state "unstable".
    static let unstableWindow: TimeInterval = 10 * 60
    /// How long a drop is counted in "n drops in the last hour".
    static let outageWindow: TimeInterval = 60 * 60

    private(set) var status: ConnectivityStatus = .checking
    private(set) var latencyMS: Int?
    private(set) var lastChecked: Date?
    private(set) var lastSuccess: Date?
    private(set) var offlineSince: Date?
    /// Start times of online → offline transitions, trimmed to `outageWindow`.
    private(set) var outages: [Date] = []
    /// Most recent checks, oldest first, capped at `maxChecks`.
    private(set) var checks: [ConnectivityCheck] = []
    private var nextCheckID = 0

    /// Applies one probe outcome. Repeated failures while already offline do
    /// not count as new drops; a recovery ends the current outage.
    mutating func record(ok: Bool, latencyMS: Int?, at date: Date) {
        status = ok ? .online : .offline
        lastChecked = date
        if ok {
            self.latencyMS = latencyMS
            lastSuccess = date
            offlineSince = nil
        } else {
            self.latencyMS = nil
            if offlineSince == nil {
                offlineSince = date
                outages.append(date)
            }
        }

        nextCheckID += 1
        checks.append(ConnectivityCheck(id: nextCheckID, at: date, ok: ok))
        if checks.count > Self.maxChecks {
            checks.removeFirst(checks.count - Self.maxChecks)
        }
        outages.removeAll { date.timeIntervalSince($0) > Self.outageWindow }
    }

    func health(at now: Date = Date()) -> ConnectivityHealth {
        switch status {
        case .checking:
            return .checking
        case .offline:
            return .down
        case .online:
            return recentOutageCount(Self.unstableWindow, at: now) > 0 ? .unstable : .good
        }
    }

    func recentOutageCount(_ window: TimeInterval, at now: Date) -> Int {
        outages.reduce(0) { $0 + (now.timeIntervalSince($1) <= window && now >= $1 ? 1 : 0) }
    }

    /// Colored-dot title (Settings and the menu row).
    func title(at now: Date = Date()) -> String {
        switch status {
        case .checking: return "Checking…"
        case .offline: return "Offline"
        case .online: return health(at: now) == .unstable ? "Online — unstable" : "Online"
        }
    }

    /// One-line explanation, shown under the dot in Settings.
    func detail(at now: Date = Date()) -> String {
        switch status {
        case .checking:
            return "Contacting the internet to check reachability…"
        case .offline:
            var text: String
            if let since = offlineSince {
                text = "No internet since \(since.formatted(date: .omitted, time: .shortened))"
                    + " (\(Self.shortDuration(now.timeIntervalSince(since))))."
            } else {
                text = "No internet."
            }
            if let lastSuccess {
                text += " Last success at \(lastSuccess.formatted(date: .omitted, time: .shortened))."
            }
            text += " Wi-Fi can stay connected while the router's uplink is down."
            return text
        case .online:
            var text = latencyMS.map { "Replied in \($0) ms." } ?? "Connected."
            let drops = recentOutageCount(Self.outageWindow, at: now)
            if drops > 0 {
                text += " \(drops) drop\(drops == 1 ? "" : "s") in the last hour."
            }
            return text
        }
    }

    /// Compact right-aligned value for the menu-bar menu row.
    func menuValue(at now: Date = Date()) -> String {
        switch status {
        case .checking:
            return "Checking…"
        case .online:
            if health(at: now) == .unstable { return "Online · unstable" }
            return latencyMS.map { "Online · \($0) ms" } ?? "Online"
        case .offline:
            if let since = offlineSince {
                return "Offline · \(Self.shortDuration(now.timeIntervalSince(since)))"
            }
            return "Offline"
        }
    }

    static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60) min" }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }
}
