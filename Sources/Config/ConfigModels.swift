import Foundation

enum Route: String, Codable, CaseIterable, Identifiable {
    case tunnel = "TUNNEL"
    case direct = "DIRECT"
    case block = "BLOCK"

    var id: String { rawValue }
}

struct TargetRule: Identifiable, Codable, Equatable {
    var id: UUID
    var pattern: String
    var enabled: Bool

    init(id: UUID = UUID(), pattern: String, enabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.enabled = enabled
    }

    // Tolerant decode so a rule from an older/newer schema never fails the
    // whole config load (see AppConfig).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// What a rule key refers to. Bundle ids are the primary identity; executable
/// path/name cover CLI tools and apps that ship without a bundle.
enum AppRuleKeyKind: String, Codable, CaseIterable, Identifiable {
    case bundle = "BUNDLE"
    case executable = "EXECUTABLE"
    case executableName = "EXECUTABLE_NAME"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bundle: return "Application"
        case .executable: return "Executable"
        case .executableName: return "Executable name"
        }
    }
}

/// How an app's traffic is routed. `targets` means "fall through to the host
/// allow-list"; the other two override it for the app's every request.
enum AppRoutingMode: String, Codable, CaseIterable, Identifiable {
    case tunnel = "TUNNEL"
    case targets = "TARGETS"
    case direct = "DIRECT"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tunnel: return "Tunnel all"
        case .targets: return "Use target rules"
        case .direct: return "Direct all"
        }
    }
}

struct AppRule: Identifiable, Codable, Equatable {
    var id: UUID
    var key: String
    var keyKind: AppRuleKeyKind
    var mode: AppRoutingMode
    var enabled: Bool

    init(id: UUID = UUID(), key: String, keyKind: AppRuleKeyKind,
         mode: AppRoutingMode, enabled: Bool = true) {
        self.id = id
        self.key = key
        self.keyKind = keyKind
        self.mode = mode
        self.enabled = enabled
    }

    // Tolerant decode (see AppConfig): a missing/extra field must not fail the
    // whole config load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        keyKind = (try? c.decode(AppRuleKeyKind.self, forKey: .keyKind)) ?? .bundle
        mode = (try? c.decode(AppRoutingMode.self, forKey: .mode)) ?? .targets
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Per-app routing. Off by default so the proxy hot path is untouched until the
/// user opts in. `defaultMode` applies to apps with no matching rule.
struct AppSettings: Codable, Equatable {
    var enabled: Bool = false
    var defaultMode: AppRoutingMode = .targets
    var recordInTelemetry: Bool = true
    var rules: [AppRule] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        defaultMode = (try? c.decode(AppRoutingMode.self, forKey: .defaultMode)) ?? .targets
        recordInTelemetry = try c.decodeIfPresent(Bool.self, forKey: .recordInTelemetry) ?? true
        rules = try c.decodeIfPresent([AppRule].self, forKey: .rules) ?? []
    }
}

struct ProxySettings: Codable, Equatable {
    var bindHost: String = "127.0.0.1"
    var port: UInt16 = 8888

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bindHost = try c.decodeIfPresent(String.self, forKey: .bindHost) ?? "127.0.0.1"
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 8888
    }
}

/// How the tunnel is provided.
enum TunnelMode: String, Codable, CaseIterable, Identifiable {
    case manual = "MANUAL"    // user runs their own tunnel; we point at it
    case managed = "MANAGED"  // the app runs an SSH SOCKS5 tunnel for you
    var id: String { rawValue }
}

enum SSHAuthMethod: String, Codable, CaseIterable, Identifiable {
    case key = "KEY"
    case password = "PASSWORD"
    var id: String { rawValue }
}

