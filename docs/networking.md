# Networking — sockets & SOCKS5

`Sources/Socks/Socket.swift`, `Sources/Socks/SOCKS5.swift`

## Why raw BSD sockets

`Network.framework` (`NWConnection`/`NWListener`) **honors the macOS system proxy**. Since this app sets the system proxy to `127.0.0.1:8888`, an `NWConnection` outbound connection loops back into the proxy → `Connection refused` → dead internet. **All upstream (outbound) connections must use raw BSD sockets** (`connect()`), which ignore the system proxy.

## Socket.swift

- `setNoSIGPIPE` — sets `SO_NOSIGPIPE` on every fd the app creates or accepts; macOS has no `MSG_NOSIGNAL`, so without it a `send()` to a reset peer raises `SIGPIPE` and kills the process.
- `connect(host:port:timeout:)` — `resolve` runs `getaddrinfo` (AF_UNSPEC) on a detached thread with a hard deadline (the resolver itself is unbounded), then tries each resolved address: non-blocking `connect()`, `poll()` for `POLLOUT` + `SO_ERROR`. `timeout` is one overall budget across DNS + all attempts. Closes the fd on every failure path; `defer { freeaddrinfo(info) }`.
- `waitForWritable` — uses `poll()` (not `select`/`fd_set`, which had a `fd≥32` bit-indexing bug).
- `setNonBlocking`, `setTimeouts` (`SO_RCVTIMEO`/`SO_SNDTIMEO`).
- `recvExact`, `sendAll` — loop for partial I/O; treat `EINTR` carefully.

### Known sharp edges (see `docs/roadmap.md`)

- `sendAll` waits for writability and retries on `EAGAIN`/`EWOULDBLOCK` (bounded at 30 s), so it is safe on both blocking and non-blocking fds.
- `resolve` frees the `addrinfo` list exactly once even when DNS times out: the caller marks the box cancelled and whichever side finishes last frees. `Socket.liveResolutions` is a test-only counter proving no leak.

## SOCKS5.swift (RFC 1928 client)

- **No-auth only** (`[0x05,0x01,0x00]` → expect `[0x05,0x00]`).
- **Connect request uses `ATYP=0x03` (domain)** so DNS resolves on the tunnel side (`--socks5-hostname` semantics). Port is 2-byte big-endian.
- Reply: parse header `[ver,rep,rsv,atyp]`, check `REP==0`, skip the variable-length bound address (IPv4=4 / domain=len+bytes / IPv6=16) + 2-byte port.
- `connect(targetHost:targetPort:)` → returns the tunnel fd, closing it on any handshake failure.
- `probe(serverHost:serverPort:)` — synchronous health check (greeting + method reply) used by `TunnelSupervisor`; closes fd via `defer`.

### Timeouts

- `connectTimeout` (10 s) bounds the TCP connect.
- `handshakeTimeout` (5 s) bounds the SOCKS exchange via `SO_RCVTIMEO`/`SO_SNDTIMEO`.
- The relay sets the fd non-blocking; note the handshake `SO_SNDTIMEO` (5 s) still applies to the first plain-HTTP request write before the relay starts (see `docs/roadmap.md`).

## Tunnel host

Default `127.0.0.1:1080` (the conventional local SOCKS5 port). It's resolved like any host; point it at whatever SOCKS5 server you run (e.g. `ssh -D 1080 user@host`).
