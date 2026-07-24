#!/bin/zsh
set -euo pipefail

# Build a self-contained app bundle. The default is deliberately convenient for
# local development; the release packager supplies an architecture and a
# Developer ID identity explicitly.

project_dir=${0:A:h:h}
arch=$(uname -m)
output_dir="$project_dir/dist/Beta Display.app"
signing_identity="${BETADISPLAY_CODESIGN_IDENTITY:--}"
build_jobs="${BETADISPLAY_BUILD_JOBS:-$(sysctl -n hw.ncpu)}"

usage() {
    print -- "Usage: zsh scripts/build-app.zsh [--arch arm64|x86_64] [--output PATH] [--identity IDENTITY]"
}

while (( $# > 0 )); do
    case "$1" in
        --arch)
            arch="${2:?missing architecture after --arch}"
            shift 2
            ;;
        --output)
            output_dir="${2:?missing path after --output}"
            shift 2
            ;;
        --identity)
            signing_identity="${2:?missing identity after --identity}"
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

case "$arch" in
    arm64|x86_64) ;;
    *)
        print -u2 -- "Unsupported architecture: $arch (expected arm64 or x86_64)"
        exit 64
        ;;
esac

cd "$project_dir"
target_triple="${arch}-apple-macosx13.0"
swift build -c release --triple "$target_triple" --disable-index-store -j "$build_jobs"
binary_dir=$(swift build -c release --triple "$target_triple" --show-bin-path)
binary="$binary_dir/BetaDisplay"
resource_bundle="$binary_dir/BetaDisplay_BetaDisplay.bundle"
app_icon="$project_dir/App/Resources/BetaDisplay.icns"

if [[ ! -x "$binary" ]]; then
    print -u2 -- "Build did not produce an executable: $binary"
    exit 1
fi
if [[ ! -d "$resource_bundle" ]]; then
    print -u2 -- "Build did not produce the resource bundle: $resource_bundle"
    exit 1
fi
if [[ ! -f "$app_icon" ]]; then
    print -u2 -- "App icon is missing: $app_icon"
    exit 1
fi

if [[ -e "$output_dir" ]]; then
    rm -rf -- "$output_dir"
fi
mkdir -p "${output_dir:h}"
mkdir -p "$output_dir/Contents/MacOS" "$output_dir/Contents/Resources"
cp "$binary" "$output_dir/Contents/MacOS/BetaDisplay"
cp "$project_dir/App/Info.plist" "$output_dir/Contents/Info.plist"
ditto "$resource_bundle" "$output_dir/Contents/Resources/BetaDisplay_BetaDisplay.bundle"
cp "$app_icon" "$output_dir/Contents/Resources/BetaDisplay.icns"

codesign_args=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
    codesign_args+=(--options runtime --timestamp)
fi
codesign "${codesign_args[@]}" "$output_dir/Contents/Resources/BetaDisplay_BetaDisplay.bundle"
codesign "${codesign_args[@]}" "$output_dir"
print -- "$output_dir"
