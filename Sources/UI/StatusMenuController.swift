import AppKit
import Combine

/// Width shared by the custom-view menu rows.
private let statusMenuWidth: CGFloat = 250

/// Native macOS menu-bar menu (an `NSStatusItem` + `NSMenu`), replacing the
/// SwiftUI `.menu` MenuBarExtra.
///
/// A `.menu`-style SwiftUI extra cannot tint custom status rows or show native
/// key equivalents, so the menu is built in AppKit. Interactive rows are plain
/// `NSMenuItem`s so they get the native hover highlight and native checkmark;
/// only the inert status/error rows are custom views (for colored dots):
///
///   ● Routing   On / Off / Degraded / Starting… / Stopping…   (status)
///   ● Tunnel    Up / Down                                     (status)
///   error line (red, only while `lastError` is set)
///   ─────────────
///   ✓ Routing                                                (plain item; ✓
///                                                            state = native
///                                                            checkmark; grayed
///                                                            while busy)
///   ✓ Launch at Login
///   Restart Tunnel                                           (supervised only)
///   ─────────────
///   Open Dashboard…   ⌘D
///   Settings…         ⌘,
///   About Proxy Manager
///   Quit Proxy Manager ⌘Q
///
/// Items are updated in place (never rebuilt) on model changes, so live state —
/// starting/stopping, tunnel flaps, errors — shows up even while the menu is
/// open. Key equivalents on the status menu are display hints; the actual ⌘Q /
/// ⌘, / ⌘D handling while the app is active comes from the SwiftUI main menu
/// (the `Settings` scene + `AppCommands`). Only a *click* on this menu's "Quit
/// Proxy Manager" row quits; ⌘Q closes the front window instead.
final class StatusMenuController: NSObject {
    static let shared = StatusMenuController()

    private let model = AppModel.shared
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var lastIconKey: String?

    // Custom status/error rows (updated in place; held strongly here, the menu
    // retains them via `item.view`) plus the plain toggle items we mutate.
    private let routingStatusRow = StatusRowView(title: "Routing")
    private let tunnelStatusRow = StatusRowView(title: "Tunnel")
    private let errorRowView = ErrorRowView()
    private var routingToggleItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var errorMenuItem: NSMenuItem?
    private var restartMenuItem: NSMenuItem?
    private var checkForUpdatesItem: NSMenuItem?

    private override init() {
        super.init()
        menu.autoenablesItems = false
        statusItem.menu = menu
        configureStatusButton()
        buildMenu()
        observe()
        refresh()
    }

