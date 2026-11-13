import SwiftUI
import Charts
import Combine
import AppKit

private enum TimeRange: String, CaseIterable, Identifiable {
    case m5, h1, h24, d7

    var id: String { rawValue }

    var label: String {
        switch self {
        case .m5: return "5m"
        case .h1: return "1h"
        case .h24: return "24h"
        case .d7: return "7d"
        }
    }

    /// Spelled out where the UI needs to state the window it is showing.
    var longLabel: String {
        switch self {
        case .m5: return "Last 5 minutes"
        case .h1: return "Last hour"
        case .h24: return "Last 24 hours"
        case .d7: return "Last 7 days"
        }
    }

    /// Bucket width in words, for the chart subtitle ("2 h buckets").
    var bucketLabel: String {
        switch self {
        case .m5: return "30 s"
        case .h1: return "1 min"
        case .h24: return "15 min"
        case .d7: return "2 h"
        }
    }

    var seconds: Int {
        switch self {
        case .m5: return 300
        case .h1: return 3_600
        case .h24: return 86_400
        case .d7: return 604_800
        }
    }

    var bucketMs: Int64 {
        switch self {
        case .m5: return 30_000
        case .h1: return 60_000
        case .h24: return 900_000
        case .d7: return 7_200_000
        }
    }

    /// How often this range re-queries SQLite. The 5 m chart is bucketed from
    /// live memory, so it never touches the database.
    var queryCadence: TimeInterval? {
        switch self {
        case .m5: return nil
        case .h1: return 5
        case .h24: return 15
        case .d7: return 60
        }
    }

    var axisComponent: Calendar.Component {
        switch self {
        case .m5, .h1: return .minute
        case .h24: return .hour
        case .d7: return .day
        }
    }

    var axisCount: Int {
        switch self {
        case .m5: return 1
        case .h1: return 10
        case .h24: return 2
        case .d7: return 1
        }
    }
}

private enum ChartMetric: String, CaseIterable, Identifiable {
    case requests, bytes, errors

    var id: String { rawValue }

