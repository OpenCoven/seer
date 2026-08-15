#!/usr/bin/env node
// Boundary checks that prove the standalone macOS build never absorbs any
// part of the Glaze/Electron runtime it was ported off of.
//
// Two independent surfaces are scanned:
//
//   1. Repository *source* (`scanSourceBoundary`): the standalone-safe
//      surface — shared renderer code, the native Swift app, and the small
//      set of shared TypeScript policy files the standalone build actually
//      reads — must never reference `@glaze/core`, the `.glaze-core` local
//      SDK symlink (see `glaze.ts`), the `glaze-core:` custom resource
//      scheme, the `window.glazeAPI` bridge global, or a literal Glaze SDK
//      binary path. This is a *content* scan, independent of whether a
//      build has ever run.
//
//   2. A built `.app` bundle (`scanBundle` + `checkInfoPlist` +
//      `checkEntitlements`): walked with `fs` APIs that never follow
//      symlinks, checked file-by-file for forbidden names/extensions and
//      forbidden byte content (the recorded canonical repo/DerivedData
//      paths, absolute `/Users/` paths, the current account's home directory,
//      and the same Glaze references as above), and structurally verified via
//      `/usr/bin/file` (exactly one Mach-O, at `Contents/MacOS/Seer`),
//      `/usr/bin/lipo -archs` (exact output `arm64`), and `/usr/bin/otool -L`
//      (every dependency under `/System/Library` or `/usr/lib`, never an
//      embedded `@rpath` framework). These are structural allowlists —
//      they catch an embedded runtime executable/framework regardless of
//      what it happens to be named, not only files that still say "Glaze"
//      or "node" in their name.
//
// Both this module's exported functions and `tests/standalone-boundary.test.mjs`
// import from this single file, so the checks a CI/local run enforces and
// the checks the test suite asserts against can never silently drift apart
// (the same pattern `scripts/renderer-build-identity.mjs` already
// established for the renderer build-identity digest).
import { execFileSync } from "node:child_process";
import console from "node:console";
import {
  closeSync,
  constants as fsConstants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  readdirSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative } from "node:path";
import { normalize as posixNormalize } from "node:path/posix";
import process from "node:process";
import { fileURLToPath } from "node:url";

/**
 * Lstat's `path` (never following a symlink, unlike `existsSync`/`statSync`)
 * and returns its `Stats`, or `null` if nothing exists at `path` at all.
 * Used everywhere a path's existence/symlink-ness must be checked without
 * ever transparently resolving through a symlink as a side effect of the
 * check itself.
 */
function lstatOrNull(path) {
  try {
    return lstatSync(path);
  } catch {
    return null;
  }
}

const here = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = dirname(here);

/** The bundle path this script checks unless overridden — never committed, built fresh by `npm run build:macos`. */
export const DEFAULT_APP_PATH = join(REPO_ROOT, "build", "macos", "unsigned", "Seer.app");

/** Private local build metadata, deliberately adjacent to (not inside) the unsigned output directory. */
export const DEFAULT_PROVENANCE_PATH = join(REPO_ROOT, "build", "macos", "standalone-build-provenance.json");

/** The one file the built bundle's executable is expected at, relative to the `.app` root. */
export const EXPECTED_EXECUTABLE_RELATIVE_PATH = "Contents/MacOS/Seer";

/**
 * Forbidden Glaze references in *source*: an import/global a standalone
 * file could plausibly contain if Glaze-specific code (or a copy-pasted
 * fragment of it) leaked into the standalone-safe surface.
 */
export const SOURCE_FORBIDDEN_PATTERNS = [
  { pattern: /@glaze\/core/, description: "@glaze/core import" },
  { pattern: /\.glaze-core\b/, description: ".glaze-core local SDK symlink/path (see glaze.ts)" },
  { pattern: /glaze-core:/, description: "glaze-core: custom resource scheme" },
  { pattern: /window\.glazeAPI/, description: "window.glazeAPI bridge global" },
  { pattern: /app\.glaze\.macos/, description: "Glaze app's Application Support bundle identifier path" },
  { pattern: /cli\/glaze\.js/, description: "Glaze SDK CLI binary path" },
];

