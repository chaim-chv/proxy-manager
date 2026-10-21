# ProxyManager — Deep Audit: Performance, Leaks, Hangs and Crash Risks

**Date:** 2026-10-21
**Commit audited:** `224c5c3` (working tree clean at audit time)
**Scope:** all of `Sources/`, plus `revert.sh`, `build.sh`, config/snapshot persistence, the privileged helper, the crash watchdog, and the SwiftUI/AppKit UI
**Method:** five parallel read-only specialist audits (proxy/sockets, telemetry/SQLite, lifecycle/system-proxy/helper, tunnel/config/routing, UI/AppKit), followed by independent verification of the highest-severity claims by the coordinating reviewer. Agents compiled standalone probes outside the repo to reproduce the relay, parser, SQLite, `getaddrinfo`, `SO_RCVTIMEO`, Security-framework and AppKit claims. No repository source was modified; this file is the only addition.

**Verification labels used below**

| Label | Meaning |
|---|---|
| **Reproduced** | A standalone probe or the real code path was executed and the failure observed. |
| **Confirmed** | Verified by reading the exact code path; the mechanism and trigger are unambiguous. |
| **Likely** | Verified mechanism, but the impact depends on environment/load or an OS behavior not exercised. |
| **Needs runtime test** | Plausible, but requires a signed build, a VM, or a GUI run to confirm. |

**Severity**

| Severity | Meaning |
|---|---|
| **Critical** | Can lose the user's internet, kill the process, or make the product's core feature fail deterministically. |
| **High** | Badly degrades performance/reliability in realistic scenarios; data loss, unbounded resource use, or a security boundary failure. |
| **Medium** | Real defect with a bounded blast radius or a trigger that needs specific conditions. |
| **Low** | Correctness/robustness/performance polish; should be fixed but is not urgent. |

---

## Executive summary

The proxy relay itself is substantially better than a typical audit target: the poll loop avoids the classic 100% CPU spins, `SIGPIPE` is handled, fds are closed on the early-return paths, telemetry is off the per-chunk path, and the feed identity/selection design is sound. The serious defects cluster in **recovery-state ownership** (system proxy, snapshot, watchdog), **SQLite failure/lifecycle handling**, **relay teardown semantics**, and **per-keystroke side effects in the UI/model layer**.

### The ten fixes with the highest expected value

1. **`enable()` deletes the only crash-recovery snapshot and disarms the watchdog even when it failed before touching the proxy** (`LC-03`). This is a direct "user loses internet" path.
2. **The privileged helper can never authorize any client** because `SecCodeCopySigningInformation` is called with empty flags, omitting the Team ID (`LC-01`, reproduced at runtime). The signed-install path is dead.
3. **The watchdog disarms when the snapshot is missing or when `networksetup` reads fail**, and **its exact-port check makes a failed re-apply look "clean"** (`LC-05`, `LC-07`). Crash recovery then never runs.
4. **Services added after enable (dock/USB Ethernet/VPN) are proxied but never snapshotted**, so disable/quit leaves that interface pointing at a dead listener (`LC-04`).
5. **One stale/deleted network service aborts the whole restore**, and the app then retries forever while the machine stays offline (`LC-06`).
6. **A dead/RST client leaves the relay draining a chatty upstream forever**, holding one of only 256 connection permits (`PS-02`, reproduced: 50 MB drained in 4 s after the client was gone).
7. **The 3 s half-close grace truncates legitimate responses whenever the client half-closes and the origin takes longer than 3 s** (`PS-03`, reproduced).
8. **SQLite errors are ignored, there is no `busy_timeout`/`ROLLBACK`, and a failed batch logs once per row** — at high request rates this becomes tens of thousands of unified-log lines per second and silent data loss (`TM-01`).
9. **A failed `ssh` respawn leaves the runner "running" with no process and no retry**, and **managed settings restart SSH on every keystroke** (`TC-04`, `TC-05`).
10. **The dashboard recomputes the feed/chart/top lists multiple times per 10 Hz tick and fully reloads the table every tick under traffic** (`UI-01`, `UI-02`).

### Finding count

Counts include the lower-severity appendix (`LC-L*`) and cross-referenced duplicates once, in their canonical section.

| Area | High | Medium-High | Medium | Low-Medium | Low | Total |
|---|---:|---:|---:|---:|---:|---:|
| Proxy core + sockets | 3 | 0 | 4 | 0 | 6 | 13 |
| Telemetry + SQLite | 4 | 0 | 7 | 3 | 5 | 19 |
| Lifecycle/system/helper/watchdog | 12 | 0 | 12 | 0 | 15 | 39 |
| Tunnel/config/routing | 6 | 3 | 8 | 6 | 5 | 28 |
| UI/AppKit | 3 | 1 | 6 | 6 | 8 | 24 |
| **Total** | **28** | **4** | **37** | **15** | **39** | **123** |

No finding reaches "critical" by the definition above only because the most dangerous paths require a second instance, a crash, or a specific user configuration; several are one small ordering mistake away from it. Treat the High column as the release blocker set.

---

## 1. Proxy core and sockets

### Summary

| ID | Sev | Confidence | Finding |
|---|---|---|---|
| PS-01 | High (conditional) | Confirmed + probe | SSRF guard checks the host string, not the resolved address; numeric/DNS forms bypass it |
| PS-02 | High | Reproduced | Relay keeps reading a chatty upstream forever after the client is hard-gone |
| PS-03 | High | Reproduced | 3 s half-close grace truncates legitimate slow responses |
| PS-04 | Medium | Reproduced | `rewrite` drops non-default ports and IPv6 brackets from `Host`; query-only path loses `/` |
| PS-05 | Medium | Confirmed | Chunked `Transfer-Encoding` is stripped while the chunked body is forwarded verbatim |
| PS-06 | Medium | Confirmed | One detached resolver thread per connect; timed-out resolvers are unbounded |
| PS-07 | Medium | Confirmed | `removeFirst(n)` on 256 KB relay buffers is O(n) per send |
| PS-08 | Low | Confirmed | `EINTR` on relay `recv`/`send` is treated as EOF/failure; `connect` retries EINTR wrongly |
| PS-09 | Low-Medium | Probe | `SO_RCVTIMEO {0,0}` means *infinite*; sub-microsecond deadlines and wall-clock jumps can pin a connection |
| PS-10 | Low | Confirmed | "256 KB" buffer cap is actually `maxBuf + 16 KB − 1` per direction |
| PS-11 | Low | Needs runtime test | Accept-loop restart race / unlocked `listenFD` read |
| PS-12 | Low | Confirmed | SOCKS5 handshake has per-recv timeouts, not an overall deadline |
| PS-13 | Low/info | Confirmed | Perf notes: no `TCP_NODELAY`, thread-per-connection, optional per-connection libproc scan, initial bytes not telemetered |

### PS-01 — SSRF guard is bypassable with DNS and numeric address forms

**Location:** `Sources/Proxy/HostClassifier.swift:9-29`, `Sources/Proxy/ProxyServer.swift:208-216`

**Confidence/evidence:** Confirmed. `getaddrinfo` on the audit machine resolved `2130706433`, `0x7f000001`, `127.1`, `localhost.` and `::ffff:127.0.0.1` to loopback/private addresses, while `HostClassifier` rejects none of those forms (it recognizes only exact `localhost`, `::1`, four-part dotted IPv4, `fe80:/fc/fd` IPv6 prefixes).

**Mechanism:** The guard classifies the *string* before connecting. The connection is then made by `getaddrinfo`, which accepts integer/hex/shorthand IPv4, trailing-dot names, IPv4-mapped IPv6, and arbitrary DNS names. The check and the actual destination use different representations.

**Trigger:** The proxy is bound to a non-loopback address (supported via `proxy.bindHost = 0.0.0.0` and only warned about at `ProxyServer.swift:115-117`). A LAN client, or a local process connecting via the LAN IP, requests `CONNECT localhost.:22`, `CONNECT 127.1:11434`, `CONNECT 2130706433:6379`, or any attacker-controlled hostname whose DNS record is private. The guard passes, the proxy connects, returns `200`, and relays raw bytes.

**Impact:** The only network ACL on an unauthenticated proxy is bypassed. Reachable targets include SSH, databases, Ollama/model servers, device management, and cloud metadata endpoints. `CONNECT` gives full bidirectional access, not a probe. A DNS-rebinding name also defeats a purely string-based check for public hostnames.

**Fix:** Move the policy decision to the resolved address and normalize numeric forms before deciding.

1. Resolve once, reuse the result for `connect`, and inspect every candidate `sockaddr` (IPv4 and IPv6).
2. Block: IPv4 loopback `127/8`, unspecified `0/8`, private `10/8`, `172.16/12`, `192.168/16`, link-local `169.254/16`, CGNAT `100.64/10`, `192.0.0/24`, benchmarking `198.18/15`, multicast `224/4`, reserved `240/4`, broadcast; IPv6 `::1`, `::`, `fe80::/10`, `fc00::/7`, `ff00::/8`, and `::ffff:0:0/96` classified by its embedded IPv4.
3. Pass `allowPrivate: clientIsLoopback` into `Socket.connect` (or check the resolved list before connecting).
4. Harden the string check anyway: strip trailing dots, use `inet_pton`, and reject integer/hex/shorthand forms rather than letting `getaddrinfo` interpret them.
5. The SOCKS route resolves on the proxy side, so local verification is impossible there; keep the string check and document the residual risk, or require a loopback client for the tunnel route too.

```swift
// Sketch
let info = try Socket.resolve(host: host, port: port, timeout: budget)
defer { freeaddrinfo(info) }
if !allowPrivate {
    var p = info
    while let a = p {
        if HostClassifier.isPrivateOrLoopback(a.pointee.ai_addr, a.pointee.ai_addrlen) {
            throw SocketError.message("blocked_private_destination")
        }
        p = a.pointee.ai_next
    }
}
```

**Verification:** Unit-test the address classifier with all of the forms above. Add an E2E that binds `0.0.0.0`, connects from a non-loopback interface, and asserts `403` for each bypass form. Add a resolver seam for the DNS-rebinding case.

---

### PS-02 — Relay keeps draining the upstream forever after the client is hard-gone

**Location:** `Sources/Proxy/ProxyServer.swift:434-436`, `:487-490`, `:501-505`, `:514-517`, `:528-531`, `:553-556`, `:563`

**Confidence/evidence:** Reproduced against the real `ProxyServer`/relay sources. A mock origin wrote 16 KB chunks every 1 ms; the client read `200`, then forced an RST with `SO_LINGER(0)`. Over the next 4 s the origin successfully wrote **50,397,184 bytes** while the proxy discarded them. CPU during the drain was ~0.16 s (this is bandwidth/permit drain, not a busy spin).

**Mechanism:** `clientReadDone` is set for three distinct events: a graceful FIN (`recv == 0`), a fatal `recv` error, and a failed `send` (EPIPE/ECONNRESET). Only the first should preserve half-close semantics. After cases 2/3 the loop still polls the upstream for `POLLIN` and reads/discards every byte. `halfClosed` only lowers the poll timeout to 3 s, but a streaming upstream always has events, so the timeout never fires. Termination requires both read sides done and both buffers empty.

**Trigger:** Any app closing a tab during a large download, a crashed/force-quit client, or a malicious local process that opens a tunnel to a fast infinite stream and RSTs. The same symmetric bug exists when the upstream send fails: `upstreamReadDone = true` but the client keeps being read forever.

**Impact:** Each dead connection holds one of the 256 semaphore permits. With 256 such connections the accept loop blocks at `semaphore.wait()`; the whole system proxy appears dead while the dead connections keep downloading at line rate. The live telemetry row also never finishes, so the dashboard shows phantom live connections.

**Fix:** Separate "graceful FIN" from "hard gone", and break immediately on hard-gone in either direction.

```swift
var clientGone = false, upstreamGone = false

if clientRevents & Int16(POLLERR | POLLNVAL) != 0 { clientGone = true }
...
if n < 0 {
    if errno == EINTR { continue }
    if errno != EAGAIN && errno != EWOULDBLOCK { clientGone = true }
}
...
if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK { clientGone = true }
...
if clientGone { c2u.removeAll(); u2c.removeAll(); break }
if upstreamGone { c2u.removeAll(); u2c.removeAll(); break }
```

Keep `readDone` exclusively for `recv() == 0`. Record the current iteration's progress before breaking so telemetry counts the bytes that actually moved. If buffered request bytes must be flushed to a still-live peer, do one bounded flush; for a dead peer, close immediately.

**Verification:** Extend `Tests/ProxyE2E` with a chatty holding origin: `CONNECT`, read `200`, RST the client, wait 2 s, assert the origin's post-RST byte delta is bounded by kernel buffers (< 2 MB) and that a fresh `CONNECT` succeeds immediately (permit freed). Mirror the test for an upstream RST while the client keeps sending.

---

### PS-03 — The 3 s half-close grace truncates legitimate slow responses

**Location:** `Sources/Proxy/ProxyServer.swift:416`, `:452`, `:563`

**Confidence/evidence:** Reproduced against the real relay. A client sent `CONNECT`, read `200`, called `shutdown(SHUT_WR)`, and read to EOF. A mock origin waited 4 s and then wrote `LATE-BODY`:

```
delay=0.0  body="LATE-BODY"  waited=0ms     truncated=false
delay=4.0  body=""           waited=3001ms  truncated=true
```

**Mechanism:** `if clientReadDone || upstreamReadDone { halfClosed = true }` arms the 3 s grace on *any* EOF, including a client's legitimate write-side shutdown. While waiting for the origin's response, poll has no events, hits the 3 s timeout, and the loop breaks. The same sticky timer applies after the origin sends FIN while the client is still slowly draining buffered data.

**Trigger:** HTTP/1.0 clients and tools that `shutdown(SHUT_WR)` after sending a request, WebSocket/SSE clients that close their write side, long-running LLM/API streams with more than 3 s between chunks. The existing E2E half-close test passes only because its mock origin replies immediately.

**Impact:** Silent response truncation, not a connection error. Clients see a short body and may cache/accept it. The documented invariant "a client that half-closes still receives the full response" holds only for 3 s.

**Fix:** Do not arm the close grace merely because the client finished writing. Apply it only in the final state where the server side is fully done and delivered:

```swift
// Remove: if clientReadDone || upstreamReadDone { halfClosed = true }
let waitingForPeerClose = upstreamReadDone && u2c.isEmpty && !clientReadDone
let timeout = waitingForPeerClose ? grace : idle
```

This gives a client FIN + slow origin the full `idle` (120 s), keeps draining a slow client after the origin FIN, and still reaps a client that never closes after its response in 3 s. If a shorter reaping time is desired for "client FIN, origin never answers", use a separate 30–60 s response budget rather than the close grace.

**Verification:** Add E2E cases: (a) direct and tunneled `CONNECT`, client half-closes, origin sleeps 4 s, assert the full body; (b) forward HTTP path with `shutdown(SHUT_WR)`, origin sleeps 4 s; (c) origin sends a body that fits in `u2c` + socket buffers, closes, client pauses 6 s mid-body.

---

### PS-04 — `rewrite` corrupts `Host` authority and query-only paths

**Location:** `Sources/Proxy/HTTPParser.swift:61-74` (`host`), `:95-104` (`path`), `:155-164` (`rewrite`)

**Confidence/evidence:** Reproduced with `HTTPParser` directly:

```
http://example.com:8080/api?x=1  -> Host: example.com            (port lost)
http://[::1]:8080/x              -> Host: ::1                    (invalid, needs brackets)
http://example.com?x=1           -> GET ?x=1 HTTP/1.1            (should be /?x=1)
```

**Mechanism:** `request.host` is deliberately host-only: the origin-form path strips the port via `splitHostPort`, and the absolute-form path uses `URL.host`, which also removes brackets. `rewrite` then strips every `Host` header and re-emits `Host: \(request.host)`. Separately, `path` appends `?query` to an empty path before the `isEmpty ? "/"` check, so a query-only URL returns `?q` rather than `/?q`.

**Trigger:** Any plain-HTTP request to a non-default port through the proxy (`http://localhost:3000`, `http://api.internal:8080`), any IPv6 origin, or an absolute URL with an empty path and a query.

**Impact:** The TCP connection goes to the right port but the origin receives the wrong authority. Virtual-host routing, reverse proxies, redirects, and frameworks with host allow-lists (Django `ALLOWED_HOSTS`, Rails host auth, Vapor) misroute or reject. IPv6 `Host: ::1` is invalid per RFC 7230. Query-only paths become malformed request targets.

**Fix:** Add an authority property and use it in `rewrite`; keep the original origin-form `Host` verbatim.

```swift
var hostHeader: String {
    if isConnect { return target }
    if target.hasPrefix("http://") || target.hasPrefix("https://"),
       let url = URL(string: target), let h = url.host {
        let authority = h.contains(":") ? "[\(h)]" : h
        let defaultPort = target.hasPrefix("https://") ? 443 : 80
        if let p = url.port, p != defaultPort { return "\(authority):\(p)" }
        return authority
    }
    return headerNamed("host") ?? host
}

var path: String {
    if target.hasPrefix("http://") || target.hasPrefix("https://"),
       let url = URL(string: target) {
        var p = url.path
        if p.isEmpty { p = "/" }
        if let q = url.query { p += "?" + q }
        return p
    }
    return target
}
```

**Verification:** Add `RegressionHarness` cases for `Host: example.com:8080`, `[::1]:8080`, and `http://h?q=1`, asserting both the request line and the emitted `Host`.

---

### PS-05 — Chunked request bodies are broken: framing is stripped, body is forwarded

**Location:** `Sources/Proxy/HTTPParser.swift:155-169`, `Sources/Proxy/ProxyServer.swift:284-287`

**Confidence/evidence:** Confirmed by inspection; no ambiguity. `rewrite` strips `transfer-encoding`, `trailer`, and `te`, then appends `Connection: close`; the relay then forwards all bytes after the header block verbatim, including the chunk-size lines.

**Mechanism:** The origin receives a request with neither `Content-Length` nor `Transfer-Encoding`, followed by bytes like `5\r\nhello\r\n0\r\n\r\n`. It parses the request as body-less and either ignores the trailing bytes or treats them as a pipelined request. `Content-Length` is *not* stripped, but duplicate differently-cased headers both survive, producing conflicting framing.

**Trigger:** Any plain-HTTP `POST`/`PUT` with `Transfer-Encoding: chunked` through the proxy (common in streaming uploads and some SDKs), or a request with duplicate `Content-Length` headers differing in case.

**Impact:** Silent upload loss, origin `400`/connection close, and a classic "proxy strips a framing header but forwards the body" smuggling primitive. Each client connection maps 1:1 to an upstream with `Connection: close`, so cross-request backend reuse is limited, but the upload is still corrupted.

**Fix:** Pick a correct, explicit policy:

- **Preferred:** if `Transfer-Encoding` is present and not `identity`, preserve `Transfer-Encoding` and `Trailer` and forward the chunked framing unchanged (the proxy does not modify the body).
- Or reject chunked requests with `501` instead of silently corrupting them.
- Reject requests with both TE and CL (`400`), and deduplicate `Content-Length` case-insensitively, rejecting conflicting values.
- Do not emit both `Connection: close` and a chunked body if the origin relies on keep-alive framing.

**Verification:** Add a mock origin that parses a chunked POST and echoes the body. Assert the origin sees exactly the body and a valid framing header. Add duplicate-case `Content-Length` cases to `RegressionHarness`.

---

### PS-06 — One detached resolver thread per connect; timed-out resolvers are unbounded

**Location:** `Sources/Socks/Socket.swift:83-113` (especially `:88` and `:100`), `:120`, `Sources/Proxy/ProxyServer.swift:347`

