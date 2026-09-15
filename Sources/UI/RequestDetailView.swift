import SwiftUI
import AppKit

/// Right-hand inspector for a single selected request. Shows only the metadata
/// the proxy already records — headers and bodies are never captured, so there
/// is nothing else to show. `event` is resolved by id from the live/completed
/// feeds, so a live row updates in place as bytes and duration tick.
struct RequestDetailView: View {
    @EnvironmentObject var model: AppModel

    let event: RequestEvent
    let onClose: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    card(title: "Request") {
                        row("Method", event.method)
                        row("Scheme", event.scheme)
                        hostRow
                        row("Port", String(event.port))
                        row("Source port", String(event.srcPort))
                    }
                    card(title: "Routing") {
                        routeRow
                        row("Status", event.status > 0 ? String(event.status) : "—")
                        if let error = event.error, !error.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Text("Error").foregroundStyle(.secondary)
                                Spacer()
                                Text(error)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                    card(title: "Data") {
                        row("Bytes in", Format.bytes(event.bytesIn))
                        row("Bytes out", Format.bytes(event.bytesOut))
                        row("Total", Format.bytes(event.bytesIn + event.bytesOut))
                        row("Duration", Format.duration(event.durationMs))
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Request detail")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close (click the row again to clear)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Building blocks

    private func card(title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var hostRow: some View {
        HStack(spacing: 6) {
            Text("Host")
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: copyHost) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .hoverTooltip("Copy host")
            Text(event.host)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func copyHost() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(event.host, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
    }

    private var routeRow: some View {
        HStack(spacing: 8) {
            Text("Route")
                .foregroundStyle(.secondary)
            Spacer()
            targetButton
            routeChip
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Targets action

    private enum TargetAction {
        case add
        case remove(TargetRule)
        case reveal(TargetRule)
    }

    private var targetAction: TargetAction {
        let h = RoutingEngine.normalize(event.host)
        let targets = model.config.targets
        for rule in targets where rule.enabled {
            if !RoutingEngine.isWildcard(rule.pattern)
                && RoutingEngine.normalize(rule.pattern) == h {
                return .remove(rule)
            }
        }
        for rule in targets where rule.enabled {
            if RoutingEngine.isWildcard(rule.pattern)
                && RoutingEngine.matches(pattern: rule.pattern, host: h) {
                return .reveal(rule)
            }
        }
        return .add
    }

    private var targetButton: some View {
        Button(action: performTargetAction) {
            Image(systemName: targetButtonIcon)
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(targetButtonColor)
        .hoverTooltip(targetButtonTooltip)
    }

    private var targetButtonIcon: String {
        switch targetAction {
        case .add: return "plus.circle"
        case .remove: return "minus.circle"
        case .reveal: return "scope"
        }
    }

    private var targetButtonColor: Color {
        switch targetAction {
        case .add: return .green
        case .remove: return .red
        case .reveal: return .accentColor
        }
    }

    private var targetButtonTooltip: String {
        switch targetAction {
        case .add:
            return "Add \(event.host) to targets (tunnel it)"
        case .remove(let rule):
            return "Remove \(rule.pattern) from targets"
        case .reveal(let rule):
            return "Matched by wildcard \(rule.pattern) — open in Targets"
        }
    }

    private func performTargetAction() {
        switch targetAction {
        case .add:
            model.addTarget(event.host)
        case .remove(let rule):
            model.removeTarget(id: rule.id)
        case .reveal(let rule):
            model.revealTargetInSettings(rule)
        }
    }

    private var routeChip: some View {
        Text(event.route.rawValue)
            .font(.caption.bold())
            .foregroundStyle(routeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(routeColor.opacity(0.18)))
    }

    private var routeColor: Color {
        switch event.route {
        case .tunnel: return .green
        case .direct: return .secondary
        case .block: return .red
        }
    }
}
