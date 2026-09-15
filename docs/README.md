# ProxyManager docs

Area-specific deep dives. **Read the relevant doc before touching that part of the code.** The entry point for agents is [`AGENTS.md`](../AGENTS.md); this directory is the detailed reference.

## Index

| Doc | Covers |
|---|---|
| [architecture.md](architecture.md) | High-level design, data flow, component inventory |
| [proxy-core.md](proxy-core.md) | HTTP CONNECT/forward proxy, relay, concurrency model |
| [networking.md](networking.md) | Raw BSD sockets, SOCKS5 client, timeouts |
| [http-parser.md](http-parser.md) | Request-line/header parsing, host/port, IPv6, rewrite |
| [routing.md](routing.md) | Allow-list matching engine |
| [telemetry.md](telemetry.md) | SQLite store, batched flush, live feed, stats |
| [system-integration.md](system-integration.md) | System proxy (networksetup), shell env injection, snapshot |
| [privileged-helper.md](privileged-helper.md) | Helper daemon, XPC protocol, authorization |
| [app-model-lifecycle.md](app-model-lifecycle.md) | State machine, enable/disable, crash recovery |
| [config.md](config.md) | JSON config store, models, snapshot persistence |
| [tunnel-supervisor.md](tunnel-supervisor.md) | SOCKS5 health probe, tunnel restart |
| [ui.md](ui.md) | SwiftUI menu bar, dashboard, settings, targets |
| [build-and-distribution.md](build-and-distribution.md) | build.sh, signing, helper embedding, CI |
| [testing.md](testing.md) | How to build/run regression harnesses |
| [debugging-logging.md](debugging-logging.md) | Unified log, debugging, revert |
| [performance.md](performance.md) | Performance model, resource footprint, hot path |
| [roadmap.md](roadmap.md) | What's left to do |

## Hard requirements (every change must respect these)

1. **Performant** — the user must not feel any change when the tunnel is working.
2. **Reliable** — no crashes, no hangs, no bugs; handle malformed input, aborts, half-closes.
3. **Never break the user's internet** — a crash must never leave the system proxy dangling.
4. **Debuggable & logged** — lifecycle + errors logged via the unified log.

See [`AGENTS.md`](../AGENTS.md) for the critical lessons learned and commands.
