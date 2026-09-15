# Proxy core — HTTP CONNECT/forward proxy

`Sources/Proxy/ProxyServer.swift`

## Responsibilities

- Listen on `127.0.0.1:8888` (configurable `proxy.bindHost`/`proxy.port`).
- Parse the client request (`CONNECT host:port` for HTTPS, or absolute-form `GET http://host/...` for plain HTTP).
- Decide route via `RoutingEngine.decide(host)`.
- Open upstream: SOCKS5 (tunnel) or direct TCP, then relay bytes bidirectionally.
- Emit telemetry: the connection appears in the live feed the moment it is established (`beginSession`), ticks bytes/duration while it streams, and is finalized when it closes (`endSession`). One `RequestEvent` per connection; events carry the **start** timestamp and `durationMs` = connection wall time.

## Connection lifecycle

`start()` creates the listen socket (blocking), then a single accept thread (`acceptQueue`) loops:

```
accept() → semaphore.wait() → active.inc() → Thread.detachNewThread { handleConnection(cfd) }
```

Each connection runs its whole life on **one detached thread**:

1. `readHeader` — blocking `recv` until `\r\n\r\n` (bounded at 64 KB and a **total 15 s deadline**; `SO_RCVTIMEO` is per-call, so the deadline defeats slowloris).
2. `HTTPParser.parse`.
3. Route decision; if tunnel-down + fail-closed → `502`; fail-open → direct (event tagged `tunnel_down`).
4. `connectUpstream` (SOCKS5 handshake or direct `connect`), on failure → `502`.
5. CONNECT: send `200 Connection Established`, then `relay`. Absolute-form: rewrite + send, then `relay`.
6. Successful relay connections call `telemetry.beginSession` (live row) before `relay`, feed `telemetry.updateSession` per poll iteration, and `telemetry.endSession` when `relay` returns. Failures (connect refused, tunnel-down+closed, malformed) record directly via `telemetry.record`.

`defer { close(upstream) }` (right after connect) and `defer { close(cfd) }` (at the top) guarantee no fd leaks.

## Relay (the hot path)

`relay(_ client:_ upstream:initial:idle:progress:)` is a **single-threaded `poll()` loop** with two buffered directions (`c2u` client→upstream, `u2c` upstream→client). The optional `progress` closure is invoked once per poll iteration when bytes moved (with `(bytesIn, bytesOut)` deltas, off the hot path — see `docs/telemetry.md`).

- Both sockets set non-blocking; reads/writes driven by `POLLIN`/`POLLOUT`.
- Buffers bounded at `256 KB` each; read chunk `16 KB`; `POLLIN` is suppressed when the outgoing buffer is full (backpressure).
- **Half-close (FIN) is propagated only after the corresponding buffer drains** — so a client that half-closes still receives the full response, and `shutdown()` never cuts off pending data.
- **Termination**: only when both directions are done *and* both buffers empty.
- **`POLLERR`/`POLLNVAL`** mark that direction done (avoids a 100%-CPU busy-spin); `POLLHUP` is folded into the read path (recv returns 0) **only while that direction's EOF has not been read yet**.
- **Never recv after EOF is consumed.** Once `recv()` has returned 0 (peer's EOF read), the peer's `POLLHUP` stays level-triggered and *always* reported; a read handler that keeps calling `recv()` on it gets 0/EAGAIN forever → a 100%-CPU busy-spin that never reaches the poll timeout. Guard every read with `!readDone`.
- **A hung-up, non-writable peer means its outgoing buffer is undeliverable.** `POLLHUP`/`POLLERR`/`POLLNVAL` are mutually exclusive with `POLLOUT` once a peer is gone (verified: a *live* half-closed peer keeps returning `POLLOUT`; a truly closed/reset peer returns hangup flags without `POLLOUT`). If a buffer is non-empty and poll reports the peer hung up without `POLLOUT`, the buffered data can never be delivered — drop it (`removeAll`). Otherwise the level-triggered hangup makes `poll()` return instantly forever (the original 100%-CPU relay spin, fixed).
- **Grace timeout**: once either side half-closes, the poll timeout drops from `idle` (120 s) to `grace` (3 s), so a peer that never closes after FIN is reaped in ~3 s instead of 120 s.

## Concurrency & limits

- `DispatchSemaphore(value: 256)` bounds concurrent connections; the accept loop blocks when full (backpressure into the TCP backlog).
- `maxConcurrent` is a `ProxyRuntimeSettings` field but the semaphore is fixed at 256 at init — changing the setting at runtime has no effect (known limitation; see `docs/roadmap.md`).

## Failure paths that must stay covered

- Malformed request line / header flood → error, close (see `docs/http-parser.md`).
- Upstream connect failure → `502 Bad Gateway`.
- Client abort mid-handshake → caught, fd closed, truncated event recorded.
- Tunnel down + fail-open → direct; fail-closed → `502`.

## Don't break these

- Never add `Network.framework` to the outbound path (system-proxy loop).
- Never buffer a whole body — stream in chunks.
- Never let `relay` terminate early on one-direction EOF (truncates responses).
- Always close both fds on every path.
- **Set `Socket.setNoSIGPIPE(fd)` on every socket** (listener, accepted client, `Socket.connect` result). Without it a `send()` to a reset peer raises SIGPIPE and kills the process (`Tests/ProxyE2E` RST burst is the regression).

## Audit changes (2026-09-15)

- **SIGPIPE**: `SO_NOSIGPIPE` on all created/accepted sockets + process-wide `signal(SIGPIPE, SIG_IGN)`.
- **SSRF guard**: a **non-loopback** client is refused (`403`) for loopback/link-local/RFC1918 destinations; a non-loopback bind logs a warning. Loopback clients (the normal case) are unaffected.
- **Direct upstream send timeout**: the direct fd gets `SO_SNDTIMEO`/`SO_RCVTIMEO` (the SOCKS path already did), so a forwarded request to a stalled upstream can't block forever.
- **Bounded DNS/connect**: `Socket.connect` runs `getaddrinfo` on a detached thread with a deadline and uses one overall budget across all addresses.
- **Header deadline** + `EINTR` retry in `readHeader`.

