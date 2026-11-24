import AppKit
import Charts
import SwiftUI

/// The internet-health half of the dashboard.
///
/// The request log answers "what went through the proxy"; this answers "was the
/// internet actually there, and when it wasn't, was it DNS or the network?".
/// Outages are replayed from persisted probes, so a relaunch no longer erases
/// the history the user is looking at.
struct InternetHealthView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var telemetry: TelemetryStore
    @ObservedObject private var monitor = ConnectivityMonitor.shared

    @State private var window: Window = .h24
    @State private var stats = ConnectivityRangeStats()
    @State private var buckets: [ConnectivityBucket] = []
    @State private var outages: [ConnectivityOutage] = []
    @State private var evidence = OutageTunnelEvidence()
    @State private var loaded = false
    @State private var copied = false
    @State private var generation = 0
    @StateObject private var ticker = CoalescedTicker(interval: 15)

    private enum Window: String, CaseIterable, Identifiable {
        case h1, h24, d7
        var id: String { rawValue }
        var label: String {
            switch self {
            case .h1: return "1h"
            case .h24: return "24h"
            case .d7: return "7d"
            }
        }
        var longLabel: String {
            switch self {
            case .h1: return "Last hour"
            case .h24: return "Last 24 hours"
            case .d7: return "Last 7 days"
            }
        }
        var seconds: Int {
            switch self {
            case .h1: return 3_600
            case .h24: return 86_400
            case .d7: return 604_800
            }
        }
        var bucketMs: Int64 {
            switch self {
            case .h1: return 5 * 60_000
            case .h24: return 15 * 60_000
            case .d7: return 2 * 3_600_000
            }
        }
        var bucketLabel: String {
            switch self {
            case .h1: return "5 min buckets"
            case .h24: return "15 min buckets"
            case .d7: return "2 h buckets"
            }
        }
    }

    private var enabled: Bool { model.config.connectivity.enabled }
    private var snapshot: ConnectivitySnapshot { monitor.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            liveBanner
            Divider()
            statsRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            chartCard
                .padding(16)
                .frame(height: 232)
            Divider()
            outageList
        }
        .onAppear {
            refresh()
            ticker.start()
        }
        .onDisappear { ticker.stop() }
        .onChange(of: window) { _, _ in refresh() }
        .onReceive(ticker.$tick) { _ in refresh() }
    }

    // MARK: - Live status

    private var liveBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(enabled ? snapshot.title() : "Monitoring is off")
                    .font(.headline)
                if enabled {
                    Text(snapshot.detail())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(snapshot.detail())
                } else {
                    Text("Turn on Settings → General → Internet → Monitor internet status to record outages here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if enabled {
                Button("Check Now") { monitor.checkNow() }
                Button {
                    copySummary()
                } label: {
                    Label(copied ? "Copied" : "Copy summary",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .help("Copy a plain-text report of this window — uptime, outages, causes and "
                      + "whether the tunnel kept working. Useful when reporting a fault to an ISP.")
            } else {
                Button("Open Settings") { model.openSettings() }
            }
            Picker("", selection: $window) {
                ForEach(Window.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help("How far back the history and outage list reach")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        guard enabled else { return Color(nsColor: .tertiaryLabelColor) }
        switch snapshot.health() {
        case .checking: return Color(nsColor: .tertiaryLabelColor)
        case .good: return .green
        case .unstable: return .orange
        case .down: return snapshot.failure == .dns ? .orange : .red
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatBox(title: "Uptime",
                    value: loaded ? percent(stats.uptime) : "—",
                    detail: loaded ? "\(Format.count(stats.ok)) of \(Format.count(stats.total)) checks" : nil,
                    color: uptimeColor,
                    help: "Share of reachability checks that succeeded in the selected window. A check is one tiny HTTPS request, so this is measured, not inferred from traffic.")

            StatBox(title: "Outages",
                    value: loaded ? Format.count(outageCount) : "—",
                    detail: loaded ? outageDetail : nil,
                    color: outageCount == 0 ? .secondary : .red,
                    help: "Separate outages in the selected window. A failure is only a new outage when the previous check succeeded; repeated failures are one outage. A single failed probe is listed as a brief blip.")

            StatBox(title: "Longest",
                    value: loaded ? longestOutageText : "—",
                    detail: loaded && outages.isEmpty ? "no outages recorded" : nil,
                    color: .secondary,
                    help: "The longest single outage in the selected window. Gaps longer than five minutes between checks are split, so sleep/quit time is never reported as one long outage.")

            StatBox(title: "Tunnel during outages",
                    value: loaded && evidence.attempted > 0
                        ? "\(evidence.outagesWithSuccess)/\(evidence.outagesWithTraffic)" : "—",
                    detail: loaded
                        ? (evidence.attempted > 0
                           ? "\(Format.count(evidence.tunnelOK)) ok · \(Format.count(evidence.tunnelFailed)) failed"
                           : "no tunneled connections")
                        : nil,
                    color: evidence.outagesWithSuccess > 0 ? .green : .secondary,
                    help: "Outages in which at least one tunneled connection still succeeded. Tunneled names are resolved by the SOCKS server, so this is the honest test of whether the tunnel was affected by a DNS failure.")
        }
    }

    private var outageCount: Int {
        outages.count
    }

    /// "5 brief · 9 DNS / 9 network checks" — the split that tells the user
    /// whether to look at the resolver or at the uplink.
    private var outageDetail: String {
        guard stats.failed > 0 else { return "no failed checks" }
        var parts: [String] = []
        let brief = outages.filter(\.isBrief).count
        if brief > 0 { parts.append("\(brief) brief") }
        var causes: [String] = []
        if stats.dnsFailed > 0 { causes.append("\(Format.count(stats.dnsFailed)) DNS") }
        if stats.networkFailed > 0 { causes.append("\(Format.count(stats.networkFailed)) network") }
        if !causes.isEmpty { parts.append(causes.joined(separator: "/") + " checks") }
        return parts.joined(separator: " · ")
    }

    /// The stored history can be younger than the selected window (fresh
    /// install, or retention). Clamping the axis keeps a two-hour history from
    /// being drawn as a mostly-empty 24-hour chart.
    private var historyStart: Date? {
        guard let first = stats.firstCheck else { return nil }
        let rangeStart = Date().addingTimeInterval(-Double(window.seconds))
        return first.timeIntervalSince(rangeStart) > 60 ? first : nil
    }

    private var uptimeColor: Color {
        guard loaded, stats.total > 0 else { return .secondary }
        if stats.uptime >= 0.99 { return .green }
        if stats.uptime >= 0.95 { return .orange }
        return .red
    }

    private var longestOutageText: String {
        guard let longest = outages.map({ $0.duration() }).max(), longest > 0 else { return "—" }
        return ConnectivitySnapshot.shortDuration(longest)
    }

    private func percent(_ value: Double) -> String {
        guard stats.total > 0 else { return "—" }
        return String(format: "%.1f%%", value * 100)
    }

    // MARK: - Timeline

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Availability")
                        .font(.headline)
                    Text(chartSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if stats.total > 0 {
                    Text("red = failed check")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if buckets.isEmpty {
                VStack(spacing: 4) {
                    Text(!enabled ? "Internet monitoring is off."
                         : (loaded ? "No probe history in this window." : "Loading…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !enabled {
                        Text("Enable it in Settings → General → Internet to record outages here.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if loaded {
                        Text("History starts as soon as monitoring runs; leave the app open for a few minutes.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("Time", Date(timeIntervalSince1970: Double(bucket.startMs) / 1000)),
                        y: .value("Checks", bucket.ok)
                    )
                    .foregroundStyle(by: .value("Result", "Passed"))

                    BarMark(
                        x: .value("Time", Date(timeIntervalSince1970: Double(bucket.startMs) / 1000)),
                        y: .value("Checks", bucket.failed)
                    )
                    .foregroundStyle(by: .value("Result", "Failed"))
                }
                .chartForegroundStyleScale([
                    // Failed checks are the signal; keep passed checks quiet so
                    // a 30-second outage is visible even in a 2-hour bucket.
                    "Passed": Color.green.opacity(0.38),
                    "Failed": Color.red
                ])
                .chartXScale(domain: chartDomain)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(window == .d7
                                     ? date.formatted(.dateTime.month(.abbreviated).day())
                                     : date.formatted(.dateTime.hour().minute()))
                            }
                        }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 4)
            }
        }
    }

    private var chartSubtitle: String {
        var text = "\(window.longLabel) · \(window.bucketLabel) · checks per bucket"
        if let first = historyStart {
            text += " · history since \(first.formatted(date: .omitted, time: .shortened))"
        }
        return text
    }

    /// Pinned to the selected window (or to the first stored check when the
    /// history is younger) so a quiet period cannot stretch the axis — the same
    /// rule the traffic chart follows.
    private var chartDomain: ClosedRange<Date> {
        let end = Date()
        let start = historyStart ?? end.addingTimeInterval(-Double(window.seconds))
        return start...end
    }

    // MARK: - Outages

    private var outageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Outages")
                    .font(.headline)
                Text("newest first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !outages.isEmpty {
                    Text("showing \(min(outages.count, 20)) of \(outages.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if outages.isEmpty {
                Text(!enabled
                     ? "Outage history is recorded only while monitoring is on."
                     : (loaded
                        ? "No outages recorded in this window. Every check succeeded."
                        : "Loading outage history…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(outages.prefix(20))) { outage in
                            outageRow(outage)
                            Divider()
                        }
                    }
                }
            }

            Divider()
            Text("A check is one tiny HTTPS request every 5–20 s. When it fails, a literal-IP TCP "
                 + "probe separates a DNS problem from a dead network path. Only outcomes are stored; "
                 + "the probe never goes through the proxy and never carries browsing data.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func outageRow(_ outage: ConnectivityOutage) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(outage.isOpen ? Color.red
                      : outage.isBrief ? Color.orange.opacity(0.5) : Color.red.opacity(0.55))
                .frame(width: 7, height: 7)
            Text(outage.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.callout.monospacedDigit())
                .frame(width: 128, alignment: .leading)
            Text(ConnectivitySnapshot.shortDuration(outage.duration()))
                .font(.callout.monospacedDigit())
                .frame(width: 74, alignment: .leading)
            causePill(outage)
            Text(outage.isOpen ? "ongoing" : "\(outage.checks) check\(outage.checks == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            if outage.isBrief {
                Text("brief")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .foregroundStyle(.secondary)
            }
            tunnelBadge(outage)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .help(causeHelp(outage))
    }

    /// What the tunnel did during *this* outage. "No tunnel traffic" is a real
    /// answer too — it means the outage was never tested against the tunnel.
    @ViewBuilder
    private func tunnelBadge(_ outage: ConnectivityOutage) -> some View {
        let counts = evidence.perOutage[outage.start] ?? OutageTunnel()
        if counts.attempted == 0 {
            Text("tunnel idle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            Label("\(counts.ok)/\(counts.attempted) tunneled",
                  systemImage: counts.ok > 0 ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption2)
                .foregroundStyle(counts.ok > 0 ? Color.green : Color.secondary)
                .help(counts.ok > 0
                      ? "Tunneled connections still succeeded during this outage: the tunnel resolves hostnames remotely, so a DNS failure does not affect it."
                      : "Tunneled connections were attempted during this outage and none succeeded, so the tunnel was affected too.")
        }
    }

    private func causePill(_ outage: ConnectivityOutage) -> some View {
        let failure = outage.dominantFailure
        let text: String
        let color: Color
        switch failure {
        case .dns:
            text = outage.isMixed ? "Mixed" : "DNS"
            color = .orange
        case .network:
            text = outage.isMixed ? "Mixed" : "Network"
            color = .red
        case .none:
            text = "Unknown"
            color = .secondary
        }
        return Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
            .frame(width: 74, alignment: .leading)
            .help(outage.causeSummary)
    }

    private func causeHelp(_ outage: ConnectivityOutage) -> String {
        let cause = "\(outage.causeSummary)."
        switch outage.dominantFailure {
        case .dns:
            return cause + " A name probe failed while a raw TCP connect to a literal IP still worked: "
                + "the resolver or the provider's DNS failed, not the network path."
        case .network:
            return cause + " Both the name probe and the IP-literal probe failed, so the network path itself was down."
        case .none:
            return cause + " The failure was not classified (the probe cycle was cut short)."
        }
    }

    // MARK: - Copy

    /// A compact plain-text report. This is the "hand it to someone" path:
    /// provider support asks for times, durations and whether it was DNS.
    private func copySummary() {
        var lines: [String] = []
        lines.append("ProxyManager internet health — \(window.longLabel.lowercased())")
        if let first = stats.firstCheck {
            lines.append("History since: \(first.formatted(date: .abbreviated, time: .shortened))")
        }
        if stats.total > 0 {
            var uptime = "Uptime: \(percent(stats.uptime)) (\(Format.count(stats.ok)) of \(Format.count(stats.total)) checks"
            if let latency = stats.averageLatencyMS { uptime += ", \(latency) ms average" }
            lines.append(uptime + ")")
        }
        lines.append("Outages: \(outageCount)" + (stats.failed > 0 ? " (\(outageDetail))" : ""))
        if let longest = outages.map({ $0.duration() }).max(), longest > 0 {
            lines.append("Longest: \(ConnectivitySnapshot.shortDuration(longest))")
        }
        if evidence.attempted > 0 {
            lines.append("Tunnel: succeeded during \(evidence.outagesWithSuccess) of "
                         + "\(evidence.outagesWithTraffic) outages with tunnel traffic "
                         + "(\(Format.count(evidence.tunnelOK)) ok, \(Format.count(evidence.tunnelFailed)) failed)")
        }
        if !outages.isEmpty {
            lines.append("")
            for outage in outages.prefix(20) {
                let counts = evidence.perOutage[outage.start] ?? OutageTunnel()
                var line = "\(outage.start.formatted(date: .abbreviated, time: .standard))"
                line += "  \(ConnectivitySnapshot.shortDuration(outage.duration()))"
                line += "  \(outage.isOpen ? "ongoing, " : "")\(outage.causeSummary)"
                if counts.attempted > 0 {
                    line += "  tunnel \(counts.ok)/\(counts.attempted)"
                }
                lines.append("- " + line)
            }
            if outages.count > 20 {
                lines.append("… and \(outages.count - 20) more")
            }
        }
        lines.append("")
        lines.append("Measured by ProxyManager's active reachability probe "
                     + "(DNS name check + literal-IP TCP check).")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    // MARK: - Loading

    private func refresh() {
        guard enabled else {
            loaded = true
            return
        }
        generation &+= 1
        let current = generation
        let window = self.window
        telemetry.connectivityStats(rangeSeconds: window.seconds) { value in
            guard current == generation else { return }
            stats = value
            loaded = true
        }
        telemetry.connectivityBuckets(rangeSeconds: window.seconds, bucketMs: window.bucketMs) { value in
            guard current == generation else { return }
            buckets = value
        }
        telemetry.connectivityOutages(rangeSeconds: window.seconds) { list in
            guard current == generation else { return }
            outages = Array(list.reversed())
            telemetry.tunnelEvidence(for: list) { value in
                guard current == generation else { return }
                evidence = value
            }
        }
    }
}
