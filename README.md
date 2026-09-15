# Proxy Manager

[![Build](https://img.shields.io/github/actions/workflow/status/chaim-chv/proxy-manager/release.yml?label=build)](https://github.com/chaim-chv/proxy-manager/actions)
[![License](https://img.shields.io/github/license/chaim-chv/proxy-manager)](./LICENSE)

A native macOS menu-bar app that routes **only the hostnames you choose** through an existing SOCKS5 proxy/tunnel — while leaving all other traffic untouched.

- **Single on/off switch** in the menu bar (⌘L) or the Dashboard.
- **Local domain-aware proxy** (`127.0.0.1:8888`) that tunnels allow-listed hosts through your SOCKS5 proxy and passes everything else through directly.
- **System integration**: sets the macOS system proxy (prompt-free `networksetup`, or the optional privileged helper when installed) and exports shell/CLI environment variables, so browsers, `curl`, `node`/`bun`, and system apps all honor the routing — nothing else is rerouted.
- **Crash watchdog**: a tiny always-on helper restores your original proxy settings if the app is force-quit or crashes while routing is on, so your internet never stays pointed at a dead local proxy (~0% idle CPU; disable in Settings → System).
- **First-run onboarding** that walks you through pointing the app at your tunnel and choosing what to route.
- **Run the tunnel for you**: the app can start and supervise an SSH SOCKS5 tunnel (key file or password auth, stored in Keychain), keeping it alive automatically.
- **Live monitoring**: per-request feed with route decision, host, method, bytes, latency, status; per-route and per-host stats.
- **Presets** (DeepSeek, OpenAI, Anthropic/Claude, Google Gemini, GitHub, NVIDIA, WhatsApp) to get started fast, plus full manual control.
- **Self-updating**: Sparkle 2 checks for new versions in the background (Never/Daily/Weekly in Settings → General → Updates) and always asks before installing.
- **No MITM.** TLS is pass-through; the app never sees plaintext payloads.

## What it is, in plain words

- **HTTP proxy** — a local middleman your apps talk to. This app runs one at `127.0.0.1:8888`; it opens the real connection on the app's behalf.
- **SOCKS5 proxy / tunnel** — a lower-level pipe, often created over SSH (`ssh -D`). Traffic you send into it comes out on a remote server.
- **What this app does** — connects your apps to that SOCKS5 tunnel, but only for the hostnames on your list. Everything else goes direct.

```
Browser / CLI ──▶ Local HTTP CONNECT proxy (127.0.0.1:8888)
                       │
                       ├─ host in allow-list? ── YES ──▶ your SOCKS5 proxy
                       │
                       └──────────────────────── NO ──▶ direct connection
```

The local proxy is a *policy router*, not a MITM: `CONNECT` requests are relayed byte-for-byte through the SOCKS5 tunnel, and plain-HTTP proxied requests are rewritten to origin form and streamed with backpressure (preserving SSE streaming from LLM APIs).

## Requirements

- macOS 14.0 or later (uses `Charts`, `SMAppService`).
- An existing SOCKS5 proxy (e.g. `ssh -D 1080 user@host`, `ssh -D` via `autossh`, or any SOCKS5 server you already run). You can also let the app run and supervise the SSH tunnel for you (see [Run the tunnel for me](#run-the-tunnel-for-me-ssh)).

## Installation

### Build from source

Requires only the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh 1.0.0        # version as a parameter
```

This produces `ProxyManager.app` in the current directory. Drag it to `/Applications` and launch.

Build a universal (arm64 + x86_64) binary:

```bash
UNIVERSAL=1 ./build.sh 1.0.0
```

### Proxy toggles are prompt-free

Enabling/disabling never pops a password dialog on a normal setup. Mutations run `networksetup` with the least privilege that works (see `docs/system-integration.md`): the privileged helper daemon when installed, otherwise `networksetup` **directly as your user** — HTTP(S)/PAC proxy settings for your network services are per-user and need no root (this is why `./revert.sh` never asks for a password). The elevated `osascript` admin dialog is only a last resort when direct access genuinely fails (e.g. a non-admin account).

So by default `build.sh` ad-hoc signing needs no admin approval at all. The privileged helper is an optional hardening for signed, `/Applications` installs:

```bash
IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh 1.0.0
```

Requirements for the helper to register (via `SMAppService.daemon`, macOS 13+):
- The app **must** be installed in `/Applications` and signed with a Developer ID (same Team ID as the embedded `com.proxymanager.helper` daemon).
- The first toggle still shows a single admin-approval prompt to install the daemon; subsequent toggles are silent.

The embedded daemon (`Contents/Library/LaunchDaemons/com.proxymanager.helper`) validates all arguments, passes `networksetup` argv arrays directly (no shell), and only ever points the proxy at `127.0.0.1`.

### From a release

Download `ProxyManager-<version>.zip` from the [Releases](https://github.com/chaim-chv/proxy-manager/releases/latest) page, unzip, and drag `ProxyManager.app` to `/Applications`.

> [!NOTE]
> The app is not notarized by Apple. On first launch you may need to go to System Settings → Privacy & Security and click "Open Anyway".

Once installed, Proxy Manager updates itself via Sparkle — use **Check for Updates…** in the menu bar or Settings → General → Updates.

## Usage

1. On first launch, the **onboarding guide** asks for your SOCKS5 tunnel address and which hosts to route, then offers to enable routing. (Re-open it any time from Settings → General → "Run setup again".)
2. Click the menu-bar icon and toggle **Routing** (or press ⌘L).
3. Open the **Dashboard** (⌘D) to watch live traffic and route decisions.
4. Edit **Targets** in Settings to change which hostnames are tunneled, or apply a preset.

When enabled, the app also writes `~/.config/proxy-manager/env.sh` and adds a guarded `source` line to your shell rc files, so **new** terminal sessions pick up `HTTP_PROXY`/`HTTPS_PROXY` for CLI tools that can't speak SOCKS5 directly (Node/undici, `bun`, `curl`).

### Run the tunnel for me (SSH)

In Settings → Tunnel, switch to **"Run the tunnel for me"** and fill in the SSH host, port, username, and either a key file path or a password (stored in the macOS Keychain). The app then runs `ssh -N -D <socksHost>:<socksPort> <username>@<sshHost>` in the background, supervises it, and restarts it automatically if the connection drops (with backoff). Key-file auth is preferred; for password auth the app feeds the Keychain password to `ssh` via a one-shot askpass helper — it's never put on the command line.

## Configuration

The app's configuration lives in `~/Library/Application Support/ProxyManager/config.json` (it can also be edited in the sidebar-based Settings UI, which is the recommended way):

```jsonc
{
  "version": 1,
  "proxy": { "bindHost": "127.0.0.1", "port": 8888 },
  "tunnel": {
    "mode": "MANUAL",            // or "MANAGED" to run an SSH tunnel for you
    "host": "127.0.0.1", "port": 1080, "supervised": false, "launchdLabel": "",
    "managed": { "sshHost": "", "sshPort": 22, "username": "", "auth": "KEY",
                 "keyPath": "", "socksHost": "127.0.0.1", "socksPort": 1080 }
  },
  "policy": { "failClosedWhenTunnelDown": false },   // false = fail-open
  "system": { "injectShellEnv": true, "launchAtLogin": false, "restoreOnQuit": true,
              "crashWatchdog": true, "colorizeMenuIcon": true, "appearanceMode": "SYSTEM",
              "iconMode": "MENU_BAR_AND_DOCK", "managedShellRcs": ["~/.zshrc"] },
  "targets": [],                                      // empty by default — add your own
  "monitor": { "retentionDays": 7, "maxRows": 500000, "recordPaths": true },
  "lock": { "enabled": false }
}
```

- **targets** — the allow-list. Empty by default; use onboarding, a preset, or add rules manually. Wildcard `*.example.com` also matches the apex `example.com`.
- **tunnel.mode** — `MANUAL` (point at your own tunnel) or `MANAGED` (the app runs the SSH tunnel for you).
- **tunnel.launchdLabel** — in `MANUAL` mode, if your tunnel is a launchd job, set its label (e.g. `com.user.autossh_socks`) and enable "Supervised by app" to unlock the "Restart tunnel" button.
- **system** — shell-env injection and the rc files it manages (`managedShellRcs`, default `~/.zshrc`), launch-at-login, quit/watchdog behavior, and appearance (`colorizeMenuIcon`, `appearanceMode`, `iconMode`).

Telemetry is stored in `~/Library/Application Support/ProxyManager/telemetry.sqlite` (SQLite/WAL). Metadata only — no request bodies or headers are captured.

## Development

```bash
./build.sh            # default version 1.0.0
open ProxyManager.app
```

Compile a single binary for quick iteration:

```bash
find Sources -name '*.swift' -not -path 'Sources/Helper/*' -print0 | sort -z | xargs -0 \
  xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework SwiftUI -framework Charts \
  -framework Network -framework ServiceManagement -framework Security \
  -F Vendor/Sparkle -framework Sparkle \
  -Xlinker -rpath -Xlinker "$PWD/Vendor/Sparkle" \
  -o /tmp/proxymanager && /tmp/proxymanager
```

## Project structure

```
ProxyManager/
├── build.sh                      # build script (version as parameter)
├── revert.sh                     # emergency: undo all app effects
├── Sources/
│   ├── App.swift                 # @main SwiftUI app + menu bar
│   ├── AppModel.swift            # app-wide state machine + wiring
│   ├── Config/                   # JSON config store + models + presets
│   ├── Routing/                  # allow-list matching engine
│   ├── Socks/                    # POSIX sockets + RFC 1928 SOCKS5 client
│   ├── Proxy/                    # HTTP CONNECT / forwarding proxy core
│   ├── System/                   # system proxy (helper/direct/osascript) + XPC + shell env
│   ├── Tunnel/                   # SOCKS5 health probe + supervisor + SSH runner + Keychain
│   ├── Telemetry/                # SQLite store + live feed
│   ├── Helper/                   # privileged helper daemon (separate binary)
│   ├── Support/                  # unified-log logger + crash watchdog
│   └── UI/                       # dashboard, settings, targets, onboarding, updater
├── Resources/                    # localizations
├── Vendor/Sparkle/               # vendored Sparkle 2 auto-update framework
├── Tests/                        # standalone regression harnesses + crash probes
├── docs/                         # area-specific deep dives
└── .github/                      # release workflow + changelog script
```

## Security & privacy

- Local-only bind (`127.0.0.1`); no remote exposure.
- TLS is passed through untouched; metadata only (host, size, timing, status).
- The SSH password (if you use "Run the tunnel for me") is stored in the macOS Keychain — never in `config.json` or on a command line. Key-file auth stores nothing.
- `Proxy-Authorization` headers are stripped in plain-HTTP forwarding and never logged.

## Credits & License

100% vibe-coded by [@chaim-chv](https://github.com/chaim-chv/) © 2026.  
As an agentic harness, I use [**OpenCode**](https://opencode.ai/) with a personally developed set of agents, skills, and plugins.  
For LLM models, I use **DeepSeek V4** (mostly Flash at default reasoning effort, with some Pro at high reasoning effort for complex tasks) via the [DeepSeek](https://platform.deepseek.com/) API.  
Released under the [MIT License](LICENSE).