**Confidence/evidence:** Confirmed by code. `resolve` spawns `Thread.detachNewThread` for every `getaddrinfo`, including numeric IPs. The caller waits with a deadline (10 s direct / 5 s probe); on timeout the addrinfo list is freed correctly, but the thread keeps running until the resolver returns. The connection semaphore bounds *callers*, not orphaned resolver threads.

**Trigger:** A blackholed/slow DNS name, a half-up VPN, or mDNS. The caller times out, its connection thread exits and releases its permit; a new connection repeats. Over time the number of blocked resolver threads can exceed 256 without bound.

**Impact:** Unbounded memory/thread growth on resolver failure; avoidable thread creation + context switch on every connect, including literal IPs; the documented ~13.7 k req/s path pays two threads per tunneled connection.

**Fix:** In order:

1. Numeric fast path: parse with `inet_pton` (strip IPv6 brackets); build the `sockaddr` directly, no thread, no `getaddrinfo`.
2. Bound resolver concurrency with a global semaphore (e.g., 8 permits) or a fixed worker pool; if the cap is full, fail with "resolver busy" after the deadline.
3. Add a short-TTL DNS cache keyed by `(host, port)` and coalesce in-flight lookups for the same key.
4. Keep the existing addrinfo ownership box.

**Verification:** Extend `Tests/CrashProbes/dns_timeout` to assert the live resolver *thread* count stays bounded (not just `liveResolutions`). Microbenchmark a CONNECT to a literal IP before/after and assert no `pthread_create`.

---

### PS-07 — `removeFirst(n)` on large relay buffers is O(n) per send

**Location:** `Sources/Proxy/ProxyServer.swift:513`, `:552`; buffer sizing at `:414-417`, `:445-448`

**Confidence/evidence:** Confirmed. `Array.removeFirst(k)` memmoves the remaining `count - k` bytes. Under backpressure the buffer sits near 256 KB and drains in 16 KB chunks, so each delivered chunk shifts ~240 KB: up to ~15x write amplification per byte. Already noted in `docs/roadmap.md`.

**Impact:** Visible CPU/memory bandwidth under a slow reader; matters on lower-end Macs and at the documented 3.4 GB/s streaming baseline.

**Fix:** Consume with a read index and compact rarely.

```swift
var c2u = initial, c2uRead = 0
let available = c2u.count - c2uRead
let n = c2u.withUnsafeBytes { Darwin.send(upstream, $0.baseAddress! + c2uRead, available, 0) }
if n > 0 { c2uRead += n }
if c2uRead == c2u.count { c2u.removeAll(keepingCapacity: true); c2uRead = 0 }
else if c2uRead >= 64 * 1024 { c2u.removeFirst(c2uRead); c2uRead = 0 }
```

Use `count - read` for the `maxBuf` checks, and `reserveCapacity(maxBuf)` once at the start. Mirror for `u2c`.

**Verification:** Microbenchmark a slow reader with a large payload, comparing CPU/`sample` before and after; assert identical bytes delivered.

---

### PS-08 — `EINTR` on relay I/O is treated as EOF/failure; `connect` retries EINTR incorrectly

**Location:** `Sources/Proxy/ProxyServer.swift:498-505`, `:537-544`, `:513-517`, `:551-556`; `Sources/Socks/Socket.swift:136-139`

**Confidence/evidence:** Confirmed by code; low likelihood today because only `SIGPIPE` is ignored (ignored signals do not interrupt syscalls) and no other handlers are installed.

**Mechanism:** A signal-interrupted non-blocking `recv`/`send` returns `-1/EINTR`, which falls into the `errno != EAGAIN` branch and marks the direction done, dropping buffered data. `connect` is retried on `EINTR`; a retried non-blocking connect can return `EALREADY`/`EISCONN`, which the code treats as a hard failure and discards a connection that is actually in progress.

**Impact:** Rare truncated request/response if a signal arrives mid-transfer; a valid connection can be skipped after `EINTR`.

**Fix:** Add `if errno == EINTR { continue }` (or retry the I/O without changing state) in all four relay branches. In `connect`, break out of the retry loop on `EINTR` and go to the `waitForWritable`/`SO_ERROR` path; treat `EALREADY`/`EISCONN` as in-progress/success. Consider `sigaction` with `SA_RESTART` for any future handlers.

**Verification:** Install a no-op non-`SA_RESTART` handler for a test signal, start a large transfer, and signal the process repeatedly; assert no truncation. Add a connect-level EINTR injection test.

---

### PS-09 — Tiny/zero socket timeouts become infinite; wall-clock deadline; latent `Int` trap

**Location:** `Sources/Socks/Socket.swift:213-223`, `Sources/Proxy/ProxyServer.swift:354-362`

**Confidence/evidence:** Confirmed with a socketpair probe: `SO_RCVTIMEO {0,0}` means *block forever* on macOS, not "return immediately".

**Mechanism:** `makeTimeval` clamps negative to 0 and truncates to whole seconds/microseconds. `readHeader` passes `min(remaining, 5)`; if `remaining` is positive but < 1 µs, both `tv_sec` and `tv_usec` become 0, so the next blocking `recv` has **no timeout**. The deadline only re-checks after `recv` returns, so a client can pause forever after that byte and pin a connection thread and a permit. The deadline uses wall-clock `Date`, so a clock step backward can extend the header read far beyond 15 s. Separately, `Int(clamped)` traps on a finite value > `Int.max`; not reachable with today's fixed 120/10/5 values, but the roadmap plans configurable timeouts.

**Impact:** Permanent stuck connection/permit leak in the header phase; latent process-killing trap if timeouts become user-configurable; weak slowloris bound under clock changes.

**Fix:** Never pass `{0,0}` for a short timeout; use a 1 µs floor (`usec = max(1, ...)`) or handle `t <= 0` explicitly. Use a monotonic deadline (`DispatchTime`/`clock_gettime(CLOCK_MONOTONIC)`) and a bounded `wait` loop; prefer `poll()` + `recv()` with the remaining monotonic time. Clamp `Int(clamped)` to a sane maximum before conversion.

**Verification:** Probe `Socket.setTimeouts(fd, receive: 0)` and assert a blocking `recv` returns quickly (it hangs today). Add `makeTimeval` boundary tests for `0`, `1e-9`, `0.0000005`, `86_400`, `1e300`. Add a slowloris test where the last byte arrives at `15 s − ε`.

---

### PS-10 — Real buffer cap is ~272 KB per direction, not 256 KB

**Location:** `Sources/Proxy/ProxyServer.swift:414-417`, `:445-448`, `:499`, `:538`

**Confidence/evidence:** Confirmed. The poll mask allows a full 16 KB read whenever `count < maxBuf`, so a buffer at `maxBuf - 1` can grow to `maxBuf + 16383`.

**Impact:** Per-connection worst case is ~544 KB (plus read buffer and initial data), not 512 KB; docs and any future memory accounting are wrong by 16 KB per direction.

**Fix:** Read `min(chunk, maxBuf - count)` bytes, or document the true bound; `reserveCapacity(maxBuf)` once.

**Verification:** Assert the post-read buffer count in a unit test or add an invariant check in debug builds.

---

### PS-11 — Accept-loop restart race and unlocked `listenFD`

**Location:** `Sources/Proxy/ProxyServer.swift:111-112`, `:122-145`

**Confidence/evidence:** The data race is confirmed by inspection; the duplicate-accept-loop consequence was **not reproduced** in 3000 rapid stop/start cycles (thread count stayed at 4). `accept()` on macOS *is* woken by `close()` (probe: errno 53 `ECONNABORTED`).

**Mechanism:** `acceptLoop` reads `listenFD` outside the lock while `stop()`/`start()` write it under the lock. `stop()` closes the fd and sets `running = false`; `start()` can set it true before the old loop checks. If the old loop sees `true`, it re-reads the new fd and becomes a second accept loop. The 50 ms error sleep widens the window. `stop()` also cannot interrupt a thread blocked in `semaphore.wait()` after accepting the 257th connection.

**Impact:** Theoretically duplicate accept loops, fd churn, and an accepted fd held until a permit frees (up to the 120 s idle). In the shipping app, `AppModel` serializes start/stop on `workQueue`, which makes this hard to hit, but `ProxyServer` itself is not internally safe.

**Fix:** Add a generation counter, capture the fd locally under the lock, and check the generation each iteration. `stop()` should bump the generation, `shutdown(fd, SHUT_RDWR)` then close, and optionally wait for the loop to exit before `start()` rebinds. Consider a non-blocking listener + `DispatchSourceRead` with a cancel handler.

**Verification:** Run the E2E under TSAN. Add a stop/start churn test that forces `accept` errors (e.g., near `RLIMIT_NOFILE`) and asserts exactly one accept loop.

---

### PS-12 — SOCKS5 handshake has no overall deadline

**Location:** `Sources/Socks/SOCKS5.swift:20`, `:42-74`

**Confidence/evidence:** Confirmed. The socket gets a 5 s per-call timeout, but the handshake performs up to four `recvExact` and two `sendAll` calls. A server dribbling one byte every 4.9 s stretches the handshake to ~20–30 s, and `sendAll` can wait up to 30 s on `EAGAIN`.

**Impact:** A slow/hostile SOCKS server holds a proxy permit for tens of seconds; repeated attempts can exhaust the 256 permits.

**Fix:** Compute a monotonic handshake deadline and set each read/write timeout to `min(remaining, 5)`, or wrap the handshake in a deadline-checked loop. Reset socket timeouts to relay idle values after the handshake.

**Verification:** A mock SOCKS server that dribbles bytes; assert the handshake aborts at the deadline.

---

### PS-13 — Informational performance notes

- **No `TCP_NODELAY`** on accepted or upstream sockets (`ProxyServer.swift:83-109`, `:146`). Small HTTP/WebSocket exchanges can incur Nagle + delayed-ACK latency. Measure before adding; it increases packet count for bulk transfer.
- **Thread per accepted connection + thread per resolve.** Deliberate (GCD caps blocking threads), but thread creation is a fixed per-connection cost. A bounded worker pool would remove it; not required.
- **`AppResolver` libproc scan per connection** when per-app telemetry/routing is enabled (`ProxyServer.swift:221-228`, `AppResolver.swift:210-248`): ~1–3 ms and ~80 KB of buffers per scan. See `TC-07`.
- **256 idle `CONNECT`s** can hold all permits for the 120 s idle timeout. Consider a shorter pre-data timeout.
- **Telemetry undercount:** bytes forwarded as `initial`/`leftover` before `relay` are not added to `bytesOut` (`ProxyServer.swift:272`, `:293`).

---

## 2. Telemetry and SQLite

### Summary

| ID | Sev | Confidence | Finding |
|---|---|---|---|
| TM-01 | High | Confirmed + probe | SQLite rc ignored, no `busy_timeout`, no `ROLLBACK`, per-row log storm, silent prepare failure |
| TM-02 | High | Confirmed | Retention/max-rows settings are captured once and never updated until relaunch |
| TM-03 | High | Confirmed + measured | Retention bounds rows, not disk; no WAL cap/truncate/VACUUM; catch-up delete is one unbounded statement |
| TM-04 | Medium | Confirmed + measured | Long-range analytics run on the writer queue every 2 s; wrong index; 130 ms @500k, 580 ms @2M |
| TM-05 | Medium | Confirmed | Hot path is not O(1): O(n) `endSession`, global lock per 16 KB chunk, lock held while building snapshots |
| TM-06 | Medium | Confirmed | Dashboard chart/top/feed recomputation + full table reload (see `UI-01`, `UI-02`) |
| TM-07 | Medium | Confirmed | `purge()` has no generation: in-flight rows resurrect, stats can return, pre-purge inserts can land after DELETE |
| TM-08 | Medium | Confirmed | Feed cap is by count, not bytes; a 64 KB `Host` can make `recentRequests` ~320 MB |
| TM-09 | Medium | Likely | Unbounded `dbQueue` backlog with full event arrays when SQLite is slow/locked |
| TM-10 | High impact/Low likelihood | Confirmed | `Int64(retentionDays) * 86_400_000` traps on overflow in a background block |
| TM-11 | Medium | Confirmed | Failed `sqlite3_open` leaks the handle; failed prepare silently disables telemetry; corrupt DB never quarantined |
| TM-12 | Low-Medium | Confirmed | `AppIcon` caches successes only (see `UI-12`) |
| TM-13 | Low-Medium | Confirmed | Inspector recomputes routing/target decisions (see `UI-16`) |
| TM-14 | Low-Medium | Confirmed | Long-lived live rows sort out of the 250-row feed window |
| TM-15 | Low | Confirmed | Up to 999 rows are memory-only and lost on crash |
| TM-16 | Low | Disproved | `reloadData()` selection-notification concern; AppKit probe showed it does not post, so not a bug |
| TM-17 | Low | Confirmed | DB open/migrate on the main thread; `flushNow()` can block quit for seconds |
| TM-18 | Low | Confirmed | 5 m chart/top lists sample only the last 2,000/3,000 events; stale selection; Active=0 after purge |
| TM-19 | Low | Confirmed | 10 Hz flusher + main hop continue with no Dashboard open |

### TM-01 — SQLite error handling turns every failure into data loss plus a log storm

**Location:** `Sources/Telemetry/TelemetryStore.swift:172-182`, `:240-249`, `:412-464`, `:481`, `:484`

**Confidence/evidence:** Confirmed; a two-writer probe reproduced `BEGIN failed: database is locked`, 1,000 failing autocommit inserts, and `COMMIT failed: cannot commit - no transaction is active`. There is no `sqlite3_busy_timeout` anywhere in the repo.

**Mechanism:**

1. `sqlite3_exec(db, "BEGIN IMMEDIATE", ...)` return code is ignored. If another connection holds the write lock, `BEGIN` fails and the 1,000 inserts run in autocommit, each failing with `SQLITE_BUSY`.
2. Each failing row calls `NSLog`, so one batch can emit 1,001 lines. At 13.7 k req/s (~14 batches/s) that is ~14,000 unified-log lines per second.
3. `COMMIT` failure is ignored and there is no `ROLLBACK`, so the transaction stays open. The next `BEGIN` fails ("cannot start a transaction within a transaction"), also ignored, and every later batch piles into one ever-growing transaction.
4. `prepareStatements` ignores its return code and never logs. If `migrateSchema` failed (locked DB), the `INSERT` fails to prepare with `no such column`; from then on `insertBatch` returns silently forever. The Dashboard still shows live rows, so the user believes telemetry is being recorded.
5. Schema and purge `sqlite3_exec` calls are also unchecked, so disk-full/corrupt failures are invisible.

**Impact:** Silent telemetry loss, CPU/log-volume blow-up precisely when the machine is unhealthy, and potentially unbounded WAL/transaction growth while locked. A second app instance (no single-instance guard) or any SQLite tool is a valid trigger.

**Fix:**

```swift
// open
sqlite3_busy_timeout(db, 2_000)
sqlite3_exec(db, "PRAGMA journal_size_limit=33554432;", nil, nil, nil)

// prepare
guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, stmt != nil else {
    Log.telemetry.error("telemetry prepare failed: \(errmsg(db))")
    telemetryUnavailable = true
    return
}

// insertBatch
guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
    noteBatchFailure(); return          // do not insert outside a transaction
}
var failed = 0
for e in events { if step != SQLITE_DONE { failed += 1 } }
if failed > 0 || sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
    noteBatchFailure()
}
```

`noteBatchFailure` should log once per batch (first failure + count) and at most once per 60 s while failing. Expose `storeError` to the UI so Settings → Monitoring can show that persistence is unavailable.

**Verification:** Extend `Tests/TelemetryHarness` with a holder connection that takes `BEGIN IMMEDIATE`, then `record` + `flushNow`; assert one log line, no crash, and successful persistence after release. Open a read-only DB and assert a single explicit prepare error.

---

### TM-02 — Retention and max-rows settings never reach the running store

**Location:** `Sources/Telemetry/TelemetryStore.swift:133-134`, `:155-158`; `Sources/AppModel.swift:78-80`; `Sources/UI/SettingsView.swift:755-758`

**Confidence/evidence:** Confirmed. `maxRows`/`retentionDays` are `let`, set only in `init`. `syncProxySettings()` pushes proxy/routing settings to `ProxyServer` but never touches telemetry. There is no setter.

**Trigger:** A user watching a 4 GB DB lowers retention from 7 to 1 day, or lowers `maxRows` in `config.json`. Nothing happens for the rest of the process lifetime.

**Impact:** The retention UI is a lie until relaunch; disk can keep growing despite the setting. Docs do not mention a restart requirement.

**Fix:** Make both `var` under a small lock, add `setLimits(maxRows:retentionDays:)` that clamps and forces `lastPurgeMs = 0`, and call it from `AppModel.syncProxySettings()` next to the `recordPaths` update. Clamp at decode as well (`TM-10`).

**Verification:** Create a store with 7-day retention, insert a 2-day-old event, call `setLimits(1)`, pump the flusher, assert the row is purged without reconstructing the store.

---

### TM-03 — Retention bounds rows, not disk; the database never shrinks

**Location:** `Sources/Telemetry/TelemetryStore.swift:172-182`, `:471-487`, `:505-524`, `:166-170`

**Confidence/evidence:** Confirmed and measured:

```
after 600k inserts:                 db 19,955,712   wal 20,085,032
after DELETE of 400k rows:          db 19,955,712   wal 20,060,312
after two PASSIVE checkpoints:      db 19,955,712   wal 20,060,312
after deleting 1.5M rows (235 MB):  235,712,512 bytes — unchanged
```

**Mechanism:** No `PRAGMA journal_size_limit`; a checkpoint truncates nothing by default. No `wal_checkpoint(TRUNCATE)` on quit, in `flushNow`, or after purge. The store is owned by `AppModel.shared` and never deallocated, so `deinit`'s `sqlite3_close` never runs. `DELETE` frees pages for reuse but does not return them to the filesystem; there is no `VACUUM`. The `maxRows` catch-up uses `LIMIT -1 OFFSET maxRows`, materialising every excess id in one autocommit statement (measured 3.12 s for 1.5 M rows).

**Impact:** Long-uptime disk growth to the peak footprint (the docs claim the opposite), a "Purge history now" button that frees no space, and multi-second stalls of the entire telemetry pipeline (and quit) during catch-up purges.

**Fix:**

```swift
sqlite3_exec(db, "PRAGMA journal_size_limit=33554432;", nil, nil, nil)
// bounded, resumable trim in 5k-row chunks
repeat {
    sqlite3_exec(db, """
      DELETE FROM requests WHERE id IN (
        SELECT id FROM requests WHERE ts < \(t) OR (ts = \(t) AND id < \(id))
        LIMIT 5000)
      """, ...)
} while sqlite3_changes(db) > 0

// user purge + quit
sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", ...)
// user-initiated only, needs ~2x free space:
sqlite3_exec(db, "VACUUM;", ...)
```

Log DB/WAL size and row count in Settings → Monitoring. Add a scheduled `wal_checkpoint(TRUNCATE)` (e.g., after purge and on quit).

**Verification:** Insert old rows, purge, assert chunked progress and that the `-wal` is ≤ the journal limit after the post-purge checkpoint. Soak test with a 7-day dashboard and mid-run `maxRows` change.

---

### TM-04 — Long-range analytics run on the writer's serial queue every 2 seconds

**Location:** `Sources/Telemetry/TelemetryStore.swift:558-652`; `Sources/UI/DashboardView.swift:90`, `:124`, `:583-595`

