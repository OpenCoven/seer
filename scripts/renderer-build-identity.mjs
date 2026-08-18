#!/usr/bin/env node
// Shared, deterministic content-digest computation for the standalone macOS
// renderer bundle's build identity marker.
//
// Both the lock-owning renderer build wrapper and its tests import this exact
// module, so the digest a bundle is built with and the digest a consumer
// independently recomputes cannot drift through duplicated logic.
//
// The digest deliberately depends on nothing but the *bytes* of the files
// this build actually reads: no `Date.now()`/`builtAtEpochSeconds`, no
// `git rev-parse`/commit SHA (which cannot distinguish a clean checkout
// from one with uncommitted local edits, and is simply absent outside a
// git checkout), and no filesystem mtimes (which change on every
// checkout/clone/copy regardless of content). Two checkouts with
// byte-identical relevant source always produce the exact same digest;
// changing even one byte of relevant source always changes it.
import { Buffer } from "node:buffer";
import { spawnSync } from "node:child_process";
import console from "node:console";
import { createHash } from "node:crypto";
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

/** Bump only if the manifest's on-disk shape changes incompatibly. */
export const RENDERER_BUILD_MANIFEST_SCHEMA_VERSION = 2;
export const RENDERER_BUILD_MANIFEST_ALGORITHM = "sha256";

/**
 * Fixed, repo-root-relative files (outside `renderer/`) the standalone
 * build actually reads: `vite.standalone.config.ts`'s own entry point and
 * plugin config, and the npm/TypeScript toolchain configuration/lockfile
 * that determine exactly what gets installed and how it's compiled.
 * `tsconfig.json` is included alongside `tsconfig.standalone.json` because
 * the latter's `"extends": "./tsconfig.json"` means the root config's
 * `compilerOptions` genuinely feed into how the standalone renderer is
 * type-checked/compiled — a change to it can change build output just as
 * much as a change to `tsconfig.standalone.json` itself. Tailwind v4 is
 * configured entirely in CSS (`@import "tailwindcss" source(none)`,
 * explicit `@source`, and `@theme`; see `renderer/styles.css`) — there is no
 * separate `tailwind.config.*`/`postcss.config.*` file in this repo to also
 * list. Every explicit Tailwind scan source is either under `renderer/` or
 * the `standalone-window.html` entry listed below, so the scanner cannot read
 * class content outside this digest's input scope.
 */
const TOP_LEVEL_INPUT_FILES = [
  "standalone-window.html",
  "vite.standalone.config.ts",
  "package.json",
  "package-lock.json",
  "tsconfig.standalone.json",
  "tsconfig.json",
];

/** The renderer source tree, walked recursively. */
const RENDERER_SOURCE_DIR = "renderer";

/**
 * The *only* filename excluded from `renderer/`'s otherwise-exhaustive
 * recursive walk. `.DS_Store` is Finder-generated metadata macOS silently
 * writes into any directory a Finder window has ever browsed — its bytes
 * (icon-position/view-state caches) never reflect anything the build
 * actually reads, so letting it participate would let purely-local Finder
 * browsing "poison" (change) a checkout's build-identity digest with no
 * corresponding change to the built output.
 *
 * Deliberately narrow: this excludes *only* a file named exactly
 * `.DS_Store`, never dotfiles/dot-directories in general. A hidden file
 * under `renderer/` could legitimately be intentional build input the
 * project relies on, and Swift's `rendererBuildInputFiles` (see
 * `apps/macos/Seer/Tests/Integration/RendererIntegrationTests.swift`)
 * mirrors this exact same narrow exclusion — never a blanket
 * "skip all hidden files" rule — so the two implementations can never
 * silently diverge on which hidden files count as build input.
 */
const EXCLUDED_METADATA_FILENAMES = new Set([".DS_Store"]);

function toPosixRelativePath(repoRoot, absolutePath) {
  return relative(repoRoot, absolutePath).split(sep).join("/");
}

