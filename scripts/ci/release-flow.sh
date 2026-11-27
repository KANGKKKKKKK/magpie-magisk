#!/bin/sh
# Release policy. Privileged jobs execute this only from the pinned policy checkout.
set -eu
umask 077

fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
need() { [ -n "$1" ] || fail "$2"; }
valid_tag() { printf '%s\n' "$1" | LC_ALL=C grep -Eq '^v[0-9]{1,9}\.[0-9]{1,9}(\.[0-9]{1,9})?(-[0-9A-Za-z][0-9A-Za-z.-]{0,60})?$'; }
valid_commit() { [ "${#1}" -eq 40 ] && printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[0-9a-f]{40}$'; }
valid_digest() { [ "${#1}" -eq 64 ] && printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$'; }
valid_id() { case "$1" in ''|0|*[!0-9]*) return 1 ;; esac; }
valid_code() { valid_id "$1" && [ "${#1}" -le 10 ] && [ "$1" -le 2147483647 ]; }
sha256() { _sum=$(sha256sum "$1") || return 1; printf '%s\n' "${_sum%% *}"; }

command_name=${1:-}
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"  # never use the artifact/candidate directory as a cwd or an import path
TOOLS="$root/scripts/ci"
repo=${GITHUB_REPOSITORY:?}
work=$(mktemp -d "${RUNNER_TEMP:?}/magpie-policy.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
tag=${TARGET_TAG:-${GITHUB_REF_NAME:-}}
mode=${MODE:-build}
if ! valid_tag "$tag" || [ "$(printf '%s' "$tag" | wc -l)" -ne 0 ]; then fail 'invalid release tag'; fi
case "$mode:$GITHUB_EVENT_NAME:$GITHUB_REF" in
  "build:push:refs/tags/$tag"|"build:workflow_dispatch:refs/tags/$tag"|finalize:workflow_dispatch:refs/heads/main|recover:workflow_dispatch:refs/heads/main) ;;
  *) fail 'new builds must run on the target tag ref; draft finalization/recovery must run on main' ;;
esac

verify_release_kind() {
  case "$tag:${PRERELEASE:-false}" in
    *-*:true) ;;
    *-*:false|*:true) fail 'prerelease intent must match a suffixed tag; push auto-builds only stable tags' ;;
    *:false) ;;
    *) fail 'invalid prerelease choice' ;;
  esac
}

# The repository is public; a read-only git fetch needs no persisted checkout credential.
resolve_ref() {
  git fetch -q --force --no-tags origin '+refs/heads/main:refs/remotes/origin/main' "+refs/tags/$tag:refs/tags/$tag"
  tag_object=$(git rev-parse "refs/tags/$tag")
  [ "$(git cat-file -t "$tag_object")" = tag ] || fail 'annotated tag required'
  commit=$(git rev-parse "$tag_object^{commit}")
  git merge-base --is-ancestor "$commit" origin/main || fail 'target is not on main'
  if [ "$mode" = build ]; then
    [ "$(git rev-parse "$GITHUB_SHA^{commit}")" = "$commit" ] || fail 'event SHA does not match tag'
  fi
  if [ -n "${EXPECTED_TAG_OBJECT:-}" ]; then
    if [ "$tag_object" != "$EXPECTED_TAG_OBJECT" ] || [ "$commit" != "$EXPECTED_COMMIT" ]; then fail 'tag moved after planning'; fi
  fi
}

policy_guard() {
  valid_commit "${POLICY_SHA:-}" || fail 'configure MAGPIE_RELEASE_POLICY_SHA in the protected environment'
  [ "$(git rev-parse HEAD)" = "$POLICY_SHA" ] || fail 'policy checkout does not match approval pin'
  resolve_ref
  git merge-base --is-ancestor "$POLICY_SHA" origin/main || fail 'pinned policy commit is not on main'
  # In tag runs the event workflow still comes from that tag. Refuse an honest
  # invocation of a mismatched workflow, but protect v* and main in repository rules too.
  if [ "$mode" = build ]; then _workflow_commit=$commit; else _workflow_commit=$GITHUB_SHA; fi
  git show "$_workflow_commit:.github/workflows/release.yml" > "$work/event-workflow.yml"
  cmp -s "$work/event-workflow.yml" .github/workflows/release.yml || fail 'event workflow does not match the approved policy checkout'
}

