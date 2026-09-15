import AppKit
import SwiftUI

/// Set while a target rule is being edited inline, so the global Escape handler
/// (`AppDelegate`) leaves the key to the field (which cancels the edit) instead
/// of closing the Settings window.
enum InlineEditGuard { static var isActive = false }

struct TargetsView: View {
    @EnvironmentObject var model: AppModel

    @State private var newPatterns = ""
    @State private var previewHost = ""
    @State private var editingID: UUID?
    @State private var editPattern = ""
    @State private var highlightedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            addSection
            Divider()
            rulesList
            Divider()
            previewRow
        }
        .contentShape(Rectangle())
        .onTapGesture { cancelEdit() }
        .onChange(of: editingID) { _, newValue in
            InlineEditGuard.isActive = newValue != nil
        }
        .onAppear { reveal(model.revealTargetID) }
        .onChange(of: model.revealTargetID) { _, id in reveal(id) }
        .onDisappear { InlineEditGuard.isActive = false }
    }

    /// Consumes a reveal request: highlight the target and scroll it into view,
    /// then fade the highlight after a moment.
    private func reveal(_ id: UUID?) {
        guard let id else { return }
        highlightedID = id
        model.revealTargetID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if highlightedID == id { highlightedID = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Targets")
                    .font(.title2.bold())
                Text("Only these hostnames go through the tunnel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            presetsMenu
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var presetsMenu: some View {
        Menu {
            ForEach(TargetPreset.all) { preset in
                Button(preset.name) { model.applyPreset(preset) }
            }
            Divider()
            Button("Clear All", role: .destructive) { model.clearTargets() }
        } label: {
            Label("Presets", systemImage: "wand.and.stars")
        }
        .fixedSize()
        .help("Apply a ready-made allow-list, or clear all targets.")
    }

    // MARK: - Add section

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Add targets")
                    .font(.callout.bold())
                HelpPopover(
                    text: "Enter one or more hostnames. Separate them with line breaks, commas, or semicolons.",
                    example: "*.openai.com\nchatgpt.com, *.claude.ai; api.deepseek.com")
                Spacer()
                Button("Add") { addRules() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedNewPatterns.isEmpty)
            }

            TextEditor(text: $newPatterns)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35))
                )
                .overlay(alignment: .topLeading) {
                    if newPatterns.isEmpty {
                        Text("*.example.com\napi.example.com, example.org")
                            .font(.body.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: - Rules list

    private var rulesList: some View {
        ScrollViewReader { proxy in
            List {
                if model.config.targets.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No targets yet")
                            .font(.callout)
                        Text("Hosts will go direct. Add a rule above or apply a preset.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach($model.config.targets) { $rule in
                    TargetRuleRow(
                        rule: $rule,
                        isEditing: editingID == rule.id,
                        isHighlighted: highlightedID == rule.id,
                        editPattern: $editPattern,
                        onBeginEdit: { beginEdit(rule) },
                        onCommit: { commitEdit() },
                        onCancel: { cancelEdit() }
                    )
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 120, maxHeight: .infinity)
            .onChange(of: highlightedID) { _, id in
                if let id {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    // MARK: - Match preview

    private var previewRow: some View {
        HStack(spacing: 8) {
            Text("Match preview:")
                .foregroundStyle(.secondary)
            TextField("type a hostname", text: $previewHost)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Text(previewResult)
                .font(.callout.monospacedDigit())
                .foregroundStyle(previewColor)
            Spacer()
            HelpPopover(
                text: "A wildcard like *.example.com matches the apex domain and any subdomain. An exact name matches only itself.",
                example: "*.example.com → example.com, api.example.com, a.b.example.com")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var previewResult: String {
        let host = previewHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return "—" }
        if let rule = model.proxyServer.routingEngine.matchingRule(for: host) {
            return "TUNNEL · \(rule.pattern)"
        }
        return "DIRECT"
    }

    private var previewColor: Color {
        previewResult.hasPrefix("TUNNEL") ? .green : .secondary
    }

    // MARK: - Actions

    /// Splits the bulk input on line breaks, commas, or semicolons.
    private var parsedNewPatterns: [String] {
        newPatterns
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func addRules() {
        var existing = Set(model.config.targets.map { $0.pattern.lowercased() })
        for pattern in parsedNewPatterns {
            let key = pattern.lowercased()
            guard !existing.contains(key) else { continue }
            model.config.targets.append(TargetRule(pattern: pattern))
            existing.insert(key)
        }
        model.commitConfig()
        newPatterns = ""
    }

    private func beginEdit(_ rule: TargetRule) {
        editPattern = rule.pattern
        editingID = rule.id
    }

    private func commitEdit() {
        guard let id = editingID,
              let index = model.config.targets.firstIndex(where: { $0.id == id }) else {
            cancelEdit()
            return
        }
        let pattern = editPattern.trimmingCharacters(in: .whitespaces)
        if !pattern.isEmpty {
            model.config.targets[index].pattern = pattern
            model.commitConfig()
        }
        editingID = nil
    }

    private func cancelEdit() {
        editingID = nil
    }
}

/// A single target rule row. Double-click the pattern (or click the pencil next
/// to the toggle) to edit it inline: Return saves, Esc cancels.
private struct TargetRuleRow: View {
    @EnvironmentObject var model: AppModel

    @Binding var rule: TargetRule
    let isEditing: Bool
    let isHighlighted: Bool
    @Binding var editPattern: String
    let onBeginEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var editFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { value in
                    rule.enabled = value
                    model.commitConfig()
                }
            ))
            .labelsHidden()

            Button { onBeginEdit() } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            .disabled(isEditing)

            if isEditing {
                TextField("Domain (e.g. *.openai.com)", text: $editPattern)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.accentColor.opacity(0.5))
                    )
                    .focused($editFocused)
                    .onAppear { editFocused = true }
                    .onSubmit { onCommit() }
                    .onExitCommand { onCancel() }
                    .frame(maxWidth: 320)

                Button { onCommit() } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.green)
                .help("Save (Return)")

                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel (Esc)")
            } else {
                Text(rule.pattern)
                    .font(.callout)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onBeginEdit() }
                    .help("Double-click to edit")
            }

            Spacer()

            Button {
                model.config.targets.removeAll { $0.id == rule.id }
                model.commitConfig()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isEditing { onCancel() } }
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
    }
}
