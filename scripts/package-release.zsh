#!/bin/zsh
set -euo pipefail

# Release preparation and publishing are deliberately separate. Preparation
# builds from a clean, pushed source commit and records that revision. The tag
# may then add exactly one generated Cask commit; publishing rejects any other
# source-tree drift and binds the prepared archives to that Cask's hashes.

project_dir=${0:A:h:h}
release_dir="${BETADISPLAY_RELEASE_DIR:-$project_dir/dist/release}"
release_base_url="${BETADISPLAY_RELEASE_BASE_URL:-https://github.com/ysdj/beta-display/releases/download}"
github_release_repo="${BETADISPLAY_GITHUB_RELEASE_REPO:-ysdj/beta-display}"
tested_through_macos="${BETADISPLAY_TESTED_THROUGH_MACOS:-}"
version=""
mode=""

usage() {
    print -- "Usage: BETADISPLAY_TESTED_THROUGH_MACOS=26 zsh scripts/package-release.zsh --prepare|--publish|--resume-draft [--version VERSION] [--output PATH]"
}

fail() {
    print -u2 -- "$1"
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --prepare|--publish|--resume-draft)
            [[ -z "$mode" ]] || { usage >&2; exit 64; }
            mode="${1#--}"
            shift
            ;;
        --version)
            version="${2:?missing version after --version}"
            shift 2
            ;;
        --output)
            release_dir="${2:?missing path after --output}"
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

[[ -n "$mode" ]] || { usage >&2; exit 64; }

if [[ -z "$version" ]]; then
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/App/Info.plist")
fi

plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/App/Info.plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$project_dir/App/Info.plist")
[[ "$version" == "$plist_version" ]] || fail "Release version $version does not match App/Info.plist version $plist_version"
[[ "$version" =~ '^[0-9]+([.][0-9]+){1,3}([._+-][0-9A-Za-z._+-]+)?$' ]] || fail "Invalid release version: $version"
[[ "$release_base_url" =~ '^https://[^[:space:]]+$' ]] || fail "Release base URL must be HTTPS"
[[ "$tested_through_macos" =~ '^[0-9]+$' ]] && (( tested_through_macos >= 26 )) || fail "BETADISPLAY_TESTED_THROUGH_MACOS must be 26 or newer"

host_macos_major=$(sw_vers -productVersion | cut -d. -f1)
[[ "$host_macos_major" =~ '^[0-9]+$' ]] && (( host_macos_major >= 26 )) || fail "Release packaging must run on macOS 26 or newer (current: $(sw_vers -productVersion))"

tag="v${version}"
release_dir=${release_dir:A}
mkdir -p "$release_dir"
manifest="$release_dir/BetaDisplay-${version}-release.json"
arm64_app="$release_dir/bundles/arm64/Beta Display.app"
x86_64_app="$release_dir/bundles/x86_64/Beta Display.app"
arm64_zip="$release_dir/BetaDisplay-${version}-arm64.zip"
x86_64_zip="$release_dir/BetaDisplay-${version}-x86_64.zip"
cask_output="$release_dir/Casks/beta-display.rb"
cask_expected="$release_dir/Casks/beta-display.expected.rb"
cask_repository_path="$project_dir/Casks/beta-display.rb"

verify_app_bundle() {
    local app_path="$1"
    [[ -d "$app_path" && -x "$app_path/Contents/MacOS/BetaDisplay" ]] || fail "Invalid app bundle: $app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"

    local gate_output
    gate_output=$("$app_path/Contents/MacOS/BetaDisplay" --deployment-gate)
    local expected_gate="BetaDisplay deployment-gate beta-display-lut-baseline-guard-v2 $version $build_number"
    [[ "$gate_output" == "$expected_gate" ]] || fail "Deployment gate failed for $app_path"

    local self_test_output
    self_test_output=$("$app_path/Contents/MacOS/BetaDisplay" --self-test)
    [[ "$self_test_output" == "Beta Display self-test passed" ]] || fail "Self-test failed for $app_path"
}

build_and_archive() {
    local arch="$1"
    local app_path="$2"
    local archive_path="$3"

    zsh "$project_dir/scripts/build-app.zsh" --arch "$arch" --output "$app_path" --identity -
    verify_app_bundle "$app_path"
    rm -f -- "$archive_path"
    ditto -c -k --keepParent --norsrc "$app_path" "$archive_path"
    verify_archive "$archive_path"
}

