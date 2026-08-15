#!/bin/bash
#
# Builds an unsigned, arm64 Release Seer.app for local development/testing —
# never signs, notarizes, packages, or distributes it. Every step is a fixed,
# hardcoded sequence:
#
#   1. Build the standalone renderer (npm run build:standalone-renderer).
#   2. Generate the Xcode project from apps/macos/Seer/project.yml via
#      `xcodegen generate` (the generated .xcodeproj is gitignored and
#      never committed).
#   3. Build the Seer scheme, Release configuration by default, with
#      CODE_SIGNING_ALLOWED=NO (this script never signs anything).
#   4. Stage the built Seer.app under build/macos/unsigned and publish it
#      atomically with descriptor-relative, no-follow filesystem operations.
#
# Only CONFIGURATION and DERIVED_DATA_PATH may be overridden via the
# environment, and each is validated/quoted as a single opaque argv token —
# never `eval`'d or spliced into a larger shell string — so a value
# containing shell metacharacters can never do anything except fail as an
# invalid xcodebuild argument, not execute as a shell fragment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

HOST_ARCH="$(uname -m)"
if [ "${HOST_ARCH}" != "arm64" ]; then
  echo "error: scripts/build-macos-app.sh requires an Apple Silicon (arm64) host, found '${HOST_ARCH}'" >&2
  exit 1
fi

CONFIGURATION="${CONFIGURATION:-Release}"
if ! [[ "${CONFIGURATION}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "error: CONFIGURATION must match [A-Za-z0-9_-]+, got '${CONFIGURATION}'" >&2
  exit 1
fi

# Kept under the repo's own gitignored build/ directory by default so a
# local run never writes outside the checkout.
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${REPO_ROOT}/build/macos/derived-data}"
case "${DERIVED_DATA_PATH}" in
  /*) ;;
  *)
    echo "error: DERIVED_DATA_PATH must be an absolute path, got '${DERIVED_DATA_PATH}'" >&2
    exit 1
    ;;
esac

PROJECT_SPEC="${REPO_ROOT}/apps/macos/Seer/project.yml"
XCODEPROJ="${REPO_ROOT}/apps/macos/Seer/Seer.xcodeproj"

UNSIGNED_DIR="${REPO_ROOT}/build/macos/unsigned"
DEST_APP="${UNSIGNED_DIR}/Seer.app"

cd "${REPO_ROOT}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found on PATH" >&2
  exit 1
fi

echo "==> Building standalone renderer"
npm run build:standalone-renderer

echo "==> Generating Xcode project from ${PROJECT_SPEC}"
xcodegen generate --spec "${PROJECT_SPEC}"

echo "==> Building Seer.app (configuration=${CONFIGURATION}, unsigned, arm64)"
# ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO: this Xcode toolchain
# otherwise instruments even a plain `build` action with Clang's coverage
# counters (visible as CLANG_COVERAGE_MAPPING/ENABLE_CODE_COVERAGE=YES in
# -showBuildSettings, with no explicit setting anywhere in
# project.yml/Seer.xcodeproj to account for it — `-enableCodeCoverage NO`
# is rejected outright by a plain `build` action, so these two build
# setting overrides are the actual fix), which bakes this checkout's own
# absolute source path into the binary as an LLVM profile-data symbol
# (`___profc_<absolute path>...`) — exactly the kind of leak
# scripts/check-standalone-boundary.mjs's bundle scan exists to catch.
xcodebuild \
  -project "${XCODEPROJ}" \
  -scheme Seer \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO \
  build

EFFECTIVE_DERIVED_DATA_PATH="$(cd "${DERIVED_DATA_PATH}" && pwd -P)"
BUILT_APP="${EFFECTIVE_DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/Seer.app"
if [ ! -d "${BUILT_APP}" ]; then
  echo "error: expected xcodebuild output at ${BUILT_APP}, but it does not exist" >&2
  exit 1
fi

BUILT_EXECUTABLE="${BUILT_APP}/Contents/MacOS/Seer"
if [ ! -x "${BUILT_EXECUTABLE}" ]; then
  echo "error: expected executable at ${BUILT_EXECUTABLE}" >&2
  exit 1
fi

# Xcode's plain `build` action (unlike `archive`/`install`) never runs its
# own Strip build phase regardless of STRIP_INSTALLED_PRODUCT — that only
# takes effect under DEPLOYMENT_POSTPROCESSING, which `archive` sets and a
# plain `build` does not. Left unstripped, DEBUG_INFORMATION_FORMAT's
# dwarf-with-dsym debug map embeds this checkout's own absolute build path
# (e.g. ".../Intermediates.noindex/Seer.build/...") directly in the
# executable — `strip -S` (debug symbol table only, safe for a plain
# executable that does not require exported symbols) removes exactly that
# without touching the binary's actual code or its architecture/otool
# dependency graph. `strip` re-signs the binary ad-hoc afterward on its
# own (required on Apple Silicon for any tool that modifies a Mach-O
# binary's bytes) — this script still never signs anything itself.
strip -S "${BUILT_EXECUTABLE}"

ARCHITECTURES="$(/usr/bin/lipo -archs "${BUILT_EXECUTABLE}")"
if [ "${ARCHITECTURES}" != "arm64" ]; then
  echo "error: expected exactly one arm64 slice in ${BUILT_EXECUTABLE}; lipo -archs returned '${ARCHITECTURES}'" >&2
  exit 1
fi

echo "==> Publishing ${BUILT_APP} -> ${DEST_APP}"
# The helper creates a private random staging directory under unsigned/,
# copies without following bundle symlinks, then reopens and identity-checks
# the canonical repo/build/macos/unsigned chain immediately before using
# renameat-style descriptor-relative operations. An existing Seer.app is
# first moved to a private same-parent backup and removed without recursive
# path traversal only after the staged app and private provenance metadata
# have been published successfully.
/usr/bin/python3 "${SCRIPT_DIR}/publish-macos-app.py" \
  --repo-root "${REPO_ROOT}" \
  --source-app "${BUILT_APP}" \
  --derived-data-path "${EFFECTIVE_DERIVED_DATA_PATH}"

echo "==> Built unsigned app: ${DEST_APP}"
