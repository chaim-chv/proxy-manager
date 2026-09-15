import os

/// Centralized logging for ProxyManager, backed by the macOS unified log (os_log).
///
/// Inspect at runtime with:
///   log stream --predicate 'subsystem == "com.proxymanager.app"' --level debug
///   log show --last 30m --predicate 'subsystem == "com.proxymanager.app"'
///
/// Categories map 1:1 to the subsystems in `docs/`.
enum Log {
    static let app = Logger(subsystem: "com.proxymanager.app", category: "app")
    static let proxy = Logger(subsystem: "com.proxymanager.app", category: "proxy")
    static let telemetry = Logger(subsystem: "com.proxymanager.app", category: "telemetry")
    static let system = Logger(subsystem: "com.proxymanager.app", category: "system")
    static let tunnel = Logger(subsystem: "com.proxymanager.app", category: "tunnel")
}
