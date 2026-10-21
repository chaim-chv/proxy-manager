import Foundation
import os
import SQLite3

/// Tells SQLite to copy the bound string immediately. `nil`/`SQLITE_STATIC`
/// would store a raw pointer into a temporary `NSString` that is released before
/// `sqlite3_step` runs — a use-after-free.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Same subsystem/category as `Log.telemetry`, declared locally so this file
/// still compiles in the standalone TelemetryHarness (which does not link
/// `Support/Log.swift`).
private let telemetryLog = Logger(subsystem: "com.proxymanager.app", category: "telemetry")

struct RequestEvent: Identifiable, Equatable {
    let id: UUID
    var ts: Int64
    var scheme: String
    var method: String
    var host: String
    var port: UInt16
    var path: String
    var route: Route
    var status: Int
    var bytesIn: Int64
    var bytesOut: Int64
    var durationMs: Int64
    var error: String?
    var srcPort: Int
    /// Originating app display name, when per-app routing/telemetry is enabled.
    var app: String?
    /// Stable app identity (bundle id) when available; nil for CLI tools.
    var appBundle: String?

    init(id: UUID = UUID(), ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
         scheme: String = "https", method: String = "CONNECT", host: String = "",
         port: UInt16 = 443, path: String = "", route: Route = .direct,
         status: Int = 0, bytesIn: Int64 = 0, bytesOut: Int64 = 0,
         durationMs: Int64 = 0, error: String? = nil, srcPort: Int = 0,
         app: String? = nil, appBundle: String? = nil) {
        self.id = id
        self.ts = ts
        self.scheme = scheme
        self.method = method
        self.host = host
        self.port = port
        self.path = path
        self.route = route
        self.status = status
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.durationMs = durationMs
        self.error = error
        self.srcPort = srcPort
        self.app = app
        self.appBundle = appBundle
    }

    /// Copy with a new byte/duration snapshot (used for live rows while the
    /// connection is still open). Metadata (id/ts/host/route/...) is immutable.
    func snapshot(bytesIn: Int64, bytesOut: Int64, durationMs: Int64) -> RequestEvent {
        RequestEvent(id: id, ts: ts, scheme: scheme, method: method, host: host,
                     port: port, path: path, route: route, status: status,
                     bytesIn: bytesIn, bytesOut: bytesOut, durationMs: durationMs,
                     error: error, srcPort: srcPort, app: app, appBundle: appBundle)
    }
}

struct StatsSnapshot: Equatable {
    var tunneledRequests: Int = 0
    var directRequests: Int = 0
    var blockedRequests: Int = 0
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var activeConnections: Int = 0

    var totalRequests: Int { tunneledRequests + directRequests + blockedRequests }
}

/// One aggregated time bucket for a single route, used by the dashboard charts.
/// `bucketMs` is the bucket start (unix ms); `errors` counts rows with a
/// status >= 400 or a recorded error.
struct ChartBucket: Equatable {
    let bucketMs: Int64
    let route: Route
    let count: Int
    let bytesIn: Int64
    let bytesOut: Int64
    let errors: Int
}

/// High-throughput telemetry store.
///
/// Performance model: the proxy core calls `record(_:)` from its relay threads
/// at potentially thousands of requests/sec. `record` is O(1) — it only locks,
/// appends to an in-memory buffer and accumulates a stats delta. No SQLite, no
/// dispatch, no UI work happens per request.
///
/// Long-lived connections (CONNECT tunnels that stay open for keep-alive /
/// streaming) used to be invisible until they closed, then appeared minutes
/// later with a duration equal to their whole lifetime. The proxy can't see
/// into the TLS byte stream, so "when did the request finish" is unknowable —
/// instead the connection shows up in the live feed the moment it is
/// established and stays there until it closes:
///
///  - `beginSession` is O(1) (lock + register); it publishes a live feed row.
///  - `updateSession` is O(1) (session lock + add) and is safe to call per
///    relay iteration; the 10 Hz flusher publishes the current byte count.
///  - `endSession` finalizes the row (same UUID) as a normal completed event.
///
/// A single background flusher (10 Hz) drains the buffer and:
///  - publishes the live feed + stats to the UI (batched, throttled), and
///  - batches rows into a prepared SQLite `INSERT` inside a single transaction
///    (a few writes/sec, not thousands).
final class TelemetryStore: ObservableObject {
    static let liveFeedCapacity = 5000
    static let dbBatchSize = 1000

    /// A connection currently in the relay. `bytes` is written by the owning
    /// relay thread and read by the 10 Hz flusher.
    private final class LiveSession {
        let event: RequestEvent
        let lock = NSLock()
        var bytesIn: Int64 = 0
        var bytesOut: Int64 = 0
        var publishedIn: Int64 = 0
        var publishedOut: Int64 = 0
        var lastPublishMs: Int64 = 0
        init(event: RequestEvent) { self.event = event }
    }