**Confidence/evidence:** Confirmed with `EXPLAIN QUERY PLAN` and timings. `topHosts` uses the 3-value `idx_requests_route`, scans every TUNNEL row, ignores the `ts` range, and sorts twice in temp B-trees. Measured: 130 ms @500k rows, 580 ms @2M for `topHosts`; 80–90 ms for the chart @200k. At the default 500k cap, long-range mode spends ~330 ms of every 2 s on the same serial queue used by inserts.

**Trigger:** Leave the dashboard on 1 h/24 h/7 d with a large `requests` table.

**Impact:** `insertBatch` and purge stall behind analytics; `dbAccumulator` grows; CPU/disk/battery burn while the window is open. If a query exceeds 2 s, the timer queues another without an in-flight guard.

**Fix:**

1. Open a second **read-only** connection (`SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`) on a separate `analyticsQueue`; finalize it on quit. WAL permits concurrent readers.
2. Add `CREATE INDEX idx_requests_ts_route ON requests(ts, route)`; drop `idx_requests_host` and `idx_requests_route` unless a query needs them (they cost write amplification).
3. Add an in-flight flag + generation token so only one query pair is outstanding and stale completions are dropped.
4. Use range-dependent cadence: 5 s for 1 h, 15 s for 24 h, 60 s for 7 d; 2 s only for the in-memory 5 m.
5. Consider an hourly rollup table for 7 d top hosts.

**Verification:** Assert the new plan uses `ts_route`; measure insert-batch latency with `os_signpost` while 7 d is open.

---

### TM-05 — The hot path is O(1) only by assertion

**Location:** `Sources/Telemetry/TelemetryStore.swift:267-299`, `:328-362`; `Sources/Proxy/ProxyServer.swift:273`, `:294`, `:565-570`

**Confidence/evidence:** Confirmed.

**Mechanism:**

- `beginSession` does `sessionOrder.insert(at: 0)` — an O(n) memmove (n ≤ 256).
- `endSession` does `firstIndex(of:)` + `remove(at:)` **while holding the global lock**.
- `updateSession` always takes the global lock before the per-session lock, and the progress closure fires once per poll iteration that moved bytes (~every 16 KB per direction). At 3.4 GB/s that is ~207,000 calls/s contending with `record`/`endSession`/`flush`.
- `flush` holds the global lock while iterating all sessions, taking each per-session lock and building up to 256 `RequestEvent` snapshots (struct copies, string retains, array growth).

**Impact:** Tail latency and wasted CPU on relay threads under exactly the load the design targets. Not a correctness bug, but the documented O(1) claim is false.

**Fix:** Return a session token from `beginSession` and have `progress` update two per-session atomics with no global lock. Replace `sessionOrder` with `[UUID: Int]` + swap-remove (order is irrelevant). In `flush`, copy the session values under the lock, release it, then read counters and build snapshots.

**Verification:** A microbenchmark with 256 threads at 200k updates/s; report p99 lock wait. Re-run `ProxyE2E` throughput before/after.

---

### TM-06 — Dashboard recomputation and full table reload

See `UI-01` and `UI-02`. This is the single largest steady-state UI cost and it is structural, not measurement-dependent.

---

### TM-07 — `purge()` has no generation; Clear can be undone

**Location:** `Sources/Telemetry/TelemetryStore.swift:505-524`, `:290-299`, `:328-379`, `:381-433`

**Confidence/evidence:** Confirmed.

**Mechanism:**

1. `purge()` clears `sessions`/`sessionOrder`, but live relays still call `endSession`, which appends a finish and calls `appendCompletion` — up to 256 rows and their stats deltas come back after "Clear".
2. A `flush()` that snapshotted `pendingDelta` just before the lock clear can enqueue `applyToUI` after purge's main block, adding the pre-purge delta back.
3. `flush()` moves events to `dbBatch` under the lock, then dispatches `insertBatch`; `purge()` dispatches its `DELETE`. Two threads dispatching to the same serial queue can order the insert after the DELETE, leaving pre-purge rows in SQLite.
4. `purge()` zeroes `stats.activeConnections` while connections are still live; it is not corrected until the next accept/close.

**Impact:** "Clear history" does not clear; counts go backwards/forward inconsistently; docs claim in-flight rows are discarded, which is false.

**Fix:** Add a `generation: UInt64` incremented under `lock` in `purge()`. Capture it in `flush()` and pass it to `applyToUI`/`insertBatch`; drop stale blocks. In `endSession`, skip `appendCompletion` for purged sessions (keep a purged-ID set or mark the session cancelled). Set `activeConnections` to the current live count after purge.

**Verification:** `beginSession` → `purge` → `endSession` → pump flushes; assert both memory and `SELECT COUNT(*)` stay zero. Stress purge concurrently with 100 live records.

---

### TM-08 — The 5,000-event cap is by count, not bytes

**Location:** `Sources/Telemetry/TelemetryStore.swift:110`, `:126`, `:414-419`; `Sources/Proxy/ProxyServer.swift:195`, `:199`; `Sources/Proxy/HTTPParser.swift:74-84`

**Confidence/evidence:** Confirmed. The header block is capped at 64 KB; a `CONNECT <60 KB>` produces a `RequestEvent.host` of ~60 KB, and an absolute-form URL can put similar data in `path`. Five thousand such rows is ~320 MB in memory, and 500k such rows is ~32 GB on disk.

**Impact:** Local memory/disk exhaustion (the proxy is loopback by default, so this is not remote, but any local process can do it); UI text measurement (`NSString.size`) becomes expensive for long hosts.

**Fix:** Clamp at ingest: `host.prefix(255)`, `path.prefix(2048)`, `error.prefix(1024)`, `app.prefix(255)`. Add a byte budget for `recentRequests` (e.g., 8 MB) alongside the 5,000-row cap, dropping oldest until both hold.

**Verification:** Record ten 60 KB-host events; assert the stored host is ≤255 bytes and the byte budget holds after 5,000 large rows.

---

### TM-09 — Unbounded DB queue backlog when SQLite is slow

**Location:** `Sources/Telemetry/TelemetryStore.swift:335-338`, `:372-376`, `:476-486`, `:493-503`

**Confidence/evidence:** Likely. `flush()` dispatches `insertBatch` with a strong copy of the event array whenever `dbAccumulator >= 1000`, with no outstanding-batch cap or backpressure. A 3 s catch-up delete, a 0.6–3 s analytics query, or a full disk can delay the writer while batches accumulate.

**Impact:** At 13.7 k req/s, a 1 s stall accumulates ~14 k events (a few MB normally, hundreds of MB with long hosts per TM-08). Memory spikes during exactly the unhealthy periods.

**Fix:** Keep at most one dirty write scheduled, or a counting semaphore around `insertBatch` with a drop+count policy when saturated. Add a time-based flush (`TM-15`). Log the dropped count.

**Verification:** Hold `BEGIN IMMEDIATE` on a second connection for 10 s while recording at 10 k/s; assert bounded queued event count.

---

### TM-10 — Config-driven `Int64` overflow crashes the process

**Location:** `Sources/Telemetry/TelemetryStore.swift:478-479`; `Sources/Config/ConfigModels.swift:330-331`

**Confidence/evidence:** Confirmed by Swift semantics. `retentionDays` is decoded with no range clamp; `Int64(days) * 86_400_000` traps for `days > ~106,751,991`. The trap runs on `dbQueue` inside `maybePurge` (5 minutes after launch), so the app can crash-loop on relaunch.

**Trigger:** `config.json` with `"retentionDays": 9223372036854775807` (hand edit, bad migration, future schema). The stepper clamps 1...90, but the file is user-editable.

**Impact:** Process death and a crash loop every 5 minutes, independently of the proxy.

**Fix:** Clamp at decode (`retentionDays` 1...3,650, `maxRows` 0...10,000,000) **and** use `multipliedReportingOverflow` with a floor fallback.

```swift
let (m, overflow) = Int64(days).multipliedReportingOverflow(by: 86_400_000)
let cutoff = overflow ? Int64.min : nowMs - m
```

**Verification:** Decode the hostile value and assert a clamp; call the cutoff helper with `Int.max` and assert no trap.

---

### TM-11 — Open/prepare failures are silent or leak the handle

**Location:** `Sources/Telemetry/TelemetryStore.swift:166-182`, `:240-249`, `:437-438`

**Confidence/evidence:** Confirmed.

**Mechanism:** On `sqlite3_open` failure, the code `NSLog`s and sets `db = nil` without `sqlite3_close` (SQLite allocates a handle on most failures). With `db == nil` or a failed prepare, `insertBatch` returns silently, forever. A corrupt DB opens successfully, then every insert fails with `SQLITE_CORRUPT`/`SQLITE_NOTADB`, producing the TM-01 log storm. There is no integrity check or quarantine-and-recreate.

**Impact:** The app looks healthy (live feed works) while persistence is dead. Leaked handle/fd for the process lifetime in the open-failure case.

**Fix:** Close the handle on open failure, log via `Log.telemetry`, and expose a `storeError` published value in Settings/Monitoring. On `SQLITE_CORRUPT`/`SQLITE_NOTADB`, finalize, close, rename to `telemetry.sqlite.corrupt-<ts>`, reopen a fresh DB, log once, and notify the UI.

**Verification:** Open a path in a nonexistent directory; assert no crash, one error log, and no leaked fd. Corrupt the SQLite header and assert quarantine + a fresh DB.

---

### TM-14 — Long-lived live rows disappear from the feed

**Location:** `Sources/UI/DashboardView.swift:525-540`, `:556`

**Confidence/evidence:** Confirmed. `baseFeedRows` builds live + the newest 250 completed rows, sorts **everything by `ts` descending**, then `prefix(250)`. A live SSE/keep-alive connection started 10 minutes ago has an old `ts` and sorts below newer completions.

**Impact:** The connection type the live feed exists for vanishes from the table while its detail (if selected) still updates. Confusing and looks like a telemetry bug.

**Fix:** Keep live rows pinned above the completed window, or sort by `(isLive, ts)` and apply `prefix(250)` only to the completed part.

**Verification:** Start 300 completions plus one long-lived CONNECT; assert the live row is present in `computeFeedRows()` (extract it to a pure function for tests).

---

### TM-15 — Up to 999 rows are lost on a crash

**Location:** `Sources/Telemetry/TelemetryStore.swift:336-338`, `:493-503`

**Confidence/evidence:** Confirmed. `dbAccumulator` flushes only at 1,000 rows. At 5 req/s, rows wait ~200 s before reaching SQLite; `kill -9`/crash loses them. `flushNow` only runs on a graceful quit.

**Impact:** Up to 999 events lost on crash/force-quit, more during long low-rate periods.

**Fix:** Flush when `count >= 1000` **or** the oldest accumulator row is older than ~5 s (track `accumulatorSinceMs`).

**Verification:** Record 3 rows, pump 6 s without `flushNow`, assert they are in SQLite.

---

### TM-16 — `reloadData()` selection concern (disproved)

**Location:** `Sources/UI/FeedTable.swift:98-143`

A code-review hypothesis suggested `reloadData()` might post `tableViewSelectionDidChange` synchronously and clear the inspector. An AppKit probe run by the UI auditor showed `reloadData()` clears an invalid selection **without posting** the delegate callback, so the reselect-by-id path is not overwritten. The ordering remains fragile; adding an `isProgrammaticReload` guard is cheap defensive work, but this is not a confirmed bug.

---

### TM-17 — DB open/migrate on the main thread; `flushNow()` can block quit

**Location:** `Sources/Telemetry/TelemetryStore.swift:159-163`, `:172-238`, `:493-503`; `Sources/AppModel.swift:78-80`, `:785`; `Sources/App.swift:167-169`

**Confidence/evidence:** Confirmed path; impact depends on DB size/disk. `TelemetryStore.init` opens the DB, sets WAL, creates the table and three indexes, runs `PRAGMA table_info`, and may `ALTER TABLE`, all synchronously on main before the first window. `flushNow()` does `dbQueue.sync` from `applicationWillTerminate`; a 3 s catch-up delete or 0.6 s analytics query blocks quit for that long.

**Impact:** Launch stall on a large/cold DB; quit/logout/Sparkle-install hang on an unhealthy DB.

**Fix:** Open/migrate on `dbQueue` and inject the store when ready. In `flushNow`, use a bounded async + semaphore (`wait(timeout: .now() + 2)`) and leave the snapshot/watchdog to cover the rest. Run `wal_checkpoint(TRUNCATE)` there.

**Verification:** Time init on a 1 M-row DB; simulate a slow `dbQueue` block and assert quit is bounded.

---

### TM-18 — High-rate chart/top-list correctness and stale selection

**Location:** `Sources/UI/DashboardView.swift:122-123`, `:237-248`, `:410-454`, `:482-487`

**Confidence/evidence:** Confirmed.

- The 5 m chart samples only `recentRequests.suffix(2000)`; at 13.7 k req/s that is ~146 ms of traffic, not 5 minutes. The axis still claims 5 m.
- `inMemoryTopTunneledHosts`/`inMemoryTopApps` scan only 3,000 events (~0.2 s at that rate), so "Top tunneled hosts" reflects a fraction of a second.
- `selectedID` is reconciled only on `.onChange(of: recentRequests.count)`; once the array saturates at 5,000, the count stops changing and a selected event can roll out silently.
- `purge()` zeroes `activeConnections` while connections are live.

**Impact:** Misleading analytics under load, a stale selection, and an Active count that stays 0 after a purge.

**Fix:** Maintain 5 m buckets incrementally in `applyToUI` (10-slot dictionary keyed by bucket start), derive top hosts/apps from the same buckets or SQL. Reconcile `selectedID` whenever the id is absent. On purge, set `activeConnections` to the current live count.

**Verification:** Feed 20,000 synthetic events over 5 minutes and assert bucket count/total. At the 5,000 cap, assert the selected id clears when it falls out.

---

### TM-19 — 10 Hz flusher and main hop run with no Dashboard open

**Location:** `Sources/Telemetry/TelemetryStore.swift:251-257`, `:364-370`

**Confidence/evidence:** Confirmed. `hasUIWork` gates on telemetry content, not on observers. With traffic and the dashboard closed, the store still enqueues a main-queue block 10×/s, trims `recentRequests` (`removeFirst` shifting up to 5,000 elements), rebuilds/diffs `liveRequests` (up to 256 equality checks), and updates stats.

**Impact:** ~1.5 MB/s of array shifting at the cap and keeps the full feed alive for no visible benefit; wasted main-thread time while the app is in the background.

**Fix:** Let `DashboardWindowController` set `telemetry.isUIObserved = true/false` on show/close, and skip the main hop (still do DB accumulation) when unobserved. Raise the timer interval when idle and no sessions are live.

**Verification:** Signpost the main hop; with the dashboard closed and 13 k req/s, assert main-thread telemetry work is ~0.

---

## 3. App lifecycle, system proxy, privileged helper and watchdog

### Summary

| ID | Sev | Confidence | Finding |
|---|---|---|---|
| LC-01 | High | Reproduced | Helper Team-ID lookup omits signing-info flags, so every client is rejected |
| LC-02 | High | Confirmed | XPC error handlers never signal the semaphore: fixed 15 s stall; helper can outlive the timeout |
| LC-03 | High | Confirmed | `enable()` deletes the snapshot and disarms the watchdog even when it failed before applying |
| LC-04 | High | Confirmed | Services added after enable are proxied but never snapshotted → left dangling on disable/quit |
| LC-05 | High | Confirmed | Watchdog disarms on a missing snapshot or a failed `networksetup` read ("clean") |
| LC-06 | High | Confirmed + probe | One stale/deleted service aborts the whole restore; exit 8 escalates to admin |
| LC-07 | High | Confirmed | Watchdog exact-port match turns a failed re-apply/port change into "clean" and disarms |
| LC-08 | High | Confirmed + live state | Snapshot lifecycle: never cleared, re-captured from a dangling proxy, writes ignored, stale on quit |
| LC-09 | High/Medium | Confirmed | Empty/failed service lists and empty restores are treated as success; pipe read after exit can deadlock |
| LC-10 | High/Medium | Confirmed | Crash between apply and `wasOnKey` is never recovered on launch |
| LC-11 | High | Confirmed | Non-loopback `bindHost` leaves the system proxy pointing at a dead `127.0.0.1` |
| LC-12 | High/Medium | Confirmed | Quit delegates to a watchdog that may not exist; quit restore can prompt/block up to 180 s |
| LC-13 | Medium | Confirmed | Watchdog install/relaunch race can clobber a fresh apply and disarm it |
| LC-14 | Medium | Confirmed | Multiple instances share/overwrite all recovery state |
| LC-15 | Medium | Confirmed | Shell env reconciled only at enable/disable; fish/csh breakage; symlinks replaced |
| LC-16 | Medium | Confirmed | Restore does not faithfully restore bypass/PAC/auth; capture defaults failed reads to "off" |
| LC-17 | Medium | Confirmed | Unbounded process waits, polling, main-thread `launchctl`, orphaned admin children |
| LC-18 | Medium | Confirmed | Watchdog retry storm, stale config for env removal, orphaned SSH, unbounded log |
| LC-19 | Medium | Confirmed | Keystroke re-apply storm; port 0/invalid hosts accepted (side effects canonical in `TC-05`) |
| LC-20 | Medium | Confirmed | Cross-thread reads of `config`/`state`; `syncManagedTunnel` can run concurrently |
| LC-21 | Medium-low | Confirmed | `degraded` conflates tunnel-down with recovery-failed; can show ON after a failed restore |
| LC-22 | Medium-low | Confirmed | `WatchdogArmedState` not tolerant; out-of-range values wipe the whole config |
| LC-23 | Medium-low | Confirmed | Helper silently drops service names outside its charset |
| LC-24 | Medium | Confirmed | `revert.sh` does not restore originals/PAC/GUI env, does not kill SSH/helper, deletes the snapshot on failure |

### LC-01 — The privileged helper rejects every client

**Location:** `Sources/Helper/main.swift:46-53` (call at line 50)

**Confidence/evidence:** Reproduced at runtime. A probe against a Developer-ID-signed app:

```
flags=0              keys=[...]                         team(0) = nil
flags=SigningInfo    keys=[..., teamid, ...]            team = XM9GC3SUL2
```

The SDK marks `kSecCodeInfoTeamIdentifier` as `/* Signing */` and requires `kSecCSSigningInformation`. With `[]`, the key is absent.

**Mechanism:** `ownTeamIdentifier()` returns `nil`, so `isAuthorized` returns false before checking the client. `listener(_:shouldAcceptNewConnection:)` rejects every connection.

**Trigger:** Any Developer-ID-signed install where the helper daemon is enabled. The app silently falls back to direct `networksetup` and then to the `osascript` admin prompt.

**Impact:** The one-time-admin-grant design is dead. Every first toggle per session pays the LC-02 15 s stall before falling back; every watchdog restore does too. Security-wise it fails closed, but the feature does not work.

**Fix:**

```swift
let signing = SecCSFlags(rawValue: kSecCSSigningInformation)
guard SecCodeCopySigningInformation(staticCode, signing, &info) == errSecSuccess,
      let dict = info as? [String: Any],
      let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
      !team.isEmpty else { return nil }
```

Cache the helper's own Team ID. Optionally also require the designated requirement/bundle-id, not just "same Team ID".

**Verification:** The probe above; a `HelperAuthHarness` that signs a test binary and asserts non-nil. On a signed install, `log stream` must show no "rejected unauthorized connection".

---

### LC-02 — The XPC bridge waits the full 15 s on immediate failures

**Location:** `Sources/System/HelperXPCClient.swift:55-82`; `Sources/System/SystemProxyManager.swift:168-184`

**Confidence/evidence:** Confirmed. `sync` only wakes on the reply callback. The error/interruption/invalidation handlers set `errorBox` but never signal the semaphore.

