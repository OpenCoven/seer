#!/bin/bash

set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

MODE="${1:-}"
[[ "$#" -eq 1 ]] || fail "usage: release-macos-draft.sh marker|preflight|upload|capture|publish"
case "${MODE}" in
  marker | preflight | upload | capture | publish) ;;
  *) fail "usage: release-macos-draft.sh marker|preflight|upload|capture|publish" ;;
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
EXPECTED_BODY="${EXPECTED_MARKER}"$'\n\n'"Seer ${VERSION} for Apple Silicon Macs running macOS 14 or later."$'\n'

if [[ "${MODE}" == "marker" ]]; then
  printf '%s\n' "${EXPECTED_MARKER}"
  exit 0
fi

GH_REPO="${GH_REPO:-}"
[[ "${GH_REPO}" == "OpenCoven/seer-releases" ]] ||
  fail "release destination must be OpenCoven/seer-releases"
command -v gh >/dev/null 2>&1 || fail "gh is required"
command -v node >/dev/null 2>&1 || fail "node is required"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STATE_HELPER="${SCRIPT_DIR}/release-macos-draft-state.mjs"
[[ -f "${STATE_HELPER}" && ! -L "${STATE_HELPER}" ]] || fail "release state helper is missing or unsafe"

EXPECTED_ASSETS=("Seer-v${VERSION}-arm64.dmg" "SHA256SUMS" "release-manifest.json")
RELEASE_ENDPOINT="repos/${GH_REPO}/releases/tags/${SOURCE_TAG}"
RELEASE_EXISTS=0
RELEASE_ID=""
RELEASE_DRAFT=""
RELEASE_ASSET_COUNT=0
RELEASE_ASSETS_COMPLETE=""

query_release() {
  local field_count
  local response
  local status
  local summary

  set +e
  response="$(gh api "${RELEASE_ENDPOINT}" 2>&1)"
  status=$?
  set -e

  if [[ "${status}" -ne 0 ]]; then
    if /usr/bin/grep -Eq '\(HTTP 404\)|^HTTP/[0-9.]+ 404 ' <<< "${response}"; then
      RELEASE_EXISTS=0
      RELEASE_ID=""
      RELEASE_DRAFT=""
      RELEASE_ASSET_COUNT=0
      RELEASE_ASSETS_COMPLETE=""
      return
    fi
    fail "unable to inspect release ${SOURCE_TAG}: ${response}"
  fi

  set +e
  summary="$(printf '%s' "${response}" | node "${STATE_HELPER}" inspect 2>&1)"
  status=$?
  set -e
  [[ "${status}" -eq 0 ]] || fail "${summary#error: }"

  RELEASE_EXISTS=1
  field_count="$(printf '%s\n' "${summary}" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  [[ "${field_count}" -eq 4 ]] || fail "release metadata has an invalid shape"
  RELEASE_ID="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '1s/^id=//p')"
  RELEASE_DRAFT="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '2s/^draft=//p')"
  RELEASE_ASSET_COUNT="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '3s/^assetCount=//p')"
  RELEASE_ASSETS_COMPLETE="$(printf '%s\n' "${summary}" | /usr/bin/sed -n '4s/^assetsComplete=//p')"
  [[ "${RELEASE_ID}" =~ ^[1-9][0-9]*$ &&
    "${RELEASE_DRAFT}" =~ ^(true|false)$ &&
    "${RELEASE_ASSET_COUNT}" =~ ^[0-9]+$ &&
    "${RELEASE_ASSETS_COMPLETE}" =~ ^(true|false)$ ]] ||
    fail "release metadata has an invalid shape"
}

inspect_release() {
  query_release
  if [[ "${RELEASE_EXISTS}" -eq 0 ]]; then
    return 0
  fi
  [[ "${RELEASE_DRAFT}" == "true" ]] ||
    fail "existing published release ${SOURCE_TAG} cannot be resumed"
}