/**
 * Standalone-safe directories walked recursively for the source scan.
 * Mirrors `lint:standalone`'s scope (see `package.json`) plus the native
 * Swift app, which cannot import Glaze at all but can still leak a
 * hardcoded Glaze SDK path in a comment or fixture.
 */
const SOURCE_SCAN_DIRS = [
  "renderer",
  "apps/macos/Seer/Sources",
  "apps/macos/Seer/Tests",
  "apps/macos/Seer/Config",
  "apps/macos/Seer/Scripts",
];

/**
 * Standalone-safe individual files walked for the source scan.
 * Deliberately excludes this module itself (`check-standalone-boundary.mjs`)
 * — dev-time tooling, never shipped into the bundle — since its own
 * `SOURCE_FORBIDDEN_PATTERNS` definitions and documentation necessarily
 * spell out the exact forbidden strings they match, which would otherwise
 * make this scan permanently flag itself.
 */
const SOURCE_SCAN_FILES = [
  "apps/macos/Seer/project.yml",
  "main/services/agent-detection-policy.ts",
  "main/services/update-check.ts",
  "vite.standalone.config.ts",
  "standalone-window.html",
  "tsconfig.standalone.json",
  "scripts/build-macos-app.sh",
  "scripts/build-standalone-renderer.mjs",
  "scripts/publish-macos-app.py",
];

/**
 * Files under `renderer/` that intentionally implement (or exercise) the
 * Glaze-specific `RendererBridge`, or the Glaze-only dev entry point — the
 * whole point of the `RendererBridge` seam is that exactly one
 * implementation is allowed to reference Glaze, and it is this one, never
 * shipped into the standalone bundle.
 */
const EXCLUDED_SOURCE_FILES = new Set([
  "renderer/preload.ts",
  "renderer/main/index.tsx",
  "renderer/bridge/glaze-renderer-bridge.ts",
  "renderer/bridge/glaze-renderer-bridge.test.ts",
]);

const EXCLUDED_SOURCE_DIRS = ["renderer/dev"];

/**
 * Recursively collects root-relative file paths under `directory`, skipping
 * excluded dirs/files. Uses `readdirSync(..., { withFileTypes: true })`'s
 * `Dirent`, which reports a symlink entry as a symlink (`isSymbolicLink()`)
 * without following it — a symlinked entry is never treated as a directory
 * to recurse into nor as a plain file to later `readFileSync`; it is
 * pushed to `offenders` and otherwise skipped entirely, so a source-tree
 * symlink pointing outside the repository (or anywhere else) can never be
 * dereferenced by this scan.
 */
function walkFiles(directory, root, excludedDirs, excludedFiles, out, offenders) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const fullPath = join(directory, entry.name);
    const relPath = relative(root, fullPath);

    if (excludedDirs.some((dir) => relPath === dir || relPath.startsWith(`${dir}/`))) {
      continue;
    }
    if (entry.isSymbolicLink()) {
      offenders.push(`${relPath}: symlink in source tree (not allowed; skipped, never followed)`);
      continue;
    }
    if (entry.isDirectory()) {
      walkFiles(fullPath, root, excludedDirs, excludedFiles, out, offenders);
      continue;
    }
    if (excludedFiles.has(relPath)) {
      continue;
    }
    out.push(relPath);
  }
}

/**
 * Gathers root-relative paths of every standalone-safe source file:
 * `SOURCE_SCAN_DIRS` walked recursively (skipping `EXCLUDED_SOURCE_DIRS`
 * and `EXCLUDED_SOURCE_FILES`) plus `SOURCE_SCAN_FILES`. Missing
 * directories/files are silently skipped rather than throwing, so this
 * also works unmodified against a partial, synthetic fixture root (e.g. a
 * disposable directory containing only a `renderer/` subtree) — never
 * only against a full repository checkout.
 *
 * Every `SOURCE_SCAN_DIRS`/`SOURCE_SCAN_FILES` entry is `lstat`'d (never
 * `existsSync`/`statSync`, which follow symlinks) before it is walked or
 * read: a symlinked scan root or scan file is recorded in `offenders` and
 * skipped, never traversed or read through, so a symlink cannot be used to
 * redirect this scan outside the repository — including a dangling
 * symlink whose target does not exist or is not readable at all.
 */
