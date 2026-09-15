import AppKit
import SwiftUI

/// Single-instance dashboard window. Manages its own NSWindow so it can be
/// reopened from the Dock (applicationShouldHandleReopen), the menu bar, or ⌘D.
///
/// Window size, position, and screen are persisted with AppKit's frame
/// autosave (`setFrameAutosaveName`): the frame is stored in the app defaults
/// on every move/resize and restored on reopen, and a saved frame that would
/// land off-screen (e.g. the monitor was unplugged) is constrained back onto a
/// visible screen automatically.
final class DashboardWindowController: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowController()

    private let frameAutosaveName = "ProxyManagerDashboard"
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = DashboardView()
                .environmentObject(AppModel.shared)
                .environmentObject(AppModel.shared.telemetry)
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Proxy Manager"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            // Default size only applies when there is no saved frame yet.
            w.setContentSize(NSSize(width: 980, height: 640))
            if !w.setFrameUsingName(frameAutosaveName) {
                w.center()
            }
            w.setFrameAutosaveName(frameAutosaveName)
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Flush the current frame to defaults (called on close and on app quit,
    /// so a resize right before quitting is never lost).
    func saveWindowFrame() {
        window?.saveFrame(usingName: frameAutosaveName)
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
        window = nil
    }
}
