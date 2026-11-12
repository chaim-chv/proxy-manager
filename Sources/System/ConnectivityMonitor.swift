import Combine
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
        for index in 0..<ConnectivitySnapshot.maxChecks {
            let at = now.addingTimeInterval(Double(index - ConnectivitySnapshot.maxChecks + 1) * Self.activeInterval)
            seeded.record(ok: true, latencyMS: 28 + index % 9, at: at)
        }
        snapshot = seeded
    }

    // MARK: - Probing

    private func probeNow() {
        guard started, cycle == nil else { return }
        let cycle = Cycle()
        self.cycle = cycle

        let watchdog = Timer(timeInterval: Self.cycleWatchdog, repeats: false) { [weak self] _ in
            self?.complete(ok: false, latencyMS: nil, cycle: cycle)
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog

        request(Self.primary, cycle: cycle) { [weak self] ok, latency in
            guard let self else { return }
            if ok {
                self.complete(ok: true, latencyMS: latency, cycle: cycle)
            } else {
                self.probeFallbacks(for: cycle)
            }
        }
    }

    private func probeFallbacks(for cycle: Cycle) {
        cycle.remaining = Self.fallbacks.count
        for probe in Self.fallbacks {
            request(probe, cycle: cycle) { [weak self] ok, latency in
                guard let self, self.cycle === cycle else { return }
                if ok {
                    cycle.succeeded = true
                    if let latency {
                        cycle.bestLatencyMS = min(cycle.bestLatencyMS ?? latency, latency)
                    }
                }
                cycle.remaining -= 1
                if cycle.remaining == 0 {
                    self.complete(ok: cycle.succeeded,
                                  latencyMS: cycle.bestLatencyMS,
                                  cycle: cycle)
                }
            }
        }
    }

    private func request(_ probe: Probe,
                         cycle: Cycle,
                         completion: @escaping (Bool, Int?) -> Void) {
        var request = URLRequest(url: probe.url,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let startedAt = Date()
        let task = session.dataTask(with: request) { data, response, error in
            var ok = false
            var latencyMS: Int?
            if error == nil,
               let http = response as? HTTPURLResponse,
               http.statusCode == probe.expectedStatus {
                if let needle = probe.bodyNeedle {
                    ok = data.map { String(decoding: $0, as: UTF8.self).contains(needle) } ?? false
                } else {
                    ok = true
                }
                if ok { latencyMS = Int(Date().timeIntervalSince(startedAt) * 1_000) }
            }
            DispatchQueue.main.async { completion(ok, latencyMS) }
        }
        cycle.tasks.append(task)
        task.resume()
    }

    private func complete(ok: Bool, latencyMS: Int?, cycle: Cycle) {
        guard self.cycle === cycle else { return }
        self.cycle = nil
        watchdog?.invalidate()
        watchdog = nil
        // No-ops for finished tasks; cancels stragglers after the watchdog.
        cycle.tasks.forEach { $0.cancel() }

        var next = snapshot
        next.record(ok: ok, latencyMS: latencyMS, at: cycle.startedAt)
        snapshot = next

        if next.status != lastLoggedStatus {
            lastLoggedStatus = next.status
            if next.status == .online {
                Log.system.notice("internet connectivity: online (\(latencyMS ?? 0) ms)")
            } else if next.status == .offline {
                Log.system.notice("internet connectivity: offline")
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
