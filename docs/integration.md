# External integration

ProxyManager can be controlled from another app, a Shortcut, or the OS. The
surface is deliberately small: **routing on/off, targets, per-app rules, status
reads, and opening a window or pane**. The tunnel, the local proxy listener,
system integration, appearance, monitoring and config import/export are not
exposed — those stay UI-only.

The source of truth for the action list is `Sources/Integration/IntegrationAction.swift`.
`capabilities` returns the same data at runtime.

> **Status:** the router, the local control socket and the XPC agent are
> implemented. The URL scheme (P2) and App Intents (P3) adapters are next; the
> registry already records which actions they may expose.

## Architecture

```
 third-party app / CLI
        │  Mach "com.proxymanager.control"
        ▼
 control agent (per-user LaunchAgent, unprivileged)
        │  identity: pid → SecCode → designated requirement
        │  relay: length-prefixed JSON
        ▼
 ProxyManager.app
   control.sock (0600, same UID, per-launch token)
        ▼
 IntegrationRouter → authorization → validation → rate limit → AppModel
```

- **One router.** Adapters parse a transport and call `IntegrationRouter.perform`.
  Validation, authorization, rate limiting and auditing live in one place so a
  new transport cannot bypass a rule.
- **The agent owns no state.** It only proves who is calling and relays.
- **The socket is the app's real endpoint.** It also works in an ad-hoc build,
  which is what makes the feature testable without a Developer ID.

## Security model

| Scope | Actions |
|---|---|
| `read` | every `*.list`, `status`, `routing.explain`, `apps.resolve`, window navigation |
| `control` | `read` + `routing.*`, `targets.*`, `presets.apply`, `apps.*` |

- **Per-identity consent.** The first request from an unknown code identity
  shows a sheet with *Allow Control / Read Only / Deny*. The decision is stored
  in `integration-permissions.json` (`0600`) keyed by the **designated
  requirement**, not the bundle id, so a different binary claiming the same
  bundle id is asked again. Revoke in Settings → Integration.
- **No prompts, ever.** Every external call runs with `userInitiated: false`.
  An external `routing.enable` cannot raise the administrator dialog; that is a
  phishing primitive. If a privileged action is needed it is deferred, exactly
  as for a background launch.
- **No secrets.** Nothing in the action list accepts a password, a key, or a
  tunnel endpoint. The SSH password is UI-only.
- **Same-user boundary.** The socket is `0600` and the agent checks the caller's
  identity, but a process already running as the same user can read the token.
  This protects against accidental control and unapproved apps, not against
  malware running as you.
- **Rate limits.** 240 reads/min and 30 mutations/min per caller, with a
  separate 6/min bucket for `routing.toggle` because each one runs `networksetup`.
- **Audit.** `integration-audit.jsonl` (`0600`, 2 MiB × 5) records caller,
  action, redacted arguments, outcome and duration. Secrets are redacted by key.

## Transports

### XPC agent (production)

- Mach service: `com.proxymanager.control`
- LaunchAgent: `Contents/Library/LaunchAgents/com.proxymanager.control-agent.plist`
- Binary: `Contents/Library/HelperTools/com.proxymanager.control-agent`
- Registered with `SMAppService.agent(plistName:)` when Settings → Integration →
  *Allow XPC clients* is on. Registration is silent; the item appears in
  **Login Items & Extensions**.
- **Requires a Developer-ID signed build.** `SMAppService` refuses to register an
  agent without a Team ID, so an ad-hoc build reports *XPC agent unavailable*.
  The socket still works for development.
- Sandboxed clients need
  `com.apple.security.temporary-exception.mach-lookup.global-name =
  com.proxymanager.control`. Unsandboxed apps and CLIs need nothing.

### Local socket (development and tests)

- Path: `~/Library/Application Support/ProxyManager/control.sock` (`0600`)
- Token: `…/control.token` (`0600`), regenerated on every launch
- Frame: 4-byte big-endian length + UTF-8 JSON, 256 KB cap; 5 s request timeout, 25 s reply (consent can wait)
- Peer: same UID only (`getpeereid`)

Envelope:

