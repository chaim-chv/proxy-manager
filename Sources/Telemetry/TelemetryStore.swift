import Foundation
import SQLite3

/// Tells SQLite to copy the bound string immediately. `nil`/`SQLITE_STATIC`
/// would store a raw pointer into a temporary `NSString` that is released before
/// `sqlite3_step` runs — a use-after-free.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    init(id: UUID = UUID(), ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
         scheme: String = "https", method: String = "CONNECT", host: String = "",
         port: UInt16 = 443, path: String = "", route: Route = .direct,
         status: Int = 0, bytesIn: Int64 = 0, bytesOut: Int64 = 0,
         durationMs: Int64 = 0, error: String? = nil, srcPort: Int = 0) {
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
    }

    /// Copy with a new byte/duration snapshot (used for live rows while the
    /// connection is still open). Metadata (id/ts/host/route/...) is immutable.
    func snapshot(bytesIn: Int64, bytesOut: Int64, durationMs: Int64) -> RequestEvent {
        RequestEvent(id: id, ts: ts, scheme: scheme, method: method, host: host,
                     port: port, path: path, route: route, status: status,
                     bytesIn: bytesIn, bytesOut: bytesOut, durationMs: durationMs,
                     error: error, srcPort: srcPort)
    }
}

struct StatsSnapshot {
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
    private let maxRows: Int
    private let retentionDays: Int
    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private var statsStmt: OpaquePointer?

    private let dbQueue = DispatchQueue(label: "com.proxymanager.telemetry.db")
    private let lock = NSLock()

    private var pending: [RequestEvent] = []
    private var pendingDelta = StatsSnapshot()
    private var dbAccumulator: [RequestEvent] = []
    private var activeCount = 0
    private var lastPurge = Date()

    private var flusher: DispatchSourceTimer?

    /// Live-session bookkeeping (guarded by `lock`).
    private var sessions: [UUID: LiveSession] = [:]
    private var sessionOrder: [UUID] = []
    private var pendingLiveStarts: [RequestEvent] = []
    private var pendingFinishes: [UUID] = []

    init(dbURL: URL, maxRows: Int = 500_000, retentionDays: Int = 7) {
        self.dbURL = dbURL
        self.maxRows = maxRows
        self.retentionDays = retentionDays
        openDatabase()
        createSchema()
        prepareStatements()
        startFlusher()
    }