/// Settings for the app-managed SSH SOCKS5 tunnel ("run the tunnel for me").
/// The password is never stored here — it lives in the Keychain.
struct ManagedTunnelSettings: Codable, Equatable {
    var sshHost: String = ""
    var sshPort: UInt16 = 22
    var username: String = ""
    var auth: SSHAuthMethod = .key
    var keyPath: String = ""
    var socksHost: String = "127.0.0.1"
    var socksPort: UInt16 = 1080

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sshHost = try c.decodeIfPresent(String.self, forKey: .sshHost) ?? ""
        sshPort = try c.decodeIfPresent(UInt16.self, forKey: .sshPort) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        auth = try c.decodeIfPresent(SSHAuthMethod.self, forKey: .auth) ?? .key
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        socksHost = try c.decodeIfPresent(String.self, forKey: .socksHost) ?? "127.0.0.1"
        socksPort = try c.decodeIfPresent(UInt16.self, forKey: .socksPort) ?? 1080
    }
}

struct TunnelSettings: Codable, Equatable {
    var mode: TunnelMode = .manual
    var host: String = "127.0.0.1"
    var port: UInt16 = 1080
    var supervised: Bool = false
    var launchdLabel: String = ""
    var managed: ManagedTunnelSettings = ManagedTunnelSettings()

    /// The host/port the proxy core should dial, based on the current mode.
    var effectiveHost: String { mode == .managed ? managed.socksHost : host }
    var effectivePort: UInt16 { mode == .managed ? managed.socksPort : port }

    // Custom Codable so older config.json files (which lack `launchdLabel` /
    // `mode` / `managed`) still load instead of failing whole-file decode.
    enum CodingKeys: String, CodingKey {
        case mode, host, port, supervised, launchdLabel, managed
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(TunnelMode.self, forKey: .mode) ?? .manual
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 1080
        supervised = try c.decodeIfPresent(Bool.self, forKey: .supervised) ?? false
        launchdLabel = try c.decodeIfPresent(String.self, forKey: .launchdLabel) ?? ""
        managed = try c.decodeIfPresent(ManagedTunnelSettings.self, forKey: .managed) ?? ManagedTunnelSettings()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(supervised, forKey: .supervised)
        try c.encode(launchdLabel, forKey: .launchdLabel)
        try c.encode(managed, forKey: .managed)
    }
}

struct PolicySettings: Codable, Equatable {
    var failClosedWhenTunnelDown: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        failClosedWhenTunnelDown = try c.decodeIfPresent(Bool.self, forKey: .failClosedWhenTunnelDown) ?? false
    }
}

/// The app's color appearance: follow the system, or force light/dark.
enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system = "SYSTEM"  // follow the system appearance
    case light = "LIGHT"
    case dark = "DARK"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Where the app's icon lives: menu bar only (no Dock icon), both the menu bar
/// and the Dock, or the Dock only (no menu bar status item).
enum AppIconMode: String, Codable, CaseIterable, Identifiable {
    case menuBarOnly = "MENU_BAR_ONLY"
    case menuBarAndDock = "MENU_BAR_AND_DOCK"
    case dockOnly = "DOCK_ONLY"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .menuBarOnly: return "Menu bar only"
        case .menuBarAndDock: return "Menu bar + Dock"
        case .dockOnly: return "Dock only"
        }
    }

    var showsMenuBarIcon: Bool {
        switch self {
        case .menuBarOnly, .menuBarAndDock: return true
        case .dockOnly: return false
        }
    }

    var showsDockIcon: Bool {
        switch self {
        case .menuBarAndDock, .dockOnly: return true
        case .menuBarOnly: return false
        }
    }
}

struct SystemSettings: Codable, Equatable {
    var injectShellEnv: Bool = true
    var injectGuiEnv: Bool = true
    var launchAtLogin: Bool = false
    var restoreOnQuit: Bool = true
    var colorizeMenuIcon: Bool = true
    var appearanceMode: AppearanceMode = .system
    var iconMode: AppIconMode = .menuBarAndDock
    var managedShellRcs: [String] = ["~/.zshrc"]
    var crashWatchdog: Bool = true

