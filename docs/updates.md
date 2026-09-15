# Updates (Sparkle)

`Vendor/Sparkle/`, `Sources/UI/UpdaterController.swift`, `build.sh`, `.github/workflows/release.yml`

Proxy Manager ships its own updater using [Sparkle 2](https://sparkle-project.org)
(vendored, see [`Vendor/Sparkle/README.md`](../Vendor/Sparkle/README.md)). No
Apple Developer account, domain, or server is required — the update feed is a
static file attached to each GitHub release.

## How it works

1. On launch the app starts `SPUStandardUpdaterController` (in
   `UpdaterController.swift`), which reads `SUFeedURL` and `SUPublicEDKey` from
   `Info.plist`.
2. Sparkle checks the feed in the background. The user picks the cadence in
   Settings → General → Updates: **Never / Daily / Weekly** (default **Daily**).
   `SUAutomaticallyUpdate` is `NO`, so it always asks before installing. The
   choice maps onto `SPUUpdater.automaticallyChecksForUpdates` +
   `updateCheckInterval`; the Info.plist keys (`SUEnableAutomaticChecks`,
   `SUScheduledCheckInterval` = 86400) are only the initial default.
3. The feed (`appcast.xml`) lists the newest version and its download URL plus a
   Sparkle EdDSA signature. The signature is verified against the public key in
   the **old** app; a valid EdDSA signature is sufficient — Developer ID code
   signing is not required (ad-hoc is accepted).
4. On install, Sparkle quits the app, replaces it, and relaunches. Sparkle strips
   the quarantine flag, so the relaunched app does not hit Gatekeeper.

`SPUStandardUpdaterController` is only touched from the normal app path — the
`--watchdog` mode never loads it (see `App.swift`), keeping the watchdog lean.

## UI

| Where | What |
|---|---|
| Settings → General → Updates | "Check for updates" frequency popup (Never / Daily / Weekly, default Daily), current version, and a "Check for Updates…" button. |
| Status menu | "Check for Updates…" (between About and Quit). |

The manual check controls are disabled while a check is already running, driven
by `SPUUpdater.canCheckForUpdates`.

## Lifecycle interaction (important)

Installing an update **relaunches the app**, and this app owns the system proxy:

- Sparkle asks the app to terminate → `applicationWillTerminate` →
  `AppModel.shutdownForQuit()` restores the original system proxy and disarms
  the watchdog. The user keeps working internet during the install.
- On relaunch, `wasOnKey` auto-re-enables routing if it was on.

Because `shutdownForQuit()` runs bounded synchronous admin work, a slow
`networksetup` can delay the quit; Sparkle tolerates a short delay. The crash
watchdog remains the backstop if the app is killed mid-install.

## Keys

One EdDSA key pair per project (`Vendor/Sparkle/bin/generate_keys`):

- **Public key** — committed at `Vendor/Sparkle/public_ed_key.txt`, embedded as
  `SUPublicEDKey` by `build.sh`. Safe to share.
- **Private key** — lives in the maintainer's login Keychain and in the
  `SPARKLE_PRIVATE_KEY` GitHub Actions secret. Never commit it.

Export/import for a new machine or to restore:

```bash
Vendor/Sparkle/bin/generate_keys -x /tmp/sparkle.key   # export (keep safe)
Vendor/Sparkle/bin/generate_keys -f /tmp/sparkle.key   # import elsewhere
```

Losing the private key means existing installs can no longer be updated (Sparkle
only supports key rotation, not key loss, without Developer ID). Back it up.

## Release flow (`.github/workflows/release.yml`)

1. `./build.sh <version>` — links, embeds, and signs Sparkle.
2. Package with `ditto -c -k --sequesterRsrc --keepParent` (**not** `zip -r`:
   a plain zip follows the framework symlinks and breaks the code signature).
3. `Vendor/Sparkle/bin/generate_appcast --ed-key-file <key>` signs the archive
   and writes `updates/appcast.xml` with an `enclosure` URL pointing at the
   release asset.
4. Attach `appcast.xml` to the release. The app's `SUFeedURL` is
   `https://github.com/chaim-chv/proxy-manager/releases/latest/download/appcast.xml`,
   so `latest/download/appcast.xml` always resolves to the newest feed.

If `SPARKLE_PRIVATE_KEY` is unset the workflow warns and ships the release
without a feed (that version will not be offered as an update).

## build.sh changes

- Links `-F Vendor/Sparkle -framework Sparkle` and adds the
  `@executable_path/../Frameworks` rpath **for the app only** (the helper daemon
  must not link Sparkle).
- Copies `Sparkle.framework` into `Contents/Frameworks/` with `ditto`.
- Adds `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`,
  `SUAutomaticallyUpdate`, `SUScheduledCheckInterval` to `Info.plist`.
- Signs **inside-out** (Sparkle XPC services → `Autoupdate` → `Updater.app` →
  framework → helper → app). `--deep` is deliberately not used: it is deprecated
  and would smear the XPC services' entitlements across the framework.

## Testing an update

1. Install an older build (or temporarily lower `CFBundleVersion`).
2. Clear the last-check time: `defaults delete com.proxymanager.app SULastCheckTime`.
3. Launch, use **Check for Updates…**, and watch the unified log:
   `log stream --predicate 'subsystem == "com.proxymanager.app"' --level debug`.

## Caveats without an Apple Developer account

- The app is **not notarized**: the *first* manual download needs
  right-click → Open. Updates install cleanly (Sparkle clears quarantine).
- The privileged helper cannot register via `SMAppService.daemon` without a
  Developer ID; the app falls back to `networksetup` (see
  [privileged-helper.md](privileged-helper.md)).
- Releases are arm64-only unless built with `UNIVERSAL=1`; `generate_appcast`
  records `sparkle:hardwareRequirements` accordingly.
