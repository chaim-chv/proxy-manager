# Networking — sockets & SOCKS5

`Sources/Socks/Socket.swift`, `Sources/Socks/SOCKS5.swift`

## Why raw BSD sockets

`Network.framework` (`NWConnection`/`NWListener`) **honors the macOS system proxy**. Since this app sets the system proxy to `127.0.0.1:8888`, an `NWConnection` outbound connection loops back into the proxy → `Connection refused` → dead internet. **All upstream (outbound) connections must use raw BSD sockets** (`connect()`), which ignore the system proxy.

## Socket.swift

- `connect(host:port:timeout:)` — `getaddrinfo` (AF_UNSPEC → tries IPv4/IPv6 in order), non-blocking `connect()`, then `poll()` for `POLLOUT` + `SO_ERROR` to complete the connect with a timeout. Closes the fd on every failure path; `defer { freeaddrinfo(result) }`.
- `waitForWritable` — uses `poll()` (not `select`/`fd_set`, which had a `fd≥32` bit-indexing bug).
- `setNonBlocking`, `setTimeouts` (`SO_RCVTIMEO`/`SO_SNDTIMEO`).
- `recvExact`, `sendAll` — loop for partial I/O; treat `EINTR` carefully.

### Known sharp edges (see `docs/roadmap.md`)

- `sendAll` treats `EAGAIN` as fatal — fine for blocking sockets, but never call it on a non-blocking fd.
- `Int32(timeout * 1000)` overflows for very large timeouts.
- `connect` reports `strerror(errno)` after a `poll`/`SO_ERROR` path, which can show stale `EINPROGRESS` rather than the real error.

## SOCKS5.swift (RFC 1928 client)

- **No-auth only** (`[0x05,0x01,0x00]` → expect `[0x05,0x00]`).
- **Connect request uses `ATYP=0x03` (domain)** so DNS resolves on the tunnel side (`--socks5-hostname` semantics). Port is 2-byte big-endian.
- Reply: parse header `[ver,rep,rsv,atyp]`, check `REP==0`, skip the variable-length bound address (IPv4=4 / domain=len+bytes / IPv6=16) + 2-byte port.
- `connect(targetHost:targetPort:)` → returns the tunnel fd, closing it on any handshake failure.
- `probe(serverHost:serverPort:)` — synchronous health check (greeting + method reply) used by `TunnelSupervisor`; closes fd via `defer`.

### Timeouts

- `connectTimeout` (10 s) bounds the TCP connect.
- `handshakeTimeout` (5 s) bounds the SOCKS exchange via `SO_RCVTIMEO`/`SO_SNDTIMEO`.
- After the handshake, the fd's timeouts are irrelevant: the relay sets it non-blocking.

## Tunnel host

Default `127.0.0.1:1080` (the conventional local SOCKS5 port). It's resolved like any host; point it at whatever SOCKS5 server you run (e.g. `ssh -D 1080 user@host`).
