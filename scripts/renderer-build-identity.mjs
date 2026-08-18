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
  chmodSync,
  closeSync,
  constants,
  fstatSync,
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
const rendererAssetDigestPrivateRunsRootParentDir = join(
  dirname(dirname(rendererAssetDigestHelperSource)),
  "build",
);
// A fixed, well-known *parent* directory name is fine to share by name
// across every process/invocation: nothing is ever published or contended
// for at this exact path. It exists only to hold each invocation's own
// unique, unpredictable run directory (see
// createPrivateRendererAssetDigestRunDir below); this parent is itself
// verified real/non-symlink/current-uid-owned/mode-0700 (see
// ensurePrivateDirectory) every time, so - regardless of `build/`'s own
// permissions - no other OS user can ever traverse into it, let alone
// create, read, or race the creation of anything inside it.
// Exported only so tests can place deliberately abandoned/malformed
// fixtures at the exact same path production uses (e.g. to prove a
// leftover directory from a killed process never blocks a later,
// independent real call) without duplicating this path-construction logic.
export const rendererAssetDigestPrivateRunsRoot = join(
  rendererAssetDigestPrivateRunsRootParentDir,
  ".renderer-asset-digest-runs",
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

// The helper below has no shared canonical name at all: nothing is ever
// staged-then-published, locked, or reused across calls or processes. Every
// single call that needs it (see readDescriptorAnchoredRendererAssets)
// compiles its own fresh copy into its own unique, unpredictable, private
// work directory - created fresh, used once, and removed again before that
// call returns - so there is no shared state for a validation/publication/
// execution TOCTOU to ever open a window in, and no canonical winner whose
// identity a concurrent or later call could race, displace, or wedge.
//
// Exclusivity comes entirely from filesystem permissions, not from any
// mutual-exclusion protocol: `ensurePrivateDirectory` requires the private
// runs root and every run directory under it to be a real, non-symlink
// directory, owned by the current uid, and mode *exactly* 0700 (rejecting
// any group/world bit at all) - normalizing (`chmodSync`) newly created
// directories rather than trusting the mode requested at creation, because
// that request is itself subject to the ambient umask and can otherwise
// come out *less* permissive than intended (observed directly: an unusual
// umask can leave a freshly created "mode 0700" directory completely
// inaccessible, though never more permissive than requested - umask only
// ever clears bits). A preexisting parent that is not already exactly this
// shape is never "fixed" (chmod'd, or deleted and recreated) - fixing a
// symlink planted at that exact path could affect whatever it actually
// points at - it is rejected outright, failing closed. Since no other OS
// user can ever traverse, read, or write a 0700 directory owned by someone
// else, nothing outside this process's own uid can pre-create, observe, or
// tamper with anything inside its run directory, regardless of `build/`'s
// own (unrelated, unchanged) permissions.
//
// The compiled file itself is chmod 0500 (owner read+execute, no write bit
// at all) immediately after compilation, then independently validated -
// `lstat`, then re-checked by an `O_NOFOLLOW`-opened descriptor's `fstat` -
// to be a regular, non-symlink, current-uid-owned, non-empty,
// owner-executable file that is not writable by any group or other user.
// That descriptor is kept open through the spawn immediately below it
// (`spawnValidatedPrivateRendererAssetDigestHelperFile`), which spawns by
// the private pathname - Node has no portable way to exec an already-open
// descriptor directly - and then revalidates identity immediately
// afterward: a fresh `lstat` of that same pathname (catching a full
// unlink-and-replace, which the kept-open descriptor's own `fstat` cannot
// see, since it still refers to the original, now-detached inode) and a
// fresh `fstat` of the original descriptor re-checked against every
// rejection rule (catching an in-place mutation of that same inode, e.g. a
// chmod or truncate-and-overwrite that never unlinked the path at all).
// This cannot *prevent* a same-uid actor from swapping the file between
// validation and spawn - no pathname-based exec ever can - it only
// guarantees such a swap is always detected and thrown, never silently
// trusted. Under this design's threat model (a 0700, current-uid-owned
// private run directory nothing else can traverse or write into), no other
// OS user can ever perform that swap in the first place.
//
// Cleanup only ever removes the exact run directory this call itself just
// created, and only after re-verifying (fresh `lstat` + identity check)
// that it still is that exact directory - never a path that merely looks
// similar, and never any *other* call's or process's run directory. This
// module never scans the shared runs root for "abandoned" entries to clean
// up: a process killed at any point (compiler failure, a SIGKILL, anything
// in between) leaves at worst one inert, uniquely named leftover directory
// nothing else ever looks at, waits on, or depends on - it can never wedge,
// block, or otherwise affect any other, fully independent call, each of
// which always creates and only ever touches its own unique path.

/**
 * Pure check over an already-obtained `fs.Stats` (or, in tests, a
 * fabricated stand-in exposing the same shape) for why `stats` would be
 * rejected as a private run directory (or the runs root itself), or `null`
 * if it looks safe. Kept separate from the on-disk lstat/open(
 * `O_NOFOLLOW`)/fstat identity dance in {@link verifyPrivateDirectoryOrThrow}
 * so "owned by a different user" can be exercised deterministically in
 * tests without root/multi-user privileges.
 */
export function privateDirectoryRejectionReason(stats) {
  if (!stats.isDirectory()) return "must be a real directory";
  if (stats.uid !== process.getuid()) return "is not owned by the current user";
  if ((stats.mode & 0o777) !== 0o700) return "must be mode 0700, rejecting any group/world access";
  return null;
}

/**
 * Verifies that `path` is a real, non-symlink directory, owned by the
 * current user, mode *exactly* 0700 - opened `O_NOFOLLOW|O_DIRECTORY` and
 * re-checked by descriptor so it can never be swapped out from under the
 * check (never trusting the initial `lstat` alone, which a symlink
 * installed immediately afterward could invalidate). Throws on absolutely
 * any mismatch, including absence: unlike the removed publish design,
 * nothing here is ever a legitimate "not published yet" state - a missing
 * or malformed directory is always an error the caller must fail closed on,
 * never silently treated as safe to create-over or reuse.
 */
export function verifyPrivateDirectoryOrThrow(path, label) {
  const before = lstatSync(path);
  if (before.isSymbolicLink()) {
    throw new Error(`${label} must not be a symlink: ${path}`);
  }
  if (!before.isDirectory()) {
    throw new Error(`${label} must be a real directory: ${path}`);
  }
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_DIRECTORY);
  try {
    const after = fstatSync(descriptor);
    if (!sameFileSystemIdentity(before, after)) {
      throw new Error(`${label} changed identity while being verified: ${path}`);
    }
    const rejection = privateDirectoryRejectionReason(after);
    if (rejection) {
      throw new Error(`${label} ${rejection}: ${path}`);
    }
    return after;
  } finally {
    closeSync(descriptor);
  }
}