```json
{ "v": 1, "token": "…",
  "identity": { "pid": 4711, "bundleID": "com.acme.tool", "teamID": "ABCDE12345",
                "requirement": "identifier \"com.acme.tool\" and anchor apple generic",
                "displayName": "Acme Tool", "path": "/Applications/Acme Tool.app" },
  "request": { "v": 1, "id": "…", "action": "targets.add",
               "args": { "pattern": "api.example.com" } } }
```

The app answers with `{ "v": 1, "result": { … } }`.

### XPC client

```swift
@objc protocol ControlAgentProtocol {
    func ping(withReply reply: @escaping (Bool) -> Void)
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

let connection = NSXPCConnection(machServiceName: "com.proxymanager.control")
connection.remoteObjectInterface = NSXPCInterface(with: ControlAgentProtocol.self)
connection.resume()
let agent = connection.remoteObjectProxyWithErrorHandler { error in
    // service unavailable, or the app could not be launched
} as! ControlAgentProtocol

agent.perform(try JSONEncoder().encode(request)) { data in
    let result = try JSONDecoder().decode(IntegrationResult.self, from: data)
}
```

`perform` carries the same `IntegrationRequest` JSON as the socket, minus the
token and identity: the agent supplies those. The first call from an unknown
app blocks on the consent sheet, so give the XPC call a generous timeout.

## Actions

`risk` is `read`, `ui` or `policy`. Mutations are idempotent and report
`changed`. Arguments marked `?` are optional.

| Action | Arguments | Risk |
|---|---|---|
| `ping` | — | read |
| `capabilities` | — | read |
| `status` | — | read |
| `routing.explain` | `host`, `bundleID?` | read |
| `routing.enable` | — | policy |
| `routing.disable` | — | policy |
| `routing.toggle` | — | policy |
| `routing.retry` | — | policy |
| `targets.list` | `enabledOnly?` | read |
| `targets.add` | `pattern`, `enabled?` | policy |
| `targets.remove` | `id` **or** `pattern` | policy |
| `targets.update` | `id`, `pattern?`, `enabled?` | policy |
| `targets.clear` | `confirm=true` | policy |
| `presets.list` | — | read |
| `presets.apply` | `name` | policy |
| `apps.list` | — | read |
| `apps.setEnabled` | `enabled` | policy |
| `apps.setDefault` | `mode` (`TUNNEL`/`TARGETS`/`DIRECT`) | policy |
| `apps.rule.set` | `key`, `keyKind`, `mode`, `enabled?` | policy |
| `apps.rule.remove` | `id` **or** `key`+`keyKind` | policy |
| `apps.resolve` | `bundleID` **or** `path` **or** `pid` | read |
| `ui.open` | `pane`, `section?`, `revealPattern?`, `revealAppRuleID?` | ui |
| `app.activate` | `pane?` | ui |

Validation notes:

- A target pattern is lowercased, port-stripped and trailing-dot-trimmed; only
  one leading `*.` wildcard is accepted; the list is capped at 500 rules.
- Unknown arguments are rejected, so a typo fails loudly.
- `apps.rule.set` never enables per-app routing as a side effect.
- `ui.open` with `section` requires `pane=settings`.

## Results and errors

```json
{ "v": 1, "id": "…", "action": "targets.add", "ok": true, "changed": true,
  "data": { "id": "…", "pattern": "api.example.com" },
  "error": null, "auditId": "…", "durationMs": 12 }
```

Stable error codes: `bad_request`, `unknown_action`, `invalid_argument` (with
`field`), `unauthorized`, `forbidden`, `not_found`, `conflict`, `busy`,
`timeout`, `unavailable`, `unsupported`, `shutting_down`,
`requires_user_action`, `internal`.

`v` in a request newer than the app's `IntegrationProtocol.version` is refused
with `unsupported`.

## Enabling and diagnostics

Settings → **Integration**:

- master switch (off by default)
- XPC clients toggle and registration state
- audit log toggle
- approved identities with **Revoke**
- live socket state

Unified log: `log stream --predicate 'subsystem == "com.proxymanager.app" AND category == "integration"'`.

## Tests

`Tests/IntegrationHarness` covers the exposure matrix, validation,
idempotency, the 500-rule cap, rate limits, audit redaction, the permission
store, framing and a full socket round trip.

```bash
./Tests/run-all.sh
```
