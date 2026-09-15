# Build, signing & distribution

`build.sh`, `.github/workflows/release.yml`

## Build (`build.sh <version>`)

- No Xcode project — compiles all `Sources/*.swift` (except `Sources/Helper/`) with `xcrun swiftc -swift-version 5 -O -target <arch>-apple-macosx14.0`.
- **Two binaries**: the app (`Contents/MacOS/ProxyManager`) and the helper daemon (`Contents/Library/LaunchDaemons/com.proxymanager.helper`), plus the daemon's `com.proxymanager.helper.plist`.
- Generates `Info.plist` (bundle id `com.proxymanager.app`), copies `Resources/*.lproj`, then `codesign --force --deep`.

### Options

| Env | Effect |
|---|---|
| `ARCH` | Override target arch (default `uname -m`) |
| `UNIVERSAL=1` | Build arm64 + x86_64 and `lipo` them |
| `IDENTITY="Developer ID Application: …"` | Sign with a Developer ID (required for the helper daemon to register) |

## Signing / helper

- Ad-hoc signing (`-`) is fine for development; the helper daemon can't register via `SMAppService.daemon` without a Developer ID, so the app runs `networksetup` **directly as the current user** (prompt-free — per-user proxy settings need no root). The elevated `osascript` dialog is only used if that direct path fails.
- For the full experience: `IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh 1.0.0`, install to `/Applications`. First toggle prompts once to install the daemon.

## CI (`release.yml`)

Builds on `macos-latest` on tag push or `workflow_dispatch` (version input), zips `ProxyManager.app`, and creates a GitHub release with a changelog (`.github/scripts/changelog.sh`, Conventional Commits).

## Distribution status

Not notarized (documented in release notes). Homebrew cask / DMG not yet set up (see `docs/roadmap.md`).