verify_archive() {
    local archive_path="$1"
    unzip -t "$archive_path" >/dev/null
    local extraction_dir
    extraction_dir=$(mktemp -d "${TMPDIR%/}/beta-display-release.XXXXXX")
    {
        ditto -x -k "$archive_path" "$extraction_dir"
        verify_app_bundle "$extraction_dir/Beta Display.app"
    } always {
        rm -rf -- "$extraction_dir"
    }
}

write_manifest() {
    local arm64_sha256="$1"
    local x86_64_sha256="$2"
    local source_revision="$3"
    /usr/bin/ruby - "$manifest" "$version" "${release_base_url%/}" "$tested_through_macos" "$source_revision" "$arm64_zip" "$arm64_sha256" "$x86_64_zip" "$x86_64_sha256" <<'RUBY'
require "json"
output, version, base_url, tested, source_revision, arm_path, arm_sha, intel_path, intel_sha = ARGV
payload = {
  "version" => version,
  "source_revision" => source_revision,
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
}

require_clean_pushed_source_head() {
    [[ -z "$(git -C "$project_dir" status --porcelain)" ]] || fail "Preparation requires a clean worktree; commit all source and release-script changes first"
    local head_commit
    head_commit=$(git -C "$project_dir" rev-parse HEAD)
    local remote_main_commit
    remote_main_commit=$(git -C "$project_dir" ls-remote origin refs/heads/main | awk 'NR == 1 { print $1 }')
    [[ "$remote_main_commit" == "$head_commit" ]] || fail "Preparation requires HEAD to be pushed to origin/main"
    [[ -z "$(git -C "$project_dir" ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")" ]] || fail "Remote tag $tag already exists; refusing version reuse"
    print -- "$head_commit"
}

render_cask() {
    local output="$1"
    local arm64_sha256="$2"
    local x86_64_sha256="$3"
    zsh "$project_dir/scripts/render-cask.zsh" \
        --version "$version" \
        --release-base-url "$release_base_url" \
        --arm64-sha256 "$arm64_sha256" \
        --x86_64-sha256 "$x86_64_sha256" \
        --output "$output"
}

require_tagged_pushed_head() {
    [[ -z "$(git -C "$project_dir" status --porcelain)" ]] || fail "Publishing requires a clean worktree"
    local head_commit
    head_commit=$(git -C "$project_dir" rev-parse HEAD)
    local local_tag_commit
    local_tag_commit=$(git -C "$project_dir" rev-parse -q --verify "$tag^{commit}" || true)
    [[ "$local_tag_commit" == "$head_commit" ]] || fail "Release tag $tag must exist and point at HEAD"

    local remote_main_commit
    remote_main_commit=$(git -C "$project_dir" ls-remote origin refs/heads/main | awk 'NR == 1 { print $1 }')
    [[ "$remote_main_commit" == "$head_commit" ]] || fail "HEAD must be pushed to origin/main before publishing"

    local remote_tag_commit
    remote_tag_commit=$(git -C "$project_dir" ls-remote --tags origin "refs/tags/$tag" | awk 'NR == 1 { print $1 }')
    local remote_peeled_tag_commit
    remote_peeled_tag_commit=$(git -C "$project_dir" ls-remote --tags origin "refs/tags/$tag^{}" | awk 'NR == 1 { print $1 }')
    [[ -n "$remote_peeled_tag_commit" ]] && remote_tag_commit="$remote_peeled_tag_commit"
    [[ "$remote_tag_commit" == "$head_commit" ]] || fail "Release tag $tag must be pushed and point at HEAD"
    print -- "$head_commit"
}

require_pushed_release_tag() {
    [[ -z "$(git -C "$project_dir" status --porcelain)" ]] || fail "Draft resumption requires a clean worktree"
    local head_commit
    head_commit=$(git -C "$project_dir" rev-parse HEAD)
    local remote_main_commit
    remote_main_commit=$(git -C "$project_dir" ls-remote origin refs/heads/main | awk 'NR == 1 { print $1 }')
    [[ "$remote_main_commit" == "$head_commit" ]] || fail "HEAD must be pushed to origin/main before resuming a draft"

    local local_tag_commit
    local_tag_commit=$(git -C "$project_dir" rev-parse -q --verify "$tag^{commit}" || true)
    [[ -n "$local_tag_commit" ]] || fail "Release tag $tag does not exist locally"
    local remote_tag_commit
    remote_tag_commit=$(git -C "$project_dir" ls-remote --tags origin "refs/tags/$tag" | awk 'NR == 1 { print $1 }')
    local remote_peeled_tag_commit
    remote_peeled_tag_commit=$(git -C "$project_dir" ls-remote --tags origin "refs/tags/$tag^{}" | awk 'NR == 1 { print $1 }')
    [[ -n "$remote_peeled_tag_commit" ]] && remote_tag_commit="$remote_peeled_tag_commit"
    [[ "$remote_tag_commit" == "$local_tag_commit" ]] || fail "Release tag $tag must be pushed and match the local tag"
    git -C "$project_dir" merge-base --is-ancestor "$local_tag_commit" "$head_commit" || fail "Release tag $tag is not an ancestor of HEAD"
    print -- "$local_tag_commit"
}

verify_prepared_artifacts() {
    local release_commit="${1:-HEAD}"
    [[ -f "$manifest" && -f "$arm64_zip" && -f "$x86_64_zip" ]] || fail "Prepared release files are missing; run --prepare from the pushed source commit"
    local source_revision
    source_revision=$(/usr/bin/ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("source_revision")' "$manifest")
    [[ "$source_revision" =~ '^[0-9a-f]{40}$' ]] || fail "Prepared source revision is invalid"
    local head_parent
    head_parent=$(git -C "$project_dir" rev-parse "$release_commit^")
    [[ "$source_revision" == "$head_parent" ]] || fail "The release tag must be exactly one Cask-only commit after the prepared source revision"
    local changed_files
    changed_files=$(git -C "$project_dir" diff --name-only "$source_revision" "$release_commit")
    [[ "$changed_files" == "Casks/beta-display.rb" ]] || fail "Only Casks/beta-display.rb may differ between the prepared source revision and release tag"

    verify_archive "$arm64_zip"
    verify_archive "$x86_64_zip"
    local arm64_sha256
    local x86_64_sha256
    arm64_sha256=$(shasum -a 256 "$arm64_zip" | awk '{print $1}')
    x86_64_sha256=$(shasum -a 256 "$x86_64_zip" | awk '{print $1}')
    /usr/bin/ruby -rjson - "$manifest" "$version" "$source_revision" "$arm64_sha256" "$x86_64_sha256" <<'RUBY'
manifest, version, source_revision, arm64_sha, x86_64_sha = ARGV
payload = JSON.parse(File.read(manifest))
abort "Prepared manifest version mismatch" unless payload["version"] == version
abort "Prepared manifest source mismatch" unless payload["source_revision"] == source_revision
artifacts = payload.fetch("artifacts")
abort "Prepared arm64 hash mismatch" unless artifacts.dig("arm64", "sha256") == arm64_sha
abort "Prepared x86_64 hash mismatch" unless artifacts.dig("x86_64", "sha256") == x86_64_sha
RUBY
    render_cask "$cask_expected" "$arm64_sha256" "$x86_64_sha256"
    git -C "$project_dir" show "$release_commit:Casks/beta-display.rb" | cmp -s "$cask_expected" - || fail "Tagged Cask does not match the prepared release archives"
}

release_id_for_tag() {
    local release_ids
    release_ids=$(gh api --paginate "repos/$github_release_repo/releases?per_page=100" \
        --jq ".[] | select(.tag_name == \"$tag\") | .id")
    [[ -n "$release_ids" ]] || return 1

    local -a release_id_list
    release_id_list=("${(@f)release_ids}")
    (( ${#release_id_list[@]} == 1 )) || fail "Expected exactly one release for $tag; found ${#release_id_list[@]}"
    [[ "${release_id_list[1]}" =~ '^[0-9]+$' ]] || fail "GitHub returned an invalid release ID for $tag"
    print -- "${release_id_list[1]}"
}

verify_release_assets() {
    local release_id="$1"
    local expected_draft="$2"
    local arm64_sha256
    local x86_64_sha256
    arm64_sha256=$(shasum -a 256 "$arm64_zip" | awk '{print $1}')
    x86_64_sha256=$(shasum -a 256 "$x86_64_zip" | awk '{print $1}')
    gh api "repos/$github_release_repo/releases/$release_id" | /usr/bin/ruby -rjson -e '
      release = JSON.parse(STDIN.read)
      tag, expected_draft, *asset_pairs = ARGV
      expected = asset_pairs.each_slice(2).to_h.transform_values { |digest| "sha256:#{digest}" }
      assets = release.fetch("assets")
      names = assets.map { |asset| asset.fetch("name") }
      abort "Duplicate uploaded asset names" unless names.uniq.length == names.length
      actual = assets.to_h { |asset| [asset.fetch("name"), asset["digest"]] }
      abort "Release tag mismatch" unless release["tag_name"] == tag
      abort "Release draft state mismatch" unless release["draft"] == (expected_draft == "true")
      abort "Uploaded asset set mismatch" unless actual.keys.sort == expected.keys.sort
      expected.each do |name, digest|
        abort "Mismatched uploaded asset: #{name}" unless actual[name] == digest
      end
    ' "$tag" "$expected_draft" "BetaDisplay-${version}-arm64.zip" "$arm64_sha256" "BetaDisplay-${version}-x86_64.zip" "$x86_64_sha256"
}

publish_verified_draft() {
    local release_id="$1"
    gh release edit "$tag" --repo "$github_release_repo" --draft=false --latest --verify-tag
    verify_release_assets "$release_id" false
    local published_release_id
    published_release_id=$(gh api "repos/$github_release_repo/releases/tags/$tag" --jq '.id')
    [[ "$published_release_id" == "$release_id" ]] || fail "Published tag endpoint does not resolve to the verified release"
    print -- "Published and verified: $tag in $github_release_repo"
}

case "$mode" in
    prepare)
        source_revision=$(require_clean_pushed_source_head)
        build_and_archive arm64 "$arm64_app" "$arm64_zip"
        build_and_archive x86_64 "$x86_64_app" "$x86_64_zip"
        arm64_sha256=$(shasum -a 256 "$arm64_zip" | awk '{print $1}')
        x86_64_sha256=$(shasum -a 256 "$x86_64_zip" | awk '{print $1}')
        render_cask "$cask_output" "$arm64_sha256" "$x86_64_sha256"
        cp "$cask_output" "$cask_repository_path"
        cmp -s "$cask_output" "$cask_repository_path" || fail "Generated Cask could not be synchronized into the repository"
        write_manifest "$arm64_sha256" "$x86_64_sha256" "$source_revision"
        print -- "Prepared release assets: $arm64_zip and $x86_64_zip"
        print -- "Prepared source revision: $source_revision"
        print -- "Updated repository Cask: $cask_repository_path"
        print -- "Next: review and commit only Casks/beta-display.rb; push main; tag that commit as $tag; push the tag; then run --publish."
        ;;
    publish)
        release_commit=$(require_tagged_pushed_head)
        verify_prepared_artifacts "$release_commit"
        command -v gh >/dev/null 2>&1 || fail "GitHub CLI is required to publish release assets"
        release_id=""
        if release_id=$(release_id_for_tag); then
            verify_release_assets "$release_id" true
            print -- "Resuming verified draft release $tag (ID $release_id)"
        else
            gh release create "$tag" "$arm64_zip" "$x86_64_zip" \
                --repo "$github_release_repo" \
                --draft \
                --verify-tag \
                --title "Beta Display ${version}" \
                --notes "Fixes repeated LUT gain compounding after display wake/reconfiguration. Adds a fail-closed runtime deployment gate. Ad-hoc-signed builds for macOS 13 and later; release validation recorded through macOS ${tested_through_macos}."
            release_id=$(release_id_for_tag) || fail "Created release $tag could not be resolved by ID"
            verify_release_assets "$release_id" true
        fi
        publish_verified_draft "$release_id"
        ;;
    resume-draft)
        release_commit=$(require_pushed_release_tag)
        verify_prepared_artifacts "$release_commit"
        command -v gh >/dev/null 2>&1 || fail "GitHub CLI is required to publish release assets"
        release_id=$(release_id_for_tag) || fail "No draft release found for $tag"
        verify_release_assets "$release_id" true
        print -- "Resuming verified draft release $tag (ID $release_id)"
        publish_verified_draft "$release_id"
        ;;
esac
