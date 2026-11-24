import Foundation

/// Whether the internet itself is reachable. This is deliberately separate from
/// the local link: Wi-Fi can be connected (and `NWPathMonitor` satisfied) while
/// the router's uplink is down.
enum ConnectivityStatus: Equatable {
    case checking
    case online
    case offline
}

/// Why a probe cycle failed. Every connection starts with a DNS lookup, so a
/// total outage and a resolver-only outage look identical to an app; only an
/// IP-literal probe can tell them apart.
enum ConnectivityFailure: String, Equatable, CaseIterable {
    case none
    case dns
    case network

    var label: String {
        switch self {
        case .none: return "Unknown"
        case .dns: return "DNS"
        case .network: return "Network"
        }
    }
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
    /// Only meaningful when `ok` is false.
    var failure: ConnectivityFailure = .none
}

/// One completed probe, in the shape the history sink persists.
struct ConnectivityRecord: Equatable {
    let at: Date
    let ok: Bool
    let latencyMS: Int?
    let failure: ConnectivityFailure
}

/// The monitor owns probing; this is the narrow write path into history. Keeping
/// it a protocol means `ConnectivityMonitor` stays network-only and the state
/// machine stays testable without SQLite.
protocol ConnectivityHistorySink: AnyObject {
    func recordConnectivity(_ record: ConnectivityRecord)
}

/// One outage, as the dashboard reads it back from history.
struct ConnectivityOutage: Identifiable, Equatable {
    let start: Date
    /// `nil` while the outage is still open (last check failed).
    var end: Date?
    /// First classified cause. Kept for a stable identity; `dominantFailure`
    /// is what the UI shows (real outages mix DNS and network checks).
    var failure: ConnectivityFailure
    var checks: Int
    var dnsChecks: Int = 0
    var networkChecks: Int = 0

    var id: Date { start }

    func duration(at now: Date = Date()) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }

    var isOpen: Bool { end == nil }

    /// The cause that best describes the outage. A single failed probe is
    /// always "brief"; the checklist in the UI says so.
    var dominantFailure: ConnectivityFailure {
        if dnsChecks > networkChecks { return .dns }
        if networkChecks > dnsChecks { return .network }
        return failure
    }

    /// Both probes failed during the same outage. Showing just one would hide
    /// that the resolver and the line were both unavailable.
    var isMixed: Bool { dnsChecks > 0 && networkChecks > 0 }

    /// Every failed check was a single probe: a blip, not a sustained outage.
    var isBrief: Bool { checks <= 1 }

    var causeSummary: String {
        switch (dnsChecks, networkChecks) {
        case (0, 0): return "Unknown"
        case (let d, 0): return "\(d) DNS check\(d == 1 ? "" : "s")"
        case (0, let n): return "\(n) network check\(n == 1 ? "" : "s")"
        case (let d, let n): return "\(d) DNS + \(n) network checks"
        }
    }
}

/// Range totals for the internet-health dashboard. `failed` counts completed
/// failed probes; `dnsFailed` is the subset where the IP-level check still
/// answered, which is the actionable one.
struct ConnectivityRangeStats: Equatable {
    var total = 0
    var ok = 0
    var failed = 0
    var dnsFailed = 0
    var networkFailed = 0
    var averageLatencyMS: Int?
    /// Oldest stored probe in the range. History can be younger than the
    /// selected window (the app was just installed), and the chart says so.
    var firstCheck: Date?

    var uptime: Double {
        total == 0 ? 0 : Double(ok) / Double(total)
    }
}

/// One chart bucket of probe outcomes.
struct ConnectivityBucket: Identifiable, Equatable {
    let startMs: Int64
    let total: Int
    let failed: Int
    let dnsFailed: Int
    let averageLatencyMS: Int?

    var id: Int64 { startMs }
    var ok: Int { max(0, total - failed) }
}

/// Per-outage tunnel activity, keyed by the outage start.
struct OutageTunnel: Equatable {
    var ok = 0
    var failed = 0
    var attempted: Int { ok + failed }
}

/// Did tunneled traffic keep working while the internet probe was failing?
/// Computed by matching real `TUNNEL` rows against the outage windows.
struct OutageTunnelEvidence: Equatable {
    var outagesWithTraffic = 0
    var outagesWithSuccess = 0
    var tunnelOK = 0
    var tunnelFailed = 0
    var perOutage: [Date: OutageTunnel] = [:]

    var attempted: Int { tunnelOK + tunnelFailed }
}

