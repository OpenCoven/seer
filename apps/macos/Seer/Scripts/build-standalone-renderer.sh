#!/bin/bash
#
# Xcode preBuildScripts entry (see `project.yml`'s `Seer` target) that builds
# the standalone renderer *before* Xcode's own "Copy Resources" build phase
# ever runs, so the `Renderer` folder that phase copies into `Seer.app`
# always reflects the current checkout — never a bundle left over from a
# previous build, and never one built on demand at test runtime (see
# `RendererIntegrationTests.swift`'s `BundledRenderer`, which now only ever
# reads what this script already produced).
#
# Only ever invokes the already-installed local `npm`/Vite toolchain
# (`npm run build:standalone-renderer`, itself `vite build --config
# vite.standalone.config.ts` — see `package.json`) — never a network fetch.
# `basedOnDependencyAnalysis: false` on this script's `project.yml` entry
# means Xcode always re-runs it, so it is deliberately not gated on any
# input/output file list here.
#
# Every path below is fixed, derived only from Xcode's own `SRCROOT` build
# setting (always exported into a Run Script phase's environment — never
# `$0`/`BASH_SOURCE`, which would instead resolve to whatever ephemeral
# temp-file location Xcode happens to copy this phase's inlined script text
# to at build time, not this file's real location in the repo) — no dynamic
# path construction, `$PWD`, or caller-supplied fragments. `SRCROOT` is the
# directory containing `project.yml`/`Seer.xcodeproj`
# (`<repo>/apps/macos/Seer`), so the repository root is exactly three
# directories up — the same fixed relative layout `project.yml`'s own
# `outputFiles` paths for this script already assume.
set -euo pipefail

: "${SRCROOT:?SRCROOT must be set by Xcode when running this build phase}"
REPO_ROOT="$(cd "${SRCROOT}/../../.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/build/standalone-renderer/Renderer"
DOCUMENT_PATH="${OUTPUT_DIR}/standalone-window.html"
MANIFEST_PATH="${OUTPUT_DIR}/build-manifest.json"

# Xcode's Run Script phase environment does not always include Homebrew's
# install prefix; append the two fixed, standard locations `npm` is
# installed at on this toolchain (Apple Silicon Homebrew, Intel Homebrew/
# /usr/local) so CI runners that only add npm to an interactive shell's
# PATH still resolve it here.
export PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin"

if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm not found on PATH (${PATH})" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node not found on PATH (${PATH})" >&2
  exit 1
fi

cd "${REPO_ROOT}"
npm run build:standalone-renderer

if [ ! -f "${DOCUMENT_PATH}" ]; then
  echo "error: npm run build:standalone-renderer did not produce ${DOCUMENT_PATH}" >&2
  exit 1
fi

# A deterministic source/build identity marker, copied into the bundle as
# an ordinary resource (it lives inside the `Renderer` folder `project.yml`
# already declares as a resources build phase input): a stable content
# digest over every file this build actually reads (the whole `renderer/`
# source tree plus the fixed top-level config/lockfile inputs — see
# `scripts/renderer-build-identity.mjs`, the single shared implementation
# this script and `RendererIntegrationTests.swift`'s independent Swift
# recomputation both rely on). Deliberately never a timestamp or `git`
# commit SHA: a timestamp only proves *when* a build ran, not *what* it was
# built from, and a commit SHA can't tell a clean checkout apart from one
# with uncommitted local edits (and is simply unavailable outside a git
# checkout at all). Read back by
# `RendererIntegrationTests.BundledRenderer.ensureAvailable()`, which fails
# closed if the digest it recomputes over the current checkout doesn't
# exactly match this manifest's `digest` — proving the bundled renderer was
# actually built from what's on disk right now, not a stale artifact left
# in `build/` (e.g. from an earlier checkout, or `build/` restored from a
# cache), regardless of git availability or dirty/uncommitted state.
node "${REPO_ROOT}/scripts/renderer-build-identity.mjs" "${REPO_ROOT}" "${MANIFEST_PATH}"