require_remote_tag_absent() {
  local response
  local status
  set +e
  response="$(gh api --include "repos/${GH_REPO}/git/ref/tags/${SOURCE_TAG}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    fail "tag ${SOURCE_TAG} exists without a resumable release"
  fi
  /usr/bin/grep -Eq '\(HTTP 404\)|^HTTP/[0-9.]+ 404 ' <<< "${response}" ||
    fail "unable to prove tag ${SOURCE_TAG} is absent"
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
  local headers="${prefix}.headers"
  local metadata="${prefix}.json"
  [[ ! -e "${headers}" && ! -L "${headers}" && ! -e "${metadata}" && ! -L "${metadata}" ]] ||
    fail "release state response paths must not preexist"
  curl --fail-with-body --silent --show-error \
    --request GET \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer ${GH_TOKEN}" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    --dump-header "${headers}" \
    --output "${metadata}" \
    "${GITHUB_API_URL:-https://api.github.com}/repos/${GH_REPO}/releases/tags/${SOURCE_TAG}"
  printf '%s\n%s\n' "${metadata}" "${headers}"
}

download_missing_digests() {
  local metadata="$1"
  local prefix="$2"
  local missing="${prefix}.missing"
  local fallback="${prefix}.assets"
  [[ ! -e "${missing}" && ! -L "${missing}" && ! -e "${fallback}" && ! -L "${fallback}" ]] ||
    fail "release digest fallback paths must not preexist"
  mkdir "${fallback}"
  node "${STATE_HELPER}" missing "${metadata}" > "${missing}"
  local asset_id
  local asset_name
  while IFS=$'\t' read -r asset_id asset_name; do
    [[ "${asset_id}" =~ ^[1-9][0-9]*$ ]] || fail "release asset id is invalid"
    [[ " ${EXPECTED_ASSETS[*]} " == *" ${asset_name} "* ]] || fail "release asset name is invalid"
    curl --fail-with-body --silent --show-error --location \
      --request GET \
      --header "Accept: application/octet-stream" \
      --header "Authorization: Bearer ${GH_TOKEN}" \
      --header "X-GitHub-Api-Version: 2022-11-28" \
      --output "${fallback}/${asset_id}" \
      "${GITHUB_API_URL:-https://api.github.com}/repos/${GH_REPO}/releases/assets/${asset_id}"
  done < "${missing}"
  printf '%s\n' "${fallback}"
}

visibility="$(gh api "repos/${GH_REPO}" --jq '.visibility')"
[[ "${visibility}" == "public" ]] || fail "release destination must be public"

case "${MODE}" in
  preflight)
    inspect_release
    if [[ "${RELEASE_EXISTS}" -eq 0 ]]; then
      require_remote_tag_absent
    fi
    ;;
  upload)
    validate_local_release
    inspect_release
    if [[ "${RELEASE_EXISTS}" -eq 0 ]]; then
      require_remote_tag_absent
      gh release create "${SOURCE_TAG}" --draft \
        --title "Seer ${VERSION}" \
        --notes-file "${RELEASE_BODY}"
      inspect_release
      [[ "${RELEASE_EXISTS}" -eq 1 ]] ||
        fail "new draft release could not be verified"
    fi
    gh release upload "${SOURCE_TAG}" \
      "${RELEASE_DIR}/Seer-v${VERSION}-arm64.dmg" \
      "${RELEASE_DIR}/SHA256SUMS" \
      "${RELEASE_DIR}/release-manifest.json" \
      --clobber
    inspect_release
    require_complete_remote_assets
    ;;
  capture)
    command -v curl >/dev/null 2>&1 || fail "curl is required"
    validate_local_release
    validate_state_paths
    [[ ! -e "${VERIFIED_STATE}" && ! -L "${VERIFIED_STATE}" ]] ||
      fail "verified release state path must not preexist"
    response_paths="$(rest_get_release "${STATE_WORK_DIR}/capture")"
    response_metadata="$(printf '%s\n' "${response_paths}" | /usr/bin/sed -n '1p')"
    response_headers="$(printf '%s\n' "${response_paths}" | /usr/bin/sed -n '2p')"
    [[ -n "${response_metadata}" && -n "${response_headers}" ]] ||
      fail "release state response paths have an invalid shape"
    fallback_dir="$(download_missing_digests "${response_metadata}" "${STATE_WORK_DIR}/capture")"
    node "${STATE_HELPER}" capture \
      "${response_metadata}" "${response_headers}" \
      "${RELEASE_DIR}" "${RELEASE_BODY}" "${VERIFIED_STATE}" "${fallback_dir}"
    ;;
  publish)
    command -v curl >/dev/null 2>&1 || fail "curl is required"
    validate_local_release
    validate_state_paths
    [[ -f "${VERIFIED_STATE}" && ! -L "${VERIFIED_STATE}" ]] ||
      fail "verified release state is missing or unsafe"
    response_paths="$(rest_get_release "${STATE_WORK_DIR}/publish")"
    response_metadata="$(printf '%s\n' "${response_paths}" | /usr/bin/sed -n '1p')"
    response_headers="$(printf '%s\n' "${response_paths}" | /usr/bin/sed -n '2p')"
    [[ -n "${response_metadata}" && -n "${response_headers}" ]] ||
      fail "release state response paths have an invalid shape"
    fallback_dir="$(download_missing_digests "${response_metadata}" "${STATE_WORK_DIR}/publish")"
    publish_binding="$(
      node "${STATE_HELPER}" compare \
        "${response_metadata}" "${response_headers}" \
        "${RELEASE_DIR}" "${RELEASE_BODY}" "${VERIFIED_STATE}" "${fallback_dir}"
    )"
    [[ "$(printf '%s\n' "${publish_binding}" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -eq 2 ]] ||
      fail "verified release binding has an invalid shape"
    release_id="$(printf '%s\n' "${publish_binding}" | /usr/bin/sed -n '1p')"
    release_etag="$(printf '%s\n' "${publish_binding}" | /usr/bin/sed -n '2p')"
    [[ "${release_id}" =~ ^[1-9][0-9]*$ && -n "${release_etag}" ]] ||
      fail "verified release binding has an invalid shape"

    patch_headers="${STATE_WORK_DIR}/publish-patch.headers"
    patch_response="${STATE_WORK_DIR}/publish-patch.json"
    [[ ! -e "${patch_headers}" && ! -L "${patch_headers}" &&
      ! -e "${patch_response}" && ! -L "${patch_response}" ]] ||
      fail "conditional publish response paths must not preexist"
    set +e
    curl --fail-with-body --silent --show-error \
      --request PATCH \
      --header "Accept: application/vnd.github+json" \
      --header "Authorization: Bearer ${GH_TOKEN}" \
      --header "X-GitHub-Api-Version: 2022-11-28" \
      --header "If-Match: ${release_etag}" \
      --data '{"draft":false}' \
      --dump-header "${patch_headers}" \
      --output "${patch_response}" \
      "${GITHUB_API_URL:-https://api.github.com}/repos/${GH_REPO}/releases/${release_id}"
    patch_status=$?
    set -e
    [[ "${patch_status}" -eq 0 ]] ||
      fail "conditional publish failed; release precondition may have changed"
    node "${STATE_HELPER}" verify-patch "${patch_response}" "" "" "" "${VERIFIED_STATE}" ""
    ;;
esac
