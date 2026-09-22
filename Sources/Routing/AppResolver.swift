import Foundation
import Darwin

/// A bundle discovered on an executable's path (its `Contents/Info.plist`).
struct AppBundleInfo: Equatable {
    let rootPath: String
    let bundleId: String?
    let displayName: String?
}

private typealias ResponsibleFn = @convention(c) (Int32) -> Int32

/// Maps a connection accepted by the proxy back to the app that opened it.
///
/// macOS exposes no socket option for the peer PID of a TCP connection
/// (`LOCAL_PEERPID` is `AF_UNIX`-only), so the PID is found with a `libproc`
/// scan: every process's socket fds are matched by the client's ephemeral port
/// against the proxy port. The PID is then resolved to an app identity from its
/// executable path; helper processes (XPC services, `Contents/Frameworks/...`
/// helpers, WebKit's shared networking process) are attributed to their
/// responsible process so the user sees "Google Chrome", not
/// "Google Chrome Helper".
///
/// The scan is only run when per-app rules are enabled, so the default hot path
/// is untouched. Results are cached per PID (validated against the process start
/// time to survive PID reuse).
final class AppResolver {
    private static let maxPids = 4096
    private static let maxFds = 8192
    private static let maxPathBytes = 4096
    private static let sockInfoTCP: Int32 = 2
    private static let cacheTTL: TimeInterval = 30
    private static let bundleCacheLimit = 512

    private struct CacheEntry {
        let identity: AppIdentity
        let startSec: UInt64
        let startUsec: UInt64
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var identityCache: [Int32: CacheEntry] = [:]
    private var bundleCache: [String: AppBundleInfo] = [:]
    private var noBundlePaths = Set<String>()

    /// Whether the private responsible-process API could be resolved. When
    /// false, helper processes still resolve to their enclosing app bundle (and
    /// otherwise to their own bundle/executable); only WebKit-style shared
    /// services lose host-app attribution.
    static let responsibleProcessAPIAvailable: Bool = (AppResolver.responsibleFn != nil)

    private static let responsibleFn: ResponsibleFn? = {
        guard let handle = dlopen("/usr/lib/system/libsystem_coreservices.dylib", RTLD_NOW),
              let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    init() {
        Log.proxy.debug("AppResolver ready (responsible-process API: \(Self.responsibleProcessAPIAvailable ? "available" : "unavailable"))")
    }

    // MARK: - Resolution

    /// Resolves the app behind an accepted loopback connection.
    /// `localPort` is the client's ephemeral port (the accepted socket's peer
    /// port); `proxyPort` is the proxy's listening port.
    func resolve(localPort: UInt16, proxyPort: UInt16) -> AppIdentity? {
        guard let pid = Self.pidForLoopbackConnection(localPort: localPort, proxyPort: proxyPort) else {
            return nil
        }
        return identity(forPid: pid)
    }

    /// Resolves (and caches) the identity of a live PID. Returns nil if the
    /// process is gone or its executable cannot be read.
    func identity(forPid pid: Int32) -> AppIdentity? {
        guard pid > 0 else { return nil }
        let now = Date()
        lock.lock()
        if let entry = identityCache[pid], entry.expiresAt > now {
            lock.unlock()
            if let start = Self.processStartTime(pid),
               start.sec == entry.startSec, start.usec == entry.startUsec {
                return entry.identity
            }
            lock.lock()
            identityCache.removeValue(forKey: pid)
            lock.unlock()
            // Fall through and re-resolve; the PID was reused.
        } else {
            lock.unlock()
        }

        guard let start = Self.processStartTime(pid) else { return nil }
        let path = Self.executablePath(pid)
        guard !path.isEmpty else { return nil }
        let identity = buildIdentity(pid: pid, path: path)
        lock.lock()
        identityCache[pid] = CacheEntry(identity: identity, startSec: start.sec,
                                        startUsec: start.usec,
                                        expiresAt: now.addingTimeInterval(Self.cacheTTL))
        lock.unlock()
        return identity
    }

    func clearCache() {
        lock.lock()
        identityCache.removeAll()
        bundleCache.removeAll()
        noBundlePaths.removeAll()
        lock.unlock()
    }

    private func buildIdentity(pid: Int32, path: String) -> AppIdentity {
        let exeName = (path as NSString).lastPathComponent
        var bundle = bundleInfo(forPath: path)
        if Self.isHelperPath(path), let respPid = Self.responsiblePid(pid), respPid != pid {
            let respPath = Self.executablePath(respPid)
            if !respPath.isEmpty, let respBundle = bundleInfo(forPath: respPath),
               let respId = respBundle.bundleId, respId != bundle?.bundleId {
                bundle = respBundle
            }
        }
        return AppIdentity(pid: pid,
                           bundleId: bundle?.bundleId,
                           executablePath: path,
                           executableName: exeName,
                           displayName: bundle?.displayName ?? exeName)
    }

    private func bundleInfo(forPath path: String) -> AppBundleInfo? {
        lock.lock()
        if let cached = bundleCache[path] { lock.unlock(); return cached }
        if noBundlePaths.contains(path) { lock.unlock(); return nil }
        lock.unlock()

        let info = Self.enclosingBundle(path: path)
        lock.lock()
        if let info {
            if bundleCache.count >= Self.bundleCacheLimit { bundleCache.removeAll(keepingCapacity: true) }
            bundleCache[path] = info
        } else {
            if noBundlePaths.count >= Self.bundleCacheLimit { noBundlePaths.removeAll(keepingCapacity: true) }
            noBundlePaths.insert(path)
        }
        lock.unlock()
        return info
    }

    // MARK: - Pure helpers (unit-testable)

    /// Finds the **outermost** bundle on an executable's path (a directory with
    /// a `Contents/Info.plist`). Outermost so a helper inside an app resolves to
    /// the app, not to a nested helper bundle. Pure; reads only the plist.
    static func enclosingBundle(path: String) -> AppBundleInfo? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var prefix = ""
        for component in components {
            prefix += "/" + component
            let plistPath = prefix + "/Contents/Info.plist"
            guard FileManager.default.fileExists(atPath: plistPath) else { continue }
            let dict = NSDictionary(contentsOfFile: plistPath)
            let bundleId = dict?["CFBundleIdentifier"] as? String
            let displayName = (dict?["CFBundleDisplayName"] as? String)
                ?? (dict?["CFBundleName"] as? String)
            return AppBundleInfo(rootPath: prefix, bundleId: bundleId, displayName: displayName)
        }
        return nil
    }