/**
 * Ensures `path` is a private (real, non-symlink, current-uid-owned, mode
 * 0700) directory, creating it fresh if nothing exists there yet, and
 * always independently verifying it (whether just created or preexisting)
 * before returning. Creation always normalizes the mode with an explicit
 * `chmodSync` immediately afterward rather than trusting `mkdirSync`'s own
 * `mode` option, which is itself subject to the ambient umask (umask can
 * only ever clear bits, so a freshly created directory here can come out
 * *less* permissive than 0700 - even fully inaccessible - but never more;
 * there is accordingly no window where it is briefly more open than
 * intended). A preexisting path that fails verification is never repaired
 * (chmod'd, or removed and recreated) - only ever rejected - so this
 * always fails closed on an unsafe preexisting parent instead of guessing
 * at whether it is safe to reuse or "fix".
 */
export function ensurePrivateDirectory(path, label) {
  if (!lstatOrNull(path)) {
    mkdirSync(path, { mode: 0o700 });
    chmodSync(path, 0o700);
  }
  return verifyPrivateDirectoryOrThrow(path, label);
}

/**
 * Creates one fresh, unique, unpredictable (pid *and* 128 random bits -
 * never a predictable name anything could pre-create or pre-empt, though
 * under this design's 0700-parent threat model no other uid ever could
 * regardless) private run directory under the already-validated `root`,
 * verifies it, and returns its path alongside the verified `fs.Stats`
 * cleanup later re-checks identity against.
 */
export function createPrivateRendererAssetDigestRunDir(root) {
  const path = join(root, `run-${process.pid}-${randomBytes(16).toString("hex")}`);
  return { path, stats: ensurePrivateDirectory(path, "renderer asset digest private run directory") };
}

/**
 * Removes exactly the run directory this process itself created - never
 * any other path - and only after re-verifying (fresh `lstat` + identity
 * check against the `stats` captured at creation time) that it still is
 * that exact, untampered directory. A mismatch (vanished, replaced,
 * symlinked, or otherwise no longer identical) never triggers a recursive
 * delete: it is logged and left in place, exactly as an abandoned
 * leftover from a killed process would be (see the module doc comment
 * above) - this can never wedge or affect any other, independent call.
 * Never throws: a failed or skipped cleanup must never fail an otherwise-
 * already-completed (successful or not) digest computation.
 */
