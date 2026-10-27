import Foundation

/// Non-throwing field decoding for config files. `decodeIfPresent` only covers
/// a missing key; an unknown enum raw value, a wrong JSON type, an
/// out-of-range integer or a malformed UUID still throws and would fail the
/// whole `AppConfig` decode (TC-01).
private extension KeyedDecodingContainer {
    func tolerant<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decode(T.self, forKey: key)) ?? fallback
    }

    /// Ports are stored as `UInt16` but decoded through `Int` so 70000 clamps to
    /// 65535 instead of throwing, and 0/negative fall back to the documented
    /// default (a zero port is never a usable proxy/SOCKS/SSH port).
    func tolerantPort(_ key: Key, _ fallback: UInt16) -> UInt16 {
        guard let raw = try? decode(Int.self, forKey: key), raw > 0 else { return fallback }
        return UInt16(clamping: raw)
    }

    func tolerantClampedInt(_ key: Key, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        guard let raw = try? decode(Int.self, forKey: key) else { return fallback }
        return min(max(raw, range.lowerBound), range.upperBound)
    }
}

/// Element-level wrapper so one malformed array entry (non-object, wrong field
/// type) cannot reject the whole list; valid entries survive.
private struct LenientTargetRule: Decodable {
    private enum CodingKeys: String, CodingKey { case pattern }
    let value: TargetRule?

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
              let pattern = try? c.decode(String.self, forKey: .pattern),
              !pattern.trimmingCharacters(in: .whitespaces).isEmpty else {
            value = nil
            return
        }
        value = try? TargetRule(from: decoder)
    }
}

private struct LenientAppRule: Decodable {
    private enum CodingKeys: String, CodingKey { case key }
    let value: AppRule?

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
              let key = try? c.decode(String.self, forKey: .key),
              !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            value = nil
            return
        }
        value = try? AppRule(from: decoder)
    }
}

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
        id = c.tolerant(.id, UUID())
        pattern = c.tolerant(.pattern, "")
        enabled = c.tolerant(.enabled, true)
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
        id = c.tolerant(.id, UUID())
        key = c.tolerant(.key, "")
        keyKind = c.tolerant(.keyKind, .bundle)
        mode = c.tolerant(.mode, .targets)
        // An unknown/wrong-typed routing value must never silently take on a
        // different meaning. Keep the rule (so it is visible/fixable) but
        // disable it: that is the safe fallback (TC-01).
        var unknownRouting = false
        if c.contains(.keyKind),
           (try? c.decode(String.self, forKey: .keyKind))
               .flatMap(AppRuleKeyKind.init(rawValue:)) == nil {
            unknownRouting = true
        }
        if c.contains(.mode),
           (try? c.decode(String.self, forKey: .mode))
               .flatMap(AppRoutingMode.init(rawValue:)) == nil {
            unknownRouting = true
        }
        enabled = c.tolerant(.enabled, true) && !unknownRouting
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
        enabled = c.tolerant(.enabled, false)
        defaultMode = c.tolerant(.defaultMode, .targets)
        recordInTelemetry = c.tolerant(.recordInTelemetry, true)
        if let wrapped = try? c.decode([LenientAppRule].self, forKey: .rules) {
            rules = wrapped.compactMap(\.value)
        } else {
            rules = []
        }
    }
}

struct ProxySettings: Codable, Equatable {
    var bindHost: String = "127.0.0.1"
    var port: UInt16 = 8888

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bindHost = c.tolerant(.bindHost, "127.0.0.1")
        port = c.tolerantPort(.port, 8888)
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
        sshHost = c.tolerant(.sshHost, "")
        sshPort = c.tolerantPort(.sshPort, 22)
        username = c.tolerant(.username, "")
        auth = c.tolerant(.auth, .key)
        keyPath = c.tolerant(.keyPath, "")
        socksHost = c.tolerant(.socksHost, "127.0.0.1")
        socksPort = c.tolerantPort(.socksPort, 1080)
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
        mode = c.tolerant(.mode, .manual)
        host = c.tolerant(.host, "127.0.0.1")
        port = c.tolerantPort(.port, 1080)
        supervised = c.tolerant(.supervised, false)
        launchdLabel = c.tolerant(.launchdLabel, "")
        managed = c.tolerant(.managed, ManagedTunnelSettings())
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
        failClosedWhenTunnelDown = c.tolerant(.failClosedWhenTunnelDown, false)
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

/// Where the app's icon lives: menu bar only (no Dock icon unless the Dashboard
/// or Settings is open), both the menu bar and the Dock, or the Dock only (no
/// menu bar status item).
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

