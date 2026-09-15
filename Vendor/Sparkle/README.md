# Sparkle (vendored)

[Sparkle](https://sparkle-project.org) is the macOS update framework. This
directory contains the prebuilt distribution so builds are reproducible and work
offline — `build.sh` links and embeds `Sparkle.framework`, and the release
workflow uses `bin/` to sign and publish updates.

- **Version:** 2.10.0 (requires macOS 12.0+; this app targets macOS 14.0+)
- **Source:** <https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0>
- **License:** see [LICENSE](LICENSE)

## What's here

| Path | Purpose |
|---|---|
| `Sparkle.framework` | Linked and embedded into `ProxyManager.app/Contents/Frameworks/` by `build.sh`. |
| `bin/generate_keys` | One-time: create the EdDSA signing key pair. |
| `bin/generate_appcast` | Release: build + sign `appcast.xml` from the update archive. |
| `bin/sign_update` | Manual signing of an archive/release notes (rarely needed). |
| `bin/BinaryDelta` | Delta generation used by `generate_appcast`. |

The framework's `Versions/Current` symlinks are load-bearing — never flatten
them. `build.sh` copies it with `ditto`, which preserves symlinks.

## Updating Sparkle

1. Download the new `Sparkle-<version>.tar.xz` from the Sparkle releases page.
2. Extract and replace `Sparkle.framework` and the `bin/` tools (keep `ditto`
   semantics / symlinks intact).
3. Update the version in this file.
4. `./build.sh` and smoke-test an update.

## Signing key

The EdDSA **public** key is committed at `public_ed_key.txt`; `build.sh` embeds
it as `SUPublicEDKey`. The **private** key lives only in the maintainer's login
Keychain and in the `SPARKLE_PRIVATE_KEY` GitHub Actions secret. Never commit
the private key.
