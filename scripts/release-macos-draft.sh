#!/bin/bash

if [[ "$-" == *x* ]]; then
  set +x
  echo "error: shell xtrace is prohibited for authenticated release operations" >&2
  exit 1
fi

set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

MODE="${1:-}"
USAGE="usage: release-macos-draft.sh marker|verify-source-tag|acquire-lock|reconcile-published|preflight|upload|capture|publish|release-lock"
[[ "$#" -eq 1 ]] || fail "${USAGE}"
case "${MODE}" in
  marker | verify-source-tag | acquire-lock | reconcile-published | preflight | upload | capture | publish | release-lock) ;;
  *) fail "${USAGE}" ;;
esac

SOURCE_REPOSITORY="${SOURCE_REPOSITORY:-}"
SOURCE_COMMIT="${SOURCE_COMMIT:-}"
SOURCE_TAG="${SOURCE_TAG:-}"
WORKFLOW_REF="${WORKFLOW_REF:-}"
WORKFLOW_RUN="${WORKFLOW_RUN:-}"
VERSION="${VERSION:-}"

[[ "${SOURCE_REPOSITORY}" == "OpenCoven/seer" ]] ||
  fail "source repository must be OpenCoven/seer"
[[ "${SOURCE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] ||
  fail "source commit must be a lowercase 40-character SHA"
[[ "${SOURCE_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "source tag must be vMAJOR.MINOR.PATCH"
[[ "${VERSION}" == "${SOURCE_TAG#v}" ]] ||
  fail "version must match the source tag"
EXPECTED_WORKFLOW_REF="${SOURCE_REPOSITORY}/.github/workflows/release-macos.yml@refs/tags/${SOURCE_TAG}"
[[ "${WORKFLOW_REF}" == "${EXPECTED_WORKFLOW_REF}" ]] ||
  fail "workflow provenance does not match the protected tagged workflow"
[[ "${WORKFLOW_RUN}" =~ ^[1-9][0-9]*$ ]] ||
  fail "workflow run must be a positive canonical identifier"

EXPECTED_MARKER="<!-- seer-release-provenance:{\"schema\":1,\"sourceRepository\":\"${SOURCE_REPOSITORY}\",\"sourceCommit\":\"${SOURCE_COMMIT}\",\"sourceTag\":\"${SOURCE_TAG}\",\"workflowRef\":\"${WORKFLOW_REF}\",\"workflowRun\":\"${WORKFLOW_RUN}\"} -->"

if [[ "${MODE}" == "marker" ]]; then
  printf '%s\n' "${EXPECTED_MARKER}"
  exit 0
fi

WORKFLOW_ATTEMPT="${WORKFLOW_ATTEMPT:-}"
[[ "${WORKFLOW_ATTEMPT}" =~ ^[1-9][0-9]*$ ]] ||
  fail "workflow attempt must be a positive canonical identifier"
command -v gh >/dev/null 2>&1 || fail "gh is required"
command -v node >/dev/null 2>&1 || fail "node is required"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STATE_HELPER="${SCRIPT_DIR}/release-macos-draft-state.mjs"
[[ -f "${STATE_HELPER}" && ! -L "${STATE_HELPER}" ]] ||
  fail "release state helper is missing or unsafe"
GH_API_VERSION="2026-03-10"

if [[ "${SEER_RELEASE_TEST_MODE:-0}" == "1" ]]; then
  [[ "${GITHUB_ACTIONS:-false}" != "true" ]] ||
    fail "SEER_RELEASE_TEST_MODE is forbidden when GITHUB_ACTIONS=true"
  [[ "${SEER_RELEASE_TEST_PLATFORM_VERIFIER:-}" == /* &&
    -f "${SEER_RELEASE_TEST_PLATFORM_VERIFIER}" &&
    ! -L "${SEER_RELEASE_TEST_PLATFORM_VERIFIER}" ]] ||
    fail "test platform verifier must be an absolute regular file"
elif [[ -n "${SEER_RELEASE_TEST_PLATFORM_VERIFIER:-}" ]]; then
  fail "test platform verifier requires SEER_RELEASE_TEST_MODE=1"
fi

resolve_remote_tag_commit() {
  local repository="$1"
  local tag_name="$2"
  local token="$3"
  local response
  local summary
  local object_type
  local object_sha

  response="$(
    GH_TOKEN="${token}" gh api \
      --header "X-GitHub-Api-Version: ${GH_API_VERSION}" \
      "repos/${repository}/git/ref/tags/${tag_name}"
  )"
  summary="$(printf '%s' "${response}" | node "${STATE_HELPER}" ref)"
  object_type="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '1p')"
  object_sha="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '2p')"
  local depth=0
  while [[ "${object_type}" == "tag" ]]; do
    depth=$((depth + 1))
    [[ "${depth}" -le 8 ]] || fail "annotated tag chain exceeds the maximum peel depth"
    response="$(
      GH_TOKEN="${token}" gh api \
        --header "X-GitHub-Api-Version: ${GH_API_VERSION}" \
        "repos/${repository}/git/tags/${object_sha}"
    )"
    summary="$(printf '%s' "${response}" | node "${STATE_HELPER}" tag-target)"
    object_type="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '1p')"
    object_sha="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '2p')"
  done
  [[ "${object_type}" == "commit" && "${object_sha}" =~ ^[0-9a-f]{40}$ ]] ||
    fail "remote tag does not peel to a commit"
  printf '%s\n' "${object_sha}"
}

verify_source_tag() {
  SOURCE_GITHUB_TOKEN="${SOURCE_GITHUB_TOKEN:-}"
  [[ -n "${SOURCE_GITHUB_TOKEN}" ]] ||
    fail "SOURCE_GITHUB_TOKEN with contents:read is required to verify the source tag"
  local resolved
  resolved="$(resolve_remote_tag_commit "${SOURCE_REPOSITORY}" "${SOURCE_TAG}" "${SOURCE_GITHUB_TOKEN}")"
  [[ "${resolved}" == "${SOURCE_COMMIT}" ]] ||
    fail "source tag moved and no longer resolves to the attested source commit"
}

if [[ "${MODE}" == "verify-source-tag" ]]; then
  verify_source_tag
  exit 0
fi

GH_TOKEN="${GH_TOKEN:-}"
[[ -n "${GH_TOKEN}" ]] || fail "GH_TOKEN is required"
GH_REPO="${GH_REPO:-}"
[[ "${GH_REPO}" == "OpenCoven/seer-releases" ]] ||
  fail "release destination must be OpenCoven/seer-releases"
RELEASE_WRITER_LOGIN="${RELEASE_WRITER_LOGIN:-}"
RELEASE_WRITER_ID="${RELEASE_WRITER_ID:-}"
[[ "${RELEASE_WRITER_LOGIN}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] ||
  fail "protected release writer login is invalid"
[[ "${RELEASE_WRITER_ID}" =~ ^[1-9][0-9]*$ ]] ||
  fail "protected release writer ID is invalid"
EXPECTED_ASSETS=("Seer-v${VERSION}-arm64.dmg" "SHA256SUMS" "release-manifest.json")
# GitHub's "get a release by tag name" endpoint only returns published releases;
# it 404s for drafts even with push access. Release discovery must instead use the
# authenticated release *listing* endpoint (which does include drafts) with exact
# tag matching, then address the release by its numeric ID thereafter.
RELEASE_LIST_PAGE_SIZE=100
RELEASE_LIST_MAX_PAGES=50
if [[ "${SEER_RELEASE_TEST_MODE:-0}" == "1" ]]; then
  RELEASE_LIST_PAGE_SIZE="${SEER_RELEASE_TEST_LIST_PAGE_SIZE:-${RELEASE_LIST_PAGE_SIZE}}"
  RELEASE_LIST_MAX_PAGES="${SEER_RELEASE_TEST_LIST_MAX_PAGES:-${RELEASE_LIST_MAX_PAGES}}"
fi
[[ "${RELEASE_LIST_PAGE_SIZE}" =~ ^[1-9][0-9]*$ && "${RELEASE_LIST_PAGE_SIZE}" -le 100 ]] ||
  fail "release list page size must be a positive integer no greater than 100"
[[ "${RELEASE_LIST_MAX_PAGES}" =~ ^[1-9][0-9]*$ ]] ||
  fail "release list page bound must be a positive integer"
LOCK_REF_NAME="seer-release-lock-${SOURCE_TAG}"
LOCK_REF="refs/tags/${LOCK_REF_NAME}"
LOCK_TAG_NAME="${LOCK_REF_NAME}-${SOURCE_COMMIT}-run-${WORKFLOW_RUN}-attempt-${WORKFLOW_ATTEMPT}"
LOCK_MESSAGE="$(
  printf '{"lockSchema":1,"sourceRepository":"%s","sourceCommit":"%s","sourceTag":"%s","workflowRef":"%s","workflowRun":"%s","workflowAttempt":"%s"}\n' \
    "${SOURCE_REPOSITORY}" "${SOURCE_COMMIT}" "${SOURCE_TAG}" "${WORKFLOW_REF}" \
    "${WORKFLOW_RUN}" "${WORKFLOW_ATTEMPT}"
)"
LOCK_MESSAGE+=$'\n'
RELEASE_EXISTS=0
RELEASE_ID=""
RELEASE_DRAFT=""
RELEASE_PRERELEASE=""
RELEASE_ASSET_COUNT=0
RELEASE_ASSETS_COMPLETE=""
DEFAULT_BRANCH=""
DESTINATION_ANCHOR_COMMIT=""

api() {
  gh api --header "X-GitHub-Api-Version: ${GH_API_VERSION}" "$@"
}

source_api() {
  local run_id="$1"
  local run_attempt="$2"
  SOURCE_GITHUB_TOKEN="${SOURCE_GITHUB_TOKEN:-}"
  [[ -n "${SOURCE_GITHUB_TOKEN}" ]] ||
    fail "SOURCE_GITHUB_TOKEN with actions:read is required to reconcile a previous release lock"
  GH_TOKEN="${SOURCE_GITHUB_TOKEN}" gh api \
    --header "X-GitHub-Api-Version: ${GH_API_VERSION}" \
    "repos/${SOURCE_REPOSITORY}/actions/runs/${run_id}/attempts/${run_attempt}"
}

require_repository_governance() {
  local response
  response="$(api user)"
  printf '%s' "${response}" | node "${STATE_HELPER}" identity

  response="$(api "repos/${GH_REPO}")"
  DEFAULT_BRANCH="$(printf '%s' "${response}" | node "${STATE_HELPER}" repository)"
  [[ -n "${DEFAULT_BRANCH}" ]] || fail "release repository default branch is missing"

  response="$(api "repos/${GH_REPO}/immutable-releases")"
  printf '%s' "${response}" | node "${STATE_HELPER}" immutable
}

verify_commit_exists() {
  local commit_sha="$1"
  local response
  response="$(api "repos/${GH_REPO}/git/commits/${commit_sha}")"
  printf '%s' "${response}" | node "${STATE_HELPER}" commit "${commit_sha}"
}

remote_lock_summary() {
  local ref_response
  local ref_summary
  local ref_type
  local ref_sha
  local tag_response

  ref_response="$(api "repos/${GH_REPO}/git/ref/tags/${LOCK_REF_NAME}")" || return $?
  ref_summary="$(printf '%s' "${ref_response}" | node "${STATE_HELPER}" ref)"
  ref_type="$(printf '%s\n' "${ref_summary}" | /usr/bin/sed -n '1p')"
  ref_sha="$(printf '%s\n' "${ref_summary}" | /usr/bin/sed -n '2p')"
  [[ "${ref_type}" == "tag" && "${ref_sha}" =~ ^[0-9a-f]{40}$ ]] ||
    fail "release lock ref does not target an annotated ownership tag"

  tag_response="$(api "repos/${GH_REPO}/git/tags/${ref_sha}")"
  local owner_summary
  owner_summary="$(printf '%s' "${tag_response}" | node "${STATE_HELPER}" lock-owner)"
  local tag_sha
  tag_sha="$(printf '%s\n' "${owner_summary}" | /usr/bin/sed -n '1s/^tagSha=//p')"
  [[ "${tag_sha}" == "${ref_sha}" ]] ||
    fail "release lock tag identity changed"
  printf '%s' "${owner_summary}"
}

verify_remote_lock() {
  local summary
  summary="$(remote_lock_summary)" || fail "release lock is missing or unreadable"
  local current
  local commit_sha
  current="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '5s/^current=//p')"
  commit_sha="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '2s/^commitSha=//p')"
  [[ "${current}" == "true" && "${commit_sha}" =~ ^[0-9a-f]{40}$ ]] ||
    fail "release lock is not owned by this exact workflow attempt"
  verify_commit_exists "${commit_sha}"
  DESTINATION_ANCHOR_COMMIT="${commit_sha}"
  export DESTINATION_ANCHOR_COMMIT
}

acquire_remote_lock() {
  local branch_response
  local branch_summary
  local branch_type
  local commit_sha
  local tag_response
  local tag_summary
  local tag_sha
  local ref_response
  local create_status
  local owner_summary
  local owner_status
  local owner_current
  local owner_run
  local owner_attempt
  local owner_commit

  branch_response="$(api "repos/${GH_REPO}/git/ref/heads/${DEFAULT_BRANCH}")"
  branch_summary="$(printf '%s' "${branch_response}" | node "${STATE_HELPER}" ref)"
  branch_type="$(printf '%s\n' "${branch_summary}" | /usr/bin/sed -n '1p')"
  commit_sha="$(printf '%s\n' "${branch_summary}" | /usr/bin/sed -n '2p')"
  [[ "${branch_type}" == "commit" && "${commit_sha}" =~ ^[0-9a-f]{40}$ ]] ||
    fail "release repository default branch does not point to a commit"
  verify_commit_exists "${commit_sha}"

  tag_response="$(
    api --method POST "repos/${GH_REPO}/git/tags" \
      --raw-field "tag=${LOCK_TAG_NAME}" \
      --raw-field "message=${LOCK_MESSAGE}" \
      --raw-field "object=${commit_sha}" \
      --raw-field "type=commit"
  )"
  tag_summary="$(printf '%s' "${tag_response}" | node "${STATE_HELPER}" lock-tag)"
  tag_sha="$(printf '%s\n' "${tag_summary}" | /usr/bin/sed -n '1p')"
  [[ "${tag_sha}" =~ ^[0-9a-f]{40}$ ]] || fail "release lock tag object is invalid"

  set +e
  ref_response="$(
    api --method POST "repos/${GH_REPO}/git/refs" \
      --raw-field "ref=${LOCK_REF}" \
      --raw-field "sha=${tag_sha}" 2>&1
  )"
  create_status=$?
  set -e
  set +e
  owner_summary="$(remote_lock_summary 2>&1)"
  owner_status=$?
  set -e
  [[ "${owner_status}" -eq 0 ]] ||
    fail "atomic release lock create result could not be reconciled: ${owner_summary}"

  owner_current="$(printf '%s\n' "${owner_summary}" | /usr/bin/sed -n '5s/^current=//p')"
  if [[ "${owner_current}" != "true" ]]; then
    [[ "${create_status}" -ne 0 ]] ||
      fail "release lock ref unexpectedly changed after successful acquisition"
    owner_run="$(printf '%s\n' "${owner_summary}" | /usr/bin/sed -n '3s/^workflowRun=//p')"
    owner_attempt="$(printf '%s\n' "${owner_summary}" | /usr/bin/sed -n '4s/^workflowAttempt=//p')"
    owner_commit="$(printf '%s\n' "${owner_summary}" | /usr/bin/sed -n '2s/^commitSha=//p')"
    [[ "${owner_run}" =~ ^[1-9][0-9]*$ &&
      "${owner_attempt}" =~ ^[1-9][0-9]*$ &&
      "${owner_commit}" =~ ^[0-9a-f]{40}$ ]] ||
      fail "previous release lock ownership is invalid"
    verify_commit_exists "${owner_commit}"

    local run_response
    run_response="$(source_api "${owner_run}" "${owner_attempt}")" ||
      fail "unable to prove the exact previous source workflow attempt terminated"
    printf '%s' "${run_response}" |
      node "${STATE_HELPER}" run-status "${owner_run}" "${owner_attempt}" ||
      fail "previous source workflow attempt is active or unknown; preserving its lock"

    local latest_summary
    latest_summary="$(remote_lock_summary)" ||
      fail "previous release lock disappeared during stale-lock reconciliation"
    [[ "${latest_summary}" == "${owner_summary}" ]] ||
      fail "release lock ownership changed during stale-lock reconciliation"
    api --method DELETE "repos/${GH_REPO}/git/refs/tags/${LOCK_REF_NAME}" >/dev/null

    set +e
    ref_response="$(
      api --method POST "repos/${GH_REPO}/git/refs" \
        --raw-field "ref=${LOCK_REF}" \
        --raw-field "sha=${tag_sha}" 2>&1
    )"
    create_status=$?
    set -e
    set +e
    owner_summary="$(remote_lock_summary 2>&1)"
    owner_status=$?
    set -e
    [[ "${owner_status}" -eq 0 ]] ||
      fail "reclaimed release lock create result could not be reconciled: ${owner_summary}"
    owner_current="$(printf '%s\n' "${owner_summary}" | /usr/bin/sed -n '5s/^current=//p')"
    [[ "${owner_current}" == "true" ]] ||
      fail "reclaimed release lock belongs to a foreign workflow attempt"
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'acquired=true\n' >> "${GITHUB_OUTPUT}"
  fi
  verify_remote_lock
}

release_remote_lock() {
  local summary
  local status
  set +e
  summary="$(remote_lock_summary 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 0 ]]; then
    if /usr/bin/grep -Eq '\(HTTP 404\)|^HTTP/[0-9.]+ 404 ' <<< "${summary}"; then
      return 0
    fi
    fail "release lock could not be reconciled during cleanup: ${summary}"
  fi
  local current
  local commit_sha
  current="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '5s/^current=//p')"
  commit_sha="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '2s/^commitSha=//p')"
  [[ "${current}" == "true" ]] ||
    fail "refusing to remove a release lock owned by another workflow attempt"
  verify_commit_exists "${commit_sha}"
  local latest_summary
  latest_summary="$(remote_lock_summary)" ||
    fail "release lock disappeared during cleanup reconciliation"
  [[ "${latest_summary}" == "${summary}" ]] ||
    fail "release lock ownership changed during cleanup reconciliation"
  api --method DELETE "repos/${GH_REPO}/git/refs/tags/${LOCK_REF_NAME}" >/dev/null
}

query_release() {
  local page
  local response
  local status
  local summary
  local page_count
  local match_count
  local field_count

  RELEASE_EXISTS=0
  RELEASE_ID=""
  RELEASE_DRAFT=""
  RELEASE_PRERELEASE=""
  RELEASE_ASSET_COUNT=0
  RELEASE_ASSETS_COMPLETE=""

  page=1
  while :; do
    [[ "${page}" -le "${RELEASE_LIST_MAX_PAGES}" ]] ||
      fail "release listing exceeded the maximum bounded page count without a definitive result"

    response="$(api "repos/${GH_REPO}/releases?per_page=${RELEASE_LIST_PAGE_SIZE}&page=${page}")"

    set +e
    summary="$(printf '%s' "${response}" | node "${STATE_HELPER}" list-page 2>&1)"
    status=$?
    set -e
    [[ "${status}" -eq 0 ]] || fail "${summary#error: }"

    page_count="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '1s/^pageCount=//p')"
    match_count="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '2s/^matchCount=//p')"
    [[ "${page_count}" =~ ^[0-9]+$ && "${match_count}" =~ ^(0|1)$ ]] ||
      fail "release listing page has an invalid shape"

    if [[ "${match_count}" -eq 1 ]]; then
      field_count="$(printf '%s\n' "${summary}" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
      [[ "${field_count}" -eq 7 ]] || fail "release metadata has an invalid shape"
      RELEASE_ID="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '3s/^id=//p')"
      RELEASE_DRAFT="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '4s/^draft=//p')"
      RELEASE_PRERELEASE="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '5s/^prerelease=//p')"
      RELEASE_ASSET_COUNT="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '6s/^assetCount=//p')"
      RELEASE_ASSETS_COMPLETE="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '7s/^assetsComplete=//p')"
      [[ "${RELEASE_ID}" =~ ^[1-9][0-9]*$ &&
        "${RELEASE_DRAFT}" =~ ^(true|false)$ &&
        "${RELEASE_PRERELEASE}" == "false" &&
        "${RELEASE_ASSET_COUNT}" =~ ^[0-9]+$ &&
        "${RELEASE_ASSETS_COMPLETE}" =~ ^(true|false)$ ]] ||
        fail "release metadata has an invalid shape"
      RELEASE_EXISTS=1
      return
    fi

    if [[ "${page_count}" -lt "${RELEASE_LIST_PAGE_SIZE}" ]]; then
      RELEASE_EXISTS=0
      return
    fi

    page=$((page + 1))
  done
}

inspect_release() {
  query_release
}

destination_tag_commit() {
  resolve_remote_tag_commit "${GH_REPO}" "${SOURCE_TAG}" "${GH_TOKEN}"
}

ensure_destination_tag() {
  [[ "${DESTINATION_ANCHOR_COMMIT}" =~ ^[0-9a-f]{40}$ ]] ||
    fail "destination anchor commit is unavailable"
  local resolved
  local status
  set +e
  resolved="$(destination_tag_commit 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 0 ]]; then
    if ! /usr/bin/grep -Eq '\(HTTP 404\)|^HTTP/[0-9.]+ 404 ' <<< "${resolved}"; then
      fail "unable to inspect destination tag ${SOURCE_TAG}: ${resolved}"
    fi
    set +e
    api --method POST "repos/${GH_REPO}/git/refs" \
      --raw-field "ref=refs/tags/${SOURCE_TAG}" \
      --raw-field "sha=${DESTINATION_ANCHOR_COMMIT}" >/dev/null 2>&1
    set -e
    set +e
    resolved="$(destination_tag_commit 2>&1)"
    status=$?
    set -e
    [[ "${status}" -eq 0 ]] ||
      fail "destination tag create result could not be reconciled: ${resolved}"
  fi
  [[ "${resolved}" == "${DESTINATION_ANCHOR_COMMIT}" ]] ||
    fail "destination tag collision does not resolve to the exact captured anchor commit"
}

verify_destination_tag() {
  [[ "${DESTINATION_ANCHOR_COMMIT}" =~ ^[0-9a-f]{40}$ ]] ||
    fail "destination anchor commit is unavailable"
  local resolved
  resolved="$(destination_tag_commit)" ||
    fail "published release destination tag is missing or unreadable"
  [[ "${resolved}" == "${DESTINATION_ANCHOR_COMMIT}" ]] ||
    fail "published release destination tag does not resolve to the exact captured anchor commit"
}

require_complete_remote_assets() {
  [[ "${RELEASE_ASSET_COUNT}" -eq "${#EXPECTED_ASSETS[@]}" &&
    "${RELEASE_ASSETS_COMPLETE}" == "true" ]] ||
    fail "draft release does not contain the complete public asset allowlist"
}

validate_local_release() {
  RELEASE_DIR="${RELEASE_DIR:-}"
  RELEASE_BODY="${RELEASE_BODY:-}"
  [[ -d "${RELEASE_DIR}" && ! -L "${RELEASE_DIR}" ]] ||
    fail "release directory must be a real directory"
  [[ -f "${RELEASE_BODY}" && ! -L "${RELEASE_BODY}" ]] ||
    fail "release body must be a regular non-symlink file"
  node "${STATE_HELPER}" validate-notes "${RELEASE_BODY}"

  local entry_count
  entry_count="$(
    /usr/bin/find "${RELEASE_DIR}" -mindepth 1 -maxdepth 1 -print |
      /usr/bin/wc -l |
      /usr/bin/tr -d ' '
  )"
  [[ "${entry_count}" -eq "${#EXPECTED_ASSETS[@]}" ]] ||
    fail "local release directory must contain exactly the public asset allowlist"
  local expected
  for expected in "${EXPECTED_ASSETS[@]}"; do
    [[ -f "${RELEASE_DIR}/${expected}" && ! -L "${RELEASE_DIR}/${expected}" ]] ||
      fail "missing or unsafe local release asset ${expected}"
  done
}

validate_state_paths() {
  STATE_WORK_DIR="${STATE_WORK_DIR:-}"
  VERIFIED_STATE="${VERIFIED_STATE:-}"
  [[ -d "${STATE_WORK_DIR}" && ! -L "${STATE_WORK_DIR}" ]] ||
    fail "release state work directory must be a real directory"
  [[ "$(cd "${STATE_WORK_DIR}" && pwd -P)" == "$(cd "$(dirname "${VERIFIED_STATE}")" && pwd -P)" ]] ||
    fail "verified state must be written inside the state work directory"
}

rest_get_release() {
  local prefix="$1"
  local release_id="$2"
  local metadata="${prefix}.json"
  [[ "${release_id}" =~ ^[1-9][0-9]*$ ]] ||
    fail "a verified numeric release ID is required to retrieve release metadata"
  [[ ! -e "${metadata}" && ! -L "${metadata}" ]] ||
    fail "release state response path must not preexist"
  curl --fail-with-body --silent --show-error \
    --request GET \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer ${GH_TOKEN}" \
    --header "X-GitHub-Api-Version: ${GH_API_VERSION}" \
    --output "${metadata}" \
    "${GITHUB_API_URL:-https://api.github.com}/repos/${GH_REPO}/releases/${release_id}"
  printf '%s\n' "${metadata}"
}

download_assets() {
  local metadata="$1"
  local prefix="$2"
  local list="${prefix}.downloads"
  local downloads="${prefix}.assets"
  [[ ! -e "${list}" && ! -L "${list}" && ! -e "${downloads}" && ! -L "${downloads}" ]] ||
    fail "release download paths must not preexist"
  mkdir "${downloads}"
  node "${STATE_HELPER}" downloads "${metadata}" > "${list}"
  local asset_id
  local asset_name
  while IFS=$'\t' read -r asset_id asset_name; do
    [[ "${asset_id}" =~ ^[1-9][0-9]*$ ]] || fail "release asset id is invalid"
    [[ " ${EXPECTED_ASSETS[*]} " == *" ${asset_name} "* ]] ||
      fail "release asset name is invalid"
    curl --fail-with-body --silent --show-error --location \
      --request GET \
      --header "Accept: application/octet-stream" \
      --header "Authorization: Bearer ${GH_TOKEN}" \
      --header "X-GitHub-Api-Version: ${GH_API_VERSION}" \
      --output "${downloads}/${asset_id}" \
      "${GITHUB_API_URL:-https://api.github.com}/repos/${GH_REPO}/releases/assets/${asset_id}"
  done < "${list}"
  printf '%s\n' "${downloads}"
}

verify_published_platform() {
  local directory="$1"
  local dmg="${directory}/Seer-v${VERSION}-arm64.dmg"
  if [[ "${SEER_RELEASE_TEST_MODE:-0}" == "1" ]]; then
    node "${SEER_RELEASE_TEST_PLATFORM_VERIFIER}" "${directory}" "${dmg}" ||
      fail "Apple signature or notarization validation failed"
    return
  fi

  (
    set -euo pipefail
    local mount_point="${STATE_WORK_DIR}/existing-published-mount"
    local mounted=0
    cleanup_published_mount() {
      local status=$?
      trap - EXIT HUP INT TERM
      set +e
      if [[ "${mounted}" -eq 1 ]]; then
        /usr/bin/hdiutil detach "${mount_point}" >/dev/null
      fi
      /bin/rmdir "${mount_point}" >/dev/null 2>&1
      exit "${status}"
    }
    trap cleanup_published_mount EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    /usr/bin/codesign --verify --strict --verbose=2 "${dmg}"
    /usr/bin/xcrun stapler validate "${dmg}"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "${dmg}"

    [[ ! -e "${mount_point}" && ! -L "${mount_point}" ]]
    /bin/mkdir "${mount_point}"
    /usr/bin/hdiutil attach "${dmg}" \
      -readonly \
      -nobrowse \
      -noautoopen \
      -mountpoint "${mount_point}"
    mounted=1

    local app="${mount_point}/Seer.app"
    node "${SCRIPT_DIR}/check-release-boundary.mjs" \
      --dmg-root "${mount_point}" \
      --forbid-path "${GITHUB_WORKSPACE:-${SCRIPT_DIR}}" \
      --forbid-path "${directory}"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "${app}"
    /usr/bin/xcrun stapler validate "${app}"
    /usr/sbin/spctl --assess --type execute --verbose=4 "${app}"
    [[ "$(/usr/bin/lipo -archs "${app}/Contents/MacOS/Seer")" == "arm64" ]]

    /usr/bin/hdiutil detach "${mount_point}"
    mounted=0
    /bin/rmdir "${mount_point}"
  )
}

reconcile_published() {
  verify_remote_lock
  inspect_release
  if [[ "${RELEASE_EXISTS}" -eq 0 || "${RELEASE_DRAFT}" == "true" ]]; then
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      printf 'published=false\n' >> "${GITHUB_OUTPUT}"
    else
      printf 'published=false\n'
    fi
    return
  fi

  require_complete_remote_assets
  verify_destination_tag
  verify_source_tag
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  STATE_WORK_DIR="${STATE_WORK_DIR:-}"
  [[ -d "${STATE_WORK_DIR}" && ! -L "${STATE_WORK_DIR}" ]] ||
    fail "published reconciliation requires a fresh safe state work directory"
  local published_dir="${STATE_WORK_DIR}/existing-published-release"
  local evidence="${STATE_WORK_DIR}/existing-published-state.json"
  [[ ! -e "${published_dir}" && ! -L "${published_dir}" &&
    ! -e "${evidence}" && ! -L "${evidence}" ]] ||
    fail "published reconciliation paths must not preexist"
  /bin/mkdir "${published_dir}"

  local metadata
  local downloads
  metadata="$(rest_get_release "${STATE_WORK_DIR}/existing-published-initial" "${RELEASE_ID}")"
  downloads="$(download_assets "${metadata}" "${STATE_WORK_DIR}/existing-published-initial")"
  node "${STATE_HELPER}" materialize-published \
    "${metadata}" "" "" "" "" "${downloads}" "${published_dir}"
  verify_published_platform "${published_dir}"

  local final_metadata
  local final_downloads
  final_metadata="$(rest_get_release "${STATE_WORK_DIR}/existing-published-final" "${RELEASE_ID}")"
  final_downloads="$(download_assets "${final_metadata}" "${STATE_WORK_DIR}/existing-published-final")"
  node "${STATE_HELPER}" capture-existing-published \
    "${final_metadata}" "" "${published_dir}" "" "${evidence}" "${final_downloads}"
  verify_remote_lock
  verify_source_tag

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'published=true\n'
      printf 'existing-published-state=%s\n' "${evidence}"
      printf 'release-directory=%s\n' "${published_dir}"
    } >> "${GITHUB_OUTPUT}"
  else
    printf 'published=true\nexisting-published-state=%s\nrelease-directory=%s\n' \
      "${evidence}" "${published_dir}"
  fi
}

require_repository_governance

case "${MODE}" in
  acquire-lock)
    acquire_remote_lock
    ;;
  release-lock)
    release_remote_lock
    ;;
  reconcile-published)
    reconcile_published
    ;;
  preflight)
    verify_remote_lock
    inspect_release
    ensure_destination_tag
    verify_remote_lock
    ;;
  upload)
    verify_remote_lock
    inspect_release
    ensure_destination_tag
    if [[ "${RELEASE_EXISTS}" -eq 1 && "${RELEASE_DRAFT}" == "false" ]]; then
      fail "immutable published release must be reconciled before upload; refusing to overwrite it"
    fi
    validate_local_release
    if [[ "${RELEASE_EXISTS}" -eq 0 ]]; then
      gh release create "${SOURCE_TAG}" --draft --verify-tag \
        --target "${DESTINATION_ANCHOR_COMMIT}" \
        --title "Seer ${VERSION}" \
        --notes-file "${RELEASE_BODY}"
      verify_remote_lock
      inspect_release
      [[ "${RELEASE_EXISTS}" -eq 1 ]] ||
        fail "new draft release could not be verified"
    fi
    gh release upload "${SOURCE_TAG}" \
      "${RELEASE_DIR}/Seer-v${VERSION}-arm64.dmg" \
      "${RELEASE_DIR}/SHA256SUMS" \
      "${RELEASE_DIR}/release-manifest.json" \
      --clobber
    verify_remote_lock
    inspect_release
    require_complete_remote_assets
    ;;
  capture)
    command -v curl >/dev/null 2>&1 || fail "curl is required"
    verify_remote_lock
    validate_local_release
    validate_state_paths
    [[ ! -e "${VERIFIED_STATE}" && ! -L "${VERIFIED_STATE}" ]] ||
      fail "verified release state path must not preexist"
    inspect_release
    [[ "${RELEASE_EXISTS}" -eq 1 ]] ||
      fail "release must exist before its state can be captured"
    response_metadata="$(rest_get_release "${STATE_WORK_DIR}/capture" "${RELEASE_ID}")"
    downloads_dir="$(download_assets "${response_metadata}" "${STATE_WORK_DIR}/capture")"
    node "${STATE_HELPER}" capture \
      "${response_metadata}" "" \
      "${RELEASE_DIR}" "${RELEASE_BODY}" "${VERIFIED_STATE}" "${downloads_dir}"
    verify_remote_lock
    ;;
  publish)
    command -v curl >/dev/null 2>&1 || fail "curl is required"
    verify_remote_lock
    if [[ -n "${EXISTING_PUBLISHED_STATE:-}" ]]; then
      [[ -f "${EXISTING_PUBLISHED_STATE}" && ! -L "${EXISTING_PUBLISHED_STATE}" ]] ||
        fail "existing-published-state evidence is missing or unsafe"
      STATE_WORK_DIR="${STATE_WORK_DIR:-}"
      [[ -d "${STATE_WORK_DIR}" && ! -L "${STATE_WORK_DIR}" ]] ||
        fail "existing-published-state verification requires a safe state work directory"
      [[ "$(cd "${STATE_WORK_DIR}" && pwd -P)" == \
        "$(cd "$(dirname "${EXISTING_PUBLISHED_STATE}")" && pwd -P)" ]] ||
        fail "existing-published-state evidence must be inside the state work directory"
      verify_source_tag
      inspect_release
      [[ "${RELEASE_EXISTS}" -eq 1 ]] ||
        fail "release must exist to verify existing-published-state evidence"
      response_metadata="$(rest_get_release "${STATE_WORK_DIR}/existing-published-compare" "${RELEASE_ID}")"
      downloads_dir="$(
        download_assets "${response_metadata}" "${STATE_WORK_DIR}/existing-published-compare"
      )"
      comparison_dir="${STATE_WORK_DIR}/existing-published-compare-release"
      [[ ! -e "${comparison_dir}" && ! -L "${comparison_dir}" ]] ||
        fail "existing-published-state comparison directory must not preexist"
      /bin/mkdir "${comparison_dir}"
      node "${STATE_HELPER}" materialize-published \
        "${response_metadata}" "" "" "" "" "${downloads_dir}" "${comparison_dir}"
      verify_published_platform "${comparison_dir}"
      node "${STATE_HELPER}" compare-existing-published \
        "${response_metadata}" "" "" "" "${EXISTING_PUBLISHED_STATE}" "${downloads_dir}"
      verify_remote_lock
      verify_source_tag
      exit 0
    fi
    inspect_release
    if [[ "${RELEASE_EXISTS}" -eq 1 && "${RELEASE_DRAFT}" == "false" ]]; then
      fail "existing-published-state evidence is required for an immutable published release"
    fi
    [[ "${RELEASE_EXISTS}" -eq 1 ]] ||
      fail "release must exist before it can be published"
    validate_local_release
    validate_state_paths
    [[ -f "${VERIFIED_STATE}" && ! -L "${VERIFIED_STATE}" ]] ||
      fail "verified release state is missing or unsafe"

    verify_remote_lock
    response_metadata="$(rest_get_release "${STATE_WORK_DIR}/publish" "${RELEASE_ID}")"
    downloads_dir="$(download_assets "${response_metadata}" "${STATE_WORK_DIR}/publish")"
    set +e
    release_id="$(
      node "${STATE_HELPER}" compare \
        "${response_metadata}" "" \
        "${RELEASE_DIR}" "${RELEASE_BODY}" "${VERIFIED_STATE}" "${downloads_dir}" 2>&1
    )"
    compare_status=$?
    set -e
    if [[ "${compare_status}" -ne 0 ]]; then
      fail "release is not the exact verified draft; independently validated existing-published-state evidence is required for an immutable published release: ${release_id}"
    fi
    [[ "${release_id}" =~ ^[1-9][0-9]*$ ]] ||
      fail "verified release binding has an invalid shape"

    verify_source_tag
    patch_response="${STATE_WORK_DIR}/publish-patch.json"
    [[ ! -e "${patch_response}" && ! -L "${patch_response}" ]] ||
      fail "publish response path must not preexist"
    set +e
    curl --fail-with-body --silent --show-error \
      --request PATCH \
      --header "Accept: application/vnd.github+json" \
      --header "Authorization: Bearer ${GH_TOKEN}" \
      --header "X-GitHub-Api-Version: ${GH_API_VERSION}" \
      --data '{"draft":false,"prerelease":false}' \
      --output "${patch_response}" \
      "${GITHUB_API_URL:-https://api.github.com}/repos/${GH_REPO}/releases/${release_id}"
    patch_status=$?
    set -e

    post_metadata="$(rest_get_release "${STATE_WORK_DIR}/post-publish" "${release_id}")"
    post_downloads="$(download_assets "${post_metadata}" "${STATE_WORK_DIR}/post-publish")"
    set +e
    published_result="$(
      node "${STATE_HELPER}" compare-published \
        "${post_metadata}" "" \
        "${RELEASE_DIR}" "${RELEASE_BODY}" "${VERIFIED_STATE}" "${post_downloads}" 2>&1
    )"
    published_status=$?
    set -e
    if [[ "${published_status}" -eq 0 ]]; then
      verify_remote_lock
      exit 0
    fi

    set +e
    draft_result="$(
      node "${STATE_HELPER}" compare \
        "${post_metadata}" "" \
        "${RELEASE_DIR}" "${RELEASE_BODY}" "${VERIFIED_STATE}" "${post_downloads}" 2>&1
    )"
    draft_status=$?
    set -e
    if [[ "${draft_status}" -eq 0 ]]; then
      fail "publish PATCH left the exact verified draft unchanged (curl status ${patch_status}); retry is safe"
    fi
    fail "post-publish release state mismatched both the verified draft and canonical published state: ${published_result}"
    ;;
esac
