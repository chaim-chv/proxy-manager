import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Resolves a rule's display name and icon from its key.
enum AppDisplay {
    static func url(for rule: AppRule) -> URL? {
        switch rule.keyKind {
        case .bundle:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.key)
        case .executable:
            return URL(fileURLWithPath: rule.key)
        case .executableName:
            return nil
        }
    }

    static func name(for rule: AppRule) -> String {
        switch rule.keyKind {
        case .bundle:
            if let url = url(for: rule), let info = Bundle(url: url)?.infoDictionary {
                if let name = info["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
                if let name = info["CFBundleName"] as? String, !name.isEmpty { return name }
            }
            return rule.key
        case .executable:
            return (rule.key as NSString).lastPathComponent
        case .executableName:
            return rule.key
        }
    }

    static func icon(for rule: AppRule) -> NSImage? {
        guard let url = url(for: rule), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Settings → Apps: per-app routing rules. A left list of configured apps and a
/// right detail pane (the InputSourcePro/LinearMouse pattern), plus the default
/// mode applied to apps with no rule.
struct AppsSettingsView: View {
    @EnvironmentObject var model: AppModel

    @State private var selection: UUID?
    @State private var showRunningApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            defaultModeRow
            Divider()
            HStack(spacing: 0) {
                ruleList
                    .frame(width: 300)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { reveal(model.revealAppRuleID) }
        .onChange(of: model.revealAppRuleID) { _, id in reveal(id) }
        .sheet(isPresented: $showRunningApps) {
            RunningAppsPickerSheet()
                .environmentObject(model)
        }
    }

    private func reveal(_ id: UUID?) {
        guard let id else { return }
        selection = id
        model.revealAppRuleID = nil
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Apps")
                    .font(.title2.bold())
                Text("Route each app's traffic — through the tunnel, by the target rules, or direct.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Text("Route by app")
                HelpPopover(
                    text: "When on, the proxy identifies the app that opened each connection and applies its rule. Off by default — nothing is scanned or changed until you turn it on.",
                    example: "Chrome → Tunnel all, Dropbox → Direct all")
                Toggle("", isOn: Binding(
                    get: { model.config.apps.enabled },
                    set: { model.config.apps.enabled = $0; model.commitConfig() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Default mode

    private var defaultModeRow: some View {
        HStack(spacing: 10) {
            Text("Apps with no rule")
                .font(.callout)
            HelpPopover(
                text: "What to do for an app that has no rule of its own. “Use target rules” keeps today's hostname behaviour; “Direct all” makes only apps you list use the tunnel.",
                example: "Only Chrome tunnels → set this to Direct all and add Chrome → Tunnel all")
            Picker("", selection: Binding(
                get: { model.config.apps.defaultMode },
                set: { model.config.apps.defaultMode = $0; model.commitConfig() }
            )) {
                ForEach(AppRoutingMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Rule list

    private var ruleList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    Button("Choose App…") { chooseApps() }
                    Button("Add Running Apps…") { showRunningApps = true }
                    Divider()
                    Button("Add Executable…") { chooseExecutable() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .fixedSize()

                Button {
                    if let id = selection { model.removeAppRule(id: id); selection = nil }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Remove the selected app")

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if model.config.apps.rules.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No apps yet")
                        .font(.callout)
                    Text("Add an app to route its traffic.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(selection: $selection) {
                    ForEach($model.config.apps.rules) { $rule in
                        AppRuleRow(rule: $rule)
                            .tag(rule.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func select(_ id: UUID?) {
        if let id { selection = id }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let id = selection,
           let index = model.config.apps.rules.firstIndex(where: { $0.id == id }) {
            AppRuleDetail(rule: $model.config.apps.rules[index]) {
                model.removeAppRule(id: id)
                selection = nil
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Select an app to set its routing")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Add actions

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        var lastID: UUID?
        for url in panel.urls {
            if let bundleId = Bundle(url: url)?.bundleIdentifier {
                lastID = model.addAppRule(key: bundleId, keyKind: .bundle, mode: .tunnel) ?? lastID
            }
        }
        select(lastID)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.unixExecutable]
        panel.allowsOtherFileTypes = true
        panel.message = "Select an executable file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(model.addAppRule(key: url.path, keyKind: .executable, mode: .tunnel))
    }
}

/// One row in the Apps list: enable toggle, icon, name + key, and a mode chip.
private struct AppRuleRow: View {
    @EnvironmentObject var model: AppModel

    @Binding var rule: AppRule

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { rule.enabled = $0; model.commitConfig() }
            ))
            .labelsHidden()

            icon
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(AppDisplay.name(for: rule))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rule.key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            ModeChip(mode: rule.mode)
        }
        .padding(.vertical, 1)
        .opacity(rule.enabled ? 1 : 0.5)
        .help(rule.key)
    }

    @ViewBuilder private var icon: some View {
        if let image = AppDisplay.icon(for: rule) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: rule.keyKind == .bundle ? "app.dashed" : "terminal")
                .foregroundStyle(.secondary)
        }
    }
}

/// Right-hand detail for the selected rule.
private struct AppRuleDetail: View {
    @EnvironmentObject var model: AppModel

    @Binding var rule: AppRule
    let onRemove: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    icon
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppDisplay.name(for: rule))
                            .font(.title3.bold())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(rule.key)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Routing")
                        .font(.callout.weight(.semibold))
                    Picker("", selection: Binding(
                        get: { rule.mode },
                        set: { rule.mode = $0; model.commitConfig() }
                    )) {
                        ForEach(AppRoutingMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(modeExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Enabled", isOn: Binding(
                    get: { rule.enabled },
                    set: { rule.enabled = $0; model.commitConfig() }
                ))
                .toggleStyle(.switch)

                Divider()

                HStack {
                    Text(rule.keyKind.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive, action: onRemove)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var icon: some View {
        if let image = AppDisplay.icon(for: rule) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: rule.keyKind == .bundle ? "app.dashed" : "terminal")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }

    private var modeExplanation: String {
        switch rule.mode {
        case .tunnel: return "Every request from this app goes through the tunnel, whatever the host."
        case .targets: return "This app follows the hostname allow-list on the Targets page."
        case .direct: return "Every request from this app goes direct, even for allow-listed hosts."
        }
    }
}

/// Small colored chip showing a rule's mode.
private struct ModeChip: View {
    let mode: AppRoutingMode

    var body: some View {
        Text(shortLabel)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private var shortLabel: String {
        switch mode {
        case .tunnel: return "TUNNEL"
        case .targets: return "TARGETS"
        case .direct: return "DIRECT"
        }
    }

    private var color: Color {
        switch mode {
        case .tunnel: return .green
        case .targets: return .accentColor
        case .direct: return .secondary
        }
    }
}