    var label: String {
        switch self {
        case .requests: return "Connections"
        case .bytes: return "Bytes"
        case .errors: return "Failures"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var telemetry: TelemetryStore

    @State private var routeFilter: String = "All"
    @State private var hostFilter: String = ""
    @State private var appFilterKey: String?
    @State private var paused = false
    @State private var pausedSnapshot: [FeedRow] = []
    @State private var timeRange: TimeRange = DashboardView.initialRange
    @State private var metric: ChartMetric = DashboardView.initialMetric
    @State private var topMetric: TopMetric = DashboardView.initialTopMetric
    @State private var selectedID: UUID?
    @State private var windowVisible = true

    #if SCREENSHOT_MODE
    /// Screenshot builds can open on a specific range/tab/metric so a capture
    /// can show the 24 h chart, the Targets panel or the failure triage.
    private static var initialRange: TimeRange {
        switch ProcessInfo.processInfo.environment["PROXYMANAGER_RANGE"] {
        case "1h": return .h1
        case "24h": return .h24
        case "7d": return .d7
        default: return .m5
        }
    }

    private static var initialMetric: ChartMetric {
        switch ProcessInfo.processInfo.environment["PROXYMANAGER_METRIC"] {
        case "bytes": return .bytes
        case "errors": return .errors
        default: return .requests
        }
    }

    private static var initialTopMetric: TopMetric {
        switch ProcessInfo.processInfo.environment["PROXYMANAGER_TOP"] {
        case "apps": return .apps
        case "targets": return .targets
        default: return .hosts
        }
    }
    #else
    private static let initialRange: TimeRange = .m5
    private static let initialMetric: ChartMetric = .requests
    private static let initialTopMetric: TopMetric = .hosts
    #endif

    // Long-range chart/top-hosts data, loaded from SQLite. The 2 s ticker below
    // only drives a load once the range's cadence has elapsed; one chart + one
    // top query pair may be in flight, and completions are tagged with the
    // generation they were requested under so a stale pair (after a range/top
    // metric change or a window restore) can never paint over newer data.
    @State private var dbSeries: [ChartBucket] = []
    @State private var dbTopHosts: [(host: String, count: Int)] = []
    @State private var dbTopApps: [(app: String, bundle: String?, count: Int)] = []
    @State private var lastDBLoad: Int64 = 0
    @State private var dbPendingCount = 0
    @State private var dbLoading = false
    @State private var dbGeneration = 0
    @State private var dbRefreshPending = false
    /// Range-scoped aggregates for the strip, loaded beside the chart.
    @State private var dbStats = RangeStats()
    @State private var dbActivity24h: [HostActivity] = []
    @State private var lastTargetsLoad: Int64 = 0
    @State private var dbFailingHosts: [(host: String, count: Int)] = []
    /// Bucket under the pointer, for the chart's value readout.
    @State private var hoverBucketMs: Int64?
    @State private var showingClearConfirm = false
    @State private var sortKey = "time"
    @State private var sortAscending = false

    private let routeOptions = ["All", "Tunneled", "Direct", "Blocked"]
    @StateObject private var seriesTicker = CoalescedTicker(interval: 2)

    private enum TopMetric: String, CaseIterable, Identifiable {
        case hosts = "Hosts"
        case apps = "Apps"
        case targets = "Targets"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if windowVisible {
                loadedContent()
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onChange(of: timeRange) { _, _ in
            clearLongRangeData()
            refreshLongRange(force: true)
        }
        .onChange(of: topMetric) { _, _ in
            clearLongRangeData()
            refreshLongRange(force: true)
        }
        .onChange(of: windowVisible) { _, visible in
            guard visible else {
                seriesTicker.stop()
                return
            }
            seriesTicker.start()
            reconcileSelection()
            refreshLongRange(force: true)
        }
        .onChange(of: telemetry.liveRequests.count) { _, _ in reconcileSelection() }
        .onChange(of: telemetry.recentRequests.count) { _, _ in reconcileSelection() }
        .onReceive(seriesTicker.$tick) { _ in refreshLongRange() }
        .onAppear {
            if windowVisible {
                seriesTicker.start()
                // Load immediately instead of leaving a long range blank until
                // the first 2 s tick.
                refreshLongRange(force: true)
            }
        }
        .onDisappear { seriesTicker.stop() }
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        #if SCREENSHOT_MODE
        .onAppear {
            guard DemoMode.isEnabled, DemoMode.showsDetailPanel else { return }
            // The seeded feed is published by the flusher, not synchronously;
            // wait one turn before picking a row for the detail-panel capture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                guard selectedID == nil else { return }
                let event = telemetry.recentRequests.last { $0.route == .tunnel && !$0.path.isEmpty }
                    ?? telemetry.recentRequests.last { $0.route == .tunnel }
                selectedID = event?.id
            }
        }
        #endif
    }

    /// The full dashboard. Only built while the hosting window is on screen:
    /// every value here walks the live/recent event arrays or the chart data, so
    /// an occluded/minimized/hidden window skips all of it (UI-08).
    private func loadedContent() -> some View {
        let baseRows = baseFeedRows()
        let appOptions = appFilterOptions(from: paused ? pausedSnapshot : baseRows)
        let appOptionIds = appOptions.map(\.id)
        let appKey = validatedAppFilterKey(appOptions)
        // Pause freezes the unfiltered base rows, not the filtered result, so the
        // route/host/app filters keep working on the frozen data (UI-15).
        let rows = computeFeedRows(from: paused ? pausedSnapshot : baseRows, appKey: appKey)
        let points = seriesPoints
        let stats = currentStats()
        let targets = currentTargets(activity: currentActivity())

        return VStack(spacing: 0) {
            header
            Divider()
            statusAndStats(stats: stats)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            HStack(alignment: .top, spacing: 16) {
                chartSection(points: points)
                topHostsSection(items: topItems, targets: targets, activity: currentActivity())
                    .frame(width: 300)
            }
            .padding(16)
            .frame(height: 286)
            Divider()
            feedArea(rows: rows, appOptions: appOptions, buffered: (paused ? pausedSnapshot : baseRows).count)
        }
        .onChange(of: paused) { _, isPaused in
            if isPaused { pausedSnapshot = baseRows }
        }
        // The app filter menu is hidden when no apps are in the feed, so a
        // selected app that ages out (or is purged) would otherwise silently
        // filter every remaining row. Re-validate on appearance and whenever
        // the live option set changes; `initial: true` also covers a stale
        // selection surviving a hide/restore (UI-07).
        .onChange(of: appOptionIds, initial: true) { _, ids in
            guard let key = appFilterKey, !ids.contains(key) else { return }
            appFilterKey = nil
        }
    }

    private func reconcileSelection() {
        guard windowVisible else { return }
        if selectedID != nil && selectedEvent == nil { selectedID = nil }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: model.toggle) {
                Label(model.state.isActive ? "Disable" : "Enable",
                      systemImage: model.state.isActive ? "pause.circle" : "play.circle")
            }
            .disabled(model.state == .starting || model.state == .stopping)

            Toggle("Freeze feed", isOn: $paused)
                .toggleStyle(.checkbox)
                .help("Stop the feed from scrolling while you read a row. The chart and statistics keep updating.")

            Spacer()

            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Open Settings")

            Button(role: .destructive) {
                showingClearConfirm = true
            } label: {
                Label("Delete history…", systemImage: "trash")
            }
            .help("Delete every recorded request from the local database")
            .confirmationDialog("Delete all request history?",
                                isPresented: $showingClearConfirm, titleVisibility: .visible) {
                Button("Delete History", role: .destructive) { telemetry.purge() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every recorded request from the local database and cannot be undone. "
                     + "Your configuration and target list are not affected.")
            }
        }
        .padding(12)
    }

    // MARK: - Status + stats

