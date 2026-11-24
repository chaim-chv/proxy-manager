import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok  \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)

// Fresh monitor: no claim until a probe answers.
do {
    let snapshot = ConnectivitySnapshot()
    expect(snapshot.status == .checking, "initial status is checking")
    expect(snapshot.health(at: t0) == .checking, "initial health is checking")
    expect(snapshot.title(at: t0) == "Checking…", "initial title is Checking…")
    expect(snapshot.menuValue(at: t0) == "Checking…", "initial menu value is Checking…")
    expect(snapshot.checks.isEmpty, "no history before the first check")
}

// Healthy online.
var snapshot = ConnectivitySnapshot()
snapshot.record(ok: true, latencyMS: 42, at: t0)
expect(snapshot.status == .online, "successful probe is online")
expect(snapshot.health(at: t0) == .good, "healthy online is good")
expect(snapshot.latencyMS == 42, "latency is recorded")
expect(snapshot.lastSuccess == t0, "last success is recorded")
expect(snapshot.title(at: t0) == "Online", "online title")
expect(snapshot.menuValue(at: t0) == "Online · 42 ms", "menu shows latency")
expect(snapshot.detail(at: t0) == "Replied in 42 ms.", "online detail shows latency")
expect(snapshot.checks.count == 1 && snapshot.checks[0].ok, "history records the check")

// A failure becomes offline immediately and counts as one drop.
snapshot.record(ok: false, latencyMS: nil, at: t0.addingTimeInterval(8))
expect(snapshot.status == .offline, "failed probe is offline")
expect(snapshot.health(at: t0.addingTimeInterval(8)) == .down, "offline health is down")
expect(snapshot.offlineSince == t0.addingTimeInterval(8), "offline start is recorded")
expect(snapshot.outages.count == 1, "the first failure counts as one drop")
expect(snapshot.latencyMS == nil, "latency clears while offline")
expect(snapshot.menuValue(at: t0.addingTimeInterval(68)) == "Offline · 1 min",
       "menu shows how long the outage has lasted")
expect(snapshot.detail(at: t0.addingTimeInterval(68)).contains("Wi-Fi can stay connected"),
       "offline detail explains link vs internet")
expect(snapshot.detail(at: t0.addingTimeInterval(68)).contains("1 min"),
       "offline detail shows outage duration")
expect(snapshot.detail(at: t0.addingTimeInterval(68)).contains("Last success at"),
       "offline detail shows when the last successful check was")

// Repeated failures while offline are not new drops.
snapshot.record(ok: false, latencyMS: nil, at: t0.addingTimeInterval(16))
snapshot.record(ok: false, latencyMS: nil, at: t0.addingTimeInterval(24))
expect(snapshot.outages.count == 1, "staying offline does not inflate the drop count")

// Recovery inside ten minutes is "unstable", not "good".
snapshot.record(ok: true, latencyMS: 30, at: t0.addingTimeInterval(32))
expect(snapshot.status == .online, "recovery is online")
expect(snapshot.offlineSince == nil, "recovery clears the outage start")
expect(snapshot.health(at: t0.addingTimeInterval(40)) == .unstable,
       "a recent drop makes the connection unstable")
expect(snapshot.title(at: t0.addingTimeInterval(40)) == "Online — unstable",
       "unstable title")
expect(snapshot.menuValue(at: t0.addingTimeInterval(40)) == "Online · unstable",
       "unstable menu value")
expect(snapshot.detail(at: t0.addingTimeInterval(40)).contains("1 drop in the last hour"),
       "detail counts recent drops")

// After the ten-minute window it is healthy again, but the drop still counts
// for the one-hour tally.
expect(snapshot.health(at: t0.addingTimeInterval(32 + 601)) == .good,
       "unstable clears after ten minutes")
expect(snapshot.detail(at: t0.addingTimeInterval(32 + 601)).contains("1 drop in the last hour"),
       "drops still count for an hour")
expect(snapshot.recentOutageCount(60 * 60, at: t0.addingTimeInterval(32 + 3_000)) == 1,
       "drop stays in the hour window")

// Outages age out of the window when a new check arrives.
snapshot.record(ok: true, latencyMS: 30, at: t0.addingTimeInterval(4_000))
expect(snapshot.recentOutageCount(60 * 60, at: t0.addingTimeInterval(4_000)) == 0,
       "drops older than an hour are discarded")
expect(snapshot.outages.isEmpty, "outage list is trimmed in place")

// History is a bounded ring.
var ring = ConnectivitySnapshot()
for index in 0..<(ConnectivitySnapshot.maxChecks + 25) {
    ring.record(ok: true, latencyMS: 10, at: t0.addingTimeInterval(Double(index)))
}
expect(ring.checks.count == ConnectivitySnapshot.maxChecks, "history is capped")
expect(ring.checks.last?.at == t0.addingTimeInterval(Double(ConnectivitySnapshot.maxChecks + 24)),
       "history keeps the newest check")
expect(ring.checks.first?.id != ring.checks.last?.id, "history ids are unique")

