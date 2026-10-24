import Foundation
import Darwin
import Dispatch

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
/// time to survive PID reuse) and per `(localPort, proxyPort)` for a few seconds,
/// so a connection burst does not trigger one full system scan per connection.
/// Scans are bounded by a permit semaphore and reuse pooled scan buffers.
final class AppResolver {
    private static let maxPids = 4096
    private static let maxFds = 8192
    private static let maxPathBytes = 4096
    private static let sockInfoTCP: Int32 = 2
    private static let cacheTTL: TimeInterval = 30
    /// Internal so the standalone harness can assert the bound.
    static let bundleCacheLimit = 512

    private static let identityCacheLimit = 4096
    private static let portCacheTTL: TimeInterval = 5
    private static let portCacheLimit = 1024
    private static let scanPermits = 6
    private static let scanWaitMs = 100

    /// Bundle/no-bundle entries expire on their own, so an app installed (or
    /// deleted) while the app runs is picked up without a restart.
    private static let bundleCacheTTL: TimeInterval = 300
    /// Upper bound on waiting for another thread's in-flight plist read. The read
    /// is local; past this we resolve ourselves rather than return a wrong nil.
    private static let bundleWaitSeconds: TimeInterval = 2

    private struct CacheEntry {
        let identity: AppIdentity
        let startSec: UInt64
        let startUsec: UInt64
        let expiresAt: Date
        let cachedAt: Date
    }

    /// Bundle results are value-typed and small; `lastUsed` drives LRU eviction so
    /// reaching the cap never discards the whole cache.
    private struct BundleEntry {
        let info: AppBundleInfo
        let expiresAt: Date
        var lastUsed: Date
    }

    private struct NoBundleEntry {
        let expiresAt: Date
        var lastUsed: Date
    }

    /// One plist read per path at a time: concurrent misses for the same new
    /// executable (a connection burst from a just-launched app) share it.
    private final class InFlightBundleLookup {
        let condition = NSCondition()
        var finished = false
        var info: AppBundleInfo?
    }

    private struct PortKey: Hashable {
        let localPort: UInt16
        let proxyPort: UInt16
    }

    private struct PortCacheEntry: Equatable {
        let pid: Int32
        let startSec: UInt64
        let startUsec: UInt64
        let expiresAt: Date
    }

    /// Reused across scans. `proc_listpids`/`proc_pidinfo` rewrite the populated
    /// prefix; entries past the returned count are stale and never read.
    private final class ScanBuffers {
        var pids: [pid_t]
        var fds: [proc_fdinfo]
        var sock = socket_fdinfo()

        init(pidCount: Int, fdCount: Int) {
            pids = [pid_t](repeating: 0, count: pidCount)
            fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        }
    }

    private let lock = NSLock()
    private var identityCache: [Int32: CacheEntry] = [:]
    private var bundleCache: [String: BundleEntry] = [:]
    private var noBundlePaths: [String: NoBundleEntry] = [:]
    private var inFlightBundles: [String: InFlightBundleLookup] = [:]
    private var portCache: [PortKey: PortCacheEntry] = [:]

