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
  fstatSync,
  linkSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
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

function lstatOrNull(path) {
  try {
    return lstatSync(path);
  } catch (error) {
    if (error && error.code === "ENOENT") return null;
    throw error;
  }
}

/**
 * Two `fs.Stats` refer to the exact same on-disk file instance only if
 * `dev`+`ino` match *and* (whenever both sides report a finite birth
 * time) `birthtimeMs` also matches. `dev`+`ino` alone is not enough: many
 * filesystems recycle inode numbers essentially immediately after a
 * remove, so a since-replaced file at the same path can otherwise present
 * the exact same `dev`+`ino` pair coincidentally.
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

// The helper below is compiled and published without any mutual-exclusion
// lock at all. `helperPath` is content-addressed by the Swift source's own
// sha256 (see `compiledRendererAssetDigestHelper()`), so every concurrent
// process compiling the *same* source is - by construction - trying to
// publish byte-identical content to the exact same path: there is nothing
// to serialize between them. Each process instead compiles into its own
// unique, unpredictable, same-directory staging path and publishes with a
// single `linkSync` (POSIX `link(2)`): creating a new path is atomic and
// all-or-nothing, so at most one process's link to a given canonical path
// can ever succeed - every other process's link of that same path fails
// with `EEXIST` and simply defers to whichever content already won.
//
// This has no equivalent of any of the lock-protocol failure modes a
// crash-safe mutual-exclusion lock is still exposed to: there is no
// "successor" a slow reclaimer or a process's own cleanup could ever
// displace, because nothing is ever renamed or deleted *at* the canonical
// path - only unique, per-process staging files are ever unlinked, and a
// process's own staging path can never coincide with the canonical path
// or another process's staging path. There is no "still initializing"
// grace period that could reclaim a live-but-paused owner, because there
// is no multi-step owner-commit sequence to be caught mid-way through: a
// `link()` either has not happened yet, or has already completed with
// fully-formed content - never in between. There is no pid-based liveness
// check at all, so pid reuse can never matter. And there is no
// bounded-wait/deadline loop to overrun, because nothing ever waits: a
// loser resolves the winner's content immediately instead of polling for
// it. A process killed at any point leaves, at worst, an inert, uniquely
// named staging file nothing else ever looks at - never a canonical lock
// that could wedge a future build.
//
// Both the staged file (before publication) and the canonical path (this
// process's own just-published file, or a concurrent winner's) are
// independently verified - `lstat`, then re-checked by an `O_NOFOLLOW`
// descriptor's `fstat` - to be the exact same regular, non-symlink,
// current-user-owned, executable file throughout: this process never
// publishes content it has not itself validated, and never trusts (let
// alone executes) whatever ends up at the canonical path merely because
// *a* `link()` happened to succeed or fail.
//
// `rendererAssetDigestHelperCandidateRejectionReason()`,
// `verifyRendererAssetDigestHelperCandidateOrNull()`, and
// `publishRendererAssetDigestHelperCandidate()` are exported *only* so
// tests/renderer-asset-digest-publish.test.mjs can construct precise
// on-disk fixtures (preexisting symlinks/non-regular/non-executable
// canonical state, abandoned staging files, racing publishers) and drive
// this exact logic deterministically, without needing a real `swiftc`
// compile for every case. `compiledRendererAssetDigestHelper()` below is
// the only production caller.

/**
 * Pure check over an already-obtained `fs.Stats` (or, in tests, a
 * fabricated stand-in exposing the same shape) for why it would be
 * rejected as a renderer asset digest helper candidate, or `null` if it
 * looks like a plausible one. Kept separate from the lstat/open(
 * `O_NOFOLLOW`)/fstat identity dance in
 * {@link verifyRendererAssetDigestHelperCandidateOrNull} so "owned by a
 * different user" can be exercised deterministically in tests: actually
 * creating a file on disk owned by a different uid would require
 * root/multi-user privileges no test environment can assume, but
 * fabricating a `Stats`-shaped object with a foreign `uid` requires none.
 */
export function rendererAssetDigestHelperCandidateRejectionReason(stats) {
  if (!stats.isFile()) return "must be a regular file";
  if (stats.uid !== process.getuid()) return "is not owned by the current user";
  if ((stats.mode & constants.S_IXUSR) === 0) return "is not executable";
  if (stats.size <= 0) return "is empty";
  return null;
}

