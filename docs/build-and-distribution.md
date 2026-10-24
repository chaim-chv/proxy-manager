# Build, signing & distribution

`build.sh`, `.github/workflows/release.yml`

## Build (`build.sh <version>`)

- No Xcode project — compiles all `Sources/**/*.swift` (except `Sources/Helper/`) with `xcrun swiftc -swift-version 5 -O -target <arch>-apple-macosx14.0`.
- **Two binaries**: the app (`Contents/MacOS/ProxyManager`) and the helper daemon (`Contents/Library/HelperTools/com.proxymanager.helper`), plus the daemon's plist at `Contents/Library/LaunchDaemons/com.proxymanager.helper.plist` whose `BundleProgram` points at `Contents/Library/HelperTools/com.proxymanager.helper` (the canonical `SMAppService.daemon` layout).
- Links and embeds the vendored **Sparkle** framework (`Vendor/Sparkle/Sparkle.framework` → `Contents/Frameworks/`), adds the `@executable_path/../Frameworks` rpath to the app only, and writes the `SUFeedURL` / `SUPublicEDKey` / auto-update keys into `Info.plist`.
- Generates `Info.plist` (bundle id `com.proxymanager.app`) with `CFBundleShortVersionString` / `CFBundleVersion` = `<version>` and `BuildDate` = the UTC build date (`YYYY-MM-DD`, override with `BUILD_DATE`), copies `Resources/*.lproj`, then signs **inside-out** with `--options runtime` (Sparkle XPC services → `Autoupdate` → `Updater.app` → framework → helper → app). `--deep` is intentionally **not** used — it is deprecated and would smear Sparkle's XPC entitlements. See [updates.md](updates.md).

### Options

| Env | Effect |
|---|---|
| `ARCH` | Override target arch (default `uname -m`) |
| `BUILD_DATE` | Override the `BuildDate` stamped into `Info.plist` (default UTC today, `YYYY-MM-DD`) |
| `SPARKLE_DIR` | Path to the vendored Sparkle framework (default `Vendor/Sparkle`) |
| `UNIVERSAL=1` | Build arm64 + x86_64 and `lipo` them |
| `IDENTITY="Developer ID Application: …"` | Sign with a Developer ID (required for the helper daemon to register) |

## Signing / helper

> **Helper layout (canonical `SMAppService.daemon`):** the daemon binary is built into `Contents/Library/HelperTools/com.proxymanager.helper`; `Contents/Library/LaunchDaemons/com.proxymanager.helper.plist` carries `BundleProgram` pointing at it, and both the app and helper are signed `--options runtime` with the same identity/Team ID. An ad-hoc build prints a warning that the helper cannot register (ad-hoc signatures carry no Team ID) and that direct `networksetup` is used instead; see [`tasks/authd-unlock-deadlock/`](tasks/authd-unlock-deadlock/README.md).

- Ad-hoc signing (`-`) is fine for development; the helper daemon can't register via `SMAppService.daemon` without a Developer ID/Team ID, so the app runs `networksetup` **directly as the current user** (prompt-free — per-user proxy settings need no root). If that fails, the app **defers**; it only shows the elevated `osascript` dialog for an explicit user action in an interactive session.
- For the full experience: `IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh 1.0.0`, install to `/Applications`. Settings → System → **Administrator access** installs/approves the daemon once; after that toggles use it without prompting.

## CI (`release.yml`)

Builds on `macos-latest` on tag push or `workflow_dispatch` (version input), packages `ProxyManager.app` with `ditto` (preserves framework symlinks), signs the archive and generates `appcast.xml` with Sparkle's `generate_appcast`, and creates a GitHub release with a changelog (`.github/scripts/changelog.sh`, Conventional Commits) plus the zip and the appcast feed. Requires the `SPARKLE_PRIVATE_KEY` secret for the feed; without it the release ships update-less with a warning. See [updates.md](updates.md).

## Distribution status

Not notarized (documented in release notes). Self-updates via Sparkle from GitHub releases. Homebrew cask / DMG not yet set up (see `docs/roadmap.md`).
