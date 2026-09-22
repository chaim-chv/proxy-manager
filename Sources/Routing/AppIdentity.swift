import Foundation

/// Identity of the local process that opened a connection to the proxy.
///
/// Rules match on `bundleId` first, then `executablePath`, then
/// `executableName`. `displayName` is for the UI only. Kept Foundation-only
/// (no `AppKit`/`Darwin`) so the routing logic and its harnesses stay lightweight;
/// resolving an identity lives in `AppResolver`.
struct AppIdentity: Equatable {
    let pid: Int32
    let bundleId: String?
    let executablePath: String
    let executableName: String
    let displayName: String
}
