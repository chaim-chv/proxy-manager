import AppKit

/// Shared SSH private-key picker. Opens an `NSOpenPanel` that defaults to
/// `~/.ssh` (when it exists) with hidden files shown, and returns the chosen
/// path (or nil if cancelled). Used by both the Settings tunnel form and the
/// onboarding wizard.
enum KeyFilePicker {
    static func chooseKeyFile() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an SSH private key"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true

        let sshDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        if FileManager.default.fileExists(atPath: sshDir.path) {
            panel.directoryURL = sshDir
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
