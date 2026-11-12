import AppKit

/// Locates SwiftUI's generated "Settings…" command in the app menu.
///
/// SwiftUI wires the Settings scene to a private `menuAction:` item, and
/// `showSettingsWindow:` is a no-op, so reopening Settings has to fire that
/// real item. Match the ⌘, key equivalent first: the title is localized, so
/// an English-only title match would silently disable the menu-bar item in a
/// translated build.
enum SettingsMenuCommand {
    static func item(in mainMenu: NSMenu?) -> NSMenuItem? {
        guard let mainMenu else { return nil }
        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            if let match = submenu.items.first(where: {
                $0.action != nil && $0.keyEquivalent == ","
            }) {
                return match
            }
        }
        // Fallback for a build whose Settings command has no ⌘, equivalent.
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
}
