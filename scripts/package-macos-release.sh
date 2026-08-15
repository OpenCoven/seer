#!/bin/bash
set -euo pipefail

# Signing consumes only the two inert preparation artifacts. Until credentials
# are destroyed, every subprocess target is a fixed macOS system path. A local
# test harness may substitute tools only behind the CI-impossible test gate.

SYSTEM_BASE64=/usr/bin/base64
SYSTEM_CODESIGN=/usr/bin/codesign
SYSTEM_CP=/bin/cp
SYSTEM_DITTO=/usr/bin/ditto
SYSTEM_ENV=/usr/bin/env
SYSTEM_HDIUTIL=/usr/bin/hdiutil
SYSTEM_LIPO=/usr/bin/lipo
SYSTEM_LN=/bin/ln
SYSTEM_MKDIR=/bin/mkdir
SYSTEM_MKTEMP=/usr/bin/mktemp
SYSTEM_OPENSSL=/usr/bin/openssl
SYSTEM_PLUTIL=/usr/bin/plutil
SYSTEM_RM=/bin/rm
SYSTEM_RMDIR=/bin/rmdir
SYSTEM_SECURITY=/usr/bin/security
SYSTEM_SHASUM=/usr/bin/shasum
SYSTEM_SPCTL=/usr/sbin/spctl
SYSTEM_STAT=/usr/bin/stat
SYSTEM_TAR=/usr/bin/tar
SYSTEM_UNAME=/usr/bin/uname
SYSTEM_XCRUN=/usr/bin/xcrun

BUILD_ROOT=""
LOCK_DIR=""
RELEASE_DIR=""
WORK_ROOT=""
CREDENTIAL_ROOT=""
KEYCHAIN_PATH=""
CERTIFICATE_PATH=""
API_KEY_PATH=""
ORIGINAL_DEFAULT_KEYCHAIN=""
ORIGINAL_USER_KEYCHAINS=()
LOCK_HELD=0
KEYCHAIN_CREATED=0
DEFAULT_KEYCHAIN_CHANGED=0
USER_KEYCHAIN_LIST_CHANGED=0
DMG_MOUNTED=0
MOUNT_POINT=""
CLEANUP_STARTED=0
CREDENTIAL_PHASE_STARTED=0
TEST_TOOL_DIR=""

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ "${SEER_TEST_MODE:-0}" == "1" ]]; then
  if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    fail "SEER_TEST_MODE is forbidden when GITHUB_ACTIONS=true"
  fi
  if [[ "${SEER_TEST_SYSTEM_TOOLS_DIR:-}" != /* ]] ||
    [[ ! -d "${SEER_TEST_SYSTEM_TOOLS_DIR}" ]] ||
    [[ -L "${SEER_TEST_SYSTEM_TOOLS_DIR}" ]]
  then
    fail "SEER_TEST_SYSTEM_TOOLS_DIR must be an absolute real directory in test mode"
  fi
  TEST_TOOL_DIR="${SEER_TEST_SYSTEM_TOOLS_DIR}"
elif [[ -n "${SEER_TEST_SYSTEM_TOOLS_DIR:-}" || -n "${SEER_TEST_COMMAND_LOG:-}" ]]; then
  fail "test-only signing controls require SEER_TEST_MODE=1"
fi

run_system_tool() {
  local production_path="$1"
  shift
  local executable="${production_path}"
  if [[ "${CREDENTIAL_PHASE_STARTED}" -eq 0 && -n "${SEER_TEST_COMMAND_LOG:-}" ]]; then
    printf '%s\n' "${production_path}" >> "${SEER_TEST_COMMAND_LOG}"
  fi
  if [[ -n "${TEST_TOOL_DIR}" && -x "${TEST_TOOL_DIR}/${production_path##*/}" ]]; then
    executable="${TEST_TOOL_DIR}/${production_path##*/}"
  fi
  "${executable}" "$@"
}

destroy_credentials() {
  local cleanup_failed=0
  set +e
  if [[ -n "${CERTIFICATE_PATH}" ]]; then
    run_system_tool "${SYSTEM_RM}" -f "${CERTIFICATE_PATH}" || cleanup_failed=1
  fi
  if [[ -n "${API_KEY_PATH}" ]]; then
    run_system_tool "${SYSTEM_RM}" -f "${API_KEY_PATH}" || cleanup_failed=1
  fi
  if [[ "${DEFAULT_KEYCHAIN_CHANGED}" -eq 1 && -n "${ORIGINAL_DEFAULT_KEYCHAIN}" ]]; then
    run_system_tool "${SYSTEM_SECURITY}" default-keychain -s "${ORIGINAL_DEFAULT_KEYCHAIN}" >/dev/null 2>&1 ||
      cleanup_failed=1
    DEFAULT_KEYCHAIN_CHANGED=0
  fi
  if [[ "${USER_KEYCHAIN_LIST_CHANGED}" -eq 1 ]]; then
    run_system_tool "${SYSTEM_SECURITY}" list-keychains -d user -s \
      "${ORIGINAL_USER_KEYCHAINS[@]}" >/dev/null 2>&1 ||
      cleanup_failed=1
    USER_KEYCHAIN_LIST_CHANGED=0
  fi
  if [[ -n "${KEYCHAIN_PATH}" ]] &&
    [[ "${KEYCHAIN_CREATED}" -eq 1 || -e "${KEYCHAIN_PATH}" ]]
  then
    run_system_tool "${SYSTEM_SECURITY}" delete-keychain "${KEYCHAIN_PATH}" >/dev/null 2>&1 ||
      cleanup_failed=1
    run_system_tool "${SYSTEM_RM}" -f "${KEYCHAIN_PATH}" || cleanup_failed=1
    KEYCHAIN_CREATED=0
  fi
  if [[ -n "${CREDENTIAL_ROOT}" ]]; then
    run_system_tool "${SYSTEM_RM}" -rf "${CREDENTIAL_ROOT}" || cleanup_failed=1
  fi

  SIGNING_CERTIFICATE_VALUE=""
  SIGNING_CERTIFICATE_PASSWORD_VALUE=""
  SIGNING_IDENTITY_VALUE=""
  SIGNING_TEAM_ID_VALUE=""
  NOTARY_API_ISSUER_VALUE=""
  NOTARY_API_KEY_ID_VALUE=""
  NOTARY_API_KEY_BASE64_VALUE=""
  NOTARY_APPLE_ID_VALUE=""
  NOTARY_APPLE_PASSWORD_VALUE=""
  KEYCHAIN_PASSWORD=""
  NOTARY_ARGS=()
  ORIGINAL_USER_KEYCHAINS=()
  unset \
    SIGNING_CERTIFICATE_VALUE SIGNING_CERTIFICATE_PASSWORD_VALUE \
    SIGNING_IDENTITY_VALUE SIGNING_TEAM_ID_VALUE \
    NOTARY_API_ISSUER_VALUE NOTARY_API_KEY_ID_VALUE NOTARY_API_KEY_BASE64_VALUE \
    NOTARY_APPLE_ID_VALUE NOTARY_APPLE_PASSWORD_VALUE KEYCHAIN_PASSWORD
  for apple_variable in "${!APPLE_@}"; do
    unset "${apple_variable}"
  done
  set -e
  return "${cleanup_failed}"
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ "${CLEANUP_STARTED}" -eq 1 ]]; then
    exit "${status}"
  fi
  CLEANUP_STARTED=1

  if [[ "${DMG_MOUNTED}" -eq 1 && -n "${MOUNT_POINT}" ]]; then
    run_system_tool "${SYSTEM_HDIUTIL}" detach "${MOUNT_POINT}" >/dev/null 2>&1
    DMG_MOUNTED=0
  fi
  destroy_credentials
  if [[ -n "${WORK_ROOT}" ]]; then
    run_system_tool "${SYSTEM_RM}" -rf "${WORK_ROOT}"
  fi
  if [[ "${LOCK_HELD}" -eq 1 && -n "${LOCK_DIR}" ]]; then
    run_system_tool "${SYSTEM_RMDIR}" "${LOCK_DIR}" >/dev/null 2>&1
    LOCK_HELD=0
  fi
  exit "${status}"
}

