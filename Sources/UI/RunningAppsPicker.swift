import AppKit
import SwiftUI
import CoreGraphics

/// One running app (or bundle-less process) offered by the picker.
struct RunningAppItem: Identifiable {
    enum Section: String, CaseIterable, Identifiable {
        case windowed = "With Windows"
        case running = "Running"
        case menuBar = "Menu Bar"
        case cli = "Command-line tools"
        case background = "System & Background"
        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .windowed: return "Apps showing a window right now."
            case .running: return "Dock apps that are running but have no open window."
            case .menuBar: return "Menu-bar apps and agents with no Dock icon."
            case .cli: return "Processes without an app bundle, matched by executable name."
            case .background: return "System agents and background services."
            }
        }
    }

    let id: String
    let section: Section
    let name: String
    let key: String
    let keyKind: AppRuleKeyKind
    let bundleId: String?
    let path: String?
    let icon: NSImage?
}

/// A large, searchable, categorized running-apps picker (sheet).
///
/// Unlike InputSourcePro (which shows only `activationPolicy == .regular` apps
/// plus a hardcoded floating-app list), this categorizes by activation policy
/// *and* whether the app currently has an on-screen window
/// (`CGWindowListCopyWindowInfo`). That needs no Screen Recording permission for
/// the metadata we read (PID/layer/bounds/alpha). The scan runs once, off the
/// main thread, when the sheet opens. Clicking a row adds its rule; clicking it
/// again removes it.
struct RunningAppsPickerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var items: [RunningAppItem] = []
    @State private var loading = true
    @State private var query = ""
    @State private var showBackground = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 540, height: 600)
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Add Running Apps")
                .font(.headline)
            HelpPopover(
                text: "Running apps are grouped by how they run. “With Windows” are the ones you're using right now; the rest run in the background. Click an app to add its rule, and click it again to remove it.",
                example: "Chrome → Tunnel all, Dropbox → Direct all")
            Spacer()
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(12)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if loading {
            VStack {
                ProgressView()
                Text("Looking for running apps…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            Text("No running apps found")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(RunningAppItem.Section.allCases) { section in
                        sectionBlock(section)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private func sectionBlock(_ section: RunningAppItem.Section) -> some View {
        let list = items(in: section)
        // While searching, hide categories with no matches; otherwise show every
        // category (greyed when empty) so the taxonomy is discoverable.
        if query.isEmpty || !list.isEmpty {
            if section == .background {
                backgroundBlock(list)
            } else {
                sectionHeader(section, count: list.count)
                if list.isEmpty {
                    emptyRow
                } else {
                    ForEach(list) { item in row(item) }
                }
            }
        }
    }

    private func sectionHeader(_ section: RunningAppItem.Section, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(section.rawValue)
                .font(.caption.weight(.semibold))
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .foregroundStyle(count == 0 ? .tertiary : .secondary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(section.explanation)
    }

    @ViewBuilder private func backgroundBlock(_ list: [RunningAppItem]) -> some View {
        let expanded = showBackground || !query.isEmpty
        VStack(alignment: .leading, spacing: 2) {
            Button {
                showBackground.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(RunningAppItem.Section.background.rawValue)
                        .font(.caption.weight(.semibold))
                    Text("\(list.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .foregroundStyle(list.isEmpty ? .tertiary : .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(RunningAppItem.Section.background.explanation + " Click to expand.")

            if expanded {
                if list.isEmpty {
                    emptyRow
                } else {
                    ForEach(list) { item in row(item) }
                }
            }
        }
    }

    private var emptyRow: some View {
        Text("None")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: RunningAppItem) -> some View {
        RunningAppRow(item: item, configured: isConfigured(item)) { toggle(item) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Choose App…") { chooseApp() }
            Button("Add Executable…") { chooseExecutable() }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Data

    private func items(in section: RunningAppItem.Section) -> [RunningAppItem] {
        let list = query.isEmpty ? items : items.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.key.localizedCaseInsensitiveContains(query)
        }
        return list.filter { $0.section == section }
    }

    private func isConfigured(_ item: RunningAppItem) -> Bool {
        model.appRule(forKey: item.key, keyKind: item.keyKind) != nil
    }

    private func toggle(_ item: RunningAppItem) {
        if let rule = model.appRule(forKey: item.key, keyKind: item.keyKind) {
            model.removeAppRule(id: rule.id)
        } else {
            model.addAppRule(key: item.key, keyKind: item.keyKind, mode: .tunnel)
        }
    }

    @MainActor private func load() async {
        let apps = NSWorkspace.shared.runningApplications
        let windowPIDs = await Task.detached(priority: .userInitiated) {
            Self.onScreenPIDs()
        }.value
        items = Self.buildItems(apps: apps, windowPIDs: windowPIDs,
                                selfBundleId: Bundle.main.bundleIdentifier)
        loading = false
    }

    /// PIDs that own at least one real on-screen window. Metadata only — no
    /// Screen Recording permission required.
    nonisolated static func onScreenPIDs() -> Set<pid_t> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var pids = Set<pid_t>()
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0 else { continue }
            if let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.01 { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width >= 40, rect.height >= 40 else { continue }
            pids.insert(pid)
        }
        return pids
    }

    nonisolated static func buildItems(apps: [NSRunningApplication], windowPIDs: Set<pid_t>,
                                       selfBundleId: String?) -> [RunningAppItem] {
        var byKey: [String: RunningAppItem] = [:]
        for app in apps {
            if app.isTerminated { continue }
            let bundleId = app.bundleIdentifier
            if let bundleId, bundleId == selfBundleId { continue }
            // Skip helpers/XPC services nested inside another app bundle.
            if let path = app.bundleURL?.path, path.contains(".app/Contents/") { continue }

            let key: String
            let keyKind: AppRuleKeyKind
            if let bundleId, !bundleId.isEmpty {
                key = bundleId
                keyKind = .bundle
            } else if let name = app.executableURL?.lastPathComponent, !name.isEmpty {
                key = name
                keyKind = .executableName
            } else {
                continue
            }
            if byKey[key] != nil { continue }

            let policy = app.activationPolicy
            let hasWindow = windowPIDs.contains(app.processIdentifier)
            let isSystem = (app.bundleURL?.path ?? "").hasPrefix("/System/")
            let section: RunningAppItem.Section
            if bundleId == nil {
                section = .cli
            } else if policy == .prohibited {
                section = .background
            } else if policy == .accessory {
                section = isSystem ? .background : .menuBar
            } else if hasWindow {
                section = .windowed
            } else {
                section = .running
            }

            let path = app.bundleURL?.path
            byKey[key] = RunningAppItem(
                id: key, section: section,
                name: app.localizedName ?? bundleId ?? key,
                key: key, keyKind: keyKind,
                bundleId: bundleId, path: path,
                icon: AppIcon.image(bundleId: bundleId, path: path))
        }
        return byKey.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Escape hatches

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleId = Bundle(url: url)?.bundleIdentifier {
                model.addAppRule(key: bundleId, keyKind: .bundle, mode: .tunnel)
            }
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.unixExecutable]
        panel.allowsOtherFileTypes = true
        panel.message = "Select an executable file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addAppRule(key: url.path, keyKind: .executable, mode: .tunnel)
    }
}

/// A picker row: medium icon, name + key, and a checkmark when a rule exists.
/// Clicking toggles the rule (add ↔ remove).
private struct RunningAppRow: View {
    let item: RunningAppItem
    let configured: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(item.key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if configured {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(configured ? "Remove the rule for \(item.key)" : "Add \(item.name) — \(item.key)")
    }

    @ViewBuilder private var icon: some View {
        if let image = item.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .font(.title2)
                .foregroundStyle(.tertiary)
        }
    }
}
