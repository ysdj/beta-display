# Release and Homebrew delivery

Beta Display publishes prebuilt ZIP archives for Apple silicon and Intel Macs.
Homebrew downloads the matching public release archive and verifies its
SHA-256 checksum. The installation Mac does not need Xcode, Swift, GitHub CLI,
a GitHub account, or a token.

## Compatibility

The app deployment target is macOS 13. The release script refuses to package
unless `BETADISPLAY_TESTED_THROUGH_MACOS=26` (or a newer major version) is set,
and it must run on macOS 26 or newer.

## Signing model

This public distribution intentionally uses ad-hoc signing (`codesign -s -`).
No Developer ID certificate or notarization profile is required. The Cask
removes the quarantine attribute after installation because ad-hoc signatures
are not notarized by Apple. Publish only release archives that have been
reviewed and tested.

## Create a release

Run the following two phases on a macOS 26-or-newer release machine. First
commit and push all source, version, tests, documentation, and release-script
changes. Preparation refuses a dirty or unpushed source tree.

### 1. Prepare and commit the release

```sh
BETADISPLAY_TESTED_THROUGH_MACOS=26 \
zsh scripts/package-release.zsh --prepare
```

This creates and validates two ZIPs and writes a SHA-256-pinned Cask plus
manifest in `dist/release/`:

- `BetaDisplay-<version>-arm64.zip`
- `BetaDisplay-<version>-x86_64.zip`
- `BetaDisplay-<version>-release.json`

The command records the exact source revision and synchronizes the generated
Cask into the tracked `Casks/beta-display.rb`. Review it, commit only that Cask,
and push `main`. Then create an annotated tag at that exact commit and push it:

```sh
git tag -a v<version> -m "Beta Display <version>"
git push origin main v<version>
```

### 2. Publish the prepared assets

```sh
BETADISPLAY_TESTED_THROUGH_MACOS=26 \
zsh scripts/package-release.zsh --publish
```

Publishing fails closed unless the worktree is clean and the local/remote tag
and `origin/main` all point to the same commit. That tag must be exactly one
Cask-only commit after the recorded source revision. Publishing verifies both
extracted app bundles, the manifest, and the committed Cask SHA-256 values
before it uploads a draft release. It then checks the uploaded asset digests
and only then publishes it. The Cask uses public GitHub Release URLs, so
installers never need credentials.

## Installer command

One command installs the app and its Cask from the application repository:

```sh
brew install --cask ysdj/beta-display/beta-display
```