export function removePrivateRendererAssetDigestRunDirIfSafe(runDir) {
  const current = lstatOrNull(runDir.path);
  if (!current || current.isSymbolicLink() || !current.isDirectory() || !sameFileSystemIdentity(runDir.stats, current)) {
    if (current) {
      console.error(
        `renderer asset digest private run directory changed identity before cleanup, leaving it in place: ${runDir.path}`,
      );
    }
    return;
  }
  try {
    rmSync(runDir.path, { recursive: true });
  } catch (error) {
    console.error(
      `failed to remove renderer asset digest private run directory ${runDir.path}: ${error.message}`,
    );
  }
}

/**
 * Ensures the shared (by name only - never by content or state) private
 * runs root exists and is safe, creates one fresh unique run directory
 * under it, hands its path to `run`, and always attempts to remove exactly
 * that run directory afterward (see
 * removePrivateRendererAssetDigestRunDirIfSafe) regardless of whether `run`
 * succeeded or threw. A compiler failure or any other error `run` throws
 * still triggers cleanup of this call's own run directory before
 * propagating - it can never block any other, fully independent call, each
 * of which creates and only ever touches its own unique directory.
 */
export function withPrivateRendererAssetDigestHelper(run) {
  mkdirSync(rendererAssetDigestPrivateRunsRootParentDir, { recursive: true });
  ensurePrivateDirectory(rendererAssetDigestPrivateRunsRoot, "renderer asset digest private runs root");
  const runDir = createPrivateRendererAssetDigestRunDir(rendererAssetDigestPrivateRunsRoot);

  let result;
  let failure;
  try {
    result = run(runDir.path);
  } catch (error) {
    failure = error;
  }
  removePrivateRendererAssetDigestRunDirIfSafe(runDir);
  if (failure) throw failure;
  return result;
}

/**
 * Pure check over an already-obtained `fs.Stats` (or, in tests, a
 * fabricated stand-in) for why it would be rejected as the compiled
 * renderer asset digest helper executable, or `null` if it looks safe to
 * trust and spawn. Kept separate from the on-disk identity dance in
 * {@link openValidatedPrivateRendererAssetDigestHelperFile} so
 * "owned by a different user" can be exercised deterministically in tests
 * without root/multi-user privileges. Beyond the removed publish design's
 * own checks, this also rejects group/world *writability* specifically
 * (independent of the exact mode bits) - defense in depth on top of the
 * 0500 chmod compilation always applies, in case that chmod's own effect
 * were ever somehow bypassed.
 */
export function rendererAssetDigestHelperFileRejectionReason(stats) {
  if (!stats.isFile()) return "must be a regular file";
  if (stats.uid !== process.getuid()) return "is not owned by the current user";
  if ((stats.mode & constants.S_IXUSR) === 0) return "is not executable by its owner";
  if ((stats.mode & (constants.S_IWGRP | constants.S_IWOTH)) !== 0) {
    return "is writable by a group or other user";
  }
  if (stats.size <= 0) return "is empty";
  return null;
}

/**
 * Verifies that `path` is a regular, non-symlink, current-uid-owned,
 * non-empty, owner-executable, not-group-or-world-writable file - `lstat`,
 * then re-checked by an `O_NOFOLLOW`-opened descriptor's `fstat`, so it can
 * never be swapped out from under the check (never trusting the initial
 * `lstat` alone, which a symlink installed immediately afterward could
 * invalidate). Throws on any mismatch, including absence. Returns the open
 * descriptor and its stats; the caller must keep the descriptor open
 * through the spawn (see {@link spawnValidatedPrivateRendererAssetDigestHelperFile})
 * and is responsible for closing it afterward.
 */
export function openValidatedPrivateRendererAssetDigestHelperFile(path, label) {
  const before = lstatSync(path);
  if (before.isSymbolicLink()) {
    throw new Error(`${label} must not be a symlink: ${path}`);
  }
  if (!before.isFile()) {
    throw new Error(`${label} must be a regular file: ${path}`);
  }
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const after = fstatSync(fd);
    if (!sameFileSystemIdentity(before, after)) {
      throw new Error(`${label} changed identity while being verified: ${path}`);
    }
    const rejection = rendererAssetDigestHelperFileRejectionReason(after);
    if (rejection) {
      throw new Error(`${label} ${rejection}: ${path}`);
    }
    return { fd, stats: after };
  } catch (error) {
    closeSync(fd);
    throw error;
  }
}

