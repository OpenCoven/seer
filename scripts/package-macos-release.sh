#!/bin/bash
set -euo pipefail

# Signing-only half of the release contract. Task 17 must run this in a fresh
# job on a different machine/runner and download the two preparation artifacts.
# Build tools are intentionally absent: a build and signing must never share a
# user, checkout process tree, or machine.

BUILD_ROOT=""
LOCK_DIR=""
RELEASE_DIR=""
WORK_ROOT=""
CREDENTIAL_ROOT=""
KEYCHAIN_PATH=""
CERTIFICATE_PATH=""
API_KEY_PATH=""
ORIGINAL_DEFAULT_KEYCHAIN=""
LOCK_HELD=0
KEYCHAIN_CREATED=0
DEFAULT_KEYCHAIN_CHANGED=0
DMG_MOUNTED=0
MOUNT_POINT=""
CLEANUP_STARTED=0

fail() {
  echo "error: $*" >&2
  exit 1
}

destroy_credentials() {
  set +e
  if [[ -n "${CERTIFICATE_PATH}" ]]; then
    rm -f "${CERTIFICATE_PATH}"
  fi
  if [[ -n "${API_KEY_PATH}" ]]; then
    rm -f "${API_KEY_PATH}"
  fi
  if [[ "${DEFAULT_KEYCHAIN_CHANGED}" -eq 1 && -n "${ORIGINAL_DEFAULT_KEYCHAIN}" ]]; then
    security default-keychain -s "${ORIGINAL_DEFAULT_KEYCHAIN}" >/dev/null 2>&1
    DEFAULT_KEYCHAIN_CHANGED=0
  fi
  if [[ -n "${KEYCHAIN_PATH}" ]] &&
    [[ "${KEYCHAIN_CREATED}" -eq 1 || -e "${KEYCHAIN_PATH}" ]]
  then
    security delete-keychain "${KEYCHAIN_PATH}" >/dev/null 2>&1
    rm -f "${KEYCHAIN_PATH}"
    KEYCHAIN_CREATED=0
  fi
  if [[ -n "${CREDENTIAL_ROOT}" ]]; then
    rm -rf "${CREDENTIAL_ROOT}"
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
  unset \
    SIGNING_CERTIFICATE_VALUE SIGNING_CERTIFICATE_PASSWORD_VALUE \
    SIGNING_IDENTITY_VALUE SIGNING_TEAM_ID_VALUE \
    NOTARY_API_ISSUER_VALUE NOTARY_API_KEY_ID_VALUE NOTARY_API_KEY_BASE64_VALUE \
    NOTARY_APPLE_ID_VALUE NOTARY_APPLE_PASSWORD_VALUE KEYCHAIN_PASSWORD
  for apple_variable in "${!APPLE_@}"; do
    unset "${apple_variable}"
  done
  set -e
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
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1
    DMG_MOUNTED=0
  fi
  destroy_credentials
  if [[ -n "${WORK_ROOT}" ]]; then
    rm -rf "${WORK_ROOT}"
  fi
  if [[ "${LOCK_HELD}" -eq 1 && -n "${LOCK_DIR}" ]]; then
    rmdir "${LOCK_DIR}" >/dev/null 2>&1
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

# Keep the established missing-credential order before validating artifact
# inputs, while still performing no filesystem side effect.
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
require_value "UNSIGNED_APP_ARCHIVE" "${UNSIGNED_APP_ARCHIVE:-}" "release-input"
require_value "UNSIGNED_APP_ATTESTATION" "${UNSIGNED_APP_ATTESTATION:-}" "release-input"
require_value "UNSIGNED_APP_SHA256" "${UNSIGNED_APP_SHA256:-}" "release-input"
if ! [[ "${UNSIGNED_APP_SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
  fail "UNSIGNED_APP_SHA256 must be a lowercase SHA-256 digest"
fi

RELEASE_VERSION="${VERSION}"
RELEASE_BUILD_NUMBER="${BUILD_NUMBER}"
RELEASE_SOURCE_COMMIT="${SOURCE_COMMIT}"
RELEASE_WORKFLOW_RUN="${WORKFLOW_RUN}"
RELEASE_INPUT_ARCHIVE="${UNSIGNED_APP_ARCHIVE}"
RELEASE_INPUT_ATTESTATION="${UNSIGNED_APP_ATTESTATION}"
RELEASE_INPUT_SHA256="${UNSIGNED_APP_SHA256}"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

for required_command in \
  base64 codesign ditto git grep hdiutil lipo mktemp node openssl plutil \
  security spctl uname xcrun
do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command not found on PATH: ${required_command}"
done
[[ -x /usr/bin/python3 ]] || fail "required system command not found: /usr/bin/python3"

if [[ "$(uname -m)" != "arm64" ]]; then
  fail "signed macOS packaging requires an Apple Silicon (arm64) host"
fi
if [[ "$(git rev-parse --verify HEAD)" != "${RELEASE_SOURCE_COMMIT}" ]]; then
  fail "SOURCE_COMMIT does not match the immutable signing checkout"
fi
if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  fail "signing requires a clean checkout of SOURCE_COMMIT on its distinct runner"
fi

umask 077
BUILD_ROOT="${REPO_ROOT}/build/macos"
LOCK_DIR="${BUILD_ROOT}/.release-package.lock"
RELEASE_DIR="${BUILD_ROOT}/release"
mkdir -p "${BUILD_ROOT}"
if ! mkdir "${LOCK_DIR}"; then
  fail "another macOS release packaging process holds ${LOCK_DIR}"
fi
LOCK_HELD=1
WORK_ROOT="$(mktemp -d "${BUILD_ROOT}/.release-work.XXXXXXXX")"

VALIDATION_ROOT="${WORK_ROOT}/validation"
UNSIGNED_ROOT="${WORK_ROOT}/unsigned"
mkdir "${VALIDATION_ROOT}" "${UNSIGNED_ROOT}"
NODE_BIN="$(command -v node)"
SAFE_HOME="${HOME:-${WORK_ROOT}}"

validate_release_input() {
  local destination="$1"
  /usr/bin/env -i \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="${SAFE_HOME}" \
    /usr/bin/python3 "${SCRIPT_DIR}/macos-release-input.py" validate \
    --archive "${RELEASE_INPUT_ARCHIVE}" \
    --attestation "${RELEASE_INPUT_ATTESTATION}" \
    --expected-archive-sha256 "${RELEASE_INPUT_SHA256}" \
    --expected-source-commit "${RELEASE_SOURCE_COMMIT}" \
    --expected-version "${RELEASE_VERSION}" \
    --expected-build-number "${RELEASE_BUILD_NUMBER}" \
    --destination "${destination}"
}

run_repo_node() {
  /usr/bin/env -i \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="${SAFE_HOME}" \
    "${NODE_BIN}" "$@"
}

# Validate an inert copy first. Repository JavaScript receives a minimal,
# credential-free environment and is never run again until credential teardown.
validate_release_input "${VALIDATION_ROOT}"
VALIDATION_APP="${VALIDATION_ROOT}/Seer.app"
VALIDATION_EXECUTABLE="${VALIDATION_APP}/Contents/MacOS/Seer"
if [[ "$(plutil -extract CFBundleShortVersionString raw -o - "${VALIDATION_APP}/Contents/Info.plist")" != "${RELEASE_VERSION}" ]]; then
  fail "unsigned app CFBundleShortVersionString does not match VERSION"
fi
if [[ "$(plutil -extract CFBundleVersion raw -o - "${VALIDATION_APP}/Contents/Info.plist")" != "${RELEASE_BUILD_NUMBER}" ]]; then
  fail "unsigned app CFBundleVersion does not match BUILD_NUMBER"
fi
if [[ "$(plutil -extract CFBundleIdentifier raw -o - "${VALIDATION_APP}/Contents/Info.plist")" != "ai.opencoven.seer" ]]; then
  fail "unsigned app bundle identifier is not ai.opencoven.seer"
fi
if [[ "$(lipo -archs "${VALIDATION_EXECUTABLE}")" != "arm64" ]]; then
  fail "unsigned release executable must contain exactly one arm64 slice"
fi
run_repo_node "${SCRIPT_DIR}/check-release-boundary.mjs" \
  --app "${VALIDATION_APP}" \
  --forbid-path "${REPO_ROOT}" \
  --forbid-path "${WORK_ROOT}"

# Re-read, re-hash, and re-extract after the repository boundary process exits.
# Mutable or mismatched artifact bytes cannot cross into the signing phase.
validate_release_input "${UNSIGNED_ROOT}"
rm -rf "${VALIDATION_ROOT}"
SIGNED_APP="${UNSIGNED_ROOT}/Seer.app"
SIGNED_EXECUTABLE="${SIGNED_APP}/Contents/MacOS/Seer"
if [[ "$(plutil -extract CFBundleIdentifier raw -o - "${SIGNED_APP}/Contents/Info.plist")" != "ai.opencoven.seer" ]] ||
  [[ "$(lipo -archs "${SIGNED_EXECUTABLE}")" != "arm64" ]]
then
  fail "unsigned app identity changed after boundary validation"
fi

# Nothing above this line creates a credential file, keychain, or child process
# carrying signing values. Only trusted system signing/notary/DMG tools run
# between this point and destroy_credentials.
CREDENTIAL_ROOT="$(mktemp -d "${BUILD_ROOT}/.release-credentials.XXXXXXXX")"
KEYCHAIN_PATH="${CREDENTIAL_ROOT}/release-signing.keychain-db"
CERTIFICATE_PATH="${CREDENTIAL_ROOT}/developer-id.p12"
API_KEY_PATH="${CREDENTIAL_ROOT}/notary-api-key.p8"
APP_ZIP="${WORK_ROOT}/Seer-notarization.zip"
DMG_ROOT="${WORK_ROOT}/dmg-root"
DMG_NAME="Seer-v${RELEASE_VERSION}-arm64.dmg"
WORK_DMG="${WORK_ROOT}/${DMG_NAME}"
MOUNT_POINT="${WORK_ROOT}/mounted-dmg"
FINAL_STAGE="${WORK_ROOT}/release"
ENTITLEMENTS_PATH="${REPO_ROOT}/apps/macos/Seer/Config/Seer.entitlements"

ORIGINAL_DEFAULT_KEYCHAIN="$(
  security default-keychain -d user |
    sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
)"
if [[ -z "${ORIGINAL_DEFAULT_KEYCHAIN}" ]]; then
  fail "unable to determine the original default user keychain"
fi

printf "%s" "${SIGNING_CERTIFICATE_VALUE}" | base64 --decode > "${CERTIFICATE_PATH}" ||
  fail "APPLE_CERTIFICATE is not valid base64"
if [[ "${API_CREDENTIAL_COUNT}" -eq 3 ]]; then
  printf "%s" "${NOTARY_API_KEY_BASE64_VALUE}" | base64 --decode > "${API_KEY_PATH}" ||
    fail "APPLE_API_KEY_BASE64 is not valid base64"
fi

KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
export -n KEYCHAIN_PASSWORD
KEYCHAIN_CREATED=1
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security import "${CERTIFICATE_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -P "${SIGNING_CERTIFICATE_PASSWORD_VALUE}" \
  -T "$(command -v codesign)" \
  -T "$(command -v security)"
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "${KEYCHAIN_PASSWORD}" \
  "${KEYCHAIN_PATH}"

IDENTITIES="$(security find-identity -v -p codesigning "${KEYCHAIN_PATH}")"
if [[ "${IDENTITIES}" != *"\"${SIGNING_IDENTITY_VALUE}\""* ]]; then
  fail "APPLE_SIGNING_IDENTITY was not found in the imported certificate"
fi

DEFAULT_KEYCHAIN_CHANGED=1
security default-keychain -s "${KEYCHAIN_PATH}"

codesign \
  --force \
  --sign "${SIGNING_IDENTITY_VALUE}" \
  --options runtime \
  --timestamp \
  --entitlements "${ENTITLEMENTS_PATH}" \
  "${SIGNED_APP}"
codesign --verify --deep --strict --verbose=2 "${SIGNED_APP}"

SIGNATURE_DETAILS="$(codesign -d --verbose=4 "${SIGNED_APP}" 2>&1)"
grep -Fqx "Authority=${SIGNING_IDENTITY_VALUE}" <<< "${SIGNATURE_DETAILS}" ||
  fail "signed app authority does not match APPLE_SIGNING_IDENTITY"
grep -Fqx "TeamIdentifier=${SIGNING_TEAM_ID_VALUE}" <<< "${SIGNATURE_DETAILS}" ||
  fail "signed app team identifier does not match APPLE_TEAM_ID"
grep -Eq '^Timestamp=' <<< "${SIGNATURE_DETAILS}" ||
  fail "signed app does not contain a secure timestamp"
grep -Eq '^flags=.*\(runtime\)' <<< "${SIGNATURE_DETAILS}" ||
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
  if ! response="$(
    xcrun notarytool submit "${artifact_path}" \
      --wait \
      --output-format json \
      "${NOTARY_ARGS[@]}"
  )"; then
    fail "notarytool submission failed"
  fi
  if ! /usr/bin/python3 -c \
    'import json, sys; raise SystemExit(0 if json.load(sys.stdin).get("status") == "Accepted" else 1)' \
    <<< "${response}"
  then
    fail "notarization result was not Accepted"
  fi
}

