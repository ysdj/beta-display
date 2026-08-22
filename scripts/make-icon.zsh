#!/bin/zsh
set -euo pipefail

# Compiles the source artwork into the standard macOS multi-resolution .icns
# container. The source stays unchanged; sips prepares the required sizes.

project_dir=${0:A:h:h}
source_image="$project_dir/App/IconSource/BetaDisplay-1024.png"
output_icon="$project_dir/App/Resources/BetaDisplay.icns"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/BetaDisplay.icon.XXXXXX")
iconset_dir="$temporary_dir/BetaDisplay.iconset"

cleanup() {
    rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

if [[ ! -f "$source_image" ]]; then
    print -u2 -- "Icon source is missing: $source_image"
    exit 1
fi

mkdir -p "${output_icon:h}"
mkdir -p "$iconset_dir"
for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    size=${spec%% *}
    name=${spec#* }
    /usr/bin/sips -z "$size" "$size" "$source_image" --out "$iconset_dir/$name" >/dev/null
done

/usr/bin/iconutil -c icns "$iconset_dir" -o "$output_icon"
print -- "$output_icon"