    private let scanSemaphore = DispatchSemaphore(value: AppResolver.scanPermits)
    private let bufferLock = NSLock()
    private var freeScanBuffers: [ScanBuffers] = []
    private var scanCounter = 0
    private var scanTimeoutCounter = 0
    private var bundleResolveCounter = 0

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
        freeScanBuffers = (0..<Self.scanPermits).map {
            _ in ScanBuffers(pidCount: Self.maxPids, fdCount: Self.maxFds)
        }
        Log.proxy.debug("AppResolver ready (responsible-process API: \(Self.responsibleProcessAPIAvailable ? "available" : "unavailable"))")
    }

    // MARK: - Resolution

    /// Resolves the app behind an accepted loopback connection.
    /// `localPort` is the client's ephemeral port (the accepted socket's peer
    /// port); `proxyPort` is the proxy's listening port.
    func resolve(localPort: UInt16, proxyPort: UInt16) -> AppIdentity? {
        let key = PortKey(localPort: localPort, proxyPort: proxyPort)
        let now = Date()
        lock.lock()
        let cached = portCache[key]
        lock.unlock()

        if let cached {
            // Re-validate the PID and its start time: the ephemeral port may have
            // been reused, and the cached PID may have died since the scan.
            if cached.expiresAt > now, let start = Self.processStartTime(cached.pid),
               start.sec == cached.startSec, start.usec == cached.startUsec {
                return identity(forPid: cached.pid)
            }
            lock.lock()
            if portCache[key] == cached { portCache.removeValue(forKey: key) }
            lock.unlock()
        }

        guard let pid = scanPid(localPort: localPort, proxyPort: proxyPort),
              let start = Self.processStartTime(pid) else {
            return nil
        }
        lock.lock()
        portCache[key] = PortCacheEntry(pid: pid, startSec: start.sec, startUsec: start.usec,
                                        expiresAt: now.addingTimeInterval(Self.portCacheTTL))
        trimPortCacheLocked()
        lock.unlock()
        return identity(forPid: pid)
    }

    /// Runs one bounded libproc scan. Returns nil (unknown identity) rather than
    /// blocking a proxy thread indefinitely when all scan permits are busy.
    private func scanPid(localPort: UInt16, proxyPort: UInt16) -> Int32? {
        let deadline = DispatchTime.now() + .milliseconds(Self.scanWaitMs)
        guard scanSemaphore.wait(timeout: deadline) == .success else {
            lock.lock()
            scanTimeoutCounter += 1
            lock.unlock()
            return nil
        }
        defer { scanSemaphore.signal() }

        bufferLock.lock()
        let buffers = freeScanBuffers.popLast()
        bufferLock.unlock()
        guard let buffers else { return nil }
        defer {
            bufferLock.lock()
            freeScanBuffers.append(buffers)
            bufferLock.unlock()
        }

        lock.lock()
        scanCounter += 1
        lock.unlock()

        return Self.pidForLoopbackConnection(localPort: localPort, proxyPort: proxyPort,
                                             buffers: buffers)
    }

    private func trimPortCacheLocked() {
        while portCache.count > Self.portCacheLimit {
            var oldestKey: PortKey?
            var oldestAt = Date.distantFuture
            for (key, entry) in portCache where entry.expiresAt < oldestAt {
                oldestAt = entry.expiresAt
                oldestKey = key
            }
            guard let oldestKey else { break }
            portCache.removeValue(forKey: oldestKey)
        }
    }

    /// Resolves (and caches) the identity of a live PID. Returns nil if the
    /// process is gone or its executable cannot be read.
    func identity(forPid pid: Int32) -> AppIdentity? {
        guard pid > 0 else { return nil }
        let now = Date()
        lock.lock()
        if let entry = identityCache[pid] {
            if entry.expiresAt > now {
                lock.unlock()
                if let start = Self.processStartTime(pid),
                   start.sec == entry.startSec, start.usec == entry.startUsec {
                    return entry.identity
                }
                lock.lock()
                if identityCache[pid]?.cachedAt == entry.cachedAt {
                    identityCache.removeValue(forKey: pid)
                }
                lock.unlock()
                // Fall through and re-resolve; the PID was reused.
            } else {
                identityCache.removeValue(forKey: pid)
                lock.unlock()
            }
        } else {
            lock.unlock()
        }

        guard let start = Self.processStartTime(pid) else { return nil }
        let path = Self.executablePath(pid)
        guard !path.isEmpty else { return nil }
        let identity = buildIdentity(pid: pid, path: path)
        lock.lock()
        insertIdentityLocked(CacheEntry(identity: identity, startSec: start.sec,
                                        startUsec: start.usec,
                                        expiresAt: now.addingTimeInterval(Self.cacheTTL),
                                        cachedAt: now),
                             forPid: pid, now: now)
        lock.unlock()
        return identity
    }

    private func insertIdentityLocked(_ entry: CacheEntry, forPid pid: Int32, now: Date) {
        pruneIdentityCacheLocked(now: now)
        if identityCache.count >= Self.identityCacheLimit {
            evictOldestIdentityLocked()
        }
        identityCache[pid] = entry
    }

    private func pruneIdentityCacheLocked(now: Date) {
        var expired: [Int32] = []
        for (pid, entry) in identityCache where entry.expiresAt <= now {
            expired.append(pid)
        }
        for pid in expired {
            identityCache.removeValue(forKey: pid)
        }
    }

    private func evictOldestIdentityLocked() {
        var oldestPid: Int32?
        var oldestAt = Date.distantFuture
        for (pid, entry) in identityCache where entry.cachedAt < oldestAt {
            oldestAt = entry.cachedAt
            oldestPid = pid
        }
        if let oldestPid {
            identityCache.removeValue(forKey: oldestPid)
        }
    }

    func clearCache() {
        lock.lock()
        identityCache.removeAll()
        bundleCache.removeAll()
        noBundlePaths.removeAll()
        inFlightBundles.removeAll()
        bundleResolveCounter = 0
        portCache.removeAll()
        lock.unlock()
    }

    // MARK: - Diagnostics (internal; used by the standalone harness)

    var identityCacheCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return identityCache.count
    }

    var bundleCacheCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bundleCache.count
    }

    var noBundlePathsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return noBundlePaths.count
    }

    /// Number of `enclosingBundle` calls (one per real plist lookup).
    var bundleResolveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bundleResolveCounter
    }

    /// Internal test seam: drives the production bundle-cache path.
    func bundleInfoForTesting(path: String) -> AppBundleInfo? {
        bundleInfo(forPath: path)
    }

    var portCacheCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return portCache.count
    }

    /// Number of libproc scans actually started (cache misses that acquired a permit).
    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scanCounter
    }

    /// Number of scans skipped because every permit was busy past the deadline.
    var scanTimeoutCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scanTimeoutCounter
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
        let now = Date()
        lock.lock()
        if var entry = bundleCache[path] {
            if entry.expiresAt > now {
                entry.lastUsed = now
                bundleCache[path] = entry
                lock.unlock()
                return entry.info
            }
            bundleCache.removeValue(forKey: path)
        }
        if var entry = noBundlePaths[path] {
            if entry.expiresAt > now {
                entry.lastUsed = now
                noBundlePaths[path] = entry
                lock.unlock()
                return nil
            }
            noBundlePaths.removeValue(forKey: path)
        }
        // Another thread is already reading this path's plist: wait for its
        // result instead of issuing a duplicate read (TC-26).
        if let pending = inFlightBundles[path] {
            lock.unlock()
            return awaitBundle(pending, path: path)
        }
        let lookup = InFlightBundleLookup()
        inFlightBundles[path] = lookup
        bundleResolveCounter += 1
        lock.unlock()

        // Reads a real plist: the cache lock is never held across it.
        let info = Self.enclosingBundle(path: path)

        lock.lock()
        insertBundleLocked(info, forPath: path, now: Date())
        lock.unlock()

        lookup.condition.lock()
        lookup.info = info
        lookup.finished = true
        lookup.condition.broadcast()
        lookup.condition.unlock()

        lock.lock()
        if inFlightBundles[path] === lookup { inFlightBundles.removeValue(forKey: path) }
        lock.unlock()
        return info
    }

    /// Waits (bounded) for an in-flight plist read, then resolves directly if the
    /// leader is stuck past the budget, so a slow filesystem cannot return a
    /// confidently wrong "no bundle".
    private func awaitBundle(_ lookup: InFlightBundleLookup, path: String) -> AppBundleInfo? {
        let deadline = Date().addingTimeInterval(Self.bundleWaitSeconds)
        lookup.condition.lock()
        while !lookup.finished {
            if !lookup.condition.wait(until: deadline) { break }
        }
        let finished = lookup.finished
        let info = lookup.info
        lookup.condition.unlock()
        if finished { return info }

        Log.proxy.debug("bundle lookup for \(path) timed out waiting for an in-flight read")
        lock.lock()
        bundleResolveCounter += 1
        lock.unlock()
        let resolved = Self.enclosingBundle(path: path)
        lock.lock()
        insertBundleLocked(resolved, forPath: path, now: Date())
        lock.unlock()
        return resolved
    }

    private func insertBundleLocked(_ info: AppBundleInfo?, forPath path: String, now: Date) {
        pruneBundleCacheLocked(now: now)
        let expiresAt = now.addingTimeInterval(Self.bundleCacheTTL)
        if let info {
            noBundlePaths.removeValue(forKey: path)
            bundleCache[path] = BundleEntry(info: info, expiresAt: expiresAt, lastUsed: now)
            Self.trimBundleCache(&bundleCache, lastUsed: \.lastUsed)
        } else {
            bundleCache.removeValue(forKey: path)
            noBundlePaths[path] = NoBundleEntry(expiresAt: expiresAt, lastUsed: now)
            Self.trimBundleCache(&noBundlePaths, lastUsed: \.lastUsed)
        }
    }

    private func pruneBundleCacheLocked(now: Date) {
        var expiredBundles: [String] = []
        for (path, entry) in bundleCache where entry.expiresAt <= now {
            expiredBundles.append(path)
        }
        for path in expiredBundles { bundleCache.removeValue(forKey: path) }

        var expiredNoBundle: [String] = []
        for (path, entry) in noBundlePaths where entry.expiresAt <= now {
            expiredNoBundle.append(path)
        }
        for path in expiredNoBundle { noBundlePaths.removeValue(forKey: path) }
    }

    /// Evicts the least-recently-used entries one at a time; never clears the
    /// whole cache at the cap (TC-26).
    private static func trimBundleCache<T>(_ cache: inout [String: T],
                                           lastUsed: KeyPath<T, Date>) {
        while cache.count > bundleCacheLimit {
            var oldestKey: String?
            var oldest = Date.distantFuture
            for (key, entry) in cache where entry[keyPath: lastUsed] < oldest {
                oldest = entry[keyPath: lastUsed]
                oldestKey = key
            }
            guard let oldestKey else { break }
            cache.removeValue(forKey: oldestKey)
        }
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
    /// `buffers` is reused across calls; see `ScanBuffers`.
    private static func pidForLoopbackConnection(localPort: UInt16, proxyPort: UInt16,
                                                 buffers: ScanBuffers) -> Int32? {
        let pidBytes = buffers.pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress,
                          Int32(maxPids * MemoryLayout<pid_t>.size))
        }
        guard pidBytes > 0 else { return nil }
        let pidCount = min(Int(pidBytes) / MemoryLayout<pid_t>.size, maxPids)

        for i in 0..<pidCount {
            let pid = buffers.pids[i]
            if pid <= 0 { continue }
            let fdBytes = buffers.fds.withUnsafeMutableBytes {
                proc_pidinfo(pid, Int32(PROC_PIDLISTFDS), 0, $0.baseAddress,
                             Int32(maxFds * MemoryLayout<proc_fdinfo>.size))
            }
            if fdBytes <= 0 { continue }
            let fdCount = min(Int(fdBytes) / MemoryLayout<proc_fdinfo>.size, maxFds)
            for j in 0..<fdCount {
                let fdInfo = buffers.fds[j]
                guard Int32(fdInfo.proc_fdtype) == PROX_FDTYPE_SOCKET else { continue }
                let rc = withUnsafeMutablePointer(to: &buffers.sock) {
                    proc_pidfdinfo(pid, fdInfo.proc_fd, Int32(PROC_PIDFDSOCKETINFO),
                                   $0, Int32(MemoryLayout<socket_fdinfo>.size))
                }
                guard rc > 0 else { continue }
                guard buffers.sock.psi.soi_kind == sockInfoTCP,
                      buffers.sock.psi.soi_family == AF_INET else { continue }
                let ini = buffers.sock.psi.soi_proto.pri_tcp.tcpsi_ini
                let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
                let fport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
                if lport == localPort && fport == proxyPort { return pid }
            }
        }
        return nil
    }
}