ditto -c -k --keepParent "${SIGNED_APP}" "${APP_ZIP}"
submit_for_notarization "${APP_ZIP}"
rm -f "${APP_ZIP}"
xcrun stapler staple "${SIGNED_APP}"
xcrun stapler validate "${SIGNED_APP}"
codesign --verify --deep --strict --verbose=2 "${SIGNED_APP}"

mkdir "${DMG_ROOT}"
ditto "${SIGNED_APP}" "${DMG_ROOT}/Seer.app"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create \
  -volname Seer \
  -srcfolder "${DMG_ROOT}" \
  -format UDZO \
  -ov \
  "${WORK_DMG}"

codesign \
  --force \
  --sign "${SIGNING_IDENTITY_VALUE}" \
  --timestamp \
  "${WORK_DMG}"
codesign --verify --strict --verbose=2 "${WORK_DMG}"
DMG_SIGNATURE_DETAILS="$(codesign -d --verbose=4 "${WORK_DMG}" 2>&1)"
grep -Fqx "Authority=${SIGNING_IDENTITY_VALUE}" <<< "${DMG_SIGNATURE_DETAILS}" ||
  fail "signed DMG authority does not match APPLE_SIGNING_IDENTITY"
grep -Fqx "TeamIdentifier=${SIGNING_TEAM_ID_VALUE}" <<< "${DMG_SIGNATURE_DETAILS}" ||
  fail "signed DMG team identifier does not match APPLE_TEAM_ID"
