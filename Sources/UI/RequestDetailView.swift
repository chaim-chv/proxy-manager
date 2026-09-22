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
                        appRow
                        row("Source port", String(event.srcPort))
                    }
                    card(title: "Routing") {
                        routeDecisionRow
                        reasonRow
                        optionsRow
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
                        row("Status", event.status > 0 ? String(event.status) : "—")
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

    private var appRow: some View {
        HStack(spacing: 6) {
            Text("App")
                .foregroundStyle(.secondary)
            Spacer()
            if let app = event.app, !app.isEmpty {
                if let image = AppIcon.image(bundleId: event.appBundle, path: nil) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(app)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help(event.appBundle ?? "")
    }

    private var routeDecisionRow: some View {
        HStack {
            Text("Route")
                .foregroundStyle(.secondary)
            Spacer()
            routeChip
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var reasonRow: some View {
        HStack(spacing: 6) {
            Text("Reason")
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if configChangedSinceRequest {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text(reasonShort)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .hoverTooltip(reasonSentence)
    }

    private var optionsRow: some View {
        HStack(spacing: 12) {
            Text("Options")
                .foregroundStyle(.secondary)
            Spacer()
            changeAppModeMenu
            targetButton
            openAppSettingsButton
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Explanation ("why")

    private var appLabel: String {
        (event.app?.isEmpty == false) ? event.app! : "This app"
    }

    /// Identity reconstructed from the recorded event, for app-rule matching.
    private var appIdentityForMatching: AppIdentity? {
        guard let app = event.app, !app.isEmpty else { return nil }
        return AppIdentity(pid: 0, bundleId: event.appBundle, executablePath: "",
                           executableName: app, displayName: app)
    }

    private var explanation: RouteExplanation {
        model.proxyServer.routingEngine.explain(host: event.host, app: appIdentityForMatching)
    }

    /// True when the recorded route differs from what the current rules produce
    /// (so the inspector must not claim the explanation is what happened).
    private var configChangedSinceRequest: Bool {
        guard recordedErrorShort == nil else { return false }
        return explanation.route.route != event.route
    }

    private var recordedErrorShort: String? {
        guard let error = event.error else { return nil }
        if error.contains("tunnel_down") {
            return event.route == .block ? "tunnel down → blocked" : "tunnel down → direct"
        }
        if error.contains("blocked_private_destination") { return "blocked · private destination" }
        return nil
    }

    private var recordedErrorSentence: String? {
        guard let error = event.error else { return nil }
        if error.contains("tunnel_down") {
            return event.route == .block
                ? "The tunnel was down, so the request was blocked (fail-closed)."
                : "The tunnel was down, so the request fell back to a direct connection (fail-open)."
        }
        if error.contains("blocked_private_destination") {
            return "A non-loopback client tried to reach a private/loopback destination, so it was blocked."
        }
        return nil
    }

    private var reasonShort: String {
        if let recorded = recordedErrorShort { return recorded }
        let e = explanation
        switch e.reason {
        case .appTunnel: return "\(appLabel) · Tunnel all"
        case .appDirect: return "\(appLabel) · Direct all"
        case .appDefaultTunnel: return "default: Tunnel all"
        case .appDefaultDirect: return "default: Direct all"
        case .targetExact: return "exact \(e.matched ?? "")"
        case .targetWildcard: return "wildcard \(e.matched ?? "")"
        case .noMatch: return "no rule"
        }
    }

    private var reasonSentence: String {
        if let recorded = recordedErrorSentence { return recorded }
        let e = explanation
        var sentence: String
        switch e.reason {
        case .appTunnel:
            sentence = "\(appLabel) is set to “Tunnel all”, so all of its traffic goes through the tunnel."
        case .appDirect:
            sentence = "\(appLabel) is set to “Direct all”, so its traffic goes direct."
        case .appDefaultTunnel:
            sentence = "\(appLabel) has no rule; the default for apps is “Tunnel all”."
        case .appDefaultDirect:
            sentence = "\(appLabel) has no rule; the default for apps is “Direct all”."
        case .targetExact:
            sentence = "The host matches the target rule “\(e.matched ?? "")”."
        case .targetWildcard:
            sentence = "The host matches the wildcard target “\(e.matched ?? "")”."
        case .noMatch:
            sentence = "No app rule or target matched, so it went direct."
        }
        if e.appRuleMode == .targets, e.appRuleKey != nil {
            sentence = "\(appLabel) is set to “Use target rules”. " + sentence
        }
        if configChangedSinceRequest {
            sentence += "\n\nRules changed since this request. With the current rules it would be \(explanation.route.route.rawValue)."
        }
        return sentence
    }

    // MARK: - Quick change

    private var appRuleKey: (key: String, kind: AppRuleKeyKind)? {
        if let bundle = event.appBundle, !bundle.isEmpty { return (bundle, .bundle) }
        if let app = event.app, !app.isEmpty { return (app, .executableName) }
        return nil
    }

    @ViewBuilder private var changeAppModeMenu: some View {
        if let key = appRuleKey {
            Menu {
                ForEach(AppRoutingMode.allCases) { mode in
                    Button(mode.label) {
                        model.upsertAppRule(key: key.key, keyKind: key.kind, mode: mode)
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .hoverTooltip("Change routing for \(appLabel)")
        }
    }

    @ViewBuilder private var openAppSettingsButton: some View {
        if appRuleKey != nil {
            Button(action: openAppSettings) {
                Image(systemName: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .hoverTooltip("Open \(appLabel) settings")
        }
    }

    private func openAppSettings() {
        guard let key = appRuleKey else { return }
        if let rule = model.appRule(forKey: key.key, keyKind: key.kind) {
            model.revealAppInSettings(rule.id)
        } else {
            model.settingsSelection = .apps
            model.openSettings()
        }
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
