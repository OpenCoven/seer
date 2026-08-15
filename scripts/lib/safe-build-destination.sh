#!/bin/bash
# Shared helpers for scripts/build-macos-app.sh's build-output destination
# safety checks, split into their own sourceable file so
# tests/build-macos-app-destination-safety.test.sh can exercise them
# directly against a synthetic, disposable "repo root" — without ever
# invoking a real xcodebuild — and prove a symlinked intermediate
# build/macos (or build/macos/unsigned) directory can never redirect a
# cleanup (`rm -rf`) or copy (`cp -R`) outside the intended destination.
#
# Threat model: `mkdir -p` and `rm -rf`/`cp -R` all transparently follow any
# *intermediate* directory symlink while resolving a path — only the final
# path component's own symlink-ness affects whether an operation acts on
# the link itself or its target. So if an attacker (or a stray leftover
# from something else on a shared machine) replaces, say, `build/macos`
# with a symlink to an arbitrary directory before this script runs, a naive
# `mkdir -p .../unsigned && rm -rf .../unsigned/Seer.app` would silently
# operate underneath that symlink's target instead of inside this repo.
# The helpers below refuse to proceed the moment any *existing* path
# component turns out to be a symlink, and only ever create missing
# components one at a time (never `mkdir -p`), each freshly verified.
set -euo pipefail

# Fails loudly if any *existing* path component from "$trusted_root" down to
# "$target" (both already-canonical, symlink-free absolute paths, e.g. from
# `cd ... && pwd -P`) is itself a symlink. A component that does not exist
# yet is fine — the caller is expected to create it next, one component at
# a time, via seer_create_safe_dir. Never dereferences a discovered symlink
# (only `[ -L ... ]`, never `readlink`/`cd` into it) before reporting it.
seer_assert_no_symlink_components() {
  local target="$1"
  local trusted_root="$2"

  case "${target}" in
    "${trusted_root}")
      return 0
      ;;
    "${trusted_root}"/*)
      ;;
    *)
      echo "error: refusing to operate on '${target}': not lexically beneath trusted root '${trusted_root}'" >&2
      return 1
      ;;
  esac

  local relative="${target#"${trusted_root}"/}"
  local current="${trusted_root}"
  local part
  local IFS='/'
  for part in ${relative}; do
    current="${current}/${part}"
    if [ -L "${current}" ]; then
      echo "error: refusing to continue: '${current}' is a symlink (not allowed in build output path)" >&2
      return 1
    fi
  done
  return 0
}

# Creates "$dir" if missing via a single `mkdir` (never `mkdir -p`, which
# would silently traverse/create through an already-rejected symlinked
# ancestor). Fails loudly if "$dir" already exists as anything other than a
# real, non-symlink directory, or if it was somehow created as a symlink.
seer_create_safe_dir() {
  local dir="$1"
  if [ -L "${dir}" ]; then
    echo "error: '${dir}' exists and is a symlink; refusing to use it as a build output directory" >&2
    return 1
  fi
  if [ -e "${dir}" ]; then
    if [ ! -d "${dir}" ]; then
      echo "error: '${dir}' exists and is not a directory; refusing to use it as a build output directory" >&2
      return 1
    fi
    return 0
  fi
  mkdir "${dir}"
  if [ -L "${dir}" ]; then
    echo "error: '${dir}' was created as a symlink unexpectedly; aborting" >&2
    return 1
  fi
}

# Ensures "$repo_root/build", "$repo_root/build/macos", and
# "$repo_root/build/macos/unsigned" exist as a real (non-symlink) directory
# tree beneath "$repo_root" (itself expected to already be a canonical,
# symlink-resolved path — e.g. via `pwd -P`), creating any missing
# component one at a time, and re-verifies via a fresh `pwd -P` that the
# fully resolved result still lexically lives under "$repo_root/build" —
# guarding against a TOCTOU swap between the component checks above and
# this final resolution. Prints the resulting unsigned-dir path on success.
seer_prepare_unsigned_dir() {
  local repo_root="$1"
  local build_root="${repo_root}/build"
  local macos_dir="${build_root}/macos"
  local unsigned_dir="${macos_dir}/unsigned"

  seer_assert_no_symlink_components "${unsigned_dir}" "${repo_root}"

  seer_create_safe_dir "${build_root}"
  seer_create_safe_dir "${macos_dir}"
  seer_create_safe_dir "${unsigned_dir}"

  local resolved
  resolved="$(cd "${unsigned_dir}" && pwd -P)"
  case "${resolved}" in
    "${build_root}"/* | "${build_root}")
      ;;
    *)
      echo "error: resolved destination '${resolved}' escapes repo build root '${build_root}'" >&2
      return 1
      ;;
  esac

  echo "${unsigned_dir}"
}

# Refuses to remove/replace "$dest_app" (the fixed Seer.app destination
# path) if it is itself a symlink — a defensive belt-and-suspenders check
# alongside seer_prepare_unsigned_dir's ancestor-component checks, in case
# a previous run (or something else on a shared machine) left the leaf
# itself as a symlink rather than a real directory/file.
seer_assert_dest_app_not_symlink() {
  local dest_app="$1"
  if [ -L "${dest_app}" ]; then
    echo "error: '${dest_app}' exists and is a symlink; refusing to rm -rf/cp -R through it" >&2
    return 1
  fi
}
