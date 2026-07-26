#!/bin/zsh
set -euo pipefail

# Builds, validates, and atomically installs Beta Display only when the app
# bundle and its executable both prove they contain the current LUT recovery
# guard. This deliberately refuses a partial or stale deployment.

project_dir=${0:A:h:h}
target_app="/Applications/Beta Display.app"
source_app=""
expected_marker="beta-display-lut-baseline-guard-v2"
deployment_lock_directory=""
deployment_lock_owner_file=""
deployment_lock_held=false
stale_lock_directory=""
staging_app=""
backup_app=""
install_committed=false
target_moved=false
launched_pid=""
rollback_started=false
deployment_succeeded=false
verify_installed_only=false

usage() {
    print -- "Usage: zsh scripts/deploy-verified-app.zsh [--source APP] [--target APP] [--verify-installed]"
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
        --verify-installed)
            verify_installed_only=true
            shift
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

verify_installed_app() {
    local app="$1"
    local reference_app="${2:-}"
    require_app "$app"
    codesign --verify --deep --strict --verbose=2 "$app"
    local identifier
    identifier=$(plist_value "$app" CFBundleIdentifier)
    local version
    version=$(plist_value "$app" CFBundleShortVersionString)
    local build
    build=$(plist_value "$app" CFBundleVersion)
    [[ "$identifier" == "io.github.ysdj.betadisplay" ]] || {
        print -u2 -- "Unexpected installed bundle identifier: $identifier"
        exit 1
    }
    require_gate "$app" "$version" "$build"
    require_self_test "$app"
    if [[ -n "$reference_app" ]]; then
        require_app "$reference_app"
        codesign --verify --deep --strict --verbose=2 "$reference_app"
        local reference_identifier
        reference_identifier=$(plist_value "$reference_app" CFBundleIdentifier)
        local reference_version
        reference_version=$(plist_value "$reference_app" CFBundleShortVersionString)
        local reference_build
        reference_build=$(plist_value "$reference_app" CFBundleVersion)
        local reference_sha256
        reference_sha256=$(app_sha256 "$reference_app")
        require_gate "$reference_app" "$reference_version" "$reference_build"
        require_self_test "$reference_app"
        [[ "$identifier" == "$reference_identifier" && "$version" == "$reference_version" && "$build" == "$reference_build" ]] || {
            print -u2 -- "Installed bundle metadata differs from the reference app"
            exit 1
        }
        [[ "$(app_sha256 "$app")" == "$reference_sha256" ]] || {
            print -u2 -- "Installed binary checksum differs from the reference app"
            exit 1
        }
    fi
    print -- "Installed bundle verified: $app ($version build $build)"
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

acquire_deployment_lock() {
    deployment_lock_directory="${target_app:h}/.Beta Display.deploy.lock"
    deployment_lock_owner_file="$deployment_lock_directory/owner-pid"
    if ! mkdir "$deployment_lock_directory" 2>/dev/null; then
        local recorded_owner=""
        [[ -d "$deployment_lock_directory" && ! -L "$deployment_lock_directory" && -f "$deployment_lock_owner_file" && ! -L "$deployment_lock_owner_file" ]] \
            && recorded_owner=$(<"$deployment_lock_owner_file")
        [[ "$recorded_owner" == <-> ]] || {
            print -u2 -- "Deployment lock requires manual inspection: $deployment_lock_directory"
            exit 1
        }
        if kill -0 "$recorded_owner" 2>/dev/null; then
            print -u2 -- "Another deployment is active (PID $recorded_owner)"
            exit 1
        fi
        local unexpected_entries
        unexpected_entries=$(command ls -A "$deployment_lock_directory" | grep -v -x 'owner-pid' || true)
        [[ -z "$unexpected_entries" ]] || {
            print -u2 -- "Stale deployment lock contains unexpected entries: $deployment_lock_directory"
            exit 1
        }
        stale_lock_directory="${target_app:h}/.Beta Display.deploy.stale-$$-$RANDOM.lock"
        mv -- "$deployment_lock_directory" "$stale_lock_directory" 2>/dev/null || {
            print -u2 -- "Deployment lock changed while being inspected; refusing deployment"
            exit 1
        }
        mkdir "$deployment_lock_directory" 2>/dev/null || {
            print -u2 -- "Another deployment acquired the lock"
            exit 1
        }
    fi
    deployment_lock_held=true
    if ! print -r -- "$$" > "$deployment_lock_owner_file"; then
        rmdir "$deployment_lock_directory" 2>/dev/null || true
        deployment_lock_held=false
        print -u2 -- "Could not record deployment lock ownership"
        exit 1
    fi
}

release_deployment_lock() {
    [[ "$deployment_lock_held" == true ]] || return 0
    local recorded_owner=""
    [[ -f "$deployment_lock_owner_file" ]] && recorded_owner=$(<"$deployment_lock_owner_file")
    if [[ -n "$recorded_owner" && "$recorded_owner" != "$$" ]]; then
        print -u2 -- "Refusing to remove deployment lock owned by PID $recorded_owner"
        return 0
    fi
    rm -f -- "$deployment_lock_owner_file"
    rmdir "$deployment_lock_directory" 2>/dev/null || {
        print -u2 -- "Could not release deployment lock: $deployment_lock_directory"
        return 0
    }
    deployment_lock_held=false
    if [[ -n "$stale_lock_directory" && -d "$stale_lock_directory" && ! -L "$stale_lock_directory" ]]; then
        local stale_owner_file="$stale_lock_directory/owner-pid"
        [[ -f "$stale_owner_file" && ! -L "$stale_owner_file" ]] && rm -f -- "$stale_owner_file"
        rmdir "$stale_lock_directory" 2>/dev/null || print -u2 -- "Retained stale lock for inspection: $stale_lock_directory"
    fi
}

remove_owned_path() {
    # In zsh, `path` is the special array backing PATH. Never use that name
    # for an app path here: doing so makes the cleanup command unresolvable.
    local owned_path="$1"
    local prefix="$2"
    [[ -n "$owned_path" && "$owned_path:h" == "${target_app:h}" && "$owned_path:t" == ${~prefix} ]] || {
        print -u2 -- "Refusing cleanup of unexpected deployment path: $owned_path"
        return 1
    }
    /bin/rm -rf -- "$owned_path"
}

recover_interrupted_deployment_if_needed() {
    [[ -e "$target_app" ]] && return 0
    local orphaned_backups=("${target_app:h}"/.Beta\ Display.previous-*.app(N))
    (( ${#orphaned_backups} == 0 )) && return 0
    (( ${#orphaned_backups} == 1 )) || {
        print -u2 -- "Multiple interrupted deployment backups require manual inspection: ${orphaned_backups[*]}"
        exit 1
    }
    local backup="${orphaned_backups[1]}"
    require_app "$backup"
    codesign --verify --deep --strict --verbose=2 "$backup"
    mv -- "$backup" "$target_app" || {
        print -u2 -- "Could not restore interrupted deployment backup: $backup"
        exit 1
    }
    print -u2 -- "Restored interrupted deployment backup: $target_app"
}

terminate_launched_process_for_rollback() {
    [[ -n "$launched_pid" ]] || return 0
    kill -0 "$launched_pid" 2>/dev/null || return 0
    osascript -e 'tell application id "io.github.ysdj.betadisplay" to quit' || true
    for _ in {1..50}; do
        kill -0 "$launched_pid" 2>/dev/null || return 0
        sleep 0.1
    done
    return 1
}

rollback_install() {
    [[ "$rollback_started" == false ]] || return
    rollback_started=true
    if [[ "$deployment_succeeded" == true ]]; then
        [[ -n "$staging_app" ]] && remove_owned_path "$staging_app" '.Beta Display.deploying-*.app'
        return
    fi
    if [[ -n "$launched_pid" ]] && ! terminate_launched_process_for_rollback; then
        print -u2 -- "Deployment interrupted; retained the verified new app because its launched process is still running"
        return
    fi
    if [[ "$target_moved" == true && -n "$backup_app" && -e "$backup_app" ]]; then
        [[ "$target_app" == "/Applications/Beta Display.app" ]] || return
        rm -rf -- "$target_app"
        mv -- "$backup_app" "$target_app"
        print -u2 -- "Deployment interrupted; restored previous app"
    elif [[ "$install_committed" == true && -e "$target_app" ]]; then
        [[ "$target_app" == "/Applications/Beta Display.app" ]] || return
        rm -rf -- "$target_app"
        print -u2 -- "Deployment interrupted; removed incomplete new app"
    fi
    [[ -n "$staging_app" ]] && remove_owned_path "$staging_app" '.Beta Display.deploying-*.app'
}

if [[ "$verify_installed_only" == true ]]; then
    [[ -n "$source_app" ]] || {
        print -u2 -- "--verify-installed requires --source so it can prove installed provenance"
        exit 64
    }
    source_app=${source_app:A}
    verify_installed_app "$target_app" "$source_app"
    exit 0
fi

cleanup_on_exit() {
    local exit_status=$?
    trap - EXIT
    set +e
    rollback_install
    release_deployment_lock
    exit "$exit_status"
}

trap cleanup_on_exit EXIT
trap 'exit 1' HUP INT TERM

acquire_deployment_lock
recover_interrupted_deployment_if_needed

if [[ -z "$source_app" ]]; then
    source_app="$project_dir/dist/Beta Display.app"
    zsh "$project_dir/scripts/build-app.zsh" --output "$source_app" --identity -
fi
source_app=${source_app:A}

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
deployment_nonce="$$-$RANDOM"
staging_app="$target_parent/.Beta Display.deploying-$deployment_nonce.app"
backup_app="$target_parent/.Beta Display.previous-$deployment_nonce.app"

remove_owned_path "$staging_app" '.Beta Display.deploying-*.app'
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

[[ ! -e "$backup_app" ]] || {
    print -u2 -- "Deployment backup path already exists: $backup_app"
    exit 1
}
# Close the small post-quit race: no Beta Display process may appear between
# the graceful shutdown check and the atomic replacement.
[[ -z "$(running_beta_display_processes)" ]] || {
    print -u2 -- "Beta Display restarted before replacement; refusing installation"
    exit 1
}
if [[ -e "$target_app" ]]; then
    # Arm recovery before the move: a signal between `mv` and state assignment
    # must still put the previous bundle back.
    target_moved=true
    mv -- "$target_app" "$backup_app"
fi
if ! mv -- "$staging_app" "$target_app"; then
    if [[ -e "$backup_app" ]]; then
        mv -- "$backup_app" "$target_app" || {
            print -u2 -- "Install failed and the previous app could not be restored"
            exit 1
        }
    fi
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

# Start the already-verified executable without the deployment terminal as its
# parent. `nohup` keeps a shell HUP from terminating it; its executable path is
# then checked directly against the installed target.
/usr/bin/nohup "$target_app/Contents/MacOS/BetaDisplay" </dev/null >/dev/null 2>&1 &
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
# A short observation window avoids treating a process that immediately exits
# (for example, due to a stale instance lock or launch-time self-test failure)
# as a successful deployment.
sleep 1
kill -0 "$installed_pid" 2>/dev/null || {
    print -u2 -- "Installed Beta Display exited immediately after launch"
    exit 1
}
running_command=$(ps -p "$installed_pid" -o comm= | sed 's/^[[:space:]]*//')
[[ "$running_command" == "$target_app/Contents/MacOS/BetaDisplay" ]] || {
    print -u2 -- "Launched process path changed before deployment completed"
    exit 1
}
# A successful deployment is committed before backup cleanup. If a signal
# interrupts cleanup, retaining a backup is safe; deleting the new target is
# not.
require_gate "$target_app" "$source_version" "$source_build"
deployment_succeeded=true
install_committed=false
target_moved=false
launched_pid=""
remove_owned_path "$backup_app" '.Beta Display.previous-*.app'
print -- "Installed and verified: $target_app ($source_version build $source_build)"