**Mechanism:** A rejected/invalidated connection (LC-01), a crashed helper, or a missing daemon blocks the caller for the full 15 s. The timeout is also independent of the work: `HelperService` runs each command serially with a 20 s per-command timeout, so a slow apply can exceed 15 s. On timeout the app invalidates and falls back to `runDirect` **while the helper is still mutating**, causing two concurrent writers and a rollback that may undo an in-progress apply.

**Impact:** 15 s added to the first toggle per session and to every watchdog restore (internet stays dead 15 s longer); duplicate mutations; a successful apply classified as failed.

**Fix:** Signal the semaphore from every error/interruption/invalidation handler. Return a typed result (`success`, `remoteError`, `timeout`) instead of always "timed out". Compute the timeout from command count (`max(15, 2 * n)`) or implement cancellation. Make `HelperService` reply from a worker queue and check an epoch/cancellation token before each command.

**Verification:** A fake XPC endpoint that immediately rejects; assert `<1 s` and a surfaced error. A slow helper that asserts no overlapping fallback.

---

### LC-03 — `enable()` destroys recovery state on a pre-apply failure

**Location:** `Sources/AppModel.swift:250-344` (esp. 253-277, 317-326)

**Confidence/evidence:** Confirmed. `proxyApplied` is set true **before** `applyProxy`; the catch's `rolledBack` starts true. If `proxyServer.start()` throws (port in use, invalid bind host, another instance) while a snapshot exists on disk, the catch runs with `proxyApplied == false`, takes the `rolledBack` branch, and clears the snapshot, disarms the watchdog, and sets `wasOnKey = false`.

**Trigger:** `enable()` while port 8888 is occupied or the bind host is invalid, with a snapshot left by a previous crash/instance.

**Impact:** The only recovery state is deleted, crash protection is disabled, and a dangling proxy becomes unrecoverable by the app. Direct "user loses internet" path.

**Fix:** Track whether the system proxy was actually touched. Only clear/disarm/`wasOnKey=false` after a successful restore of a state the app changed. On a pre-apply failure, keep the snapshot, keep the watchdog armed, keep the listener running if it started, and report the bind error.

```swift
var touchedProxy = false
...
touchedProxy = true
try applyProxy(...)
} catch {
    if touchedProxy {
        let restored = (try? restoreOrClear()) != nil
        if restored { clearStateAndDisarm() } else { keepRecoveryState(); setState(.degraded) }
    } else {
        // preserve snapshot + armed watchdog; just report the start failure
    }
}
```

**Verification:** Inject a `ProxyServer.start` failure with a pre-created snapshot and armed watchdog; assert both survive and the state is not `.on`.

---

### LC-04 — New services are proxied but never snapshotted

**Location:** `Sources/AppModel.swift:185-211` (wake/reapply), `:471-513` (port rebind); `Sources/System/SystemProxyManager.swift:104-109`

**Confidence/evidence:** Confirmed. Both reapply paths call `applyProxy(services: listServices())` without merging new services into the snapshot. Restore only iterates snapshot keys.

**Trigger:** Enable on Wi-Fi, then plug in a USB/Thunderbolt Ethernet or dock, or bring up a VPN; sleep/wake or a path update re-applies. Then disable, quit, or crash.

**Impact:** The new (often now-primary) service points at `127.0.0.1:8888` but is not in the snapshot. `disable()` restores only snapshot services, stops the listener, clears the snapshot, sets `wasOnKey=false`, and disarms the watchdog. That interface has no internet. The user's original proxy on it was also never captured.

**Fix:** Before any apply, call `ensureSnapshotCovers(listServices())`: for each service not in the snapshot, read and merge its state, persist the snapshot **before** applying. On restore, also clear any current service that points at our local port but is absent from the snapshot. Capture at reapply time under `workQueue` and log new services.

**Verification:** VM/harness: enable, add a service, trigger reapply, disable, assert it is restored or cleared. Repeat with a crash + watchdog restore.

---

### LC-05 — The watchdog disarms on unproven-clean states

**Location:** `Sources/Support/Watchdog.swift:226-240`; `Sources/System/SystemProxyManager.swift:20-27`

**Confidence/evidence:** Confirmed.

```swift
guard let snapshot = hooks.loadSnapshot() else {
    hooks.log("no snapshot; nothing to restore"); hooks.disarm(); return false
}
guard hooks.proxyPointsAtLocalhost(port) else {
    hooks.log("system proxy already clean; disarming"); hooks.disarm(); return false
}
```

1. **Missing snapshot ⇒ assumes clean.** `saveSnapshot` ignores write errors, `arm()` does not verify, and the file can be deleted by `revert.sh`/cleanup. The proxy can be dangling with no snapshot; the watchdog then disarms.
2. **Read failure ⇒ "clean".** `listServices()` returns `[]` on any `networksetup` read failure/timeout, so `proxyPointsAtLocalhost` returns false and the watchdog logs "already clean" and disarms permanently.
3. The snapshot is not cleared in either path (LC-08).

**Impact:** Permanent internet loss in exactly the crash-recovery scenario the watchdog exists for.

**Fix:** Make the proxy check tri-state (`.ours`, `.clean`, `.unknown`). Never disarm on `.unknown`; retry/back off. If the proxy points at a local port but no snapshot exists, do not simply disarm: clear the local proxy states under the same guard, or keep retrying and log loudly. Refuse to accept `saveSnapshot` failure at enable. Have `arm()` verify both writes. Keep a backup copy of the snapshot.

**Verification:** Watchdog harness with `snapshot = nil` + `proxyPointsAtLocalhost = true`; assert no disarm without a clean proxy. Fake a `listServices` failure with a dangling proxy; assert `.unknown` keeps it armed. Update the existing harness case that currently enshrines the disarm behavior.

---

### LC-06 — One stale/deleted service makes restore permanently impossible

**Location:** `Sources/System/SystemProxyManager.swift:189-211`; `Sources/Helper/HelperService.swift:57-63`; `Sources/System/HelperProtocol.swift:135-159`

**Confidence/evidence:** Confirmed with the real `networksetup`: `-setwebproxystate "Definitely Not A Service" off` exits 8 with "Unable to find item in network database".

**Mechanism:** `runDirect` (and the helper) return on the first failure. Snapshot dictionary iteration order is arbitrary, so which services get restored is nondeterministic. A deleted USB/dock service in the snapshot aborts everything after it. The app escalates to `osascript ... with administrator privileges` for this non-permission failure.

**Impact:** `disable()` stays `.degraded` forever; the watchdog retries forever but never restores; on quit the remaining services stay pointed at the dead listener. `revert.sh` is the only escape.

**Fix:** Intersect snapshot keys with `listServices()` before building commands and sort for determinism. Treat exit 8 / "Unable to find item" as "service gone", skip it, and continue. After a partial successful restore, rewrite the snapshot without gone services. Never escalate to admin on exit 8.

**Verification:** A temp snapshot with one bogus and one real service; assert the real one is restored, success is returned, and no admin prompt appears.

---

### LC-07 — Watchdog port mismatch turns a failed reapply into permanent internet loss

**Location:** `Sources/AppModel.swift:198-205`, `:482-510`, `:851-856`; `Sources/System/SystemProxyManager.swift:59-75`; `Sources/Support/Watchdog.swift:235-240`

**Confidence/evidence:** Confirmed.

**Mechanism:** Wake reapply arms the **configured** port before applying; port change arms the **new** port before apply. If the apply fails and the rollback apply also fails, the old listener is stopped, the system proxy may still be on the old port, and the watchdog is armed for the new port. `currentProxyPointsAtLocalhost(newPort)` returns false → "already clean" → disarm.

**Trigger:** Change the port while active to one that cannot be bound or applied; crash before a successful reapply. Same for any apply failure after arming.

**Impact:** The watchdog disarms and leaves the old-port proxy dangling with a dead listener: dead internet despite an armed snapshot.

**Fix:** When a snapshot exists, check for *any* local proxy port (`port == 0`) or track the set of applied ports. On reapply failure, re-arm the last-good applied port; arm the new port only after a successful apply. Persist a `lastGoodPort` alongside the armed state. Never disarm on "no match" without evidence of a clean state (LC-05).

**Verification:** Watchdog harness: armed port 9999, actual proxy 8888, snapshot present → assert restore or at least no disarm. App harness: force a port rebind/apply failure, crash, assert recovery.

---

### LC-08 — Snapshot lifecycle: never cleared, re-captured from a dangling proxy, failures ignored

**Location:** `Sources/Support/Watchdog.swift:241-247`, `:357-374`; `Sources/AppModel.swift:260-265`, `:775-829`; `Sources/Config/ConfigStore.swift:83-92`; `Sources/System/SystemProxyManager.swift:31-53`

**Confidence/evidence:** Confirmed, and the live machine exhibits the contaminated state. The snapshot contains `webServer=127.0.0.1`, `webPort=8888`, the app's exact bypass list, and `pacEnabled:true` with `pacURL:""` across services — i.e., the app's own applied state, not the user's original configuration.

**Mechanism:**

1. A successful watchdog restore calls `removeEnv()` and `disarm()` but **never clears the snapshot**. The stale "original" lingers.
2. If the snapshot file is missing, `enable()` captures whatever is currently set — including our own `127.0.0.1:<port>`.
3. `saveSnapshot`/`clearSnapshot` swallow errors; `enable()` proceeds even if the snapshot or armed state was not persisted.
4. `shutdownForQuit` reads only the disk snapshot. If missing, it calls `clearProxy` (turning off original proxy states without restoring servers). If stale and routing was never enabled this session, it restores the stale copy over the user's current settings.
5. `captureSnapshot` defaults failed reads to "off", so a transient read failure later disables that service's working proxy.

**Impact:** After a restore, a user who changes their proxy has it overwritten on the next enable/disable. A failed snapshot write makes the watchdog useless (LC-05). Quitting can wipe a working proxy. The live snapshot is already poisoned.

**Fix:**

- Add `clearSnapshot` to `WatchdogHooks` and call it after a successful restore and after "already clean".
- Make `saveSnapshot`/`clearSnapshot`/`arm`/`disarm` return success; `enable` must abort (or refuse to route) if persistence/verification fails. Keep a `.backup` copy.
- On launch, if a snapshot exists and `wasOnKey == false`, treat it as recovery state and restore it; do not ignore it.
- Before capture, reject/flag services already set to `127.0.0.1` on the app's port; never accept our own state as "original".
- `shutdownForQuit`: only restore if this session applied routing or the current proxy points at our port; otherwise remove/back up the stale snapshot without touching the user's proxy. Use the in-memory snapshot as a fallback.
- `captureSnapshot`: abort on any failed read instead of defaulting to "off".

**Verification:** Assert the snapshot file is deleted after a watchdog restore. Launch with a dangling proxy and a deleted snapshot. Force a `saveSnapshot` failure. Quit with a stale snapshot and routing off.

---

### LC-09 — Empty/failed service enumeration and empty restores are treated as success

**Location:** `Sources/System/SystemProxyManager.swift:20-27`, `:117-126`, `:168-211`, `:227-249`; `Sources/AppModel.swift:253`; `Sources/Helper/HelperService.swift:11-38`

**Confidence/evidence:** Confirmed.

- `listServices()` returns `[]` on any read failure/timeout.
- `enable()` has no empty check.
- `runDirect` over zero commands returns success; the helper rejects empty, but `runMutations` falls back to the empty direct run, defeating the guard.
- An empty snapshot is considered restorable.
- `runRead` reads the pipe only **after** the child exits; a full pipe deadlocks until the 20 s timeout, then yields `[]`.

**Impact:** The app reports ON while the system proxy was never touched; a `{}` snapshot is persisted; `clearProxy([])` on disable "succeeds" and stops the listener even if the proxy was applied. Empty watchdog restores also report success.

**Fix:** Make `listServices` return a `Result`/optional and abort on failure. Treat zero commands as an error for apply/clear/restore (except a deliberately empty bypass list). Verify at least one service was mutated. Never persist an empty snapshot. Drain stdout/stderr concurrently and use a monotonic deadline.

**Verification:** Inject a failing read; assert enable fails and stays off. Assert an empty command list throws.

---

### LC-10 — A crash between apply and `wasOnKey` is never recovered

**Location:** `Sources/AppModel.swift:126-130`, `:284`

**Confidence/evidence:** Confirmed. Auto-recovery is gated on `wasOnKey`, which is written only after apply + env injection. With `crashWatchdog` disabled (a supported setting) or a failed watchdog install, a crash after `applyProxy` leaves a dangling proxy and an on-disk snapshot that the next launch ignores.

**Impact:** Dead internet after a crash until `revert.sh`; the snapshot is present but unused.

**Fix:** Persist the intent (`wasOnKey = true` or a dedicated `routingApplied` marker) **before** applying. On launch, a snapshot file should trigger recovery regardless of `wasOnKey`.

**Verification:** SIGKILL between apply and line 284 with the watchdog disabled; launch and assert recovery.

---

### LC-11 — A non-loopback `bindHost` yields a dead system proxy while the UI says ON

**Location:** `Sources/System/HelperProtocol.swift:110-123`; `Sources/Proxy/ProxyServer.swift:74-104`; `Sources/UI/SettingsView.swift:643`; `Sources/System/ShellEnvInjector.swift:16-24`

**Confidence/evidence:** Confirmed. `NetworksetupCommands.applyProxy` always points the system proxy at `127.0.0.1`, while the listener binds only the configured host. `0.0.0.0` works because the wildcard includes loopback; a LAN IP does not.

**Impact:** System/browser HTTP(S) is refused; CLI tools using the injected LAN-host env work, masking the failure.

**Fix:** Bind loopback in addition for system-proxy use, or make `applyProxy` take the actual system-proxy host (loopback for loopback/wildcard, otherwise the bind host) and validate reachability. Default to loopback with an inline warning.

**Verification:** VM with a LAN bind; check `networksetup -getwebproxy` and curl through the system proxy.

---

### LC-12 — Quit can delegate to a watchdog that is not running, and can block on an admin prompt

**Location:** `Sources/AppModel.swift:775-830`; `Sources/System/SystemProxyManager.swift:254-286`; `Sources/Support/Watchdog.swift:79-107`

**Confidence/evidence:** Confirmed.

- `canDelegateToWatchdog = config.system.crashWatchdog` only. If the LaunchAgent was never installed (unwritable `~/Library/LaunchAgents`, bootstrap failure, translocated app), with `restoreOnQuit=false` the app skips the restore and exits; nothing restores.
- If the direct restore fails, the quit path can fall back to `osascript ... with administrator privileges`, blocking main for up to 180 s during quit/logout/update.
- A stale snapshot plus routing never enabled this session causes a restore over the user's current settings (LC-08).

**Impact:** Dead internet, hung quit/logout, or silently reverted proxy settings.

**Fix:** `canDelegateToWatchdog` must mean "agent installed and armed" (verify the plist/job/pid, or track a successful install+arm), not just the config flag. Use a no-prompt restore on the quit path and bound total quit work. Only restore if this session applied routing or the current proxy points at our port; otherwise discard/back up the stale snapshot.

**Verification:** Force install failure + `restoreOnQuit=false`; assert synchronous restore. Force a direct failure; assert no admin prompt on quit. Stale snapshot + routing off.

---

### LC-13 — Watchdog install/relaunch race can clobber a fresh apply and disarm it

**Location:** `Sources/Support/Watchdog.swift:97-107`, `:226-259`; `Sources/AppModel.swift:269-272`

**Confidence/evidence:** Confirmed. `installIfNeeded` unconditionally `bootout`s then `bootstrap`s. A restore/disarm is not conditional on the armed PID/port. During a Sparkle update or relaunch with `restoreOnQuit=false`, the old watchdog's in-flight restore can complete after the new app applies and then disarm the new state.

**Impact:** Routing silently turns off after an update/relaunch; the new instance has no crash protection; the UI says ON while the proxy is the old original.

**Fix:** Serialize watchdog operations; wait for `bootout`; make `performRestore` re-read `watchdog.json` and abort if `pid`/`port` changed; add `disarmIfStill(pid:port:)`; make helper commands check an epoch. Do not boot out a healthy agent unnecessarily. If install/arm fails, fail enable or warn prominently.

**Verification:** Watchdog harness with a slow restore + re-arm; assert the new armed state survives and the old restore does not run.

---

### LC-14 — Multiple instances share and overwrite recovery state

**Location:** no single-instance guard in `build.sh:79-118`; shared files in `ConfigStore`, `GuiEnvInjector`, `ShellEnvInjector`, `ssh.pid`, `watchdog.json`

**Confidence/evidence:** Confirmed. `Info.plist` has no `LSMultipleInstancesProhibited`. `open -n` or running `Contents/MacOS/ProxyManager` directly bypasses the normal duplicate suppression.

**Impact:** Two instances auto-enable; the second's quit can restore/clear the first's snapshot and disarm the shared watchdog; both overwrite config/rc/env/`watchdog.json`. Config/snapshot corruption and lost updates.

**Fix:** Acquire an exclusive `flock` on a support-dir lock file before any side effects; exit or activate the existing instance. Include an owner id/pid in the snapshot/armed state and never restore/disarm another owner's state.

**Verification:** Launch two instances; assert the second exits without touching proxy/config/watchdog.

---

### LC-15 — Shell env is only reconciled at enable/disable

**Location:** `Sources/AppModel.swift:280-283`, `:308-311`, `:367-370`, `:406-413`, `:807-810`; `Sources/System/ShellEnvInjector.swift:55-81`

**Confidence/evidence:** Confirmed.

- Turning `injectShellEnv` off while active does not remove the rc block/env file (disable checks the current config).
- Turning it on while active does nothing until re-enable.
- Changing the port/bind host while active rewrites the listener/system proxy but leaves `env.sh` on the old port.
- Changing `managedShellRcs` leaves blocks in the old files.
- A POSIX `export` block and `.` source line are appended to any configured file, breaking fish/csh.
- `String.write(toFile:atomically:)` replaces symlinks with regular files and resets permissions.

**Impact:** Stale/failed CLI proxy env; broken shell startup; unremovable app-managed blocks without `revert.sh`.

**Fix:** Reconcile shell env in `commitConfig` on `workQueue` using `appliedPort`/`appliedBindHost` and the previously applied rc list. Always remove marker blocks regardless of the current toggle. Detect the target shell and emit fish/csh syntax (or restrict/validate). Preserve symlinks and attributes (write through the resolved path).

**Verification:** Temp HOME harness; toggle injection/rc/port; assert files and blocks. Add symlink and fish-syntax tests.

---

### LC-16 — Restore does not faithfully restore bypass/PAC/auth

**Location:** `Sources/System/HelperProtocol.swift:135-159`; `Sources/System/SystemProxyManager.swift:31-53`

**Confidence/evidence:** Confirmed.

- Bypass domains are restored only when non-empty; an originally empty list leaves the app's `*.local,169.254/16,...` list in place.
- `-setautoproxystate` follows `pacEnabled` even when `pacURL` is empty/non-HTTP. The live snapshot has `pacEnabled:true` with an empty URL, so restore enables PAC with no URL.
- Auto-proxy discovery and the authenticated-proxy flag are never captured/restored.
- A failed read during capture leaves `webEnabled=false`/empty server, so restore turns that service's proxy off.

**Impact:** The user's proxy configuration is not restored faithfully; PAC users can lose connectivity; corporate authenticated proxies need reconfiguration.

**Fix:** Always restore bypass (including clearing it with the documented empty-list form). Enable PAC only when a valid URL was captured. Capture/restore auto-discovery and the auth flag. Abort capture on any read failure rather than defaulting to off.

**Verification:** Snapshot fixtures with empty bypass, PAC-on-empty-URL, authenticated proxy, and a failed read; assert the intended restores/aborts.