function collectFilesRecursively(absoluteDir, out) {
  const directoryInfo = lstatSync(absoluteDir);
  if (directoryInfo.isSymbolicLink() || !directoryInfo.isDirectory()) {
    throw new Error(`renderer build input directory must be a real directory: ${absoluteDir}`);
  }
  let entries;
  try {
    entries = readdirSync(absoluteDir, { withFileTypes: true });
  } catch (error) {
    if (error && error.code === "ENOENT") return;
    throw error;
  }
  // Sort entries before recursing so traversal order itself is
  // deterministic too (not load-bearing for the digest — the final file
  // list is sorted again below — but keeps this function's behavior
  // independent of the OS/filesystem's own directory-entry ordering).
  const sortedEntries = [...entries].sort((a, b) =>
    a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
  );
  for (const entry of sortedEntries) {
    if (EXCLUDED_METADATA_FILENAMES.has(entry.name)) continue;
    const absoluteChild = join(absoluteDir, entry.name);
    if (entry.isSymbolicLink()) {
      throw new Error(`renderer build input must not be a symlink: ${absoluteChild}`);
    }
    if (entry.isDirectory()) {
      collectFilesRecursively(absoluteChild, out);
    } else if (entry.isFile()) {
      out.push(absoluteChild);
    } else {
      throw new Error(`renderer build input must be a regular file or directory: ${absoluteChild}`);
    }
  }
}

/**
 * Every absolute path (on this machine, right now) this build's
 * deterministic content digest depends on. Returns their POSIX-style path
 * *relative to `repoRoot`* — never an absolute path — sorted
 * lexicographically, so the returned list (and therefore the digest
 * computed from it) never depends on filesystem enumeration order, the
 * checkout's absolute location on disk, or the host OS's path separator.
 */
export function rendererBuildInputFiles(repoRoot) {
  const absoluteFiles = [];
  collectFilesRecursively(join(repoRoot, RENDERER_SOURCE_DIR), absoluteFiles);

  for (const relativePath of TOP_LEVEL_INPUT_FILES) {
    const absolutePath = join(repoRoot, relativePath);
    try {
      const info = lstatSync(absolutePath);
      if (info.isSymbolicLink() || !info.isFile()) {
        throw new Error(`renderer build input must be a regular non-symlink file: ${absolutePath}`);
      }
      absoluteFiles.push(absolutePath);
    } catch (error) {
      if (error && error.code === "ENOENT") continue;
      throw error;
    }
  }

  const relativePaths = absoluteFiles.map((absolutePath) =>
    toPosixRelativePath(repoRoot, absolutePath),
  );
  relativePaths.sort();
  return relativePaths;
}

function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

/**
 * Canonical renderer-asset path ordering shared with
 * `renderer-asset-digest.py` and the bundled-renderer Swift verifier.
 *
 * A path is root-relative, uses `/` separators, and retains each filename's
 * exact Unicode scalar sequence: no locale collation, case folding, or
 * Unicode normalization is applied. Encode that path as UTF-8, compare the
 * first differing byte as an unsigned octet, and treat a strict prefix as
 * smaller. This preserves the manifest's existing bytes/hash construction
 * while giving every host exactly one ordering contract.
 */
export function compareRendererAssetPaths(left, right) {
  return Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8"));
}

function readRegularFileNoFollow(path, label) {
  const before = lstatSync(path);
  if (before.isSymbolicLink() || !before.isFile()) {
    throw new Error(`${label} must be a regular non-symlink file`);
  }
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const opened = fstatSync(descriptor);
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino) {
      throw new Error(`${label} changed identity while being opened`);
    }
    return readFileSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
}

/**
 * The deterministic build-identity digest: lowercase hex SHA-256 over a
 * stable manifest of `<posix-relative-path>:<sha256-hex-of-file-bytes>\n`
 * lines, one per file from {@link rendererBuildInputFiles}, sorted by path.
 * Hashing each file's bytes first (rather than concatenating raw file
 * contents) means the final digest is sensitive to which file changed,
 * not just that some byte somewhere changed, and avoids any ambiguity
 * from file boundaries when concatenating binary content directly.
 */
export function computeRendererBuildDigest(repoRoot) {
  const relativePaths = rendererBuildInputFiles(repoRoot);
  let manifestLines = "";
  for (const relativePath of relativePaths) {
    const absolutePath = join(repoRoot, ...relativePath.split("/"));
    const contents = readRegularFileNoFollow(absolutePath, `renderer build input ${relativePath}`);
    manifestLines += `${relativePath}:${sha256Hex(contents)}\n`;
  }
  return sha256Hex(Buffer.from(manifestLines, "utf8"));
}

