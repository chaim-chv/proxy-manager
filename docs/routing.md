# Allow-list routing

`Sources/Routing/RoutingEngine.swift`; the proxy applies the decision in `Sources/Proxy/ProxyServer.swift`.

Decides, per request host, whether to `TUNNEL` (through SOCKS5) or `DIRECT`.

`RoutingEngine` only returns `TUNNEL`/`DIRECT`. The proxy can additionally record route `BLOCK` for two cases it decides itself: a **non-loopback** client targeting a loopback/link-local/RFC1918 host (SSRF guard, `403`), and tunnel-down with `policy.failClosedWhenTunnelDown` — default `false` = **fail-open** (fall back to `DIRECT`, tagged `tunnel_down`); `true` = **fail-closed** (`502`).

## Per-app routing (opt-in)

When `apps.enabled` is true, the decision can also depend on the **originating
app** (see `docs/per-app-rules.md`). `ProxyServer` resolves the app identity only
when `RoutingEngine.needsAppIdentity` (enabled **and** ≥1 enabled rule), then
calls `decide(host:app:)`:

- a matching app rule's mode wins — `TUNNEL` (`Tunnel all`), `DIRECT`
  (`Direct all`), or `TARGETS` (fall through to the host allow-list);
- otherwise `apps.defaultMode` applies (`TARGETS` by default, preserving today's
  behaviour; `DIRECT`/`TUNNEL` give a per-app-VPN model).

With per-app routing off (the default), `decide(host:app:)` is exactly
`decide(host:)` and no identity scan runs. Rule keys are matched bundle id →
executable path → executable name; the first enabled rule for a key wins. An
unresolved app still honours a `DIRECT`/`TUNNEL` default (no leak through the
host allow-list).

## Rule model

`TargetRule { id, pattern, enabled }` (see `docs/config.md`). Enabled rules compile into an **exact-match dictionary** plus an ordered **wildcard list**; `decide` checks exact first, then wildcards in list order. No match → `DIRECT`.

The default list is **empty**. Users seed it via the first-run onboarding, a **preset** (`TargetPreset` in `Sources/Config/Presets.swift`: DeepSeek, OpenAI, Anthropic/Claude, Google Gemini, GitHub, NVIDIA, WhatsApp), or by adding rules manually.

## Matching (`matches`)

- Case-insensitive; pattern is trimmed of trailing dots.
- **Exact**: `example.com` matches only that host.
- **Wildcard subdomain** `*.example.com` — matches the apex `example.com` **and** any subdomain at any depth (`api.example.com`, `a.b.example.com`).
- **Leading dot** `.example.com` — treated the same as `*.example.com`.
- Host is normalized (`normalize`): lowercase, strip brackets + port for IPv6 literals (`[2001:db8::1]:443` → `2001:db8::1`), strip a numeric `:port` suffix, strip trailing dot.

## Thread safety & performance

`decide`/`matchingRule` take an `NSLock`-guarded snapshot of the precompiled rules and evaluate off-lock. `update(rules:)` compiles the list once into an **exact-match dictionary** (O(1)) plus a **wildcard list**, so a request allocates nothing and the common exact case is O(1) regardless of list size.

## Sharp edges (see `docs/roadmap.md`)

- `matches(pattern:host:)` requires an **already-normalized host** (`decide`/`matchingRule` normalize first). Passing a raw host silently fails to match; the regression harness documents this trap.
- Rule patterns containing `:port` can never match (the pattern side isn't port-stripped).
- No IDN/punycode normalization; a non-ASCII host must be written in its ASCII/punycode form to match.

## Preview

`matchingRule(for:)` powers the "match preview" field in the Targets editor.