export function listStandaloneSourceFiles(repoRoot) {
  const files = [];
  const offenders = [];
  for (const dir of SOURCE_SCAN_DIRS) {
    const fullDirPath = join(repoRoot, dir);
    const stat = lstatOrNull(fullDirPath);
    if (!stat) {
      continue;
    }
    if (stat.isSymbolicLink()) {
      offenders.push(`${dir}: symlink in source tree (not allowed; skipped, never followed)`);
      continue;
    }
    walkFiles(fullDirPath, repoRoot, EXCLUDED_SOURCE_DIRS, EXCLUDED_SOURCE_FILES, files, offenders);
  }
  for (const file of SOURCE_SCAN_FILES) {
    if (EXCLUDED_SOURCE_FILES.has(file)) {
      continue;
    }
    const fullFilePath = join(repoRoot, file);
    const stat = lstatOrNull(fullFilePath);
    if (!stat) {
      continue;
    }
    if (stat.isSymbolicLink()) {
      offenders.push(`${file}: symlink in source tree (not allowed; skipped, never followed)`);
      continue;
    }
    files.push(file);
  }
  return { files, offenders };
}

/**
 * Scans `files` (root-relative paths under `root`) for `patterns`,
 * returning one offender string per match. Deliberately decoupled from
 * `listStandaloneSourceFiles`'s fixed directory/file list so it can be
 * exercised directly against an arbitrary, disposable file list — e.g. a
 * test proving the pattern-matching itself flags a violation — without
 * needing a fixture that mirrors this repository's whole standalone
 * source layout.
 */
export function scanFilesForForbiddenPatterns(files, root, patterns = SOURCE_FORBIDDEN_PATTERNS) {
  const offenders = [];
  for (const relPath of files) {
    const source = readFileSync(join(root, relPath), "utf8");
    for (const { pattern, description } of patterns) {
      if (pattern.test(source)) {
        offenders.push(`${relPath}: contains ${description} (matches ${pattern})`);
      }
    }
  }
  return offenders;
}

/**
 * Scans every standalone-safe source file for `SOURCE_FORBIDDEN_PATTERNS`,
 * returning one offender string per match, plus one offender per symlink
 * `listStandaloneSourceFiles` found and skipped. An empty array means the
 * source boundary is clean.
 */
export function scanSourceBoundary(repoRoot = REPO_ROOT) {
  const { files, offenders } = listStandaloneSourceFiles(repoRoot);
  return [...offenders, ...scanFilesForForbiddenPatterns(files, repoRoot)];
}

/**
 * Bundle entry names/extensions that must never appear in the shipped
 * `.app`, regardless of where in the bundle they'd otherwise land.
 * Deliberately structural (extension/name), not content-based, so a
 * renamed offender is still caught by `scanBundle`'s Mach-O/otool checks
 * even if it slips past this list.
 */
