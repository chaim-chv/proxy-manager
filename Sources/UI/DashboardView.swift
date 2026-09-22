import SwiftUI
import Charts
import Combine

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

    // Long-range chart/top-hosts data, loaded from SQLite on a 2 s cadence.
    @State private var dbSeries: [ChartBucket] = []
    @State private var dbTopHosts: [(host: String, count: Int)] = []
    @State private var dbTopApps: [(app: String, bundle: String?, count: Int)] = []
    @State private var lastDBLoad: Int64 = 0

    private let routeOptions = ["All", "Tunneled", "Direct", "Blocked"]
    private let seriesTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private enum TopMetric: String, CaseIterable, Identifiable {
        case hosts = "Hosts"
        case apps = "Apps"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statsStrip
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            HStack(alignment: .top, spacing: 16) {
                chartSection
                topHostsSection
                    .frame(width: 260)
            }
            .padding(16)
            .frame(height: 260)
            Divider()
            feedArea
        }
        .frame(minWidth: 860, minHeight: 560)
        .onChange(of: paused) { _, isPaused in
            if isPaused { pausedSnapshot = computeFeedRows() }
        }
        .onChange(of: timeRange) { _, _ in refreshLongRange(force: true) }
        .onChange(of: topMetric) { _, _ in refreshLongRange(force: true) }
        .onChange(of: telemetry.liveRequests.count) { _, _ in reconcileSelection() }
        .onChange(of: telemetry.recentRequests.count) { _, _ in reconcileSelection() }
        .onReceive(seriesTimer) { _ in refreshLongRange() }
        #if SCREENSHOT_MODE
        .onAppear {
            guard DemoMode.isEnabled, DemoMode.showsDetailPanel, selectedID == nil else { return }
            let event = telemetry.recentRequests.last { $0.route == .tunnel && !$0.path.isEmpty }
                ?? telemetry.recentRequests.last { $0.route == .tunnel }
            selectedID = event?.id
        }
        #endif
    }

    private func reconcileSelection() {
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

    private var chartSection: some View {
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

            if seriesPoints.isEmpty {
                Text("No data yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
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

    private var chart: some View {
        Chart(seriesPoints) { point in
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

    private var topHostsSection: some View {
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
            let items = topItems
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
            Text(item.label)
                .lineLimit(1)
                .truncationMode(.middle)
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

    private var feedArea: some View {
        HSplitView {
            VStack(spacing: 0) {
                feedHeader
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                if feedRows.isEmpty {
                    Text("No requests yet")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FeedTable(rows: feedRows, selectedID: $selectedID)
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

    private var feedHeader: some View {
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
            if !appFilterOptions.isEmpty {
                AppFilterMenu(options: appFilterOptions, selection: $appFilterKey)
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

    private var feedRows: [FeedRow] {
        if paused { return pausedSnapshot }
        return computeFeedRows()
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

    private func computeFeedRows() -> [FeedRow] {
        var rows = baseFeedRows()
        switch routeFilter {
        case "Tunneled": rows = rows.filter { $0.event.route == .tunnel }
        case "Direct": rows = rows.filter { $0.event.route == .direct }
        case "Blocked": rows = rows.filter { $0.event.route == .block }
        default: break
        }
        if !hostFilter.isEmpty {
            rows = rows.filter { $0.event.host.localizedCaseInsensitiveContains(hostFilter) }
        }
        if let appFilterKey {
            rows = rows.filter { ($0.event.appBundle ?? $0.event.app ?? "") == appFilterKey }
        }
        return Array(rows.prefix(250))
    }

    /// Apps present in the current feed, most-requested first (then A–Z), with
    /// their bundle id so the menu can show icons. Derived from the same rows the
    /// feed shows, so only apps actually in the feed are offered.
    private var appFilterOptions: [AppFilterOption] {
        var counts: [String: (name: String, bundle: String?, count: Int)] = [:]
        for row in baseFeedRows() {
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

    private func refreshLongRange(force: Bool = false) {
        guard timeRange != .m5 else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard force || now - lastDBLoad >= 1500 else { return }
        lastDBLoad = now
        let range = timeRange.seconds
        telemetry.chartSeries(rangeSeconds: range, bucketMs: timeRange.bucketMs) { dbSeries = $0 }
        if topMetric == .apps {
            telemetry.topApps(rangeSeconds: range, limit: 6) { dbTopApps = $0 }
        } else {
            telemetry.topHosts(rangeSeconds: range, limit: 6) { dbTopHosts = $0 }
        }
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