/**
 * Spawns the already-validated `path` (see
 * {@link openValidatedPrivateRendererAssetDigestHelperFile}) by pathname -
 * Node has no portable way to exec an already-open descriptor directly -
 * then revalidates identity immediately afterward, before the caller may
 * trust `spawnSync`'s result: a fresh `lstat` of `path` compared against
 * the stats captured at validation time (catching a full unlink-and-replace
 * or a symlink swap - a scenario the kept-open descriptor's own `fstat`
 * cannot see, since it still refers to the original, now-detached inode),
 * and a fresh `fstat` of that original descriptor re-checked against every
 * rejection rule (catching an in-place mutation of that same inode, e.g. a
 * chmod or truncate-and-overwrite that never unlinked the path at all).
 *
 * This cannot *prevent* a same-uid actor from swapping the file between
 * validation and this call - no pathname-based exec ever can - it only
 * guarantees such a swap is always detected and thrown, never silently
 * trusted. Under this design's threat model (a 0700, current-uid-owned
 * private run directory nothing else can traverse or write into), no other
 * OS user can ever perform that swap in the first place.
 */
export function spawnValidatedPrivateRendererAssetDigestHelperFile(path, opened, label, args, spawnOptions) {
  const result = spawnSync(path, args, spawnOptions);

  const afterPath = lstatOrNull(path);
  if (!afterPath || afterPath.isSymbolicLink() || !sameFileSystemIdentity(opened.stats, afterPath)) {
    throw new Error(`${label} changed identity between validation and spawn: ${path}`);
  }
  const afterDescriptor = fstatSync(opened.fd);
  const rejection = rendererAssetDigestHelperFileRejectionReason(afterDescriptor);
  if (rejection) {
    throw new Error(`${label} ${rejection} immediately after spawn: ${path}`);
  }
  return result;
}

/**
 * Compiles `sourcePath` into a file named `digest-helper` inside `runDir`
 * (already private and validated by the caller - see
 * {@link withPrivateRendererAssetDigestHelper}) and chmods it 0500 (owner
 * read+execute, no write bit at all - not even for its own owner, so
 * nothing can trivially mutate it in place afterward without an explicit
 * chmod first) before returning its path. Never caches, reuses, or shares
 * this compiled output with any other call: every call compiles its own.
 * Compiler stdout/stderr are bounded (`maxBuffer`) so a runaway or
 * unexpectedly verbose `swiftc` invocation can never grow unbounded.
 */
export function compilePrivateRendererAssetDigestHelper(sourcePath, runDir) {
  const helperPath = join(runDir, "digest-helper");
  const compilation = spawnSync("swiftc", [sourcePath, "-o", helperPath], {
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (compilation.error || compilation.status !== 0) {
    throw new Error(
      `unable to compile descriptor-anchored renderer asset digest helper: ${
        compilation.error?.message ?? compilation.stderr?.trim() ?? "swiftc failed"
      }`,
      { cause: compilation.error },
    );
  }
  chmodSync(helperPath, 0o500);
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

// This call compiles, validates, spawns, revalidates, and cleans up a
// brand-new private helper instance every single time it runs (see
// withPrivateRendererAssetDigestHelper above): there is no cache, no
// canonical path, and nothing shared or reused across calls or processes.
function readDescriptorAnchoredRendererAssets(rendererRoot, afterCollection) {
  if (process.platform !== "darwin") {
    throw new Error("descriptor-anchored renderer asset hashing requires macOS");
  }
  const hook = normalizeAfterCollectionHook(afterCollection);
  const args = [resolve(rendererRoot)];
  if (hook) {
    args.push(
      "--after-collection-hook",
      Buffer.from(JSON.stringify(hook), "utf8").toString("base64"),
    );
  }

  return withPrivateRendererAssetDigestHelper((runDirPath) => {
    const helperPath = compilePrivateRendererAssetDigestHelper(rendererAssetDigestHelperSource, runDirPath);
    const opened = openValidatedPrivateRendererAssetDigestHelperFile(helperPath, "renderer asset digest helper");
    try {
      const result = spawnValidatedPrivateRendererAssetDigestHelperFile(
        helperPath,
        opened,
        "renderer asset digest helper",
        args,
        { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 },
      );
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
    } finally {
      closeSync(opened.fd);
    }
  });
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