// Node has no binding for Darwin's openat(2)/fstatat(2)/O_NOFOLLOW dir_fd
// family, so the actual descriptor-anchored walk lives in a committed
// Python 3 source file this repository ships as ordinary, readable source:
// never compiled, never installed, never copied anywhere, and never
// executed by a repository-relative pathname. Every single invocation:
//
//   1. reads that file's own bytes fresh off disk (see
//      readDescriptorAnchoredRendererAssets below), via the exact same
//      readRegularFileNoFollow helper every other build-input file in this
//      module goes through - no separate file-reading path to keep in sync;
//   2. validates /usr/bin/python3 is exactly the trusted, root-owned,
//      non-symlink system interpreter (see assertTrustedSystemInterpreterOrThrow);
//   3. spawns that exact interpreter as `/usr/bin/python3 - <args...>`,
//      piping the bytes read in step 1 verbatim to its stdin.
//
// `-` tells Python to read and execute its program from stdin: the process
// image on disk is always /usr/bin/python3 itself (an OS-owned binary this
// repository never writes to and never asks the OS to resolve by any
// repository-relative path), and the *program* it runs is whatever exact
// bytes were piped to it moments earlier. There is accordingly no shared
// canonical helper path for another process to look up, replace, race, or
// symlink-swap - no such path is ever created, published, or executed by
// name - and therefore nothing left to compile, cache, chmod, ACL-strip, or
// garbage-collect: no shared canonical executable, no private run
// directory, no root parent directory, no publication step, and so no
// publication-vs-execution TOCTOU, no ACL/umask race, and no
// EEXIST-on-shared-root race either. Those were all properties of the
// deleted compiled/cached/private-executable design, not of this one. Any
// directory a prior version of that design left behind on disk (e.g. an
// abandoned `build/.renderer-asset-digest-runs/`) is simply never
// referenced by any code below - its presence, absence, or contents can
// never influence this module's behavior.
const rendererAssetDigestHelperSource = join(
  dirname(fileURLToPath(import.meta.url)),
  "renderer-asset-digest.py",
);

/** The one fixed, OS-owned interpreter this module ever executes. */
const TRUSTED_SYSTEM_PYTHON3_PATH = "/usr/bin/python3";

function lstatOrNull(path) {
  try {
    return lstatSync(path);
  } catch (error) {
    if (error && error.code === "ENOENT") return null;
    throw error;
  }
}

/**
 * Read fresh on every call (never frozen into a module-load-time constant)
 * so tests can override the helper's own timeouts per invocation via
 * `process.env` without needing to re-import this module in a fresh
 * process. Genuinely *positive*: rejects `0` as well as negative values and
 * non-integers, because `0` means "no bound at all" to Node's own
 * `spawnSync({ timeout })`, silently defeating the very backstop this value
 * exists to provide.
 */
function positiveIntegerFromEnv(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}

/**
 * `/usr/bin/python3` is a fixed, OS-owned system binary this repository
 * never creates or writes to - unlike the deleted design's self-materialized
 * helper file, there is no meaningful open-then-fstat descriptor dance to
 * perform here: a non-root actor can never legitimately replace a
 * root-owned system binary out from under a single `lstatSync` call and a
 * subsequent `spawnSync` that re-resolves the same fixed, absolute path.
 * This is a deliberately narrow check, exported so tests can drive every
 * rejection branch directly against synthetic `stats`-like objects without
 * ever touching the real `/usr/bin/python3`.
 */
export function systemInterpreterRejectionReason(path, stats) {
  if (!stats) return `${path} does not exist`;
  if (stats.isSymbolicLink()) return `${path} must not be a symlink`;
  if (!stats.isFile()) return `${path} must be a regular file`;
  if (stats.uid !== 0) return `${path} must be owned by root`;
  if ((stats.mode & constants.S_IWGRP) !== 0 || (stats.mode & constants.S_IWOTH) !== 0) {
    return `${path} must not be group- or other-writable`;
  }
  if ((stats.mode & constants.S_IXUSR) === 0) {
    return `${path} must be owner-executable`;
  }
  return null;
}

export function assertTrustedSystemInterpreterOrThrow(path) {
  const reason = systemInterpreterRejectionReason(path, lstatOrNull(path));
  if (reason) {
    throw new Error(`refusing to invoke untrusted system interpreter: ${reason}`);
  }
}

