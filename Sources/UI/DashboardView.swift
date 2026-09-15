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

    @State private var routeFilter: String = "All"
    @State private var hostFilter: String = ""
    @State private var paused = false
    @State private var pausedSnapshot: [FeedRow] = []
    @State private var timeRange: TimeRange = .m5
    @State private var metric: ChartMetric = .requests
    @State private var selectedID: UUID?

    // Long-range chart/top-hosts data, loaded from SQLite on a 2 s cadence.
    @State private var dbSeries: [ChartBucket] = []
    @State private var dbTopHosts: [(host: String, count: Int)] = []
    @State private var lastDBLoad: Int64 = 0

    private let routeOptions = ["All", "Tunneled", "Direct", "Blocked"]
    private let seriesTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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
        .onChange(of: model.telemetry.liveRequests.count) { _, _ in reconcileSelection() }
        .onChange(of: model.telemetry.recentRequests.count) { _, _ in reconcileSelection() }
        .onReceive(seriesTimer) { _ in refreshLongRange() }
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

            TextField("Filter host…", text: $hostFilter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Toggle("Pause", isOn: $paused)
                .toggleStyle(.checkbox)

            Spacer()

            Button(role: .destructive) {
                model.telemetry.purge()
            } label: {
                Label("Clear", systemImage: "trash")
            }
        }
        .padding(12)
    }

    // MARK: - Stats

    private var statsStrip: some View {
        HStack(spacing: 12) {
            StatBox(title: "Tunneled", value: "\(model.telemetry.stats.tunneledRequests)", color: .green)
            StatBox(title: "Direct", value: "\(model.telemetry.stats.directRequests)", color: .gray)
            StatBox(title: "Blocked", value: "\(model.telemetry.stats.blockedRequests)", color: .red)
            StatBox(title: "Bytes", value: Format.bytes(model.telemetry.stats.bytesIn + model.telemetry.stats.bytesOut), color: .blue)
            StatBox(title: "Active", value: "\(model.telemetry.stats.activeConnections)", color: .orange)
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
        let id = UUID()
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
            for e in model.telemetry.liveRequests where e.ts >= cutoff { events.append(e) }
            for e in model.telemetry.recentRequests.suffix(2000) where e.ts >= cutoff { events.append(e) }
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
            Text("Top tunneled hosts")
                .font(.headline)
            let hosts = topHosts
            if hosts.isEmpty {
                Text("No data yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(Array(hosts.enumerated()), id: \.element.host) { index, item in
                    hostBar(item: item, ratio: ratio(item.count, in: hosts))
                }
                Spacer()
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var topHosts: [(host: String, count: Int)] {
        if timeRange == .m5 { return inMemoryTopTunneledHosts }
        return dbTopHosts
    }

    private func ratio(_ count: Int, in hosts: [(host: String, count: Int)]) -> CGFloat {
        let max = hosts.first?.count ?? 1
        guard max > 0 else { return 0 }
        return CGFloat(count) / CGFloat(max)
    }

    private func hostBar(item: (host: String, count: Int), ratio: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(item.host)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 118, alignment: .leading)
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

    private var inMemoryTopTunneledHosts: [(host: String, count: Int)] {
        let hourAgo = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        var counts: [String: Int] = [:]
        var scanned = 0
        for event in model.telemetry.liveRequests {
            if event.route == .tunnel { counts[event.host, default: 0] += 1 }
            scanned += 1
            if scanned > 500 { break }
        }
        scanned = 0
        for event in model.telemetry.recentRequests.reversed() where event.ts >= hourAgo {
            if event.route == .tunnel { counts[event.host, default: 0] += 1 }
            scanned += 1
            if scanned > 3000 { break }
        }
        return counts.sorted { $0.value > $1.value }.prefix(6).map { (host: $0.key, count: $0.value) }
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
        if let e = model.telemetry.liveRequests.first(where: { $0.id == id }) { return e }
        if let e = model.telemetry.recentRequests.first(where: { $0.id == id }) { return e }
        return nil
    }

    private var feedHeader: some View {
        HStack(spacing: 10) {
            Text("Request feed")
                .font(.headline)
            Picker("Route", selection: $routeFilter) {
                ForEach(routeOptions, id: \.self) { Text($0) }
            }
            .frame(width: 130)
            if paused {
                Text("paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.telemetry.liveRequests.count) live · \(model.telemetry.recentRequests.count) completed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var feedRows: [FeedRow] {
        if paused { return pausedSnapshot }
        return computeFeedRows()
    }

    private func computeFeedRows() -> [FeedRow] {
        var rows: [FeedRow] = []
        rows.reserveCapacity(320)
        for event in model.telemetry.liveRequests {
            rows.append(FeedRow(event: event, isLive: true))
        }
        for event in model.telemetry.recentRequests.suffix(250).reversed() {
            rows.append(FeedRow(event: event, isLive: false))
        }
        switch routeFilter {
        case "Tunneled": rows = rows.filter { $0.event.route == .tunnel }
        case "Direct": rows = rows.filter { $0.event.route == .direct }
        case "Blocked": rows = rows.filter { $0.event.route == .block }
        default: break
        }
        if !hostFilter.isEmpty {
            rows = rows.filter { $0.event.host.localizedCaseInsensitiveContains(hostFilter) }
        }
        // Stable sort: equal timestamps keep their pre-sort relative order, so
        // rows never reshuffle between refreshes (a live feed must not "jump").
        rows = rows.enumerated()
            .sorted { a, b in
                if a.element.event.ts != b.element.event.ts { return a.element.event.ts > b.element.event.ts }
                return a.offset < b.offset
            }
            .map(\.element)
        return Array(rows.prefix(250))
    }

    // MARK: - Long-range loading

    private func refreshLongRange(force: Bool = false) {
        guard timeRange != .m5 else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard force || now - lastDBLoad >= 1500 else { return }
        lastDBLoad = now
        let range = timeRange.seconds
        model.telemetry.chartSeries(rangeSeconds: range, bucketMs: timeRange.bucketMs) { dbSeries = $0 }
        model.telemetry.topHosts(rangeSeconds: range, limit: 6) { dbTopHosts = $0 }
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