    // MARK: - Setup

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.toolTip = "Proxy Manager"
        applyIcon(to: button)
    }

    private func buildMenu() {
        menu.addItem(viewItem(routingStatusRow))
        menu.addItem(viewItem(tunnelStatusRow))

        let errorItem = viewItem(errorRowView)
        errorItem.isHidden = true
        errorMenuItem = errorItem
        menu.addItem(errorItem)

        menu.addItem(.separator())

        let routing = NSMenuItem(title: "Routing", action: #selector(toggleRouting), keyEquivalent: "")
        routing.target = self
        routingToggleItem = routing
        menu.addItem(routing)

        let launchAtLogin = NSMenuItem(title: "Launch at Login",
                                       action: #selector(toggleLaunchAtLogin),
                                       keyEquivalent: "")
        launchAtLogin.target = self
        launchAtLoginItem = launchAtLogin
        menu.addItem(launchAtLogin)

        let restart = NSMenuItem(title: "Restart Tunnel",
                                 action: #selector(restartTunnel),
                                 keyEquivalent: "")
        restart.target = self
        restartMenuItem = restart
        menu.addItem(restart)

        menu.addItem(.separator())

        menu.addItem(navItem(title: "Open Dashboard…", key: "d", action: #selector(openDashboard)))
        menu.addItem(navItem(title: "Settings…", key: ",", action: #selector(openSettings)))
        menu.addItem(navItem(title: "About Proxy Manager", key: nil, action: #selector(showAbout)))

        // Sparkle's standard updater handles the whole flow; its target/action
        // also drives the enabled state via `canCheckForUpdates`.
        let checkForUpdates = NSMenuItem(title: "Check for Updates…",
                                         action: #selector(UpdaterController.checkForUpdates(_:)),
                                         keyEquivalent: "")
        checkForUpdates.target = UpdaterController.shared
        checkForUpdatesItem = checkForUpdates
        menu.addItem(checkForUpdates)

        menu.addItem(navItem(title: "Quit Proxy Manager", key: "q", action: #selector(quitApp)))
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func navItem(title: String, key: String?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key ?? "")
        item.target = self
        if key != nil {
            item.keyEquivalentModifierMask = [.command]
        }
        return item
    }

    private func observe() {
        let main = DispatchQueue.main
        model.$state.receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        model.$tunnelUp.receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        model.$lastError.receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        model.$config.receive(on: main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        UpdaterController.shared.$canCheckForUpdates.receive(on: main)
            .sink { [weak self] canCheck in
                self?.checkForUpdatesItem?.isEnabled = canCheck
            }
            .store(in: &cancellables)
    }

    // MARK: - Refresh

    private func refresh() {
        statusItem.isVisible = model.config.system.iconMode.showsMenuBarIcon
        applyIcon()
        let state = model.state
        routingStatusRow.update(dot: stateColor(state),
                                value: stateText(state),
                                valueColor: stateColor(state))
        tunnelStatusRow.update(dot: model.tunnelUp ? .systemGreen : .systemRed,
                               value: model.tunnelUp ? "Up" : "Down",
                               valueColor: model.tunnelUp ? .systemGreen : .systemRed)
        if let item = routingToggleItem {
            let busy = state == .starting || state == .stopping
            item.state = state.isActive ? .on : .off
            item.isEnabled = !busy
        }
        if let item = launchAtLoginItem {
            item.state = model.config.system.launchAtLogin ? .on : .off
        }
        if let error = model.lastError {
            errorRowView.update(text: error)
        }
        errorMenuItem?.isHidden = model.lastError == nil
        restartMenuItem?.isHidden = !model.config.tunnel.supervised
    }

    private func applyIcon() {
        guard let button = statusItem.button else { return }
        applyIcon(to: button)
    }

    private func applyIcon(to button: NSStatusBarButton) {
        let symbol: String
        switch model.state {
        case .off: symbol = "circle"
        case .on: symbol = "circle.fill"
        case .degraded: symbol = "exclamationmark.triangle.fill"
        case .starting, .stopping: symbol = "hourglass"
        }
        // `refresh()` runs on every `@Published` change (including each keystroke
        // in a Settings field via `$config`); only re-rasterize the SF Symbol
        // when the resulting image would actually differ.
        let colorize = model.config.system.colorizeMenuIcon
        let color = colorize ? iconColor() : nil
        let key = "\(symbol)|\(colorize)|\(color?.description ?? "")"
        if key == lastIconKey, button.image != nil { return }
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        lastIconKey = key
        if let color {
            // Recolor the symbol itself (non-template); `contentTintColor` does
            // not reliably color NSStatusItem template images.
            let colored = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
            colored?.isTemplate = false
            button.image = colored
        } else {
            base.isTemplate = true
            button.image = base
        }
        button.contentTintColor = nil
    }

    /// Status color for the colorized menu-bar icon. Off is neutral gray unless
    /// an error is present (red); starting/stopping is amber progress, on is
    /// green, degraded is orange.
    private func iconColor() -> NSColor {
        switch model.state {
        case .on: return .systemGreen
        case .degraded: return .systemOrange
        case .starting, .stopping: return .systemYellow
        case .off: return model.lastError == nil ? .systemGray : .systemRed
        }
    }

    private func stateText(_ state: AppState) -> String {
        switch state {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .on: return "On"
        case .degraded: return "Degraded"
        case .stopping: return "Stopping…"
        }
    }

    private func stateColor(_ state: AppState) -> NSColor {
        switch state {
        case .off: return .systemGray
        case .on: return .systemGreen
        case .degraded: return .systemOrange
        case .starting, .stopping: return .systemYellow
        }
    }

    // MARK: - Actions

    @objc private func openDashboard() {
        DashboardWindowController.shared.show()
    }

    @objc func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI registers the Settings scene's command as an NSMenuItem whose
        // action is `menuAction:` on a private callback — `sendAction(to: nil)`
        // for `showSettingsWindow:` does *not* open it. Fire the real item.
        guard let item = settingsMenuItem(), let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
        // Ensure it is key/front even if the SwiftUI action only orders front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.title.contains("Settings") }) {
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// The SwiftUI-generated "Settings…" command in the app menu.
    private func settingsMenuItem() -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            if let match = submenu.items.first(where: {
                $0.action != nil && ($0.title == "Settings…" || $0.title.hasPrefix("Settings"))
            }) {
                return match
            }
        }
        return nil
    }

    @objc private func toggleRouting() {
        model.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        model.setLaunchAtLogin(!model.config.system.launchAtLogin)
    }

    @objc private func showAbout() {
        presentAboutPanel()
    }

    /// Presents the standard About panel (also invoked by screenshot/demo builds).
    func presentAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        // The standard panel renders "Version <ApplicationVersion> (<Version>)".
        // Put the marketing version in `.applicationVersion` and the build date
        // in `.version` so the date appears once, in parentheses.
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: UpdaterController.displayVersion,
            .version: UpdaterController.buildDate ?? "",
            .credits: Self.aboutCredits
        ])
    }

    /// The standard About panel has no homepage field, so the homepage and
    /// source links live in the credits text as clickable links.
    private static var aboutCredits: NSAttributedString {
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let label: [NSAttributedString.Key: Any] = [
            .font: small,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let result = NSMutableAttributedString()
        func append(_ prefix: String, _ title: String, _ url: URL) {
            result.append(NSAttributedString(string: prefix, attributes: label))
            result.append(NSAttributedString(string: title, attributes: [.font: small, .link: url]))
        }
        append("Homepage  ", "chaim-chv.github.io/proxy-manager", AppLinks.homepage)
        result.append(NSAttributedString(string: "\n", attributes: label))
        append("Source  ", "github.com/chaim-chv/proxy-manager", AppLinks.source)
        return result
    }

    @objc private func quitApp() {
        model.quitApp()
    }

    @objc private func restartTunnel() {
        model.restartTunnel()
    }
}

// MARK: - Custom menu row views

/// Base for inert custom-view menu rows (status/error indicators). The whole
/// row acts as one hit target that swallows the click, so a click never falls
/// through to the NSMenu tracking loop (which would close the menu).
private class MenuRowView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
}

/// A colored circular dot used as a status indicator.
private final class DotView: NSView {
    var color: NSColor = .systemGray {
        didSet { layer?.backgroundColor = color.cgColor }
    }

    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        self.color = color
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = newSize.height / 2
    }
}

/// An inert status row: colored dot on the left, title, right-aligned value.
/// Clicks are swallowed so it reads as a read-only indicator.
private final class StatusRowView: MenuRowView {
    private let dotView: DotView
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    init(title: String) {
        dotView = DotView(color: .systemGray)
        super.init(frame: NSRect(x: 0, y: 0, width: statusMenuWidth, height: 26))
        titleLabel.stringValue = title
        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        valueLabel.font = NSFont.menuFont(ofSize: 0)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        addSubview(dotView)
        addSubview(titleLabel)
        addSubview(valueLabel)
        place()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(dot: NSColor, value: String, valueColor: NSColor) {
        dotView.color = dot
        valueLabel.stringValue = value
        valueLabel.textColor = valueColor
        place()
    }

    private func place() {
        let height = bounds.height
        let dotSize: CGFloat = 10
        dotView.frame = NSRect(x: 16, y: (height - dotSize) / 2, width: dotSize, height: dotSize)
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 36, y: (height - titleLabel.frame.height) / 2)
        valueLabel.isHidden = valueLabel.stringValue.isEmpty
        if !valueLabel.isHidden {
            valueLabel.sizeToFit()
            let size = valueLabel.frame.size
            valueLabel.frame = NSRect(x: bounds.width - 12 - size.width,
                                      y: (height - size.height) / 2,
                                      width: size.width,
                                      height: size.height)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }
}

/// A wrapping, red, read-only error line. Only visible while `lastError` is set.
private final class ErrorRowView: MenuRowView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let font = NSFont.menuFont(ofSize: 12)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: statusMenuWidth, height: 26))
        label.font = font
        label.textColor = .systemRed
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(text: String) {
        label.stringValue = text
        let inset: CGFloat = 16
        let available = bounds.width - inset * 2
        label.preferredMaxLayoutWidth = available
        let measured = label.attributedStringValue.boundingRect(
            with: CGSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textHeight = min(measured.height, font.pointSize * 1.4 * 3)
        let rowHeight = max(ceil(textHeight) + 8, 24)
        var frame = self.frame
        frame.size.height = rowHeight
        self.frame = frame
        label.frame = NSRect(x: inset, y: 4, width: available, height: bounds.height - 8)
    }
}
