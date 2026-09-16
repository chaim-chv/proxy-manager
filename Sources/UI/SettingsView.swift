import SwiftUI
import AppKit

/// Weak reference to the SwiftUI Settings window so AppDelegate can close it on
/// Escape. The Settings window is titled "Proxy Manager" — same as the dashboard
/// — so it must be identified by reference, not title.
enum SettingsWindow {
    static weak var current: NSWindow?
}

private struct SettingsWindowRef: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = SettingsWindowRefView()
        view.onWindowChange = { SettingsWindow.current = $0 }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SettingsWindowRefView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case tunnel = "Tunnel"
    case proxy = "Proxy"
    case targets = "Targets"
    case system = "System"
    case monitoring = "Monitoring"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "circle.lefthalf.filled"
        case .tunnel: return "point.3.connected.trianglepath.dotted"
        case .proxy: return "arrow.triangle.branch"
        case .targets: return "scope"
        case .system: return "terminal"
        case .monitoring: return "chart.bar"
        case .about: return "info.circle"
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .tunnel: return "Tunnel"
        case .proxy: return "Proxy"
        case .targets: return "Targets"
        case .system: return "System"
        case .monitoring: return "Monitoring"
        case .about: return "About"
        }
    }

    var summary: String {
        switch self {
        case .general: return "Startup behavior and resetting the app."
        case .appearance: return "The menu bar icon and the app's light or dark look."
        case .tunnel: return "The encrypted pipe that carries your selected traffic to a remote machine."
        case .proxy: return "The local router that sends allow-listed hosts to the tunnel and everything else direct."
        case .targets: return "Only these hostnames go through the tunnel."
        case .system: return "How routing is wired into macOS and your terminal."
        case .monitoring: return "What gets recorded and how long it's kept."
        case .about: return "How Proxy Manager works, in plain words."
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SettingsSection? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(SettingsWindowRef())
        .onAppear {
            if let s = model.settingsSelection { selection = s }
        }
        .onChange(of: model.settingsSelection) { _, section in
            if let section { selection = section }
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .general {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .tunnel: TunnelSettingsView()
        case .proxy: ProxySettingsView()
        case .targets: TargetsView()
        case .system: SystemSettingsView()
        case .monitoring: MonitoringSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

/// Shared page scaffolding: title + short description above the content.
struct SettingsPage<Content: View>: View {
    let title: String
    let summary: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.bold())
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared page building blocks
//
// Settings pages align their content with the page header (a 20 pt edge inset)
// instead of letting the grouped-form style add a deeper gutter. Content is
// organized into rounded "group" cards so the density stays close to the
// grouped-form look while the whitespace — horizontal and vertical — stays tight.

/// Aligns page content to the header inset (20 pt) with a tight vertical rhythm.
private struct SettingsContent<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled settings group rendered as a rounded card aligned to the header.
/// `title` (with optional inline help) appears above the card, like a section
/// header in a grouped form.
private struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var help: String? = nil
    var example: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.semibold))
                    if let help {
                        HelpPopover(text: help, example: example)
                    }
                }
                .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }
}

/// A single compact settings row, inset like a grouped-form row.
private struct SettingsRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A caption under a control row inside a group card.
private struct SettingsCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row where a title sits on the left and a switch control on the right —
/// the macOS preferences look for a boolean option.
private struct SettingsToggleRow: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        SettingsRow {
            Text(title)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// A label + text field row, with a fixed label column so fields line up.
private struct SettingsFieldRow<Field: View>: View {
    let label: String
    let field: Field

    init(_ label: String, _ field: Field) {
        self.label = label
        self.field = field
    }

