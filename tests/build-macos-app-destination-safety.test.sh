#!/bin/bash
# Exercises scripts/lib/safe-build-destination.sh's build-output
# destination-safety helpers directly against synthetic, disposable "repo
# root" trees — never invoking a real xcodebuild — proving:
#
#   1. A clean synthetic repo root (no symlinked build/ ancestors) lets
#      seer_prepare_unsigned_dir create build/macos/unsigned normally.
#   2. A symlinked build/macos component (the exact scenario
#      scripts/build-macos-app.sh must defend against: an intermediate
#      directory on the path to build/macos/unsigned/Seer.app replaced by a
#      symlink to an arbitrary directory) is rejected outright, and a
#      canary file inside the symlink's target ("victim") directory is left
#      completely untouched — proving no rm -rf/mkdir ever reached through
#      the symlink.
#   3. A symlinked build/macos/unsigned/Seer.app destination *leaf* is
#      independently rejected by seer_assert_dest_app_not_symlink, again
#      leaving its target untouched.
#
# All scratch state lives under this repository's own gitignored build/
# directory (never /tmp, never mktemp) as an "injectable safe temporary
# repo seam" — a disposable directory tree that stands in for a repo root
# — and is removed at the end of the run regardless of outcome.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

# shellcheck source=../scripts/lib/safe-build-destination.sh
source "${REPO_ROOT}/scripts/lib/safe-build-destination.sh"

SCRATCH_ROOT="${REPO_ROOT}/build/tmp-destination-safety-test"
rm -rf "${SCRATCH_ROOT}"
mkdir -p "${SCRATCH_ROOT}"
cleanup() {
  rm -rf "${SCRATCH_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "== Test 1: a clean synthetic repo root creates build/macos/unsigned normally =="
CLEAN_REPO="${SCRATCH_ROOT}/clean-repo"
mkdir -p "${CLEAN_REPO}"
UNSIGNED_DIR="$(seer_prepare_unsigned_dir "${CLEAN_REPO}")"
[ -d "${UNSIGNED_DIR}" ] || fail "expected '${UNSIGNED_DIR}' to exist as a directory"
[ ! -L "${UNSIGNED_DIR}" ] || fail "'${UNSIGNED_DIR}' must not be a symlink"
[ "${UNSIGNED_DIR}" = "${CLEAN_REPO}/build/macos/unsigned" ] || fail "unexpected unsigned dir: ${UNSIGNED_DIR}"
echo "ok"

echo "== Test 2: a symlinked build/macos component is rejected, and the victim directory is left untouched =="
ATTACK_REPO="${SCRATCH_ROOT}/attack-repo"
VICTIM_DIR="${SCRATCH_ROOT}/victim"
mkdir -p "${ATTACK_REPO}/build" "${VICTIM_DIR}/unsigned/Seer.app"
echo "do-not-delete-me" >"${VICTIM_DIR}/unsigned/Seer.app/canary.txt"
ln -s "${VICTIM_DIR}" "${ATTACK_REPO}/build/macos"

if OUTPUT="$(seer_prepare_unsigned_dir "${ATTACK_REPO}" 2>&1)"; then
  fail "expected seer_prepare_unsigned_dir to reject a symlinked build/macos component, got success: ${OUTPUT}"
fi
echo "${OUTPUT}" | grep -q "symlink" || fail "expected an error mentioning 'symlink', got: ${OUTPUT}"
[ -f "${VICTIM_DIR}/unsigned/Seer.app/canary.txt" ] ||
  fail "victim canary file was removed — a symlinked ancestor let the safety check reach outside the repo root"
[ "$(cat "${VICTIM_DIR}/unsigned/Seer.app/canary.txt")" = "do-not-delete-me" ] ||
  fail "victim canary file content changed unexpectedly"
echo "ok (victim canary file still present and unmodified)"

echo "== Test 3: a symlinked build/macos/unsigned/Seer.app destination leaf is rejected without touching its target =="
LEAF_REPO="${SCRATCH_ROOT}/leaf-repo"
LEAF_VICTIM_DIR="${SCRATCH_ROOT}/leaf-victim"
mkdir -p "${LEAF_REPO}" "${LEAF_VICTIM_DIR}"
echo "leaf-canary" >"${LEAF_VICTIM_DIR}/canary.txt"
LEAF_UNSIGNED_DIR="$(seer_prepare_unsigned_dir "${LEAF_REPO}")"
LEAF_DEST_APP="${LEAF_UNSIGNED_DIR}/Seer.app"
ln -s "${LEAF_VICTIM_DIR}" "${LEAF_DEST_APP}"

if OUTPUT="$(seer_assert_dest_app_not_symlink "${LEAF_DEST_APP}" 2>&1)"; then
  fail "expected seer_assert_dest_app_not_symlink to reject a symlinked Seer.app destination, got success: ${OUTPUT}"
fi
echo "${OUTPUT}" | grep -q "symlink" || fail "expected an error mentioning 'symlink', got: ${OUTPUT}"
[ -f "${LEAF_VICTIM_DIR}/canary.txt" ] || fail "leaf victim canary file was removed"
[ "$(cat "${LEAF_VICTIM_DIR}/canary.txt")" = "leaf-canary" ] || fail "leaf victim canary file content changed unexpectedly"
echo "ok (leaf victim canary file still present and unmodified)"

echo "== Test 4: a real (non-symlink) pre-existing build/macos/unsigned directory tree is reused without error =="
REUSE_REPO="${SCRATCH_ROOT}/reuse-repo"
mkdir -p "${REUSE_REPO}"
FIRST_UNSIGNED_DIR="$(seer_prepare_unsigned_dir "${REUSE_REPO}")"
echo "leftover-from-a-previous-run" >"${FIRST_UNSIGNED_DIR}/leftover.txt"
SECOND_UNSIGNED_DIR="$(seer_prepare_unsigned_dir "${REUSE_REPO}")"
[ "${SECOND_UNSIGNED_DIR}" = "${FIRST_UNSIGNED_DIR}" ] || fail "expected the same unsigned dir on a second run"
[ -f "${SECOND_UNSIGNED_DIR}/leftover.txt" ] ||
  fail "seer_prepare_unsigned_dir must not delete pre-existing sibling files under unsigned/ — only build-macos-app.sh's own rm -rf \"\${DEST_APP}\" (a fixed leaf path) does that"
echo "ok"

echo
echo "All build-macos-app.sh destination-safety tests passed."