export const BUNDLE_FORBIDDEN_NAME_PATTERNS = [
  { pattern: /\.map$/, description: "source map" },
  { pattern: /\.tsx?$/, description: "TypeScript source" },
  { pattern: /\.node$/, description: "native Node addon" },
  { pattern: /(?:^|\/)node(?:js)?$/i, description: "Node executable" },
  { pattern: /glaze/i, description: "Glaze-named file" },
  { pattern: /Fixtures\//, description: "test fixture" },
  { pattern: /(?:^|\/)package-lock\.json$/, description: "package lock file" },
  { pattern: /(?:^|\/)yarn\.lock$/, description: "package lock file" },
  { pattern: /(?:^|\/)pnpm-lock\.yaml$/, description: "package lock file" },
];

/** Byte-level content patterns forbidden anywhere in the built bundle. */
const BUNDLE_FORBIDDEN_CONTENT_PATTERNS = [
  { pattern: /\/Users\//, description: "absolute /Users/ path" },
  { pattern: /@glaze\/core/, description: "@glaze/core reference" },
  { pattern: /glaze-core:/, description: "glaze-core: reference" },
];

/**
 * Lstat's every path component from `appPath` (the app bundle root) down to
 * `appPath/relativePath` inclusive — never `appPath`'s or any intermediate
 * component's resolved target — and returns an offender string for the
 * first (root-most) component found to be a symlink, or `null` if every
 * component that currently exists is a real, non-symlink directory/file.
 * A missing component is not itself an offender here; the caller's own
 * subsequent `plutil`/`file`/`otool`/`codesign` call is left to report a
 * normal "not found" failure for that case.
 *
 * This exists because `scanBundle`'s recursive `walkBundle` already checks
 * every component *below* `appPath` via `Dirent.isSymbolicLink()` as it
 * descends, but `appPath` itself — and any function invoked independently
 * of `walkBundle`, such as `checkInfoPlist` and `checkEntitlements` calling
 * straight into `plutil`/`codesign` — is not otherwise protected: without
 * this check, a symlinked bundle root, or a symlinked `Contents`/
 * `Contents/Info.plist` reached only through such a standalone call, would
 * be transparently followed by the OS the moment `plutil`/`codesign` opens
 * it.
 */
export function findBundleSymlinkOffender(appPath, relativePath = "") {
  let current = appPath;
  const candidates = [current];
  if (relativePath) {
    for (const segment of relativePath.split("/")) {
      current = join(current, segment);
      candidates.push(current);
    }
  }

  for (const candidatePath of candidates) {
    const stat = lstatOrNull(candidatePath);
    if (!stat) {
      return null;
    }
    if (stat.isSymbolicLink()) {
      const label = candidatePath === appPath ? "app bundle root" : relative(appPath, candidatePath);
      return `${label}: symlink in bundle path (not allowed; refusing to read/run tools through it)`;
    }
  }
  return null;
}

/**
 * Walks `appPath` with `fs` APIs that never follow symlinks
 * (`readdirSync(..., { withFileTypes: true })`'s `Dirent` reports a
 * symlink as a symlink, not as whatever it points at, and this function
 * never calls `statSync`/`readlinkSync` to resolve one). Returns
 * `{ offenders, regularFiles }`: `offenders` already covers every symlink,
 * forbidden name, and forbidden content match found; `regularFiles` is
 * every plain file's bundle-relative path, for the caller's Mach-O/otool
 * pass.
 *
 * Callers must check `findBundleSymlinkOffender(appPath)` (or otherwise
 * know `appPath` itself is not a symlink) before calling this — `visit`
 * below calls `readdirSync(appPath)` directly for the root, which (like
 * any `fs` call given a path, as opposed to a `Dirent` already reported by
 * a previous `readdirSync`) transparently follows `appPath` if it is
 * itself a symlink.
 */
export function walkBundle(appPath, { forbiddenAbsolutePaths = [] } = {}) {
  const offenders = [];
  const regularFiles = [];
  const uniqueBuildPaths = [
    ...new Set(forbiddenAbsolutePaths.filter((path) => typeof path === "string" && path.length > 1)),
  ];

  function visit(directory) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const fullPath = join(directory, entry.name);
      const relPath = relative(appPath, fullPath);

      if (entry.isSymbolicLink()) {
        offenders.push(`${relPath}: symlink in bundle (not allowed)`);
        continue;
      }
      if (entry.isDirectory()) {
        visit(fullPath);
        continue;
      }

      for (const { pattern, description } of BUNDLE_FORBIDDEN_NAME_PATTERNS) {
        if (pattern.test(relPath)) {
          offenders.push(`${relPath}: forbidden bundle entry (${description})`);
        }
      }

      const content = readFileSync(fullPath).toString("latin1");
      for (const { pattern, description } of BUNDLE_FORBIDDEN_CONTENT_PATTERNS) {
        if (pattern.test(content)) {
          offenders.push(`${relPath}: contains ${description}`);
        }
      }
      const home = homedir();
      if (home && home !== "/" && content.includes(home)) {
        offenders.push(`${relPath}: contains the current account's home directory path`);
      }
      for (const buildPath of uniqueBuildPaths) {
        if (content.includes(buildPath)) {
          offenders.push(`${relPath}: contains absolute build provenance path ${JSON.stringify(buildPath)}`);
        }
      }

      regularFiles.push(relPath);
    }
  }

  visit(appPath);
  return { offenders, regularFiles };
}