/**
 * Low-level spawn seam: (re-)validates the trusted interpreter, then runs
 * `/usr/bin/python3 - ...args` with `sourceBytes` supplied verbatim via
 * stdin, bounding both wall-clock time and captured output. `sourceBytes` is
 * executed *exactly*: whatever this `Buffer`/`string` contains is the
 * program `/usr/bin/python3` runs, regardless of whether a file of the same
 * content also happens to exist anywhere on disk, under any name, at the
 * time of the call - so replacing/removing the source file on disk after
 * these bytes were read has no effect on what actually executes. Exported
 * so tests can exercise the exact-bytes-from-stdin, malformed-output, and
 * timeout/error contracts directly (see
 * tests/renderer-asset-digest-helper.test.mjs).
 *
 * `timeoutMs` must be a positive number of milliseconds - never `0`
 * (meaning "unbounded" to Node's own `child_process.spawnSync`) and never
 * negative. This is Node's own outer backstop only: the helper enforces its
 * own, tighter overall deadline internally (see `--deadline-seconds` below
 * and that file's own `main`/`_on_alarm`), including cleaning up any
 * `--after-collection-hook` descendant itself before it exits - so under
 * normal operation this outer bound is never the one that fires, and Node
 * never needs to (and does not) reach into a process group of its own to
 * collect descendants on timeout.
 */
export function spawnRendererAssetDigestHelper(sourceBytes, args, { timeoutMs } = {}) {
  assertTrustedSystemInterpreterOrThrow(TRUSTED_SYSTEM_PYTHON3_PATH);
  const resolvedTimeoutMs =
    timeoutMs === undefined
      ? positiveIntegerFromEnv("SEER_RENDERER_ASSET_DIGEST_HELPER_TIMEOUT_MS", 60_000)
      : timeoutMs;
  if (!Number.isSafeInteger(resolvedTimeoutMs) || resolvedTimeoutMs <= 0) {
    throw new Error("renderer asset digest helper timeout must be a positive integer");
  }
  const result = spawnSync(TRUSTED_SYSTEM_PYTHON3_PATH, ["-", ...args], {
    input: sourceBytes,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    timeout: resolvedTimeoutMs,
    killSignal: "SIGKILL",
  });
  if (result.error?.code === "ETIMEDOUT") {
    throw new Error(
      `descriptor-anchored renderer asset digest helper did not finish within ${resolvedTimeoutMs}ms and was killed`,
      { cause: result.error },
    );
  }
  if (result.error || result.status !== 0) {
    throw new Error(
      result.stderr?.trim() ||
        result.error?.message ||
        "descriptor-anchored renderer asset digest helper failed",
      { cause: result.error },
    );
  }
  let assets;
  try {
    assets = JSON.parse(result.stdout);
  } catch (error) {
    throw new Error("descriptor-anchored renderer asset digest helper returned invalid JSON", {
      cause: error,
    });
  }
  if (
    !Array.isArray(assets) ||
    assets.some(
      (asset) =>
        !asset ||
        typeof asset !== "object" ||
        typeof asset.relativePath !== "string" ||
        typeof asset.sha256 !== "string" ||
        !/^[0-9a-f]{64}$/.test(asset.sha256),
    )
  ) {
    throw new Error("descriptor-anchored renderer asset digest helper returned invalid assets");
  }
  return assets;
}

function normalizeAfterCollectionHook(afterCollection) {
  if (afterCollection === undefined) return null;
  if (
    !afterCollection ||
    typeof afterCollection !== "object" ||
    Array.isArray(afterCollection) ||
    typeof afterCollection.executable !== "string" ||
    !Array.isArray(afterCollection.args) ||
    afterCollection.args.some((argument) => typeof argument !== "string")
  ) {
    throw new TypeError(
      "afterCollection must be an object with an executable string and string args array",
    );
  }
  return afterCollection;
}

/**
 * A pure-JS re-implementation of the same output contract (sorted relative
 * paths, regular files only, symlinks rejected, `build-manifest.json`
 * excluded, `{relativePath, sha256}` objects), used *only* when
 * `SEER_RENDERER_BUILD_TEST_BUILDER` is set - i.e. only when the entire
 * `vite build` step has already been replaced with a deterministic test
 * fixture generator (see scripts/build-standalone-renderer.mjs's own use of
 * that same, pre-existing flag). Its purpose is narrow: the renderer lock
 * stress test (tests/standalone-renderer-lock.test.mjs's 64-waiter test)
 * exercises hundreds of real wrapper invocations to validate *lock handoff*
 * behavior, a property entirely unrelated to asset hashing - paying for a
 * fresh Python interpreter launch on every one of those would burn a
 * meaningful share of that test's fixed liveness budget on a property the
 * test was never about. Production never sets this flag, and no direct
 * digest/security/parity test does either (see
 * tests/renderer-build-identity.test.mjs and
 * tests/renderer-asset-digest-helper.test.mjs, which always exercise the
 * real Python helper), so this path can never mask a real regression in the
 * descriptor-anchored helper itself.
 */