    @Published var recentRequests: [RequestEvent] = []
    /// In-progress connections, newest first. Rows appear here the moment a
    /// connection is established and move to `recentRequests` when it closes.
    @Published private(set) var liveRequests: [RequestEvent] = []
    @Published var stats = StatsSnapshot()

    private let dbURL: URL
    /// Live retention limits, guarded by `lock`. Read as one snapshot by the
    /// retention pass so a concurrent `setLimits` cannot mix the pair.
    private var maxRows: Int
    private var retentionDays: Int
    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?

    /// Set when the DB could not be opened or the INSERT could not be prepared;
    /// writes are kept in the retry queue instead of being silently discarded.
    private(set) var telemetryUnavailable = false

    private let dbQueue = DispatchQueue(label: "com.proxymanager.telemetry.db")
    private let lock = NSLock()

    private var pending: [RequestEvent] = []
    private var pendingDelta = StatsSnapshot()
    private var dbAccumulator: [RequestEvent] = []
    private var activeCount = 0
    private var lastPurgeMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)

    /// Bumped by `purge()` under `lock`. Work captured before the bump (UI
    /// blocks, insert batches, completion appends) is stale: applying it after
    /// the clear would resurrect rows/stats the user asked to delete.
    private var generation: UInt64 = 0

    // Failed batches stay queued (bounded) instead of being dropped on a
    // transient lock. Guarded by `lock`; SQLite work never runs under it.
    private var retryBatches: [[RequestEvent]] = []
    private var retryEventCount = 0
    private var retryAfterMs: Int64 = 0
    private var retryDropReported = false
    private var lastDbErrorLogMs: Int64 = 0
    private var suppressedDbErrors = 0

    private static let maxRetryBatches = 4
    private static let maxRetryEvents = 50_000
    private static let retryBackoffMs: Int64 = 2_000

    /// Rows touched by one trim statement. Bounds the work (and the rollback
    /// journal) of a single autocommit instead of materialising the whole
    /// excess in one multi-second `LIMIT -1 OFFSET` delete.
    private static let trimChunkSize = 5_000
    /// Safety cap per trim pass (5,000 × 2,000 = 10M rows). A larger backlog is
    /// left for the next pass and logged rather than monopolising `dbQueue`.
    private static let trimMaxIterations = 2_000

    /// Test seam: how many bounded DELETE statements the last retention pass
    /// actually executed. Written on `dbQueue`, so it is safe to read after
    /// `runRetentionNow()` returns.
    private(set) var lastRetentionDeleteChunks = 0

    private var flusher: DispatchSourceTimer?

    /// Live-session bookkeeping (guarded by `lock`).
    private var sessions: [UUID: LiveSession] = [:]
    private var sessionOrder: [UUID] = []
    private var pendingLiveStarts: [RequestEvent] = []
    private var pendingFinishes: [UUID] = []

    init(dbURL: URL, maxRows: Int = 500_000, retentionDays: Int = 7) {
        self.dbURL = dbURL
        self.maxRows = Self.clampMaxRows(maxRows)
        self.retentionDays = Self.clampRetentionDays(retentionDays)
        openDatabase()
        createSchema()
        migrateSchema()
        prepareStatements()
        startFlusher()
    }

    deinit {
        flusher?.cancel()
        sqlite3_finalize(insertStmt)
        if let db = db { sqlite3_close(db) }
    }

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            telemetryUnavailable = true
            let message = String(cString: sqlite3_errmsg(db))
            telemetryLog.error("failed to open telemetry DB: \(message, privacy: .public)")
            db = nil
        }
        if let db = db {
            sqlite3_busy_timeout(db, 2_000)
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA cache_size=-8000;", nil, nil, nil)
            // Cap how much WAL a checkpoint leaves behind. Without this the
            // `-wal` sidecar grows to the peak write volume and never shrinks.
            execChecked(db, "PRAGMA journal_size_limit=33554432;", "journal_size_limit pragma")
        }
    }

    private func createSchema() {
        guard let db = db else { return }
        let schema = """
        CREATE TABLE IF NOT EXISTS requests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            scheme TEXT,
            method TEXT,
            host TEXT NOT NULL,
            port INTEGER,
            path TEXT,
            route TEXT NOT NULL,
            status INTEGER,
            bytes_in INTEGER DEFAULT 0,
            bytes_out INTEGER DEFAULT 0,
            duration_ms INTEGER,
            error TEXT,
            src_port INTEGER,
            app TEXT,
            app_bundle TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_requests_ts ON requests(ts);
        CREATE INDEX IF NOT EXISTS idx_requests_host ON requests(host);
        CREATE INDEX IF NOT EXISTS idx_requests_route ON requests(route);
        -- `minute_stats` was a write-only aggregate (never queried); drop it on
        -- upgrade. Charts read the `requests` table directly.
        DROP TABLE IF EXISTS minute_stats;
        """
        execChecked(db, schema, "schema creation")
    }

    /// Adds columns introduced after the first release to an existing DB.
    /// `CREATE TABLE IF NOT EXISTS` never alters an existing table, so a DB from
    /// a build before per-app telemetry lacks `app`/`app_bundle` and the new
    /// `INSERT` (which names them) would fail every write. Guarded by
    /// `PRAGMA table_info` so it is idempotent.
    private func migrateSchema() {
        guard let db = db else { return }
        var existing = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(requests);", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    existing.insert(String(cString: name))
                }
            }
        }
        sqlite3_finalize(stmt)
        if !existing.contains("app") {
            execChecked(db, "ALTER TABLE requests ADD COLUMN app TEXT;", "app column migration")
        }
        if !existing.contains("app_bundle") {
            execChecked(db, "ALTER TABLE requests ADD COLUMN app_bundle TEXT;", "app_bundle column migration")
        }
    }

    private func prepareStatements() {
        guard let db = db else {
            telemetryUnavailable = true
            return
        }
        let insertSQL = """
        INSERT INTO requests (ts, scheme, method, host, port, path, route, status,
                              bytes_in, bytes_out, duration_ms, error, src_port,
                              app, app_bundle)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let rc = sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil)
        guard rc == SQLITE_OK, insertStmt != nil else {
            telemetryUnavailable = true
            if insertStmt != nil {
                sqlite3_finalize(insertStmt)
                insertStmt = nil
            }
            noteDatabaseFailure("prepare INSERT failed (\(rc)): \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    private func startFlusher() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        flusher = t
    }

    // MARK: - Hot path (called from relay threads, thousands/sec)

    func record(_ event: RequestEvent) {
        appendCompletion(event)
    }

    /// Register a connection that is about to stream. Publishes a live feed
    /// row immediately (next flush tick); must be paired with `endSession`.
    func beginSession(_ event: RequestEvent) -> UUID {
        let session = LiveSession(event: event)
        lock.lock()
        sessions[event.id] = session
        sessionOrder.insert(event.id, at: 0)
        pendingLiveStarts.append(event)
        lock.unlock()
        return event.id
    }

    /// Per-relay-iteration byte deltas (O(1), no main-thread work).
    func updateSession(_ id: UUID, bytesIn: Int64, bytesOut: Int64) {
        lock.lock()
        guard let s = sessions[id] else { lock.unlock(); return }
        s.lock.lock()
        s.bytesIn += bytesIn
        s.bytesOut += bytesOut
        s.lock.unlock()
        lock.unlock()
    }

    /// Finalize a session: the live row closes and the event becomes a normal
    /// completed request (persisted + counted exactly like `record`).
    func endSession(_ id: UUID, _ event: RequestEvent) {
        lock.lock()
        // A session removed by `purge()` was explicitly discarded: don't append
        // its completion (or a finish the main block would have to undo).
        let existed = sessions.removeValue(forKey: id) != nil
        if let idx = sessionOrder.firstIndex(of: id) {
            sessionOrder.remove(at: idx)
        }
        if existed {
            pendingFinishes.append(id)
        }
        lock.unlock()
        if existed {
            appendCompletion(event)
        }
    }

    private func appendCompletion(_ event: RequestEvent) {
        lock.lock()
        pending.append(event)
        switch event.route {
        case .tunnel: pendingDelta.tunneledRequests += 1
        case .direct: pendingDelta.directRequests += 1
        case .block: pendingDelta.blockedRequests += 1
        }
        pendingDelta.bytesIn += event.bytesIn
        pendingDelta.bytesOut += event.bytesOut
        lock.unlock()
    }

    func setActiveConnections(_ count: Int) {
        lock.lock(); activeCount = count; lock.unlock()
    }

    #if SCREENSHOT_MODE
    /// Screenshot-only: seed in-progress rows so the live feed and "Active" stat
    /// render. Compiled out of the shipping app.
    func seedDemoLive(_ events: [RequestEvent]) {
        liveRequests = events
    }
    #endif

    // MARK: - Flush (10 Hz, single background thread)

    private func flush() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let canRetry = retriesDue(nowMs: nowMs)
        lock.lock()
        let gen = generation
        let batch = pending
        let delta = pendingDelta
        let active = activeCount
        pending.removeAll(keepingCapacity: true)
        pendingDelta = StatsSnapshot()
        dbAccumulator.append(contentsOf: batch)
        let flushDB = dbAccumulator.count >= Self.dbBatchSize || canRetry
        let dbBatch = flushDB ? dbAccumulator : []
        if flushDB { dbAccumulator.removeAll(keepingCapacity: true) }

        let starts = pendingLiveStarts
        pendingLiveStarts.removeAll(keepingCapacity: true)
        let finishes = pendingFinishes
        pendingFinishes.removeAll(keepingCapacity: true)

        // Snapshot live sessions whose row content changed (bytes moved or
        // ≥1 s elapsed so the duration ticks).
        var updates: [RequestEvent] = []
        for id in sessionOrder {
            guard let s = sessions[id] else { continue }
            s.lock.lock()
            let bi = s.bytesIn, bo = s.bytesOut
            s.lock.unlock()
            if bi != s.publishedIn || bo != s.publishedOut || nowMs - s.lastPublishMs >= 1000 {
                s.publishedIn = bi
                s.publishedOut = bo
                s.lastPublishMs = nowMs
                updates.append(s.event.snapshot(bytesIn: bi, bytesOut: bo,
                                                durationMs: nowMs - s.event.ts))
            }
        }
        lock.unlock()

        let hasUIWork = !batch.isEmpty || !starts.isEmpty || !updates.isEmpty || !finishes.isEmpty
        if hasUIWork {
            DispatchQueue.main.async { [weak self] in
                self?.applyToUI(starts: starts, updates: updates, finishes: finishes,
                                batch: batch, delta: delta, active: active, generation: gen)
            }
        }

        if flushDB {
            dbQueue.async { [weak self] in
                self?.insertBatch(dbBatch, generation: gen)
            }
        }

        maybePurge(nowMs: nowMs)
    }

    private func applyToUI(starts: [RequestEvent], updates: [RequestEvent],
                           finishes: [UUID], batch: [RequestEvent],
                           delta: StatsSnapshot, active: Int, generation: UInt64) {
        // A flush that snapshotted pre-purge state may have enqueued this block
        // before `purge()` enqueued its clear. Dropping it prevents the old
        // rows/stats from reappearing after "Clear".
        lock.lock()
        let current = self.generation
        lock.unlock()
        guard generation == current else { return }

        // A connection that began AND ended inside one flush tick must not
        // leave a ghost live row behind.
        let finished = Set(finishes)

        // Rebuild the live list locally and assign it at most once, only when
        // something actually changed. Each mutation of a `@Published` array
        // fires `objectWillChange`, so assigning per-operation re-rendered every
        // observer several times per tick.
        if !starts.isEmpty || !updates.isEmpty || !finishes.isEmpty {
            var newLive = liveRequests
            if !newLive.isEmpty && !finished.isEmpty {
                newLive.removeAll { finished.contains($0.id) }
            }
            if !starts.isEmpty {
                let known = Set(newLive.map(\.id))
                for event in starts where !finished.contains(event.id) && !known.contains(event.id) {
                    newLive.insert(event, at: 0)
                }
            }
            if !updates.isEmpty && !newLive.isEmpty {
                var index: [UUID: Int] = [:]
                index.reserveCapacity(newLive.count)
                for (i, e) in newLive.enumerated() { index[e.id] = i }
                for event in updates {
                    if let idx = index[event.id] { newLive[idx] = event }
                }
            }
            if newLive != liveRequests { liveRequests = newLive }
        }

        if !batch.isEmpty {
            recentRequests.append(contentsOf: batch)
            if recentRequests.count > Self.liveFeedCapacity {
                recentRequests.removeFirst(recentRequests.count - Self.liveFeedCapacity)
            }
        }

        // The six stat fields are written together so a tick that only moves
        // bytes (or a duration-only tick) doesn't fire six separate changes.
        if delta != StatsSnapshot() || active != stats.activeConnections {
            var newStats = stats
            newStats.tunneledRequests += delta.tunneledRequests
            newStats.directRequests += delta.directRequests
            newStats.blockedRequests += delta.blockedRequests
            newStats.bytesIn += delta.bytesIn
            newStats.bytesOut += delta.bytesOut
            newStats.activeConnections = active
            if newStats != stats { stats = newStats }
        }
    }

    // MARK: - SQLite (batched)

    private func insertBatch(_ events: [RequestEvent], generation: UInt64) {
        // Purge invalidates any batch captured before it. If this work is still
        // queued, drop it instead of re-inserting rows the DELETE removed. An
        // already-running batch is ordered before the purge DELETE on this same
        // serial `dbQueue`, so it cannot land after the delete.
        lock.lock()
        let current = self.generation
        lock.unlock()
        guard generation == current else { return }

        var batches = takeRetries()
        if !events.isEmpty { batches.append(events) }
        guard !batches.isEmpty else { return }
        guard let db = db, let stmt = insertStmt else {
            let queued = batches.reduce(0) { $0 + $1.count }
            noteDatabaseFailure("telemetry unavailable (db=\(db != nil), insertStmt=\(insertStmt != nil)); \(queued) event(s) queued for retry")
            requeue(batches, generation: generation)
            return
        }
        var index = 0
        while index < batches.count {
            if insertTransaction(batches[index], db: db, stmt: stmt) {
                index += 1
            } else {
                requeue(Array(batches[index...]), generation: generation)
                return
            }
        }
        lock.lock()
        retryDropReported = false
        lock.unlock()
    }

    private func insertTransaction(_ events: [RequestEvent], db: OpaquePointer,
                                   stmt: OpaquePointer) -> Bool {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            noteDatabaseFailure("BEGIN IMMEDIATE failed, \(events.count) event(s) not written: \(message)")
            return false
        }
        var failed = 0
        var firstError: String?
        for e in events {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_int64(stmt, 1, e.ts)
            bindText(stmt, 2, e.scheme)
            bindText(stmt, 3, e.method)
            bindText(stmt, 4, e.host)
            sqlite3_bind_int(stmt, 5, Int32(e.port))
            bindText(stmt, 6, e.path)
            bindText(stmt, 7, e.route.rawValue)
            sqlite3_bind_int(stmt, 8, Int32(e.status))
            sqlite3_bind_int64(stmt, 9, e.bytesIn)
            sqlite3_bind_int64(stmt, 10, e.bytesOut)
            sqlite3_bind_int64(stmt, 11, e.durationMs)
            if let err = e.error { bindText(stmt, 12, err) } else { sqlite3_bind_null(stmt, 12) }
            sqlite3_bind_int(stmt, 13, Int32(e.srcPort))
            if let app = e.app { bindText(stmt, 14, app) } else { sqlite3_bind_null(stmt, 14) }
            if let bundle = e.appBundle { bindText(stmt, 15, bundle) } else { sqlite3_bind_null(stmt, 15) }
            if sqlite3_step(stmt) != SQLITE_DONE {
                failed += 1
                if firstError == nil {
                    firstError = String(cString: sqlite3_errmsg(db))
                }
            }
        }
        if failed == 0 {
            if sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK { return true }
            let message = String(cString: sqlite3_errmsg(db))
            let rb = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            noteDatabaseFailure("COMMIT failed, \(events.count) event(s) rolled back: \(message)\(rollbackSuffix(rb, db: db))")
            return false
        }
        let rb = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        noteDatabaseFailure("\(failed)/\(events.count) INSERT(s) failed; batch rolled back (first error: \(firstError ?? "unknown"))\(rollbackSuffix(rb, db: db))")
        return false
    }

    private func rollbackSuffix(_ rc: Int32, db: OpaquePointer) -> String {
        guard rc != SQLITE_OK else { return "" }
        return " (ROLLBACK also failed: \(String(cString: sqlite3_errmsg(db))))"
    }

    /// Logs at most once per minute while failures persist, so a locked or
    /// corrupt DB cannot flood the unified log. The first failure of a burst is
    /// always logged; the suppressed count is reported on the next log.
    private func noteDatabaseFailure(_ message: String) {
        let now = Self.nowMs()
        lock.lock()
        guard now - lastDbErrorLogMs >= 60_000 else {
            suppressedDbErrors += 1
            lock.unlock()
            return
        }
        let suppressed = suppressedDbErrors
        suppressedDbErrors = 0
        lastDbErrorLogMs = now
        lock.unlock()
        if suppressed > 0 {
            telemetryLog.error("telemetry DB error: \(message, privacy: .public) [\(suppressed, privacy: .public) similar failure(s) suppressed]")
        } else {
            telemetryLog.error("telemetry DB error: \(message, privacy: .public)")
        }
    }

    @discardableResult
    private func execChecked(_ db: OpaquePointer, _ sql: String, _ label: String) -> Bool {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let detail = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorMessage)
            noteDatabaseFailure("\(label) failed: \(detail)")
            return false
        }
        return true
    }

    private func takeRetries() -> [[RequestEvent]] {
        lock.lock()
        defer { lock.unlock() }
        guard !retryBatches.isEmpty else { return [] }
        let batches = retryBatches
        retryBatches.removeAll(keepingCapacity: true)
        retryEventCount = 0
        retryAfterMs = 0
        return batches
    }

    private func requeue(_ batches: [[RequestEvent]], generation: UInt64) {
        let incoming = batches.filter { !$0.isEmpty }
        guard !incoming.isEmpty else { return }
        var dropped = 0
        lock.lock()
        // A failed pre-purge batch must not sit in the retry queue and get
        // written by the next flush after `purge()` cleared everything.
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        retryBatches.append(contentsOf: incoming)
        for batch in incoming { retryEventCount += batch.count }
        while retryBatches.count > Self.maxRetryBatches || retryEventCount > Self.maxRetryEvents {
            var oldest = retryBatches.removeFirst()
            let excess = retryEventCount - Self.maxRetryEvents
            if excess > 0 && oldest.count > excess {
                oldest.removeFirst(excess)
                dropped += excess
                retryEventCount -= excess
                retryBatches.insert(oldest, at: 0)
            } else {
                dropped += oldest.count
                retryEventCount -= oldest.count
            }
        }
        retryAfterMs = Self.nowMs() + Self.retryBackoffMs
        let reportDrop = dropped > 0 && !retryDropReported
        if reportDrop { retryDropReported = true }
        lock.unlock()
        if reportDrop {
            telemetryLog.error("telemetry retry queue saturated; dropped \(dropped, privacy: .public) oldest event(s)")
        }
    }

    private func retriesDue(nowMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !retryBatches.isEmpty && nowMs >= retryAfterMs
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ text: String) {
        sqlite3_bind_text(stmt, idx, (text as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    /// Safe even for an in-memory hostile `days`: on overflow the cutoff is
    /// `Int64.min`, which purges rows older than any representable timestamp.
    static func retentionCutoffMs(nowMs: Int64, days: Int) -> Int64 {
        let safeDays = max(1, days)
        let (span, overflow) = Int64(clamping: safeDays).multipliedReportingOverflow(by: 86_400_000)
        guard !overflow else { return Int64.min }
        let (cutoff, underflow) = nowMs.subtractingReportingOverflow(span)
        return underflow ? Int64.min : cutoff
    }

    // Same ranges as `MonitorSettings` decoding (TM-10), applied again at the
    // setter so a runtime update cannot introduce an out-of-range limit.
    private static func clampMaxRows(_ value: Int) -> Int {
        min(max(value, 0), 10_000_000)
    }

    private static func clampRetentionDays(_ value: Int) -> Int {
        min(max(value, 1), 3_650)
    }

    /// Applies new retention limits to the running store (no relaunch needed).
    /// The values are clamped, and a real change forces the next flusher tick
    /// (≤0.1 s) to run a retention pass. A no-op commit does not, so dragging an
    /// unrelated setting cannot queue a trim pass per commit. No SQLite work
    /// happens on the caller's thread.
    func setLimits(maxRows: Int, retentionDays: Int) {
        let cap = Self.clampMaxRows(maxRows)
        let days = Self.clampRetentionDays(retentionDays)
        lock.lock()
        let changed = self.maxRows != cap || self.retentionDays != days
        self.maxRows = cap
        self.retentionDays = days
        if changed {
            // `maybePurge` treats a very old timestamp as due immediately.
            lastPurgeMs = 0
        }
        lock.unlock()
    }

    /// Atomic snapshot of the active limits (thread-safe diagnostic/test seam).
    func currentLimits() -> (maxRows: Int, retentionDays: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (maxRows, retentionDays)
    }

    private func maybePurge(nowMs: Int64) {
        // Retention purge once every 5 minutes. `nowMs` is reused from `flush`
        // so the 10 Hz tick does not pay for an extra `Date()` every time.
        lock.lock()
        let due = nowMs - lastPurgeMs > 300_000
        if due { lastPurgeMs = nowMs }
        lock.unlock()
        guard due else { return }
        dbQueue.async { [weak self] in self?.purgeExpiredOnQueue() }
    }

    /// Test seam: run the periodic retention/max-rows pass immediately instead
    /// of waiting for the 5-minute cadence. Resets the cadence so the next
    /// natural pass is not skipped; production timing is otherwise unchanged.
    func runRetentionNow() {
        lock.lock()
        lastPurgeMs = Self.nowMs()
        lock.unlock()
        dbQueue.sync { purgeExpiredOnQueue() }
    }

    /// Runs on `dbQueue` with a live connection. Checkpoints only when the pass
    /// actually deleted something, so an idle pass does not touch the WAL.
    private func purgeExpiredOnQueue() {
        lastRetentionDeleteChunks = 0
        guard let db = db else { return }
        if runRetentionPass(db: db) {
            checkpointTruncate(db, "retention purge")
        }
    }

    /// One retention pass: age first, then the row cap. Must run on `dbQueue`.
    /// Returns true when at least one row was deleted.
    private func runRetentionPass(db: OpaquePointer) -> Bool {
        // One locked snapshot: a `setLimits` racing this pass either applies
        // entirely before (this pass uses the new pair) or entirely after.
        let limits = currentLimits()
        let cutoff = Self.retentionCutoffMs(nowMs: Self.nowMs(), days: limits.retentionDays)
        var deleted = deleteOlderThan(cutoff, db: db, label: "retention purge")
        let cap = limits.maxRows
        if cap > 0 {
            deleted = trimToMaxRows(cap, db: db) || deleted
        }
        return deleted
    }

    /// Chunked `DELETE ... WHERE ts < cutoff`. Stops at the first failed
    /// statement (locked/disk-full) so a bad DB cannot spin the DB queue.
    /// Returns true when at least one row was deleted.
    private func deleteOlderThan(_ cutoffMs: Int64, db: OpaquePointer, label: String) -> Bool {
        var deletedAny = false
        for _ in 0..<Self.trimMaxIterations {
            let sql = """
            DELETE FROM requests WHERE id IN (
                SELECT id FROM requests WHERE ts < \(cutoffMs) LIMIT \(Self.trimChunkSize)
            );
            """
            guard execChecked(db, sql, label) else { return deletedAny }
            guard sqlite3_changes(db) > 0 else { return deletedAny }
            deletedAny = true
            lastRetentionDeleteChunks += 1
        }
        telemetryLog.error("\(label, privacy: .public) hit the \(Self.trimMaxIterations, privacy: .public)-chunk cap; excess rows remain for the next pass")
        return deletedAny
    }

    /// Chunked trim down to `maxRows`, keeping the newest `(ts, id)` rows. The
    /// boundary is resolved once; every batch deletes only rows strictly older
    /// than it, so the trim is resumable across passes.
    private func trimToMaxRows(_ maxRows: Int, db: OpaquePointer) -> Bool {
        var boundary: (ts: Int64, id: Int64)?
        var stmt: OpaquePointer?
        let boundarySQL = "SELECT ts, id FROM requests ORDER BY ts DESC, id DESC LIMIT 1 OFFSET \(maxRows);"
        if sqlite3_prepare_v2(db, boundarySQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW {
                boundary = (sqlite3_column_int64(s, 0), sqlite3_column_int64(s, 1))
            } else if rc != SQLITE_DONE {
                noteDatabaseFailure("max-rows boundary query failed (\(rc)): \(String(cString: sqlite3_errmsg(db)))")
            }
        } else {
            noteDatabaseFailure("max-rows boundary query failed to prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
        guard let b = boundary else { return false }

        var deletedAny = false
        for _ in 0..<Self.trimMaxIterations {
            // The boundary row itself is outside the newest `maxRows`, so it is
            // deleted too (`<=`); only strictly newer rows survive.
            let sql = """
            DELETE FROM requests WHERE id IN (
                SELECT id FROM requests
                WHERE ts < \(b.ts) OR (ts = \(b.ts) AND id <= \(b.id))
                LIMIT \(Self.trimChunkSize)
            );
            """
            guard execChecked(db, sql, "max-rows purge") else { return deletedAny }
            guard sqlite3_changes(db) > 0 else { return deletedAny }
            deletedAny = true
            lastRetentionDeleteChunks += 1
        }
        telemetryLog.error("max-rows purge hit the \(Self.trimMaxIterations, privacy: .public)-chunk cap; excess rows remain for the next pass")
        return deletedAny
    }

    /// `TRUNCATE` returns the WAL to the filesystem instead of leaving stale
    /// frames behind. A busy checkpoint is logged (throttled) and ignored: the
    /// data is already durable and the next checkpoint retries.
    private func checkpointTruncate(_ db: OpaquePointer, _ label: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA wal_checkpoint(TRUNCATE);", -1, &stmt, nil) == SQLITE_OK,
              let s = stmt else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(stmt)
            noteDatabaseFailure("\(label) WAL checkpoint failed to prepare: \(message)")
            return
        }
        let rc = sqlite3_step(s)
        let busy = rc == SQLITE_ROW ? sqlite3_column_int(s, 0) : 0
        sqlite3_finalize(stmt)
        if rc != SQLITE_ROW && rc != SQLITE_DONE {
            noteDatabaseFailure("\(label) WAL checkpoint failed (\(rc)): \(String(cString: sqlite3_errmsg(db)))")
        } else if busy > 0 {
            noteDatabaseFailure("\(label) WAL checkpoint blocked by a reader/writer; WAL left in place")
        }
    }

    // MARK: - Control

    /// Persist any buffered events synchronously. Called on quit so the last
    /// sub-second of telemetry is not lost.
    func flushNow() {
        lock.lock()
        let gen = generation
        let accumulated = dbAccumulator
        let buffered = pending
        dbAccumulator.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        let all = accumulated + buffered
        dbQueue.sync {
            insertBatch(all, generation: gen)
            if let db = db {
                checkpointTruncate(db, "quit")
            }
        }
    }

    func purge() {
        lock.lock()
        generation &+= 1
        let gen = generation
        // `activeCount` tracks accepted connections; live telemetry sessions
        // begin slightly later. Preserve the higher of the two so "Active"
        // survives Clear while those connections are still streaming.
        let liveCount = max(activeCount, sessions.count)
        pending.removeAll()
        dbAccumulator.removeAll()
        pendingDelta = StatsSnapshot()
        pendingLiveStarts.removeAll()
        pendingFinishes.removeAll()
        sessions.removeAll()
        sessionOrder.removeAll()
        retryBatches.removeAll()
        retryEventCount = 0
        retryAfterMs = 0
        retryDropReported = false
        // Enqueue the UI clear and the DELETE while still holding the lock, so
        // no post-purge flush can enqueue work ahead of them (which would then
        // be wiped from the UI or re-inserted after the delete). `async` does
        // not block, so holding the lock here cannot deadlock.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let stillCurrent = self.generation == gen
            self.lock.unlock()
            guard stillCurrent else { return }
            self.recentRequests = []
            self.liveRequests = []
            var cleared = StatsSnapshot()
            cleared.activeConnections = liveCount
            self.stats = cleared
        }
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            self.lock.lock()
            let stillCurrent = self.generation == gen
            self.lock.unlock()
            guard stillCurrent else { return }
            guard self.execChecked(db, "DELETE FROM requests;", "history purge") else { return }
            self.checkpointTruncate(db, "history purge")
            // `DELETE` only frees pages for reuse; `VACUUM` is what returns the
            // space to the filesystem. User-initiated only because it rewrites
            // the whole DB and needs ~2× its size in free space.
            if self.execChecked(db, "VACUUM;", "history vacuum") {
                self.checkpointTruncate(db, "history vacuum")
            }
        }
        lock.unlock()
    }

    // MARK: - Queries (charts)

    /// Aggregates raw events into `bucketMs`-wide buckets (in-memory, pure).
    /// Used for the live "5m" chart and as the unit-testable reference for the
    /// SQL-backed path. `nowMs` only matters if the caller wants empty buckets
    /// filled to the current time — here we just return non-empty buckets.
    static func bucketize(_ events: [RequestEvent], bucketMs: Int64) -> [ChartBucket] {
        var agg: [Int64: [Route: (Int, Int64, Int64, Int)]] = [:]
        for e in events {
            let b = (e.ts / bucketMs) * bucketMs
            var cur = agg[b]?[e.route] ?? (0, 0, 0, 0)
            cur.0 += 1
            cur.1 += e.bytesIn
            cur.2 += e.bytesOut
            if e.status >= 400 || e.error != nil { cur.3 += 1 }
            agg[b, default: [:]][e.route] = cur
        }
        var result: [ChartBucket] = []
        for b in agg.keys.sorted() {
            let routes = agg[b] ?? [:]
            for route in routes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let v = routes[route]!
                result.append(ChartBucket(bucketMs: b, route: route, count: v.0,
                                          bytesIn: v.1, bytesOut: v.2, errors: v.3))
            }
        }
        return result
    }

    /// Time-series aggregation straight from SQLite, bucketed per route.
    /// Runs on the DB queue and delivers on the main thread; safe for the
    /// 1h/24h/7d chart ranges where the in-memory feed has long rolled over.
    func chartSeries(rangeSeconds: Int, bucketMs: Int64,
                     completion: @escaping ([ChartBucket]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(rangeSeconds) * 1000
            let sql = """
            SELECT (ts / ?) * ? AS bucket, route, COUNT(*),
                   COALESCE(SUM(bytes_in), 0), COALESCE(SUM(bytes_out), 0),
                   COALESCE(SUM(CASE WHEN status >= 400 OR error IS NOT NULL THEN 1 ELSE 0 END), 0)
            FROM requests
            WHERE ts >= ?
            GROUP BY bucket, route
            ORDER BY bucket;
            """
            var result: [ChartBucket] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
                sqlite3_bind_int64(s, 1, bucketMs)
                sqlite3_bind_int64(s, 2, bucketMs)
                sqlite3_bind_int64(s, 3, cutoff)
                while sqlite3_step(s) == SQLITE_ROW {
                    let routeStr = String(cString: sqlite3_column_text(s, 1))
                    result.append(ChartBucket(
                        bucketMs: sqlite3_column_int64(s, 0),
                        route: Route(rawValue: routeStr) ?? .direct,
                        count: Int(sqlite3_column_int64(s, 2)),
                        bytesIn: sqlite3_column_int64(s, 3),
                        bytesOut: sqlite3_column_int64(s, 4),
                        errors: Int(sqlite3_column_int64(s, 5))
                    ))
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func topHosts(rangeSeconds: Int, limit: Int = 10, completion: @escaping ([(host: String, count: Int)]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let cutoff = Int64(Date().timeIntervalSince1970) - Int64(rangeSeconds)
            let sql = """
            SELECT host, COUNT(*) AS c FROM requests
            WHERE ts >= \(cutoff * 1000) AND route = 'TUNNEL'
            GROUP BY host ORDER BY c DESC LIMIT \(limit);
            """
            var result: [(String, Int)] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
                while sqlite3_step(s) == SQLITE_ROW {
                    let host = String(cString: sqlite3_column_text(s, 0))
                    result.append((host, Int(sqlite3_column_int(s, 1))))
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Top apps by request count over a range, for the dashboard breakdown.
    /// Groups by app identity (bundle id when present) and returns a bundle id
    /// so the UI can show the app icon.
    func topApps(rangeSeconds: Int, limit: Int = 10,
                 completion: @escaping ([(app: String, bundle: String?, count: Int)]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let cutoff = Int64(Date().timeIntervalSince1970) - Int64(rangeSeconds)
            let sql = """
            SELECT MAX(app) AS name, MAX(app_bundle) AS bundle, COUNT(*) AS c
            FROM requests
            WHERE ts >= \(cutoff * 1000) AND app IS NOT NULL AND app != ''
            GROUP BY COALESCE(app_bundle, app) ORDER BY c DESC LIMIT \(limit);
            """
            var result: [(String, String?, Int)] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
                while sqlite3_step(s) == SQLITE_ROW {
                    let name = String(cString: sqlite3_column_text(s, 0))
                    let bundle = sqlite3_column_text(s, 1).map { String(cString: $0) }
                    result.append((name, bundle, Int(sqlite3_column_int(s, 2))))
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(result) }
        }
    }
}
