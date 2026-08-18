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
import { createHash, randomBytes } from "node:crypto";
import {
  closeSync,
  constants,
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
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
 * `renderer-asset-digest.swift` and the bundled-renderer Swift verifier.
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

// Node does not expose Darwin's openat(2), so this macOS-only helper retains
// O_NOFOLLOW directory descriptors and walks each child from its pinned parent.
const rendererAssetDigestHelperSource = join(
  dirname(fileURLToPath(import.meta.url)),
  "renderer-asset-digest.swift",
);
const rendererAssetDigestHelperCache = join(
  dirname(dirname(rendererAssetDigestHelperSource)),
  "build",
  ".renderer-asset-digest-helper",
);

function nonNegativeIntegerFromEnv(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return value;
}

/**
 * How long a waiter blocks for the digest-helper lock before giving up
 * (bounds every wait loop below - this lock never spins forever).
 */
const rendererAssetDigestHelperLockDeadlineMs = nonNegativeIntegerFromEnv(
  "SEER_RENDERER_ASSET_DIGEST_HELPER_LOCK_DEADLINE_MS",
  120_000,
);

/**
 * How long a lock directory is allowed to exist with no `owner.json` yet
 * before a waiter may treat it as abandoned-mid-initialization rather than
 * a live owner that simply hasn't finished its atomic metadata commit.
 * Measured from the directory's own filesystem birth time (immutable and
 * identical for every observer), never from any one waiter's first poll,
 * so concurrent waiters never disagree about when the grace period ends.
 */
const rendererAssetDigestHelperLockInitGraceMs = nonNegativeIntegerFromEnv(
  "SEER_RENDERER_ASSET_DIGEST_HELPER_LOCK_INIT_GRACE_MS",
  2_000,
);

function sleepMs(durationMs) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, durationMs);
}

function lstatOrNull(path) {
  try {
    return lstatSync(path);
  } catch (error) {
    if (error && error.code === "ENOENT") return null;
    throw error;
  }
}

/**
 * Two `fs.Stats` refer to the exact same on-disk file/directory instance
 * only if `dev`+`ino` match *and* (whenever both sides report a finite
 * birth time) `birthtimeMs` also matches. `dev`+`ino` alone is not enough:
 * many filesystems recycle inode numbers essentially immediately after a
 * remove, so a since-replaced directory at the same path can otherwise
 * present the exact same `dev`+`ino` pair coincidentally.
 */
function sameFileSystemIdentity(left, right) {
  return (
    left.dev === right.dev &&
    left.ino === right.ino &&
    (!Number.isFinite(left.birthtimeMs) ||
      !Number.isFinite(right.birthtimeMs) ||
      left.birthtimeMs === right.birthtimeMs)
  );
}

function isPidAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error && error.code === "EPERM") return true;
    if (error && error.code === "ESRCH") return false;
    throw error;
  }
}

// The four functions below (owner-metadata reads, single-attempt reclaim,
// acquire, release) implement the crash-safe digest-helper lock protocol
// and are exported *only* so tests/renderer-asset-digest-helper-lock.test.mjs
// can construct precise on-disk fixtures (abandoned mid-init directories,
// dead-owner directories, concurrent reclaimers, successor locks) and
// drive this exact logic deterministically, without needing a real
// `swiftc` compile or timing-dependent process races. `compiledRendererAssetDigestHelper()`
// below is the only production caller.

/**
 * Reads and verifies `<lockDirPath>/owner.json`, opened `O_NOFOLLOW` and
 * re-checked by descriptor so it cannot be swapped out from under the
 * read. Returns `null` only when the file is simply absent (the narrow,
 * bounded, pre-commit window every fresh lock directory passes through).
 * Anything else that isn't a well-formed `{ pid }` record - a symlink, a
 * non-regular file, unparsable JSON, a missing/invalid `pid` - throws:
 * malformed or tampered lock state must never be silently treated as
 * either "live" or "reclaimable".
 */
