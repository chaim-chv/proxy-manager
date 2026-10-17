import AppKit

// Standalone harness for AppWindowTracker (see Tests/run-all.sh). It creates
// real NSWindows but never activates the app or shows the Dock icon.
//
// The key regression: in menu-bar-only mode the Dock icon must appear while the
// Dashboard or Settings is open, disappear when the last one closes, and appear
// again when either is reopened.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var failures = 0
var checks = 0

func check(_ name: String, _ condition: Bool) {
    checks += 1
    if condition {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)")
    }
}

func pump(_ seconds: TimeInterval = 0.2) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func makeWindow() -> NSWindow {
    NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 140),
             styleMask: [.titled, .closable], backing: .buffered, defer: false)
}

let tracker = AppWindowTracker.shared
tracker.onChange = {}

print("== Window tracker: Dashboard ==")
let dashboard = makeWindow()
tracker.trackDashboardWindow(dashboard)
check("hidden window does not count as open", !tracker.hasOpenWindow)

dashboard.makeKeyAndOrderFront(nil)
pump()
check("showing the Dashboard opens it", tracker.hasOpenWindow)

dashboard.performClose(nil)
pump()
check("closing the Dashboard closes it", !tracker.hasOpenWindow)

dashboard.makeKeyAndOrderFront(nil)
pump()
check("reopening the Dashboard opens it again", tracker.hasOpenWindow)

dashboard.orderOut(nil)
pump()
check("ordering out counts as closed", !tracker.hasOpenWindow)

dashboard.orderFront(nil)
pump()
check("ordering in counts as open", tracker.hasOpenWindow)

dashboard.close()
pump()
check("closing the Dashboard before the Settings tests", !tracker.hasOpenWindow)

print("== Window tracker: Settings ==")
let settings = makeWindow()
tracker.settingsWindowChanged(settings)
check("tracking a hidden Settings window does not open it", !tracker.hasOpenWindow)

settings.makeKeyAndOrderFront(nil)
pump()
check("showing Settings opens it", tracker.hasOpenWindow)

settings.performClose(nil)
pump()
check("closing Settings closes it", !tracker.hasOpenWindow)

settings.makeKeyAndOrderFront(nil)
pump()
check("reopening Settings opens it again", tracker.hasOpenWindow)

print("== Window tracker: multiple windows ==")
dashboard.makeKeyAndOrderFront(nil)
pump()
check("two open windows keep the Dock icon", tracker.hasOpenWindow)
check("frontmost open window is a tracked one",
      tracker.frontmostOpenWindow() === settings || tracker.frontmostOpenWindow() === dashboard)

settings.close()
pump()
check("closing Settings leaves the Dashboard open", tracker.hasOpenWindow)

dashboard.close()
pump()
check("closing the last window closes the tracker", !tracker.hasOpenWindow)
check("closed windows are cleaned up", tracker.frontmostOpenWindow() == nil)

print("")
if failures == 0 {
    print("PASS: window tracker (\(checks) checks)")
    exit(0)
} else {
    print("FAIL: window tracker (\(failures)/\(checks) checks failed)")
    exit(1)
}
