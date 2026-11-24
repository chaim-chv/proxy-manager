import Foundation
import Darwin

// Regression probe for PS-06: a timed-out `getaddrinfo` must not leak its
// `addrinfo` list *and* orphaned resolver threads must stay bounded.
//
// The `delay` test seam makes the resolver thread deterministically outlive a
// short caller timeout. `Socket.liveResolutions` counts allocated-but-not-freed
// lists, and `Socket.liveResolverThreads` counts detached resolver threads that
// are still inside `getaddrinfo` (permit-bounded). Once the threads drain, both
// must return to 0.
//
// Compiled with Sources/Socks/Socket.swift. Exit 0 = no leak/bound violation.

let iterations = 25
var timedOut = 0
var busy = 0
for _ in 0..<iterations {
    do {
        _ = try Socket.resolve(host: "localhost", port: 443, timeout: 0.05, delay: 0.4)
        print("PROBE: unexpected resolve success (delay seam not applied)")
    } catch {
        let message = String(describing: error)
        if message.contains("timed out") { timedOut += 1 }
        else if message.contains("resolver busy") { busy += 1 }
    }
}

// Immediately after the loop the caller threads have returned; only orphaned
// resolver threads may remain, and the permit cap must hold.
let peakThreads = Socket.liveResolverThreads.value
print("PROBE: immediately after \(iterations) lookups: liveResolverThreads=\(peakThreads) " +
      "(timedOut=\(timedOut), resolverBusy=\(busy))")
var failed = false
if peakThreads <= Socket.maxConcurrentResolutions {
    print("PROBE: resolver threads bounded (<= \(Socket.maxConcurrentResolutions))")
} else {
    print("PROBE: UNBOUNDED — \(peakThreads) resolver threads live (cap \(Socket.maxConcurrentResolutions))")
    failed = true
}

// Let every resolver thread finish (delay 0.4 + getaddrinfo) and release.
Thread.sleep(forTimeInterval: 1.5)

var liveThreads = Socket.liveResolverThreads.value
var live = Socket.liveResolutions.value
print("PROBE: after drain: liveResolverThreads=\(liveThreads) liveResolutions=\(live)")

if liveThreads != 0 {
    print("PROBE: THREAD LEAK — \(liveThreads) resolver thread(s) still live")
    failed = true
}
if live == 0 {
    print("PROBE: no leaked addrinfo after \(iterations) timed-out resolutions")
} else {
    print("PROBE: LEAK — \(live) addrinfo list(s) still allocated after timeout")
    failed = true
}

// Saturation phase: more concurrent lookups than permits must cap the live
// resolver threads and reject the excess callers with a clear "resolver busy"
// error instead of spawning unbounded orphans.
let concurrent = Socket.maxConcurrentResolutions + 16
let group = DispatchGroup()
let busyLock = NSLock()
var concurrentBusy = 0
for _ in 0..<concurrent {
    group.enter()
    Thread.detachNewThread {
        defer { group.leave() }
        do {
            _ = try Socket.resolve(host: "localhost", port: 443, timeout: 0.05, delay: 1.0)
        } catch {
            if String(describing: error).contains("resolver busy") {
                busyLock.lock(); concurrentBusy += 1; busyLock.unlock()
            }
        }
    }
}
group.wait()

let saturatedThreads = Socket.liveResolverThreads.value
print("PROBE: concurrent saturation: liveResolverThreads=\(saturatedThreads) " +
      "resolverBusy=\(concurrentBusy)/\(concurrent)")
if saturatedThreads <= Socket.maxConcurrentResolutions {
    print("PROBE: concurrent resolver threads bounded (<= \(Socket.maxConcurrentResolutions))")
} else {
    print("PROBE: UNBOUNDED — \(saturatedThreads) concurrent resolver threads (cap \(Socket.maxConcurrentResolutions))")
    failed = true
}
if concurrentBusy > 0 {
    print("PROBE: saturated callers rejected with 'resolver busy'")
} else {
    print("PROBE: SATURATION NOT OBSERVED — no caller hit the permit cap")
    failed = true
}

// The permit holders outlived their callers by design; they must all drain.
Thread.sleep(forTimeInterval: 1.5)
liveThreads = Socket.liveResolverThreads.value
live = Socket.liveResolutions.value
print("PROBE: final drain: liveResolverThreads=\(liveThreads) liveResolutions=\(live)")
if liveThreads != 0 {
    print("PROBE: THREAD LEAK after saturation — \(liveThreads) resolver thread(s)")
    failed = true
}
if live != 0 {
    print("PROBE: LEAK after saturation — \(live) addrinfo list(s)")
    failed = true
}

exit(failed ? 1 : 0)