/**
 * Verifies that `path` is a regular, non-symlink, current-user-owned,
 * non-empty, owner-executable file, opened `O_NOFOLLOW` and re-checked by
 * descriptor so it can never be swapped out from under the check (never
 * trusting the initial `lstat` alone, which a symlink installed
 * immediately afterward could invalidate). Returns its `fs.Stats` on
 * success, or `null` only when nothing exists at `path` at all (the
 * ordinary "not staged/published yet" case). Anything else - a symlink, a
 * directory or other non-regular file, a file owned by someone else, a
 * non-executable or empty file, or one that changes identity between the
 * `lstat` and the `fstat` - throws: malformed or tampered helper state
 * must never be silently treated as absent, valid, or safe to overwrite.
 */
export function verifyRendererAssetDigestHelperCandidateOrNull(path, label) {
  const before = lstatOrNull(path);
  if (!before) return null;
  if (before.isSymbolicLink()) {
    throw new Error(`${label} must not be a symlink: ${path}`);
  }
  if (!before.isFile()) {
    throw new Error(`${label} must be a regular file: ${path}`);
  }
  let descriptor;
  try {
    descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  } catch (error) {
    if (error && error.code === "ENOENT") return null; // vanished between the lstat and this open.
    throw error;
  }
  try {
    const after = fstatSync(descriptor);
    if (!sameFileSystemIdentity(before, after)) {
      throw new Error(`${label} changed identity while being verified: ${path}`);
    }
    const rejection = rendererAssetDigestHelperCandidateRejectionReason(after);
    if (rejection) {
      throw new Error(`${label} ${rejection}: ${path}`);
    }
    return after;
  } finally {
    closeSync(descriptor);
  }
}

/**
 * Publishes `stagingPath` - a file this caller has already fully written
 * and closed, at a same-directory path unique to this process/attempt -
 * to `canonicalPath` via a single atomic, no-clobber `linkSync`: the only
 * primitive this design relies on for exclusivity, since at most one
 * `link()` of any given new path can ever succeed.
 *
 * `stagingPath` is independently verified *before* the link attempt (this
 * process must never publish content it has not itself validated), and
 * `canonicalPath` is independently re-verified *after* - regardless of
 * whether this call's own link won or a concurrent publisher's did,
 * because that outcome alone says nothing about whether the file now at
 * `canonicalPath` (this call's own, a concurrent winner's, or something
 * pre-existing entirely outside this protocol) is actually valid.
 *
 * `stagingPath` is always removed before returning or throwing. It is
 * unique to this call and never the canonical path, so removing it can
 * never affect `canonicalPath` or any other process's own staging file -
 * whether this call's link won, lost, or validation itself failed.
 */
export function publishRendererAssetDigestHelperCandidate(stagingPath, canonicalPath) {
  try {
    const staged = verifyRendererAssetDigestHelperCandidateOrNull(
      stagingPath,
      "freshly compiled renderer asset digest helper",
    );
    if (!staged) {
      throw new Error(`freshly compiled renderer asset digest helper is missing: ${stagingPath}`);
    }
    try {
      linkSync(stagingPath, canonicalPath);
    } catch (error) {
      // `EEXIST` is the *only* possible outcome for every loser: a
      // concurrent publisher's link to `canonicalPath` already succeeded
      // first, and its content is already complete and immutable there.
      // There is nothing to undo and nothing more to do.
      if (!error || error.code !== "EEXIST") throw error;
    }
  } finally {
    rmSync(stagingPath, { force: true });
  }

  const published = verifyRendererAssetDigestHelperCandidateOrNull(
    canonicalPath,
    "renderer asset digest helper",
  );
  if (!published) {
    throw new Error(
      `renderer asset digest helper is missing immediately after publication: ${canonicalPath}`,
    );
  }
  return published;
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
  if (verifyRendererAssetDigestHelperCandidateOrNull(helperPath, "renderer asset digest helper")) {
    return helperPath;
  }

  mkdirSync(rendererAssetDigestHelperCache, { recursive: true });

  // Unique and unpredictable (pid *and* random bytes - never just a
  // predictable name another process, or an attacker on a shared cache
  // directory, could pre-create/pre-empt), but always in the same
  // directory as `helperPath` so `linkSync` below never crosses a
  // filesystem boundary.
  const stagingPath = join(
    rendererAssetDigestHelperCache,
    `.renderer-asset-digest-staging-${process.pid}-${randomBytes(16).toString("hex")}`,
  );
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

  publishRendererAssetDigestHelperCandidate(stagingPath, helperPath);
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
