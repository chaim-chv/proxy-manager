import Foundation
import SQLite3

// Standalone harness for the telemetry store's per-app columns (no XCTest/SPM).
//
// Build + run (see Tests/run-all.sh):
//   xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
//     Sources/Config/ConfigModels.swift Sources/Telemetry/TelemetryStore.swift \
//     Tests/TelemetryHarness/main.swift -o /tmp/telemetry && /tmp/telemetry
//
// Covers the schema migration that must not break an existing install: a
// `requests` table created before per-app telemetry lacks `app`/`app_bundle`,
// so the store must ALTER it in and keep writing (and the old rows must
// survive). Also checks that app/app_bundle persist and that `topApps` groups.

setbuf(stdout, nil)

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

/// Pumps the main run loop in short slices until `condition` holds or the
/// timeout expires. The telemetry store hops UI work onto the main queue and
/// runs its 10 Hz flusher on a global queue, so a plain `Thread.sleep` would
/// neither run `applyToUI` nor be deterministic.
func pumpMain(timeout: TimeInterval = 5, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

/// Pumps the main queue for a bounded slice so at least one 10 Hz flush tick
/// (0.1 s) is guaranteed to have completed, then returns.
func pumpMain(seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

func openDB(_ path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
    return db
}

@discardableResult
func exec(_ db: OpaquePointer?, _ sql: String) -> Int32 {
    sqlite3_exec(db, sql, nil, nil, nil)
}

func queryString(_ db: OpaquePointer?, _ sql: String) -> String? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: c)
}

func queryInt(_ db: OpaquePointer?, _ sql: String) -> Int? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int64(stmt, 0))
}

func openFDCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}

func fileSize(_ path: String) -> Int64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? NSNumber else { return nil }
    return size.int64Value
}

func columns(_ db: OpaquePointer?) -> Set<String> {
    var out = Set<String>()
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(requests);", -1, &stmt, nil) == SQLITE_OK else { return out }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let c = sqlite3_column_text(stmt, 1) { out.insert(String(cString: c)) }
    }
    return out
}

let tmpDir = NSTemporaryDirectory()

print("== fresh database writes app columns ==")
let freshPath = tmpDir + "pm-telemetry-fresh-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: freshPath)
let store = TelemetryStore(dbURL: URL(fileURLWithPath: freshPath), maxRows: 1000, retentionDays: 1)
store.record(RequestEvent(host: "a.example", route: .tunnel, app: "Google Chrome", appBundle: "com.google.Chrome"))
store.record(RequestEvent(host: "b.example", route: .direct, app: "node"))
store.flushNow()

if let db = openDB(freshPath) {
    check("app column created", columns(db).contains("app"))
    check("app_bundle column created", columns(db).contains("app_bundle"))
    check("both rows persisted", queryInt(db, "SELECT COUNT(*) FROM requests") == 2)
    check("app stored", queryString(db, "SELECT app FROM requests WHERE host='a.example'") == "Google Chrome")
    check("app_bundle stored", queryString(db, "SELECT app_bundle FROM requests WHERE host='a.example'") == "com.google.Chrome")
    check("missing app_bundle stored as NULL",
          queryInt(db, "SELECT COUNT(*) FROM requests WHERE host='b.example' AND app_bundle IS NULL") == 1)
    sqlite3_close(db)
} else {
    check("open fresh DB", false)
}

print("== topApps groups by app ==")
// `topApps` delivers on the main queue, so pump the run loop rather than
// blocking the main thread on a semaphore (which would deadlock).
var topResult: [(app: String, bundle: String?, count: Int)] = []
var topDone = false
store.topApps(rangeSeconds: 3600, limit: 10) { topResult = $0; topDone = true }
let deadline = Date().addingTimeInterval(5)
while !topDone && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
check("topApps returns both apps", topResult.count == 2)
check("topApps never returns empty app names", topResult.allSatisfy { !$0.app.isEmpty })
check("topApps carries the bundle id for the icon",
      topResult.contains { $0.bundle == "com.google.Chrome" })

