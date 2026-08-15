#!/bin/bash
set -euo pipefail

# This script is the credential-free half of the release contract. Task 17 must
# run it on a different machine/runner from signing and transfer only the two
# fixed release-input artifacts. Any APPLE_* variable is an isolation failure.
for apple_variable in "${!APPLE_@}"; do
  echo "error: ${apple_variable} is forbidden in the credential-free build job; use a distinct runner for signing" >&2
  exit 1
done

fail() {
  echo "error: $*" >&2
  exit 1
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
  local unsigned_app="$6"
  local version="$7"
  local build_number="$8"
  local executable="${unsigned_app}/Contents/MacOS/Seer"

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

  if [[ ! -d "${unsigned_app}" || -L "${unsigned_app}" ]]; then
    fail "xcodebuild did not produce a real Seer.app in the archive"
  fi
  if [[ ! -x "${executable}" || -L "${executable}" ]]; then
    fail "archive is missing its real executable Contents/MacOS/Seer"
  fi
  if [[ "$(plutil -extract CFBundleShortVersionString raw -o - "${unsigned_app}/Contents/Info.plist")" != "${version}" ]]; then
    fail "archive CFBundleShortVersionString does not match VERSION"
  fi
  if [[ "$(plutil -extract CFBundleVersion raw -o - "${unsigned_app}/Contents/Info.plist")" != "${build_number}" ]]; then
    fail "archive CFBundleVersion does not match BUILD_NUMBER"
  fi
  if [[ "$(plutil -extract CFBundleIdentifier raw -o - "${unsigned_app}/Contents/Info.plist")" != "ai.opencoven.seer" ]]; then
    fail "archive bundle identifier is not ai.opencoven.seer"
  fi

  strip -S "${executable}"
  if [[ "$(lipo -archs "${executable}")" != "arm64" ]]; then
    fail "release executable must contain exactly one arm64 slice"
  fi

  node "${repo_root}/scripts/check-release-boundary.mjs" \
    --app "${unsigned_app}" \
    --forbid-path "${repo_root}" \
    --forbid-path "$(dirname "${archive_path}")"
}

if [[ "${1:-}" == "--run-unsigned-build" ]]; then
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
if ! [[ "${SOURCE_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]]; then
  fail "SOURCE_COMMIT must be a lowercase 40-character SHA"
fi

for required_command in git lipo node plutil strip uname xcodebuild xcodegen; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command not found on PATH: ${required_command}"
done
[[ -x /usr/bin/python3 ]] || fail "required system command not found: /usr/bin/python3"

if [[ "$(uname -m)" != "arm64" ]]; then
  fail "unsigned macOS release preparation requires an Apple Silicon (arm64) host"
fi

ACTUAL_SOURCE_COMMIT="$(git rev-parse --verify HEAD)"
if [[ "${ACTUAL_SOURCE_COMMIT}" != "${SOURCE_COMMIT}" ]]; then
  fail "SOURCE_COMMIT does not match the checked-out commit"
fi
if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  fail "release preparation requires an immutable clean checkout of SOURCE_COMMIT"
fi

BUILD_ROOT="${REPO_ROOT}/build/macos"
LOCK_DIR="${BUILD_ROOT}/.release-input.lock"
OUTPUT_DIR="${BUILD_ROOT}/release-input"
WORK_ROOT=""
LOCK_HELD=0

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ -n "${WORK_ROOT}" ]]; then
    rm -rf "${WORK_ROOT}"
  fi
  if [[ "${LOCK_HELD}" -eq 1 ]]; then
    rmdir "${LOCK_DIR}" >/dev/null 2>&1
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

umask 077
mkdir -p "${BUILD_ROOT}"
if [[ -e "${OUTPUT_DIR}" || -L "${OUTPUT_DIR}" ]]; then
  fail "fixed unsigned release input already exists: ${OUTPUT_DIR}"
fi
if ! mkdir "${LOCK_DIR}"; then
  fail "another unsigned release preparation process holds ${LOCK_DIR}"
fi
LOCK_HELD=1
WORK_ROOT="$(mktemp -d "${BUILD_ROOT}/.release-input-work.XXXXXXXX")"

ARCHIVE_PATH="${WORK_ROOT}/Seer.xcarchive"
DERIVED_DATA_PATH="${WORK_ROOT}/derived-data"
UNSIGNED_APP="${ARCHIVE_PATH}/Products/Applications/Seer.app"
PROJECT_SPEC="${REPO_ROOT}/apps/macos/Seer/project.yml"
XCODEPROJ="${REPO_ROOT}/apps/macos/Seer/Seer.xcodeproj"
STAGE_DIR="${WORK_ROOT}/release-input"
mkdir "${STAGE_DIR}"

node "${SCRIPT_DIR}/build-standalone-renderer.mjs" -- \
  /bin/bash "${BASH_SOURCE[0]}" --run-unsigned-build \
  "${REPO_ROOT}" \
  "${PROJECT_SPEC}" \
  "${XCODEPROJ}" \
  "${DERIVED_DATA_PATH}" \
  "${ARCHIVE_PATH}" \
  "${UNSIGNED_APP}" \
  "${VERSION}" \
  "${BUILD_NUMBER}"

/usr/bin/python3 "${SCRIPT_DIR}/macos-release-input.py" create \
  --app "${UNSIGNED_APP}" \
  --archive "${STAGE_DIR}/Seer-unsigned-arm64.tar" \
  --attestation "${STAGE_DIR}/unsigned-app-attestation.json" \
  --source-commit "${SOURCE_COMMIT}" \
  --version "${VERSION}" \
  --build-number "${BUILD_NUMBER}" \
  --bundle-identifier ai.opencoven.seer \
  --architecture arm64

chmod 0644 \
  "${STAGE_DIR}/Seer-unsigned-arm64.tar" \
  "${STAGE_DIR}/unsigned-app-attestation.json"
mv "${STAGE_DIR}" "${OUTPUT_DIR}"

echo "unsigned release input staged at build/macos/release-input"