verify_ci() {
  [ "$(gh api "repos/$repo/branches/main" --jq '.protected')" = true ] || fail 'main protection is required before release'
  _attempt=0
  while [ "$_attempt" -lt 12 ]; do
    gh api "repos/$repo/actions/workflows/ci.yml/runs?head_sha=$commit&event=push&per_page=100" > "$work/ci.json"
    _state=$(jq -r --arg c "$commit" '
      [.workflow_runs[] | select(.head_sha == $c and .head_branch == "main")]
      | sort_by(.run_number) | last | if .status == "completed" then .conclusion else "pending" end' "$work/ci.json")
    case "$_state" in success) return 0 ;; pending) ;; *) fail "main CI for $commit: $_state" ;; esac
    _attempt=$((_attempt + 1))
    [ "$_attempt" -ge 12 ] || sleep 10
  done
  fail 'exact main CI was not green within two minutes; wait for it and rerun all jobs'
}

receive_artifact() {
  _kind=$1; _dest=$2
  if ! valid_id "$ARTIFACT_ID" || ! valid_digest "$ARTIFACT_DIGEST"; then fail 'missing/invalid artifact proof'; fi
  gh api "repos/$repo/actions/artifacts/$ARTIFACT_ID" > "$work/artifact.json"
  jq -e --arg id "$ARTIFACT_ID" --arg run "$GITHUB_RUN_ID" --arg name "magpie-$_kind-$GITHUB_RUN_ATTEMPT" \
    --arg sha "$commit" --arg digest "sha256:$ARTIFACT_DIGEST" '
      (.id | tostring) == $id and .name == $name and .expired == false and .digest == $digest
      and (.workflow_run.id | tostring) == $run and .workflow_run.head_sha == $sha
      and .size_in_bytes > 0 and .size_in_bytes <= 16777216' "$work/artifact.json" >/dev/null || fail 'artifact identity/attempt/digest mismatch; rerun all jobs'
  gh api "repos/$repo/actions/artifacts/$ARTIFACT_ID/zip" > "$work/artifact.zip"
  [ "$(sha256 "$work/artifact.zip")" = "$ARTIFACT_DIGEST" ] || fail 'downloaded artifact digest mismatch'
  python3 -I "$TOOLS/release-artifacts.py" unwrap "$_kind" "$work/artifact.zip" "$_dest" --tag "$tag"
}

verify_module() {
  _checked_zip=$1
  python3 -I "$TOOLS/release-artifacts.py" verify --source "$root" --git-ref "$commit" --tag "$tag" --file "$_checked_zip" > "$work/module.json"
  mkdir -p "$work/source/tile-app"
  git show "$commit:tile-app/AndroidManifest.xml" > "$work/source/tile-app/AndroidManifest.xml"
  SOURCE_ROOT="$work/source" EXPECTED_CERT_FILE="$TOOLS/tile-cert-sha256.txt" \
    sh "$TOOLS/verify-release-zip.sh" "$_checked_zip" "$tag"
  version_code=$(jq -er '.versionCode' "$work/module.json")
  zip_digest=$(jq -er '.sha256' "$work/module.json")
}

check_sums() {
  printf '%s  %s\n' "$zip_digest" "magpie-$tag.zip" > "$work/expected-sums"
  cmp -s "$work/expected-sums" "$1/SHA256SUMS" || fail 'SHA256SUMS does not bind the exact ZIP'
}

releases() {
  gh api --paginate 'repos/'"$repo"'/releases?per_page=100' > "$work/release-pages.json"
  jq -s 'add // []' "$work/release-pages.json" > "$work/releases.json"
}

