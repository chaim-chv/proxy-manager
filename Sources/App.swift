import SwiftUI
import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenuController: StatusMenuController?
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Native menu-bar status item + menu (custom-view NSMenu). See
        // StatusMenuController.swift for why this is AppKit, not SwiftUI.
        statusMenuController = StatusMenuController.shared
        installEscapeToCloseSettings()
        if AppModel.shared.showOnboarding {
            OnboardingWindowController.shared.show()
        }
    }

    /// Close the Settings or Onboarding window on Escape. A local monitor (not
    /// `onExitCommand`) so it fires even when no SwiftUI control has focus.
    private func installEscapeToCloseSettings() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            // An inline target edit handles Esc itself (cancel the edit), so it
            // must not also close the Settings window.
            if InlineEditGuard.isActive { return event }
            if let settings = SettingsWindow.current,
               settings.isVisible,
               event.window === settings || NSApp.keyWindow === settings {
                settings.performClose(nil)
                return nil
            }
            if let onboarding = OnboardingWindowController.shared.window,
               onboarding.isVisible,
               event.window === onboarding || NSApp.keyWindow === onboarding {
                onboarding.performClose(nil)
                return nil
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