grep -Eq '^Timestamp=' <<< "${DMG_SIGNATURE_DETAILS}" ||
  fail "signed DMG does not contain a secure timestamp"
submit_for_notarization "${WORK_DMG}"
xcrun stapler staple "${WORK_DMG}"
xcrun stapler validate "${WORK_DMG}"
codesign --verify --strict --verbose=2 "${WORK_DMG}"

spctl --assess --type execute --verbose=4 "${SIGNED_APP}"
spctl --assess --type open --context context:primary-signature --verbose=4 "${WORK_DMG}"

# Final signature/notarization gates passed. Erase every credential surface
# before any repository JavaScript runs or a release artifact is published.
destroy_credentials

run_repo_node "${SCRIPT_DIR}/check-release-boundary.mjs" \
  --app "${SIGNED_APP}" \
  --forbid-path "${REPO_ROOT}" \
  --forbid-path "${WORK_ROOT}"

mkdir "${MOUNT_POINT}"
DMG_MOUNTED=1
hdiutil attach \
  "${WORK_DMG}" \
  -readonly \
  -nobrowse \
  -noautoopen \
  -mountpoint "${MOUNT_POINT}"
run_repo_node "${SCRIPT_DIR}/check-release-boundary.mjs" \
  --dmg-root "${MOUNT_POINT}" \
  --forbid-path "${REPO_ROOT}" \
  --forbid-path "${WORK_ROOT}"
hdiutil detach "${MOUNT_POINT}"
DMG_MOUNTED=0

if [[ -e "${RELEASE_DIR}" || -L "${RELEASE_DIR}" ]]; then
  fail "fixed release staging directory already exists: ${RELEASE_DIR}"
fi
mkdir "${FINAL_STAGE}"
cp -p "${WORK_DMG}" "${FINAL_STAGE}/${DMG_NAME}"
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