find_release() {
  releases
  jq -e --arg tag "$tag" '[.[] | select(.tag_name == $tag)] | if length == 1 then .[0] else error("expected one release") end' \
    "$work/releases.json" > "$work/release.json" || fail 'target release is missing or ambiguous'
  release_id=$(jq -er .id "$work/release.json")
  valid_id "$release_id" || fail 'bad release ID'
}

check_version_progress() {
  _parent=$(git show "$commit^:module.prop" | sed -n 's/^versionCode=//p')
  if ! valid_code "$_parent" || [ "$version_code" -le "$_parent" ]; then fail 'module versionCode must increase from parent'; fi
  _recent=$(jq -r --arg tag "$tag" '[.[] | select(.tag_name != $tag and (.draft == false and .prerelease == false))] | sort_by(.published_at) | last | .tag_name // empty' "$work/releases.json")
  if [ -n "$_recent" ]; then
    valid_tag "$_recent" || fail 'previous stable release tag is malformed'
    gh release download "$_recent" --repo "$repo" -p "magpie-$_recent.zip" -O "$work/previous.zip"
    _previous=$(unzip -p "$work/previous.zip" module.prop | sed -n 's/^versionCode=//p')
    if ! valid_code "$_previous" || [ "$version_code" -le "$_previous" ]; then fail 'module versionCode must increase from latest stable release'; fi
  fi
}

verify_provenance() {
  _vf_file=$1; _vf_bundle=$2
  # No reusable workflow in this pipeline: the event tag commit is also the signer digest.
  gh attestation verify "$_vf_file" --repo "$repo" --source-ref "refs/tags/$tag" \
    --source-digest "$commit" --signer-workflow "$repo/.github/workflows/release.yml" \
    --signer-digest "$commit" --deny-self-hosted-runners --bundle "$_vf_bundle"
}

read_release_assets() {
  _rd=$1
  mkdir -p "$_rd"
  jq -e --arg zip "magpie-$tag.zip" '([.assets[].name] | sort) == (["SHA256SUMS", "provenance.sigstore.json", $zip] | sort)' \
    "$work/release.json" >/dev/null || fail 'expected exactly three release assets'
  for _name in "magpie-$tag.zip" SHA256SUMS provenance.sigstore.json; do
    _asset_id=$(jq -er --arg n "$_name" '.assets[] | select(.name == $n) | .id' "$work/release.json")
    _asset_digest=$(jq -er --arg n "$_name" '.assets[] | select(.name == $n and .state == "uploaded" and .size > 0 and .size <= 8388608) | .digest' "$work/release.json")
    if ! valid_id "$_asset_id" || ! valid_digest "${_asset_digest#sha256:}"; then fail 'invalid asset ID/digest'; fi
    gh api "repos/$repo/releases/assets/$_asset_id" -H 'Accept: application/octet-stream' > "$_rd/$_name"
    [ "sha256:$(sha256 "$_rd/$_name")" = "$_asset_digest" ] || fail "asset digest mismatch: $_name"
  done
}

verify_release_assets() {
  verify_module "$1/magpie-$tag.zip"
  check_sums "$1"
  verify_provenance "$1/magpie-$tag.zip" "$1/provenance.sigstore.json"
  verify_provenance "$1/SHA256SUMS" "$1/provenance.sigstore.json"
}

assert_release_intent() {
  _intent_pre=$(jq -er 'if (.prerelease | type) == "boolean" then (.prerelease | tostring) else error("invalid release intent") end' "$work/release.json")
  case "$tag:$_intent_pre" in *-*:true) ;; *-*:false|*:true) fail 'release intent does not match tag suffix' ;; *:false) ;; esac
}

check_immutable_setting() {
  # The GET endpoint requires Administration: read. This scoped token must not have
  # write access or be present in signing/build/recovery/update-channel jobs.
  need "${MAGPIE_RELEASE_SETTINGS_TOKEN:-}" 'configure the repository-scoped read-only release settings token; verified draft left untouched'
  GH_TOKEN="$MAGPIE_RELEASE_SETTINGS_TOKEN" gh api "repos/$repo/immutable-releases" \
    -H 'X-GitHub-Api-Version: 2026-03-10' > "$work/immutable-setting.json" || fail 'unable to verify repository immutability; draft left untouched'
  unset MAGPIE_RELEASE_SETTINGS_TOKEN
  jq -e '.enabled == true' "$work/immutable-setting.json" >/dev/null || fail 'enable Immutable releases before publishing; draft left untouched'
}

