import SwiftUI

/// First-run onboarding: a short, plain-language walk-through that configures
/// the two things a new user must know — their SOCKS5 tunnel address and which
/// hosts to route through it — then gets them running. Re-openable from
/// Settings → General.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    @State private var step = 0
    @State private var tunnelHost: String
    @State private var tunnelPortText: String
    @State private var testState: TestState = .idle
    @State private var targetChoice: TargetChoice
    @State private var launchAtLogin = false
    @State private var injectShellEnv = true
    @State private var enableNow = true

    // Managed ("run the tunnel for me") fields.
    @State private var tunnelMode: TunnelMode
    @State private var sshHost: String
    @State private var sshPortText: String
    @State private var sshUser: String
    @State private var auth: SSHAuthMethod
    @State private var keyPath: String
    @State private var sshPassword: String
    @State private var socksHost: String
    @State private var socksPortText: String

    init() {
        let cfg = AppModel.shared.config
        _tunnelHost = State(initialValue: cfg.tunnel.host)
        _tunnelPortText = State(initialValue: String(cfg.tunnel.port))
        // Respect an existing target list: offer to keep it instead of
        // silently overwriting it with a preset or an empty list.
        _targetChoice = State(initialValue: cfg.targets.isEmpty ? .empty : .keepExisting)
        _launchAtLogin = State(initialValue: cfg.system.launchAtLogin)
        _injectShellEnv = State(initialValue: cfg.system.injectShellEnv)

        _tunnelMode = State(initialValue: cfg.tunnel.mode)
        _sshHost = State(initialValue: cfg.tunnel.managed.sshHost)
        _sshPortText = State(initialValue: String(cfg.tunnel.managed.sshPort))
        _sshUser = State(initialValue: cfg.tunnel.managed.username)
        _auth = State(initialValue: cfg.tunnel.managed.auth)
        _keyPath = State(initialValue: cfg.tunnel.managed.keyPath)
        _sshPassword = State(initialValue: DemoMode.isEnabled ? "" : AppModel.shared.loadManagedPassword())
        _socksHost = State(initialValue: cfg.tunnel.managed.socksHost)
        _socksPortText = State(initialValue: String(cfg.tunnel.managed.socksPort))
        #if SCREENSHOT_MODE
        if DemoMode.isEnabled { _step = State(initialValue: DemoMode.onboardingStep) }
        #endif
    }

    private enum TestState {
        case idle, testing, ok, fail
    }

    private enum TargetChoice: Equatable {
        case keepExisting
        case empty
        case preset(String)
    }

    private let steps = ["Welcome", "Tunnel", "Targets", "Done"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForEach(steps.indices, id: \.self) { i in
                    stepDot(index: i)
                    if i < steps.count - 1 { Spacer() }
                }
            }
            Text(title)
                .font(.title2.bold())
        }
        .padding(20)
    }

    private func stepDot(index: Int) -> some View {
        VStack(spacing: 4) {
            Text(steps[index])
                .font(.caption)
                .foregroundStyle(index <= step ? Color.accentColor : Color.secondary)
            RoundedRectangle(cornerRadius: 2)
                .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(height: 3)
        }
    }

    private var title: String {
        switch step {
        case 0: return "Welcome to Proxy Manager"
        case 1: return "Point to your tunnel"
        case 2: return "Choose what to route"
        default: return "You're all set"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: tunnel
        case 2: targets
        default: finishStep
        }
    }

    // MARK: - Step 1: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proxy Manager is a tiny router on your Mac. It sends only the sites you choose through a proxy or tunnel, and leaves everything else untouched.")
            Text("Three concepts, in plain words:")
            concept(title: "HTTP proxy", text: "A middleman your apps talk to locally. It opens the real connection for them. This app runs one at 127.0.0.1 on a local port.")
            concept(title: "SOCKS5 proxy / tunnel", text: "A lower-level pipe, often created over SSH (e.g. `ssh -D`). Traffic you send into it comes out on a remote server — useful to reach sites through another network.")
            concept(title: "What this app does", text: "It connects your apps to the SOCKS5 tunnel, but only for the hostnames you add to the list.")
            Text("No encryption keys or passwords are stored. TLS passes through untouched — this is routing, not spying.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func concept(title: String, text: String) -> some View {
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

    // MARK: - Step 2: Tunnel

    private var tunnel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your selected traffic needs an encrypted pipe to a remote machine. You can use a tunnel you already run, or let the app run one over SSH for you.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("", selection: $tunnelMode) {
                Text("I already have a tunnel").tag(TunnelMode.manual)
                Text("Run the tunnel for me").tag(TunnelMode.managed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tunnelMode == .managed {
                managedTunnelFields
            } else {
                manualTunnelFields
            }
        }
    }

    private var manualTunnelFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the address of your existing SOCKS5 tunnel. If you made one with `ssh -D`, it's usually 127.0.0.1 and the port you chose.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Host", text: $tunnelHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                TextField("Port", text: $tunnelPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Button(testButtonTitle) { test() }
                    .disabled(testState == .testing)
                if case .ok = testState { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                if case .fail = testState { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            }

            if case .fail = testState {
                Text("Couldn't reach that address. Make sure the tunnel is running and the host/port are right.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text("Example: `ssh -D 1080 user@yourserver.com` creates a SOCKS5 tunnel on 127.0.0.1:1080. You don't need the app to create it — just point it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var managedTunnelFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The app will run and supervise an SSH SOCKS5 tunnel for you — no manual `ssh` needed.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                TextField("SSH host (IP or address)", text: $sshHost)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $sshPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                TextField("Username", text: $sshUser)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }

            Picker("Authentication", selection: $auth) {
                Text("Key file").tag(SSHAuthMethod.key)
                Text("Password").tag(SSHAuthMethod.password)
            }
            .pickerStyle(.radioGroup)

            if auth == .key {
                HStack {
                    TextField("Private key path", text: $keyPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") {
                        if let path = KeyFilePicker.chooseKeyFile() {
                            keyPath = path
                        }
                    }
                }
                Text("Use a passphrase-less key, or one already loaded in ssh-agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SecureField("Password", text: $sshPassword)
                    .textFieldStyle(.roundedBorder)
                Text("Stored securely in the macOS Keychain — never in the config file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("Local SOCKS bind host", text: $socksHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                TextField("Port", text: $socksPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
        }
    }

    private var testButtonTitle: String {
        switch testState {
        case .testing: return "Testing…"
        default: return "Test connection"
        }
    }

    private func test() {
        guard let port = UInt16(tunnelPortText) else {
            testState = .fail
            return
        }
        testState = .testing
        model.testTunnel(host: tunnelHost, port: port) { up in
            testState = up ? .ok : .fail
        }
    }

    // MARK: - Step 3: Targets

    private var targets: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a starting allow-list, or start empty. You can edit this any time in Settings → Targets, or route by app in Settings → Apps.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                if !model.config.targets.isEmpty {
                    keepExistingRow
                }
                ForEach(TargetPreset.all) { preset in
                    presetRow(preset)
                }
                emptyRow
            }
        }
    }

    private var keepExistingRow: some View {
        let selected = targetChoice == .keepExisting
        return HStack(alignment: .top) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep my current list").font(.callout.bold())
                Text("\(model.config.targets.count) target\(model.config.targets.count == 1 ? "" : "s") already configured — leave them as they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(selectionBackground(.keepExisting))
        .contentShape(Rectangle())
        .onTapGesture { targetChoice = .keepExisting }
    }

    private var emptyRow: some View {
        let selected = targetChoice == .empty
        return HStack {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Text("Start empty (add hosts manually)")
            Spacer()
        }
        .padding(8)
        .background(selectionBackground(.empty))
        .contentShape(Rectangle())
        .onTapGesture { targetChoice = .empty }
    }

    private func presetRow(_ preset: TargetPreset) -> some View {
        let selected = targetChoice == .preset(preset.id)
        return HStack(alignment: .top) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.callout.bold())
                Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                Text(preset.rules.map(\.pattern).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(8)
        .background(selectionBackground(.preset(preset.id)))
        .contentShape(Rectangle())
        .onTapGesture { targetChoice = .preset(preset.id) }
    }

    private func selectionBackground(_ choice: TargetChoice) -> Color {
        targetChoice == choice ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)
    }

    // MARK: - Step 4: Done

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable routing now", isOn: $enableNow)
            Toggle("Launch at login", isOn: $launchAtLogin)
            Toggle("Set proxy for terminal apps too (shell env)", isOn: $injectShellEnv)
            Text("Terminal apps read HTTP_PROXY/HTTPS_PROXY. Browsers and most apps use the macOS system proxy, which this app also sets while routing is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Want to route by app instead of by hostname? Open Settings → Apps any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { withAnimation { step -= 1 } }
            }
            Spacer()
            if step < steps.count - 1 {
                Button("Next") { withAnimation { step += 1 } }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Finish") { finishOnboarding() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func finishOnboarding() {
        configApply()
        model.completeOnboarding()
        if enableNow {
            model.enable()
        }
        OnboardingWindowController.shared.finish()
    }

    private func configApply() {
        model.config.tunnel.mode = tunnelMode
        if let port = UInt16(tunnelPortText) {
            model.config.tunnel.host = tunnelHost
            model.config.tunnel.port = port
        }
        if let sshPort = UInt16(sshPortText) {
            model.config.tunnel.managed.sshPort = sshPort
        }
        model.config.tunnel.managed.sshHost = sshHost.trimmingCharacters(in: .whitespaces)
        model.config.tunnel.managed.username = sshUser.trimmingCharacters(in: .whitespaces)
        model.config.tunnel.managed.auth = auth
        model.config.tunnel.managed.keyPath = keyPath.trimmingCharacters(in: .whitespaces)
        model.config.tunnel.managed.socksHost = socksHost.trimmingCharacters(in: .whitespaces)
        if let socksPort = UInt16(socksPortText) {
            model.config.tunnel.managed.socksPort = socksPort
        }
        if auth == .password {
            model.saveManagedPassword(sshPassword)
        }

        switch targetChoice {
        case .keepExisting:
            break
        case .empty:
            model.config.targets = []
        case .preset(let id):
            if let preset = TargetPreset.with(id: id) {
                model.config.targets = preset.rules
            }
        }
        if model.config.system.launchAtLogin != launchAtLogin {
            model.setLaunchAtLogin(launchAtLogin)
        }
        model.config.system.injectShellEnv = injectShellEnv
        model.commitConfig()
    }
}

/// Single-instance onboarding window (mirrors `DashboardWindowController`).
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private(set) var window: NSWindow?
    private var didFinish = false

    func show() {
        didFinish = false
        if window == nil {
            let view = OnboardingView().environmentObject(AppModel.shared)
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Welcome to Proxy Manager"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Completed via the "Finish" button (as opposed to dismissed).
    func finish() {
        didFinish = true
        close()
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // Dismissing (Esc / close button) marks onboarding as seen so it doesn't
        // nag again, and drops the user into Settings to continue configuring.
        if !didFinish {
            AppModel.shared.completeOnboarding()
            StatusMenuController.shared.openSettings()
        }
    }
}
