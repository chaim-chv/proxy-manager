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

func openDB(_ path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
    return db
}

func exec(_ db: OpaquePointer?, _ sql: String) {
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

try? FileManager.default.removeItem(atPath: freshPath)
try? FileManager.default.removeItem(atPath: legacyPath)
try? FileManager.default.removeItem(atPath: freshPath + "-wal")
try? FileManager.default.removeItem(atPath: freshPath + "-shm")
try? FileManager.default.removeItem(atPath: legacyPath + "-wal")
try? FileManager.default.removeItem(atPath: legacyPath + "-shm")

print("")
if failures == 0 { print("PASS: telemetry"); exit(0) }
else { print("FAIL: \(failures) telemetry check(s) failed"); exit(1) }