---

### LC-17 — Process handling: unbounded waits, polling, main-thread work, orphaned children

**Location:** `Sources/System/GuiEnvInjector.swift:149-166`; `Sources/Support/Watchdog.swift:171-185`, `:396-398`, `:851-862`; `Sources/System/SystemProxyManager.swift:239-286`; `Sources/Helper/HelperService.swift:89-99`

**Confidence/evidence:** Confirmed.

- `GuiEnvInjector` does `readDataToEndOfFile()` + `waitUntilExit()` with no timeout; called ~12x per enable/disable and on quit/watchdog restore.
- `launchctl` in the watchdog uses `waitUntilExit()` with pipes never drained and no timeout, called on **main** from `commitConfig`/`setCrashWatchdog`.
- `networksetup` waits poll every 20–50 ms; the admin wait polls 20x/s for up to 180 s.
- On admin timeout, only `osascript` is killed; its `sh`/`networksetup` children can continue mutating after rollback.

**Impact:** A hung launchd/networksetup freezes the UI, quit, or the watchdog; a timed-out admin apply can still complete in the background.

**Fix:** One bounded process helper using `terminationHandler` + a timed semaphore, draining stdout/stderr concurrently (or `/dev/null` where unused). Move `launchctl` off main. Run admin shell in its own process group and `kill(-pgid)` on timeout. Use monotonic deadlines.

**Verification:** Fake slow executables; assert bounded return and no main-thread stall. Timed-out admin test asserts children are gone.

---

### LC-18 — Watchdog retry storm, stale env config, orphaned SSH, unbounded log

**Location:** `Sources/Support/Watchdog.swift:226-258`, `:312-316`, `:354-374`; `Sources/Tunnel/SSHTunnelRunner.swift:45-67`, `:100-160`

**Confidence/evidence:** Confirmed.

- A persistent restore failure (LC-06) retries every 15 s forever; each attempt runs `listServices()` + `2N` reads + a full restore. Both stdout and stderr go to `~/Library/Logs/ProxyManager-watchdog.log` with no rotation.
- `Watchdog.defaultHooks` captures `ConfigStore.shared` at watchdog start; `removeEnv` later consults a stale `injectShellEnv`/`managedShellRcs`. If the user changed the setting, the block is not removed.
- A crash/force-quit leaves the managed `ssh -N -D` running; the watchdog and `revert.sh` do not stop it.
- The askpass temp dir/secret is not cleaned on crash.

**Impact:** CPU/battery drain and log growth in failure states; stale proxy env; orphan SSH sessions; a password file left in tmp.

**Fix:** Exponential backoff (15 s → 1 m → 5 m) with a "requires attention" state and log rotation. Always remove marker blocks/env file unconditionally. Reap `ssh.pid` after verifying the process is ssh, and clean askpass dirs on launch/watchdog restore.

**Verification:** Hook-count harness over time; crash + relaunch env/ssh test; log rotation check.

---

### LC-19 — Keystroke re-apply storm and validation gaps

**Location:** `Sources/AppModel.swift:400-415`, `:474-513`, `:748-766`; `Sources/Config/ConfigModels.swift:113-128`; `Sources/UI/SettingsView.swift:643`

**Confidence/evidence:** Confirmed. The side effects are canonical in `TC-05`/`UI-03`; here the validation gaps:

- `portBinding` uses `UInt16(clamping:)`, so `-1` becomes 0 and the UI accepts port 0.
- Invalid bind hosts are only discovered after the listener is stopped.
- Each keystroke in Bind host/Port while active queues a full reapply (`listServices` + 6N `networksetup` commands), causing brief outages and possibly an admin prompt per keystroke.

**Impact:** Outages and admin prompts while typing; an ephemeral/invalid port; confusing failures.

**Fix:** Debounce the reapply (0.5 s) separately from the config save; validate port `1...65535` and bind host with inline errors; apply on commit/focus loss. See `TC-05` for the SSH/commit fix.

**Verification:** Count `networksetup` spawns while typing; try 0/-1/invalid host.

---

### LC-20 — Cross-thread data races on `config`/`state`; concurrent `syncManagedTunnel`

**Location:** `Sources/AppModel.swift:185-193`, `:445-469`

**Confidence/evidence:** Confirmed. `config` is read on the NWPathMonitor queue and `workQueue` while main mutates it; `state` is read on `workQueue`. `syncManagedTunnel` can be entered from main (`commitConfig`) and from `workQueue` (`enable`), and it deletes Keychain items / stops SSH outside the lock.

**Impact:** Swift struct/string COW races (rare crashes/undefined behavior); lost SSH mode/auth changes; a password deleted for a tunnel just configured; a reapply guard acting on a stale state.

**Fix:** Capture `config` and `state` once on main into the work item and pass them down (as `enable`/`disable` already do for `cfg`). Serialize `syncManagedTunnel` on one queue and act on a local snapshot inside the lock. Consider confining `config` to main.

**Verification:** TSan on a harness or a stress test toggling network changes while editing.

---

### LC-21 — `degraded` conflates "tunnel down" with "recovery failed"

**Location:** `Sources/AppModel.swift:866-875`

**Confidence/evidence:** Confirmed. A failed enable rollback or disable restore sets `.degraded`. If the tunnel probe later recovers, `recomputeStateAfterTunnelChange(up: true)` flips `.degraded → .on`, hiding the failed restore.

**Impact:** UI shows ON while the system proxy is inconsistent or unrestored.

**Fix:** Add a separate `recoveryFailed` flag/state; only perform tunnel-driven transitions when the proxy state is consistent.

**Verification:** Harness simulating a failed restore + tunnel flap; assert it does not become `.on`.

---

### LC-22 — Tolerant-decode gaps in watchdog state and numeric config

**Location:** `Sources/Support/Watchdog.swift:9-16`, `:52-58`; `Sources/Config/ConfigModels.swift:113-128`, `:330-331`

**Confidence/evidence:** Confirmed. `WatchdogArmedState` uses synthesized `Codable`, so a future/older field makes `readArmedState()` return `.disarmed` — silent loss of crash protection. Config fields use `decodeIfPresent`, which still throws for a present-but-out-of-range value (`port: 70000`, negative ints), wiping the whole config.

**Fix:** Custom tolerant `init(from:)` with defaults for `WatchdogArmedState`. Decode numeric fields as `Int`/`String` and clamp/validate, or use `try?` per field. Canonical config-decode fix in `TC-01`.

**Verification:** Decode fixtures with extra fields, old formats, port 70000/-1.

---

### LC-23 — Helper silently drops service names outside its charset

**Location:** `Sources/System/HelperProtocol.swift:182-186`; `Sources/Helper/HelperService.swift:11`, `:21`, `:39`

**Confidence/evidence:** Confirmed. `isValidService` allows alphanumerics plus ` .-_()/`. Names containing `&`, `+`, `'`, `#`, `@`, `,`, `:` are filtered out, and the helper still replies success. The app does not compare counts.

**Impact:** Those services silently bypass the proxy (or are left dangling if applied via the direct path and restored via the helper).

**Fix:** Validate on the app side and surface dropped services; relax the charset (argv is safe; reject only control characters/newlines); verify `valid.count == services.count`.

**Verification:** Service names with `&`, `'`, `+`; assert coverage or an explicit report.

---

### LC-24 — `revert.sh` does not remove everything and can make things worse

**Location:** `revert.sh:12-62`

**Confidence/evidence:** Confirmed. Paths, bundle id, snapshot names, LaunchAgent, rc files and env file match. Gaps:

- It does not restore the user's original proxy/GUI env/PAC; it unsets/deletes them. A corporate PAC/proxy user may be left with no internet.
- PAC is never re-enabled from the snapshot.
- It does not kill the managed SSH tunnel (`ssh.pid`) or unregister the helper daemon.
- `tail -n +2` keeps `*`-prefixed disabled services; `networksetup -setwebproxystate "*Thunderbolt Bridge" off` fails, leaving stale proxy settings if re-enabled.
- It deletes `system-proxy-snapshot.json` even if the clearing loop failed.
- `pkill` (SIGTERM) does not kill already-spawned `networksetup`/`osascript` children; they can finish after the clear with the snapshot deleted.
- Arbitrary user-configured rc files are not cleaned.
- `sed -i ''` replaces symlinks.

**Impact:** The emergency lifeline can fail to restore connectivity, lose recovery data, or leave orphans.

**Fix:** Restore saved originals (or explicitly document "reset to direct"), re-enable PAC from the snapshot before deleting it, strip `*` when enumerating, verify each clear and only delete the snapshot on success, reap `ssh.pid` after verifying `comm`, and optionally unregister the helper. Kill the process group before clearing.

**Verification:** VM with a pre-existing GUI proxy + PAC, an app-applied state, and a managed SSH tunnel; run revert and assert original connectivity/env, all services clear, no ssh remains.

---

### Lower-severity lifecycle findings

| ID | Location | Issue | Fix |
|---|---|---|---|
| LC-L1 | `Watchdog.swift:28` | `urls(...).first!` can trap in an unusual sandbox/daemon context | Guard and fall back to `NSHomeDirectory()`. |
| LC-L2 | `AppModel.swift:417-426` | Debounced config save not flushed on quit; last ≤0.5 s of settings lost | Cancel the work item and save synchronously at the start of `shutdownForQuit`. |
| LC-L3 | `AppModel.swift:782-787` | Early quit return skips GUI/shell env removal | Remove env when no snapshot/listener too. |
| LC-L4 | `AppModel.swift:564-567` | `restartApp` interpolates the bundle path into a shell command; `while kill -0` can wait forever on PID reuse | Use `Process` + `open`, not a shell string. |
| LC-L5 | `App.swift:123-131` | ⌘Q detection requires the modifier mask to equal `.command`; Caps Lock/numpad/function keys make it a "deliberate quit" | Check `contains(.command)` and only reject explicit extra modifiers. |
| LC-L6 | `ShellEnvInjector.swift:68-81` | `remove` rewrites the file even when no block was found | Return early if no marker. |
| LC-L7 | `SystemProxyManager.swift:239-279`; `HelperService.swift:89-99`; `SSHTunnelRunner.swift:330` | Wall-clock deadlines and polling; `ps` wait without timeout | Monotonic deadlines, `terminationHandler`. |
| LC-L8 | `Watchdog.swift:110-118` | `uninstall()` returns early if only `watchdog.json` exists; stale armed marker remains | Always remove/disarm the marker. |
| LC-L9 | `Watchdog.swift:274-287` | Dir vnode watch not re-added after delete/rename; no 15 s tick while disarmed | Re-add the watch; keep a safety tick. |
| LC-L10 | `ProxyServer.swift:121-134` | `stop()` closes only the listener; established connections continue after "disable" | Acceptable; document or drain them. |
| LC-L11 | `HelperService.swift:56-63` | Stops at first failure and blocks its listener queue for N×20 s | Continue on per-service failure; use a worker queue. |
| LC-L12 | `Log.swift:1-16`; watchdog plist | Unbounded watchdog log file | Rotation/size cap. |
| LC-L13 | `AppModel.swift:885-887` | `lastError` never cleared on a later success | Clear on success. |
| LC-L14 | `SSHTunnelRunner.swift:236-260` | Askpass secret temp dir not cleaned on crash | Startup sweep; `trap` in the helper. |
| LC-L15 | `SSHKeychain.swift:19-40` | Keychain save/update errors swallowed | Return/surface `OSStatus`. |

---

## 4. Managed SSH, config, routing and per-app resolution

### Summary

| ID | Sev | Confidence | Finding |
|---|---|---|---|
| TC-01 | High | Confirmed + probe | Tolerant decode still fails the whole config on unknown enums, malformed UUIDs, wrong types and out-of-range numbers |
| TC-02 | High | Confirmed | An unreadable config is treated as "absent" and overwritten with defaults |
| TC-03 | High | Confirmed | An unreadable/corrupt snapshot disarms the watchdog and can be re-captured as "original" |
| TC-04 | High | Confirmed | A failed SSH respawn leaves `runningValue == true` with no process and no retry |
| TC-05 | High | Confirmed | Every managed-settings keystroke restarts SSH; fatal errors are bypassed by any unrelated config commit |
| TC-06 | Medium-High | Confirmed | Managed SSH runs whenever `mode == .managed`, even when routing is off, including at launch |
| TC-06A | Medium-High | Confirmed | `stopLocked()` deletes the pid file without reaping the orphan |
| TC-07 | High (when enabled) | Confirmed | A full libproc scan runs per connection with no semaphore/port cache and ~80 KB of allocations |
| TC-08 | Medium-High | Confirmed | Askpass secret survives a crash if ssh never prompts; stale temp dirs are never swept |
| TC-09 | Medium | Confirmed | `errData` is unbounded |
| TC-10 | Medium | Confirmed | `identityCache` grows without bound |
| TC-11 | Medium | Confirmed | Fatal classification races the stderr drain (50 ms sleep heuristic) |
| TC-12 | Medium | Confirmed | Wildcard matching allocates `"." + base` per rule per request; no dedupe |
| TC-13 | Medium | Confirmed | Probe DNS resolution can leak an uncancellable thread (see `PS-06`) |
| TC-14 | Medium-low | Confirmed | PID reuse can kill an unrelated `ssh` process |
| TC-15 | Medium | Confirmed | `config` read on `workQueue` while main mutates it; concurrent `syncManagedTunnel` (see `LC-20`) |
| TC-16 | Medium-low | Confirmed | Invalid managed settings leave the old SSH process running while `currentSettings` claims the new config |
| TC-18 | Low-Medium | Confirmed | Debounced config save not flushed on quit |
| TC-19 | Low-Medium | Confirmed | Keychain/askpass failures are swallowed |
| TC-20 | Low-Medium | Confirmed | User `ProxyCommand` children are not killed; no `-F /dev/null` |
| TC-21 | Low-Medium | Confirmed | `launchctl` restart has no timeout |
| TC-22 | Low-Medium | Confirmed | `/bin/ps` reaper has no timeout and can wedge the SSH queue/quit |
| TC-23 | Low | Confirmed | Force-unwrapped Application Support URL |
| TC-24 | Low | Confirmed | `proc_pidpath` result handling ignores the returned length |
| TC-25 | Low | Confirmed | Socket-to-PID match ignores connection state and addresses |
| TC-26 | Low | Confirmed | Bundle cache evicts all entries at once and stampedes |
| TC-27 | Low | Confirmed | Supervisor timer is not invalidated on deinit; `stop()` leaves stale state |
| TC-28 | Low-Medium | Confirmed | Config JSON encode+write and routing rebuild on main; port validation gaps |

### TC-01 — Tolerant decoding is incomplete; one bad value wipes the whole config

**Location:** `Sources/Config/ConfigModels.swift:26`, `:88`, `:124`, `:157-162`, `:188`, `:301-302`, `:330-331`

**Confidence/evidence:** Confirmed with a decode matrix compiled against `ConfigModels.swift`. All of these failed whole-config decode:

```
unknown tunnel mode          unknown appearance mode      unknown managed auth
port 70000                   port -1                      malformed target UUID
wrong-typed target pattern
```

**Mechanism:** `decodeIfPresent` only avoids `keyNotFound`. It still throws on an unknown `RawRepresentable` raw value, a wrong JSON type, an out-of-range integer, or a malformed UUID. The throw propagates out of `AppConfig.init(from:)`; `ConfigStore` treats the whole file as corrupt, backs it up, and saves defaults over it. `targets` defaults to `[]`, so every request then goes direct — a privacy regression, not just lost settings.

**Trigger:** A future build writes `mode: "SMART"` and the user downgrades; a hand-edited port `70000`; a migration writes a bad UUID; a wrong-typed target entry.

**Impact:** Total loss of the allow-list and settings; traffic previously tunneled goes direct.

**Fix:** Route every scalar/enum/UUID through a non-throwing helper and clamp numerics.

```swift
private static func tolerant<T: Decodable>(
    _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, _ fallback: T
) -> T { (try? c.decode(T.self, forKey: key)) ?? fallback }

port = UInt16(clamping: tolerant(c, .port, 8888))
mode = tolerant(c, .mode, .manual)      // do NOT use decodeIfPresent for enums
id   = tolerant(c, .id, UUID())
```

Decode arrays element-by-element with a failable wrapper, skipping malformed entries. For unknown app-rule kinds/modes, keep the rule disabled rather than silently defaulting to a potentially wrong meaning.

**Verification:** Extend `Tests/RegressionHarness` with all seven cases and assert `targets` survives. Add a `ConfigDecodeHarness` with extra keys, `null`s and wrong types.

---

### TC-02 — A read error is treated as "no config" and overwritten

**Location:** `Sources/Config/ConfigStore.swift:33-40`, `:51-63`

**Confidence/evidence:** Confirmed.

**Mechanism:** `guard let data = try? Data(contentsOf: url) else { return nil }` collapses "missing" and "unreadable" into `nil`. The initializer then writes defaults over the existing file.

**Trigger:** A transient I/O error, changed permissions after a restore/migration, a sandbox denial, a file-provider/network-home hiccup, or a brief lock, while `config.json` exists.

**Impact:** The user's config is destroyed even though the file was intact on disk.

**Fix:** Distinguish absent/present-unreadable/decodable/corrupt. Absent → defaults + create. Present-unreadable → log/surface, keep the file, do not save; start with in-memory defaults until the user explicitly edits. Present-malformed → timestamped `.corrupt` backup (never overwrite prior backups). Make the URL injectable for tests.

**Verification:** Temp-directory harness with `chmod 000` or a failing `FileManager` shim; assert the original bytes remain.

---

### TC-03 — An unreadable snapshot can leave the system proxy dangling

**Location:** `Sources/Config/ConfigStore.swift:89-92`; `Sources/Support/Watchdog.swift:230-236`; `Sources/AppModel.swift:260-265`

**Confidence/evidence:** Confirmed. `loadSnapshot` returns `nil` for read failure and decode failure alike. The watchdog treats `nil` as "nothing to restore" and disarms; `enable()` then captures the dangling state as the new "original".

**Trigger:** `system-proxy-snapshot.json` present but unreadable or undecodable (permissions, I/O, hand edit, unexpected type, corruption), followed by a crash.

**Impact:** Permanent internet loss; the bad state is captured as the user's original, so even a later restore preserves the loopback proxy.

**Fix:** Return `.absent`/`.unreadable`/`.decoded`. Only `.absent` may conclude "nothing to restore"; `.unreadable` keeps the armed state and retries. `enable()` must never capture a snapshot when the current proxy already points at this app's listener; detect and restore/clear first. Add a `.corrupt` backup for the snapshot.

**Verification:** Watchdog harness with an armed state, a `loadSnapshot` hook returning a read error, and `proxyPointsAtLocalhost == true`; assert it stays armed and retries.

---

### TC-04 — A failed SSH respawn leaves the runner "running" with no process and no retry

**Location:** `Sources/Tunnel/SSHTunnelRunner.swift:94-99`, `:135-145`, `:338-345`

**Confidence/evidence:** Confirmed. `spawn()` increments the generation, terminates the old process, sets `process = nil`, then tries `p.run()`. If `run()` throws (missing binary, `fork`/`posix_spawn` failure, resource exhaustion), the catch only sets an error and cleans temp files. `runningValue` stays `true` from the previous child.

**Impact:** `isRunning`/UI lie; `apply()`'s `runningValue && currentSettings == settings` guard suppresses retries; no termination callback means no backoff. The tunnel stays down until the user changes settings or presses Restart.

**Fix:** Call `setRunning(false)` **before** attempting the replacement, and in the catch. Schedule the same backoff used by `handleExit` for spawn failures. Validate settings before mutating `currentSettings` (TC-16).

