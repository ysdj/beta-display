#!/bin/zsh
set -euo pipefail

# Render a concrete Homebrew Cask from release artifacts. The committed cask
# source is a template on purpose: Homebrew must receive the SHA-256 of the
# actual ad-hoc-signed archive.

project_dir=${0:A:h:h}
template="$project_dir/Casks/beta-display.rb.template"
version=""
release_base_url=""
arm64_sha256=""
x86_64_sha256=""
output=""

usage() {
    print -- "Usage: zsh scripts/render-cask.zsh --version VERSION --release-base-url URL --arm64-sha256 SHA256 --x86_64-sha256 SHA256 --output PATH"
}

require_value() {
    local flag="$1"
    local value="$2"
    if [[ -z "$value" ]]; then
        print -u2 -- "Missing required value for $flag"
        usage >&2
        exit 64
    fi
}

while (( $# > 0 )); do
    case "$1" in
        --version)
            version="${2:-}"
            shift 2
            ;;
        --release-base-url)
            release_base_url="${2:-}"
            shift 2
            ;;
        --arm64-sha256)
            arm64_sha256="${2:-}"
            shift 2
            ;;
        --x86_64-sha256)
            x86_64_sha256="${2:-}"
            shift 2
            ;;
        --output)
            output="${2:-}"
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

require_value --version "$version"
require_value --release-base-url "$release_base_url"
require_value --arm64-sha256 "$arm64_sha256"
require_value --x86_64-sha256 "$x86_64_sha256"
require_value --output "$output"

if [[ ! "$version" =~ '^[0-9]+([.][0-9]+){1,3}([._+-][0-9A-Za-z._+-]+)?$' ]]; then
    print -u2 -- "Invalid version: $version"
    exit 64
fi

if [[ ! "$release_base_url" =~ '^https://[^[:space:]]+$' ]]; then
    print -u2 -- "Release base URL must be an HTTPS URL"
    exit 64
fi

if [[ ! "$arm64_sha256" =~ '^[0-9a-fA-F]{64}$' ]] || [[ ! "$x86_64_sha256" =~ '^[0-9a-fA-F]{64}$' ]]; then
    print -u2 -- "Both archive checksums must be 64-character SHA-256 hex strings"
    exit 64
fi
mkdir -p "${output:h}"

# Ruby is available on supported macOS versions and avoids quoting mistakes in
# URLs such as query strings while keeping the template itself readable.
/usr/bin/ruby - "$template" "$output" "$version" "${release_base_url%/}" "$arm64_sha256" "$x86_64_sha256" <<'RUBY'
template, output, version, base_url, arm64, x86_64 = ARGV
text = File.read(template)
replacements = {
  "__VERSION__" => version,
  "__RELEASE_BASE_URL__" => base_url,
  "__ARM64_SHA256__" => arm64.downcase,
  "__X86_64_SHA256__" => x86_64.downcase,
}
replacements.each { |needle, value| text = text.gsub(needle, value) }
abort "Unexpanded Cask placeholder" if text.include?("__")
File.write(output, text)
RUBY

print -- "$output"
