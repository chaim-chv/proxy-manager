# Allow-list routing

`Sources/Routing/RoutingEngine.swift`

Decides, per request host, whether to `TUNNEL` (through SOCKS5) or `DIRECT`.

## Rule model

`TargetRule { id, pattern, enabled }` (see `docs/config.md`). Rules are evaluated in list order; the first enabled match wins. No match → `DIRECT`.

The default list is **empty**. Users seed it via the first-run onboarding, a **preset** (`TargetPreset` in `Sources/Config/Presets.swift`: DeepSeek, OpenAI, Anthropic/Claude, Google Gemini, GitHub, NVIDIA), or by adding rules manually.

## Matching (`matches`)

- Case-insensitive; pattern is trimmed of trailing dots.
- **Exact**: `example.com` matches only that host.
- **Wildcard subdomain** `*.example.com` — matches the apex `example.com` **and** any `*.example.com`.
- **Leading dot** `.example.com` — treated the same as `*.example.com`.
- Host is normalized (`normalize`): lowercase, strip brackets + port for IPv6 literals (`[2001:db8::1]:443` → `2001:db8::1`), strip a numeric `:port` suffix, strip trailing dot.

## Thread safety & performance

`decide`/`matchingRule` take an `NSLock`-guarded snapshot of the precompiled rules and evaluate off-lock. `update(rules:)` compiles the list once into an **exact-match dictionary** (O(1)) plus a **wildcard list**, so a request allocates nothing and the common exact case is O(1) regardless of list size.

## Sharp edges (see `docs/roadmap.md`)

- `matches(pattern:host:)` requires an **already-normalized host** (`decide`/`matchingRule` normalize first). Passing a raw host silently fails to match; the regression harness documents this trap.
- Rule patterns containing `:port` can never match (the pattern side isn't port-stripped).
- No IDN/punycode normalization (the comment overstates it).

## Preview

`matchingRule(for:)` powers the "match preview" field in the Targets editor.