export function readRendererAssetDigestHelperLockOwnerOrNull(lockDirPath) {
  const ownerPath = join(lockDirPath, "owner.json");
  const before = lstatOrNull(ownerPath);
  if (!before) return null;
  if (before.isSymbolicLink() || !before.isFile()) {
    throw new Error(
      `renderer asset digest helper lock owner metadata must be a regular non-symlink file: ${ownerPath}`,
    );
  }
  const descriptor = openSync(ownerPath, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const after = fstatSync(descriptor);
    if (!after.isFile() || !sameFileSystemIdentity(before, after)) {
      throw new Error(
        `renderer asset digest helper lock owner metadata changed identity while being opened: ${ownerPath}`,
      );
    }
    let parsed;
    try {
      parsed = JSON.parse(readFileSync(descriptor, "utf8"));
    } catch (error) {
      throw new Error(`renderer asset digest helper lock owner metadata is malformed: ${ownerPath}`, {
        cause: error,
      });
    }
    if (!parsed || typeof parsed !== "object" || !Number.isSafeInteger(parsed.pid) || parsed.pid <= 0) {
      throw new Error(`renderer asset digest helper lock owner metadata is malformed: ${ownerPath}`);
    }
    return { pid: parsed.pid, fileInfo: after };
  } finally {
    closeSync(descriptor);
  }
}

/**
 * Attempts exactly one identity-verified reclaim of a lock directory this
 * caller has already decided *looks* abandoned (`expectedDirInfo` and
 * `expectedOwnerInfo` - `null` for "no owner.json yet" - captured *before*
 * calling this). This never checks-then-acts on a live path (which always
 * leaves a race window between the check and the act): it acts first -
 * `renameSync` the directory out of the way, an atomic, single-winner
 * operation racing reclaimers naturally serialize on, since once one
 * reclaimer's rename has moved the source away, every other reclaimer's
 * rename of that same source path fails with `ENOENT` - and only then
 * verifies that what actually got moved is still the exact same directory
 * (and, when reclaiming a dead owner rather than a bare initialization
 * timeout, the exact same owner file) it inspected. Any mismatch (a
 * successor already replaced the lock in the meantime, or its owner
 * changed) restores the directory immediately, completely untouched -
 * this process must never delete a successor's lock.
 *
 * Returns `"reclaimed"` (the caller may now retry acquisition, which will
 * `mkdirSync` a fresh lock directory), `"raced"` (another reclaimer already
 * won; the caller should simply retry acquisition from scratch), or
 * `"not-stale"` (what is at this path now is not the abandoned state the
 * caller observed; retry acquisition from scratch).
 */
export function reclaimAbandonedRendererAssetDigestHelperLockDirectory(
  lockDirPath,
  expectedDirInfo,
  expectedOwnerInfo,
) {
  const quarantinePath = `${lockDirPath}.stale-${process.pid}-${randomBytes(6).toString("hex")}`;
  try {
    renameSync(lockDirPath, quarantinePath);
  } catch (error) {
    if (error && error.code === "ENOENT") return "raced";
    throw error;
  }
  let restore = true;
  try {
    const quarantineDirInfo = lstatSync(quarantinePath);
    if (
      quarantineDirInfo.isSymbolicLink() ||
      !quarantineDirInfo.isDirectory() ||
      !sameFileSystemIdentity(expectedDirInfo, quarantineDirInfo)
    ) {
      return "not-stale";
    }
    const quarantineOwner = readRendererAssetDigestHelperLockOwnerOrNull(quarantinePath);
    if (expectedOwnerInfo) {
      if (
        !quarantineOwner ||
        !sameFileSystemIdentity(expectedOwnerInfo.fileInfo, quarantineOwner.fileInfo)
      ) {
        return "not-stale";
      }
      if (isPidAlive(quarantineOwner.pid)) {
        return "not-stale";
      }
    } else if (quarantineOwner) {
      // Metadata now exists though it didn't when this looked like an
      // abandoned initialization: the real owner finished its atomic
      // commit just in time. Never delete a lock that turned out to be
      // live.
      return "not-stale";
    }
    restore = false;
    rmSync(quarantinePath, { recursive: true, force: false });
    return "reclaimed";
  } finally {
    if (restore) {
      try {
        renameSync(quarantinePath, lockDirPath);
      } catch (restoreError) {
        // Only reachable if a new owner's mkdirSync raced back into the
        // now-empty path between this reclaimer's rename above and this
        // restore attempt - astronomically unlikely, but never destroy
        // the quarantined directory or the new owner's lock over it:
        // leave the quarantined copy on disk for manual inspection.
        console.error(
          `unable to restore renderer asset digest helper lock ${lockDirPath} after determining it was not actually stale`,
          restoreError,
        );
      }
    }
  }
}