handle_signal() {
  local signal_number="$1"
  trap - HUP INT TERM
  exit "$((128 + signal_number))"
}

trap cleanup EXIT
trap 'handle_signal 1' HUP
trap 'handle_signal 2' INT
trap 'handle_signal 15' TERM

require_value() {
  local name="$1"
  local value="$2"
  local kind="$3"
  if [[ -z "${value}" ]]; then
    fail "missing required ${kind} variable ${name}"
  fi
}

if ! [[ "${VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  fail "VERSION must be a stable semantic version in X.Y.Z form"
fi
if ! [[ "${BUILD_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
  fail "BUILD_NUMBER must be a positive integer without leading zeros"
fi

# Preserve the established missing-credential order without creating state.
require_value "APPLE_CERTIFICATE" "${APPLE_CERTIFICATE:-}" "signing"
require_value "APPLE_CERTIFICATE_PASSWORD" "${APPLE_CERTIFICATE_PASSWORD:-}" "signing"
require_value "APPLE_SIGNING_IDENTITY" "${APPLE_SIGNING_IDENTITY:-}" "signing"
require_value "APPLE_TEAM_ID" "${APPLE_TEAM_ID:-}" "signing"

API_CREDENTIAL_COUNT=0
[[ -n "${APPLE_API_ISSUER:-}" ]] && API_CREDENTIAL_COUNT=$((API_CREDENTIAL_COUNT + 1))
[[ -n "${APPLE_API_KEY:-}" ]] && API_CREDENTIAL_COUNT=$((API_CREDENTIAL_COUNT + 1))
[[ -n "${APPLE_API_KEY_BASE64:-}" ]] && API_CREDENTIAL_COUNT=$((API_CREDENTIAL_COUNT + 1))
APPLE_ID_CREDENTIAL_COUNT=0
[[ -n "${APPLE_ID:-}" ]] && APPLE_ID_CREDENTIAL_COUNT=$((APPLE_ID_CREDENTIAL_COUNT + 1))
[[ -n "${APPLE_PASSWORD:-}" ]] && APPLE_ID_CREDENTIAL_COUNT=$((APPLE_ID_CREDENTIAL_COUNT + 1))

if [[ "${API_CREDENTIAL_COUNT}" -gt 0 && "${API_CREDENTIAL_COUNT}" -lt 3 ]]; then
  fail "partial API-key notarization credentials; provide APPLE_API_ISSUER, APPLE_API_KEY, and APPLE_API_KEY_BASE64"
fi
if [[ "${APPLE_ID_CREDENTIAL_COUNT}" -gt 0 && "${APPLE_ID_CREDENTIAL_COUNT}" -lt 2 ]]; then
  fail "partial Apple-ID notarization credentials; provide APPLE_ID and APPLE_PASSWORD"
fi
if [[ "${API_CREDENTIAL_COUNT}" -eq 3 && "${APPLE_ID_CREDENTIAL_COUNT}" -eq 2 ]]; then
  fail "provide exactly one notarization credential set; both were provided"
fi
if [[ "${API_CREDENTIAL_COUNT}" -ne 3 && "${APPLE_ID_CREDENTIAL_COUNT}" -ne 2 ]]; then
  fail "exactly one complete notarization credential set is required"
fi

if ! [[ "${APPLE_TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]]; then
  fail "APPLE_TEAM_ID must be a 10-character uppercase Apple team identifier"
fi
if ! [[ "${SOURCE_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]]; then
  fail "SOURCE_COMMIT must be a lowercase 40-character SHA"
fi
if ! [[ "${WORKFLOW_RUN:-}" =~ ^[1-9][0-9]*$ ]]; then
  fail "WORKFLOW_RUN must be a positive decimal identifier without leading zeros"
fi
if ! [[ "${PREPARE_RUNNER_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; then
  fail "PREPARE_RUNNER_ID must be a nonempty stable runner identity"
fi
if ! [[ "${SIGNING_RUNNER_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; then
  fail "SIGNING_RUNNER_ID must be a nonempty stable runner identity"
fi
if [[ "${PREPARE_RUNNER_ID}" == "${SIGNING_RUNNER_ID}" ]]; then
  fail "preparation and signing must use a distinct runner; same runner is forbidden"
fi
if [[ "${SEER_TEST_MODE:-0}" != "1" && "${PREPARE_RUNNER_ID}" == test-* ]]; then
  fail "test runner identities are forbidden outside test mode"
fi

require_value "UNSIGNED_APP_ARCHIVE" "${UNSIGNED_APP_ARCHIVE:-}" "release-input"
require_value "UNSIGNED_APP_ATTESTATION" "${UNSIGNED_APP_ATTESTATION:-}" "release-input"
require_value "UNSIGNED_APP_SHA256" "${UNSIGNED_APP_SHA256:-}" "release-input"
require_value "UNSIGNED_APP_ATTESTATION_SHA256" "${UNSIGNED_APP_ATTESTATION_SHA256:-}" "release-input"
if ! [[ "${UNSIGNED_APP_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
  fail "UNSIGNED_APP_SHA256 must be a lowercase SHA-256 digest"
fi
if ! [[ "${UNSIGNED_APP_ATTESTATION_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
  fail "UNSIGNED_APP_ATTESTATION_SHA256 must be a lowercase SHA-256 digest"
fi

RELEASE_VERSION="${VERSION}"
RELEASE_BUILD_NUMBER="${BUILD_NUMBER}"
RELEASE_SOURCE_COMMIT="${SOURCE_COMMIT}"
RELEASE_WORKFLOW_RUN="${WORKFLOW_RUN}"
RELEASE_PREPARE_RUNNER_ID="${PREPARE_RUNNER_ID}"
RELEASE_SIGNING_RUNNER_ID="${SIGNING_RUNNER_ID}"
RELEASE_INPUT_ARCHIVE="${UNSIGNED_APP_ARCHIVE}"
RELEASE_INPUT_ATTESTATION="${UNSIGNED_APP_ATTESTATION}"
RELEASE_INPUT_SHA256="${UNSIGNED_APP_SHA256}"
RELEASE_INPUT_ATTESTATION_SHA256="${UNSIGNED_APP_ATTESTATION_SHA256}"
SIGNING_CERTIFICATE_VALUE="${APPLE_CERTIFICATE}"
SIGNING_CERTIFICATE_PASSWORD_VALUE="${APPLE_CERTIFICATE_PASSWORD}"
SIGNING_IDENTITY_VALUE="${APPLE_SIGNING_IDENTITY}"
SIGNING_TEAM_ID_VALUE="${APPLE_TEAM_ID}"
NOTARY_API_ISSUER_VALUE="${APPLE_API_ISSUER:-}"
NOTARY_API_KEY_ID_VALUE="${APPLE_API_KEY:-}"
NOTARY_API_KEY_BASE64_VALUE="${APPLE_API_KEY_BASE64:-}"
NOTARY_APPLE_ID_VALUE="${APPLE_ID:-}"
NOTARY_APPLE_PASSWORD_VALUE="${APPLE_PASSWORD:-}"
export -n \
  SIGNING_CERTIFICATE_VALUE SIGNING_CERTIFICATE_PASSWORD_VALUE \
  SIGNING_IDENTITY_VALUE SIGNING_TEAM_ID_VALUE \
  NOTARY_API_ISSUER_VALUE NOTARY_API_KEY_ID_VALUE NOTARY_API_KEY_BASE64_VALUE \
  NOTARY_APPLE_ID_VALUE NOTARY_APPLE_PASSWORD_VALUE
for apple_variable in "${!APPLE_@}"; do
  unset "${apple_variable}"
done

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
if [[ "${SCRIPT_SOURCE}" != /* ]]; then
  SCRIPT_SOURCE="${PWD}/${SCRIPT_SOURCE}"
fi
SCRIPT_DIR="${SCRIPT_SOURCE%/*}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

for required_system_tool in \
  "${SYSTEM_CODESIGN}" "${SYSTEM_LIPO}" "${SYSTEM_MKDIR}" "${SYSTEM_MKTEMP}" \
  "${SYSTEM_PLUTIL}" "${SYSTEM_RM}" "${SYSTEM_RMDIR}" "${SYSTEM_SHASUM}" \
  "${SYSTEM_STAT}" "${SYSTEM_TAR}" "${SYSTEM_UNAME}"
do
  [[ -x "${required_system_tool}" ]] ||
    fail "required fixed system tool is unavailable: ${required_system_tool}"
done
if [[ "$(run_system_tool "${SYSTEM_UNAME}" -m)" != "arm64" ]]; then
  fail "signed macOS packaging requires an Apple Silicon (arm64) host"
fi

case "${RELEASE_INPUT_ARCHIVE}" in
  /*/Seer-unsigned-arm64.tar) ;;
  *) fail "UNSIGNED_APP_ARCHIVE must be an absolute fixed-name path" ;;
esac
case "${RELEASE_INPUT_ATTESTATION}" in
  /*/unsigned-app-attestation.json) ;;
  *) fail "UNSIGNED_APP_ATTESTATION must be an absolute fixed-name path" ;;
esac
if [[ ! -f "${RELEASE_INPUT_ARCHIVE}" || -L "${RELEASE_INPUT_ARCHIVE}" ]]; then
  fail "unsigned-app archive must be a regular non-symlink file"
fi
if [[ ! -f "${RELEASE_INPUT_ATTESTATION}" || -L "${RELEASE_INPUT_ATTESTATION}" ]]; then
  fail "unsigned-app attestation must be a regular non-symlink file"
fi

sha256_file() {
  local output
  output="$(run_system_tool "${SYSTEM_SHASUM}" -a 256 "$1")"
  printf '%s' "${output%% *}"
}

ACTUAL_ARCHIVE_SHA256="$(sha256_file "${RELEASE_INPUT_ARCHIVE}")"
if [[ "${ACTUAL_ARCHIVE_SHA256}" != "${RELEASE_INPUT_SHA256}" ]]; then
  fail "unsigned-app archive SHA-256 mismatch"
fi
ACTUAL_ATTESTATION_SHA256="$(sha256_file "${RELEASE_INPUT_ATTESTATION}")"
if [[ "${ACTUAL_ATTESTATION_SHA256}" != "${RELEASE_INPUT_ATTESTATION_SHA256}" ]]; then
  fail "unsigned-app attestation SHA-256 mismatch"
fi
ACTUAL_ARCHIVE_SIZE="$(run_system_tool "${SYSTEM_STAT}" -f '%z' "${RELEASE_INPUT_ARCHIVE}")"

ATTESTED_APP_DIGEST=""
ATTESTED_ENTRY_COUNT=""
ATTESTED_ENTRY_LIST_SHA256=""
ATTESTED_ARCHIVE_SHA256=""
ATTESTED_ARCHIVE_SIZE=""
ATTESTED_PREPARE_BINDING_SHA256=""
ATTESTED_PREPARE_RUNNER_ID=""
ATTESTED_SOURCE_COMMIT=""

extract_json_string_line() {
  local line="$1"
  local indentation="$2"
  local key="$3"
  local comma="$4"
  local prefix="${indentation}\"${key}\": \""
  local suffix="\"${comma}"
  [[ "${line}" == "${prefix}"*"${suffix}" ]] || return 1
  local value="${line#"${prefix}"}"
  value="${value%"${suffix}"}"
  [[ "${value}" != *'"'* && "${value}" != *'\'* ]] || return 1
  printf '%s' "${value}"
}

ATTESTATION_LINE_NUMBER=0
while IFS= read -r attestation_line || [[ -n "${attestation_line}" ]]; do
  ATTESTATION_LINE_NUMBER=$((ATTESTATION_LINE_NUMBER + 1))
  case "${ATTESTATION_LINE_NUMBER}" in
    1) [[ "${attestation_line}" == "{" ]] || fail "unsigned-app attestation is not canonical" ;;
    2) ATTESTED_APP_DIGEST="$(extract_json_string_line "${attestation_line}" "  " appDigest ,)" ||
      fail "unsigned-app attestation schema is not canonical" ;;
    3) [[ "${attestation_line}" == '  "appDigestAlgorithm": "sha256-files-v1",' ]] ||
      fail "unsigned-app attestation app digest algorithm mismatch" ;;
    4) [[ "${attestation_line}" == '  "architecture": "arm64",' ]] ||
      fail "unsigned-app attestation architecture mismatch" ;;
    5) [[ "${attestation_line}" == '  "archive": {' ]] ||
      fail "unsigned-app attestation archive schema mismatch" ;;
    6)
      [[ "${attestation_line}" =~ ^[[:space:]]{4}\"entryCount\":\ ([1-9][0-9]*),$ ]] ||
        fail "unsigned-app attestation entry count is malformed"
      ATTESTED_ENTRY_COUNT="${BASH_REMATCH[1]}"
      ;;
    7) ATTESTED_ENTRY_LIST_SHA256="$(extract_json_string_line "${attestation_line}" "    " entryListSha256 ,)" ||
      fail "unsigned-app attestation entry-list digest is malformed" ;;
    8) [[ "${attestation_line}" == '    "name": "Seer-unsigned-arm64.tar",' ]] ||
      fail "unsigned-app attestation archive name mismatch" ;;
    9) ATTESTED_ARCHIVE_SHA256="$(extract_json_string_line "${attestation_line}" "    " sha256 ,)" ||
      fail "unsigned-app attestation archive digest is malformed" ;;
    10)
      [[ "${attestation_line}" =~ ^[[:space:]]{4}\"size\":\ ([1-9][0-9]*)$ ]] ||
        fail "unsigned-app attestation archive size is malformed"
      ATTESTED_ARCHIVE_SIZE="${BASH_REMATCH[1]}"
      ;;
    11) [[ "${attestation_line}" == '  },' ]] ||
      fail "unsigned-app attestation archive schema mismatch" ;;
    12) [[ "${attestation_line}" == '  "archiveFormat": "ustar",' ]] ||
      fail "unsigned-app attestation archive format mismatch" ;;
    13) [[ "${attestation_line}" == '  "boundary": "task14-release-v1",' ]] ||
      fail "unsigned-app attestation boundary mismatch" ;;
    14) [[ "${attestation_line}" == '  "boundaryValidation": "passed",' ]] ||
      fail "unsigned-app attestation Task 14 validation was not passed" ;;
    15) [[ "${attestation_line}" == "  \"buildNumber\": \"${RELEASE_BUILD_NUMBER}\"," ]] ||
      fail "unsigned-app attestation buildNumber mismatch" ;;
    16) [[ "${attestation_line}" == '  "bundleIdentifier": "ai.opencoven.seer",' ]] ||
      fail "unsigned-app attestation bundle identifier mismatch" ;;
    17) [[ "${attestation_line}" == '  "prepareBindingAlgorithm": "sha256-lines-v1",' ]] ||
      fail "unsigned-app attestation prepare binding algorithm mismatch" ;;
    18) ATTESTED_PREPARE_BINDING_SHA256="$(extract_json_string_line "${attestation_line}" "  " prepareBindingSha256 ,)" ||
      fail "unsigned-app attestation prepare binding is malformed" ;;
    19) ATTESTED_PREPARE_RUNNER_ID="$(extract_json_string_line "${attestation_line}" "  " prepareRunnerId ,)" ||
      fail "unsigned-app attestation prepare runner identity is malformed" ;;
    20) [[ "${attestation_line}" == '  "schemaVersion": 2,' ]] ||
      fail "unsigned-app attestation schema version mismatch" ;;
    21) ATTESTED_SOURCE_COMMIT="$(extract_json_string_line "${attestation_line}" "  " sourceCommit ,)" ||
      fail "unsigned-app attestation source commit is malformed" ;;
    22) [[ "${attestation_line}" == "  \"version\": \"${RELEASE_VERSION}\"" ]] ||
      fail "unsigned-app attestation version mismatch" ;;
    23) [[ "${attestation_line}" == "}" ]] ||
      fail "unsigned-app attestation is not canonical" ;;
    *) fail "unsigned-app attestation has unexpected fields" ;;
  esac
done < "${RELEASE_INPUT_ATTESTATION}"
if [[ "${ATTESTATION_LINE_NUMBER}" -ne 23 ]]; then
  fail "unsigned-app attestation has missing fields"
fi
for digest in \
  "${ATTESTED_APP_DIGEST}" "${ATTESTED_ENTRY_LIST_SHA256}" \
  "${ATTESTED_ARCHIVE_SHA256}" "${ATTESTED_PREPARE_BINDING_SHA256}"
do
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] ||
    fail "unsigned-app attestation contains a malformed digest"
done
if [[ "${ATTESTED_SOURCE_COMMIT}" != "${RELEASE_SOURCE_COMMIT}" ]]; then
  fail "unsigned-app attestation sourceCommit mismatch"
fi
if [[ "${ATTESTED_PREPARE_RUNNER_ID}" != "${RELEASE_PREPARE_RUNNER_ID}" ]]; then
  fail "unsigned-app attestation PREPARE_RUNNER_ID mismatch"
fi
if [[ "${ATTESTED_PREPARE_RUNNER_ID}" == "${RELEASE_SIGNING_RUNNER_ID}" ]]; then
  fail "attested preparation runner and signing runner must be distinct"
fi
if [[ "${ATTESTED_ARCHIVE_SHA256}" != "${RELEASE_INPUT_SHA256}" ]]; then
  fail "unsigned-app attestation archive SHA-256 mismatch"
fi
if [[ "${ATTESTED_ARCHIVE_SIZE}" != "${ACTUAL_ARCHIVE_SIZE}" ]]; then
  fail "unsigned-app attestation archive size mismatch"
fi

umask 077
BUILD_ROOT="${REPO_ROOT}/build/macos"
LOCK_DIR="${BUILD_ROOT}/.release-package.lock"
RELEASE_DIR="${BUILD_ROOT}/release"
run_system_tool "${SYSTEM_MKDIR}" -p "${BUILD_ROOT}"
if ! run_system_tool "${SYSTEM_MKDIR}" "${LOCK_DIR}"; then
  fail "another macOS release packaging process holds ${LOCK_DIR}"
fi
LOCK_HELD=1
WORK_ROOT="$(run_system_tool "${SYSTEM_MKTEMP}" -d "${BUILD_ROOT}/.release-work.XXXXXXXX")"
UNSIGNED_ROOT="${WORK_ROOT}/unsigned"
ENTRY_LIST_FILE="${WORK_ROOT}/archive-entries"
ENTRY_VERBOSE_FILE="${WORK_ROOT}/archive-entries-verbose"
ENTRY_TYPES_FILE="${WORK_ROOT}/archive-entry-types"
APP_DIGEST_INPUT="${WORK_ROOT}/app-digest-input"
PREPARE_BINDING_INPUT="${WORK_ROOT}/prepare-binding-input"
RUNNER_BINDING_INPUT="${WORK_ROOT}/runner-binding-input"
run_system_tool "${SYSTEM_MKDIR}" "${UNSIGNED_ROOT}"

run_system_tool "${SYSTEM_TAR}" -tf "${RELEASE_INPUT_ARCHIVE}" > "${ENTRY_LIST_FILE}"
run_system_tool "${SYSTEM_TAR}" -tvf "${RELEASE_INPUT_ARCHIVE}" > "${ENTRY_VERBOSE_FILE}"
ACTUAL_ENTRY_LIST_SHA256="$(sha256_file "${ENTRY_LIST_FILE}")"
if [[ "${ACTUAL_ENTRY_LIST_SHA256}" != "${ATTESTED_ENTRY_LIST_SHA256}" ]]; then
  fail "archive exact entry allowlist does not match unsigned-app attestation"
fi

ENTRY_COUNT=0
exec 3< "${ENTRY_VERBOSE_FILE}"
while IFS= read -r archive_entry || [[ -n "${archive_entry}" ]]; do
  IFS= read -r verbose_entry <&3 ||
    fail "archive verbose entry list ended early"
  ENTRY_COUNT=$((ENTRY_COUNT + 1))
  entry_mode="${verbose_entry%% *}"
  verbose_name="${verbose_entry##* }"
  case "${entry_mode}" in
    d*) entry_type=D ;;
    -*) entry_type=F ;;
    *) fail "archive links are forbidden, as are non-file entries: ${archive_entry}" ;;
  esac
  if [[ "${archive_entry}" != "${verbose_name}" ]]; then
    fail "archive entry names must not contain whitespace or link targets"
  fi
  if [[ "${archive_entry}" != "Seer.app/" && "${archive_entry}" != Seer.app/* ]]; then
    fail "unexpected archive root entry: ${archive_entry}"
  fi
  if [[ "${archive_entry}" == /* ||
    "${archive_entry}" == *'\'* ||
    "${archive_entry}" == *:* ||
    "${archive_entry}" == *'//'* ||
    "${archive_entry}" == *'/./'* ||
    "${archive_entry}" == *'/../'* ||
    "${archive_entry}" == ../* ||
    "${archive_entry}" == *'/..' ||
    "${archive_entry}" =~ [[:space:]] ||
    ! "${archive_entry}" =~ ^[A-Za-z0-9._@+/-]+$ ]]
  then
    fail "unsafe archive entry: ${archive_entry}"
  fi
  printf '%s %s\n' "${entry_type}" "${archive_entry}" >> "${ENTRY_TYPES_FILE}"
done < "${ENTRY_LIST_FILE}"
if IFS= read -r extra_verbose_entry <&3; then
  fail "archive verbose entry list contains unexpected entries"
fi
exec 3<&-
if [[ "${ENTRY_COUNT}" != "${ATTESTED_ENTRY_COUNT}" ]]; then
  fail "archive entry count does not match unsigned-app attestation"
fi
if [[ "${ENTRY_COUNT}" -lt 5 || "${ENTRY_COUNT}" -gt 20000 ]]; then
  fail "archive entry count is outside the allowed range"
fi
for required_entry in \
  "D Seer.app/" \
  "D Seer.app/Contents/" \
  "F Seer.app/Contents/Info.plist" \
  "D Seer.app/Contents/MacOS/" \
  "F Seer.app/Contents/MacOS/Seer"
do
  found=0
  while IFS= read -r typed_entry; do
    if [[ "${typed_entry}" == "${required_entry}" ]]; then
      found=1
      break
    fi
  done < "${ENTRY_TYPES_FILE}"
  [[ "${found}" -eq 1 ]] || fail "archive is missing required entry ${required_entry#? }"
done

printf \
  'prepareRunnerId:%s\nsourceCommit:%s\narchiveSha256:%s\nappDigest:%s\nentryListSha256:%s\n' \
  "${ATTESTED_PREPARE_RUNNER_ID}" \
  "${ATTESTED_SOURCE_COMMIT}" \
  "${ATTESTED_ARCHIVE_SHA256}" \
  "${ATTESTED_APP_DIGEST}" \
  "${ATTESTED_ENTRY_LIST_SHA256}" > "${PREPARE_BINDING_INPUT}"
if [[ "$(sha256_file "${PREPARE_BINDING_INPUT}")" != "${ATTESTED_PREPARE_BINDING_SHA256}" ]]; then
  fail "unsigned-app attestation prepare binding mismatch"
fi
printf \
  'prepareRunnerId:%s\nsigningRunnerId:%s\narchiveSha256:%s\nattestationSha256:%s\n' \
  "${RELEASE_PREPARE_RUNNER_ID}" \
  "${RELEASE_SIGNING_RUNNER_ID}" \
  "${ACTUAL_ARCHIVE_SHA256}" \
  "${ACTUAL_ATTESTATION_SHA256}" > "${RUNNER_BINDING_INPUT}"
RELEASE_INPUT_RUNNER_BINDING_SHA256="$(sha256_file "${RUNNER_BINDING_INPUT}")"
[[ "${RELEASE_INPUT_RUNNER_BINDING_SHA256}" =~ ^[0-9a-f]{64}$ ]] ||
  fail "unable to bind runner identities to release inputs"

run_system_tool "${SYSTEM_TAR}" -xf "${RELEASE_INPUT_ARCHIVE}" -C "${UNSIGNED_ROOT}"
SIGNED_APP="${UNSIGNED_ROOT}/Seer.app"
SIGNED_EXECUTABLE="${SIGNED_APP}/Contents/MacOS/Seer"
[[ -d "${SIGNED_APP}" && ! -L "${SIGNED_APP}" ]] ||
  fail "extracted Seer.app must be a real directory"
[[ -f "${SIGNED_EXECUTABLE}" && -x "${SIGNED_EXECUTABLE}" && ! -L "${SIGNED_EXECUTABLE}" ]] ||
  fail "extracted app executable must be a real executable file"

: > "${APP_DIGEST_INPUT}"
while IFS=' ' read -r entry_type archive_entry; do
  if [[ "${entry_type}" == "F" ]]; then
    relative_path="${archive_entry#Seer.app/}"
    extracted_path="${SIGNED_APP}/${relative_path}"
    [[ -f "${extracted_path}" && ! -L "${extracted_path}" ]] ||
      fail "extracted app entry is not a regular file: ${relative_path}"
    file_sha256="$(sha256_file "${extracted_path}")"
    printf '%s:%s\n' "${relative_path}" "${file_sha256}" >> "${APP_DIGEST_INPUT}"
  fi
done < "${ENTRY_TYPES_FILE}"
if [[ "$(sha256_file "${APP_DIGEST_INPUT}")" != "${ATTESTED_APP_DIGEST}" ]]; then
  fail "extracted app digest does not match unsigned-app attestation"
fi

INFO_PLIST="${SIGNED_APP}/Contents/Info.plist"
[[ "$(run_system_tool "${SYSTEM_PLUTIL}" -extract CFBundleShortVersionString raw -o - "${INFO_PLIST}")" == "${RELEASE_VERSION}" ]] ||
  fail "unsigned app CFBundleShortVersionString does not match VERSION"
[[ "$(run_system_tool "${SYSTEM_PLUTIL}" -extract CFBundleVersion raw -o - "${INFO_PLIST}")" == "${RELEASE_BUILD_NUMBER}" ]] ||
  fail "unsigned app CFBundleVersion does not match BUILD_NUMBER"
[[ "$(run_system_tool "${SYSTEM_PLUTIL}" -extract CFBundleIdentifier raw -o - "${INFO_PLIST}")" == "ai.opencoven.seer" ]] ||
  fail "unsigned app bundle identifier is not ai.opencoven.seer"
[[ "$(run_system_tool "${SYSTEM_LIPO}" -archs "${SIGNED_EXECUTABLE}")" == "arm64" ]] ||
  fail "unsigned release executable must contain exactly one arm64 slice"

if ! UNSIGNED_SIGNATURE_DETAILS="$(
  run_system_tool "${SYSTEM_CODESIGN}" -d --verbose=4 "${SIGNED_APP}" 2>&1
)"; then
  fail "unable to inspect unsigned app code-signing precondition"
fi
case $'\n'"${UNSIGNED_SIGNATURE_DETAILS}"$'\n' in
  *$'\nSignature=adhoc\n'*) ;;
  *) fail "unsigned app must carry only its build-time ad-hoc signature" ;;
esac
case $'\n'"${UNSIGNED_SIGNATURE_DETAILS}"$'\n' in
  *$'\nAuthority='*) fail "unsigned app already has a signing authority" ;;
esac
case $'\n'"${UNSIGNED_SIGNATURE_DETAILS}"$'\n' in
  *$'\nTeamIdentifier=not set\n'*) ;;
  *) fail "unsigned app already has a signing team identifier" ;;
esac

# CREDENTIAL PHASE
CREDENTIAL_PHASE_STARTED=1
if [[ -n "${SEER_TEST_COMMAND_LOG:-}" ]]; then
  printf '%s\n' "# CREDENTIAL PHASE" >> "${SEER_TEST_COMMAND_LOG}"
fi
CREDENTIAL_ROOT="$(run_system_tool "${SYSTEM_MKTEMP}" -d "${BUILD_ROOT}/.release-credentials.XXXXXXXX")"
KEYCHAIN_PATH="${CREDENTIAL_ROOT}/release-signing.keychain-db"
CERTIFICATE_PATH="${CREDENTIAL_ROOT}/developer-id.p12"
API_KEY_PATH="${CREDENTIAL_ROOT}/notary-api-key.p8"
APP_ZIP="${WORK_ROOT}/Seer-notarization.zip"
DMG_ROOT="${WORK_ROOT}/dmg-root"
DMG_NAME="Seer-v${RELEASE_VERSION}-arm64.dmg"
WORK_DMG="${WORK_ROOT}/${DMG_NAME}"
MOUNT_POINT="${WORK_ROOT}/mounted-dmg"
FINAL_STAGE="${WORK_ROOT}/release"

ORIGINAL_DEFAULT_KEYCHAIN="$(
  run_system_tool "${SYSTEM_SECURITY}" default-keychain -d user
)"
ORIGINAL_DEFAULT_KEYCHAIN="${ORIGINAL_DEFAULT_KEYCHAIN#"${ORIGINAL_DEFAULT_KEYCHAIN%%[![:space:]]*}"}"
ORIGINAL_DEFAULT_KEYCHAIN="${ORIGINAL_DEFAULT_KEYCHAIN%"${ORIGINAL_DEFAULT_KEYCHAIN##*[![:space:]]}"}"
ORIGINAL_DEFAULT_KEYCHAIN="${ORIGINAL_DEFAULT_KEYCHAIN#\"}"
ORIGINAL_DEFAULT_KEYCHAIN="${ORIGINAL_DEFAULT_KEYCHAIN%\"}"
[[ -n "${ORIGINAL_DEFAULT_KEYCHAIN}" ]] ||
  fail "unable to determine the original default user keychain"

if ! ORIGINAL_USER_KEYCHAIN_LIST="$(
  run_system_tool "${SYSTEM_SECURITY}" list-keychains -d user
)"; then
  fail "unable to determine the original user keychain search list"
fi
while IFS= read -r keychain_line; do
  keychain_line="${keychain_line#"${keychain_line%%[![:space:]]*}"}"
  keychain_line="${keychain_line%"${keychain_line##*[![:space:]]}"}"
  [[ -z "${keychain_line}" ]] && continue
  if [[ "${keychain_line:0:1}" != '"' || "${keychain_line: -1}" != '"' ]]; then
    fail "unable to parse the original user keychain search list"
  fi
  ORIGINAL_USER_KEYCHAINS+=("${keychain_line:1:${#keychain_line}-2}")
done <<< "${ORIGINAL_USER_KEYCHAIN_LIST}"

printf '%s' "${SIGNING_CERTIFICATE_VALUE}" |
  run_system_tool "${SYSTEM_BASE64}" --decode > "${CERTIFICATE_PATH}" ||
  fail "APPLE_CERTIFICATE is not valid base64"
if [[ "${API_CREDENTIAL_COUNT}" -eq 3 ]]; then
  printf '%s' "${NOTARY_API_KEY_BASE64_VALUE}" |
    run_system_tool "${SYSTEM_BASE64}" --decode > "${API_KEY_PATH}" ||
    fail "APPLE_API_KEY_BASE64 is not valid base64"
fi

KEYCHAIN_PASSWORD="$(run_system_tool "${SYSTEM_OPENSSL}" rand -hex 32)"
export -n KEYCHAIN_PASSWORD
KEYCHAIN_CREATED=1
run_system_tool "${SYSTEM_SECURITY}" create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
USER_KEYCHAIN_LIST_CHANGED=1
run_system_tool "${SYSTEM_SECURITY}" list-keychains -d user -s \
  "${KEYCHAIN_PATH}" "${ORIGINAL_USER_KEYCHAINS[@]}"
run_system_tool "${SYSTEM_SECURITY}" set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"
run_system_tool "${SYSTEM_SECURITY}" unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
run_system_tool "${SYSTEM_SECURITY}" import "${CERTIFICATE_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -P "${SIGNING_CERTIFICATE_PASSWORD_VALUE}" \
  -T "${SYSTEM_CODESIGN}" \
  -T "${SYSTEM_SECURITY}"
run_system_tool "${SYSTEM_SECURITY}" set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "${KEYCHAIN_PASSWORD}" \
  "${KEYCHAIN_PATH}"

IDENTITIES="$(run_system_tool "${SYSTEM_SECURITY}" find-identity -v -p codesigning "${KEYCHAIN_PATH}")"
[[ "${IDENTITIES}" == *"\"${SIGNING_IDENTITY_VALUE}\""* ]] ||
  fail "APPLE_SIGNING_IDENTITY was not found in the imported certificate"
DEFAULT_KEYCHAIN_CHANGED=1
run_system_tool "${SYSTEM_SECURITY}" default-keychain -s "${KEYCHAIN_PATH}"

run_system_tool "${SYSTEM_CODESIGN}" \
  --force \
  --keychain "${KEYCHAIN_PATH}" \
  --sign "${SIGNING_IDENTITY_VALUE}" \
  --options runtime \
  --timestamp \
  "${SIGNED_APP}"
run_system_tool "${SYSTEM_CODESIGN}" --verify --deep --strict --verbose=2 "${SIGNED_APP}"

SIGNATURE_DETAILS="$(run_system_tool "${SYSTEM_CODESIGN}" -d --verbose=4 "${SIGNED_APP}" 2>&1)"
case $'\n'"${SIGNATURE_DETAILS}"$'\n' in
  *$'\nAuthority='"${SIGNING_IDENTITY_VALUE}"$'\n'*) ;;
  *) fail "signed app authority does not match APPLE_SIGNING_IDENTITY" ;;
esac
case $'\n'"${SIGNATURE_DETAILS}"$'\n' in
  *$'\nTeamIdentifier='"${SIGNING_TEAM_ID_VALUE}"$'\n'*) ;;
  *) fail "signed app team identifier does not match APPLE_TEAM_ID" ;;
esac
[[ "${SIGNATURE_DETAILS}" == *"Timestamp="* ]] ||
  fail "signed app does not contain a secure timestamp"
[[ "${SIGNATURE_DETAILS}" == *"(runtime)"* ]] ||
  fail "signed app does not enable Hardened Runtime"

NOTARY_ARGS=()
if [[ "${API_CREDENTIAL_COUNT}" -eq 3 ]]; then
  NOTARY_ARGS=(
    --issuer "${NOTARY_API_ISSUER_VALUE}"
    --key-id "${NOTARY_API_KEY_ID_VALUE}"
    --key "${API_KEY_PATH}"
  )
else
  NOTARY_ARGS=(
    --apple-id "${NOTARY_APPLE_ID_VALUE}"
    --password "${NOTARY_APPLE_PASSWORD_VALUE}"
    --team-id "${SIGNING_TEAM_ID_VALUE}"
  )
fi

submit_for_notarization() {
  local artifact_path="$1"
  local response
  local status
  if ! response="$(
    run_system_tool "${SYSTEM_XCRUN}" notarytool submit "${artifact_path}" \
      --wait \
      --output-format json \
      "${NOTARY_ARGS[@]}"
  )"; then
    fail "notarytool submission failed"
  fi
  if ! status="$(
    printf '%s' "${response}" |
      run_system_tool "${SYSTEM_PLUTIL}" -extract status raw -o - -
  )" || [[ "${status}" != "Accepted" ]]; then
    fail "notarization result was not Accepted"
  fi
}

run_system_tool "${SYSTEM_DITTO}" -c -k --keepParent "${SIGNED_APP}" "${APP_ZIP}"
submit_for_notarization "${APP_ZIP}"
run_system_tool "${SYSTEM_RM}" -f "${APP_ZIP}"
run_system_tool "${SYSTEM_XCRUN}" stapler staple "${SIGNED_APP}"
run_system_tool "${SYSTEM_XCRUN}" stapler validate "${SIGNED_APP}"
run_system_tool "${SYSTEM_CODESIGN}" --verify --deep --strict --verbose=2 "${SIGNED_APP}"

run_system_tool "${SYSTEM_MKDIR}" "${DMG_ROOT}"
run_system_tool "${SYSTEM_DITTO}" "${SIGNED_APP}" "${DMG_ROOT}/Seer.app"
run_system_tool "${SYSTEM_LN}" -s /Applications "${DMG_ROOT}/Applications"
run_system_tool "${SYSTEM_HDIUTIL}" create \
  -volname Seer \
  -srcfolder "${DMG_ROOT}" \
  -format UDZO \
  -ov \
  "${WORK_DMG}"

run_system_tool "${SYSTEM_CODESIGN}" \
  --force \
  --keychain "${KEYCHAIN_PATH}" \
  --sign "${SIGNING_IDENTITY_VALUE}" \
  --timestamp \
  "${WORK_DMG}"
run_system_tool "${SYSTEM_CODESIGN}" --verify --strict --verbose=2 "${WORK_DMG}"
DMG_SIGNATURE_DETAILS="$(run_system_tool "${SYSTEM_CODESIGN}" -d --verbose=4 "${WORK_DMG}" 2>&1)"
case $'\n'"${DMG_SIGNATURE_DETAILS}"$'\n' in
  *$'\nAuthority='"${SIGNING_IDENTITY_VALUE}"$'\n'*) ;;
  *) fail "signed DMG authority does not match APPLE_SIGNING_IDENTITY" ;;
esac
case $'\n'"${DMG_SIGNATURE_DETAILS}"$'\n' in
  *$'\nTeamIdentifier='"${SIGNING_TEAM_ID_VALUE}"$'\n'*) ;;
  *) fail "signed DMG team identifier does not match APPLE_TEAM_ID" ;;
esac
[[ "${DMG_SIGNATURE_DETAILS}" == *"Timestamp="* ]] ||
  fail "signed DMG does not contain a secure timestamp"
submit_for_notarization "${WORK_DMG}"
run_system_tool "${SYSTEM_XCRUN}" stapler staple "${WORK_DMG}"
run_system_tool "${SYSTEM_XCRUN}" stapler validate "${WORK_DMG}"
run_system_tool "${SYSTEM_CODESIGN}" --verify --strict --verbose=2 "${WORK_DMG}"
run_system_tool "${SYSTEM_SPCTL}" --assess --type execute --verbose=4 "${SIGNED_APP}"
run_system_tool "${SYSTEM_SPCTL}" --assess --type open --context context:primary-signature --verbose=4 "${WORK_DMG}"

# Credential teardown must succeed before any checkout-provided program executes.
if ! destroy_credentials; then
  fail "credential teardown failed; repository code remains blocked"
fi

run_repo_node() {
  local node_bin
  node_bin="$(command -v node)" || fail "required post-credential command not found: node"
  "${SYSTEM_ENV}" -i \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="${HOME:-${WORK_ROOT}}" \
    "${node_bin}" "$@"
}

run_repo_node "${SCRIPT_DIR}/check-release-boundary.mjs" \
  --app "${SIGNED_APP}" \
  --forbid-path "${REPO_ROOT}" \
  --forbid-path "${WORK_ROOT}"

run_system_tool "${SYSTEM_MKDIR}" "${MOUNT_POINT}"
DMG_MOUNTED=1
run_system_tool "${SYSTEM_HDIUTIL}" attach \
  "${WORK_DMG}" \
  -readonly \
  -nobrowse \
  -noautoopen \
  -mountpoint "${MOUNT_POINT}"
run_repo_node "${SCRIPT_DIR}/check-release-boundary.mjs" \
  --dmg-root "${MOUNT_POINT}" \
  --forbid-path "${REPO_ROOT}" \
  --forbid-path "${WORK_ROOT}"
run_system_tool "${SYSTEM_HDIUTIL}" detach "${MOUNT_POINT}"
DMG_MOUNTED=0

if [[ -e "${RELEASE_DIR}" || -L "${RELEASE_DIR}" ]]; then
  fail "fixed release staging directory already exists: ${RELEASE_DIR}"
fi
run_system_tool "${SYSTEM_MKDIR}" "${FINAL_STAGE}"
run_system_tool "${SYSTEM_CP}" -p "${WORK_DMG}" "${FINAL_STAGE}/${DMG_NAME}"
chmod 0644 "${FINAL_STAGE}/${DMG_NAME}"
run_repo_node "${SCRIPT_DIR}/write-release-manifest.mjs" \
  --version "${RELEASE_VERSION}" \
  --source-commit "${RELEASE_SOURCE_COMMIT}" \
  --workflow-run "${RELEASE_WORKFLOW_RUN}" \
  --notarization accepted \
  --artifact "${FINAL_STAGE}/${DMG_NAME}" \
  --manifest "${FINAL_STAGE}/release-manifest.json" \
  --checksums "${FINAL_STAGE}/SHA256SUMS"
chmod 0644 "${FINAL_STAGE}/release-manifest.json" "${FINAL_STAGE}/SHA256SUMS"
mv "${FINAL_STAGE}" "${RELEASE_DIR}"

echo "release package staged at build/macos/release"