/**
 * Runs `/usr/bin/file` on every regular bundle file and returns every one
 * `file` reports as Mach-O, as `{ relPath, absolutePath, output }` records.
 */
export function classifyMachOFiles(appPath, regularFiles) {
  const machOFiles = [];
  for (const relPath of regularFiles) {
    const absolutePath = join(appPath, relPath);
    const output = execFileSync("/usr/bin/file", ["-b", absolutePath], { encoding: "utf8" });
    if (/Mach-O/.test(output)) {
      machOFiles.push({ relPath, absolutePath, output: output.trim() });
    }
  }
  return machOFiles;
}

/**
 * Asserts the bundle contains exactly one Mach-O file and that it is at
 * `expectedExecutableRelPath`. Returns offenders (empty when the single
 * Mach-O check passes) and, on success, the matching classification entry
 * so the caller can chain the architecture/otool checks without
 * reclassifying.
 */
export function checkExactlyOneMachO(machOFiles, expectedExecutableRelPath) {
  if (machOFiles.length !== 1) {
    const found = machOFiles.map((entry) => entry.relPath).join(", ") || "none";
    return {
      offenders: [
        `expected exactly one Mach-O file in the bundle, at ${expectedExecutableRelPath}; found ${machOFiles.length}: ${found}`,
      ],
      entry: null,
    };
  }
  const [entry] = machOFiles;
  if (entry.relPath !== expectedExecutableRelPath) {
    return {
      offenders: [`expected the bundle's one Mach-O file at ${expectedExecutableRelPath}, found it at ${entry.relPath} instead`],
      entry: null,
    };
  }
  return { offenders: [], entry };
}

/** Requires both an arm64 executable classification and exact `lipo -archs` output `arm64`. */
export function checkArchitecture(machOEntry, { lipoOutput } = {}) {
  const architectures =
    lipoOutput ??
    execFileSync("/usr/bin/lipo", ["-archs", machOEntry.absolutePath], {
      encoding: "utf8",
    });
  if (architectures.trim() !== "arm64") {
    return [
      `${machOEntry.relPath}: expected lipo -archs output to be exactly "arm64", got ${JSON.stringify(architectures.trim())}`,
    ];
  }
  if (!/Mach-O 64-bit executable arm64\b/.test(machOEntry.output)) {
    return [`${machOEntry.relPath}: expected "Mach-O 64-bit executable arm64", got "${machOEntry.output}"`];
  }
  return [];
}

/**
 * Dependency path prefixes that must never appear in `otool -L` output
 * regardless of the absolute-path allowlist below: `@rpath`/`@loader_path`/
 * `@executable_path` are all resolved relative to the *loading* binary (or
 * an `LC_RPATH` search list baked into it), so any of them can point to an
 * arbitrary embedded/co-located file chosen entirely by whoever built the
 * dependency graph — never a fixed, inspectable system path.
 */
const FORBIDDEN_DEPENDENCY_LOADER_PREFIXES = ["@rpath", "@loader_path", "@executable_path"];

/** Absolute directory roots a dependency's *lexically standardized* path may live under (trailing slash required — see `isAllowedDependencyPath`). */
const ALLOWED_DEPENDENCY_ROOTS = ["/usr/lib/", "/System/Library/"];

