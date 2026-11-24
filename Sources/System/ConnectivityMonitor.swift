import Combine
import Darwin
import Foundation
import Network

/// Active internet reachability monitoring.
///
/// `NWPathMonitor` only knows whether the local link has a route, so it stays
/// "satisfied" when Wi-Fi is fine but the router's uplink is dead — exactly the
/// outage users cannot see. This monitor therefore fetches a tiny, cache-busted
/// HTTPS resource on a short cadence and falls back to a second independent,
/// purpose-built endpoint before declaring the internet down.
///
/// Energy and stability rules:
/// - one request per cycle; no fallback traffic unless the primary fails;
/// - 5 s while the menu/General is visible, 20 s in the background, 5 s while
///   offline (quick recovery detection); a fresh check on every menu open;
/// - three-second-class timeouts and a hard 12 s cycle watchdog, so a hung
///   request can never stall monitoring;
/// - URLSession with an empty proxy dictionary, so the probe never depends on
///   (or routes through) the local proxy this app installs;
/// - all observable state changes on the main thread; network I/O does not.
final class ConnectivityMonitor: ObservableObject {
    static let shared = ConnectivityMonitor()

    @Published private(set) var snapshot = ConnectivitySnapshot()

    /// Set by `AppModel` once telemetry exists. Weak: history must never keep
    /// the store alive, and probe writing is best-effort.
    weak var history: ConnectivityHistorySink?

    private struct Probe {
        let url: URL
        let expectedStatus: Int
        /// Some endpoints return 200 with a captive-portal page; require the
        /// expected marker so a login page is not reported as internet access.
        let bodyNeedle: String?
    }

    private static let primary = Probe(
        url: URL(string: "https://captive.apple.com/hotspot-detect.html")!,
        expectedStatus: 200,
        bodyNeedle: "Success"
    )
    private static let fallbacks = [
        Probe(url: URL(string: "https://detectportal.firefox.com/success.txt")!,
              expectedStatus: 200, bodyNeedle: "success")
    ]

    // Fast while something is watching (menu open / General visible), slow in
    // the background, and quick again while offline so recovery is noticed.
    private static let activeInterval: TimeInterval = 5
    private static let idleInterval: TimeInterval = 20
    private static let offlineInterval: TimeInterval = 5
    private static let requestTimeout: TimeInterval = 3
    private static let cycleWatchdog: TimeInterval = 12

    /// One probe cycle. The identity check (`self.cycle === cycle`) makes a
    /// late completion from a cancelled/timed-out cycle harmless.
    private final class Cycle {
        let startedAt = Date()
        var remaining = 0
        var succeeded = false
        var bestLatencyMS: Int?
        var tasks: [URLSessionDataTask] = []
        /// Set when every fallback probe has answered (success or failure).
        var fallbacksDone = false
        /// Result of the IP-literal probe. `nil` until it answers; a failure is
        /// classified only when both halves of the cycle are in, so a cycle can
        /// never report "network is down" before TCP was actually tried.
        var classification: ConnectivityFailure?
    }

    private var pathMonitor: NWPathMonitor?
    private var timer: Timer?
    private var watchdog: Timer?
    private var cycle: Cycle?
    private var started = false
    private var lastLoggedStatus: ConnectivityStatus?
    /// UI surfaces currently showing live status. While non-empty, probes run
    /// at `activeInterval`; otherwise they back off to `idleInterval`.
    private var visibleSurfaces: Set<String> = []
    private var isActive: Bool { !visibleSurfaces.isEmpty }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        // An empty dictionary explicitly disables the system proxy. The app
        // points macOS at 127.0.0.1 while routing is on; probing through that
        // would make the monitor depend on its own proxy and could loop back.
        cfg.connectionProxyDictionary = [:]
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = Self.requestTimeout
        cfg.timeoutIntervalForResource = Self.cycleWatchdog
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 1
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private init() {}

