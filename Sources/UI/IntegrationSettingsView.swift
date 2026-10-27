import SwiftUI

/// Settings → Integration.
///
/// This pane only exposes the control-plane switches and the per-identity
/// grants. It deliberately has no action editor: the actions are documented in
/// `docs/integration.md` and discovered by clients through `capabilities`.
struct IntegrationSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var permissions: [IntegrationPermission] = []

    private var coordinator: IntegrationCoordinator { model.integration }

    var body: some View {
        SettingsPage(title: SettingsSection.integration.title,
                     summary: SettingsSection.integration.summary) {
            SettingsContent {
                SettingsGroup(
                    title: "External control",
                    help: "Off by default. When on, another app can ask Proxy Manager to toggle routing, edit targets or per-app rules, read status, or open a window. Every app is approved once, and nothing can ever raise an administrator prompt."
                ) {
                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: "Allow external control",
                            help: "The master switch. Turning it off stops the local control socket, unregisters the XPC agent, and makes the URL scheme and Shortcuts refuse to run. Existing app approvals are kept, so turning it back on does not re-prompt.",
                            isOn: model.binding(\.integration.enabled)
                        )
                        Divider()
                        SettingsToggleRow(
                            title: "Apps and CLI (XPC)",
                            help: "Registers a per-user launch agent that exposes the com.proxymanager.control Mach service. Needs a Developer-ID signed build; an ad-hoc build can still use the local socket for development.",
                            isOn: model.binding(\.integration.xpcEnabled)
                        )
                        .disabled(!model.config.integration.enabled)
                        Divider()
                        SettingsToggleRow(
                            title: "URL links (proxymanager://)",
                            help: "Lets any link or script run `open proxymanager://v1/routing/toggle`, open a pane, and similar. A URL is unauthenticated, so it can only reach routing and window actions — never targets, app rules or tunnel settings.",
                            isOn: model.binding(\.integration.urlSchemeEnabled)
                        )
                        .disabled(!model.config.integration.enabled)
                        Divider()
                        SettingsToggleRow(
                            title: "Shortcuts and Siri",
                            help: "Makes the App Intents available in Shortcuts, Siri and Spotlight. They run in the app and go through the same checks as the other transports.",
                            isOn: model.binding(\.integration.intentsEnabled)
                        )
                        .disabled(!model.config.integration.enabled)
                        Divider()
                        SettingsToggleRow(
                            title: "Keep an audit log",
                            help: "Writes one line per request to integration-audit.jsonl (0600) next to the config: caller, action, arguments, outcome and duration. Arguments that look like secrets are redacted.",
                            isOn: model.binding(\.integration.auditEnabled)
                        )
                        .disabled(!model.config.integration.enabled)
                    }
                }

                SettingsGroup(
                    title: "Status",
                    help: "The local socket is what the agent relays to. It only accepts the same user and a per-launch token."
                ) {
                    VStack(spacing: 0) {
                        agentStatusRow
                        Divider()
                        SettingsRow {
                            Text("Local control socket")
                            Spacer()
                            Text(coordinator.isRunning ? "Running" : "Stopped")
                                .foregroundStyle(coordinator.isRunning ? .green : .secondary)
                        }
                    }
                }

                SettingsGroup(
                    title: "Approved apps",
                    help: "Approvals are keyed by the app's code-signing designated requirement, so a different binary claiming the same bundle identifier must ask again. Revoking takes effect immediately."
                ) {
                    if permissions.isEmpty {
                        SettingsRow {
                            SettingsCaption(text: "No app has asked for control yet.")
                            Spacer()
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(permissions, id: \.key) { permission in
                                SettingsRow {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(permission.displayName)
                                        SettingsCaption(text: detail(for: permission))
                                    }
                                    Spacer()
                                    Button("Revoke") {
                                        coordinator.revoke(permission.key)
                                        permissions = coordinator.permissionsSnapshot
                                    }
                                }
                                if permission.key != permissions.last?.key { Divider() }
                            }
                        }
                    }
                }

                SettingsGroup(
                    title: "What can be controlled",
                    help: nil
                ) {
                    SettingsRow {
                        SettingsCaption(text: "Only routing on/off, targets, per-app rules, status reads, and opening a window or pane. The tunnel, the local proxy, system integration, appearance and monitoring are never exposed to external callers.")
                        Spacer()
                    }
                }
            }
        }
        .onAppear { permissions = coordinator.permissionsSnapshot }
        .onChange(of: model.config.integration) { _, _ in
            permissions = coordinator.permissionsSnapshot
        }
    }

    @ViewBuilder private var agentStatusRow: some View {
        switch coordinator.agentState {
        case .disabled:
            statusRow(
                icon: "pause.circle",
                tint: .secondary,
                title: "XPC agent off",
                detail: "Turn on external control to register it."
            )
        case .ready:
            statusRow(
                icon: "checkmark.seal.fill",
                tint: .green,
                title: "XPC agent registered",
                detail: "Apps connect through com.proxymanager.control."
            )
        case .unavailable(let reason):
            statusRow(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "XPC agent unavailable",
                detail: reason
            )
        }
    }

    private func statusRow(icon: String, tint: Color,
                           title: String, detail: String) -> some View {
        SettingsRow {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                SettingsCaption(text: detail)
            }
            Spacer()
        }
    }

    private func detail(for permission: IntegrationPermission) -> String {
        let identity = permission.bundleID ?? permission.path ?? "unsigned"
        let scope = permission.scope == .control ? "Control" : "Read only"
        return "\(identity) · \(scope)"
    }
}