/**
 * Returns whether `depPath` (an absolute filesystem path from `otool -L`,
 * already confirmed not to start with a forbidden `@`-relative loader
 * token) is an exact descendant of `/usr/lib/` or `/System/Library/` after
 * *lexical* standardization — never a mere string-prefix check, which
 * would also incorrectly admit a sibling directory that simply shares the
 * same prefix text (`/usr/libevil/...`, `/System/Libraryevil/...`) or a
 * traversal form that only lexically escapes the allowed root
 * (`/usr/lib/../../etc/evil`).
 *
 * A path is rejected outright — before any normalization — if it is not
 * absolute, or if it contains a literal `.` or `..` segment; only a path
 * that was already in fully standardized form (no `.`/`..`, no repeated
 * slashes — `path.posix.normalize` is a no-op on it) can ever be allowed,
 * so a caller-controlled dependency string can never rely on lexical
 * collapsing tricks to reach outside the allowlisted roots.
 */
export function isAllowedDependencyPath(depPath) {
  if (!depPath.startsWith("/")) {
    return false;
  }
  const segments = depPath.split("/");
  if (segments.includes("..") || segments.includes(".")) {
    return false;
  }
  if (posixNormalize(depPath) !== depPath) {
    return false;
  }
  return ALLOWED_DEPENDENCY_ROOTS.some((root) => depPath.startsWith(root));
}

/**
 * Parses raw `otool -L <path>` output (the first line is always the
 * queried path itself, echoed back; every following line is a genuine
 * dependency — unlike a dylib, an ordinary Mach-O executable has no
 * separate "self" install-name line to skip) and asserts every dependency
 * is an exact, lexically-standardized descendant of `/System/Library/` or
 * `/usr/lib/` (see `isAllowedDependencyPath`), with no `@rpath`/
 * `@loader_path`/`@executable_path`-relative embedded reference. Kept
 * independent of the `otool` subprocess call itself so it can be exercised
 * directly against captured/synthetic `otool -L` text (e.g. by tests
 * simulating an embedded runtime dependency, a `/usr/libevil` sibling
 * directory, or a `..` traversal attempt) without needing a real, fully
 * linked Mach-O binary on disk.
 */
