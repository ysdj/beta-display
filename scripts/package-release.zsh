#!/bin/zsh
set -euo pipefail

# Produce architecture-specific ad-hoc-signed ZIP archives. End users and
# Homebrew only unpack these archives, so installation never builds Swift.

project_dir=${0:A:h:h}
release_dir="${BETADISPLAY_RELEASE_DIR:-$project_dir/dist/release}"
release_base_url="${BETADISPLAY_RELEASE_BASE_URL:-https://github.com/ysdj/beta-display/releases/download}"
github_release_repo="${BETADISPLAY_GITHUB_RELEASE_REPO:-ysdj/beta-display}"
tested_through_macos="${BETADISPLAY_TESTED_THROUGH_MACOS:-}"
version=""

usage() {
    print -- "Usage: BETADISPLAY_TESTED_THROUGH_MACOS=26 zsh scripts/package-release.zsh [--version VERSION] [--output PATH]"
}

while (( $# > 0 )); do
    case "$1" in
        --version)
            version="${2:-}"
            shift 2
            ;;
        --output)
            release_dir="${2:-}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print -u2 -- "Unknown argument: $1"
            usage >&2
            exit 64
            ;;
    esac
done

if [[ -z "$version" ]]; then
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/App/Info.plist")
fi

for name in release_base_url tested_through_macos; do
    if [[ -z "${(P)name}" ]]; then
        print -u2 -- "Missing BETADISPLAY_${(U)name}"
        usage >&2
        exit 64
    fi
done

if [[ ! "$release_base_url" =~ '^https://[^[:space:]]+$' ]]; then
    print -u2 -- "BETADISPLAY_RELEASE_BASE_URL must be an HTTPS URL"
    exit 64
fi
if [[ ! "$tested_through_macos" =~ '^[0-9]+$' ]] || (( tested_through_macos < 26 )); then
    print -u2 -- "BETADISPLAY_TESTED_THROUGH_MACOS must be 26 or newer"
    exit 64
fi
host_macos_major=$(sw_vers -productVersion | cut -d. -f1)
if [[ ! "$host_macos_major" =~ '^[0-9]+$' ]] || (( host_macos_major < 26 )); then
    print -u2 -- "Release packaging must run on macOS 26 or newer (current: $(sw_vers -productVersion))"
    exit 1
fi
mkdir -p "$release_dir"
manifest="$release_dir/BetaDisplay-${version}-release.json"
# Keep the app bundle's name stable inside both archives. Homebrew's `app`
# artifact expects Beta Display.app, while the containing directories keep the
# two build products distinct on the release machine.
arm64_app="$release_dir/bundles/arm64/Beta Display.app"
x86_64_app="$release_dir/bundles/x86_64/Beta Display.app"
arm64_zip="$release_dir/BetaDisplay-${version}-arm64.zip"
x86_64_zip="$release_dir/BetaDisplay-${version}-x86_64.zip"

build_and_archive() {
    local arch="$1"
    local app_path="$2"
    local archive_path="$3"

    zsh "$project_dir/scripts/build-app.zsh" --arch "$arch" --output "$app_path" --identity -
    # `--norsrc` keeps the archive free of Finder's __MACOSX sidecars; the
    # app bundle itself remains intact and deterministic enough for a Cask hash.
    ditto -c -k --keepParent --norsrc "$app_path" "$archive_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"
}

build_and_archive arm64 "$arm64_app" "$arm64_zip"
build_and_archive x86_64 "$x86_64_app" "$x86_64_zip"

arm64_sha256=$(shasum -a 256 "$arm64_zip" | awk '{print $1}')
x86_64_sha256=$(shasum -a 256 "$x86_64_zip" | awk '{print $1}')
cask_output="$release_dir/Casks/beta-display.rb"
if ! command -v gh >/dev/null 2>&1; then
    print -u2 -- "GitHub CLI is required to publish release assets"
    exit 1
fi
if gh release view "v${version}" --repo "$github_release_repo" >/dev/null 2>&1; then
    print -u2 -- "Release v${version} already exists in ${github_release_repo}; choose a new version"
    exit 1
fi
gh release create "v${version}" "$arm64_zip" "$x86_64_zip" \
    --repo "$github_release_repo" \
    --title "Beta Display ${version}" \
    --notes "Ad-hoc-signed Beta Display release for macOS 13 and later. Includes Apple silicon and Intel archives; release validation recorded through macOS ${tested_through_macos}."

zsh "$project_dir/scripts/render-cask.zsh" \
    --version "$version" \
    --release-base-url "$release_base_url" \
    --arm64-sha256 "$arm64_sha256" \
    --x86_64-sha256 "$x86_64_sha256" \
    --output "$cask_output"

/usr/bin/ruby - "$manifest" "$version" "${release_base_url%/}" "$tested_through_macos" "$arm64_zip" "$arm64_sha256" "$x86_64_zip" "$x86_64_sha256" <<'RUBY'
require "json"
output, version, base_url, tested, arm_path, arm_sha, intel_path, intel_sha = ARGV
payload = {
  "version" => version,
  "minimum_macos" => "13.0",
  "tested_through_macos" => tested.to_i,
  "release_base_url" => base_url,
  "artifacts" => {
    "arm64" => { "file" => File.basename(arm_path), "sha256" => arm_sha },
    "x86_64" => { "file" => File.basename(intel_path), "sha256" => intel_sha },
  },
}
File.write(output, JSON.pretty_generate(payload) + "\n")
RUBY

print -- "Release archives: $arm64_zip and $x86_64_zip"
print -- "Generated Cask: $cask_output"
print -- "Published GitHub Release: v${version} in ${github_release_repo}"
print -- "Commit the generated Cask before sharing the Homebrew install command."