    /// True when an executable path is a helper/XPC location rather than a
    /// top-level app binary.
    static func isHelperPath(_ path: String) -> Bool {
        path.contains("/Contents/Frameworks/")
            || path.contains("/Contents/XPCServices/")
            || path.contains("/Contents/Library/")
            || path.contains("/Contents/PlugIns/")
            || path.contains(".xpc/")
            || path.contains(".appex/")
    }

    static func executablePath(_ pid: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: maxPathBytes)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return "" }
        return String(cString: buffer)
    }

    static func processStartTime(_ pid: Int32) -> (sec: UInt64, usec: UInt64)? {
        var info = proc_bsdinfo()
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, Int32(PROC_PIDTBSDINFO), 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        guard rc > 0 else { return nil }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    static func responsiblePid(_ pid: Int32) -> Int32? {
        guard let fn = responsibleFn else { return nil }
        let result = fn(pid)
        return result > 0 ? result : nil
    }

    /// Finds the PID owning the client end of a loopback TCP connection by
    /// matching the client's local port and the proxy port. Returns nil when the
    /// process is owned by another user (unreadable) or the socket is gone.
    static func pidForLoopbackConnection(localPort: UInt16, proxyPort: UInt16) -> Int32? {
        var pidBuffer = [pid_t](repeating: 0, count: maxPids)
        let pidBytes = pidBuffer.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress,
                          Int32(maxPids * MemoryLayout<pid_t>.size))
        }
        guard pidBytes > 0 else { return nil }
        let pidCount = min(Int(pidBytes) / MemoryLayout<pid_t>.size, maxPids)

        var fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: maxFds)
        var sockInfo = socket_fdinfo()

        for i in 0..<pidCount {
            let pid = pidBuffer[i]
            if pid <= 0 { continue }
            let fdBytes = fdBuffer.withUnsafeMutableBytes {
                proc_pidinfo(pid, Int32(PROC_PIDLISTFDS), 0, $0.baseAddress,
                             Int32(maxFds * MemoryLayout<proc_fdinfo>.size))
            }
            if fdBytes <= 0 { continue }
            let fdCount = min(Int(fdBytes) / MemoryLayout<proc_fdinfo>.size, maxFds)
            for j in 0..<fdCount {
                let fdInfo = fdBuffer[j]
                guard Int32(fdInfo.proc_fdtype) == PROX_FDTYPE_SOCKET else { continue }
                let rc = withUnsafeMutablePointer(to: &sockInfo) {
                    proc_pidfdinfo(pid, fdInfo.proc_fd, Int32(PROC_PIDFDSOCKETINFO),
                                   $0, Int32(MemoryLayout<socket_fdinfo>.size))
                }
                guard rc > 0 else { continue }
                guard sockInfo.psi.soi_kind == sockInfoTCP,
                      sockInfo.psi.soi_family == AF_INET else { continue }
                let ini = sockInfo.psi.soi_proto.pri_tcp.tcpsi_ini
                let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
                let fport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
                if lport == localPort && fport == proxyPort { return pid }
            }
        }
        return nil
    }
}
