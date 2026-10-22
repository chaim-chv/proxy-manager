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
        case .requests: return "Requests"
        case .bytes: return "Bytes"
        case .errors: return "Errors"
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
    @State private var timeRange: TimeRange = .m5
    @State private var metric: ChartMetric = .requests
    @State private var topMetric: TopMetric = .hosts
    @State private var selectedID: UUID?
    @State private var windowVisible = true

    // Long-range chart/top-hosts data, loaded from SQLite. The 2 s timer below
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

    private let routeOptions = ["All", "Tunneled", "Direct", "Blocked"]
    private let seriesTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private enum TopMetric: String, CaseIterable, Identifiable {
        case hosts = "Hosts"
        case apps = "Apps"
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
            guard visible else { return }
            reconcileSelection()
            refreshLongRange(force: true)
        }
        .onChange(of: telemetry.liveRequests.count) { _, _ in reconcileSelection() }
        .onChange(of: telemetry.recentRequests.count) { _, _ in reconcileSelection() }
        .onReceive(seriesTimer) { _ in refreshLongRange() }
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        #if SCREENSHOT_MODE
        .onAppear {
            guard DemoMode.isEnabled, DemoMode.showsDetailPanel, selectedID == nil else { return }
            let event = telemetry.recentRequests.last { $0.route == .tunnel && !$0.path.isEmpty }
                ?? telemetry.recentRequests.last { $0.route == .tunnel }
            selectedID = event?.id
        }
        #endif
    }

    /// The full dashboard. Only built while the hosting window is on screen:
    /// every value here walks the live/recent event arrays or the chart data, so
    /// an occluded/minimized/hidden window skips all of it (UI-08).
    private func loadedContent() -> some View {
        let baseRows = baseFeedRows()
        let appOptions = appFilterOptions(from: baseRows)
        let appOptionIds = appOptions.map(\.id)
        let appKey = validatedAppFilterKey(appOptions)
        // Pause freezes the unfiltered base rows, not the filtered result, so the
        // route/host/app filters keep working on the frozen data (UI-15).
        let rows = computeFeedRows(from: paused ? pausedSnapshot : baseRows, appKey: appKey)
        let points = seriesPoints
        let tops = topItems

        return VStack(spacing: 0) {
            header
            Divider()
            statsStrip
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            HStack(alignment: .top, spacing: 16) {
                chartSection(points: points)
                topHostsSection(items: tops)
                    .frame(width: 260)
            }
            .padding(16)
            .frame(height: 260)
            Divider()
            feedArea(rows: rows, appOptions: appOptions)
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

            Toggle("Pause", isOn: $paused)
                .toggleStyle(.checkbox)

            Spacer()

            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Open Settings")

            Button(role: .destructive) {
                telemetry.purge()
            } label: {
                Label("Clear", systemImage: "trash")
            }
        }
        .padding(12)
    }

    // MARK: - Stats

    private var statsStrip: some View {
        HStack(spacing: 12) {
            StatBox(title: "Tunneled", value: "\(telemetry.stats.tunneledRequests)", color: .green)
            StatBox(title: "Direct", value: "\(telemetry.stats.directRequests)", color: .gray)
            StatBox(title: "Blocked", value: "\(telemetry.stats.blockedRequests)", color: .red)
            StatBox(title: "Bytes", value: Format.bytes(telemetry.stats.bytesIn + telemetry.stats.bytesOut), color: .blue)
            StatBox(title: "Active", value: "\(telemetry.stats.activeConnections)", color: .orange)
        }
    }

    // MARK: - Chart

    private func chartSection(points: [SeriesPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chartTitle)
                    .font(.headline)
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
                .frame(width: 210)
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
        case .requests: return "Request rate"
        case .bytes: return "Data transferred"
        case .errors: return "Errors"
        }
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

    private var seriesPoints: [SeriesPoint] {
        series.map { b in
            let value: Double
            switch metric {
            case .requests: value = Double(b.count)
            case .bytes: value = Double(b.bytesIn + b.bytesOut)
            case .errors: value = Double(b.errors)
            }
            return SeriesPoint(
                id: "\(b.bucketMs)-\(b.route.rawValue)",
                bucket: Date(timeIntervalSince1970: Double(b.bucketMs) / 1000),
                route: b.route,
                value: value
            )
        }
    }

    private func chart(_ points: [SeriesPoint]) -> some View {
        Chart(points) { point in
            if metric == .bytes {
                AreaMark(
                    x: .value("Time", point.bucket),
                    y: .value("Value", point.value)
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
        .chartForegroundStyleScale([
            "TUNNEL": Color.green,
            "DIRECT": Color.blue,
            "BLOCK": Color.red,
        ])
        .chartXAxis {
            AxisMarks(values: .stride(by: timeRange.axisComponent, count: timeRange.axisCount)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: timeRange == .d7
                    ? .dateTime.day()
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
        .frame(maxHeight: .infinity)
    }

    // MARK: - Top hosts

    private func topHostsSection(items: [TopItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(topMetric == .hosts ? "Top tunneled hosts" : "Top apps")
                    .font(.headline)
                Spacer()
                Picker("", selection: $topMetric) {
                    ForEach(TopMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
            if items.isEmpty {
                Text("No data yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    topBar(item: item, ratio: ratio(item.count, in: items))
                }
                Spacer()
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private struct TopItem {
        let label: String
        let count: Int
        let bundleId: String?
    }

    private var topItems: [TopItem] {
        if topMetric == .hosts {
            return topHosts.map { TopItem(label: $0.host, count: $0.count, bundleId: nil) }
        }
        return topApps.map { TopItem(label: $0.app, count: $0.count, bundleId: $0.bundle) }
    }

    private var topHosts: [(host: String, count: Int)] {
        if timeRange == .m5 { return inMemoryTopTunneledHosts }
        return dbTopHosts
    }

    private var topApps: [(app: String, bundle: String?, count: Int)] {
        if timeRange == .m5 { return inMemoryTopApps }
        return dbTopApps
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
                .frame(width: topMetric == .apps ? 102 : 118, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.green.opacity(0.14))
                    Capsule()
                        .fill(Color.green.opacity(0.6))
                        .frame(width: max(2, geo.size.width * ratio))
                }
            }
            .frame(height: 8)
            Text("\(item.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .font(.callout)
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

    private var inMemoryTopTunneledHosts: [(host: String, count: Int)] {
        let hourAgo = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        var counts: [String: Int] = [:]
        var scanned = 0
        for event in telemetry.liveRequests {
            if event.route == .tunnel { counts[event.host, default: 0] += 1 }
            scanned += 1
            if scanned > 500 { break }
        }
        scanned = 0
        for event in telemetry.recentRequests.reversed() where event.ts >= hourAgo {
            if event.route == .tunnel { counts[event.host, default: 0] += 1 }
            scanned += 1
            if scanned > 3000 { break }
        }
        return counts.sorted { $0.value > $1.value }.prefix(6).map { (host: $0.key, count: $0.value) }
    }

    private var inMemoryTopApps: [(app: String, bundle: String?, count: Int)] {
        let hourAgo = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        var counts: [String: (name: String, bundle: String?, count: Int)] = [:]
        func add(_ event: RequestEvent) {
            guard let app = event.app, !app.isEmpty else { return }
            let bundle = (event.appBundle?.isEmpty == false) ? event.appBundle : nil
            let key = bundle ?? app
            var entry = counts[key] ?? (app, bundle, 0)
            entry.count += 1
            if entry.bundle == nil { entry.bundle = bundle }
            counts[key] = entry
        }
        var scanned = 0
        for event in telemetry.liveRequests {
            add(event)
            scanned += 1
            if scanned > 500 { break }
        }
        scanned = 0
        for event in telemetry.recentRequests.reversed() where event.ts >= hourAgo {
            add(event)
            scanned += 1
            if scanned > 3000 { break }
        }
        return counts.sorted { $0.value.count > $1.value.count }.prefix(6)
            .map { (app: $0.value.name, bundle: $0.value.bundle, count: $0.value.count) }
    }

    // MARK: - Feed + detail

    private func feedArea(rows: [FeedRow], appOptions: [AppFilterOption]) -> some View {
        HSplitView {
            VStack(spacing: 0) {
                feedHeader(rows: rows, appOptions: appOptions)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                if rows.isEmpty {
                    Text("No requests yet")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FeedTable(rows: rows, selectedID: $selectedID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity)

            if let event = selectedEvent {
                RequestDetailView(event: event) { selectedID = nil }
                    .frame(minWidth: 240, idealWidth: 320, maxWidth: 640)
            }
        }
    }

    private var selectedEvent: RequestEvent? {
        guard let id = selectedID else { return nil }
        if let e = telemetry.liveRequests.first(where: { $0.id == id }) { return e }
        if let e = telemetry.recentRequests.first(where: { $0.id == id }) { return e }
        return nil
    }

    private func feedHeader(rows _: [FeedRow], appOptions: [AppFilterOption]) -> some View {
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
                .frame(width: 170)
            if !appOptions.isEmpty {
                AppFilterMenu(options: appOptions, selection: appFilterSelection(options: appOptions))
            }
            if paused {
                Text("paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(telemetry.liveRequests.count) live · \(telemetry.recentRequests.count) completed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.regular)
        .frame(height: 24)
    }

    /// Live + recent rows before any filter, stable-sorted. Shared by the feed
    /// and the app-filter options so the filter offers exactly what's in the feed.
    private func baseFeedRows() -> [FeedRow] {
        var rows: [FeedRow] = []
        rows.reserveCapacity(320)
        for event in telemetry.liveRequests {
            rows.append(FeedRow(event: event, isLive: true))
        }
        for event in telemetry.recentRequests.suffix(250).reversed() {
            rows.append(FeedRow(event: event, isLive: false))
        }
        return rows.enumerated()
            .sorted { a, b in
                if a.element.event.ts != b.element.event.ts { return a.element.event.ts > b.element.event.ts }
                return a.offset < b.offset
            }
            .map(\.element)
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
        return Array(rows.prefix(250))
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

    private func clearLongRangeData() {
        dbSeries = []
        dbTopHosts = []
        dbTopApps = []
    }

    /// Called by the 2 s timer, and forced on a range/top-metric change or when
    /// the window becomes visible again (UI-08). The timer itself is cheap; the
    /// database pair runs at the range's cadence, at most one pair at a time.
    private func refreshLongRange(force: Bool = false) {
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
        dbPendingCount = 2
        dbLoading = true

        telemetry.chartSeries(rangeSeconds: range, bucketMs: timeRange.bucketMs) { series in
            if generation == dbGeneration { dbSeries = series }
            longRangeQueryCompleted()
        }
        if wantsApps {
            telemetry.topApps(rangeSeconds: range, limit: 6) { apps in
                if generation == dbGeneration { dbTopApps = apps }
                longRangeQueryCompleted()
            }
        } else {
            telemetry.topHosts(rangeSeconds: range, limit: 6) { hosts in
                if generation == dbGeneration { dbTopHosts = hosts }
                longRangeQueryCompleted()
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
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
