#!/bin/zsh
set -euo pipefail

# Builds, validates, and atomically installs Beta Display only when the app
# bundle and its executable both prove they contain the current LUT recovery
# guard. This deliberately refuses a partial or stale deployment.

project_dir=${0:A:h:h}
target_app="/Applications/Beta Display.app"
source_app=""
expected_marker="beta-display-lut-baseline-guard-v2"
staging_app=""
backup_app=""
install_committed=false
target_moved=false

usage() {
    print -- "Usage: zsh scripts/deploy-verified-app.zsh [--source APP] [--target APP]"
}

while (( $# > 0 )); do
    case "$1" in
        --source)
            source_app="${2:?missing app after --source}"
            shift 2
            ;;
        --target)
            target_app="${2:?missing app after --target}"
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

if [[ -z "$source_app" ]]; then
    source_app="$project_dir/dist/Beta Display.app"
    zsh "$project_dir/scripts/build-app.zsh" --output "$source_app" --identity -
fi

source_app=${source_app:A}
target_app=${target_app:A}
[[ "$target_app" == "/Applications/Beta Display.app" ]] || {
    print -u2 -- "Refusing non-default target: $target_app"
    exit 64
}

require_app() {
    local app="$1"
    local plist="$app/Contents/Info.plist"
    local binary="$app/Contents/MacOS/BetaDisplay"
    [[ -d "$app" && -f "$plist" && -x "$binary" ]] || {
        print -u2 -- "Invalid Beta Display app bundle: $app"
        exit 1
    }
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

require_gate() {
    local app="$1"
    local version="$2"
    local build="$3"
    local output
    output=$("$app/Contents/MacOS/BetaDisplay" --deployment-gate)
    local expected="BetaDisplay deployment-gate $expected_marker $version $build"
    [[ "$output" == "$expected" ]] || {
        print -u2 -- "Deployment gate mismatch for $app"
        print -u2 -- "Expected: $expected"
        print -u2 -- "Actual:   $output"
        exit 1
    }
}

require_self_test() {
    local app="$1"
    local output
    output=$("$app/Contents/MacOS/BetaDisplay" --self-test)
    [[ "$output" == "Beta Display self-test passed" ]] || {
        print -u2 -- "Self-test failed for $app"
        print -u2 -- "$output"
        exit 1
    }
}

app_sha256() {
    local app="$1"
    shasum -a 256 "$app/Contents/MacOS/BetaDisplay" | awk '{print $1}'
}

version_is_newer() {
    /usr/bin/ruby -rrubygems - "$1" "$2" <<'RUBY'
candidate, current = ARGV
exit(Gem::Version.new(candidate) > Gem::Version.new(current) ? 0 : 1)
RUBY
}

running_beta_display_processes() {
    # Use both PID and executable path. This preserves the identity of the
    # app we asked to quit, rather than accepting a stale process whose path
    # looks the same after /Applications/Beta Display.app is atomically moved.
    ps -ax -o pid= -o comm= | awk '
        {
            pid = $1
            sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
            if ($0 ~ /\/Contents\/MacOS\/BetaDisplay$/) print pid "\t" $0
        }
    '
}

running_beta_display_pids() {
    running_beta_display_processes | awk -F "\t" '{ print $1 }'
}

rollback_install() {
    if [[ "$install_committed" == true ]]; then
        if [[ "$target_moved" == true && -n "$backup_app" && -e "$backup_app" ]]; then
            rm -rf -- "$target_app"
            mv -- "$backup_app" "$target_app"
            print -u2 -- "Deployment interrupted; restored previous app"
        elif [[ -e "$target_app" ]]; then
            rm -rf -- "$target_app"
            print -u2 -- "Deployment interrupted; removed incomplete new app"
        fi
    fi
    [[ -n "$staging_app" ]] && rm -rf -- "$staging_app"
}

trap rollback_install EXIT HUP INT TERM

require_app "$source_app"
codesign --verify --deep --strict --verbose=2 "$source_app"
source_id=$(plist_value "$source_app" CFBundleIdentifier)
source_version=$(plist_value "$source_app" CFBundleShortVersionString)
source_build=$(plist_value "$source_app" CFBundleVersion)
[[ "$source_id" == "io.github.ysdj.betadisplay" ]] || {
    print -u2 -- "Unexpected source bundle identifier: $source_id"
    exit 1
}
require_gate "$source_app" "$source_version" "$source_build"
require_self_test "$source_app"
source_sha256=$(app_sha256 "$source_app")

if [[ -e "$target_app/Contents/Info.plist" ]]; then
    installed_version_before=$(plist_value "$target_app" CFBundleShortVersionString)
    installed_build_before=$(plist_value "$target_app" CFBundleVersion)
    if [[ "$source_version" == "$installed_version_before" ]] \
        && (( 10#$source_build <= 10#$installed_build_before )); then
        print -u2 -- "Refusing non-incremental deployment: source $source_version build $source_build; installed $installed_version_before build $installed_build_before"
        exit 1
    fi
    if [[ "$source_version" != "$installed_version_before" ]] \
        && ! version_is_newer "$source_version" "$installed_version_before"; then
        print -u2 -- "Refusing version downgrade: source $source_version; installed $installed_version_before"
        exit 1
    fi
fi

# Request normal application termination first so its LUT/session restore runs.
old_processes=$(running_beta_display_processes)
if [[ -n "$old_processes" ]]; then
    osascript -e 'tell application id "io.github.ysdj.betadisplay" to quit' || true
    for _ in {1..50}; do
        active_old_processes=""
        while IFS=$'\t' read -r old_pid old_path; do
            [[ -z "$old_pid" ]] && continue
            current_path=$(ps -p "$old_pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//')
            [[ "$current_path" == "$old_path" ]] && active_old_processes+="$old_pid"$'\n'
        done <<< "$old_processes"
        [[ -z "$active_old_processes" ]] && break
        sleep 0.1
    done
fi
[[ -z "${active_old_processes:-}" ]] || {
    print -u2 -- "Beta Display did not exit gracefully; refusing installation"
    exit 1
}

target_parent=${target_app:h}
staging_app="$target_parent/.Beta Display.deploying.app"

rm -rf -- "$staging_app"
ditto "$source_app" "$staging_app"
require_app "$staging_app"
codesign --verify --deep --strict --verbose=2 "$staging_app"
stage_id=$(plist_value "$staging_app" CFBundleIdentifier)
stage_version=$(plist_value "$staging_app" CFBundleShortVersionString)
stage_build=$(plist_value "$staging_app" CFBundleVersion)
[[ "$stage_id" == "$source_id" && "$stage_version" == "$source_version" && "$stage_build" == "$source_build" ]] || {
    print -u2 -- "Staged app metadata differs from the validated source"
    exit 1
}
require_gate "$staging_app" "$source_version" "$source_build"
require_self_test "$staging_app"
stage_sha256=$(app_sha256 "$staging_app")
[[ "$stage_sha256" == "$source_sha256" ]] || {
    print -u2 -- "Staged binary checksum differs from the validated source"
    exit 1
}

backup_app="$target_parent/.Beta Display.previous.app"
rm -rf -- "$backup_app"
if [[ -e "$target_app" ]]; then
    mv -- "$target_app" "$backup_app"
    target_moved=true
fi
if ! mv -- "$staging_app" "$target_app"; then
    [[ -e "$backup_app" ]] && mv -- "$backup_app" "$target_app"
    print -u2 -- "Install failed; previous app was restored"
    exit 1
fi
install_committed=true

require_app "$target_app"
codesign --verify --deep --strict --verbose=2 "$target_app"
installed_id=$(plist_value "$target_app" CFBundleIdentifier)
installed_version=$(plist_value "$target_app" CFBundleShortVersionString)
installed_build=$(plist_value "$target_app" CFBundleVersion)
[[ "$installed_id" == "$source_id" && "$installed_version" == "$source_version" && "$installed_build" == "$source_build" ]] || {
    print -u2 -- "Installed app metadata verification failed"
    exit 1
}
require_gate "$target_app" "$source_version" "$source_build"
require_self_test "$target_app"
installed_sha256=$(app_sha256 "$target_app")
[[ "$installed_sha256" == "$source_sha256" ]] || {
    print -u2 -- "Installed binary checksum differs from the validated source"
    exit 1
}

# Avoid `open` here: LaunchServices may race an atomic app replacement and
# activate an executable image that started before the move. Starting the
# verified target directly gives the gate an unambiguous process path.
"$target_app/Contents/MacOS/BetaDisplay" >/dev/null 2>&1 &
launched_pid=$!
for _ in {1..50}; do
    installed_pid=$(ps -p "$launched_pid" -o pid= 2>/dev/null | tr -d '[:space:]')
    [[ -n "$installed_pid" ]] && break
    sleep 0.1
done
[[ -n "${installed_pid:-}" ]] || {
    print -u2 -- "Installed Beta Display did not launch"
    exit 1
}
running_command=$(ps -p "$installed_pid" -o comm= | sed 's/^[[:space:]]*//')
[[ "$running_command" == "$target_app/Contents/MacOS/BetaDisplay" ]] || {
    print -u2 -- "Launched process does not match the installed app"
    exit 1
}
require_gate "$target_app" "$source_version" "$source_build"

rm -rf -- "$backup_app"
install_committed=false
target_moved=false
print -- "Installed and verified: $target_app ($source_version build $source_build)"