public_bytes() {
  jq -e --arg tag "$tag" '.tag_name == $tag and .draft == false and .immutable == true' "$work/release.json" >/dev/null ||
    fail 'published release is not reported immutable; the manager channel was not advanced'
  for _public in "magpie-$tag.zip" SHA256SUMS provenance.sigstore.json; do
    jq -e --arg name "$_public" --arg digest "sha256:$(sha256 "$1/$_public")" \
      '[.assets[] | select(.name == $name and .digest == $digest)] | length == 1' "$work/release.json" >/dev/null ||
      fail "published asset metadata differs: $_public"
    _public_url="https://github.com/$repo/releases/download/$tag/$_public"
    curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --retry 4 --retry-all-errors --max-time 35 --max-filesize 8388608 "$_public_url" -o "$work/public"
    cmp -s "$work/public" "$1/$_public" || fail "public asset differs: $_public"
  done
}

case "$command_name" in
  plan)
    resolve_ref
    if [ "$mode" = build ]; then
      verify_release_kind
      verify_ci
      python3 -I "$TOOLS/check-tile-version.py" --repo "$root" --current-tag "$tag"
    fi
    { printf 'tag=%s\ncommit=%s\ntag_object=%s\n' "$tag" "$commit" "$tag_object"; } >> "$GITHUB_OUTPUT" ;;
  fetch-unsigned)
    policy_guard
    receive_artifact unsigned "$OUT_DIR"
    zipalign -c 4 "$OUT_DIR/magpie-tile-unsigned.apk"
    if apksigner verify "$OUT_DIR/magpie-tile-unsigned.apk" >/dev/null 2>&1; then fail 'build handed off an already signed APK'; fi ;;
  sign)
    policy_guard
    need "${MAGPIE_KEYSTORE_B64:-}" 'missing protected signing keystore'
    need "${MAGPIE_KS_PASS:-}" 'missing protected signing password'
    apk="$IN_DIR/magpie-tile-unsigned.apk"
    if [ ! -f "$apk" ] || [ -L "$apk" ]; then fail 'unsigned artifact missing'; fi
    zipalign -c 4 "$apk"
    printf '%s' "$MAGPIE_KEYSTORE_B64" | base64 -d > "$work/keystore.jks"
    unset MAGPIE_KEYSTORE_B64
    apksigner sign --ks "$work/keystore.jks" --ks-key-alias magpie \
      --ks-pass env:MAGPIE_KS_PASS --key-pass env:MAGPIE_KS_PASS --v4-signing-enabled false \
      --out "$work/magpie-tile.apk" "$apk"
    rm -f "$work/keystore.jks"
    unset MAGPIE_KS_PASS
    zipalign -c 4 "$work/magpie-tile.apk"
    mkdir -p "$OUT_DIR"
    python3 -I "$TOOLS/release-artifacts.py" package --source "$root" --git-ref "$commit" --tag "$tag" \
      --apk "$work/magpie-tile.apk" --output "$OUT_DIR"
    verify_module "$OUT_DIR/magpie-$tag.zip"
    printf '%s  %s\n' "$zip_digest" "magpie-$tag.zip" > "$OUT_DIR/SHA256SUMS" ;;
  fetch-signed)
    policy_guard
    receive_artifact signed "$OUT_DIR"
    verify_module "$OUT_DIR/magpie-$tag.zip"
    check_sums "$OUT_DIR" ;;
  publish)
    policy_guard
    if [ "$mode" = build ]; then
      verify_release_kind
      cp "$PROVENANCE_BUNDLE" "$IN_DIR/provenance.sigstore.json"
      verify_release_assets "$IN_DIR"
      releases
      jq -e --arg tag "$tag" 'all(.[]; .tag_name != $tag)' "$work/releases.json" >/dev/null || fail 'same tag release already exists; use finalization or recovery rather than overwrite'
      check_version_progress
      case "${PRERELEASE:-false}" in true) set -- --prerelease ;; false) set -- ;; *) fail 'invalid prerelease choice' ;; esac
      git show "$commit:CHANGELOG.md" > "$work/changelog.md"
      {
        # shellcheck disable=SC2016  # literal Markdown code spans
        printf 'Module **%s**, from commit `%s`.\n\n' "$tag" "$commit"
        awk -v v="$tag" '$0 == "## " v || index($0, "## " v " ") == 1 { f=1; next } f && /^## / { exit } f { print }' "$work/changelog.md"
        # shellcheck disable=SC2016  # literals are Markdown, not substitutions
        printf '\nVerify with `sha256sum -c SHA256SUMS` and:\n\n```sh\ngh attestation verify magpie-%s.zip --repo %s --bundle provenance.sigstore.json --source-ref refs/tags/%s --source-digest %s --signer-workflow %s/.github/workflows/release.yml --signer-digest %s --deny-self-hosted-runners\n```\n' "$tag" "$repo" "$tag" "$commit" "$repo" "$commit"
      } > "$work/notes.md"
      resolve_ref  # use the same annotated object immediately before writing a draft
      gh release create "$tag" "$IN_DIR/magpie-$tag.zip" "$IN_DIR/SHA256SUMS" "$IN_DIR/provenance.sigstore.json" \
        --repo "$repo" --verify-tag --draft --title "$tag" --notes-file "$work/notes.md" "$@"
    fi
    find_release
    case "$mode" in
      build|finalize) jq -e '.draft == true' "$work/release.json" >/dev/null || fail 'must finalize a draft' ;;
      recover) jq -e '.draft == false' "$work/release.json" >/dev/null || fail 'recovery requires a published release' ;;
    esac
    assert_release_intent
    read_release_assets "$work/returned"
    verify_release_assets "$work/returned"
    if [ "$mode" = build ]; then
      for _asset in "magpie-$tag.zip" SHA256SUMS provenance.sigstore.json; do cmp "$IN_DIR/$_asset" "$work/returned/$_asset"; done
    elif [ "$mode" = finalize ]; then
      check_version_progress
      verify_ci
    fi
    if [ "$mode" != recover ]; then
      _prerelease=$(jq -r .prerelease "$work/release.json")
      check_immutable_setting
      resolve_ref
      # Keep the draft's original stable/prerelease intent; no caller override at finalization.
      gh api --method PATCH "repos/$repo/releases/$release_id" -F draft=false > "$work/release.json"
      jq -e --arg pre "$_prerelease" '(.prerelease | tostring) == $pre' "$work/release.json" >/dev/null || fail 'release intent changed unexpectedly'
      # Allow GitHub time to report immutable state, but never move the channel on a mutable release.
      _imm_poll=0
      while [ "$_imm_poll" -lt 6 ]; do
        gh api "repos/$repo/releases/$release_id" > "$work/release.json"
        if jq -e '.immutable == true and .draft == false' "$work/release.json" >/dev/null; then break; fi
        _imm_poll=$((_imm_poll + 1))
        [ "$_imm_poll" -ge 6 ] || sleep 4
      done
    fi
    assert_release_intent
    public_bytes "$work/returned"
    _stable=$(jq -r '.prerelease | not' "$work/release.json")
    { printf 'stable=%s\n' "$_stable"; printf 'digest=%s\nrelease_id=%s\ncode=%s\n' "$zip_digest" "$release_id" "$version_code"; } >> "$GITHUB_OUTPUT" ;;
  update-pr)
    policy_guard
    : "${RELEASE_ID:?}" "${RELEASE_CODE:?}" "${ZIP_DIGEST:?}"
    if ! valid_id "$RELEASE_ID" || ! valid_code "$RELEASE_CODE" || ! valid_digest "$ZIP_DIGEST"; then fail 'missing release proof'; fi
    gh api "repos/$repo/releases/$RELEASE_ID" > "$work/release.json"
    jq -e '.prerelease == false' "$work/release.json" >/dev/null || fail 'only stable releases update the manager channel'
    assert_release_intent
    read_release_assets "$work/returned"
    [ "$(sha256 "$work/returned/magpie-$tag.zip")" = "$ZIP_DIGEST" ] || fail 'release changed after verification'
    public_bytes "$work/returned"
    base=$(git rev-parse origin/main)
    git show "$base:update.json" > "$work/current.json"
    current=$(jq -er '.versionCode' "$work/current.json")
    valid_code "$current" || fail 'invalid current update.json versionCode'
    if [ "$current" -gt "$RELEASE_CODE" ]; then echo 'channel already newer; not downgrading'; exit 0; fi
    url="https://github.com/$repo/releases/download/$tag/magpie-$tag.zip"
    jq -n --arg v "$tag" --argjson c "$RELEASE_CODE" --arg u "$url" --arg l "https://raw.githubusercontent.com/$repo/main/CHANGELOG.md" \
      '{version:$v,versionCode:$c,zipUrl:$u,changelog:$l}' > "$work/update.json"
    if [ "$current" -eq "$RELEASE_CODE" ]; then
      jq -e --slurp '.[0] == .[1]' "$work/current.json" "$work/update.json" >/dev/null || fail 'same versionCode has different metadata; review manually'
      echo 'channel already points at verified release'; exit 0
    fi
    branch="magpie-update/$tag-$ZIP_DIGEST"
    # Deterministic branch identity also recovers runs interrupted after creating the ref,
    # after writing the file, or after opening the PR. Never overwrite divergent work.
    _exists=0
    if git ls-remote --exit-code origin "refs/heads/$branch" > "$work/branch-ref"; then
      _exists=1
    else
      _ref_rc=$?
      [ "$_ref_rc" -eq 2 ] || fail 'unable to read update branch'
    fi
    if [ "$_exists" = 0 ]; then
      gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$base" >/dev/null
    fi
    git fetch -q --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch"
    _tip=$(git rev-parse "refs/remotes/origin/$branch")
    if git merge-base --is-ancestor "$_tip" "$base"; then
      git show "$_tip:update.json" > "$work/branch-update.json"
      jq -e --slurp '.[0] == .[1]' "$work/current.json" "$work/branch-update.json" >/dev/null || fail 'existing update branch is based on a different channel release; review manually'
      _blob=$(git rev-parse "$_tip:update.json")
      jq -n --arg branch "$branch" --arg blob "$_blob" --arg tag "$tag" --arg content "$(base64 -w0 "$work/update.json")" \
        '{branch:$branch,sha:$blob,content:$content,message:("chore: update.json -> " + $tag)}' > "$work/update-request.json"
      gh api -X PUT "repos/$repo/contents/update.json" --input "$work/update-request.json" >/dev/null
    fi
    git fetch -q --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch"
    _tip=$(git rev-parse "refs/remotes/origin/$branch")
    _parent=$(git rev-parse "$_tip^")
    git merge-base --is-ancestor "$_parent" "$base" || fail 'update branch is not based on main'
    [ "$(git diff --name-only "$_parent" "$_tip")" = update.json ] || fail 'update branch contains unrelated changes'
    git show "$_tip:update.json" > "$work/branch-update.json"
    cmp -s "$work/branch-update.json" "$work/update.json" || fail 'existing branch does not match verified update metadata'
    _existing_pr=$(gh pr list --repo "$repo" --base main --head "$branch" --state open --json url,headRefOid,isCrossRepository \
      --jq "[.[] | select(.isCrossRepository | not) | select(.headRefOid == \"$_tip\")] | first | .url // empty")
    if [ -n "$_existing_pr" ]; then printf 'Existing update PR (review before merging): %s\n' "$_existing_pr"; exit 0; fi
    gh pr create --repo "$repo" --base main --head "$branch" --title "chore: update.json -> $tag" \
      --body "Immutable release $tag verified. ZIP SHA-256: $ZIP_DIGEST. Review against the current main update channel before merging." ;;
  *) fail 'unknown release-policy command' ;;
esac
