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
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  readdirSync,
  unlinkSync,
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
  const lockPath = `${helperPath}.lock`;
  const deadline = Date.now() + 120_000;
  let lockDescriptor;
  while (lockDescriptor === undefined) {
    try {
      lockDescriptor = openSync(lockPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
      writeFileSync(lockDescriptor, `${process.pid}\n`, "utf8");
    } catch (error) {
      if (!error || error.code !== "EEXIST") throw error;
      try {
        const ownerPid = Number(readFileSync(lockPath, "utf8").trim());
        if (Number.isSafeInteger(ownerPid) && ownerPid > 0) {
          try {
            process.kill(ownerPid, 0);
          } catch (ownerError) {
            if (ownerError && ownerError.code === "ESRCH") {
              unlinkSync(lockPath);
              continue;
            }
          }
        }
      } catch (ownerError) {
        if (ownerError && ownerError.code === "ENOENT") continue;
        throw ownerError;
      }
      if (Date.now() >= deadline) {
        throw new Error("timed out waiting to compile descriptor-anchored renderer asset digest helper");
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    }
  }
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
    closeSync(lockDescriptor);
    unlinkSync(lockPath);
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
 * Lowercase SHA-256 over every emitted file except build-manifest.json.
 * Excluding the manifest avoids a self-referential digest while binding the
 * manifest to the complete immutable generation it accompanies.
 */
export function computeRendererAssetDigest(rendererRoot, { afterCollection } = {}) {
  const assets = readDescriptorAnchoredRendererAssets(rendererRoot, afterCollection);
  assets.sort((left, right) => left.relativePath.localeCompare(right.relativePath));
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