/**
 * Acquires `lockDirPath` as a crash-safe, cross-process mutual-exclusion
 * lock directory. `mkdirSync` itself is the only exclusive primitive used
 * to contend for ownership; owner identity (`owner.json`, containing this
 * process's pid) is committed *after* that, via write-to-temp-then-rename
 * so it is always either completely absent or completely present, never
 * partially written. A crash between those two steps therefore leaves a
 * well-defined "initializing" state (directory present, no owner.json)
 * that other waiters recognize and, after `initGraceMs`, safely reclaim -
 * rather than the previous single-lock-file design's empty/partially
 * written file, which no waiter's stale-owner check could ever recognize
 * as abandoned, wedging every future build indefinitely.
 */
export function acquireRendererAssetDigestHelperLock(lockDirPath, options = {}) {
  const deadlineMs = options.deadlineMs ?? rendererAssetDigestHelperLockDeadlineMs;
  const initGraceMs = options.initGraceMs ?? rendererAssetDigestHelperLockInitGraceMs;
  const deadline = Date.now() + deadlineMs;
  for (;;) {
    try {
      mkdirSync(lockDirPath, { mode: 0o700 });
    } catch (error) {
      if (!error || error.code !== "EEXIST") throw error;
      const dirInfo = lstatOrNull(lockDirPath);
      if (!dirInfo) continue; // vanished between the failed mkdir and this inspection; retry immediately.
      if (dirInfo.isSymbolicLink() || !dirInfo.isDirectory()) {
        throw new Error(
          `renderer asset digest helper lock path must be a real directory, never a symlink: ${lockDirPath}`,
        );
      }
      // Fails closed (throws) on malformed/symlink owner metadata instead
      // of guessing whether it is safe to reclaim.
      const owner = readRendererAssetDigestHelperLockOwnerOrNull(lockDirPath);
      if (owner) {
        if (isPidAlive(owner.pid)) {
          if (Date.now() >= deadline) {
            throw new Error(
              `timed out waiting for the live renderer asset digest helper lock owner (pid ${owner.pid}) to finish: ${lockDirPath}`,
            );
          }
          sleepMs(10);
          continue;
        }
        reclaimAbandonedRendererAssetDigestHelperLockDirectory(lockDirPath, dirInfo, owner);
        continue;
      }
      const ageMs = Number.isFinite(dirInfo.birthtimeMs) ? Date.now() - dirInfo.birthtimeMs : 0;
      if (ageMs < initGraceMs) {
        if (Date.now() >= deadline) {
          throw new Error(
            `timed out waiting for renderer asset digest helper lock initialization: ${lockDirPath}`,
          );
        }
        sleepMs(10);
        continue;
      }
      reclaimAbandonedRendererAssetDigestHelperLockDirectory(lockDirPath, dirInfo, null);
      continue;
    }
    const ownerPath = join(lockDirPath, "owner.json");
    const tempPath = join(lockDirPath, `.owner-${process.pid}-${randomBytes(6).toString("hex")}.tmp`);
    writeFileSync(tempPath, `${JSON.stringify({ pid: process.pid })}\n`, { mode: 0o600 });
    renameSync(tempPath, ownerPath);
    return {
      lockDirPath,
      dirInfo: lstatSync(lockDirPath),
      ownerInfo: readRendererAssetDigestHelperLockOwnerOrNull(lockDirPath),
    };
  }
}

