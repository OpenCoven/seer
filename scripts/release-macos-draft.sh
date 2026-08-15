#!/bin/bash

set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

MODE="${1:-}"
[[ "$#" -eq 1 ]] || fail "usage: release-macos-draft.sh marker|preflight|upload|publish"
case "${MODE}" in
  marker | preflight | upload | publish) ;;
  *) fail "usage: release-macos-draft.sh marker|preflight|upload|publish" ;;
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

GH_REPO="${GH_REPO:-}"
[[ "${GH_REPO}" == "OpenCoven/seer-releases" ]] ||
  fail "release destination must be OpenCoven/seer-releases"
command -v gh >/dev/null 2>&1 || fail "gh is required"

EXPECTED_ASSETS=("Seer-v${VERSION}-arm64.dmg" "SHA256SUMS" "release-manifest.json")
RELEASE_ENDPOINT="repos/${GH_REPO}/releases/tags/${SOURCE_TAG}"
RELEASE_EXISTS=0
RELEASE_DRAFT=""
RELEASE_TAG=""
RELEASE_MARKER=""
RELEASE_ASSET_COUNT=0
RELEASE_ASSETS_VALID=""
RELEASE_ASSETS_COMPLETE=""

query_release() {
  local field_count
  local jq_filter
  local response
  local status

  jq_filter='"draft=\(.draft)\ntag=\(.tag_name)\nmarker=\((.body // "") | split("\n")[0])\nassetCount=\(.assets | length)\nassetsValid=\(all(.assets[].name; . == "'"${EXPECTED_ASSETS[0]}"'" or . == "SHA256SUMS" or . == "release-manifest.json"))\nassetsComplete=\(([.assets[].name] | sort) == ["SHA256SUMS", "'"${EXPECTED_ASSETS[0]}"'", "release-manifest.json"])"'
  set +e
  response="$(gh api "${RELEASE_ENDPOINT}" --jq "${jq_filter}" 2>&1)"
  status=$?
  set -e

  if [[ "${status}" -ne 0 ]]; then
    if /usr/bin/grep -Eq '\(HTTP 404\)|^HTTP/[0-9.]+ 404 ' <<< "${response}"; then
      RELEASE_EXISTS=0
      RELEASE_DRAFT=""
      RELEASE_TAG=""
      RELEASE_MARKER=""
      RELEASE_ASSET_COUNT=0
      RELEASE_ASSETS_VALID=""
      RELEASE_ASSETS_COMPLETE=""
      return
    fi
    fail "unable to inspect release ${SOURCE_TAG}: ${response}"
  fi

  RELEASE_EXISTS=1
  field_count="$(printf '%s\n' "${response}" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  [[ "${field_count}" -eq 6 ]] || fail "release metadata has an invalid shape"
  RELEASE_DRAFT="$(printf '%s\n' "${response}" | /usr/bin/sed -n '1s/^draft=//p')"
  RELEASE_TAG="$(printf '%s\n' "${response}" | /usr/bin/sed -n '2s/^tag=//p')"
  RELEASE_MARKER="$(printf '%s\n' "${response}" | /usr/bin/sed -n '3s/^marker=//p')"
  RELEASE_ASSET_COUNT="$(printf '%s\n' "${response}" | /usr/bin/sed -n '4s/^assetCount=//p')"
  RELEASE_ASSETS_VALID="$(printf '%s\n' "${response}" | /usr/bin/sed -n '5s/^assetsValid=//p')"
  RELEASE_ASSETS_COMPLETE="$(printf '%s\n' "${response}" | /usr/bin/sed -n '6s/^assetsComplete=//p')"
  [[ "${RELEASE_DRAFT}" =~ ^(true|false)$ &&
    "${RELEASE_TAG}" == "${SOURCE_TAG}" &&
    "${RELEASE_ASSET_COUNT}" =~ ^[0-9]+$ &&
    "${RELEASE_ASSETS_VALID}" =~ ^(true|false)$ &&
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
  [[ "${RELEASE_TAG}" == "${SOURCE_TAG}" ]] ||
    fail "draft release tag does not match ${SOURCE_TAG}"
  [[ "${RELEASE_MARKER}" == "${EXPECTED_MARKER}" ]] ||
    fail "draft provenance marker does not match the source commit, tag, repository, and workflow"
  [[ "${RELEASE_ASSETS_VALID}" == "true" ]] ||
    fail "draft contains a foreign release asset"
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

validate_local_upload() {
  RELEASE_DIR="${RELEASE_DIR:-}"
  RELEASE_BODY="${RELEASE_BODY:-}"
  [[ -d "${RELEASE_DIR}" && ! -L "${RELEASE_DIR}" ]] ||
    fail "release directory must be a real directory"
  [[ -f "${RELEASE_BODY}" && ! -L "${RELEASE_BODY}" ]] ||
    fail "release body must be a regular non-symlink file"

  local body_marker
  IFS= read -r body_marker < "${RELEASE_BODY}" ||
    fail "release body must begin with the provenance marker"
  [[ "${body_marker}" == "${EXPECTED_MARKER}" ]] ||
    fail "release body provenance marker does not match"

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
    validate_local_upload
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
  publish)
    inspect_release
    [[ "${RELEASE_EXISTS}" -eq 1 ]] ||
      fail "verified draft release is missing"
    require_complete_remote_assets
    gh release edit "${SOURCE_TAG}" --draft=false
    ;;
esac
