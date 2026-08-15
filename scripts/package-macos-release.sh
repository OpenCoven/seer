#!/bin/bash
set -euo pipefail

BUILD_ROOT=""
LOCK_DIR=""
RELEASE_DIR=""
WORK_ROOT=""
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

fail() {
  echo "error: $*" >&2
  exit 1
}

require_value() {
  local name="$1"
  local value="$2"
  local kind="$3"
  if [[ -z "${value}" ]]; then
    fail "missing required ${kind} variable ${name}"
  fi
}

run_unsigned_build() {
  if [[ "$#" -ne 8 ]]; then
    fail "internal unsigned build received invalid arguments"
  fi

  local repo_root="$1"
  local project_spec="$2"
  local xcodeproj="$3"
  local derived_data_path="$4"
  local archive_path="$5"
  local signed_app="$6"
  local version="$7"
  local build_number="$8"
  local signed_executable="${signed_app}/Contents/MacOS/Seer"

  cd "${repo_root}"
  xcodegen generate --spec "${project_spec}"
  xcodebuild \
    -project "${xcodeproj}" \
    -scheme Seer \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${derived_data_path}" \
    -archivePath "${archive_path}" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ENABLE_CODE_COVERAGE=NO \
    CLANG_COVERAGE_MAPPING=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    "MARKETING_VERSION=${version}" \
    "CURRENT_PROJECT_VERSION=${build_number}" \
    archive

  if [[ ! -d "${signed_app}" || -L "${signed_app}" ]]; then
    fail "xcodebuild did not produce a real Seer.app in the archive"
  fi
  if [[ ! -x "${signed_executable}" || -L "${signed_executable}" ]]; then
    fail "archive is missing its real executable Contents/MacOS/Seer"
  fi
  if [[ "$(plutil -extract CFBundleShortVersionString raw -o - "${signed_app}/Contents/Info.plist")" != "${version}" ]]; then
    fail "archive CFBundleShortVersionString does not match VERSION"
  fi
  if [[ "$(plutil -extract CFBundleVersion raw -o - "${signed_app}/Contents/Info.plist")" != "${build_number}" ]]; then
    fail "archive CFBundleVersion does not match BUILD_NUMBER"
  fi
  if [[ "$(plutil -extract CFBundleIdentifier raw -o - "${signed_app}/Contents/Info.plist")" != "ai.opencoven.seer" ]]; then
    fail "archive bundle identifier is not ai.opencoven.seer"
  fi

  strip -S "${signed_executable}"
  if [[ "$(lipo -archs "${signed_executable}")" != "arm64" ]]; then
    fail "release executable must contain exactly one arm64 slice"
  fi
}

if [[ "${1:-}" == "--unsigned-build" ]]; then
  shift
  run_unsigned_build "$@"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

if ! [[ "${VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  fail "VERSION must be a stable semantic version in X.Y.Z form"
fi
if ! [[ "${BUILD_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
  fail "BUILD_NUMBER must be a positive integer without leading zeros"
fi

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

RELEASE_VERSION="${VERSION}"
RELEASE_BUILD_NUMBER="${BUILD_NUMBER}"
RELEASE_SOURCE_COMMIT="${SOURCE_COMMIT}"
RELEASE_WORKFLOW_RUN="${WORKFLOW_RUN}"
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

for required_command in \
  base64 codesign ditto grep hdiutil lipo mktemp node openssl plutil \
  security spctl strip uname xcodebuild xcodegen xcrun
do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command not found on PATH: ${required_command}"
done

HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" != "arm64" ]]; then
  fail "signed macOS packaging requires an Apple Silicon (arm64) host"
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
KEYCHAIN_PATH="${WORK_ROOT}/release-signing.keychain-db"
CERTIFICATE_PATH="${WORK_ROOT}/developer-id.p12"
API_KEY_PATH="${WORK_ROOT}/notary-api-key.p8"
ARCHIVE_PATH="${WORK_ROOT}/Seer.xcarchive"
DERIVED_DATA_PATH="${WORK_ROOT}/derived-data"
SIGNED_APP="${ARCHIVE_PATH}/Products/Applications/Seer.app"
APP_ZIP="${WORK_ROOT}/Seer-notarization.zip"
DMG_ROOT="${WORK_ROOT}/dmg-root"
DMG_NAME="Seer-v${RELEASE_VERSION}-arm64.dmg"
WORK_DMG="${WORK_ROOT}/${DMG_NAME}"
MOUNT_POINT="${WORK_ROOT}/mounted-dmg"
FINAL_STAGE="${WORK_ROOT}/release"
ENTITLEMENTS_PATH="${REPO_ROOT}/apps/macos/Seer/Config/Seer.entitlements"
PROJECT_SPEC="${REPO_ROOT}/apps/macos/Seer/project.yml"
XCODEPROJ="${REPO_ROOT}/apps/macos/Seer/Seer.xcodeproj"

UNSIGNED_BUILD_ARGS=(
  --unsigned-build
  "${REPO_ROOT}"
  "${PROJECT_SPEC}"
  "${XCODEPROJ}"
  "${DERIVED_DATA_PATH}"
  "${ARCHIVE_PATH}"
  "${SIGNED_APP}"
  "${RELEASE_VERSION}"
  "${RELEASE_BUILD_NUMBER}"
)
if [[ -n "${SEER_RENDERER_LOCK_HELD:-}" ]]; then
  /bin/bash "${BASH_SOURCE[0]}" "${UNSIGNED_BUILD_ARGS[@]}"
else
  node "${SCRIPT_DIR}/build-standalone-renderer.mjs" -- \
    /bin/bash "${BASH_SOURCE[0]}" "${UNSIGNED_BUILD_ARGS[@]}"
fi

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
  if ! printf "%s" "${response}" |
    node -e '
      let input = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk) => { input += chunk; });
      process.stdin.on("end", () => {
        try {
          const result = JSON.parse(input);
          process.exitCode = result.status === "Accepted" ? 0 : 1;
        } catch {
          process.exitCode = 1;
        }
      });
    '
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

node "${SCRIPT_DIR}/check-release-boundary.mjs" \
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
node "${SCRIPT_DIR}/check-release-boundary.mjs" \
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
node "${SCRIPT_DIR}/write-release-manifest.mjs" \
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