**Verification:** Make `sshPath` injectable and point it at a binary that fails `posix_spawn`; assert `isRunning == false`, an error is published, and a retry is scheduled.

---

### TC-05 — Every managed-settings keystroke restarts SSH; fatal errors are bypassed by any config edit

**Location:** `Sources/UI/SettingsView.swift:542-594`; `Sources/AppModel.swift:389-468`, `:748-755`; `Sources/Tunnel/SSHTunnelRunner.swift:47-53`

**Confidence/evidence:** Confirmed. `binding`/`portBinding` call `commitConfig()` on every setter; `commitConfig` calls `syncManagedTunnel`; `apply` only skips when **running** and settings are equal.

**Mechanism:** Typing a hostname changes `ManagedTunnelSettings` one character at a time, so `apply` terminates and respawns `ssh` per character. After a fatal failure (Permission denied/host key), `runningValue` is false, so **any** unrelated config commit (appearance, target edit) spawns ssh again — defeating the fatal/no-retry design.

**Impact:** One SSH handshake/auth attempt per character; dropped connections; server rate limiting/lockout; CPU/network churn; repeated auth prompts. The same applies to the proxy port (listener stop/start + system-proxy reapply per digit).

**Fix:** Separate draft editing from apply. Bind Settings fields to local `@State` and commit on `.onSubmit`, focus loss, or an explicit Apply. Or debounce the **side effects** (400–600 ms) and only call `sshTunnel.apply` when the normalized settings actually change. Make idempotence independent of running state (`currentSettings == settings && lastSpawnWasNotFatal`), add a fatal cooldown (`lastFatalAt`/`nextAutoRetryAt`), require an explicit Restart/change to leave a fatal state, and add a generation token so older applies cannot overwrite newer intent.

**Verification:** Instrument spawn count; type a 20-character host and expect at most one spawn after debounce. Use a fake ssh that fails with "Permission denied"; toggle an unrelated setting and assert no new spawn.

---

### TC-06 — Managed SSH runs while routing is off

**Location:** `Sources/AppModel.swift:121-124`, `:347-385`, `:445-468`

**Confidence/evidence:** Confirmed behavior; intent is unclear. The child's lifecycle is tied only to `config.tunnel.mode`, not `state.isActive`. `disable()` never stops ssh. The initial `syncManagedTunnel()` runs in `init` before the `wasOnKey` decision.

**Impact:** Launch with managed mode and routing off still opens an SSH session and performs auth. Toggling routing off keeps the remote session and local SOCKS port. This may be intentional "keep warm", but it is undocumented and surprises users.

**Fix:** Either stop SSH in `disable()` and only apply when `state.isActive`, or add an explicit "Keep tunnel connected while routing is off" setting and document it. At minimum, defer the initial sync until after the `wasOnKey` decision.

**Verification:** Launch with managed mode + `routingWasOn == false`; assert no ssh child (or that the documented option is on). Toggle off and assert exit.

---

### TC-06A — Orphaned ssh survives relaunch and its pid file is deleted

**Location:** `Sources/Tunnel/SSHTunnelRunner.swift:76-84`, `:86-99`, `:310-320`

**Confidence/evidence:** Confirmed. `stopLocked()` terminates only the in-memory `process` (nil after a crash), then deletes `ssh.pid`; it never calls `killStaleProcess()`. `killStaleProcess()` only runs from `spawn()`, which returns at the validation guard first if host/username is empty.

**Trigger:** Crash while managed ssh runs; relaunch in MANUAL (or invalid managed config); `stopLocked()` deletes the pid file but leaves ssh alive holding the SOCKS port. Switching back later cannot reap it; ssh fails with "Address already in use", classified fatal, so the tunnel never recovers.

**Impact:** A leaked SSH session and a permanently broken managed tunnel until manual cleanup.

**Fix:** Call `killStaleProcess()` at the start of `stopLocked()` before `removePidFile()`; verify the kill succeeded. Run a reaper unconditionally at startup, independent of mode/validation. Do not delete the pid file on validation failure (see TC-14 for start-time verification).

**Verification:** Spawn a fake long-lived ssh, write its pid, restart in MANUAL; assert the child is gone and the port is free.

---

### TC-07 — A full libproc scan runs per connection

**Location:** `Sources/Routing/AppResolver.swift:70-75`, `:210-247`

**Confidence/evidence:** Confirmed. `resolve` always calls `pidForLoopbackConnection`, which allocates a 16 KB pid buffer and a 64 KB fd buffer, lists all PIDs, lists all fds per process, and inspects every socket fd before consulting the identity cache. The planned `(port, remotePort) → pid` LRU and scan semaphore were never implemented.

**Impact:** With per-app routing/telemetry enabled, every connection does a full system scan. The project's own estimate is ~0.3–3 ms per scan; at 13.7 k new connections/s that is roughly 4–41 CPU-seconds per wall second, and all 256 proxy threads can scan concurrently. This is a CPU cliff and `proc_pidinfo` contention.

**Fix:** Add a 4–8 permit semaphore around the scan; add the `(localPort, proxyPort) → (pid, startTime, expiresAt)` cache with a short TTL; reuse the pid/fd buffers per thread or via a bounded pool; coalesce concurrent misses for the same port pair. Keep the feature off by default.

**Verification:** Run the documented 200-way concurrent per-app test with `sample`/Instruments; measure CPU and latency with 0/1/1000 rules. Add a benchmark to `Tests/AppIdentityHarness`.

---

### TC-08 — Askpass secret survives a crash; stale temp dirs are never swept

**Location:** `Sources/Tunnel/SSHTunnelRunner.swift:258-286`; docs `tunnel-supervisor.md:23`, `:35`

**Confidence/evidence:** Confirmed. The password is written to `<temp>/proxymanager-ssh-<UUID>/secret` (0600, dir 0700). The helper deletes it only when invoked. `cleanupTemp()` runs on the next spawn/exit/stop, but not on SIGKILL/crash, and there is no startup sweep.

**Impact:** Plaintext password persists in a predictable per-user temp location after a crash, especially when ssh exits before prompting (DNS/connect/host-key/bind/ProxyCommand failure). Multiple crashes leave multiple dirs.

**Fix:** Sweep `proxymanager-ssh-*` dirs at startup and before each spawn (only older than a few minutes to avoid racing a live sibling). Have the helper install `trap 'rm -f "$secret"' EXIT INT TERM`. Treat a failed write/chmod as a spawn failure. Longer term, read the credential from the Keychain inside the helper or pass it over an inherited pipe/fd so it never exists on disk.

**Verification:** Run password auth against an unreachable host so ssh never prompts; SIGKILL the app; assert no `secret` remains after the new sweep.

---

### TC-09 — Unbounded stderr buffer

**Location:** `Sources/Tunnel/SSHTunnelRunner.swift:116-133`, `:200-206`

**Confidence/evidence:** Confirmed. `errData` grows for the life of the child; `shortMessage()` splits the whole blob into lines at exit, doubling peak memory.

**Trigger:** A hostile/verbose SSH server, a broken `ProxyCommand`, or a pathological rekey/auth loop.

**Impact:** Unbounded memory growth and a large allocation spike at exit.

**Fix:** Keep a bounded tail (e.g. 64 KiB ring); classify on that tail (fatal markers are near the end); parse line-by-line.

**Verification:** Fake ssh writes 100 MB to stderr and exits; assert RSS stays bounded and fatal classification still works.

---

### TC-10 — `identityCache` grows without bound

**Location:** `Sources/Routing/AppResolver.swift:42-45`, `:83-105`

**Confidence/evidence:** Confirmed. Entries are removed only when the same PID is looked up again and fails start-time validation, or when `clearCache()` is called; `clearCache()` is never called in production.

**Impact:** Over days/weeks of PID churn, tens of thousands of entries (each with an `AppIdentity` of three Strings) — tens of MB and stale display names.

**Fix:** Prune expired entries opportunistically on insert; cap at e.g. 4,096 with LRU/TTL; remove on start-time mismatch. Add a cache-count diagnostic to the harness.

**Verification:** A loop creating/exiting short-lived client processes; assert the cache stays bounded and dead PIDs disappear.

---

### TC-11 — Fatal classification races the stderr drain

**Location:** `Sources/Tunnel/SSHTunnelRunner.swift:127-133`, `:148-198`

**Confidence/evidence:** Confirmed. `terminationHandler` sleeps 50 ms then snapshots `errData`; the `readabilityHandler` is asynchronous with no EOF handshake.

**Impact:** On a slow/loaded system the fatal line may not be present yet, so a permanent "Permission denied"/"Host key verification failed" is retried forever at 60 s intervals.

**Fix:** After exit, drain the read handle to EOF synchronously (bounded, with a fallback for grandchildren holding the pipe) before classifying. Do not use sleep as synchronization.

**Verification:** Fake ssh writes a fatal line and exits immediately under CPU load; assert no retry is scheduled.

---

### TC-12 — Wildcard matching allocates per rule per request

**Location:** `Sources/Routing/RoutingEngine.swift:142-150`, `:242-253`, `:266-279`; docs claim "allocates nothing" at `routing.md:43`

**Confidence/evidence:** Confirmed. For every request, every wildcard rule evaluates `normalized.hasSuffix("." + w.base)`, creating a new String each time. `update` does not dedupe wildcard patterns.

**Impact:** O(N) string allocations and suffix checks per request with N wildcard rules; duplicate rules multiply the cost. The docs' zero-allocation claim is false.

**Fix:** Precompute `(base, suffix: "." + base, rule)` in `update`, dedupe by base (first wins), and use the stored suffix. Better: a reversed-label trie or a `Set<String>` of suffixes for O(labels) lookup. Keep an immutable compiled-rules snapshot behind one atomic reference read.

**Verification:** Benchmark 1k/10k wildcard rules; compare allocations/throughput. Existing matching tests cover semantics.

**Verified-safe matching semantics:** `*.example.com` matches the apex and any depth without overmatching `evil-example.com` or `example.com.evil.com`; leading-dot patterns are equivalent; case/trailing-dot/port/bracketed-IPv6 normalization is correct; empty/`.`/`*.`/`*`/`**` do not create an allow-all; exact rules take precedence.

---

### TC-13 — Probe DNS resolution can leak uncancellable threads

See `PS-06`. The supervisor calls `Socket.resolve` every 10 s, making it a reliable way to accumulate blocked resolver threads when the system resolver hangs.

---

### TC-14 — PID reuse can kill an unrelated process

**Location:** `Sources/Tunnel/SSHTunnelRunner.swift:310-334`

**Confidence/evidence:** Confirmed logic; low frequency. `ssh.pid` contains only a PID; after a crash, `killStaleProcess` verifies `kill(pid,0) == 0` and that `ps -o comm=` is `ssh` or ends in `/ssh`. A recycled PID used by the user's own ssh session passes both checks.

**Impact:** The app SIGKILLs an unrelated SSH session.

**Fix:** Persist `pid`, `start_sec`, `start_usec` (from `proc_pidinfo(PROC_PIDTBSDINFO)`) and verify the start time before killing. Optionally verify argv contains `-D <host>:<port>` and owns the listening port. If the file lacks a start time, do not kill; remove it and let the port-conflict error surface.

**Verification:** Write a pid file for a separately started ssh with a mismatched start time; assert no kill.

---

### TC-15 — Cross-thread config/state access and concurrent tunnel sync

See `LC-20`; the fix is the same.

---

### TC-16 — Invalid managed settings leave the old SSH process running

**Location:** `Sources/Tunnel/SSHTunnelRunner.swift:47-53`, `:86-92`

**Confidence/evidence:** Confirmed. `apply` sets `currentSettings = settings` before `spawn`; `spawn` returns at the validation guard without stopping the previous child. The old process keeps running while `currentSettings` claims the invalid new config; a later valid apply may not match and can spawn a second child.

**Impact:** A zombie/duplicate tunnel and a confused UI; port conflicts.

**Fix:** Validate before mutating `currentSettings`; if invalid, stop the old child or keep the last-good settings and surface the validation error. Add a generation/settings-token so stale applies cannot win.

**Verification:** While running, set host to empty; assert the old child is stopped and the error is shown, or that the last-good config remains.

---

### TC-18 — Debounced config save not flushed on quit

**Location:** `Sources/AppModel.swift:417-425`, `:775-830`

**Confidence/evidence:** Confirmed. `commitConfig` schedules the store write 0.5 s later on main; `shutdownForQuit` does `workQueue.sync` while main is blocked, so the pending main-queue item cannot run. An edit followed by a quit within 500 ms is lost.

**Fix:** At the start of `shutdownForQuit`, cancel the pending work item and save synchronously (`configStore.config = config` or `save`), and log failures.

**Verification:** Edit a target and immediately quit; inspect `config.json`.

---

### TC-19 — Keychain and askpass failures are swallowed

**Location:** `Sources/Tunnel/SSHKeychain.swift:23-28`; `Sources/Tunnel/SSHTunnelRunner.swift:261-274`

**Confidence/evidence:** Confirmed. `SecItemUpdate` is ignored unless `errSecItemNotFound`; `SecItemAdd`'s status is ignored. `try?` on the secret/helper write and chmod can leave ssh with a missing/unreadable helper. `load()` cannot distinguish "no item" from "locked/denied".

**Impact:** The UI says the password is stored when it is not; auth failures are reported generically; a spawn can proceed with an unusable askpass helper.

**Fix:** Make `save`/`delete` return `OSStatus`/throw and surface it in Settings. Throw and abort spawn if the secret/helper cannot be written or secured. Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Distinguish "no item" from access errors in `load()`.

**Verification:** Lock/deny the Keychain; assert a visible error. Make the temp dir read-only; assert the spawn fails before launching ssh.

---

### TC-20 — User ssh config can spawn children the runner never kills

**Location:** `Sources/Tunnel/SSHTunnelRunner.swift:210-244`, `:290-296`

**Confidence/evidence:** Confirmed. Multiplexing is disabled, but `-F /dev/null` is not passed, so `ProxyCommand`/`ProxyJump`/`LocalCommand` from `~/.ssh/config` still apply. A child can inherit the stderr pipe, outlive the app, and prevent EOF.

**Impact:** Orphan processes; `readabilityHandler`/FileHandle retention; stderr growth (TC-09).

**Fix:** Add `-F /dev/null` and pass needed options explicitly (known-hosts files, etc.). If user config is intentional, kill the process tree (`proc_listchildpids`) or run ssh in a new process group and signal the group.

**Verification:** Add `ProxyCommand sleep 1000` to a test config; start/stop; assert no child remains.

---

### TC-21 — `launchctl` restart has no timeout

**Location:** `Sources/Tunnel/TunnelSupervisor.swift:78-95`

**Confidence/evidence:** Confirmed. Null pipes avoid the old deadlock, but `waitUntilExit()` is unbounded. A hung `launchctl` wedges the background thread; repeated clicks leak threads and no re-probe runs.

**Fix:** `terminationHandler` + 10 s semaphore; on timeout `terminate()` then SIGKILL, log, re-probe.

**Verification:** Fake slow `launchctl`; assert bounded return.

---

### TC-22 — `/bin/ps` reaper can wedge the SSH queue and quit

**Location:** `Sources/Tunnel/SSHTunnelRunner.swift:322-334`; `Sources/AppModel.swift:828`

**Confidence/evidence:** Confirmed. `waitUntilExit()` runs before reading the pipe and has no timeout. A hung `ps` blocks the serial SSH queue; `stopNow()` uses `queue.sync` from the quit path inside `workQueue.sync`, hanging main.

**Fix:** Read the pipe concurrently, add a bounded wait and terminate/SIGKILL fallback, avoid `queue.sync` on the quit path or give it a deadline. Prefer `proc_pidpath`/`proc_pidinfo` over spawning `ps`.

**Verification:** Inject a fake `ps` that sleeps; assert the stop path completes.

---

### TC-23 — Force-unwrapped Application Support URL

**Location:** `Sources/Config/ConfigStore.swift:16`; `Sources/Tunnel/SSHTunnelRunner.swift:39`

**Confidence/evidence:** Confirmed. `urls(for:.applicationSupportDirectory, in:.userDomainMask).first!` traps if the array is empty (unusual sandbox/container/daemon context).

**Fix:** Guard and fall back to `NSHomeDirectory()/Library/Application Support`, log, and fail gracefully.

**Verification:** Unit-test a nil-URL seam if injectable.

---

### TC-24 — `proc_pidpath` buffer handling

**Location:** `Sources/Routing/AppResolver.swift:185-190`

**Confidence/evidence:** Confirmed defensive issue. The returned byte count is ignored and `String(cString:)` is used; an exactly-full, non-NUL-terminated buffer can overread.

**Fix:** Use the returned `n`, find the first NUL within `0..<n`, and decode that slice.

**Verification:** Extract the conversion helper and test a synthetic full/no-NUL buffer.

---

### TC-25 — Socket-to-PID match ignores connection state and addresses

**Location:** `Sources/Routing/AppResolver.swift:239-244`

**Confidence/evidence:** Confirmed. The match is only `lport == localPort && fport == proxyPort`; it does not require `TCPS_ESTABLISHED`, loopback addresses, or the proxy's local address.

**Impact:** A local process can deliberately choose an ephemeral port to spoof another app's identity and be routed by its rule. Policy/telemetry spoof, not remote privilege escalation.

**Fix:** Require established state, loopback on both sides, and the expected proxy port/address; capture the accepted client's full 4-tuple and match all four.

**Verification:** Add a mismatched-state/address case to `Tests/AppIdentityHarness`.

---

### TC-26 — Bundle cache eviction is all-at-once and stampedes

**Location:** `Sources/Routing/AppResolver.swift:134-151`

**Confidence/evidence:** Confirmed. At 512 entries, `removeAll(keepingCapacity: true)` discards everything; concurrent misses for the same new path all read the same plist; entries have no TTL.

**Fix:** Bounded LRU with per-entry TTL; coalesce in-flight path lookups.

**Verification:** Burst of distinct paths; assert bounded plist reads and cache size.

---

### TC-27 — Supervisor timer is not invalidated on deinit; `stop()` leaves stale state

**Location:** `Sources/Tunnel/TunnelSupervisor.swift:22-35`

**Confidence/evidence:** Confirmed. The timer block captures `self` weakly, but the run loop retains the timer; if the supervisor is deallocated without `stop()`, it fires forever as a no-op. `stop()` invalidates but does not clear `timer`/`probing`/`upState`.

**Impact:** Idle timer wakeups in an unusual lifecycle; a stopped supervisor can still publish an in-flight probe result.

**Fix:** `deinit { timer?.invalidate() }`; in `stop()` invalidate, nil the timer, and reset/document state.

**Verification:** Deallocate without `stop()`; assert no timer fires.

---

### TC-28 — Config write amplification and validation gaps

**Location:** `Sources/Config/ConfigStore.swift:66-78`; `Sources/AppModel.swift:389-442`, `:758-765`

**Confidence/evidence:** Confirmed. `save` JSON-encodes the full config with `.prettyPrinted` and writes on main; `syncProxySettings` rebuilds routing dictionaries on main every commit. `portBinding` clamps negative/oversized values to 0/65535 with no invalid state.

**Impact:** UI stall with a large target list/slow home directory; port 0 accepted for proxy/SOCKS/SSH (ephemeral bind, probe port 0, `ssh -p 0`).

**Fix:** Encode+write on a serial background queue from an immutable snapshot (last-writer-wins). Validate ports `1...65535` with an inline error instead of clamping. Debounce rebuilds.

**Verification:** Count writes while typing; try 0/-1.

---

## 5. UI and AppKit

### Summary