// Failure classification: a failed name lookup while a literal IP answered is
// DNS, not "no internet" — the distinction the dashboard and menu must keep.
var dnsSnapshot = ConnectivitySnapshot()
dnsSnapshot.record(ok: false, latencyMS: nil, at: t0, failure: .dns)
expect(dnsSnapshot.failure == .dns, "dns failure is recorded")
expect(dnsSnapshot.title(at: t0) == "Offline — DNS failing", "dns title names DNS")
expect(dnsSnapshot.menuValue(at: t0) == "No DNS · 0s", "dns menu value says No DNS")
expect(dnsSnapshot.detail(at: t0).contains("IP-level check still answered"),
       "dns detail explains the IP-level evidence")
expect(dnsSnapshot.health(at: t0) == .down, "a dns failure is still an outage")

dnsSnapshot.record(ok: true, latencyMS: 12, at: t0.addingTimeInterval(30))
expect(dnsSnapshot.failure == .none, "recovery clears the failure cause")

var networkSnapshot = ConnectivitySnapshot()
networkSnapshot.record(ok: false, latencyMS: nil, at: t0, failure: .network)
expect(networkSnapshot.title(at: t0) == "Offline", "network failure keeps the plain title")
expect(networkSnapshot.menuValue(at: t0) == "Offline · 0s", "network menu shows the duration")
expect(networkSnapshot.detail(at: t0).contains("IP-level check also failed"),
       "network detail says the IP check failed too")

// A later cycle that classifies the outage fills in a cause the watchdog could
// not determine, without moving the outage start or counting a second drop.
var lateClassified = ConnectivitySnapshot()
lateClassified.record(ok: false, latencyMS: nil, at: t0, failure: .none)
lateClassified.record(ok: false, latencyMS: nil, at: t0.addingTimeInterval(5), failure: .dns)
expect(lateClassified.failure == .dns, "a later cycle can classify an unclassified outage")
expect(lateClassified.outages.count == 1, "classification is not a new drop")
expect(lateClassified.offlineSince == t0, "classification keeps the outage start")

// Outage grouping: one outage per run of failures, first cause kept.
var builder = ConnectivityOutageBuilder()
builder.add(at: t0, ok: true, failure: .none)
builder.add(at: t0.addingTimeInterval(10), ok: false, failure: .dns)
builder.add(at: t0.addingTimeInterval(20), ok: false, failure: .network)
builder.add(at: t0.addingTimeInterval(30), ok: true, failure: .none)
builder.add(at: t0.addingTimeInterval(40), ok: false, failure: .dns)
var grouped = builder.all()
expect(grouped.count == 2, "two failure runs are two outages")
expect(grouped[0].failure == .dns, "the first cause of an outage is kept")
expect(grouped[0].checks == 2, "consecutive failures count as one outage")
expect(grouped[0].end == t0.addingTimeInterval(30), "recovery closes the outage")
expect(grouped[0].duration(at: t0.addingTimeInterval(90)) == 20, "closed duration is start→end")
expect(grouped[1].isOpen, "a trailing failure stays open")
expect(grouped[1].duration(at: t0.addingTimeInterval(100)) == 60, "open duration runs to now")
expect(grouped[0].dnsChecks == 1 && grouped[0].networkChecks == 1,
       "an outage counts each cause")
expect(grouped[0].isMixed, "an outage with both causes is mixed")
expect(grouped[0].dominantFailure == .dns, "a tie keeps the first cause")
expect(grouped[1].isBrief, "a single failed check is brief")
expect(grouped[1].causeSummary == "1 DNS check", "cause summary is human-readable")

// A clear majority wins even when the first check was the other cause.
var majority = ConnectivityOutageBuilder()
majority.add(at: t0, ok: false, failure: .dns)
majority.add(at: t0.addingTimeInterval(5), ok: false, failure: .network)
majority.add(at: t0.addingTimeInterval(10), ok: false, failure: .network)
let majorityOutages = majority.all()
expect(majorityOutages[0].dominantFailure == .network, "the majority cause wins")
expect(majorityOutages[0].causeSummary == "1 DNS + 2 network checks",
       "mixed cause summary counts both")

// A long gap between failed checks (sleep/quit) is not one giant outage.
var gapped = ConnectivityOutageBuilder()
gapped.add(at: t0, ok: false, failure: .dns)
gapped.add(at: t0.addingTimeInterval(ConnectivityOutageBuilder.maxGap + 120),
           ok: false, failure: .dns)
let split = gapped.all()
expect(split.count == 2, "a gap longer than the limit splits the outage")
expect(split[0].end == t0, "the first burst closes where it was last observed")

// Duration formatting used by the menu/detail.
expect(ConnectivitySnapshot.shortDuration(0) == "0s", "0 seconds")
expect(ConnectivitySnapshot.shortDuration(45) == "45s", "45 seconds")
expect(ConnectivitySnapshot.shortDuration(60) == "1 min", "one minute")
expect(ConnectivitySnapshot.shortDuration(3_900) == "1 h 5 min", "hours and minutes")

print("")
if failures == 0 {
    print("PASS: connectivity state")
    exit(0)
} else {
    print("FAIL: \(failures) connectivity assertion(s)")
    exit(1)
}
