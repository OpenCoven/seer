#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

if [ -z "${SEER_RENDERER_LOCK_HELD:-}" ]; then
  exec node "${SCRIPT_DIR}/build-standalone-renderer.mjs" -- bash "${BASH_SOURCE[0]}"
fi

PROJECT_SPEC="${REPO_ROOT}/apps/macos/Seer/project.yml"
XCODEPROJ="${REPO_ROOT}/apps/macos/Seer/Seer.xcodeproj"

cd "${REPO_ROOT}"
xcodegen generate --spec "${PROJECT_SPEC}"
xcodebuild test \
  -project "${XCODEPROJ}" \
  -scheme Seer \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