    deinit {
        flusher?.cancel()
        sqlite3_finalize(insertStmt)
        sqlite3_finalize(statsStmt)
        if let db = db { sqlite3_close(db) }
    }

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            NSLog("ProxyManager: failed to open telemetry DB: \(String(cString: sqlite3_errmsg(db)))")
            db = nil
        }
        if let db = db {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA cache_size=-8000;", nil, nil, nil)
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
            src_port INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_requests_ts ON requests(ts);
        CREATE INDEX IF NOT EXISTS idx_requests_host ON requests(host);
        CREATE INDEX IF NOT EXISTS idx_requests_route ON requests(route);
        CREATE TABLE IF NOT EXISTS minute_stats (
            bucket INTEGER NOT NULL,
            route TEXT NOT NULL,
            requests INTEGER NOT NULL,
            bytes_in INTEGER NOT NULL,
            bytes_out INTEGER NOT NULL,
            PRIMARY KEY (bucket, route)
        );
        """
        sqlite3_exec(db, schema, nil, nil, nil)
    }

    private func prepareStatements() {
        guard let db = db else { return }
        let insertSQL = """
        INSERT INTO requests (ts, scheme, method, host, port, path, route, status,
                              bytes_in, bytes_out, duration_ms, error, src_port)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil)

        let statsSQL = """
        INSERT INTO minute_stats (bucket, route, requests, bytes_in, bytes_out)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(bucket, route) DO UPDATE SET
            requests = requests + excluded.requests,
            bytes_in = bytes_in + excluded.bytes_in,
            bytes_out = bytes_out + excluded.bytes_out;
        """
        sqlite3_prepare_v2(db, statsSQL, -1, &statsStmt, nil)
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
        if let idx = sessionOrder.firstIndex(of: id) {
            sessionOrder.remove(at: idx)
        }
        sessions.removeValue(forKey: id)
        pendingFinishes.append(id)
        lock.unlock()
        appendCompletion(event)
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

    // MARK: - Flush (10 Hz, single background thread)

    private func flush() {
        lock.lock()
        let batch = pending
        let delta = pendingDelta
        let active = activeCount
        pending.removeAll(keepingCapacity: true)
        pendingDelta = StatsSnapshot()
        dbAccumulator.append(contentsOf: batch)
        let flushDB = dbAccumulator.count >= Self.dbBatchSize
        let dbBatch = flushDB ? dbAccumulator : []
        if flushDB { dbAccumulator.removeAll(keepingCapacity: true) }

        let starts = pendingLiveStarts
        pendingLiveStarts.removeAll(keepingCapacity: true)
        let finishes = pendingFinishes
        pendingFinishes.removeAll(keepingCapacity: true)

        // Snapshot live sessions whose row content changed (bytes moved or
        // ≥1 s elapsed so the duration ticks).
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
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
                                batch: batch, delta: delta, active: active)
            }
        }

        if flushDB {
            dbQueue.async { [weak self] in
                self?.insertBatch(dbBatch)
            }
        }

        maybePurge()
    }

    private func applyToUI(starts: [RequestEvent], updates: [RequestEvent],
                           finishes: [UUID], batch: [RequestEvent],
                           delta: StatsSnapshot, active: Int) {
        // A connection that began AND ended inside one flush tick must not
        // leave a ghost live row behind.
        let finished = Set(finishes)

        if !liveRequests.isEmpty {
            // Finalized rows move out of the live list into the completed feed.
            for id in finishes where !liveRequests.isEmpty {
                liveRequests.removeAll { $0.id == id }
            }
        }
        for event in starts where !finished.contains(event.id) {
            liveRequests.insert(event, at: 0)
        }
        for event in updates {
            if let idx = liveRequests.firstIndex(where: { $0.id == event.id }) {
                liveRequests[idx] = event
            }
        }

        if !batch.isEmpty {
            recentRequests.append(contentsOf: batch)
            if recentRequests.count > Self.liveFeedCapacity {
                recentRequests.removeFirst(recentRequests.count - Self.liveFeedCapacity)
            }
        }
        stats.tunneledRequests += delta.tunneledRequests
        stats.directRequests += delta.directRequests
        stats.blockedRequests += delta.blockedRequests
        stats.bytesIn += delta.bytesIn
        stats.bytesOut += delta.bytesOut
        stats.activeConnections = active
    }

    // MARK: - SQLite (batched)

    private func insertBatch(_ events: [RequestEvent]) {
        guard let db = db, let stmt = insertStmt, !events.isEmpty else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
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
            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("ProxyManager: telemetry insert failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
            NSLog("ProxyManager: telemetry commit failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        upsertMinuteStats(events)
    }

    private func upsertMinuteStats(_ events: [RequestEvent]) {
        guard let stmt = statsStmt else { return }
        // Aggregate per (bucket, route) in memory, then upsert once per key.
        var agg: [Int64: [String: (Int64, Int64, Int64)]] = [:] // bucket -> route -> (count, in, out)
        for e in events {
            let bucket = (e.ts / 60_000) * 60_000
            let route = e.route.rawValue
            let cur = agg[bucket]?[route] ?? (0, 0, 0)
            agg[bucket, default: [:]][route] = (cur.0 + 1, cur.1 + e.bytesIn, cur.2 + e.bytesOut)
        }
        for (bucket, routes) in agg {
            for (route, v) in routes {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, bucket)
                sqlite3_bind_text(stmt, 2, (route as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, v.0)
                sqlite3_bind_int64(stmt, 4, v.1)
                sqlite3_bind_int64(stmt, 5, v.2)
                sqlite3_step(stmt)
            }
        }
    }

    private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ text: String) {
        sqlite3_bind_text(stmt, idx, (text as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    private func maybePurge() {
        // Retention purge once every 5 minutes.
        guard Date().timeIntervalSince(lastPurge) > 300 else { return }
        lastPurge = Date()
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let days = max(1, self.retentionDays)
            let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(days) * 86_400_000
            var sql = "DELETE FROM requests WHERE ts < \(cutoff);"
            sqlite3_exec(db, sql, nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM minute_stats WHERE bucket < \(cutoff);", nil, nil, nil)
            if self.maxRows > 0 {
                sql = "DELETE FROM requests WHERE id IN (SELECT id FROM requests ORDER BY ts DESC, id DESC LIMIT -1 OFFSET \(self.maxRows));"
                sqlite3_exec(db, sql, nil, nil, nil)
            }
        }
    }

    // MARK: - Control

    /// Persist any buffered events synchronously. Called on quit so the last
    /// sub-second of telemetry is not lost.
    func flushNow() {
        lock.lock()
        let accumulated = dbAccumulator
        let buffered = pending
        dbAccumulator.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        let all = accumulated + buffered
        guard !all.isEmpty else { return }
        dbQueue.sync { insertBatch(all) }
    }

    func purge() {
        lock.lock()
        pending.removeAll()
        dbAccumulator.removeAll()
        pendingDelta = StatsSnapshot()
        pendingLiveStarts.removeAll()
        pendingFinishes.removeAll()
        sessions.removeAll()
        sessionOrder.removeAll()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.recentRequests = []
            self?.liveRequests = []
            self?.stats = StatsSnapshot()
        }
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            sqlite3_exec(db, "DELETE FROM requests;", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM minute_stats;", nil, nil, nil)
        }
    }

    // MARK: - Queries (charts)

    func requestSeries(rangeSeconds: Int, completion: @escaping ([String: Int]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            let cutoff = Int64(Date().timeIntervalSince1970) - Int64(rangeSeconds)
            let sql = "SELECT route, COUNT(*) FROM requests WHERE ts >= \(cutoff * 1000) GROUP BY route;"
            var result: [String: Int] = [:]
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
                while sqlite3_step(s) == SQLITE_ROW {
                    let route = String(cString: sqlite3_column_text(s, 0))
                    result[route] = Int(sqlite3_column_int(s, 1))
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { completion(result) }
        }
    }

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
}