/**
 * Releases a lock acquired by {@link acquireRendererAssetDigestHelperLock}.
 * Like reclaim, this acts first (`renameSync` the directory this process
 * believes it owns out of the way) and only then verifies, by identity,
 * that what actually got moved is the exact directory and owner file this
 * process created - never a successor's lock that happens to occupy the
 * same path. A mismatch restores the directory untouched and throws
 * instead of deleting; this process must never remove a lock instance it
 * did not itself acquire.
 */
export function releaseRendererAssetDigestHelperLock(lock) {
  const { lockDirPath, dirInfo, ownerInfo } = lock;
  const quarantinePath = `${lockDirPath}.release-${process.pid}-${randomBytes(6).toString("hex")}`;
  renameSync(lockDirPath, quarantinePath);
  let restore = true;
  try {
    const quarantineDirInfo = lstatSync(quarantinePath);
    if (
      quarantineDirInfo.isSymbolicLink() ||
      !quarantineDirInfo.isDirectory() ||
      !sameFileSystemIdentity(dirInfo, quarantineDirInfo)
    ) {
      throw new Error(`renderer asset digest helper lock changed identity before release: ${lockDirPath}`);
    }
    const quarantineOwner = readRendererAssetDigestHelperLockOwnerOrNull(quarantinePath);
    if (!quarantineOwner || !sameFileSystemIdentity(ownerInfo.fileInfo, quarantineOwner.fileInfo)) {
      throw new Error(
        `renderer asset digest helper lock owner metadata changed identity before release: ${lockDirPath}`,
      );
    }
    restore = false;
    rmSync(quarantinePath, { recursive: true, force: false });
  } finally {
    if (restore) {
      try {
        renameSync(quarantinePath, lockDirPath);
      } catch (restoreError) {
        console.error(
          `unable to restore renderer asset digest helper lock ${lockDirPath} after a failed release identity check`,
          restoreError,
        );
      }
    }
  }
}

function compiledRendererAssetDigestHelper() {
  if (process.platform !== "darwin") {
    throw new Error("descriptor-anchored renderer asset hashing requires macOS");
  }

  const source = readFileSync(rendererAssetDigestHelperSource);
  const helperPath = join(
    rendererAssetDigestHelperCache,
    `renderer-asset-digest-${sha256Hex(source)}`,
  );
  if (existsSync(helperPath)) return helperPath;

  mkdirSync(rendererAssetDigestHelperCache, { recursive: true });
  const lockDirPath = `${helperPath}.lock`;
  const lock = acquireRendererAssetDigestHelperLock(lockDirPath);
  try {
    if (existsSync(helperPath)) return helperPath;
    const stagingPath = `${helperPath}.${process.pid}`;
    const compilation = spawnSync("swiftc", [rendererAssetDigestHelperSource, "-o", stagingPath], {
      encoding: "utf8",
    });
    if (compilation.error || compilation.status !== 0) {
      rmSync(stagingPath, { force: true });
      throw new Error(
        `unable to compile descriptor-anchored renderer asset digest helper: ${
          compilation.error?.message ?? compilation.stderr?.trim() ?? "swiftc failed"
        }`,
        { cause: compilation.error },
      );
    }
    try {
      renameSync(stagingPath, helperPath);
    } finally {
      rmSync(stagingPath, { force: true });
    }
  } finally {
    releaseRendererAssetDigestHelperLock(lock);
  }
  return helperPath;
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

function readDescriptorAnchoredRendererAssets(rendererRoot, afterCollection) {
  const hook = normalizeAfterCollectionHook(afterCollection);
  const args = [resolve(rendererRoot)];
  if (hook) {
    args.push(
      "--after-collection-hook",
      Buffer.from(JSON.stringify(hook), "utf8").toString("base64"),
    );
  }
  const result = spawnSync(compiledRendererAssetDigestHelper(), args, {
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });
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