| ID | Sev | Confidence | Finding |
|---|---|---|---|
| UI-01 | High | Confirmed | Dashboard recomputes feed/chart/top data 2–3x per 10 Hz tick |
| UI-02 | High | Confirmed | Full `reloadData()` every tick under traffic; scroll jump/jank |
| UI-03 | High | Confirmed | Per-keystroke `commitConfig()` restarts SSH/reapplies routing (see `TC-05`) |
| UI-04 | Medium-High | Confirmed | "Add Running Apps" resolves hundreds of icons on the main actor |
| UI-05 | Medium | Confirmed + measured | Long-range SQLite queries every 2 s (see `TM-04`) |
| UI-06 | Medium | Confirmed | Out-of-order DB completions show the wrong range |
| UI-07 | Medium | Confirmed | A stale app-filter key silently traps the feed |
| UI-08 | Medium | Confirmed | 10 Hz body + 2 s DB timer continue while the dashboard is occluded/minimized |
| UI-09 | Medium | Confirmed | Every visible cell is rebuilt/re-measured every tick, including immutable columns |
| UI-10 | Medium | Confirmed | `TooltipTrackingView` omits `super.viewWillMove(toWindow:)` |
| UI-11 | Low-Medium | Confirmed | Tooltip measurement ignores the label font and attributes |
| UI-12 | Low-Medium | Confirmed | `AppIcon` caches successes only; misses re-query LaunchServices at 10 Hz |
| UI-13 | Low-Medium | Confirmed | Apps settings view does `Bundle`/`NSWorkspace` work per row per body |
| UI-14 | Medium-Low | Confirmed | Duplicate `ForEach` identity when an rc file is added twice |
| UI-15 | Low-Medium | Confirmed | Filters are ignored while the feed is paused |
| UI-16 | Low | Confirmed | Inspector recomputes routing/target decisions 4–5x per live tick |
| UI-17 | Low | Confirmed | App-filter popover uses a non-lazy VStack |
| UI-18 | Low | Confirmed | Running-apps list filtered 5x per body/keystroke |
| UI-19 | Low-Medium | Confirmed | Synchronous Keychain read on the launch/settings path |
| UI-20 | Low | Confirmed | Status-menu submenu fully rebuilt on every model/config tick |
| UI-21 | Low | Confirmed | Post-open Settings key-window lookup uses the wrong title |
| UI-22 | Low | Confirmed | Onboarding close can call `openSettings()` during termination |
| UI-23 | Low | Confirmed | Self-updating clock text in the Appearance samples |
| UI-24 | Low | Confirmed | Index-based identity in the top hosts/apps list |

### UI-01 — The dashboard derives expensive datasets multiple times per tick

**Location:** `Sources/UI/DashboardView.swift:205-211`, `:237-265`, `:314-355`, `:458-579`

**Confidence/evidence:** Confirmed. Per `@Published` change (up to 10 Hz whenever requests flow):

1. `seriesPoints` is computed once for `.isEmpty` and again inside `chart`.
2. `baseFeedRows()` is called for `feedRows.isEmpty`, for `FeedTable(rows: feedRows)`, and again for `appFilterOptions` — at least 3x per body. Each call materialises up to 506 `FeedRow`s and sorts them.
3. `selectedEvent` scans up to 5,000 events twice while the inspector is open.
4. `inMemoryTopTunneledHosts`/`inMemoryTopApps` scan 3,500 events and sort.
5. `seriesPoints` allocates interpolated id strings per bucket per body; the `Chart` is diffed at 10 Hz even though 5 m buckets change every 30 s and DB ranges every 2 s.

**Impact:** At 200–256 live connections this is ~1,500 `FeedRow` constructions, 3 sorts, 2 bucketizations of 2,000+ events, and two 3,500-event top scans per tick, plus a full chart diff. This contradicts `docs/performance.md:16` ("avoid materializing the whole feed every render").

**Fix:** Compute each dataset once per body into a small `DashboardData` snapshot (or derive it in `applyToUI`), pass it to subviews, and make the subviews `Equatable`. Update the chart/top snapshot at 1–2 Hz and keep only the live row bytes/duration at 10 Hz. Compute `feedRows`, `appOptions`, `series`, and `tops` once.

**Verification:** Add counters/signposts around `baseFeedRows`, `bucketize`, and `topItems`; assert ≤1 call per body. Profile with 200 concurrent connections.

---

### UI-02 — The feed fully reloads on every tick under traffic

**Location:** `Sources/UI/FeedTable.swift:94-129`

**Confidence/evidence:** Confirmed. `baseFeedRows` is newest-first, so any completion in the tick changes the first row's id → `identityChanged == true` → `table.reloadData()`. The partial branch is only reached when no new/finished row entered the 250-row window, which at 13.7 k req/s is essentially never.

**Impact:** Full cell teardown/re-layout for all visible rows up to 10x/s; the selection is cleared and re-applied; a user scrolled away from the top sees the list jump every tick. This defeats the documented partial-reload optimization exactly when the feed is busiest.

**Fix:** Diff ids and apply `beginUpdates`/`insertRows`/`removeRows`/`moveRow(at:to:)`, preserving the scroll anchor. Coalesce table updates to ≤4 Hz while keeping stats at 10 Hz. Freeze the visible range while scrolling. Suppress the selection write-back during programmatic reselect (an `isApplyingSelection` flag).

**Verification:** 200 concurrent connections for 60 s, scrolled to the middle: visible rows must not jump. Instrument `reloadData`/`insertRows` and assert full reloads are rare.

---

### UI-03 — Per-keystroke side effects

See `TC-05`. This is the single most user-visible UI→model bug: typing a hostname spawns `ssh` per character and briefly drops the tunnel. The fix belongs in `AppModel`/Settings (draft state or debounced side effects).

---

### UI-04 — "Add Running Apps" resolves every icon on the main actor

**Location:** `Sources/UI/RunningAppsPicker.swift:235-243`, `:265-315`; `Sources/UI/AppIcon.swift:20-24`

**Confidence/evidence:** Confirmed. `load()` awaits only the window-list scan; `buildItems` runs on the main actor and calls `AppIcon.image` (LaunchServices + `NSWorkspace.icon`) for every running app before showing the list.

**Impact:** Multi-hundred-ms to multi-second freeze on a machine with hundreds of apps/processes; the spinner and the whole app stall.

**Fix:** Build items without icons, show the list immediately, and resolve icons lazily in `RunningAppRow` (visible rows only, cached) or hydrate in batched background passes. Keep `CGWindowListCopyWindowInfo` off-main as today.

**Verification:** Open the sheet with 600+ processes under the Hangs instrument; first paint must not wait for icons.

---

### UI-05 — Long-range DB queries every 2 s

See `TM-04`. The UI timer has no in-flight guard, so a slow query queues another; the writer is on the same serial queue.

---

### UI-06 — Stale DB completions overwrite the chart with the wrong range

**Location:** `Sources/UI/DashboardView.swift:120-121`, `:583-595`

**Confidence/evidence:** Confirmed. Completions assign `dbSeries`/`dbTop*` with no check that the request still matches the current `timeRange`/`topMetric`, and the old data is not cleared on range change.

**Impact:** Switching 7 d → 1 h while a 7 d query runs can display 7-day data under the 1 h axis until the next tick. Rapid switching can leave permanently wrong data.

**Fix:** Increment a `loadGeneration` before each load; drop completions whose generation is stale. Clear `dbSeries`/`dbTop*` on range change.

**Verification:** Inject a 3 s delay in `chartSeries`; switch ranges quickly and assert the final data matches the selection.

---

### UI-07 — A stale app-filter key silently traps the feed

**Location:** `Sources/UI/DashboardView.swift:501-503`, `:553-555`; `Sources/UI/AppFilterMenu.swift:23-25`

**Confidence/evidence:** Confirmed. The menu is hidden when `appFilterOptions` is empty, but `computeFeedRows` still filters by `appFilterKey`.

**Trigger:** Select an app, then clear history, wait for that app's rows to age out, or otherwise remove it from the base rows. The menu disappears but the filter remains; every new row from other apps is filtered out and the feed says "No requests yet" with no visible reset.

**Impact:** The feed appears broken until that same app sends another request.

**Fix:** Validate the selection against live options and reset it (`onChange(of: appFilterOptions.map(\.id))`), or always show the menu with an explicit "All apps" reset. Validate again when choosing from a snapshot, since an option can disappear while the popover is open.

**Verification:** Filter by an app, purge, generate traffic from another app; the feed must show rows and read "All apps".

---

### UI-08 — The dashboard keeps working while invisible

**Location:** `Sources/UI/DashboardView.swift:98-124`; `Sources/UI/DashboardWindowController.swift:52-55`

**Confidence/evidence:** Confirmed. Closing the window nils it (good), but minimizing, occlusion by another window, or hiding the app leaves the SwiftUI tree alive. The telemetry subscription (10 Hz) and the 2 s DB timer continue.

**Impact:** Unnecessary main-thread/GPU chart work and DB scans while nothing is visible.

**Fix:** Observe `NSWindow.didChangeOcclusionStateNotification`/`didMiniaturizeNotification` and expose an `isVisible` binding. While not visible, stop the 2 s timer and skip feed/chart derivation; recompute once when visible again.

**Verification:** Hide/minimize with traffic running; CPU should return to baseline and no DB queries should be issued.

---

### UI-09 — Every visible cell is rebuilt and re-measured every tick

**Location:** `Sources/UI/FeedTable.swift:120-128`, `:275-314`, `:345-438`

**Confidence/evidence:** Confirmed. The partial path reloads **all** columns for visible rows. `FeedLabelCell.set` allocates a new `NSMutableParagraphStyle` + `NSAttributedString`; `layout()` calls `attributedStringValue.size()` and `TruncationDetector.tooltip` on every layout. `FeedHostCell` allocates two more attributed strings; `FeedAppCell` re-resolves the icon even though the row's app never changes.

**Impact:** ~160 cell reconfigurations per tick for 20 visible rows × 8 columns, plus ~3,000 attributed strings/text measurements per second at 10 Hz, on the main thread. Scroll hitching and elevated CPU.

**Fix:** In the partial path, reload only mutable columns (`dot`, `status`, `bytes`, `duration`). Cache paragraph styles/attribute dictionaries. Early-return when text/font/color/width are unchanged. Cache measured size/truncation. Update the app icon only when the bundle/path changes.

**Verification:** Count `NSAttributedString` creations per tick; only changed cells should allocate. Profile while scrolling a busy feed.

---

### UI-10 — Tooltip tracking view violates the `viewWillMove(toWindow:)` contract

**Location:** `Sources/UI/Tooltip.swift:62-65`

**Confidence/evidence:** Confirmed AppKit contract violation. The override hides the tooltip when `newWindow == nil` but never calls `super`.

**Impact:** Stale tracking/responder state can leave hover events missed or a tooltip stuck after a view moves between windows, e.g. switching Settings sections or closing the dashboard with the pointer over a cell.

**Fix:** Call `super.viewWillMove(toWindow: newWindow)` after the hide.

**Verification:** Hover a tooltip, switch Settings sections, reopen, hover again; also close the dashboard with the tooltip visible and assert no floating window remains.

---

### UI-11 — Tooltip sizing ignores the label font and attributes

**Location:** `Sources/UI/Tooltip.swift:113-125`

**Confidence/evidence:** Confirmed. `boundingRect(with:options:)` is called without `attributes:` while the label uses a 10 pt font, and the height is hard-coded to 40.

**Impact:** Tooltips sized for the wrong font; long wrapped text can be clipped or too wide.

**Fix:** Measure with `[.font: label.font]` and an unbounded height; set `preferredMaxLayoutWidth`.

**Verification:** Compare the tooltip frame to `label.sizeThatFits` for long app names/bundle ids.

---

### UI-12 — `AppIcon` does not cache failures

**Location:** `Sources/UI/AppIcon.swift:15-27`; called from `FeedTable.swift:417`, `DashboardView.swift:398-407`, `RequestDetailView.swift:136`, `AppFilterMenu.swift:128`

**Confidence/evidence:** Confirmed. Only successful images are cached; `nil` is returned on every call.

**Impact:** An uninstalled/relocated app causes a synchronous LaunchServices round-trip on the main thread for every visible cell, 10x/s. A wedged LaunchServices can stall for seconds.

**Fix:** Add a negative cache (`NSCache<NSString, NSNull>` or a small locked set) with a TTL; resolve icons once when a row/event first appears, not in the 10 Hz cell path. Add `totalCostLimit` for the positive cache.

**Verification:** Call `AppIcon.image` twice for a nonexistent bundle; assert one LaunchServices call.

---

### UI-13 — Apps settings view does `Bundle`/`NSWorkspace` work per row

**Location:** `Sources/UI/AppsSettingsView.swift:18-36`, `:256-270`, `:295-296`, `:341`

**Confidence/evidence:** Confirmed. `AppDisplay.name` calls `urlForApplication` + `Bundle(...).infoDictionary`; `AppDisplay.icon` calls `urlForApplication` + `icon(forFile:)`; both are called twice per rule row and again in the detail pane.

**Impact:** LaunchServices DB lookups and plist parsing on main while scrolling/editing; jank with a longer rule list.

**Fix:** Cache display names per `(key, keyKind)`; route icons through `AppIcon`; resolve once per row and pass down.

**Verification:** Count LaunchServices calls while scrolling 100 rules; assert ≤1 per visible row per render.

---

### UI-14 — Duplicate `ForEach` identity for managed rc files

**Location:** `Sources/UI/SettingsView.swift:683-709`

**Confidence/evidence:** Confirmed. `ForEach(..., id: \.self)` and "Add" does not deduplicate. Adding `~/.zshrc` twice produces duplicate IDs.

**Impact:** SwiftUI undefined behavior/console warnings; editing/removing one row can affect another; `removeAll` removes all copies.

**Fix:** Deduplicate/normalize on add, or use a UUID-wrapped identity.

**Verification:** Add the same path twice; no duplicate-ID warning, one row.

---

### UI-15 — Filters are ignored while paused

**Location:** `Sources/UI/DashboardView.swift:117-119`, `:518-557`

**Confidence/evidence:** Confirmed. Pause captures `pausedSnapshot = computeFeedRows()` with the then-current filters; while paused, `feedRows` returns it unchanged, so later filter changes do nothing.

**Impact:** The filter appears broken while paused; the app-filter menu shows live options that do not correspond to the frozen rows.

**Fix:** Store the **unfiltered** snapshot and apply the current route/host/app filters at render time.

**Verification:** Pause, change each filter, assert rows update while live data stays frozen.

---

### UI-16 — Inspector recomputes routing/target decisions 4–5x per live tick

**Location:** `Sources/UI/RequestDetailView.swift:221-295`, `:355-419`

**Confidence/evidence:** Confirmed. `targetAction` scans `model.config.targets` twice and is read for the icon, color, tooltip and action. `explanation` calls `RoutingEngine.explain` and is recomputed by `configChangedSinceRequest`, `reasonShort`, and `reasonSentence`.

**Impact:** O(targets) work several times per 10 Hz frame with a large imported target list. Not a crash, but avoidable main-thread cost.

**Fix:** Compute one `InspectorFacts` struct once per body (or cache by host/app/config revision) and pass it down; compute the tooltip lazily on hover.

**Verification:** Counter around `explain`/`targetAction`; assert 1 per body.

---

### UI-17 — App-filter popover builds every row in a non-lazy stack

**Location:** `Sources/UI/AppFilterMenu.swift:70-83`

**Confidence/evidence:** Confirmed. A `VStack` inside a fixed-height `ScrollView` builds all rows, each with a `TruncatableText` (two `GeometryReader`s + hidden measurement text) and an icon.

**Impact:** Slow first open and a large view tree on a feed with many apps.

**Fix:** Use `List`/`LazyVStack`; keep the search box.

**Verification:** Open with 200 synthetic apps; measure open time.

---

### UI-18 — Running-apps list is filtered five times per body

**Location:** `Sources/UI/RunningAppsPicker.swift:119-135`, `:216-221`

**Confidence/evidence:** Confirmed. Each of the five sections calls `items(in:)`, which re-filters the full `items` array and applies the query.

**Impact:** O(5n) work and five arrays per keystroke.

**Fix:** Partition once per `(items, query)` into a dictionary; sections read their bucket.

**Verification:** Type a query with 600 items; compare CPU/allocations.

---

### UI-19 — Synchronous Keychain read on the launch/settings path

**Location:** `Sources/UI/OnboardingView.swift:46`; `Sources/UI/SettingsView.swift:616`

**Confidence/evidence:** Confirmed. `State(initialValue: AppModel.shared.loadManagedPassword())` in `init`, and `.onAppear` for Settings. `SecItemCopyMatching` can block on a locked Keychain or an access prompt.

**Impact:** Delayed onboarding first paint / Settings hitch; potentially a main-thread Keychain prompt.

**Fix:** Initialize empty and load asynchronously after appearance (or lazily on focus). Keep the password out of view init.

**Verification:** Launch with a locked Keychain; the UI should render immediately.

---

### UI-20 — Status-menu submenu is rebuilt on every model/config tick

**Location:** `Sources/UI/StatusMenuController.swift:161-210`, `:384-429`

**Confidence/evidence:** Confirmed. `$config` and other `@Published` changes call `refresh()` → `refreshAppControl()` → `removeAllItems()` + ~8 new `NSMenuItem`s + `NSWorkspace.frontmostApplication` + config lookup.

**Impact:** Menu allocation/removal several times per second in the worst case while the menu is closed.

**Fix:** Cache a signature (key, name, effective mode, existing-rule flag); rebuild only when it changes or in `menuWillOpen`.

**Verification:** Type in a Settings field; assert `refreshAppControl` does not run per keystroke.

---

### UI-21 — Post-open Settings key-window lookup uses the wrong title

**Location:** `Sources/AppModel.swift:687-696`; `Sources/UI/StatusMenuController.swift:284-296`; `Sources/UI/SettingsView.swift:4-6`

**Confidence/evidence:** Confirmed. Both look for a visible window whose title contains "Settings", but the Settings window is titled like the app ("Proxy Manager"). The follow-up `makeKeyAndOrderFront` is a no-op.

**Impact:** Settings can open behind the previous frontmost window; the user must click it.

**Fix:** Use the existing `SettingsWindow.current` weak reference after a short main-queue hop.

**Verification:** From another app, open Settings from the status menu; assert it is key/frontmost on the first try.

---

### UI-22 — Onboarding close can call `openSettings()` during termination

**Location:** `Sources/UI/OnboardingView.swift:494-502`

**Confidence/evidence:** Confirmed. `windowWillClose` calls `completeOnboarding()` and `openSettings()` whenever `didFinish` is false. Quitting with onboarding open, or closing it during another transition, activates the app/sends a menu action from inside the close notification.

**Impact:** Re-entrant AppKit/SwiftUI work during termination; can delay/cancel quit or flash Settings.

**Fix:** Guard on `NSApp.isTerminating` and defer the side effects to the next run-loop pass (`DispatchQueue.main.async`), or do it in a close completion callback.

**Verification:** Quit with onboarding open; termination is not blocked and no Settings flashes. Close via the red button; Settings opens once.

---

### UI-23 — Self-updating clock text in Appearance samples

**Location:** `Sources/UI/SettingsView.swift:850`

**Confidence/evidence:** Confirmed. `Text(Date(), style: .time)` is a self-updating date text, used in a decorative mock (three cards). It schedules periodic invalidation while the view tree lives.

**Impact:** Minor periodic invalidations; unnecessary.

**Fix:** Render a static sample time or a fixed `Date`.

**Verification:** SwiftUI instrument shows no periodic updates after first render.

---

### UI-24 — Index-based identity in the top hosts/apps list