    func start() {
        guard !DemoMode.isEnabled, !started else { return }
        started = true
        // Re-enabling after the setting was off must not expose the previous
        // run's history as if it were current.
        snapshot = ConnectivitySnapshot()
        lastLoggedStatus = nil
        // `NWPathMonitor` cannot be restarted after `cancel()`, so create a
        // fresh one each time the setting is turned back on.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            // A new route may be the end of an outage (or its start): check
            // now instead of waiting for the next timer tick.
            DispatchQueue.main.async { self?.probeNow() }
        }
        monitor.start(queue: DispatchQueue(label: "com.proxymanager.connectivity.path"))
        pathMonitor = monitor
        probeNow()
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.invalidate()
        timer = nil
        watchdog?.invalidate()
        watchdog = nil
        cycle?.tasks.forEach { $0.cancel() }
        cycle = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastLoggedStatus = nil
    }

    /// Applies the Settings toggle. Off means no probe traffic at all.
    func setEnabled(_ enabled: Bool) {
        guard !DemoMode.isEnabled else { return }
        if enabled { start() } else { stop() }
    }

    /// Called when a UI surface that shows live status appears or disappears
    /// (status menu open/close, General pane visible). Idempotent per surface.
    func setVisible(_ visible: Bool, surface: String) {
        let wasActive = isActive
        if visible {
            visibleSurfaces.insert(surface)
        } else {
            visibleSurfaces.remove(surface)
        }
        guard isActive != wasActive, started else { return }
        timer?.invalidate()
        timer = nil
        if isActive {
            if cycle == nil { probeNow() }
        } else if cycle == nil {
            scheduleNext(after: currentInterval)
        }
    }

    /// User-initiated refresh (menu open / Settings appear / Check Now).
    func checkNow() {
        probeNow()
    }

    private var currentInterval: TimeInterval {
        if snapshot.status == .offline { return Self.offlineInterval }
        return isActive ? Self.activeInterval : Self.idleInterval
    }

    /// Screenshot builds: show a plausible healthy history without any network.
    func seedDemo() {
        guard DemoMode.isEnabled else { return }
        var seeded = ConnectivitySnapshot()
        let now = Date()
        // One recent drop then recovery: the demo shows "Online — unstable"
        // and a red blip in the history strip without claiming a current outage.
        let dropIndex = ConnectivitySnapshot.maxChecks - 36
        for index in 0..<ConnectivitySnapshot.maxChecks {
            let at = now.addingTimeInterval(Double(index - ConnectivitySnapshot.maxChecks + 1) * Self.activeInterval)
            let ok = index != dropIndex
            seeded.record(ok: ok,
                          latencyMS: ok ? 28 + index % 9 : nil,
                          at: at,
                          failure: ok ? .none : .dns)
        }
        snapshot = seeded
    }

    // MARK: - Probing

    private func probeNow() {
        guard started, cycle == nil else { return }
        let cycle = Cycle()
        self.cycle = cycle

        let watchdog = Timer(timeInterval: Self.cycleWatchdog, repeats: false) { [weak self] _ in
            // A cycle cut short has no trustworthy cause: never claim "network
            // down" from a watchdog.
            self?.complete(ok: false, latencyMS: nil, failure: .none, cycle: cycle)
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog

        request(Self.primary, cycle: cycle) { [weak self] ok, latency, gotResponse in
            guard let self else { return }
            if ok {
                self.complete(ok: true, latencyMS: latency, failure: .none, cycle: cycle)
            } else if gotResponse {
                // The name resolved and something answered, but it was not our
                // marker: a captive portal / intercepting proxy, not DNS. Do
                // not claim "DNS failing" without evidence.
                cycle.classification = ConnectivityFailure.none
                self.probeFallbacks(for: cycle)
            } else {
                // DNS and IP reachability fail for different reasons and need
                // different advice. Probe both halves concurrently: an HTTPS
                // name probe can only fail at the resolver, while a raw TCP
                // connect to a literal address never touches DNS.
                self.classifyFailure(for: cycle)
                self.probeFallbacks(for: cycle)
            }
        }
    }

    private func probeFallbacks(for cycle: Cycle) {
        cycle.remaining = Self.fallbacks.count
        guard !Self.fallbacks.isEmpty else {
            cycle.fallbacksDone = true
            completeIfReady(cycle)
            return
        }
        for probe in Self.fallbacks {
            request(probe, cycle: cycle) { [weak self] ok, latency, _ in
                guard let self, self.cycle === cycle else { return }
                if ok {
                    cycle.succeeded = true
                    if let latency {
                        cycle.bestLatencyMS = min(cycle.bestLatencyMS ?? latency, latency)
                    }
                }
                cycle.remaining -= 1
                if cycle.remaining == 0 {
                    cycle.fallbacksDone = true
                    self.completeIfReady(cycle)
                }
            }
        }
    }

    /// Distinguishes "DNS is broken" from "the network is down" with a raw TCP
    /// connect to literal addresses (no resolver, no system proxy). Two
    /// independent endpoints avoid blaming the user's DNS for one blocked IP.
    private func classifyFailure(for cycle: Cycle) {
        let endpoints: [(String, UInt16)] = [("1.1.1.1", 443), ("9.9.9.9", 443)]
        let lock = NSLock()
        var remaining = endpoints.count
        var reachable = false
        for (host, port) in endpoints {
            classifyProbe(host: host, port: port) { [weak self] ok in
                lock.lock()
                if ok { reachable = true }
                remaining -= 1
                let finished = remaining == 0
                let result: ConnectivityFailure = reachable ? .dns : .network
                lock.unlock()
                guard finished, let self else { return }
                cycle.classification = result
                self.completeIfReady(cycle)
            }
        }
    }

    private func classifyProbe(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
        // Raw BSD socket on a detached thread: `NWConnection` would honor the
        // system proxy and this probe must never route through our own proxy.
        Thread.detachNewThread {
            var reachable = false
            if let fd = try? Socket.connect(host: host, port: port, timeout: 2,
                                            allowPrivate: false) {
                reachable = true
                close(fd)
            }
            DispatchQueue.main.async { completion(reachable) }
        }
    }

    private func completeIfReady(_ cycle: Cycle) {
        guard self.cycle === cycle, cycle.fallbacksDone,
              let classification = cycle.classification else { return }
        complete(ok: cycle.succeeded,
                 latencyMS: cycle.bestLatencyMS,
                 failure: cycle.succeeded ? .none : classification,
                 cycle: cycle)
    }

    private func request(_ probe: Probe,
                         cycle: Cycle,
                         completion: @escaping (Bool, Int?, Bool) -> Void) {
        var request = URLRequest(url: probe.url,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let startedAt = Date()
        let task = session.dataTask(with: request) { data, response, error in
            var ok = false
            var latencyMS: Int?
            let http = response as? HTTPURLResponse
            let gotResponse = http != nil
            if error == nil, let http, http.statusCode == probe.expectedStatus {
                if let needle = probe.bodyNeedle {
                    ok = data.map { String(decoding: $0, as: UTF8.self).contains(needle) } ?? false
                } else {
                    ok = true
                }
                if ok { latencyMS = Int(Date().timeIntervalSince(startedAt) * 1_000) }
            }
            DispatchQueue.main.async { completion(ok, latencyMS, gotResponse) }
        }
        cycle.tasks.append(task)
        task.resume()
    }

    private func complete(ok: Bool, latencyMS: Int?, failure: ConnectivityFailure, cycle: Cycle) {
        guard self.cycle === cycle else { return }
        self.cycle = nil
        watchdog?.invalidate()
        watchdog = nil
        // No-ops for finished tasks; cancels stragglers after the watchdog.
        cycle.tasks.forEach { $0.cancel() }

        var next = snapshot
        next.record(ok: ok, latencyMS: latencyMS, at: cycle.startedAt, failure: failure)
        snapshot = next

        history?.recordConnectivity(ConnectivityRecord(at: cycle.startedAt, ok: ok,
                                                       latencyMS: latencyMS,
                                                       failure: ok ? .none : failure))

        if next.status != lastLoggedStatus {
            lastLoggedStatus = next.status
            if next.status == .online {
                Log.system.notice("internet connectivity: online (\(latencyMS ?? 0) ms)")
            } else if next.status == .offline {
                Log.system.notice("internet connectivity: offline (\(failure.rawValue))")
            }
        }

        scheduleNext(after: currentInterval)
    }

    private func scheduleNext(after delay: TimeInterval) {
        timer?.invalidate()
        timer = nil
        guard started else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.probeNow()
        }
        timer.tolerance = min(1, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