function fastFixtureAssetDigestCollection(rendererRoot, afterCollection) {
  if (afterCollection !== undefined) {
    throw new Error(
      "afterCollection is not supported alongside SEER_RENDERER_BUILD_TEST_BUILDER's fast fixture digest path",
    );
  }
  const assets = [];
  const walk = (absoluteDir, relativePrefix) => {
    const directoryInfo = lstatSync(absoluteDir);
    if (directoryInfo.isSymbolicLink() || !directoryInfo.isDirectory()) {
      throw new Error(`renderer asset directory must be a real directory: ${absoluteDir}`);
    }
    const sortedEntries = [...readdirSync(absoluteDir, { withFileTypes: true })].sort((a, b) =>
      a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
    );
    for (const entry of sortedEntries) {
      const relativePath = relativePrefix ? `${relativePrefix}/${entry.name}` : entry.name;
      if (relativePath === "build-manifest.json") continue;
      const absoluteChild = join(absoluteDir, entry.name);
      if (entry.isSymbolicLink()) {
        throw new Error(`renderer asset must not be a symlink: ${absoluteChild}`);
      }
      if (entry.isDirectory()) {
        walk(absoluteChild, relativePath);
      } else if (entry.isFile()) {
        const contents = readRegularFileNoFollow(absoluteChild, `renderer asset ${relativePath}`);
        assets.push({ relativePath, sha256: sha256Hex(contents) });
      } else {
        throw new Error(`renderer asset must be a regular file or directory: ${absoluteChild}`);
      }
    }
  };
  walk(resolve(rendererRoot), "");
  return assets;
}

// Node's own outer spawn timeout (SEER_RENDERER_ASSET_DIGEST_HELPER_TIMEOUT_MS)
// must always leave the helper's own SIGALRM-based deadline comfortable room
// to fire *first*: the helper cleans up its own `--after-collection-hook`
// descendant as part of handling that deadline (see main/_on_alarm in
// renderer-asset-digest.py), but Node's own SIGKILL-on-timeout has no such
// awareness of - and no portable way to safely discover and reach into - a
// hook descendant's own separate session/process group from the outside. If
// Node's outer bound ever fired *before* the helper's own deadline could, a
// still-running hook descendant could be left behind. Requiring a minimum
// headroom below makes that ordering a structural property of every call
// through readDescriptorAnchoredRendererAssets, rather than something that
// depends on the two independently-overridable env vars happening to agree.
const RENDERER_ASSET_DIGEST_TIMEOUT_HEADROOM_MS = 5_000;

/**
 * Reads scripts/renderer-asset-digest.py's own bytes fresh off disk (never
 * cached) and pipes them into a fresh `/usr/bin/python3 -` invocation for
 * every real call - see spawnRendererAssetDigestHelper above for the full
 * no-cache/no-publish/no-compile rationale. `--deadline-seconds`/
 * `--hook-timeout-seconds` are always passed explicitly (even when equal to
 * the helper's own defaults) so both remain independently test-overridable
 * via environment variables without ever touching the committed helper
 * source.
 */