/// Incremental outage detection shared by the live dashboard and the SQLite
/// replay, so both can never disagree about what counts as one outage.
///
/// A gap longer than `maxGap` between two failed checks is treated as two
/// outages: the app was asleep/quit between them and the middle is unknown, so
/// reporting one 6-hour outage would be a lie.
struct ConnectivityOutageBuilder {
    static let maxGap: TimeInterval = 5 * 60

    private(set) var completed: [ConnectivityOutage] = []
    private(set) var open: ConnectivityOutage?
    private var lastFailedAt: Date?
    private var window: [ConnectivityOutage] = []

    mutating func add(at date: Date, ok: Bool, failure: ConnectivityFailure) {
        if ok {
            finishOpen(at: date)
            return
        }
        if open?.start != nil, let last = lastFailedAt, date.timeIntervalSince(last) > Self.maxGap {
            // The machine was unreachable *to us* between these checks; close
            // the first burst where it was last observed and start a new one.
            finishOpen(at: last)
            begin(at: date, failure: failure)
        } else if open == nil {
            begin(at: date, failure: failure)
        } else {
            open?.checks += 1
            count(failure)
            // Real outages alternate: a resolver stall can cascade into a
            // network timeout on the next probe. Keep the first *known* cause
            // as the identity, but count both so the UI can say "mixed".
            if open?.failure == ConnectivityFailure.none, failure != .none {
                open?.failure = failure
            }
        }
        lastFailedAt = date
    }

    /// Returns every outage, open or closed, newest last.
    func all() -> [ConnectivityOutage] {
        var result = completed
        if let current = open { result.append(current) }
        return result
    }

    private mutating func begin(at date: Date, failure: ConnectivityFailure) {
        open = ConnectivityOutage(start: date, end: nil, failure: failure, checks: 1)
        count(failure)
    }

    private mutating func count(_ failure: ConnectivityFailure) {
        switch failure {
        case .dns: open?.dnsChecks += 1
        case .network: open?.networkChecks += 1
        case .none: break
        }
    }

    private mutating func finishOpen(at date: Date) {
        guard var current = open else { return }
        current.end = date
        completed.append(current)
        open = nil
        lastFailedAt = nil
    }
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
    /// Why the current outage started. `.none` until a failed cycle has been
    /// classified (the IP-literal probe answers after the DNS probe fails).
    private(set) var failure: ConnectivityFailure = .none
    /// Start times of online → offline transitions, trimmed to `outageWindow`.
    private(set) var outages: [Date] = []
    /// Most recent checks, oldest first, capped at `maxChecks`.
    private(set) var checks: [ConnectivityCheck] = []
    private var nextCheckID = 0

    /// Applies one probe outcome. Repeated failures while already offline do
    /// not count as new drops; a recovery ends the current outage.
    mutating func record(ok: Bool, latencyMS: Int?, at date: Date,
                         failure: ConnectivityFailure = .none) {
        status = ok ? .online : .offline
        lastChecked = date
        if ok {
            self.latencyMS = latencyMS
            self.lastSuccess = date
            offlineSince = nil
            self.failure = .none
        } else {
            self.latencyMS = nil
            if offlineSince == nil {
                offlineSince = date
                outages.append(date)
                self.failure = failure
            } else if self.failure == .none {
                // A later cycle may be the one that finally classifies the
                // outage (the watchdog can complete an earlier one first).
                self.failure = failure
            }
        }

        nextCheckID += 1
        checks.append(ConnectivityCheck(id: nextCheckID, at: date, ok: ok, failure: ok ? .none : failure))
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
        case .offline:
            return failure == .dns ? "Offline — DNS failing" : "Offline"
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
                text = (failure == .dns ? "Name lookups are failing since " : "No internet since ")
                    + "\(since.formatted(date: .omitted, time: .shortened))"
                    + " (\(Self.shortDuration(now.timeIntervalSince(since))))."
            } else {
                text = failure == .dns ? "Name lookups are failing." : "No internet."
            }
            if failure == .dns {
                text += " An IP-level check still answered, so the network path is up —"
                text += " the resolver or your provider's DNS is the problem."
                text += " Apps with an existing connection or a tunnel can keep working."
            } else if failure == .network {
                text += " The IP-level check also failed, so the network path itself is down."
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
            let duration = offlineSince.map { Self.shortDuration(now.timeIntervalSince($0)) }
            if failure == .dns {
                return duration.map { "No DNS · \($0)" } ?? "No DNS"
            }
            return duration.map { "Offline · \($0)" } ?? "Offline"
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
