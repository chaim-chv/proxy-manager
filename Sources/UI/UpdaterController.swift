import AppKit
import Combine
import SwiftUI
import Sparkle

/// How often Sparkle checks for updates, mapped onto its two runtime settings
/// (`automaticallyChecksForUpdates` + `updateCheckInterval`). The Info.plist
/// defaults (`SUEnableAutomaticChecks` + `SUScheduledCheckInterval`) seed
/// `.daily`; a user choice overrides them in UserDefaults.
enum UpdateFrequency: String, CaseIterable, Identifiable {
    case never
    case daily
    case weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    /// `nil` for `.never` (automatic checking is off).
    var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .daily: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        }
    }
}

/// Owns Sparkle's standard updater for the whole app.
///
/// A single long-lived instance: `startingUpdater: true` kicks off the
/// scheduled background checks (daily by default, per `SUScheduledCheckInterval`)
/// as soon as the app launches. Sparkle reads `SUFeedURL` / `SUPublicEDKey`
/// from `Info.plist` (written by `build.sh`) and never needs another API call.
///
/// Not touched in `--watchdog` mode — that path must stay free of AppKit/SwiftUI
/// so the watchdog keeps its negligible footprint.
final class UpdaterController: NSObject, ObservableObject {
    static let shared = UpdaterController()

    let controller: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the status-menu item and the
    /// Settings → General button can disable themselves while a check is in flight.
    @Published private(set) var canCheckForUpdates = false

    /// Mirrors the user's check-frequency choice (Settings → General).
    @Published private(set) var frequency: UpdateFrequency = .daily

    private var cancellable: AnyCancellable?

    private override init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        super.init()
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        frequency = Self.currentFrequency(of: controller.updater)
        Log.app.info("Sparkle updater started (feed=\(Self.feedURL, privacy: .public), checks=\(self.frequency.rawValue, privacy: .public))")
    }

    /// Applies the chosen frequency to Sparkle and reschedules the next check.
    func setFrequency(_ frequency: UpdateFrequency) {
        let updater = controller.updater
        if let interval = frequency.interval {
            updater.automaticallyChecksForUpdates = true
            updater.updateCheckInterval = interval
        } else {
            updater.automaticallyChecksForUpdates = false
        }
        self.frequency = frequency
        updater.resetUpdateCycleAfterShortDelay()
        Log.app.info("Sparkle check frequency set to \(frequency.rawValue, privacy: .public)")
    }

    private static func currentFrequency(of updater: SPUUpdater) -> UpdateFrequency {
        guard updater.automaticallyChecksForUpdates else { return .never }
        return updater.updateCheckInterval >= UpdateFrequency.weekly.interval! ? .weekly : .daily
    }

    /// User-initiated check (status-menu item / Settings → General button). The
    /// standard user driver handles all UI: "up to date", "update available",
    /// progress, install + relaunch.
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    /// The app's marketing version, with the build number only when it differs.
    static var displayVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != short { return "\(short) (\(build))" }
        return short
    }

    private static var feedURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "unset"
    }
}

/// A "Check for Updates…" button for SwiftUI (Settings → General), matching
/// Sparkle's own example so the disabled state updates before macOS 12.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = UpdaterController.shared

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates(nil)
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