    /// Whether a Dock icon should be present right now. Menu-bar-only still
    /// shows one while the Dashboard or Settings window is open.
    func dockIconVisible(hasOpenAppWindow: Bool) -> Bool {
        showsDockIcon || hasOpenAppWindow
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
        injectShellEnv = c.tolerant(.injectShellEnv, true)
        injectGuiEnv = c.tolerant(.injectGuiEnv, true)
        launchAtLogin = c.tolerant(.launchAtLogin, false)
        restoreOnQuit = c.tolerant(.restoreOnQuit, true)
        colorizeMenuIcon = c.tolerant(.colorizeMenuIcon, true)
        appearanceMode = c.tolerant(.appearanceMode, .system)
        iconMode = c.tolerant(.iconMode, .menuBarAndDock)
        managedShellRcs = c.tolerant(.managedShellRcs, ["~/.zshrc"])
        crashWatchdog = c.tolerant(.crashWatchdog, true)
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
        retentionDays = c.tolerantClampedInt(.retentionDays, 7, 1...3_650)
        maxRows = c.tolerantClampedInt(.maxRows, 500_000, 0...10_000_000)
        recordPaths = c.tolerant(.recordPaths, true)
    }
}

/// Reserved: app-lock is not implemented yet. Persisted so a future build can
/// add it without a schema migration; nothing reads `enabled` today.
struct LockSettings: Codable, Equatable {
    var enabled: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.tolerant(.enabled, false)
    }
}

/// External control. Off by default: enabling it opens a local control socket
/// that another app can ask to change routing, targets or per-app rules.
struct IntegrationSettings: Codable, Equatable {
    var enabled: Bool = false
    var urlSchemeEnabled: Bool = true
    var xpcEnabled: Bool = true
    var intentsEnabled: Bool = true
    var auditEnabled: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.tolerant(.enabled, false)
        urlSchemeEnabled = c.tolerant(.urlSchemeEnabled, true)
        xpcEnabled = c.tolerant(.xpcEnabled, true)
        intentsEnabled = c.tolerant(.intentsEnabled, true)
        auditEnabled = c.tolerant(.auditEnabled, true)
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
    var integration: IntegrationSettings = IntegrationSettings()

    init() {}

    // Tolerant decode: every field falls back to its default when absent. A
    // synthesized `init(from:)` would throw `keyNotFound` and cause the whole
    // config (including the user's target list) to be wiped on upgrade.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.tolerant(.version, 1)
        proxy = c.tolerant(.proxy, ProxySettings())
        tunnel = c.tolerant(.tunnel, TunnelSettings())
        policy = c.tolerant(.policy, PolicySettings())
        system = c.tolerant(.system, SystemSettings())
        if let wrapped = try? c.decode([LenientTargetRule].self, forKey: .targets) {
            targets = wrapped.compactMap(\.value)
        } else {
            targets = AppConfig.defaultTargets()
        }
        monitor = c.tolerant(.monitor, MonitorSettings())
        lock = c.tolerant(.lock, LockSettings())
        apps = c.tolerant(.apps, AppSettings())
        integration = c.tolerant(.integration, IntegrationSettings())
    }

    // The app is generic: no domains are assumed. Users pick their own targets
    // (manually or via presets) during onboarding or in Settings → Targets.
    static func defaultTargets() -> [TargetRule] { [] }
}