    /// One line that says whether the app is doing anything, then four numbers
    /// that all share the selected range. The old strip mixed process-lifetime
    /// totals with an instantaneous count and never said so.
    private func statusAndStats(stats: RangeStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusPill(text: routingLabel, color: routingColor, icon: "point.3.connected.trianglepath.dotted")
                if model.state.isActive {
                    StatusPill(text: model.tunnelUp ? "Tunnel up" : "Tunnel down",
                               color: model.tunnelUp ? .green : .orange,
                               icon: "arrow.left.arrow.right")
                }
                if telemetry.telemetryUnavailable {
                    StatusPill(text: "History unavailable", color: .red, icon: "exclamationmark.triangle.fill")
                } else {
                    StatusPill(text: "Recording", color: .secondary, icon: "record.circle")
                }
                if stats.blocked > 0 {
                    StatusPill(text: "\(Format.count(stats.blocked)) blocked", color: .red,
                               icon: "hand.raised.fill")
                }
                if let error = model.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                }
                Spacer()
                Text("\(timeRange.longLabel) · completed connections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                StatBox(title: "Through tunnel",
                        value: Format.count(stats.tunneled),
                        detail: stats.total > 0
                            ? String(format: "%.1f%% of %@", stats.tunnelShare * 100,
                                     Format.count(stats.total))
                            : "no traffic",
                        color: .green,
                        help: "Connections routed through your SOCKS5 tunnel in the selected range. "
                            + "One connection can carry many HTTP requests.")
                StatBox(title: "Direct",
                        value: Format.count(stats.direct),
                        detail: "everything else",
                        color: .secondary,
                        help: "Connections that went straight out, because no target or app rule "
                            + "sent them to the tunnel. Includes fallbacks while the tunnel is down.")
                StatBox(title: "Via tunnel",
                        value: Format.bytes(stats.tunnelBytes),
                        detail: "downloaded + uploaded",
                        color: .blue,
                        help: "Bytes that actually crossed the tunnel in the selected range. "
                            + "Direct traffic is not included.")
                StatBox(title: "Active",
                        value: Format.count(telemetry.liveRequests.count),
                        detail: "open now",
                        color: .orange,
                        help: "Connections open at this instant. Not part of the selected range.")
            }
        }
    }

    private var routingLabel: String {
        switch model.state {
        case .on: return "Routing on"
        case .degraded: return "Routing degraded"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .off: return "Routing off"
        }
    }

    private var routingColor: Color {
        switch model.state {
        case .on: return .green
        case .degraded: return .orange
        case .starting, .stopping: return .yellow
        case .off: return .secondary
        }
    }

    // MARK: - Chart

    private func chartSection(points: [SeriesPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chartTitle)
                        .font(.headline)
                    Text(chartSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Range", selection: $timeRange) {
                    ForEach(TimeRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 176)
                Picker("Metric", selection: $metric) {
                    ForEach(ChartMetric.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 236)
            }

            if metric == .errors, !currentFailingHosts().isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failingSummary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if points.isEmpty {
                Text("No data yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart(points)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var chartTitle: String {
        switch metric {
        case .requests: return "Connections"
        case .bytes: return "Data transferred"
        case .errors: return "Failed connections"
        }
    }

    private var chartSubtitle: String {
        let unit: String
        switch metric {
        case .requests: unit = "connections"
        case .bytes: unit = "tunnel only"
        case .errors: unit = "connect failures + 4xx/5xx"
        }
        return "\(timeRange.longLabel) · \(timeRange.bucketLabel) buckets · \(unit)"
    }

    private var failingSummary: String {
        let total = currentStats().failed
        let top = currentFailingHosts().prefix(2)
            .map { "\($0.host) (\(Format.count($0.count)))" }
            .joined(separator: ", ")
        guard !top.isEmpty else { return "\(Format.count(total)) failed connections" }
        return "\(Format.count(total)) failed connections · top: \(top)"
    }

    private struct SeriesPoint: Identifiable {
        // Deterministic id (bucket + route) so `Chart` can diff marks instead
        // of rebuilding every one on each telemetry tick.
        let id: String
        let bucket: Date
        let route: Route
        let value: Double
    }

    /// The chart data for the current metric, either bucketed in-memory (5m)
    /// or loaded from SQLite (longer ranges).
    private var series: [ChartBucket] {
        if timeRange == .m5 {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let cutoff = nowMs - Int64(timeRange.seconds) * 1000
            var events: [RequestEvent] = []
            events.reserveCapacity(2100)
            for e in telemetry.liveRequests where e.ts >= cutoff { events.append(e) }
            for e in telemetry.recentRequests.suffix(2000) where e.ts >= cutoff { events.append(e) }
            return TelemetryStore.bucketize(events, bucketMs: timeRange.bucketMs)
        }
        return dbSeries
    }

    /// Bucket bounds for the selected range, aligned to the bucket grid so the
    /// x axis is the range the picker promises — not merely the data's extent.
    private var chartWindow: (startMs: Int64, endMs: Int64) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let bucket = timeRange.bucketMs
        let end = (nowMs / bucket) * bucket
        let start = ((nowMs - Int64(timeRange.seconds) * 1000) / bucket) * bucket
        return (start, end)
    }

    /// Zero-fills every bucket in the range for the routes that appear, so a
    /// quiet period is a visible gap-to-zero rather than a silently shortened
    /// axis (and stacked areas drop to the baseline correctly).
    private var seriesPoints: [SeriesPoint] {
        let buckets = series
        guard !buckets.isEmpty else { return [] }
        // Bytes are tunnel-only: including direct traffic buries the number the
        // user actually pays for (and the strip above already says "Via tunnel").
        let routes: Set<Route> = metric == .bytes ? [.tunnel] : Set(buckets.map(\.route))
        var byKey: [String: ChartBucket] = [:]
        for b in buckets { byKey["\(b.bucketMs)-\(b.route.rawValue)"] = b }

        var points: [SeriesPoint] = []
        points.reserveCapacity(Int(timeRange.seconds) * 1000 / Int(timeRange.bucketMs) * routes.count)
        let window = chartWindow
        var t = window.startMs
        while t <= window.endMs {
            for route in routes {
                let bucket = byKey["\(t)-\(route.rawValue)"]
                let value: Double
                switch metric {
                case .requests: value = Double(bucket?.count ?? 0)
                case .bytes: value = Double((bucket?.bytesIn ?? 0) + (bucket?.bytesOut ?? 0))
                case .errors: value = Double(bucket?.errors ?? 0)
                }
                points.append(SeriesPoint(id: "\(t)-\(route.rawValue)",
                                          bucket: Date(timeIntervalSince1970: Double(t) / 1000),
                                          route: route, value: value))
            }
            t += timeRange.bucketMs
        }
        return points
    }

    private var presentRoutes: [Route] {
        let routes: Set<Route> = metric == .bytes ? [.tunnel] : Set(series.map(\.route))
        return routes.sorted { $0.rawValue < $1.rawValue }
    }

    private func routeColor(_ route: Route) -> Color {
        switch route {
        case .tunnel: return .green
        case .direct: return .blue
        case .block: return .red
        }
    }

    private func chart(_ points: [SeriesPoint]) -> some View {
        let window = chartWindow
        let start = Date(timeIntervalSince1970: Double(window.startMs) / 1000)
        let end = Date(timeIntervalSince1970: Double(window.endMs) / 1000)
        return Chart(points) { point in
            if metric == .bytes {
                AreaMark(
                    x: .value("Time", point.bucket),
                    y: .value("Value", point.value),
                    stacking: .standard
                )
                .foregroundStyle(by: .value("Route", point.route.rawValue))
            } else {
                BarMark(
                    x: .value("Time", point.bucket),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(by: .value("Route", point.route.rawValue))
            }
        }
        .chartForegroundStyleScale(
            domain: presentRoutes.map(\.rawValue),
            range: presentRoutes.map(routeColor)
        )
        .chartXScale(domain: start...end)
        .chartXAxis {
            AxisMarks(values: .stride(by: timeRange.axisComponent, count: timeRange.axisCount)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: timeRange == .d7
                    ? .dateTime.month(.defaultDigits).day()
                    : .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                if metric == .bytes {
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(Format.bytes(Int64(v))) }
                    }
                } else {
                    AxisValueLabel()
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geo[plot].origin.x
                            guard x >= 0, x <= geo[plot].width else { return }
                            guard let date = proxy.value(atX: x, as: Date.self) else { return }
                            let ms = Int64(date.timeIntervalSince1970 * 1000)
                            let bucket = (ms / timeRange.bucketMs) * timeRange.bucketMs
                            if hoverBucketMs != bucket { hoverBucketMs = bucket }
                        case .ended:
                            if hoverBucketMs != nil { hoverBucketMs = nil }
                        }
                    }
            }
        }
        .overlay(alignment: .topTrailing) { hoverReadout(points) }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func hoverReadout(_ points: [SeriesPoint]) -> some View {
        if let bucket = hoverBucketMs {
            let ms = Int64(Date(timeIntervalSince1970: Double(bucket) / 1000).timeIntervalSince1970 * 1000)
            let rows = points
                .filter { Int64($0.bucket.timeIntervalSince1970 * 1000) == ms }
                .filter { $0.value > 0 }
                .sorted { $0.value > $1.value }
            VStack(alignment: .leading, spacing: 3) {
                Text(Format.time(bucket))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if rows.isEmpty {
                    Text("no data").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    ForEach(rows) { row in
                        HStack(spacing: 5) {
                            Circle().fill(routeColor(row.route)).frame(width: 6, height: 6)
                            Text(row.route.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(metric == .bytes ? Format.bytes(Int64(row.value)) : Format.count(Int(row.value)))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor).opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .padding(6)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Top hosts / apps / targets

    private func topHostsSection(items: [TopItem], targets: [TargetHealth],
                                 activity: [HostActivity]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(topTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(topSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Picker("", selection: $topMetric) {
                ForEach(TopMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            if topMetric == .targets {
                targetsPanel(targets: targets, activity: activity)
            } else if items.isEmpty {
                Text("No data yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(Array(items.prefix(7).enumerated()), id: \.offset) { _, item in
                    topBar(item: item, ratio: ratio(item.count, in: items))
                }
                Spacer(minLength: 2)
                if let footer = topFooter(items) {
                    Text(footer).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var topTitle: String {
        switch topMetric {
        case .hosts: return "Top tunneled hosts"
        case .apps: return "Top tunneled apps"
        case .targets: return "Targets"
        }
    }

    private var topSubtitle: String {
        topMetric == .targets ? "last 24 h" : timeRange.longLabel.lowercased()
    }

    private struct TopItem {
        let label: String
        let count: Int
        let bundleId: String?
    }

    private var topItems: [TopItem] {
        switch topMetric {
        case .hosts:
            return topHosts.map { TopItem(label: $0.host, count: $0.count, bundleId: nil) }
        case .apps:
            return topApps.map { TopItem(label: $0.app, count: $0.count, bundleId: $0.bundle) }
        case .targets:
            return []
        }
    }

    private var topHosts: [(host: String, count: Int)] {
        timeRange == .m5 ? inMemoryTopTunneledHosts : dbTopHosts
    }

    private var topApps: [(app: String, bundle: String?, count: Int)] {
        timeRange == .m5 ? inMemoryTopApps : dbTopApps
    }

    /// "Top 7 are 84% of tunneled connections" — the denominator the bars lack.
    private func topFooter(_ items: [TopItem]) -> String? {
        let tunneled = currentStats().tunneled
        guard tunneled > 0 else { return nil }
        let shown = items.prefix(7).reduce(0) { $0 + $1.count }
        let pct = Int((Double(shown) / Double(tunneled) * 100).rounded())
        return "Top \(min(items.count, 7)) = \(pct)% of \(Format.count(tunneled)) tunneled"
    }

    private func ratio(_ count: Int, in items: [TopItem]) -> CGFloat {
        let max = items.map(\.count).max() ?? 1
        guard max > 0 else { return 0 }
        return CGFloat(count) / CGFloat(max)
    }

    private func topBar(item: TopItem, ratio: CGFloat) -> some View {
        HStack(spacing: 8) {
            if topMetric == .apps {
                appIcon(item.bundleId)
                    .frame(width: 16, height: 16)
            }
            TruncatableText(item.label)
                .frame(width: topMetric == .apps ? 128 : 146, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.green.opacity(0.14))
                    Capsule()
                        .fill(Color.green.opacity(0.6))
                        .frame(width: max(2, geo.size.width * ratio))
                }
            }
            .frame(height: 8)
            Text(Format.count(item.count))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .font(.callout)
    }

    /// Per-target health: the only view that makes the target list verifiable.
    /// `0` is the interesting value — it means the rule has never carried
    /// traffic in this range.
    @ViewBuilder
    private func targetsPanel(targets: [TargetHealth], activity: [HostActivity]) -> some View {
        if targets.isEmpty {
            Text("No targets enabled")
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            ForEach(Array(targets.prefix(7).enumerated()), id: \.offset) { _, target in
                HStack(spacing: 7) {
                    Circle()
                        .fill(target.used ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                    TruncatableText(target.pattern)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if target.used {
                        Text(Format.count(target.connections))
                            .font(.caption.monospacedDigit())
                        Text(lastSeen(target.latestTs))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .trailing)
                    } else {
                        Text("no traffic")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .opacity(target.enabled ? 1 : 0.45)
            }
            Spacer(minLength: 4)
            VStack(alignment: .leading, spacing: 3) {
                let used = targets.filter(\.used).count
                Text("\(used) of \(targets.count) carried traffic")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let appRules = appRuleTunnelSummary(activity: activity) {
                    Text(appRules)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let gap = targetGap(activity: activity) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(gap)
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("These hosts end with one of your target names but need a wildcard rule "
                          + "(for example *.example.com) to be routed.")
                }
            }
        }
    }

    private func lastSeen(_ ts: Int64) -> String {
        guard ts > 0 else { return "—" }
        let seconds = max(0, (Int64(Date().timeIntervalSince1970 * 1000) - ts) / 1000)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    /// "App rules: 43 connections" — tunnels that a target did not cause.
    private func appRuleTunnelSummary(activity: [HostActivity]) -> String? {
        guard model.config.apps.enabled else { return nil }
        let count = activity.reduce(0) { $0 + ($1.tunneled > 0 && matchingTarget(for: $1.host) == nil ? $1.tunneled : 0) }
        guard count > 0 else { return nil }
        return "App rules: \(Format.count(count)) connections"
    }

    /// The counter-evidence a routing tool needs: hosts that went direct even
    /// though their parent domain is an exact target — i.e. the user forgot the
    /// wildcard (`example.com` does not cover `api.example.com`).
    private func targetGap(activity: [HostActivity]) -> String? {
        var total = 0
        var example: String?
        let exactTargets = model.config.targets
            .filter { $0.enabled && !RoutingEngine.isWildcard($0.pattern) }
            .map { RoutingEngine.normalizePattern($0.pattern) }
        for host in activity where host.total > host.tunneled {
            let normalized = RoutingEngine.normalize(host.host)
            guard matchingTarget(for: normalized) == nil else { continue }
            for pattern in exactTargets where normalized.hasSuffix("." + pattern) {
                total += host.total - host.tunneled
                if example == nil { example = host.host }
                break
            }
        }
        guard total > 0, let example else { return nil }
        return "\(Format.count(total)) direct under \(example) — add *."
    }

    private func matchingTarget(for host: String) -> TargetRule? {
        let normalized = RoutingEngine.normalize(host)
        guard !normalized.isEmpty else { return nil }
        return model.config.targets.first {
            $0.enabled && RoutingEngine.matches(pattern: $0.pattern, host: normalized)
        }
    }

    @ViewBuilder private func appIcon(_ bundleId: String?) -> some View {
        if let image = AppIcon.image(bundleId: bundleId, path: nil) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.tertiary)
        }
    }

    /// In-memory host counts for the 5 m range, honouring the selected window
    /// (the old code always used one hour under the "5m" tab).
    private var inMemoryTopTunneledHosts: [(host: String, count: Int)] {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(timeRange.seconds) * 1000
        var counts: [String: Int] = [:]
        for event in telemetry.liveRequests where event.route == .tunnel {
            counts[event.host, default: 0] += 1
        }
        for event in telemetry.recentRequests.reversed() where event.ts >= cutoff {
            if event.route == .tunnel { counts[event.host, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(7).map { (host: $0.key, count: $0.value) }
    }

    private var inMemoryTopApps: [(app: String, bundle: String?, count: Int)] {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(timeRange.seconds) * 1000
        var counts: [String: (name: String, bundle: String?, count: Int)] = [:]
        func add(_ event: RequestEvent) {
            guard event.route == .tunnel, let app = event.app, !app.isEmpty else { return }
            let bundle = (event.appBundle?.isEmpty == false) ? event.appBundle : nil
            let key = bundle ?? app
            var entry = counts[key] ?? (app, bundle, 0)
            entry.count += 1
            if entry.bundle == nil { entry.bundle = bundle }
            counts[key] = entry
        }
        for event in telemetry.liveRequests { add(event) }
        for event in telemetry.recentRequests.reversed() where event.ts >= cutoff { add(event) }
        return counts.sorted { $0.value.count > $1.value.count }.prefix(7)
            .map { (app: $0.value.name, bundle: $0.value.bundle, count: $0.value.count) }
    }

    // MARK: - Range-scoped data

    private func currentStats() -> RangeStats {
        if timeRange != .m5 { return dbStats }
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(timeRange.seconds) * 1000
        var stats = RangeStats()
        func add(_ e: RequestEvent) {
            guard e.ts >= cutoff else { return }
            switch e.route {
            case .tunnel:
                stats.tunneled += 1
                stats.tunnelBytes += e.bytesIn + e.bytesOut
            case .direct: stats.direct += 1
            case .block: stats.blocked += 1
            }
            if e.status >= 400 || e.error != nil { stats.failed += 1 }
        }
        for e in telemetry.liveRequests { add(e) }
        for e in telemetry.recentRequests.reversed() where e.ts >= cutoff { add(e) }
        return stats
    }

    /// Target health is always a 24-hour view (labelled in the card): a 5-minute
    /// window would report almost every target as idle. SQLite is the source;
    /// the in-memory buffer is a fallback when the DB is unavailable or has not
    /// been flushed yet, so the panel is never blank for no reason.
    private func currentActivity() -> [HostActivity] {
        dbActivity24h.isEmpty ? memoryActivity24h() : dbActivity24h
    }

    private func memoryActivity24h() -> [HostActivity] {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 86_400_000
        struct Acc { var total = 0; var tunneled = 0; var latest: Int64 = 0; var bytes: Int64 = 0 }
        var byHost: [String: Acc] = [:]
        func add(_ e: RequestEvent) {
            guard e.ts >= cutoff else { return }
            var acc = byHost[e.host] ?? Acc()
            acc.total += 1
            if e.route == .tunnel { acc.tunneled += 1 }
            acc.latest = max(acc.latest, e.ts)
            acc.bytes += e.bytesIn + e.bytesOut
            byHost[e.host] = acc
        }
        for e in telemetry.liveRequests { add(e) }
        for e in telemetry.recentRequests { add(e) }
        return byHost.map { HostActivity(host: $0.key, total: $0.value.total,
                                         tunneled: $0.value.tunneled,
                                         latestTs: $0.value.latest, bytes: $0.value.bytes) }
            .sorted { $0.total > $1.total }
    }

    private func currentFailingHosts() -> [(host: String, count: Int)] {
        if timeRange != .m5 { return dbFailingHosts }
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(timeRange.seconds) * 1000
        var counts: [String: Int] = [:]
        func add(_ e: RequestEvent) {
            guard e.ts >= cutoff, e.status >= 400 || e.error != nil else { return }
            counts[e.host, default: 0] += 1
        }
        for e in telemetry.liveRequests { add(e) }
        for e in telemetry.recentRequests.reversed() where e.ts >= cutoff { add(e) }
        return counts.sorted { $0.value > $1.value }.prefix(3).map { (host: $0.key, count: $0.value) }
    }

    /// Joins host activity to the *current* target list. This is a "would this
    /// host match today" view, not a historical decision log — the same honesty
    /// rule the inspector's Reason card follows.
    private func currentTargets(activity: [HostActivity]) -> [TargetHealth] {
        var byPattern: [String: (count: Int, latest: Int64)] = [:]
        for host in activity where host.tunneled > 0 {
            guard let rule = matchingTarget(for: host.host) else { continue }
            var entry = byPattern[rule.pattern] ?? (0, 0)
            entry.count += host.tunneled
            entry.latest = max(entry.latest, host.latestTs)
            byPattern[rule.pattern] = entry
        }
        let health = model.config.targets.map { rule -> TargetHealth in
            let entry = byPattern[rule.pattern] ?? (0, 0)
            return TargetHealth(id: rule.id, pattern: rule.pattern, enabled: rule.enabled,
                                connections: entry.count, latestTs: entry.latest)
        }
        return health.sorted {
            if $0.used != $1.used { return $0.used }
            if $0.connections != $1.connections { return $0.connections > $1.connections }
            return $0.pattern.localizedCaseInsensitiveCompare($1.pattern) == .orderedAscending
        }
    }

    // MARK: - Feed + detail

    private func feedArea(rows: [FeedRow], appOptions: [AppFilterOption], buffered: Int) -> some View {
        HSplitView {
            VStack(spacing: 0) {
                feedHeader(appOptions: appOptions, buffered: buffered, shown: rows.count)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                if rows.isEmpty {
                    Text(emptyFeedMessage(buffered: buffered))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FeedTable(rows: rows, selectedID: $selectedID,
                              sortKey: $sortKey, sortAscending: $sortAscending)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity)

            if let event = selectedEvent {
                RequestDetailView(event: event) { selectedID = nil }
                    .frame(minWidth: 260, idealWidth: 360, maxWidth: 640)
            }
        }
    }

    private func emptyFeedMessage(buffered: Int) -> String {
        if routeFilter != "All" || !hostFilter.isEmpty || appFilterKey != nil {
            return "No requests match these filters in the last \(buffered) buffered connections."
        }
        return telemetry.telemetryUnavailable
            ? "History is unavailable — check Settings → Monitoring."
            : "No requests yet. Turn routing on and use the network."
    }

    private var selectedEvent: RequestEvent? {
        guard let id = selectedID else { return nil }
        if let e = telemetry.liveRequests.first(where: { $0.id == id }) { return e }
        if let e = telemetry.recentRequests.first(where: { $0.id == id }) { return e }
        return nil
    }

    private func feedHeader(appOptions: [AppFilterOption], buffered: Int, shown: Int) -> some View {
        HStack(spacing: 10) {
            Text("Request feed")
                .font(.headline)
            Picker("Route", selection: $routeFilter) {
                ForEach(routeOptions, id: \.self) { Text($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            TextField("Filter host…", text: $hostFilter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            if !appOptions.isEmpty {
                AppFilterMenu(options: appOptions, selection: appFilterSelection(options: appOptions))
            }
            if paused {
                Text("frozen")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text("\(Format.count(telemetry.liveRequests.count)) live · showing \(shown) of \(buffered) buffered")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("The feed keeps the newest 5,000 connections in memory. Filters and sorting "
                      + "search all of them; the table shows the first 250 matches.")
        }
        .controlSize(.regular)
        .frame(height: 24)
    }

    /// Live + every buffered completed row, before any filter. Filters apply to
    /// the whole buffer (not just the visible 250), so "no results" means "not
    /// in the last 5,000 connections" rather than "not in the last 20 minutes".
    private func baseFeedRows() -> [FeedRow] {
        var rows: [FeedRow] = []
        rows.reserveCapacity(telemetry.recentRequests.count + telemetry.liveRequests.count)
        for event in telemetry.liveRequests {
            rows.append(FeedRow(event: event, isLive: true))
        }
        for event in telemetry.recentRequests {
            rows.append(FeedRow(event: event, isLive: false))
        }
        // Order is applied by `sortedFeedRows` after filtering, so the buffer
        // does not need to be sorted twice per tick.
        return rows
    }

    private func computeFeedRows(from baseRows: [FeedRow], appKey: String?) -> [FeedRow] {
        var rows = baseRows
        switch routeFilter {
        case "Tunneled": rows = rows.filter { $0.event.route == .tunnel }
        case "Direct": rows = rows.filter { $0.event.route == .direct }
        case "Blocked": rows = rows.filter { $0.event.route == .block }
        default: break
        }
        if !hostFilter.isEmpty {
            rows = rows.filter { $0.event.host.localizedCaseInsensitiveContains(hostFilter) }
        }
        if let appKey {
            rows = rows.filter { ($0.event.appBundle ?? $0.event.app ?? "") == appKey }
        }
        return Array(sortedFeedRows(rows).prefix(250))
    }

    /// Column sorting, applied to the filtered buffer *before* the 250-row cut
    /// so "largest / slowest" is a real answer even when the match set is large.
    private func sortedFeedRows(_ rows: [FeedRow]) -> [FeedRow] {
        func compare(_ a: FeedRow, _ b: FeedRow) -> Int {
            let ea = a.event, eb = b.event
            switch sortKey {
            case "route": return ea.route.rawValue.compare(eb.route.rawValue).rawValue
            case "host": return ea.host.localizedCaseInsensitiveCompare(eb.host).rawValue
            case "app":
                return (ea.app ?? "").localizedCaseInsensitiveCompare(eb.app ?? "").rawValue
            case "status": return ea.status == eb.status ? 0 : (ea.status < eb.status ? -1 : 1)
            case "bytes":
                let va = ea.bytesIn + ea.bytesOut, vb = eb.bytesIn + eb.bytesOut
                return va == vb ? 0 : (va < vb ? -1 : 1)
            case "connect":
                return ea.connectMs == eb.connectMs ? 0 : (ea.connectMs < eb.connectMs ? -1 : 1)
            case "open":
                return ea.durationMs == eb.durationMs ? 0 : (ea.durationMs < eb.durationMs ? -1 : 1)
            case "error":
                return (ea.error ?? "").localizedCaseInsensitiveCompare(eb.error ?? "").rawValue
            default:
                return ea.ts == eb.ts ? 0 : (ea.ts < eb.ts ? -1 : 1)
            }
        }
        return rows.sorted { a, b in
            let result = compare(a, b)
            if result != 0 { return sortAscending ? result < 0 : result > 0 }
            // Stable, deterministic tie-break: newest first.
            return a.event.ts > b.event.ts
        }
    }

    /// The app filter only ever refers to an app that is still in the feed.
    private func validatedAppFilterKey(_ options: [AppFilterOption]) -> String? {
        guard let appFilterKey, options.contains(where: { $0.id == appFilterKey }) else { return nil }
        return appFilterKey
    }

    /// The menu snapshots its options when the popover opens, so the row picked
    /// may have aged out of the live feed meanwhile. Accept only live ids;
    /// anything else resets to "All apps" instead of trapping the feed (UI-07).
    private func appFilterSelection(options: [AppFilterOption]) -> Binding<String?> {
        Binding(
            get: { validatedAppFilterKey(options) },
            set: { newValue in
                if let newValue, !options.contains(where: { $0.id == newValue }) {
                    appFilterKey = nil
                } else {
                    appFilterKey = newValue
                }
            }
        )
    }

    /// Apps present in the current feed, most-requested first (then A–Z), with
    /// their bundle id so the menu can show icons. Derived from the same rows the
    /// feed shows, so only apps actually in the feed are offered.
    private func appFilterOptions(from baseRows: [FeedRow]) -> [AppFilterOption] {
        var counts: [String: (name: String, bundle: String?, count: Int)] = [:]
        for row in baseRows {
            let event = row.event
            let bundle = (event.appBundle?.isEmpty == false) ? event.appBundle : nil
            guard let key = bundle ?? event.app, !key.isEmpty else { continue }
            var entry = counts[key] ?? (event.app ?? key, bundle, 0)
            entry.count += 1
            if entry.bundle == nil { entry.bundle = bundle }
            counts[key] = entry
        }
        return counts
            .map { AppFilterOption(id: $0.key, name: $0.value.name, bundleId: $0.value.bundle, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    // MARK: - Long-range loading

    /// Loads the 24 h host activity behind the Targets tab. Slow cadence: the
    /// panel answers "did this target carry traffic today", not "right now".
    private func loadTargets24h(force: Bool = false) {
        guard windowVisible else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if !force, now - lastTargetsLoad < 15_000 { return }
        lastTargetsLoad = now
        telemetry.hostActivity(rangeSeconds: 86_400) { activity in
            // Always take the result: a visibility flip while the query was in
            // flight must not silently leave the panel empty for 15 s.
            dbActivity24h = activity
        }
    }

    private func clearLongRangeData() {
        dbSeries = []
        dbTopHosts = []
        dbTopApps = []
        dbStats = RangeStats()
        dbActivity24h = []
        dbFailingHosts = []
    }

    /// Called by the 2 s timer, and forced on a range/top-metric change or when
    /// the window becomes visible again (UI-08). The timer itself is cheap; the
    /// database pair runs at the range's cadence, at most one pair at a time.
    private func refreshLongRange(force: Bool = false) {
        // Target health is a 24 h view independent of the chart range; refresh
        // it only while that tab is visible.
        if topMetric == .targets { loadTargets24h(force: force) }
        // No DB work while nothing is on screen; `.onChange(of: windowVisible)`
        // does one forced load when the window comes back (UI-08).
        guard windowVisible else { return }
        // The 5 m chart is in-memory. A forced switch still invalidates an
        // outstanding long-range pair so its completion cannot repopulate
        // `dbSeries` behind the in-memory chart.
        guard let cadence = timeRange.queryCadence else {
            if force { dbGeneration &+= 1 }
            dbRefreshPending = false
            return
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if force {
            // Any completion already in flight was requested for the old range
            // and/or old top metric (UI-06).
            dbGeneration &+= 1
        } else {
            guard now - lastDBLoad >= Int64(cadence * 1000) else { return }
        }

        // Only one chart + top pair may be outstanding. A forced change asks
        // for a fresh pair as soon as the current one finishes; a plain tick
        // just rides the query that is already running.
        guard dbPendingCount == 0 else {
            if force { dbRefreshPending = true }
            return
        }
        beginLongRangeLoad(now: now)
    }

    private func beginLongRangeLoad(now: Int64) {
        guard windowVisible, timeRange.queryCadence != nil else {
            dbRefreshPending = false
            return
        }
        dbRefreshPending = false
        dbGeneration &+= 1
        let generation = dbGeneration
        let range = timeRange.seconds
        let wantsApps = topMetric == .apps

        lastDBLoad = now
        dbPendingCount = 3
        dbLoading = true

        telemetry.chartSeries(rangeSeconds: range, bucketMs: timeRange.bucketMs) { series in
            if generation == dbGeneration { dbSeries = series }
            longRangeQueryCompleted()
        }
        // The strip and the chart share one range, so they are loaded together
        // and can never show different windows.
        telemetry.rangeStats(rangeSeconds: range) { stats in
            if generation == dbGeneration { dbStats = stats }
            longRangeQueryCompleted()
        }
        telemetry.topFailingHosts(rangeSeconds: range) { hosts in
            if generation == dbGeneration { dbFailingHosts = hosts }
            longRangeQueryCompleted()
        }
        if wantsApps {
            telemetry.topApps(rangeSeconds: range, limit: 7) { apps in
                if generation == dbGeneration { dbTopApps = apps }
            }
        } else if topMetric == .hosts {
            telemetry.topHosts(rangeSeconds: range, limit: 7) { hosts in
                if generation == dbGeneration { dbTopHosts = hosts }
            }
        }
    }

    /// Completions arrive on main. Both halves must report back before the pair
    /// is considered done, even when their results were stale and dropped.
    private func longRangeQueryCompleted() {
        dbPendingCount = max(0, dbPendingCount - 1)
        guard dbPendingCount == 0 else { return }
        dbLoading = false
        if dbRefreshPending {
            dbRefreshPending = false
            beginLongRangeLoad(now: Int64(Date().timeIntervalSince1970 * 1000))
        }
    }
}

/// Drives `DashboardView.windowVisible` from the actual hosting window. A
/// window that is minimized, fully occluded, or whose app is hidden is "not
/// visible"; the dashboard then keeps a cheap placeholder instead of deriving
/// the feed/charts from telemetry on every 10 Hz tick.
///
/// Window notifications are filtered to the hosting window so another window
/// (Settings, onboarding) cannot make the dashboard think it is visible.
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> WindowVisibilityObserverView {
        let view = WindowVisibilityObserverView()
        view.onVisibilityChange = publish
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityObserverView, context: Context) {
        nsView.onVisibilityChange = publish
    }

    private func publish(_ visible: Bool) {
        DispatchQueue.main.async {
            if isVisible != visible { isVisible = visible }
        }
    }
}

private final class WindowVisibilityObserverView: NSView {
    var onVisibilityChange: ((Bool) -> Void)?

    private weak var observedWindow: NSWindow?
    private var lastReported: Bool?
    private var hasBeenVisible = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observe(window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func observe(_ window: NSWindow?) {
        NotificationCenter.default.removeObserver(self)
        observedWindow = window
        guard let window else { return }

        let center = NotificationCenter.default
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didExposeNotification,
            NSWindow.didBecomeKeyNotification,
        ] {
            center.addObserver(self, selector: #selector(stateChanged), name: name, object: window)
        }
        // Hiding the app does not miniaturize the window, so watch app state too.
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(stateChanged), name: name, object: nil)
        }

        // The hosting window may not be on screen yet when the view attaches;
        // re-check once after the current runloop turn.
        report()
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    @objc private func stateChanged(_ notification: Notification) {
        report()
    }

    private func report() {
        guard let window = observedWindow else { return }
        let visible = !NSApp.isHidden
            && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        if visible {
            hasBeenVisible = true
        } else if !hasBeenVisible {
            // The view attaches before the window is ordered on screen; keep
            // the default (visible) until the window has actually appeared.
            return
        }
        guard visible != lastReported else { return }
        lastReported = visible
        onVisibilityChange?(visible)
    }
}

struct StatBox: View {
    let title: String
    let value: String
    var detail: String? = nil
    let color: Color
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .help(help ?? title)
    }
}

/// Small state chip for the routing/tunnel/recording line above the stats.
struct StatusPill: View {
    let text: String
    let color: Color
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(color.opacity(0.12))
        )
        .overlay(Capsule().stroke(color.opacity(0.28)))
    }
}