    // Decoded with defaults so older config.json files (which lack
    // `colorizeMenuIcon` / `appearanceMode` / `iconMode` / `crashWatchdog` /
    // `injectGuiEnv`) still load instead of failing whole-file decode.
    enum CodingKeys: String, CodingKey {
        case injectShellEnv, injectGuiEnv, launchAtLogin, restoreOnQuit, colorizeMenuIcon, appearanceMode, iconMode, managedShellRcs, crashWatchdog
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        injectShellEnv = try c.decodeIfPresent(Bool.self, forKey: .injectShellEnv) ?? true
        injectGuiEnv = try c.decodeIfPresent(Bool.self, forKey: .injectGuiEnv) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        restoreOnQuit = try c.decodeIfPresent(Bool.self, forKey: .restoreOnQuit) ?? true
        colorizeMenuIcon = try c.decodeIfPresent(Bool.self, forKey: .colorizeMenuIcon) ?? true
        appearanceMode = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? .system
        iconMode = try c.decodeIfPresent(AppIconMode.self, forKey: .iconMode) ?? .menuBarAndDock
        managedShellRcs = try c.decodeIfPresent([String].self, forKey: .managedShellRcs) ?? ["~/.zshrc"]
        crashWatchdog = try c.decodeIfPresent(Bool.self, forKey: .crashWatchdog) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(injectShellEnv, forKey: .injectShellEnv)
        try c.encode(injectGuiEnv, forKey: .injectGuiEnv)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(restoreOnQuit, forKey: .restoreOnQuit)
        try c.encode(colorizeMenuIcon, forKey: .colorizeMenuIcon)
        try c.encode(appearanceMode, forKey: .appearanceMode)
        try c.encode(iconMode, forKey: .iconMode)
        try c.encode(managedShellRcs, forKey: .managedShellRcs)
        try c.encode(crashWatchdog, forKey: .crashWatchdog)
    }
}

struct MonitorSettings: Codable, Equatable {
    var retentionDays: Int = 7
    var maxRows: Int = 500_000
    var recordPaths: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7
        maxRows = try c.decodeIfPresent(Int.self, forKey: .maxRows) ?? 500_000
        recordPaths = try c.decodeIfPresent(Bool.self, forKey: .recordPaths) ?? true
    }
}

/// Reserved: app-lock is not implemented yet. Persisted so a future build can
/// add it without a schema migration; nothing reads `enabled` today.
struct LockSettings: Codable, Equatable {
    var enabled: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

struct AppConfig: Codable, Equatable {
    var version: Int = 1
    var proxy: ProxySettings = ProxySettings()
    var tunnel: TunnelSettings = TunnelSettings()
    var policy: PolicySettings = PolicySettings()
    var system: SystemSettings = SystemSettings()
    var targets: [TargetRule] = AppConfig.defaultTargets()
    var monitor: MonitorSettings = MonitorSettings()
    var lock: LockSettings = LockSettings()
    var apps: AppSettings = AppSettings()

    init() {}

    // Tolerant decode: every field falls back to its default when absent. A
    // synthesized `init(from:)` would throw `keyNotFound` and cause the whole
    // config (including the user's target list) to be wiped on upgrade.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        proxy = try c.decodeIfPresent(ProxySettings.self, forKey: .proxy) ?? ProxySettings()
        tunnel = try c.decodeIfPresent(TunnelSettings.self, forKey: .tunnel) ?? TunnelSettings()
        policy = try c.decodeIfPresent(PolicySettings.self, forKey: .policy) ?? PolicySettings()
        system = try c.decodeIfPresent(SystemSettings.self, forKey: .system) ?? SystemSettings()
        targets = try c.decodeIfPresent([TargetRule].self, forKey: .targets) ?? AppConfig.defaultTargets()
        monitor = try c.decodeIfPresent(MonitorSettings.self, forKey: .monitor) ?? MonitorSettings()
        lock = try c.decodeIfPresent(LockSettings.self, forKey: .lock) ?? LockSettings()
        apps = try c.decodeIfPresent(AppSettings.self, forKey: .apps) ?? AppSettings()
    }

    // The app is generic: no domains are assumed. Users pick their own targets
    // (manually or via presets) during onboarding or in Settings → Targets.
    static func defaultTargets() -> [TargetRule] { [] }
}