print("== migration of a pre-per-app database ==")
let legacyPath = tmpDir + "pm-telemetry-legacy-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: legacyPath)
if let old = openDB(legacyPath) {
    // The exact pre-per-app schema (no app / app_bundle).
    exec(old, """
    CREATE TABLE requests (
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, scheme TEXT, method TEXT,
        host TEXT NOT NULL, port INTEGER, path TEXT, route TEXT NOT NULL, status INTEGER,
        bytes_in INTEGER DEFAULT 0, bytes_out INTEGER DEFAULT 0, duration_ms INTEGER,
        error TEXT, src_port INTEGER
    );
    """)
    exec(old, "INSERT INTO requests (ts, host, route, status) VALUES (1, 'legacy.example', 'TUNNEL', 200);")
    sqlite3_close(old)
} else {
    check("create legacy DB", false)
}

let store2 = TelemetryStore(dbURL: URL(fileURLWithPath: legacyPath), maxRows: 1000, retentionDays: 1)
store2.record(RequestEvent(host: "new.example", route: .tunnel, app: "Safari", appBundle: "com.apple.Safari"))
store2.flushNow()

if let db2 = openDB(legacyPath) {
    check("migration added app column", columns(db2).contains("app"))
    check("migration added app_bundle column", columns(db2).contains("app_bundle"))
    check("legacy row preserved", queryInt(db2, "SELECT COUNT(*) FROM requests WHERE host='legacy.example'") == 1)
    check("legacy row has NULL app", queryInt(db2, "SELECT COUNT(*) FROM requests WHERE host='legacy.example' AND app IS NULL") == 1)
    check("new row written after migration", queryString(db2, "SELECT app FROM requests WHERE host='new.example'") == "Safari")
    sqlite3_close(db2)
} else {
    check("open migrated DB", false)
}

print("== locked DB keeps rows queued and writes them after unlock ==")
let lockedPath = tmpDir + "pm-telemetry-locked-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: lockedPath)
let lockedStore = TelemetryStore(dbURL: URL(fileURLWithPath: lockedPath), maxRows: 1000, retentionDays: 1)
let holder = openDB(lockedPath)
check("holder connection opened", holder != nil)
check("holder acquired the write lock", exec(holder, "BEGIN IMMEDIATE;") == SQLITE_OK)
lockedStore.record(RequestEvent(host: "locked.example", route: .tunnel, app: "Locked"))
let lockStart = Date()
lockedStore.flushNow()
let lockElapsed = Date().timeIntervalSince(lockStart)
check("flushNow returns while DB is locked (no hang)", lockElapsed < 8)
check("locked store reports itself available (prepare succeeded)", !lockedStore.telemetryUnavailable)
exec(holder, "ROLLBACK;")
if let holder { sqlite3_close(holder) }
lockedStore.flushNow()
if let db = openDB(lockedPath) {
    check("queued row persisted after the lock was released",
          queryInt(db, "SELECT COUNT(*) FROM requests WHERE host='locked.example'") == 1)
    sqlite3_close(db)
} else {
    check("open locked DB", false)
}

print("== retention trims to maxRows in bounded chunks ==")
let capPath = tmpDir + "pm-telemetry-cap-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: capPath)
let capStore = TelemetryStore(dbURL: URL(fileURLWithPath: capPath), maxRows: 100, retentionDays: 3650)
for i in 0..<12_000 {
    capStore.record(RequestEvent(host: "cap\(i).example", route: .direct))
}
capStore.flushNow()
if let db = openDB(capPath) {
    check("all rows persisted before the trim", queryInt(db, "SELECT COUNT(*) FROM requests") == 12_000)
    sqlite3_close(db)
} else {
    check("open max-rows DB", false)
}
capStore.runRetentionNow()
if let db = openDB(capPath) {
    check("max-rows trim converges to the cap", queryInt(db, "SELECT COUNT(*) FROM requests") == 100)
    check("trim keeps the newest rows",
          queryInt(db, "SELECT COUNT(*) FROM requests WHERE id > 11900") == 100)
    sqlite3_close(db)
} else {
    check("open trimmed DB", false)
}
check("max-rows trim used multiple bounded chunks (12k rows, 5k per batch)",
      capStore.lastRetentionDeleteChunks >= 2)

