# Build, signing & distribution

`build.sh`, `.github/workflows/release.yml`

## Build (`build.sh <version>`)

- No Xcode project — compiles all `Sources/**/*.swift` (except `Sources/Helper/`) with `xcrun swiftc -swift-version 5 -O -target <arch>-apple-macosx14.0`.
- **Two binaries**: the app (`Contents/MacOS/ProxyManager`) and the helper daemon (`Contents/Library/LaunchDaemons/com.proxymanager.helper`), plus the daemon's `com.proxymanager.helper.plist`.
- Links and embeds the vendored **Sparkle** framework (`Vendor/Sparkle/Sparkle.framework` → `Contents/Frameworks/`), adds the `@executable_path/../Frameworks` rpath to the app only, and writes the `SUFeedURL` / `SUPublicEDKey` / auto-update keys into `Info.plist`.
- Generates `Info.plist` (bundle id `com.proxymanager.app`) with `CFBundleShortVersionString` / `CFBundleVersion` = `<version>` and `BuildDate` = the UTC build date (`YYYY-MM-DD`, override with `BUILD_DATE`), copies `Resources/*.lproj`, then signs **inside-out** (Sparkle XPC services → `Autoupdate` → `Updater.app` → framework → helper → app). `--deep` is intentionally **not** used — it is deprecated and would smear Sparkle's XPC entitlements. See [updates.md](updates.md).

### Options

| Env | Effect |
|---|---|
| `ARCH` | Override target arch (default `uname -m`) |
| `BUILD_DATE` | Override the `BuildDate` stamped into `Info.plist` (default UTC today, `YYYY-MM-DD`) |
| `SPARKLE_DIR` | Path to the vendored Sparkle framework (default `Vendor/Sparkle`) |
| `UNIVERSAL=1` | Build arm64 + x86_64 and `lipo` them |
| `IDENTITY="Developer ID Application: …"` | Sign with a Developer ID (required for the helper daemon to register) |

## Signing / helper

- Ad-hoc signing (`-`) is fine for development; the helper daemon can't register via `SMAppService.daemon` without a Developer ID, so the app runs `networksetup` **directly as the current user** (prompt-free — per-user proxy settings need no root). The elevated `osascript` dialog is only used if that direct path fails.
- For the full experience: `IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh 1.0.0`, install to `/Applications`. First toggle prompts once to install the daemon.

## CI (`release.yml`)

Builds on `macos-latest` on tag push or `workflow_dispatch` (version input), packages `ProxyManager.app` with `ditto` (preserves framework symlinks), signs the archive and generates `appcast.xml` with Sparkle's `generate_appcast`, and creates a GitHub release with a changelog (`.github/scripts/changelog.sh`, Conventional Commits) plus the zip and the appcast feed. Requires the `SPARKLE_PRIVATE_KEY` secret for the feed; without it the release ships update-less with a warning. See [updates.md](updates.md).

## Distribution status

Not notarized (documented in release notes). Self-updates via Sparkle from GitHub releases. Homebrew cask / DMG not yet set up (see `docs/roadmap.md`).
