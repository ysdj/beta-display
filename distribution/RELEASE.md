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

Run on a macOS 26-or-newer release machine:

```sh
BETADISPLAY_TESTED_THROUGH_MACOS=26 \
zsh scripts/package-release.zsh
```

The command creates two ZIPs, creates a public GitHub Release and uploads
them, then writes a SHA-256-pinned Cask and manifest in `dist/release/`:

- `BetaDisplay-<version>-arm64.zip`
- `BetaDisplay-<version>-x86_64.zip`
- `Casks/beta-display.rb`
- `BetaDisplay-<version>-release.json`

Commit the generated `Casks/beta-display.rb` as the new versioned Cask and push
it. The Cask uses public GitHub Release download URLs, so installers never need
to configure credentials. The template is deliberately not installable: its
placeholders can only be filled after the final release archives exist and
their checksums are known.

## Installer command

One command installs the app and its Cask from the application repository:

```sh
brew install --cask ysdj/beta-display/beta-display
```