export function parseOtoolDependencies(output) {
  const lines = output
    .split("\n")
    .slice(1)
    .map((line) => line.trim())
    .filter(Boolean);

  const offenders = [];
  for (const line of lines) {
    const match = line.match(/^(.*?)\s+\(compatibility version/);
    const depPath = match ? match[1] : line;

    const forbiddenLoaderPrefix = FORBIDDEN_DEPENDENCY_LOADER_PREFIXES.find((prefix) => depPath.startsWith(prefix));
    if (forbiddenLoaderPrefix) {
      offenders.push(`otool -L: embedded ${forbiddenLoaderPrefix} dependency not allowed: ${depPath}`);
      continue;
    }
    if (!isAllowedDependencyPath(depPath)) {
      offenders.push(`otool -L: dependency outside /System/Library and /usr/lib: ${depPath}`);
    }
  }
  return offenders;
}

/**
 * Runs `/usr/bin/otool -L` on the bundle's one executable and delegates
 * to `parseOtoolDependencies` — a structural check that rejects *any*
 * embedded runtime dependency regardless of what it's named, not only
 * dependencies that still say "Glaze" or "node".
 */
export function checkOtoolDependencies(executableAbsPath) {
  const output = execFileSync("/usr/bin/otool", ["-L", executableAbsPath], { encoding: "utf8" });
  return parseOtoolDependencies(output);
}

/**
 * Full bundle scan: symlinks/forbidden names/forbidden content (via
 * `walkBundle`), then the structural Mach-O/otool checks. Returns every
 * offender found; an empty array means the bundle boundary is clean.
 *
 * `appPath` itself is `lstat`'d first — if it is a symlink, this returns
 * immediately without ever calling `readdirSync`/`file`/`otool` through it
 * (which would otherwise transparently follow it to wherever it points,
 * including outside the repository).
 */
export function scanBundle(
  appPath,
  {
    expectedExecutableRelPath = EXPECTED_EXECUTABLE_RELATIVE_PATH,
    forbiddenAbsolutePaths = [],
  } = {},
) {
  const rootOffender = findBundleSymlinkOffender(appPath);
  if (rootOffender) {
    return [rootOffender];
  }

  const { offenders, regularFiles } = walkBundle(appPath, { forbiddenAbsolutePaths });

  const machOFiles = classifyMachOFiles(appPath, regularFiles);
  const { offenders: machOOffenders, entry } = checkExactlyOneMachO(machOFiles, expectedExecutableRelPath);
  offenders.push(...machOOffenders);

  if (entry) {
    offenders.push(...checkArchitecture(entry));
    offenders.push(...checkOtoolDependencies(join(appPath, expectedExecutableRelPath)));
  }

  return offenders;
}

/**
 * Validates `Contents/Info.plist` via `plutil -convert json` (Xcode's
 * "Process Info.plist" build phase has already substituted every
 * `$(BUILD_SETTING)` token in the source `Config/Info.plist` by the time
 * this reads the built bundle).
 *
 * `appPath`, `appPath/Contents`, and `appPath/Contents/Info.plist` are
 * each `lstat`'d first via `findBundleSymlinkOffender` — this function is
 * called independently of `scanBundle`/`walkBundle` (directly by `main()`
 * and by tests), so it cannot rely on `walkBundle`'s recursive
 * `Dirent`-based symlink checks; without its own check here, a symlinked
 * bundle root, `Contents` directory, or `Info.plist` file would be
 * transparently followed by `plutil` itself.
 */
export function checkInfoPlist(appPath) {
  const symlinkOffender = findBundleSymlinkOffender(appPath, "Contents/Info.plist");
  if (symlinkOffender) {
    return [symlinkOffender];
  }

  const plistPath = join(appPath, "Contents", "Info.plist");
  const json = execFileSync("/usr/bin/plutil", ["-convert", "json", "-o", "-", plistPath], { encoding: "utf8" });
  const plist = JSON.parse(json);

  const expectations = {
    CFBundleIdentifier: "ai.opencoven.seer",
    CFBundleExecutable: "Seer",
    CFBundleDisplayName: "Seer",
    LSMinimumSystemVersion: "14.0",
    LSUIElement: true,
  };

  const offenders = [];
  for (const [key, expected] of Object.entries(expectations)) {
    if (plist[key] !== expected) {
      offenders.push(`Info.plist ${key} is ${JSON.stringify(plist[key])}, expected ${JSON.stringify(expected)}`);
    }
  }
  return offenders;
}

/**
 * Validates the app has no App Sandbox entitlement, covering both the
 * unsigned local build (`npm run build:macos`'s `CODE_SIGNING_ALLOWED=NO`
 * output — Apple Silicon still requires the linker to attach an ad-hoc
 * signature for the binary to run at all, so `codesign -d` succeeds
 * against it, just with no entitlements blob at all: `Signature=adhoc`,
 * `Sealed Resources=none`) and a fully signed release build (where a real
 * entitlements blob is embedded), without ever silently passing on an
 * unrecognized `codesign` failure:
 *
 * - `codesign -d --entitlements - --xml` exiting zero with **no**
 *   `<plist>` in its output means the code object was inspected
 *   successfully and genuinely carries no entitlements — the expected,
 *   valid state for this project's unsigned ad-hoc-linker-signed build,
 *   and trivially satisfies "no App Sandbox entitlement" since there is no
 *   entitlement of any kind.
 * - Exiting zero **with** a `<plist>` means real entitlements are present;
 *   that effective plist is checked directly for the App Sandbox key.
 * - A nonzero exit (the bundle's code signature is missing/corrupt in a
 *   way `codesign` itself refuses to inspect, a wrong path, `codesign`
 *   itself unavailable, etc.) is always treated as an offender — never
 *   silently downgraded to "must be fine" — so this can never produce a
 *   false pass just because a code-signing failure looks superficially
 *   similar to the valid "signed, no entitlements" case above.
 *
 * The *source* `Config/Seer.entitlements` file is independently checked
 * regardless of the effective-entitlements outcome, so a real App Sandbox
 * entry making it into the file the build reads is still caught even if
 * this effective check were ever fooled by some other bundle format.
 */
export function checkEntitlements(appPath, { sourceEntitlementsPath } = {}) {
  const offenders = [];
  const rootOffender = findBundleSymlinkOffender(appPath);
  if (rootOffender) {
    offenders.push(rootOffender);
  } else {
    let stdout = "";
    let stderr = "";
    let failed = false;
    try {
      stdout = execFileSync("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", appPath], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      failed = true;
      stdout = String(error.stdout ?? "");
      stderr = String(error.stderr ?? "");
    }

    if (failed) {
      offenders.push(`unable to inspect effective entitlements via codesign: ${stderr.trim() || "unknown error"}`);
    } else if (/<plist/.test(stdout) && /com\.apple\.security\.app-sandbox/.test(stdout)) {
      offenders.push("effective (codesign) entitlements declare com.apple.security.app-sandbox");
    }
    // else: codesign succeeded with no entitlements plist at all — valid,
    // sandbox-free state for an unsigned ad-hoc-linker-signed build.
  }

  if (sourceEntitlementsPath) {
    const source = readFileSync(sourceEntitlementsPath, "utf8");
    if (/com\.apple\.security\.app-sandbox/.test(source)) {
      offenders.push(`source entitlements file ${sourceEntitlementsPath} declares com.apple.security.app-sandbox`);
    }
  }

  return offenders;
}

/**
 * Loads the canonical repo and effective DerivedData paths recorded by the
 * publisher. The file is outside Seer.app and is opened with O_NOFOLLOW;
 * its lstat/open identities must match so a symlink or leaf swap cannot
 * redirect the scanner.
 */
export function loadBuildProvenance(provenancePath = DEFAULT_PROVENANCE_PATH) {
  const before = lstatSync(provenancePath);
  if (before.isSymbolicLink() || !before.isFile()) {
    throw new Error(`build provenance must be a regular non-symlink file: ${provenancePath}`);
  }

  const descriptor = openSync(provenancePath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  let source;
  try {
    const after = fstatSync(descriptor);
    if (!after.isFile() || before.dev !== after.dev || before.ino !== after.ino) {
      throw new Error(`build provenance changed identity while being opened: ${provenancePath}`);
    }
    source = readFileSync(descriptor, "utf8");
  } finally {
    closeSync(descriptor);
  }

  const provenance = JSON.parse(source);
  if (provenance.schemaVersion !== 1) {
    throw new Error(`unsupported build provenance schemaVersion ${JSON.stringify(provenance.schemaVersion)}`);
  }
  const paths = [provenance.canonicalRepoRoot, provenance.effectiveDerivedDataPath];
  for (const path of paths) {
    if (typeof path !== "string" || !isAbsolute(path) || path === "/") {
      throw new Error(`invalid absolute path in build provenance: ${JSON.stringify(path)}`);
    }
  }
  return [...new Set(paths)];
}

function main() {
  const appPath = process.argv[2] ?? process.env.SEER_APP_PATH ?? DEFAULT_APP_PATH;
  const sourceEntitlementsPath = join(REPO_ROOT, "apps", "macos", "Seer", "Config", "Seer.entitlements");
  const provenancePath = process.env.SEER_BUILD_PROVENANCE_PATH ?? DEFAULT_PROVENANCE_PATH;

  const offenders = [...scanSourceBoundary(REPO_ROOT)];

  if (!lstatOrNull(appPath)) {
    console.error(`error: app bundle not found at ${appPath} (run \`npm run build:macos\` first)`);
    process.exitCode = 1;
    return;
  }

  let forbiddenAbsolutePaths = [];
  try {
    forbiddenAbsolutePaths = loadBuildProvenance(provenancePath);
  } catch (error) {
    offenders.push(`unable to load private build provenance from ${provenancePath}: ${error.message}`);
  }

  offenders.push(...scanBundle(appPath, { forbiddenAbsolutePaths }));
  offenders.push(...checkInfoPlist(appPath));
  offenders.push(...checkEntitlements(appPath, { sourceEntitlementsPath }));

  if (offenders.length > 0) {
    console.error(`standalone boundary check failed with ${offenders.length} offender(s):`);
    for (const offender of offenders) {
      console.error(`  - ${offender}`);
    }
    process.exitCode = 1;
    return;
  }

  console.log(`standalone boundary check passed for ${appPath}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main();
}