**Location:** `Sources/UI/DashboardView.swift:333`, `:425`, `:452`

**Confidence/evidence:** Confirmed. `ForEach(Array(items.enumerated()), id: \.offset)` with non-stable sorts (dictionary order + non-stable `sorted`). Equal counts can swap rows between ticks.

**Impact:** View reuse for a different item; potential icon/name flicker; defeats diffing.

**Fix:** Use the host/app key as id and add a deterministic tie-breaker (`label`).

**Verification:** Seed equal counts; rows must not swap identities.

---

## 6. Documentation drift

The following claims in `docs/` are contradicted by the code (fix the code or the docs):

| Doc | Claim | Reality |
|---|---|---|
| `docs/performance.md:22` | "SQLite WAL bounded by retention (`retentionDays`/`maxRows`)" | Retention bounds rows, not bytes. No `journal_size_limit`, no truncate, no `VACUUM`; measured 20 MB WAL and 235 MB DB unchanged after large deletes. |
| `docs/telemetry.md:56` | "`purge()` also drops in-flight sessions (their rows are discarded entirely)" | `endSession` still calls `appendCompletion`, so in-flight rows reappear after Clear (`TM-07`). |
| `docs/telemetry.md:19`, `docs/performance.md:14` | `record`/begin/end are O(1) | `beginSession` inserts at index 0, `endSession` searches under the global lock, `flush` builds up to 256 snapshots under it (`TM-05`). |
| `docs/ui.md:27`, `docs/performance.md:16` | Full `reloadData()` only when row identity changes; otherwise on-screen rows | Identity changes every tick with a completion, so the partial branch is effectively unreachable under traffic (`UI-02`). |
| `docs/telemetry.md:40` | Retention deletes rows older than the setting | Settings are ignored until relaunch (`TM-02`). |
| `docs/ui.md:25` | The 5 m chart/top lists cover 5 minutes | They sample the last 2,000/3,000 events — 0.15–0.2 s at the documented rate (`TM-18`). |
| `docs/performance.md:22` | "Memory: relay buffers 256 KB/direction" | Actual cap is ~272 KB/direction (`PS-10`). |
| `docs/proxy-core.md` | "client half-closes still receives the full response" | True only for 3 s (`PS-03`). |
| `docs/per-app-rules.md:228-247` | Planned scan cache/semaphore | Not implemented (`TC-07`). |
| `docs/tunnel-supervisor.md:23`, `:35` | Askpass secret self-deletes on crash | Only if ssh invokes the helper; no startup sweep (`TC-08`). |

---

## 7. Verified safe (do not "fix" these)

These were checked and are not findings:

- **fd lifecycles in the proxy:** `defer { close(cfd) }` before any header read; `defer { close(upstream) }` immediately after connect; `SOCKS5Client.connect` and `Socket.connect` close on every failure. no observed fd leak on early returns.
- **SIGPIPE:** `SO_NOSIGPIPE` on listener, accepted clients and `Socket.connect` results, plus process-wide `IGN` in app and helper. The E2E RST burst passes.
- **Semaphore ownership:** connection threads capture `self` strongly, so `ProxyServer` and the semaphore outlive permits; `defer { signal() }` runs on return.
- **Relay poll set:** `events == 0` fds excluded; EOF guarded by `!readDone`; `POLLERR`/`POLLNVAL` drop buffers; stack allocation for `pollfd`; timeout clamped before `Int32`.
- **DNS addrinfo ownership:** `ResolutionBox` frees exactly once on timeout/success; the DNS probe returns `liveResolutions == 0` (the *thread* leak is `PS-06`).
- **`close()` wakes a blocked `accept()` on macOS** (errno 53); `stop()` sets `listenFD = -1` before closing, avoiding fd-reuse races.
- **Telemetry SQLite binding:** `SQLITE_TRANSIENT` copies text at bind time; all prepared statements are finalized on the normal paths; all SQLite access is serialized on `dbQueue`; no per-request SQLite or `main.async`.
- **Telemetry lock ordering:** the only nesting is global → per-session; no inversion; no I/O or dispatch under the lock.
- **Telemetry UI publishing:** all `@Published` writes are on main; assignments are coalesced and equality-guarded; only the Dashboard observes the store; no retain cycles in the flusher/DB/UI hops.
- **Live-session pairing:** `beginSession` is always followed by `endSession`; every throwing path precedes `beginSession`; `sessions` cannot leak in normal operation.
- **`Format`** caches its formatters and is main-thread only.
- **`TruncationDetector`** is UTF-16-safe (NSString size, no range slicing that can split an emoji).
- **Feed selection** is one-way and identity-stable in the normal path; `reloadData()` does not post a selection change (probe).
- **`AppWindowTracker`**: windows weak, KVO/willClose observers removed, bounded entries.
- **Combine sinks** in `StatusMenuController`/`UpdaterController` use `[weak self]`; window controllers release their windows on close.
- **`AppIcon`** uses a thread-safe `NSCache` and a shared placeholder (the gap is failure caching).
- **Tooltip window** is a singleton, borderless, non-activating, ignores mouse events; no per-hover window allocation (the gaps are P10/P11).
- **Running-apps window scan** is off-main and needs no Screen Recording permission.
- **Sparkle** has a single retained delegate; the KVO sink is weak; frequency mapping uses a static non-nil constant.
- **Onboarding** buffers edits in local `@State` and commits on Finish (unlike Settings).
- **No reachable force-unwrap crash in the UI layer**; no `as!`, no unbounded `ForEach` index access.
- **Helper argv-only model:** `networksetup` receives an argument array, never a shell; osascript quoting handles embedded quotes.
- **Helper port/service validation** (apart from `LC-01` and `LC-23`) fails closed.
- **GUI env injector** snapshot/restore is idempotent and restores originals; covered by `Tests/GuiEnvHarness`.
- **Shell env host sanitization and markers** prevent quote breakout; removal is marker-based.
- **Paths and bundle id** agree across `ConfigStore`, `Watchdog`, and `revert.sh`.
- **Demo mode** skips tunnel probing, Keychain, network observation, auto-enable, system proxy, watchdog and quit restore.
- **`shutdownForQuit`** serializes on `workQueue`, so an in-flight apply cannot run after the restore (the specific documented race is handled).
- **`applicationShouldTerminate`** distinguishes deliberate/system quits and defers window closes.
- **Routing matching correctness** (wildcards/apex/boundaries/case/trailing dots/ports/IPv6/empty patterns) is correct and tested; the issue is allocation cost (`TC-12`), not semantics.
- **AppResolver** uses process start time for PID-reuse validation, checks libproc return values/socket kind/family, opens no fds, and has lock-protected caches.
- **SSH runner happy path:** one serial queue, generation tokens, SIGTERM→2 s→SIGKILL, password never in argv/env, `ControlMaster=no`, capped exponential backoff, normal child reaping.
- **Tunnel supervisor:** single in-flight probe, off-main, publishes only on change, weak callbacks.
- **Config writes** are atomic with owner-only permissions; missing keys and unknown keys are tolerated (the gap is malformed values, `TC-01`/`TC-02`).
- **Presets** have stable UUIDs and normal UI flows dedupe by pattern; no allow-all.

---

## 8. Needs runtime verification / open questions

These are plausible but were not confirmed; do not treat them as bugs until tested.

1. **SMAppService daemon layout.** `build.sh` places the daemon in `Contents/Library/LaunchDaemons/` next to the plist; `SMAppService.daemon` may expect the executable in `Contents/MacOS` or a `BundleProgram` key. Verify on a Developer-ID-signed VM. If registration fails, the helper path is dead even after `LC-01`.
2. **`networksetup` localization.** The audit machine's output stayed English under `LANG=de_DE.UTF-8`, so the header-matching concern was not reproduced. A localized banner would be treated as a service and fail every mutation. Defensive `dropFirst`/validation is cheap.
3. **Port 0 acceptance by `networksetup`.** If it accepts port 0, `LC-19` becomes a dead-proxy bug; if it rejects, it is a confusing rollback failure. Test on a scratch service/VM.
4. **Authenticated-proxy restore.** Whether `networksetup -setwebproxy svc server port` preserves the "Authenticated Proxy Enabled" flag needs a VM test.
5. **Watchdog `NSRunningApplication` under LaunchAgent.** A spurious `nil` while the app is alive would cause a false restore. Consider treating `kill(pid,0)==0` with an unreadable bundle id as alive (fail safe).
6. **Vnode directory-watch on atomic rename.** The harness covers `NOTE_EXIT`/idle CPU, not the arm-file wake. If it does not fire, arming is detected only by the 120 s tick.
7. **LaunchServices wedge behavior.** `UI-12` impact assumes a slow/wedged LaunchServices; the repeated-call defect is certain, the multi-second stall is environmental.
8. **Absent `autoreleasepool` on detached connection threads.** `handleConnection` does Foundation work with no explicit pool; if Foundation does not install one, autoreleased objects may accumulate per connection (worst with per-app recording). Test with 100k connections and `leaks`/`vmmap`; if growth appears, wrap the connection body in `autoreleasepool`.
9. **`TCP_NODELAY` benefit.** Measure p50/p99 for small HTTP/WebSocket exchanges before adding it.
10. **Absolute dashboard CPU.** The operation counts (`UI-01`/`UI-02`) are exact; the percentage depends on Charts/AppKit internals and the machine. Profile before/after.

---

## 9. Test and benchmark matrix

Add these to the existing standalone harnesses (see `docs/testing.md`). Every fix should land with its regression.

### Proxy / sockets (`Tests/ProxyE2E`, `Tests/CrashProbes`, `Tests/RegressionHarness`)

- Chatty origin + client RST: origin's post-RST byte delta is bounded; a new connection is accepted immediately (`PS-02`).
- Symmetric upstream RST while the client keeps sending (`PS-02`).
- Delayed origin (4 s) after client `shutdown(SHUT_WR)`, direct and tunneled; full body (`PS-03`).
- Forward HTTP half-close with a delayed origin; full body (`PS-03`).
- Slow reader after origin FIN; no truncation (`PS-03`).
- `Host` authority rewrite: non-default port, `[::1]:8080`, query-only path (`PS-04`).
- Chunked POST end-to-end; duplicate-case `Content-Length` (`PS-05`).
- DNS probe asserts bounded resolver **threads**, not just `liveResolutions` (`PS-06`).
- `makeTimeval` boundaries and a blocking-recv zero-timeout probe (`PS-09`).
- EINTR signal storm during a large transfer (`PS-08`).
- Accept-loop churn/EMFILE with a thread-count assertion; TSAN run (`PS-11`).
- Slow SOCKS5 drip handshake aborts at the deadline (`PS-12`).
- SSRF bypass forms from a non-loopback bind (`PS-01`).

### Telemetry (`Tests/TelemetryHarness` + new `TelemetryPerfHarness`)

- Locked DB: `BEGIN IMMEDIATE` held; one log line, no crash, rows persist after release (`TM-01`).
- Read-only/corrupt DB: explicit error/quarantine, no silent loop (`TM-01`, `TM-11`).
- `setLimits` then purge without restart (`TM-02`).
- Chunked trim progress + WAL truncate + size assertions (`TM-03`).
- In-flight row after `purge` stays gone; stats do not resurrect (`TM-07`).
- 60 KB host clamp + byte budget (`TM-08`).
- Time-based flush without `flushNow` (`TM-15`).
- `Int.max` retention does not trap (`TM-10`).
- 256 threads × 200k updates/s: p99 lock wait, bounded sessions (`TM-05`).
- 10k records/s with the DB locked for 10 s: bounded queue memory (`TM-09`).
- Insert-batch latency while a 7 d chart query runs (`TM-04`).

### Lifecycle / system proxy (`Tests/WatchdogHarness`, new `LifecycleHarness`, VM tests)

- Pre-apply enable failure preserves the snapshot and armed state (`LC-03`).
- New service after enable is snapshotted/restored (`LC-04`).
- Missing snapshot + dangling proxy does not disarm (`LC-05`).
- Stale service snapshot restores the real services and skips exit 8 without admin (`LC-06`).
- Armed port mismatch with a snapshot restores or stays armed (`LC-07`).
- Watchdog restore clears the snapshot (`LC-08`).
- Empty/failed service list aborts enable (`LC-09`).
- SIGKILL between apply and `wasOnKey`, watchdog disabled, recovers on launch (`LC-10`).
- Non-loopback bind never leaves a dead system proxy (`LC-11`).
- Watchdog install failure + `restoreOnQuit=false` restores synchronously (`LC-12`).
- Relaunch race: new armed state survives; old restore does not run (`LC-13`).
- Two instances: second exits without side effects (`LC-14`).
- Shell env toggles/port changes/symlinks/fish (`LC-15`).
- Restore fidelity fixtures: empty bypass, PAC empty URL, auth, failed read (`LC-16`).
- Helper auth with a signed test binary (`LC-01`); immediate XPC rejection under 1 s (`LC-02`).
- `revert.sh` VM: pre-existing GUI proxy + PAC + managed SSH (`LC-24`).

### Tunnel/config/routing (`Tests/RegressionHarness`, `Tests/AppIdentityHarness`, new `TunnelHarness`)

- Config decode matrix: unknown enums, bad UUIDs, wrong types, out-of-range ports, nulls (`TC-01`).
- Unreadable config is not overwritten (`TC-02`).
- Watchdog stays armed with an unreadable snapshot (`TC-03`).
- SSH spawn failure: `isRunning == false`, error published, backoff (`TC-04`).
- Typing a 20-char host spawns at most one ssh; fatal + unrelated edit does not respawn (`TC-05`).
- Launch with managed mode + routing off: no ssh (or documented option) (`TC-06`).
- Crash + relaunch in MANUAL reaps the old ssh and frees the port (`TC-06A`).
- 200 concurrent resolves: bounded latency/cache/thread count (`TC-07`, `TC-10`).
- Askpass crash test leaves no secret after sweep (`TC-08`).
- Fake ssh writes 100 MB stderr; bounded RSS (`TC-09`).
- Fake ssh fatal line under load; no retry loop (`TC-11`).
- 10k wildcard rule benchmark (`TC-12`).
- PID reuse: mismatched start time is not killed (`TC-14`).
- Quit immediately after an edit persists it (`TC-18`).
- `ProxyCommand` child is gone after stop (`TC-20`).
- Fake slow `launchctl`/`ps`; bounded return (`TC-21`, `TC-22`).

### UI (`Tests/UIHarness`, Instruments)

- Count `baseFeedRows`/`bucketize`/`topItems` per tick: ≤1 (`UI-01`).
- Table diff: no full reload when a new row enters; scroll anchor stable (`UI-02`).
- Running-apps sheet first paint with 600+ processes (`UI-04`).
- Range switching with a 3 s query delay; final data matches selection (`UI-06`).
- Stale app filter after purge; feed shows other apps (`UI-07`).
- Occluded/minimized dashboard: no DB queries, CPU baseline (`UI-08`).
- Attributed-string count per tick; only changed cells allocate (`UI-09`).
- Tooltip hover across Settings sections; no stale window (`UI-10`), correct long-text size (`UI-11`).
- Negative icon cache: one LaunchServices call (`UI-12`).
- Duplicate rc path: no duplicate-id warning (`UI-14`).
- Paused feed still filters (`UI-15`).
- Keychain locked: onboarding/Settings render immediately (`UI-19`).
- Settings from the status menu is key/frontmost (`UI-21`).
- Quit with onboarding open does not block (`UI-22`).

### Throughput / soak

- Re-run the documented 13.7 k req/s CONNECT, 3.4 GB/s streaming, and 256-concurrency baselines before/after relay/telemetry changes.
- 1 h soak with a 7 d dashboard open, `maxRows` lowered mid-run, and slow-client backpressure: sample RSS, thread count, `telemetry.sqlite`/`-wal` sizes, and lock-wait p99.

---

## 10. Phased remediation plan

### Phase 0 — stop the "no internet" class (do first, small diffs)

1. `LC-01` helper signing flags (one line).
2. `LC-02` signal the XPC semaphore on all error paths.
3. `LC-03` preserve snapshot/watchdog on pre-apply failure.
4. `LC-05` + `LC-07` tri-state proxy check, no disarm on missing/unknown, any-local-port match.
5. `LC-06` skip stale services, stop on exit 8, no admin escalation.
6. `LC-04` snapshot new services before applying.
7. `LC-08` clear the snapshot after a successful restore; verify writes; fix quit ownership.
8. `LC-10` persist intent before apply.

### Phase 1 — relay correctness and hot-path safety

1. `PS-02` dead-peer teardown (permit drain).
2. `PS-03` half-close grace (silent truncation).
3. `PS-04`/`PS-05` Host/path and chunked framing.
4. `PS-06` numeric fast path + bounded resolver.
5. `PS-09` timeout floor + monotonic deadline.
6. `PS-07` buffer read index.

### Phase 2 — telemetry durability and resource bounds

1. `TM-01`/`TM-11` checked rc, busy timeout, rollback, one log per batch, visible store error.
2. `TM-02` + `TM-10` live limits + overflow clamp.
3. `TM-03` chunked trim, `journal_size_limit`, checkpoint/truncate.
4. `TM-07` purge generation; `TM-08` ingest clamps/byte budget; `TM-15` time flush.
5. `TM-04` read-only analytics connection + `(ts,route)` index + in-flight guard.
6. `TM-05` per-session atomics, O(1) session bookkeeping.

### Phase 3 — config/tunnel robustness

1. `TC-01`/`TC-02` tolerant per-field decode, unreadable-vs-absent.
2. `TC-04` spawn failure state; `TC-06A` reap before deleting pid; `TC-11` EOF drain.
3. `TC-05` debounced/draft SSH settings, fatal cooldown.
4. `TC-07` resolver scan semaphore/cache; `TC-10` bounded identity cache.
5. `TC-08` askpass sweep; `TC-09` bounded stderr; `TC-14` start-time PID verification.

### Phase 4 — UI performance

1. `UI-01` single-pass derivation.
2. `UI-02` incremental table updates + scroll anchor.
3. `UI-03` commits (covered by `TC-05`).
4. `UI-04` lazy icons; `UI-09` cell caching; `UI-12` negative icon cache.
5. `UI-06` generation tokens; `UI-07` filter validation; `UI-08` visibility gating.
6. Remaining UI polish (`UI-10`–`UI-24`).

### Phase 5 — cleanup and docs

1. `LC-15`–`LC-24` env/restore/revert/process bounds.
2. Lower-severity findings (LC-L*, PS-10–13, TM-14/17–19, TC-18–28).
3. Update `docs/performance.md`, `docs/telemetry.md`, `docs/ui.md`, `docs/proxy-core.md`, `docs/routing.md`, `docs/tunnel-supervisor.md`, and `AGENTS.md` to match the fixed behavior (or remove the false claims).
4. Add every regression above to `./Tests/run-all.sh` so the definition of done catches reintroduction.

---

## 11. Closing notes on evidence quality

- The proxy findings `PS-02`, `PS-03`, `PS-04`, `PS-09` and the helper finding `LC-01` were reproduced with compiled probes against the real sources or the same OS APIs, not inferred.
- The SQLite measurements (`TM-03`, `TM-04`) are from a schema copy and a local disk; the constants will vary, but the query plans and file-growth mechanism are deterministic SQLite behavior.
- The UI operation-count findings are structural (computed properties called from `body`; newest-first identity), not dependent on Charts internals.
- Items in section 8 are explicitly **not** claimed as bugs. The one code-review hypothesis that was empirically disproved (`reloadData` selection notification, `TM-16`) is recorded so it is not re-reported as a bug.
- No source file, config, snapshot, LaunchAgent, proxy setting, Keychain item, or database in the repository was modified during the audit.