print("== retention removes expired rows and keeps recent ones ==")
let expiryPath = tmpDir + "pm-telemetry-expiry-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: expiryPath)
let expiryStore = TelemetryStore(dbURL: URL(fileURLWithPath: expiryPath), maxRows: 100_000, retentionDays: 1)
let oldTs = Int64(Date().timeIntervalSince1970 * 1000) - 3 * 86_400_000
for i in 0..<20 {
    expiryStore.record(RequestEvent(ts: oldTs, host: "old\(i).example"))
}
for i in 0..<5 {
    expiryStore.record(RequestEvent(host: "recent\(i).example"))
}
expiryStore.flushNow()
expiryStore.runRetentionNow()
if let db = openDB(expiryPath) {
    check("expired rows removed", queryInt(db, "SELECT COUNT(*) FROM requests WHERE host LIKE 'old%'") == 0)
    check("recent rows kept", queryInt(db, "SELECT COUNT(*) FROM requests WHERE host LIKE 'recent%'") == 5)
    check("only recent rows remain", queryInt(db, "SELECT COUNT(*) FROM requests") == 5)
    sqlite3_close(db)
} else {
    check("open expiry DB", false)
}

print("== flushNow checkpoints/truncates the WAL and purge vacuums ==")
let walPath = tmpDir + "pm-telemetry-wal-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: walPath)
let walStore = TelemetryStore(dbURL: URL(fileURLWithPath: walPath), maxRows: 1000, retentionDays: 1)
for i in 0..<200 {
    walStore.record(RequestEvent(host: "wal\(i).example"))
}
walStore.flushNow()
let walSize = fileSize(walPath + "-wal") ?? 0
check("WAL truncated after flushNow (\(walSize) bytes)", walSize <= 1_000_000)
if let db = openDB(walPath) {
    check("rows persisted before the checkpoint", queryInt(db, "SELECT COUNT(*) FROM requests") == 200)
    sqlite3_close(db)
} else {
    check("open WAL DB", false)
}

walStore.purge()
walStore.flushNow() // drains the purge/VACUUM queued ahead of this sync
let walAfterPurge = fileSize(walPath + "-wal") ?? 0
check("WAL truncated after user purge (\(walAfterPurge) bytes)", walAfterPurge <= 1_000_000)
if let db = openDB(walPath) {
    check("user purge deleted all rows", queryInt(db, "SELECT COUNT(*) FROM requests") == 0)
    check("VACUUM returned freed pages (freelist 0)", queryInt(db, "PRAGMA freelist_count") == 0)
    sqlite3_close(db)
} else {
    check("open purged DB", false)
}

