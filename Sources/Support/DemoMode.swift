import Foundation

#if SCREENSHOT_MODE
import AppKit

/// Screenshot-only demo mode.
///
/// Compiled **only** when the build defines `SCREENSHOT_MODE`
/// (`swiftc -D SCREENSHOT_MODE`, wired through `build.sh`'s `SWIFT_FLAGS`).
/// A normal `./build.sh` never defines the flag, so the shipping app contains
/// none of this code — only the tiny no-op shim in the `#else` branch below.
///
/// Purpose: render every screen with realistic fake data for the landing page
/// (see `.agents/skills/landing-page-maintenance`). It runs the app against an
/// isolated support directory and **never** touches the system proxy, the shell
/// environment, the Keychain, the crash watchdog, launch-at-login, or the
/// network.
///
/// Environment variables (all optional):
///   PROXYMANAGER_DEMO=1            enable the demo (required)
///   PROXYMANAGER_SCREEN            dashboard | dashboard-detail |
///                                  settings-tunnel | settings-targets |
///                                  onboarding                     (default dashboard)
///   PROXYMANAGER_APPEARANCE        dark | light                    (default dark)
///   PROXYMANAGER_ONBOARDING_STEP   0..3                            (default 2)
enum DemoMode {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PROXYMANAGER_DEMO"] == "1"
    }

    /// Injected into `ConfigStore` so the demo never reads or writes the real
    /// `~/Library/Application Support/ProxyManager` or `~/.config/proxy-manager`.
    private(set) static var supportDirOverride: URL?
    private(set) static var envDirOverride: URL?

    private static var screen: String {
        ProcessInfo.processInfo.environment["PROXYMANAGER_SCREEN"] ?? "dashboard"
    }

    private static var appearanceMode: AppearanceMode {
        switch ProcessInfo.processInfo.environment["PROXYMANAGER_APPEARANCE"] {
        case "light": return .light
        case "dark": return .dark
        default: return .dark
        }
    }

    static var onboardingStep: Int {
        Int(ProcessInfo.processInfo.environment["PROXYMANAGER_ONBOARDING_STEP"] ?? "") ?? 2
    }

    /// Whether the dashboard should open with a request selected (detail panel).
    static var showsDetailPanel: Bool { screen == "dashboard-detail" }

    // MARK: - Bootstrap (before NSApplication starts)

    /// Called from `Main.main` before the app runs. Points the app at a fresh
    /// sandbox directory and writes a seeded `config.json` into it.
    static func bootstrap() {
        guard isEnabled else { return }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("proxymanager-demo", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let env = root.appendingPathComponent("env", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: env, withIntermediateDirectories: true)
        supportDirOverride = support
        envDirOverride = env
        writeConfig(to: support)
    }

    private static func writeConfig(to support: URL) {
        var config = AppConfig()
        config.tunnel.mode = .manual
        config.tunnel.host = "127.0.0.1"
        config.tunnel.port = 1080
        config.tunnel.supervised = true
        config.tunnel.launchdLabel = "com.user.autossh_socks"
        config.system.appearanceMode = appearanceMode
        config.system.crashWatchdog = false
        config.system.injectShellEnv = false
        config.system.launchAtLogin = false
        config.system.restoreOnQuit = false
        config.system.iconMode = .menuBarAndDock
        config.targets = demoTargets()
        config.monitor.recordPaths = true

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: support.appendingPathComponent("config.json"), options: .atomic)
    }

    private static func demoTargets() -> [TargetRule] {
        [
            TargetRule(pattern: "deepseek.com"),
            TargetRule(pattern: "*.deepseek.com"),
            TargetRule(pattern: "api.openai.com"),
            TargetRule(pattern: "*.openai.com"),
            TargetRule(pattern: "chatgpt.com"),
            TargetRule(pattern: "*.anthropic.com"),
            TargetRule(pattern: "claude.ai"),
            TargetRule(pattern: "generativelanguage.googleapis.com"),
            TargetRule(pattern: "github.com"),
            TargetRule(pattern: "*.github.com"),
            TargetRule(pattern: "objects.githubusercontent.com"),
            TargetRule(pattern: "*.nvidia.com"),
            TargetRule(pattern: "*.whatsapp.com", enabled: false),
        ]
    }

    // MARK: - Apply (end of AppModel.init)

    /// Seeds fake telemetry and presents the requested screen. Runs on the main
    /// thread during launch; window work is deferred a few run-loop turns so the
    /// SwiftUI scenes have been created.
    static func apply(to model: AppModel) {
        guard isEnabled else { return }
        seedTelemetry(model.telemetry)

        model.showOnboarding = (screen == "onboarding")
        switch screen {
        case "settings-tunnel": model.settingsSelection = .tunnel
        case "settings-targets": model.settingsSelection = .targets
        default: break
        }

        // Set on the next main-queue turn: the (unstarted) tunnel supervisor
        // still emits its initial `false` through a `receive(on: .main)` sink,
        // which would otherwise overwrite these right after `init`.
        DispatchQueue.main.async {
            model.state = .on
            model.tunnelUp = true
            model.lastError = nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { present(model) }
    }

    private static func present(_ model: AppModel) {
        switch screen {
        case "onboarding":
            model.showOnboarding = true
            OnboardingWindowController.shared.show()
        case "settings-tunnel", "settings-targets":
            model.openSettings()
        default:
            DashboardWindowController.shared.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { sizeWindows() }
    }

    private static func sizeWindows() {
        for window in NSApp.windows where window.isVisible {
            if window === SettingsWindow.current {
                window.setContentSize(NSSize(width: 900, height: 640))
                window.center()
                window.makeKeyAndOrderFront(nil)
            } else if window.title == "Proxy Manager" {
                window.setContentSize(NSSize(width: 1120, height: 720))
                window.center()
                window.makeKeyAndOrderFront(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Fake telemetry

    private static func seedTelemetry(_ telemetry: TelemetryStore) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var rng = RNG(seed: 0x5EED_1234)

        var completed: [RequestEvent] = []
        var tunneled = 0
        var direct = 0
        var blocked = 0
        var bytesIn: Int64 = 0
        var bytesOut: Int64 = 0

        // Spread ~260 requests across the last 5 minutes so the 5m chart and the
        // feed both look busy.
        for i in 0..<260 {
            let profile = profiles.weightedPick(&rng)
            let ageMs = Int64(Double(i) / 260.0 * 300_000.0) + rng.int64(0...2_500)
            let ts = now - ageMs
            let isConnect = profile.method == "CONNECT"
            let status = profile.status(&rng)
            let error = profile.error(for: status)
            let path = isConnect ? "" : profile.paths.randomElement(using: &rng) ?? ""
            let dl = rng.int64(profile.download)
            let ul = rng.int64(profile.upload)
            let event = RequestEvent(
                ts: ts,
                scheme: profile.scheme,
                method: profile.method,
                host: profile.host,
                port: profile.port,
                path: path,
                route: profile.route,
                status: status,
                bytesIn: dl,
                bytesOut: ul,
                durationMs: rng.int64(profile.duration),
                error: error,
                srcPort: rng.int(50_000...65_000)
            )
            completed.append(event)
            switch profile.route {
            case .tunnel: tunneled += 1
            case .direct: direct += 1
            case .block: blocked += 1
            }
            bytesIn += dl
            bytesOut += ul
        }

        completed.sort { $0.ts < $1.ts }

        // A few in-progress connections so the live dot and "Active" stat render.
        var live: [RequestEvent] = []
        for profile in [HostProfile.liveDeepSeek, .liveOpenAI, .liveGitHub, .liveDirect] {
            let event = RequestEvent(
                ts: now - rng.int64(200...4_000),
                scheme: profile.scheme,
                method: profile.method,
                host: profile.host,
                port: profile.port,
                path: "",
                route: profile.route,
                status: 200,
                bytesIn: rng.int64(profile.download),
                bytesOut: rng.int64(profile.upload),
                durationMs: rng.int64(200...4_000),
                error: nil,
                srcPort: rng.int(50_000...65_000)
            )
            live.append(event)
        }

        telemetry.recentRequests = completed
        telemetry.seedDemoLive(live)
        telemetry.stats = StatsSnapshot(
            tunneledRequests: tunneled,
            directRequests: direct,
            blockedRequests: blocked,
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            activeConnections: live.count
        )
        telemetry.setActiveConnections(live.count)
    }

    // MARK: - Data model

    private struct HostProfile {
        let host: String
        let route: Route
        let method: String
        let scheme: String
        let port: UInt16
        let weight: Int
        let paths: [String]
        let download: ClosedRange<Int64>
        let upload: ClosedRange<Int64>
        let duration: ClosedRange<Int64>
        let failureRate: Double

        func status(_ rng: inout RNG) -> Int {
            if route == .block { return 502 }
            if rng.double() < failureRate { return 502 }
            if method != "CONNECT" { return 0 }
            return rng.double() < 0.12 ? 206 : 200
        }

        func error(for status: Int) -> String? {
            if route == .block { return "tunnel_down" }
            if status == 502 { return "connect_failed: upstream timeout" }
            return nil
        }

        static let liveDeepSeek = HostProfile(
            host: "api.deepseek.com", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
            weight: 1, paths: [], download: 480_000...2_400_000, upload: 1_200...8_000,
            duration: 1_000...9_000, failureRate: 0
        )
        static let liveOpenAI = HostProfile(
            host: "api.openai.com", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
            weight: 1, paths: [], download: 120_000...900_000, upload: 900...6_000,
            duration: 800...6_000, failureRate: 0
        )
        static let liveGitHub = HostProfile(
            host: "github.com", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
            weight: 1, paths: [], download: 8_000...90_000, upload: 400...2_000,
            duration: 200...1_500, failureRate: 0
        )
        static let liveDirect = HostProfile(
            host: "cdn.jsdelivr.net", route: .direct, method: "CONNECT", scheme: "https", port: 443,
            weight: 1, paths: [], download: 12_000...220_000, upload: 300...1_500,
            duration: 60...600, failureRate: 0
        )
    }

    private struct ProfileSet {
        let items: [HostProfile]
        var totalWeight: Int { items.reduce(0) { $0 + $1.weight } }

        func weightedPick(_ rng: inout RNG) -> HostProfile {
            var roll = rng.int(0...max(0, totalWeight - 1))
            for item in items {
                if roll < item.weight { return item }
                roll -= item.weight
            }
            return items[0]
        }
    }

    private static let profiles = ProfileSet(items: [
        HostProfile(host: "api.deepseek.com", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
                    weight: 34, paths: [], download: 220_000...2_600_000, upload: 1_000...9_000,
                    duration: 900...8_500, failureRate: 0.02),
        HostProfile(host: "chat.deepseek.com", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
                    weight: 18, paths: [], download: 90_000...700_000, upload: 800...6_000,
                    duration: 700...5_000, failureRate: 0.01),
        HostProfile(host: "api.openai.com", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
                    weight: 16, paths: [], download: 60_000...800_000, upload: 900...7_000,
                    duration: 600...6_000, failureRate: 0.02),
        HostProfile(host: "chatgpt.com", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
                    weight: 8, paths: [], download: 80_000...600_000, upload: 1_000...5_000,
                    duration: 500...4_000, failureRate: 0.01),
        HostProfile(host: "api.anthropic.com", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
                    weight: 9, paths: [], download: 70_000...900_000, upload: 900...6_000,
                    duration: 700...6_500, failureRate: 0.02),
        HostProfile(host: "claude.ai", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
                    weight: 5, paths: [], download: 90_000...500_000, upload: 800...4_000,
                    duration: 600...4_000, failureRate: 0.01),
        HostProfile(host: "generativelanguage.googleapis.com", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
                    weight: 6, paths: [], download: 50_000...400_000, upload: 900...5_000,
                    duration: 500...4_500, failureRate: 0.02),
        HostProfile(host: "github.com", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
                    weight: 7, paths: [], download: 8_000...120_000, upload: 400...2_500,
                    duration: 150...1_400, failureRate: 0.01),
        HostProfile(host: "objects.githubusercontent.com", route: .tunnel, method: "CONNECT", scheme: "https", port: 443,
                    weight: 5, paths: [], download: 120_000...3_500_000, upload: 300...1_200,
                    duration: 400...6_000, failureRate: 0.01),
        HostProfile(host: "api.deepseek.com", route: .tunnel, method: "GET", scheme: "http", port: 80,
                    weight: 4, paths: ["/v1/models", "/v1/chat/completions", "/health"],
                    download: 2_000...40_000, upload: 400...2_000,
                    duration: 120...1_200, failureRate: 0.01),
        HostProfile(host: "registry.npmjs.org", route: .direct, method: "CONNECT", scheme: "https", port: 443,
                    weight: 9, paths: [], download: 6_000...180_000, upload: 300...1_200,
                    duration: 60...900, failureRate: 0.01),
        HostProfile(host: "cdn.jsdelivr.net", route: .direct, method: "CONNECT", scheme: "https", port: 443,
                    weight: 8, paths: [], download: 10_000...260_000, upload: 300...1_500,
                    duration: 50...700, failureRate: 0.01),
        HostProfile(host: "swift.org", route: .direct, method: "CONNECT", scheme: "https", port: 443,
                    weight: 4, paths: [], download: 4_000...80_000, upload: 300...1_000,
                    duration: 80...800, failureRate: 0.01),
        HostProfile(host: "www.apple.com", route: .direct, method: "CONNECT", scheme: "https", port: 443,
                    weight: 5, paths: [], download: 8_000...140_000, upload: 300...1_000,
                    duration: 70...700, failureRate: 0.01),
        HostProfile(host: "metrics.vendor.example", route: .block, method: "CONNECT", scheme: "https", port: 443,
                    weight: 3, paths: [], download: 0...0, upload: 0...0,
                    duration: 5...40, failureRate: 1),
    ])

    private struct RNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        mutating func double() -> Double {
            Double(next() >> 11) / Double(1 << 53)
        }

        mutating func int(_ range: ClosedRange<Int>) -> Int {
            let span = range.upperBound - range.lowerBound + 1
            return range.lowerBound + Int(next() % UInt64(span))
        }

        mutating func int64(_ range: ClosedRange<Int64>) -> Int64 {
            let span = range.upperBound - range.lowerBound + 1
            guard span > 0 else { return range.lowerBound }
            return range.lowerBound + Int64(next() % UInt64(span))
        }
    }
}

#else

/// Screenshot-only demo mode is compiled out of normal builds. This no-op shim
/// keeps the call sites in `App.swift` / `AppModel.swift` / `ConfigStore.swift`
/// readable without `#if` noise at every one.
enum DemoMode {
    static let isEnabled = false
    static func bootstrap() {}
    static func apply(to model: AppModel) {}
}

#endif
