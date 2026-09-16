import SwiftUI
import AppKit
import CoreServices
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenuController: StatusMenuController?
    private var escapeMonitor: Any?
    private var powerOffObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Native menu-bar status item + menu (custom-view NSMenu). See
        // StatusMenuController.swift for why this is AppKit, not SwiftUI.
        statusMenuController = StatusMenuController.shared
        installEscapeToCloseSettings()
        observeSystemPowerOff()
        if AppModel.shared.showOnboarding {
            OnboardingWindowController.shared.show()
        }
    }

    /// A logout/restart/shutdown must never be blocked, so remember it. macOS
    /// usually stamps the quit Apple Event with `kAEQuitReason` too; this covers
    /// the paths where it does not.
    private func observeSystemPowerOff() {
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { _ in
            AppModel.shared.allowTermination()
        }
    }

    /// Close the Settings or Onboarding window on Escape. A local monitor (not
    /// `onExitCommand`) so it fires even when no SwiftUI control has focus.
    ///
    /// Escape is not ours to take while Sparkle has a window up (update alert,
    /// progress, "You're up to date"): that window owns its own cancel behavior,
    /// and grabbing the key here closed the window *underneath* the alert.
    private func installEscapeToCloseSettings() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            // An inline target edit handles Esc itself (cancel the edit), so it
            // must not also close the Settings window.
            if InlineEditGuard.isActive { return event }
            // Let Sparkle keep Escape whenever one of its windows is visible.
            if NSApp.windows.contains(where: { $0.isVisible && Self.isSparkleWindow($0) }) {
                return event
            }
            if let settings = SettingsWindow.current,
               settings.isVisible,
               Self.eventTargets(event, window: settings) {
                Self.performCloseAfterEvent(settings)
                return nil
            }
            if let onboarding = OnboardingWindowController.shared.window,
               onboarding.isVisible,
               Self.eventTargets(event, window: onboarding) {
                Self.performCloseAfterEvent(onboarding)
                return nil
            }
            return event
        }
    }

    /// True when `event` is aimed at `window`: it carries that window, or (for
    /// window-less posted/programmatic events) that window is the app's key one.
    private static func eventTargets(_ event: NSEvent, window: NSWindow) -> Bool {
        if event.window === window { return true }
        return event.window == nil && NSApp.keyWindow === window
    }

    /// Close on the next run-loop pass. Closing synchronously from inside the
    /// event monitor re-enters AppKit/SwiftUI (window close → onboarding
    /// completion → open Settings) while the key event is still being handled.
    private static func performCloseAfterEvent(_ window: NSWindow) {
        DispatchQueue.main.async { window.performClose(nil) }
    }

    /// Sparkle's windows come from its own framework; anything it shows (update
    /// alert, status, progress) must keep Escape for itself.
    private static func isSparkleWindow(_ window: NSWindow) -> Bool {
        let bundles = [window.windowController, window.contentViewController].compactMap { $0 }
        return bundles.contains { Bundle(for: type(of: $0)).bundlePath.contains("Sparkle.framework") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Only a deliberate quit (the menu-bar status menu, a click on the app-menu
    /// Quit item, the Settings → General button, Restart, or Sparkle installing
    /// an update) may terminate. Everything else — the Dock menu's Quit, a
    /// stray Apple event — just closes the front window and keeps the tunnel
    /// alive. A system logout/restart/shutdown is always allowed through.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppModel.shared.isTerminationAllowed || Self.isSystemQuitEvent() {
            return .terminateNow
        }
        Log.app.notice("applicationShouldTerminate(): ignoring incidental quit request")
        Self.closeFrontWindow()
        return .terminateCancel
    }

    /// True when the quit Apple Event came from the system (logout, restart,
    /// shutdown) rather than a user or the Dock.
    private static func isSystemQuitEvent() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass,
              event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return false }
        switch reason.typeCodeValue {
        case kAEShutDown, kAERestart, kAEReallyLogOut: return true
        default: return false
        }
    }

    /// Handles the app-menu "Quit Proxy Manager" item. A mouse click is a
    /// deliberate quit; the ⌘Q key equivalent is not — it closes the front
    /// window and leaves the app (and the tunnel) running.
    static func handleQuitCommand() {
        if let event = NSApp.currentEvent,
           event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            closeFrontWindow()
            return
        }
        AppModel.shared.quitApp()
    }

    /// Closes the frontmost app window, if any. Sparkle's own windows are left
    /// alone so an in-flight update is never interrupted.
    static func closeFrontWindow() {
        let front = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.windows
        guard let window = front.first(where: {
            $0.isVisible && $0.canBecomeKey && !isSparkleWindow($0)
        }) else { return }
        // Close on the next run-loop pass: closing synchronously from a quit
        // request re-enters AppKit while the event is still being handled.
        DispatchQueue.main.async { window.performClose(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DashboardWindowController.shared.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DashboardWindowController.shared.saveWindowFrame()
        AppModel.shared.shutdownForQuit()
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Dashboard…") {
                DashboardWindowController.shared.show()
            }
            .keyboardShortcut("d")

            Button("Toggle Routing") {
                AppModel.shared.toggle()
            }
            .keyboardShortcut("l")
        }

        // Replace the standard Quit item so only a click quits: a mouse click
        // is deliberate, while the ⌘Q key equivalent closes the front window
        // instead. See `AppDelegate.handleQuitCommand()`.
        CommandGroup(replacing: .appTermination) {
            Button("Quit Proxy Manager") {
                AppDelegate.handleQuitCommand()
            }
            .keyboardShortcut("q")
        }
    }
}

@main
enum Main {
    static func main() {
        // Belt-and-suspenders for SIGPIPE: every socket also sets SO_NOSIGPIPE
        // (Socket.setNoSIGPIPE), but ignoring it process-wide means a future fd
        // that forgets can never kill the app on a peer reset.
        signal(SIGPIPE, SIG_IGN)
        // Same binary, two roles. The watchdog mode must never touch SwiftUI /
        // AppModel so its idle footprint stays negligible.
        if CommandLine.arguments.contains("--watchdog") {
            Watchdog.run()
        }
        ProxyManagerApp.main()
    }
}

struct ProxyManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(model)
        }
        .commands {
            AppCommands()
        }
    }
}
