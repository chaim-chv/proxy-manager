import Foundation
import Darwin

// Regression probe for the DNS-timeout leak: when `getaddrinfo` outlives the
// caller's deadline, the `addrinfo` list must still be freed exactly once.
//
// The `delay` test seam makes the resolver thread deterministically outlive a
// short caller timeout. `Socket.liveResolutions` counts allocated-but-not-freed
// lists, so once the threads drain it must be back to 0 — without the fix it
// grows by one per timed-out lookup.
//
// Compiled with Sources/Socks/Socket.swift. Exit 0 = no leak; exit 1 = leak.

let iterations = 25
for _ in 0..<iterations {
    do {
        _ = try Socket.resolve(host: "localhost", port: 443, timeout: 0.05, delay: 0.4)
        print("PROBE: unexpected resolve success (delay seam not applied)")
    } catch {
        // expected: timed out while the resolver thread is still sleeping
    }
}

// Let every resolver thread finish (delay 0.4 + getaddrinfo) and free.
Thread.sleep(forTimeInterval: 1.5)

let live = Socket.liveResolutions.value
if live == 0 {
    print("PROBE: no leaked addrinfo after \(iterations) timed-out resolutions")
    exit(0)
} else {
    print("PROBE: LEAK — \(live) addrinfo list(s) still allocated after timeout")
    exit(1)
}
