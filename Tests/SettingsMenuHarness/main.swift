import AppKit

// Standalone harness for SettingsMenuCommand (see Tests/run-all.sh).
//
// The regression it pins: the menu-bar "Settings…" item must find SwiftUI's
// generated Settings command by its ⌘, key equivalent, because that item's
// title is localized. A title-only match silently broke opening Settings from
// the status menu in a translated build.

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

func item(_ title: String, key: String = "", action: Selector? = nil) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.action = action
    return item
}

func menu(_ items: [NSMenuItem]) -> NSMenu {
    let submenu = NSMenu()
    for item in items { submenu.addItem(item) }
    let mainMenu = NSMenu()
    let top = NSMenuItem()
    top.submenu = submenu
    mainMenu.addItem(top)
    return mainMenu
}

let action = #selector(NSApplication.terminate(_:))

print("== Settings menu command ==")

let localized = item("Einstellungen…", key: ",", action: action)
let localizedMenu = menu([item("Quit"), localized])
check("found by ⌘, despite a localized title",
      SettingsMenuCommand.item(in: localizedMenu) === localized)

let english = item("Settings…", action: action)
let englishMenu = menu([item("Quit"), english])
check("falls back to the English title without a key equivalent",
      SettingsMenuCommand.item(in: englishMenu) === english)

let noAction = item("Einstellungen…", key: ",")
let titleFallback = item("Settings…", action: action)
let noActionMenu = menu([noAction, titleFallback])
check("ignores a ⌘, item with no action",
      SettingsMenuCommand.item(in: noActionMenu) === titleFallback)

let unrelatedMenu = menu([item("Quit", key: "q", action: action),
                          item("Close", key: "w", action: action)])
check("returns nil when there is no Settings command",
      SettingsMenuCommand.item(in: unrelatedMenu) == nil)
check("returns nil when the app has no main menu",
      SettingsMenuCommand.item(in: nil) == nil)

print("")
if failures == 0 {
    print("PASS: settings menu command (\(checks) checks)")
    exit(0)
} else {
    print("FAIL: settings menu command (\(failures)/\(checks) checks failed)")
    exit(1)
}