function readDescriptorAnchoredRendererAssets(rendererRoot, afterCollection) {
  if (process.platform !== "darwin") {
    throw new Error("descriptor-anchored renderer asset hashing requires macOS");
  }
  if (process.env.SEER_RENDERER_BUILD_TEST_BUILDER) {
    return fastFixtureAssetDigestCollection(rendererRoot, afterCollection);
  }
  const hook = normalizeAfterCollectionHook(afterCollection);
  const source = readRegularFileNoFollow(
    rendererAssetDigestHelperSource,
    "renderer asset digest helper source",
  );
  const deadlineSeconds = positiveIntegerFromEnv("SEER_RENDERER_ASSET_DIGEST_DEADLINE_SECONDS", 45);
  const hookTimeoutSeconds = positiveIntegerFromEnv(
    "SEER_RENDERER_ASSET_DIGEST_HOOK_TIMEOUT_SECONDS",
    20,
  );
  const helperTimeoutMs = positiveIntegerFromEnv(
    "SEER_RENDERER_ASSET_DIGEST_HELPER_TIMEOUT_MS",
    60_000,
  );
  const minimumHelperTimeoutMs = deadlineSeconds * 1000 + RENDERER_ASSET_DIGEST_TIMEOUT_HEADROOM_MS;
  if (helperTimeoutMs < minimumHelperTimeoutMs) {
    throw new Error(
      `SEER_RENDERER_ASSET_DIGEST_HELPER_TIMEOUT_MS (${helperTimeoutMs}) must be at least ` +
        `${minimumHelperTimeoutMs}ms (the ${deadlineSeconds}s deadline plus ` +
        `${RENDERER_ASSET_DIGEST_TIMEOUT_HEADROOM_MS}ms headroom), so the helper's own deadline ` +
        "always fires - and cleans up any hook descendant - before Node's outer spawn timeout could",
    );
  }
  const args = [
    resolve(rendererRoot),
    "--deadline-seconds",
    String(deadlineSeconds),
    "--hook-timeout-seconds",
    String(hookTimeoutSeconds),
  ];
  if (hook) {
    args.push(
      "--after-collection-hook",
      Buffer.from(JSON.stringify(hook), "utf8").toString("base64"),
    );
  }
  return spawnRendererAssetDigestHelper(source, args, { timeoutMs: helperTimeoutMs });
}

/**
 * Lowercase SHA-256 over every emitted file except build-manifest.json,
 * canonically ordered by {@link compareRendererAssetPaths}. Excluding the
 * manifest avoids a self-referential digest while binding the manifest to the
 * complete immutable generation it accompanies.
 */
export function computeRendererAssetDigest(rendererRoot, { afterCollection } = {}) {
  const assets = readDescriptorAnchoredRendererAssets(rendererRoot, afterCollection);
  assets.sort((left, right) => compareRendererAssetPaths(left.relativePath, right.relativePath));
  let manifestLines = "";
  for (const asset of assets) {
    manifestLines += `${asset.relativePath}:${asset.sha256}\n`;
  }
  return sha256Hex(Buffer.from(manifestLines, "utf8"));
}

/** The full build-manifest object, before serialization. */
export function buildRendererBuildManifest(
  repoRoot,
  rendererRoot,
  sourceDigest = computeRendererBuildDigest(repoRoot),
) {
  return {
    schemaVersion: RENDERER_BUILD_MANIFEST_SCHEMA_VERSION,
    algorithm: RENDERER_BUILD_MANIFEST_ALGORITHM,
    sourceDigest,
    assetDigest: computeRendererAssetDigest(rendererRoot),
  };
}

/**
 * Stable JSON serialization: fixed key order (never dependent on object
 * insertion order/engine iteration order) and a trailing newline, so two
 * runs over identical inputs produce byte-identical manifest files.
 */
export function serializeRendererBuildManifest(manifest) {
  return `${JSON.stringify(
    {
      schemaVersion: manifest.schemaVersion,
      algorithm: manifest.algorithm,
      sourceDigest: manifest.sourceDigest,
      assetDigest: manifest.assetDigest,
    },
    null,
    2,
  )}\n`;
}

function main() {
  const [, , repoRootArg, rendererRootArg, outputPathArg] = process.argv;
  if (!repoRootArg || !rendererRootArg || !outputPathArg) {
    console.error(
      "usage: node renderer-build-identity.mjs <repoRoot> <rendererRoot> <outputManifestPath>",
    );
    process.exitCode = 1;
    return;
  }
  const manifest = buildRendererBuildManifest(repoRootArg, rendererRootArg);
  writeFileSync(outputPathArg, serializeRendererBuildManifest(manifest));
}

// Only run the CLI/write-to-disk entry point when this module is executed
// directly (`node renderer-build-identity.mjs ...`) — never as a side
// effect of `import`-ing it from `tests/renderer-build-identity.test.mjs`.
const isMainModule = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMainModule) {
  main();
}

// Re-exported only so callers can locate this file's own directory without
// re-deriving it (e.g. to shell out to it from another script); never used
// to construct any path embedded in the digest/manifest itself.
export const scriptDir = dirname(fileURLToPath(import.meta.url));
