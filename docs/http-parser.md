# HTTP request parsing

`Sources/Proxy/HTTPParser.swift`

`HTTPParser.parse(_ bytes:)` reads the request line + headers up to `\r\n\r\n` and returns an `HTTPRequest` (or `nil` if incomplete). `HTTPRequest` exposes `isConnect`, `host`, `port`, `scheme`, `path`, and `headerNamed`.

## Invariants (crash-safety)

- **Duplicate-case headers must not crash.** The lowercased header map is built with `Dictionary(..., uniquingKeysWith: { first, _ in first })` — never `Dictionary(uniqueKeysWithValues:)`, which traps on `Host` + `host`.
- **IPv6 literals must parse.** `splitHostPort` is bracket-aware: `[::1]:443` → host `::1`, port `443`; `[::1]` → host `::1`, default port. `lastIndex(of: ":")`/`firstIndex(of: ":")` on a bare IPv6 literal would mangle it.
- **No `target.index(after: idx)` on an invalid/end index** — `splitHostPort` only strips the port when the suffix is non-empty and numeric.

## Host/port resolution order

1. `CONNECT`: split `target` via `splitHostPort`.
2. Absolute-form (`http://`/`https://`): `URL(string:).host` / `.port`.
3. Origin-form: `Host` header via `splitHostPort`.
4. Default port: 443 for `CONNECT`/`https`, else 80.

## `rewrite(request)` — plain HTTP forwarding

Converts an absolute-form request to origin-form (`path` instead of absolute URL), strips hop-by-hop/proxy headers (`Proxy-Connection`, `Proxy-Authorization`, `Connection`, `Keep-Alive`, `TE`, `Trailer`, `Transfer-Encoding`, `Upgrade`, and any `Host`), re-adds `Host`, and forces `Connection: close`. This is what keeps CLI tools (which can't speak SOCKS5) working for allow-listed plain HTTP.

## Known limitations (see `docs/roadmap.md`)

- No header-count/size cap in `parse` (the caller's `readHeader` caps total bytes at 64 KB).
- Non-UTF8 header bytes make `parse` return `nil` (treated as "incomplete") rather than a deterministic 400.
- `findHeaderEnd` only matches `CRLFCRLF`, not bare-`LF` terminators.
- Missing `Host` yields an empty host (no 400).

## Tests

See `docs/testing.md` — a parser harness exercises duplicate-case headers and IPv6 host/port extraction.