    var body: some View {
        SettingsRow {
            Text(label)
                .frame(width: 130, alignment: .leading)
            field
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Renders `~code~`-free text: backtick-delimited spans are shown as inline
/// monospaced text and the backticks themselves never appear. Backtick spans
/// are only applied when the string actually reaches a `Text(...)` through a
/// variable (which SwiftUI would otherwise print verbatim); literal `Text("…")`
/// markdown keeps working as before.
func codeAwareText(_ text: String, baseFont: Font = .callout) -> Text {
    let pieces = text.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
    var result = Text("")
    for (index, piece) in pieces.enumerated() where !piece.isEmpty {
        if index.isMultiple(of: 2) {
            result = result + Text(piece).font(baseFont)
        } else {
            result = result + Text(piece).font(baseFont.monospaced())
        }
    }
    return result
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var updater = UpdaterController.shared

    var body: some View {
        SettingsPage(title: SettingsSection.general.title, summary: SettingsSection.general.summary) {
            SettingsContent {
                SettingsGroup {
                    SettingsToggleRow(
                        title: "Launch at login",
                        isOn: Binding(
                            get: { model.config.system.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )
                }

                SettingsGroup(
                    title: "Updates",
                    help: "Proxy Manager checks in the background and always asks before installing. Installing restarts the app; your routing settings are restored first and re-applied on relaunch."
                ) {
                    VStack(spacing: 0) {
                        SettingsRow {
                            Text("Check for updates")
                            Spacer()
                            Picker("Check for updates", selection: Binding(
                                get: { updater.frequency },
                                set: { updater.setFrequency($0) }
                            )) {
                                ForEach(UpdateFrequency.allCases) { frequency in
                                    Text(frequency.title).tag(frequency)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        }
                        Divider()
                        SettingsRow {
                            Text("Version \(UpdaterController.displayVersionWithDate)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            CheckForUpdatesButton()
                        }
                    }
                }

                SettingsGroup {
                    SettingsRow {
                        Button("Restart") { model.restartApp() }
                        HelpPopover(text: "Quits and reopens the app. Your routing settings are restored on quit and re-applied on relaunch.")
                        Spacer()
                        Button("Run setup again") { model.replayOnboarding() }
                        Button("Reset all settings and data") { model.resetAll() }
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsPage(title: SettingsSection.appearance.title, summary: SettingsSection.appearance.summary) {
            SettingsContent {
                SettingsGroup(title: "Icon placement",
                              help: "Menu bar only hides the Dock icon. Dock only hides the menu bar item — click the Dock icon to open the dashboard. Menu bar + Dock shows both.") {
                    SettingsRow {
                        AppIconModePicker(mode: model.binding(\.system.iconMode))
                    }
                }

                SettingsGroup(title: "Color mode") {
                    VStack(spacing: 0) {
                        SettingsRow {
                            Picker("Color mode", selection: model.binding(\.system.appearanceMode)) {
                                ForEach(AppearanceMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                        Divider()
                        SettingsCaption(text: "System follows the macOS setting. Light and dark force the whole app — windows, menu bar icon, dashboard — to that look.")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                }

                SettingsGroup(title: "Menu bar icon") {
                    VStack(spacing: 0) {
                        SettingsRow {
                            Picker("Menu bar icon style", selection: model.binding(\.system.colorizeMenuIcon)) {
                                HStack(spacing: 8) {
                                    MenuIconSample(colorized: false)
                                    Text("Classic")
                                }
                                .tag(false)

                                HStack(spacing: 8) {
                                    MenuIconSample(colorized: true)
                                    Text("Colorized")
                                }
                                .tag(true)
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                        }
                        Divider()
                        SettingsCaption(text: model.config.system.colorizeMenuIcon
                             ? "Colored by state: green = on, amber = starting/stopping, orange = degraded, red = error."
                             : "A monochrome icon that matches the rest of your menu bar.")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                }
                .disabled(!model.config.system.iconMode.showsMenuBarIcon)
                .opacity(model.config.system.iconMode.showsMenuBarIcon ? 1 : 0.5)
            }
        }
    }
}

// MARK: - Tunnel

struct TunnelSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsPage(title: SettingsSection.tunnel.title, summary: SettingsSection.tunnel.summary) {
            SettingsContent {
                Picker("", selection: model.binding(\.tunnel.mode)) {
                    Text("I manage the tunnel").tag(TunnelMode.manual)
                    Text("Run the tunnel for me").tag(TunnelMode.managed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                if model.config.tunnel.mode == .managed {
                    ManagedTunnelForm()
                } else {
                    ManualTunnelForm()
                }
            }
        }
    }
}

private struct ManualTunnelForm: View {
    @EnvironmentObject var model: AppModel
    @State private var testState: TestState = .idle
    private enum TestState { case idle, testing, ok, fail }

    var body: some View {
        SettingsGroup(title: "SOCKS5 tunnel",
                      help: "The SOCKS5 proxy allow-listed hosts are routed through. Usually 127.0.0.1 if the tunnel runs on this Mac.",
                      example: "ssh -D 1080 user@server  →  host 127.0.0.1, port 1080") {
            VStack(spacing: 0) {
                SettingsFieldRow("Host", TextField("Host", text: model.binding(\.tunnel.host)))
                Divider()
                SettingsFieldRow("Port", TextField("Port", value: model.portBinding(\.tunnel.port), format: .number))
            }
        }

        SettingsGroup(title: "Status") {
            SettingsRow {
                Circle()
                    .fill(model.tunnelUp ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(model.tunnelUp ? "Tunnel is up" : "Tunnel is down")
                Spacer()
                Button(testTitle) { test() }
                    .disabled(testState == .testing)
                if case .ok = testState { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                if case .fail = testState { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            }
        }

        SettingsGroup(title: "Supervision") {
            VStack(spacing: 0) {
                SettingsToggleRow(title: "Supervised by app", isOn: model.binding(\.tunnel.supervised))
                Divider()
                SettingsFieldRow("launchd job label", TextField("launchd job label", text: model.binding(\.tunnel.launchdLabel))
                    .disabled(!model.config.tunnel.supervised))
                Divider()
                SettingsRow {
                    Button("Restart tunnel") { model.restartTunnel() }
                        .disabled(!model.config.tunnel.supervised || model.config.tunnel.launchdLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                SettingsCaption(text: "If your tunnel is a launchd job, enter its label and the app can restart it for you.")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
        }
    }

    private var testTitle: String { testState == .testing ? "Testing…" : "Test connection" }

    private func test() {
        testState = .testing
        model.testTunnel(host: model.config.tunnel.host, port: model.config.tunnel.port) { up in
            testState = up ? .ok : .fail
        }
    }
}

private struct ManagedTunnelForm: View {
    @EnvironmentObject var model: AppModel
    @State private var password: String = ""

    var body: some View {
        SettingsGroup(title: "SSH connection") {
            VStack(spacing: 0) {
                SettingsFieldRow("Host", TextField("Host (IP or address)", text: model.binding(\.tunnel.managed.sshHost)))
                Divider()
                SettingsFieldRow("Port", TextField("Port", value: model.portBinding(\.tunnel.managed.sshPort), format: .number))
                Divider()
                SettingsFieldRow("Username", TextField("Username", text: model.binding(\.tunnel.managed.username)))
            }
        }

        SettingsGroup(title: "Authentication",
                      help: "A key file is preferred — no secret is passed to ssh. A password is read from the Keychain and handed to ssh via a one-shot askpass helper.",
                      example: "Key path example: ~/.ssh/id_ed25519") {
            VStack(spacing: 0) {
                SettingsRow {
                    Picker("Authentication", selection: model.binding(\.tunnel.managed.auth)) {
                        Text("Key file").tag(SSHAuthMethod.key)
                        Text("Password").tag(SSHAuthMethod.password)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                Divider()
                if model.config.tunnel.managed.auth == .key {
                    SettingsRow {
                        Text("Private key")
                            .frame(width: 130, alignment: .leading)
                        TextField("Private key path", text: model.binding(\.tunnel.managed.keyPath))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        Button("Browse…") {
                            if let path = KeyFilePicker.chooseKeyFile() {
                                model.config.tunnel.managed.keyPath = path
                                model.commitConfig()
                            }
                        }
                    }
                    SettingsCaption(text: "Use a passphrase-less key, or one already loaded in ssh-agent.")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                } else {
                    SettingsRow {
                        Text("Password")
                            .frame(width: 130, alignment: .leading)
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                            .onSubmit { model.saveManagedPassword(password) }
                    }
                    SettingsCaption(text: "Stored securely in the macOS Keychain — never in the config file.")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
            }
        }

        SettingsGroup(title: "Local SOCKS port") {
            VStack(spacing: 0) {
                SettingsFieldRow("Bind host", TextField("SOCKS bind host", text: model.binding(\.tunnel.managed.socksHost)))
                Divider()
                SettingsFieldRow("Port", TextField("SOCKS port", value: model.portBinding(\.tunnel.managed.socksPort), format: .number))
            }
        }

        SettingsGroup(title: "Status") {
            VStack(spacing: 0) {
                SettingsRow {
                    statusRow
                }
                if let err = model.sshError, !err.isEmpty {
                    SettingsRow {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Divider()
                SettingsRow {
                    Button(model.sshRunning ? "Restart tunnel" : "Start tunnel") { model.restartTunnel() }
                    Spacer()
                }
            }
        }
        .onAppear { password = model.loadManagedPassword() }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.tunnelUp ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            if model.sshRunning {
                Text(model.tunnelUp ? "Running and up" : "Running, connecting…")
            } else {
                Text("Stopped")
            }
        }
    }
}

// MARK: - Proxy

struct ProxySettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsPage(title: SettingsSection.proxy.title, summary: SettingsSection.proxy.summary) {
            SettingsContent {
                SettingsGroup(title: "Listen address") {
                    VStack(spacing: 0) {
                        SettingsFieldRow("Bind host", TextField("Bind host", text: model.binding(\.proxy.bindHost)))
                        Divider()
                        SettingsFieldRow("Port", TextField("Port", value: model.portBinding(\.proxy.port), format: .number))
                    }
                }

                SettingsGroup(title: "When the tunnel is down",
                              help: "Fail open (off) lets traffic go direct so nothing breaks. Fail closed (on) blocks routed hosts until the tunnel returns.") {
                    VStack(spacing: 0) {
                        SettingsToggleRow(title: "Fail closed (block allow-listed hosts)", isOn: model.binding(\.policy.failClosedWhenTunnelDown))
                        Divider()
                        SettingsCaption(text: "On = block routed hosts while the tunnel is down. Off = fall back to a direct connection.")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                }
            }
        }
    }
}

// MARK: - System

struct SystemSettingsView: View {
    @EnvironmentObject var model: AppModel

    @State private var newRc = ""

    var body: some View {
        SettingsPage(title: SettingsSection.system.title, summary: SettingsSection.system.summary) {
            SettingsContent {
                SettingsGroup(title: "Terminal apps",
                              help: "CLI tools read HTTP_PROXY/HTTPS_PROXY. Browsers don't need this — they use the macOS system proxy, which the app always sets while routing is on.") {
                    VStack(spacing: 0) {
                        SettingsToggleRow(title: "Inject proxy env vars into shell rc files", isOn: model.binding(\.system.injectShellEnv))
                        Divider()
                        SettingsCaption(text: "Writes ~/.config/proxy-manager/env.sh and adds a guarded source line to each file below, so new terminal sessions pick up HTTP_PROXY/HTTPS_PROXY.")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                }

                SettingsGroup(title: "Shell rc files") {
                    VStack(spacing: 0) {
                        if model.config.system.managedShellRcs.isEmpty {
                            SettingsCaption(text: "No rc files yet.")
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                        }
                        ForEach(model.config.system.managedShellRcs, id: \.self) { rc in
                            SettingsRow {
                                Text(rc).foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    model.config.system.managedShellRcs.removeAll { $0 == rc }
                                    model.commitConfig()
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                            if rc != model.config.system.managedShellRcs.last {
                                Divider()
                            }
                        }
                        Divider()
                        SettingsRow {
                            TextField("Add shell rc file (e.g. ~/.bashrc)", text: $newRc)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                let v = newRc.trimmingCharacters(in: .whitespaces)
                                guard !v.isEmpty else { return }
                                model.config.system.managedShellRcs.append(v)
                                model.commitConfig()
                                newRc = ""
                            }
                            .disabled(newRc.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }

                SettingsGroup(title: "Quit behavior",
                              help: "The crash watchdog is a tiny always-on helper that restores your original proxy settings if Proxy Manager is force-quit or crashes while routing is on — so your internet never stays pointed at a dead local proxy.") {
                    VStack(spacing: 0) {
                        SettingsToggleRow(title: "Restore original proxy settings on quit", isOn: model.binding(\.system.restoreOnQuit))
                        Divider()
                        SettingsToggleRow(
                            title: "Crash watchdog (restore internet if the app dies)",
                            isOn: Binding(
                                get: { model.config.system.crashWatchdog },
                                set: { model.setCrashWatchdog($0) }
                            )
                        )
                        Divider()
                        SettingsCaption(text: "Installs a user LaunchAgent that stays idle at ~0% CPU and restores the system proxy within milliseconds if the app is force-quit.")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                }
            }
        }
    }
}

// MARK: - Monitoring

struct MonitoringSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsPage(title: SettingsSection.monitoring.title, summary: SettingsSection.monitoring.summary) {
            SettingsContent {
                SettingsGroup(title: "History") {
                    VStack(spacing: 0) {
                        SettingsRow {
                            Text("Retention: \(model.config.monitor.retentionDays) days")
                            Spacer()
                            Stepper(value: model.binding(\.monitor.retentionDays), in: 1...90) {
                                Text("Retention days")
                            }
                            .labelsHidden()
                        }
                        Divider()
                        SettingsToggleRow(title: "Record request paths", isOn: model.binding(\.monitor.recordPaths))
                        Divider()
                        SettingsCaption(text: "Host, size, and timing are always stored; bodies and headers are never stored.")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                }

                SettingsGroup(title: "Data") {
                    SettingsRow {
                        Button("Purge history now") { model.telemetry.purge() }
                        Spacer()
                    }
                }
            }
        }
    }
}

/// A three-way selector for where the app's icon appears. Each option is a
/// large clickable card with a mini "screen" mock showing the icon's location.
private struct AppIconModePicker: View {
    @Binding var mode: AppIconMode

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppIconMode.allCases) { option in
                AppIconModeCard(mode: option, isSelected: mode == option) {
                    mode = option
                }
            }
        }
    }
}

private struct AppIconModeCard: View {
    let mode: AppIconMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                IconPlacementSample(mode: mode)
                    .frame(height: 68)
                HStack(spacing: 5) {
                    Text(mode.label)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12)
                                     : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

/// A tiny "screen" mock: a menu bar strip on top and a Dock strip on the
/// bottom, with the app icon shown in whichever location `mode` enables.
private struct IconPlacementSample: View {
    let mode: AppIconMode

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                HStack {
                    Spacer()
                    Image(systemName: "circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                        .opacity(mode.showsMenuBarIcon ? 1 : 0)
                }
                .padding(.trailing, 7)
            }
            .frame(height: 16)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)

            Spacer(minLength: 0)

            ZStack {
                Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 22)
                    .opacity(mode.showsDockIcon ? 1 : 0)
            }
            .frame(height: 26)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

/// A small inline sample of the menu-bar icon, shown inside the picker options.
private struct MenuIconSample: View {
    let colorized: Bool

    var body: some View {
        HStack(spacing: 3) {
            if colorized {
                dot(.green)
                dot(.yellow)
                dot(.orange)
                dot(.red)
            } else {
                Image(systemName: "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        SettingsPage(title: SettingsSection.about.title, summary: SettingsSection.about.summary) {
            VStack(alignment: .leading, spacing: 20) {
                versionSection
                Divider()
                flowSection
                Divider()
                conceptsSection
                Divider()
                privacySection
                Divider()
                creditsSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    // MARK: Version

    private var versionSection: some View {
        HStack(spacing: 6) {
            Text("Version")
                .font(.callout.weight(.semibold))
            Text(UpdaterController.displayVersionWithDate)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Flow diagram

    private var flowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The flow")
                .font(.headline)

            VStack(spacing: 0) {
                FlowBox("Your apps", detail: "browser · terminal · system", tint: .blue)
                flowArrow
                FlowBox("Local proxy", detail: "127.0.0.1:8888", tint: .accentColor)
                flowArrow
                FlowBox("Is the host in your list?")

                HStack(alignment: .top, spacing: 48) {
                    branch(label: "Yes", tint: .green, turn: "arrow.turn.left.down",
                           top: "SOCKS5 tunnel", bottom: "Remote server")
                    branch(label: "No", tint: .gray, turn: "arrow.turn.right.down",
                           top: "Direct connection", bottom: "Internet")
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func branch(label: String, tint: Color, turn: String, top: String, bottom: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: turn)
                .foregroundStyle(tint)
                .padding(.vertical, 3)
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(tint)
            flowArrow
            FlowBox(top, tint: tint)
            flowArrow
            FlowBox(bottom, tint: tint)
        }
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.down")
            .foregroundStyle(.secondary)
            .padding(.vertical, 3)
    }

    // MARK: Concepts

    private var conceptsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The concepts")
                .font(.headline)

            concept("HTTP proxy", "A local middleman your apps talk to. It opens the real connection on their behalf.")
            concept("SOCKS5 proxy / tunnel", "A lower-level encrypted pipe — often created over SSH (`ssh -D`). Traffic you send in comes out on a remote server.")
            concept("Routing", "The app sends only the hostnames on your list through the tunnel; everything else goes direct.")
            concept("Fail open vs fail closed", "If the tunnel drops: fail open lets traffic go direct (nothing breaks); fail closed blocks the routed hosts until it returns.")
            concept("System proxy vs shell env", "Browsers and apps use the macOS system proxy. Terminal tools read HTTP_PROXY/HTTPS_PROXY. The app sets both.")
            concept("Manual vs managed tunnel", "Point the app at a tunnel you already run, or let it run an SSH tunnel for you.")
        }
    }

    private func concept(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .padding(.top, 6)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.bold())
                codeAwareText(text, baseFont: .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy")
                .font(.headline)

            privacyBullet("No MITM — TLS passes through untouched; the app never sees plaintext.")
            privacyBullet("Local-only — the proxy binds to 127.0.0.1.")
            privacyBullet("Only metadata is recorded (host, size, timing, status); never bodies or headers.")
            privacyBullet("The SSH password (if used) lives in the macOS Keychain, never in the config file.")
        }
    }

    private func privacyBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Credits

    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Credits")
                .font(.headline)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("100% vibe coded by chaim-chv, 2026.")
                        .font(.callout.bold())
                    Text("No responsibility is taken for anything this app does — but you're warmly invited to read the code and judge for yourself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("github.com/chaim-chv/proxy-manager", destination: URL(string: "https://github.com/chaim-chv/proxy-manager")!)
                        .font(.callout)
                }
            }
        }
    }
}

/// A small labeled box used in the About flow diagram.
private struct FlowBox: View {
    let text: String
    var detail: String?
    var tint: Color

    init(_ text: String, detail: String? = nil, tint: Color = .accentColor) {
        self.text = text
        self.detail = detail
        self.tint = tint
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(text)
                .font(.callout)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: 120)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.4), lineWidth: 1))
    }
}