print("== hostile retention values are clamped, cutoff cannot overflow ==")
let hostile = Data(#"{"monitor":{"retentionDays":9223372036854775807,"maxRows":-5}}"#.utf8)
if let config = try? JSONDecoder().decode(AppConfig.self, from: hostile) {
    check("huge retentionDays clamped to 3650", config.monitor.retentionDays == 3650)
    check("negative maxRows clamped to 0", config.monitor.maxRows == 0)
} else {
    check("decode hostile monitor settings", false)
}
let hugeRows = Data(#"{"monitor":{"maxRows":9223372036854775807}}"#.utf8)
if let config = try? JSONDecoder().decode(AppConfig.self, from: hugeRows) {
    check("huge maxRows clamped to 10,000,000", config.monitor.maxRows == 10_000_000)
} else {
    check("decode huge maxRows", false)
}
let nowMs: Int64 = 1_700_000_000_000
check("normal cutoff computed",
      TelemetryStore.retentionCutoffMs(nowMs: nowMs, days: 7) == nowMs - 7 * 86_400_000)
check("Int.max days falls back to Int64.min without trapping",
      TelemetryStore.retentionCutoffMs(nowMs: nowMs, days: Int.max) == Int64.min)
check("cutoff subtraction underflow falls back to Int64.min",
      TelemetryStore.retentionCutoffMs(nowMs: Int64.min, days: 1) == Int64.min)

print("== oversized event fields are clamped in the feed and DB (TM-08) ==")
let clampPath = tmpDir + "pm-telemetry-clamp-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: clampPath)
let clampStore = TelemetryStore(dbURL: URL(fileURLWithPath: clampPath), maxRows: 1000, retentionDays: 1)
let hugeField = String(repeating: "x", count: 60_000)
clampStore.record(RequestEvent(host: hugeField, path: hugeField, error: hugeField,
                               app: hugeField, appBundle: hugeField))
pumpMain { clampStore.recentRequests.count == 1 }
clampStore.flushNow()
let clampedFeed = clampStore.recentRequests.first
check("feed host is clamped to 255", clampedFeed?.host.count == 255)
check("feed path is clamped to 2,048", clampedFeed?.path.count == 2_048)
check("feed error is clamped to 1,024", clampedFeed?.error?.count == 1_024)
check("feed app is clamped to 255", clampedFeed?.app?.count == 255)
check("feed appBundle is clamped to 255", clampedFeed?.appBundle?.count == 255)
if let db = openDB(clampPath) {
    check("DB host is clamped to 255",
          queryInt(db, "SELECT length(host) FROM requests LIMIT 1") == 255)
    check("DB path is clamped to 2,048",
          queryInt(db, "SELECT length(path) FROM requests LIMIT 1") == 2_048)
    check("DB error is clamped to 1,024",
          queryInt(db, "SELECT length(error) FROM requests LIMIT 1") == 1_024)
    check("DB app is clamped to 255",
          queryInt(db, "SELECT length(app) FROM requests LIMIT 1") == 255)
    check("DB app_bundle is clamped to 255",
          queryInt(db, "SELECT length(app_bundle) FROM requests LIMIT 1") == 255)
    sqlite3_close(db)
} else {
    check("open clamp DB", false)
}

print("== recentRequests byte budget trims below the row cap (TM-08) ==")
let budgetPath = tmpDir + "pm-telemetry-budget-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: budgetPath)
let budgetStore = TelemetryStore(dbURL: URL(fileURLWithPath: budgetPath),
                                 maxRows: 100_000, retentionDays: 1)
for _ in 0..<3_000 {
    budgetStore.record(RequestEvent(host: hugeField, path: hugeField, error: hugeField,
                                    app: hugeField, appBundle: hugeField))
}
pumpMain { budgetStore.recentRequests.count > 0 }
pumpMain(seconds: 0.5)
check("byte budget keeps fewer rows than the 5,000-row cap",
      budgetStore.recentRequests.count > 0 && budgetStore.recentRequests.count < 3_000)
check("estimated feed bytes stay within the budget (\(budgetStore.recentRequestsApproxBytes) <= \(TelemetryStore.recentRequestsByteBudget))",
      budgetStore.recentRequestsApproxBytes <= TelemetryStore.recentRequestsByteBudget)
check("a large batch still reaches SQLite", {
    budgetStore.flushNow()
    guard let db = openDB(budgetPath) else { return false }
    defer { sqlite3_close(db) }
    return queryInt(db, "SELECT COUNT(*) FROM requests") == 3_000
}())

print("== unavailable DB path does not crash or hang flushNow ==")
let missingDir = tmpDir + "pm-telemetry-missing-\(getpid())"
let missingPath = missingDir + "/telemetry.sqlite"
try? FileManager.default.removeItem(atPath: missingDir)
let fdsBeforeOpenFailures = openFDCount()
let badStore = TelemetryStore(dbURL: URL(fileURLWithPath: missingPath), maxRows: 1000, retentionDays: 1)
check("open failure marks telemetry unavailable", badStore.telemetryUnavailable)
check("open failure does not report a quarantine", badStore.dbQuarantineCount == 0)
for _ in 0..<5 {
    _ = TelemetryStore(dbURL: URL(fileURLWithPath: missingPath), maxRows: 1000, retentionDays: 1)
}
let fdsAfterOpenFailures = openFDCount()
check("repeated open failures do not leak file descriptors (\(fdsBeforeOpenFailures) -> \(fdsAfterOpenFailures))",
      fdsAfterOpenFailures <= fdsBeforeOpenFailures + 2)
badStore.record(RequestEvent(host: "nowhere.example"))
let badStart = Date()
badStore.flushNow()
check("flushNow returns promptly with an unavailable DB", Date().timeIntervalSince(badStart) < 3)
check("store survives the failed flush", badStore.telemetryUnavailable)

print("== corrupt DB is quarantined and recreated (TM-11) ==")
let corruptPath = tmpDir + "pm-telemetry-corrupt-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: corruptPath)
try? FileManager.default.removeItem(atPath: corruptPath + "-wal")
try? FileManager.default.removeItem(atPath: corruptPath + "-shm")
try? Data("this is definitely not a sqlite database".utf8)
    .write(to: URL(fileURLWithPath: corruptPath))
let corruptStore = TelemetryStore(dbURL: URL(fileURLWithPath: corruptPath),
                                  maxRows: 1000, retentionDays: 1)
check("corrupt DB recovery leaves telemetry available", !corruptStore.telemetryUnavailable)
check("corrupt DB was quarantined exactly once", corruptStore.dbQuarantineCount == 1)
let corruptBaseName = URL(fileURLWithPath: corruptPath).lastPathComponent
let quarantinedFiles = ((try? FileManager.default.contentsOfDirectory(atPath: tmpDir)) ?? [])
    .filter { $0.hasPrefix(corruptBaseName + ".corrupt-") }
check("quarantine file exists", !quarantinedFiles.isEmpty)
corruptStore.record(RequestEvent(host: "after-corrupt.example", route: .tunnel))
corruptStore.flushNow()
if let db = openDB(corruptPath) {
    check("recording works against the recreated DB",
          queryInt(db, "SELECT COUNT(*) FROM requests WHERE host='after-corrupt.example'") == 1)
    check("recreated DB passes integrity_check",
          queryString(db, "PRAGMA integrity_check") == "ok")
    sqlite3_close(db)
} else {
    check("open recreated DB", false)
}
for name in quarantinedFiles {
    try? FileManager.default.removeItem(atPath: tmpDir + name)
}

print("== live limit change applies without relaunch ==")
let livePath = tmpDir + "pm-telemetry-live-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: livePath)
let liveStore = TelemetryStore(dbURL: URL(fileURLWithPath: livePath), maxRows: 500_000, retentionDays: 7)
let twoDaysAgo = Int64(Date().timeIntervalSince1970 * 1000) - 2 * 86_400_000
liveStore.record(RequestEvent(ts: twoDaysAgo, host: "old-live.example"))
liveStore.record(RequestEvent(host: "recent-live.example"))
liveStore.flushNow()
liveStore.setLimits(maxRows: 500_000, retentionDays: 1)
let liveLimits = liveStore.currentLimits()
check("setLimits is visible on the running store",
      liveLimits.maxRows == 500_000 && liveLimits.retentionDays == 1)
liveStore.runRetentionNow()
if let db = openDB(livePath) {
    check("lowered retentionDays purges 2-day-old row immediately",
          queryInt(db, "SELECT COUNT(*) FROM requests WHERE host='old-live.example'") == 0)
    check("recent row survives the new retention window",
          queryInt(db, "SELECT COUNT(*) FROM requests WHERE host='recent-live.example'") == 1)
    sqlite3_close(db)
} else {
    check("open live-limits DB", false)
}

print("== live maxRows change trims down to the new cap ==")
let liveCapPath = tmpDir + "pm-telemetry-live-cap-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: liveCapPath)
let liveCapStore = TelemetryStore(dbURL: URL(fileURLWithPath: liveCapPath), maxRows: 100_000, retentionDays: 3650)
for i in 0..<50 {
    liveCapStore.record(RequestEvent(host: "live-cap\(i).example", route: .direct))
}
liveCapStore.flushNow()
liveCapStore.setLimits(maxRows: 10, retentionDays: 3650)
let capLimits = liveCapStore.currentLimits()
check("setLimits updates maxRows without reconstruction", capLimits.maxRows == 10)
liveCapStore.runRetentionNow()
if let db = openDB(liveCapPath) {
    check("lowered maxRows converges to 10 rows", queryInt(db, "SELECT COUNT(*) FROM requests") == 10)
    check("trim keeps the newest rows", queryInt(db, "SELECT COUNT(*) FROM requests WHERE id > 40") == 10)
    sqlite3_close(db)
} else {
    check("open live-cap DB", false)
}
liveCapStore.setLimits(maxRows: -5, retentionDays: 999_999)
let clamped = liveCapStore.currentLimits()
check("setLimits clamps maxRows to 0...10,000,000", clamped.maxRows == 0)
check("setLimits clamps retentionDays to 1...3650", clamped.retentionDays == 3650)

print("== purge drops an in-flight session instead of resurrecting it ==")
let purgePath = tmpDir + "pm-telemetry-purge-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: purgePath)
let purgeStore = TelemetryStore(dbURL: URL(fileURLWithPath: purgePath), maxRows: 1000, retentionDays: 1)
let purgedSession = purgeStore.beginSession(RequestEvent(host: "purged-live.example", route: .tunnel))
purgeStore.record(RequestEvent(host: "purged-pending.example", route: .direct))
purgeStore.purge()
purgeStore.endSession(purgedSession, RequestEvent(host: "purged-live.example", route: .tunnel))
// A post-purge live session forces a flush tick to publish UI work, proving
// that the stale completion above was not merely waiting in `pending`.
let markerSession = purgeStore.beginSession(RequestEvent(host: "marker-live.example", route: .tunnel))
pumpMain { purgeStore.liveRequests.contains { $0.host == "marker-live.example" } }
check("purged live session is not published as a completed row",
      purgeStore.recentRequests.isEmpty)
check("purged live row is not in the feed",
      !purgeStore.liveRequests.contains { $0.host == "purged-live.example" })
purgeStore.flushNow()
if let db = openDB(purgePath) {
    check("purged in-flight session never reaches SQLite",
          queryInt(db, "SELECT COUNT(*) FROM requests WHERE host='purged-live.example'") == 0)
    check("pre-purge pending event never reaches SQLite",
          queryInt(db, "SELECT COUNT(*) FROM requests") == 0)
    sqlite3_close(db)
} else {
    check("open purge DB", false)
}
purgeStore.endSession(markerSession, RequestEvent(host: "marker-live.example", route: .tunnel))

print("== purge + flushNow cannot re-insert a pre-purge batch ==")
let purgeBatchPath = tmpDir + "pm-telemetry-purge-batch-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: purgeBatchPath)
let purgeBatchStore = TelemetryStore(dbURL: URL(fileURLWithPath: purgeBatchPath), maxRows: 1000, retentionDays: 1)
for i in 0..<1_200 {
    purgeBatchStore.record(RequestEvent(host: "purge-batch\(i).example", route: .direct))
}
purgeBatchStore.purge()
purgeBatchStore.flushNow()
if let db = openDB(purgeBatchPath) {
    check("flushNow after purge writes zero rows", queryInt(db, "SELECT COUNT(*) FROM requests") == 0)
    sqlite3_close(db)
} else {
    check("open purge-batch DB", false)
}

print("== purge preserves live active connections and clears stats ==")
let purgeStatsPath = tmpDir + "pm-telemetry-purge-stats-\(getpid()).sqlite"
try? FileManager.default.removeItem(atPath: purgeStatsPath)
let purgeStatsStore = TelemetryStore(dbURL: URL(fileURLWithPath: purgeStatsPath), maxRows: 1000, retentionDays: 1)
let liveSession = purgeStatsStore.beginSession(RequestEvent(host: "stats-live.example", route: .tunnel))
purgeStatsStore.record(RequestEvent(host: "stats-pre.example", route: .tunnel,
                                    bytesIn: 10, bytesOut: 20))
purgeStatsStore.purge()
pumpMain { purgeStatsStore.stats.activeConnections >= 1 }
check("purge keeps activeConnections for a live session",
      purgeStatsStore.stats.activeConnections >= 1)
check("purge zeroes request counters", purgeStatsStore.stats.totalRequests == 0)
check("purge zeroes byte counters",
      purgeStatsStore.stats.bytesIn == 0 && purgeStatsStore.stats.bytesOut == 0)
check("purge clears the live feed row",
      !purgeStatsStore.liveRequests.contains { $0.host == "stats-live.example" })
purgeStatsStore.endSession(liveSession, RequestEvent(host: "stats-live.example", route: .tunnel))
pumpMain(seconds: 0.3)
check("a purged session that ends later does not return to the feed",
      !purgeStatsStore.recentRequests.contains { $0.host == "stats-live.example" })

for base in [freshPath, legacyPath, lockedPath, capPath, expiryPath, walPath, livePath, liveCapPath,
             purgePath, purgeBatchPath, purgeStatsPath, clampPath, budgetPath, corruptPath] {
    try? FileManager.default.removeItem(atPath: base)
    try? FileManager.default.removeItem(atPath: base + "-wal")
    try? FileManager.default.removeItem(atPath: base + "-shm")
}

print("")
if failures == 0 { print("PASS: telemetry"); exit(0) }
else { print("FAIL: \(failures) telemetry check(s) failed"); exit(1) }
