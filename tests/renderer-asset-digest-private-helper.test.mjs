// Tests for the no-shared-canonical private-run-directory design that
// replaced the lock-free "stage then publish to a canonical path" design
// (rejected for validation/publication/execution TOCTOU and ambient-
// permission flaws - see git history). There is no longer any canonical
// helper path, publish step, or "winner"/"loser" concept to test at all:
// every single call compiles its own private Swift helper into its own
// fresh, unique, unpredictable, mode-0700 work directory and removes only
// that directory again before returning - so these tests instead cover
// each safety property that design now rests on: the shared private runs
// root and every per-call run directory are real/non-symlink/current-uid-
// owned/mode-exactly-0700 (failing closed on anything preexisting and
// unsafe, never repairing it); the compiled helper file is regular/non-
// symlink/current-uid-owned/non-empty/owner-executable/never group-or-
// world-writable, revalidated by descriptor identity both before and
// immediately after the spawn that trusts it; cleanup only ever removes
// the exact run directory a call itself created, never anything an
// identity check cannot still positively confirm; and none of a compiler
// failure, an abandoned leftover run directory, or many truly concurrent
// invocations can ever block, wedge, or interfere with any other,
// independent call.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  chmodSync,
  closeSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  compilePrivateRendererAssetDigestHelper,
  computeRendererAssetDigest,
  createPrivateRendererAssetDigestRunDir,
  ensurePrivateDirectory,
  openValidatedPrivateRendererAssetDigestHelperFile,
  privateDirectoryRejectionReason,
  removePrivateRendererAssetDigestRunDirIfSafe,
  rendererAssetDigestHelperFileRejectionReason,
  rendererAssetDigestPrivateRunsRoot,
  spawnValidatedPrivateRendererAssetDigestHelperFile,
  verifyPrivateDirectoryOrThrow,
  withPrivateRendererAssetDigestHelper,
} from "../scripts/renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const runDirWorkerPath = join(here, "helpers", "renderer-asset-digest-run-dir-worker.mjs");
const fullPipelineWorkerPath = join(here, "helpers", "renderer-asset-digest-full-pipeline-worker.mjs");
const swiftHelperSource = join(repoRoot, "scripts", "renderer-asset-digest.swift");
const rendererFixtureRoot = join(repoRoot, "renderer");

/**
 * A disposable scratch directory under `build/` (already gitignored, and
 * the same convention the rest of this repo's tests use for their own
 * fixture copies) so these tests never touch the real repository tree, and
 * always clean up after themselves, pass or fail. Deliberately independent
 * of the real, shared `rendererAssetDigestPrivateRunsRoot` used by actual
 * production calls (including from other, possibly concurrently running
 * test files) - every test below passes its own scratch directory as the
 * `root`/parent argument instead, except the handful that specifically
 * mean to exercise the real production root by name (see the "abandoned
 * run directory" tests), which clean up precisely after themselves too.
 */
function withScratchDir(run) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-asset-digest-private-helper-"));
  try {
    return run(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

function writeExecutableFile(path, content, mode = 0o500) {
  writeFileSync(path, content);
  chmodSync(path, mode);
}

/** A tiny, fast-to-run, real owner-executable shell script (never a real Swift compile). */
function writeTrivialScript(path, mode = 0o500) {
  writeExecutableFile(path, "#!/bin/sh\necho private-helper-script-ok\n", mode);
}

function runChildAndCollect(childPath, args) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(process.execPath, [childPath, ...args], {
      cwd: repoRoot,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => resolvePromise({ code, stdout, stderr }));
  });
}

/**
 * A minimal `fs.Stats`-shaped stand-in for
 * {@link privateDirectoryRejectionReason}'s unit tests. Defaults describe a
 * plausible, accepted private directory; each test overrides exactly the
 * one property it means to violate.
 */
function fakeDirectoryStats(overrides = {}) {
  return {
    isDirectory: () => true,
    uid: process.getuid(),
    mode: 0o700,
    ...overrides,
  };
}

/**
 * A minimal `fs.Stats`-shaped stand-in for
 * {@link rendererAssetDigestHelperFileRejectionReason}'s unit tests.
 * Defaults describe a plausible, accepted compiled helper file (matching
 * exactly the 0500 mode production compiles to); each test overrides
 * exactly the one property it means to violate.
 */
function fakeFileStats(overrides = {}) {
  return {
    isFile: () => true,
    uid: process.getuid(),
    mode: 0o500,
    size: 42,
    ...overrides,
  };
}

// --- privateDirectoryRejectionReason: pure predicate ---
//
// "Owned by a different user" is tested here, against a fabricated Stats
// object, rather than against a real on-disk directory: actually creating
// one owned by a different uid would require root/multi-user privileges no
// test environment can assume.

test("privateDirectoryRejectionReason accepts a plausible owned, mode-0700 directory", () => {
  assert.equal(privateDirectoryRejectionReason(fakeDirectoryStats()), null);
});

test("privateDirectoryRejectionReason rejects a non-directory", () => {
  assert.equal(
    privateDirectoryRejectionReason(fakeDirectoryStats({ isDirectory: () => false })),
    "must be a real directory",
  );
});

test("privateDirectoryRejectionReason rejects a directory owned by a different user", () => {
  assert.equal(
    privateDirectoryRejectionReason(fakeDirectoryStats({ uid: process.getuid() + 1 })),
    "is not owned by the current user",
  );
});

test("privateDirectoryRejectionReason rejects a directory readable/traversable by its group", () => {
  assert.equal(
    privateDirectoryRejectionReason(fakeDirectoryStats({ mode: 0o750 })),
    "must be mode 0700, rejecting any group/world access",
  );
});

test("privateDirectoryRejectionReason rejects a directory more restrictive than 0700, not just anything at-or-under it", () => {
  assert.equal(
    privateDirectoryRejectionReason(fakeDirectoryStats({ mode: 0o500 })),
    "must be mode 0700, rejecting any group/world access",
  );
});

// --- verifyPrivateDirectoryOrThrow: on-disk fixtures ---

test("verifyPrivateDirectoryOrThrow accepts a real, owned, mode-0700 directory", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "private");
    mkdirSync(target, { mode: 0o700 });
    chmodSync(target, 0o700);

    const stats = verifyPrivateDirectoryOrThrow(target, "test private directory");
    assert.ok(stats);
    assert.equal(stats.isDirectory(), true);
  });
});

test("verifyPrivateDirectoryOrThrow throws (never returns null) when nothing exists at the path", () => {
  withScratchDir((scratch) => {
    assert.throws(
      () => verifyPrivateDirectoryOrThrow(join(scratch, "nope"), "test private directory"),
      (error) => error.code === "ENOENT",
    );
  });
});

test("verifyPrivateDirectoryOrThrow rejects a preexisting symlink without following or deleting it", () => {
  withScratchDir((scratch) => {
    const elsewhere = join(scratch, "elsewhere");
    mkdirSync(elsewhere, { mode: 0o700 });
    chmodSync(elsewhere, 0o700);
    const target = join(scratch, "private");
    symlinkSync(elsewhere, target);

    assert.throws(
      () => verifyPrivateDirectoryOrThrow(target, "test private directory"),
      /test private directory must not be a symlink/,
    );

    assert.equal(lstatSync(target).isSymbolicLink(), true);
    assert.equal(existsSync(elsewhere), true);
  });
});

test("verifyPrivateDirectoryOrThrow rejects a preexisting non-directory (a regular file) without modifying it", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "private");
    writeFileSync(target, "not a directory");

    assert.throws(
      () => verifyPrivateDirectoryOrThrow(target, "test private directory"),
      /test private directory must be a real directory/,
    );

    assert.equal(readFileSync(target, "utf8"), "not a directory");
  });
});

test("verifyPrivateDirectoryOrThrow rejects a preexisting directory with group/world access without repairing its mode", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "private");
    mkdirSync(target, { mode: 0o755 });
    chmodSync(target, 0o755);

    assert.throws(
      () => verifyPrivateDirectoryOrThrow(target, "test private directory"),
      /test private directory must be mode 0700, rejecting any group\/world access/,
    );

    assert.equal(lstatSync(target).mode & 0o777, 0o755);
  });
});

// --- ensurePrivateDirectory: create-or-verify, fail closed on unsafe reuse ---

test("ensurePrivateDirectory creates a fresh mode-0700 directory when nothing exists yet", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "fresh");
    ensurePrivateDirectory(target, "test private directory");

    const stats = lstatSync(target);
    assert.equal(stats.isDirectory(), true);
    assert.equal(stats.mode & 0o777, 0o700);
  });
});

test("ensurePrivateDirectory normalizes a freshly created directory's mode even under a pathological ambient umask", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "fresh-under-bad-umask");
    const previousUmask = process.umask(0o777);
    try {
      ensurePrivateDirectory(target, "test private directory");
    } finally {
      process.umask(previousUmask);
    }
    assert.equal(lstatSync(target).mode & 0o777, 0o700);
  });
});

test("ensurePrivateDirectory reuses (never recreates) an existing valid mode-0700 directory", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "existing");
    ensurePrivateDirectory(target, "test private directory");
    const before = lstatSync(target);

    ensurePrivateDirectory(target, "test private directory");
    const after = lstatSync(target);

    assert.equal(after.ino, before.ino);
    assert.equal(after.birthtimeMs, before.birthtimeMs);
  });
});

test("ensurePrivateDirectory fails closed on a preexisting symlinked parent instead of following or replacing it", () => {
  withScratchDir((scratch) => {
    const elsewhere = join(scratch, "elsewhere");
    mkdirSync(elsewhere, { mode: 0o700 });
    chmodSync(elsewhere, 0o700);
    const target = join(scratch, "private");
    symlinkSync(elsewhere, target);

    assert.throws(
      () => ensurePrivateDirectory(target, "test private directory"),
      /test private directory must not be a symlink/,
    );

    assert.equal(lstatSync(target).isSymbolicLink(), true);
  });
});

test("ensurePrivateDirectory fails closed on a preexisting wrong-mode parent instead of chmod-repairing it", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "private");
    mkdirSync(target, { mode: 0o755 });
    chmodSync(target, 0o755);

    assert.throws(
      () => ensurePrivateDirectory(target, "test private directory"),
      /test private directory must be mode 0700/,
    );

    assert.equal(lstatSync(target).mode & 0o777, 0o755);
  });
});

// --- createPrivateRendererAssetDigestRunDir: uniqueness ---

test("createPrivateRendererAssetDigestRunDir produces a distinct, independently valid directory on every call", () => {
  withScratchDir((scratch) => {
    const root = join(scratch, "runs-root");
    ensurePrivateDirectory(root, "test private runs root");

    const first = createPrivateRendererAssetDigestRunDir(root);
    const second = createPrivateRendererAssetDigestRunDir(root);

    assert.notEqual(first.path, second.path);
    assert.equal(dirname(first.path), root);
    assert.equal(dirname(second.path), root);
    assert.equal(lstatSync(first.path).mode & 0o777, 0o700);
    assert.equal(lstatSync(second.path).mode & 0o777, 0o700);
  });
});

// --- rendererAssetDigestHelperFileRejectionReason: pure predicate ---
//
// "Owned by a different user" is tested here, against a fabricated Stats
// object, rather than against a real on-disk file: actually creating a
// file owned by a different uid would require root/multi-user privileges
// no test environment can assume.

test("rendererAssetDigestHelperFileRejectionReason accepts a plausible owned, owner-executable, non-empty, non-group/world-writable file", () => {
  assert.equal(rendererAssetDigestHelperFileRejectionReason(fakeFileStats()), null);
});

test("rendererAssetDigestHelperFileRejectionReason rejects a non-regular file", () => {
  assert.equal(
    rendererAssetDigestHelperFileRejectionReason(fakeFileStats({ isFile: () => false })),
    "must be a regular file",
  );
});

test("rendererAssetDigestHelperFileRejectionReason rejects a file owned by a different user", () => {
  assert.equal(
    rendererAssetDigestHelperFileRejectionReason(fakeFileStats({ uid: process.getuid() + 1 })),
    "is not owned by the current user",
  );
});

test("rendererAssetDigestHelperFileRejectionReason rejects a non-owner-executable file", () => {
  assert.equal(
    rendererAssetDigestHelperFileRejectionReason(fakeFileStats({ mode: 0o400 })),
    "is not executable by its owner",
  );
});

test("rendererAssetDigestHelperFileRejectionReason rejects a group-writable file", () => {
  assert.equal(
    rendererAssetDigestHelperFileRejectionReason(fakeFileStats({ mode: 0o500 | 0o020 })),
    "is writable by a group or other user",
  );
});

test("rendererAssetDigestHelperFileRejectionReason rejects a world-writable file", () => {
  assert.equal(
    rendererAssetDigestHelperFileRejectionReason(fakeFileStats({ mode: 0o500 | 0o002 })),
    "is writable by a group or other user",
  );
});

test("rendererAssetDigestHelperFileRejectionReason rejects an empty file", () => {
  assert.equal(rendererAssetDigestHelperFileRejectionReason(fakeFileStats({ size: 0 })), "is empty");
});

// --- openValidatedPrivateRendererAssetDigestHelperFile: on-disk fixtures ---

test("openValidatedPrivateRendererAssetDigestHelperFile accepts a plausible regular, owned, mode-0500 file", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "helper");
    writeExecutableFile(target, "plausible");

    const opened = openValidatedPrivateRendererAssetDigestHelperFile(target, "test helper file");
    try {
      assert.ok(opened.fd >= 0);
      assert.equal(opened.stats.isFile(), true);
    } finally {
      closeSync(opened.fd);
    }
  });
});

test("openValidatedPrivateRendererAssetDigestHelperFile rejects a preexisting symlink without following or deleting it", () => {
  withScratchDir((scratch) => {
    const elsewhere = join(scratch, "elsewhere");
    writeExecutableFile(elsewhere, "elsewhere");
    const target = join(scratch, "helper");
    symlinkSync(elsewhere, target);

    assert.throws(
      () => openValidatedPrivateRendererAssetDigestHelperFile(target, "test helper file"),
      /test helper file must not be a symlink/,
    );

    assert.equal(lstatSync(target).isSymbolicLink(), true);
    assert.equal(existsSync(elsewhere), true);
  });
});

test("openValidatedPrivateRendererAssetDigestHelperFile rejects a preexisting non-regular entry (a directory)", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "helper");
    mkdirSync(target);

    assert.throws(
      () => openValidatedPrivateRendererAssetDigestHelperFile(target, "test helper file"),
      /test helper file must be a regular file/,
    );

    assert.equal(lstatSync(target).isDirectory(), true);
  });
});

test("openValidatedPrivateRendererAssetDigestHelperFile rejects a preexisting non-executable regular file", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "helper");
    writeFileSync(target, "not executable");
    chmodSync(target, 0o600);

    assert.throws(
      () => openValidatedPrivateRendererAssetDigestHelperFile(target, "test helper file"),
      /test helper file is not executable by its owner/,
    );

    assert.equal(readFileSync(target, "utf8"), "not executable");
  });
});

test("openValidatedPrivateRendererAssetDigestHelperFile rejects a preexisting group-writable file", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "helper");
    writeExecutableFile(target, "group writable", 0o570);

    assert.throws(
      () => openValidatedPrivateRendererAssetDigestHelperFile(target, "test helper file"),
      /test helper file is writable by a group or other user/,
    );
  });
});

test("openValidatedPrivateRendererAssetDigestHelperFile rejects a preexisting empty file", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "helper");
    writeExecutableFile(target, "");

    assert.throws(
      () => openValidatedPrivateRendererAssetDigestHelperFile(target, "test helper file"),
      /test helper file is empty/,
    );
  });
});

// --- spawnValidatedPrivateRendererAssetDigestHelperFile: validate-then-spawn swap attempts ---
//
// These exercise the exact seam between validating the compiled helper and
// actually trusting `spawnSync`'s result against it - the only place a
// same-uid actor could ever attempt to swap the file the design is about
// to execute. No production "hook" mechanism is needed to test this: the
// two functions are already independently callable, so a test can simply
// validate, swap the file out from under the validated path/descriptor by
// hand, and then call the spawn step, asserting it is always caught.

test("spawnValidatedPrivateRendererAssetDigestHelperFile succeeds and returns the process result when nothing swaps the file between validation and spawn", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "helper");
    writeTrivialScript(target);

    const opened = openValidatedPrivateRendererAssetDigestHelperFile(target, "test helper file");
    try {
      const result = spawnValidatedPrivateRendererAssetDigestHelperFile(target, opened, "test helper file", [], {
        encoding: "utf8",
      });
      assert.equal(result.status, 0);
      assert.equal(result.stdout.trim(), "private-helper-script-ok");
    } finally {
      closeSync(opened.fd);
    }
  });
});

test("spawnValidatedPrivateRendererAssetDigestHelperFile throws when the file is replaced by a different file between validation and spawn", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "helper");
    writeTrivialScript(target);

    const opened = openValidatedPrivateRendererAssetDigestHelperFile(target, "test helper file");
    try {
      rmSync(target);
      writeTrivialScript(target); // a new file (new inode) at the exact same path.

      assert.throws(
        () =>
          spawnValidatedPrivateRendererAssetDigestHelperFile(target, opened, "test helper file", [], {
            encoding: "utf8",
          }),
        /test helper file changed identity between validation and spawn/,
      );
    } finally {
      closeSync(opened.fd);
    }
  });
});

test("spawnValidatedPrivateRendererAssetDigestHelperFile throws when the file is replaced by a symlink between validation and spawn", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "helper");
    writeTrivialScript(target);
    const elsewhere = join(scratch, "elsewhere");
    writeTrivialScript(elsewhere);

    const opened = openValidatedPrivateRendererAssetDigestHelperFile(target, "test helper file");
    try {
      rmSync(target);
      symlinkSync(elsewhere, target);

      assert.throws(
        () =>
          spawnValidatedPrivateRendererAssetDigestHelperFile(target, opened, "test helper file", [], {
            encoding: "utf8",
          }),
        /test helper file changed identity between validation and spawn/,
      );
    } finally {
      closeSync(opened.fd);
    }
  });
});

test("spawnValidatedPrivateRendererAssetDigestHelperFile throws when the file is mutated in place (made group-writable) between validation and spawn", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "helper");
    writeTrivialScript(target);

    const opened = openValidatedPrivateRendererAssetDigestHelperFile(target, "test helper file");
    try {
      chmodSync(target, 0o570); // same inode, same path - but now group-writable.

      assert.throws(
        () =>
          spawnValidatedPrivateRendererAssetDigestHelperFile(target, opened, "test helper file", [], {
            encoding: "utf8",
          }),
        /test helper file is writable by a group or other user immediately after spawn/,
      );
    } finally {
      closeSync(opened.fd);
    }
  });
});

// --- removePrivateRendererAssetDigestRunDirIfSafe: cleanup isolation ---

test("removePrivateRendererAssetDigestRunDirIfSafe removes exactly the target run directory, leaving an unrelated sibling and the shared root untouched", () => {
  withScratchDir((scratch) => {
    const root = join(scratch, "runs-root");
    ensurePrivateDirectory(root, "test private runs root");
    const target = createPrivateRendererAssetDigestRunDir(root);
    const sibling = createPrivateRendererAssetDigestRunDir(root);
    writeFileSync(join(sibling.path, "marker.txt"), "sibling content");

    removePrivateRendererAssetDigestRunDirIfSafe(target);

    assert.equal(existsSync(target.path), false);
    assert.equal(existsSync(root), true);
    assert.equal(readFileSync(join(sibling.path, "marker.txt"), "utf8"), "sibling content");
  });
});

test("removePrivateRendererAssetDigestRunDirIfSafe never recursively deletes a directory that has since been replaced at the same path", () => {
  withScratchDir((scratch) => {
    const root = join(scratch, "runs-root");
    ensurePrivateDirectory(root, "test private runs root");
    const original = createPrivateRendererAssetDigestRunDir(root);

    // Simulate the path having been swapped for a brand-new directory
    // (different inode) since `original.stats` was captured - the stale
    // captured identity must never be trusted for a recursive delete.
    rmSync(original.path, { recursive: true });
    mkdirSync(original.path, { mode: 0o700 });
    chmodSync(original.path, 0o700);
    writeFileSync(join(original.path, "marker.txt"), "replacement content");

    removePrivateRendererAssetDigestRunDirIfSafe(original);

    assert.equal(existsSync(original.path), true);
    assert.equal(readFileSync(join(original.path, "marker.txt"), "utf8"), "replacement content");
  });
});

test("removePrivateRendererAssetDigestRunDirIfSafe never throws when the target directory no longer exists at all", () => {
  withScratchDir((scratch) => {
    const root = join(scratch, "runs-root");
    ensurePrivateDirectory(root, "test private runs root");
    const target = createPrivateRendererAssetDigestRunDir(root);
    rmSync(target.path, { recursive: true });

    assert.doesNotThrow(() => removePrivateRendererAssetDigestRunDirIfSafe(target));
  });
});

// --- compilePrivateRendererAssetDigestHelper: compiler failure never blocks future calls ---

test("compilePrivateRendererAssetDigestHelper throws a clear error and leaves no helper file when the source does not exist, without blocking a later independent, real compile", () => {
  withScratchDir((scratch) => {
    const root = join(scratch, "runs-root");
    ensurePrivateDirectory(root, "test private runs root");

    const failedRunDir = createPrivateRendererAssetDigestRunDir(root);
    assert.throws(
      () => compilePrivateRendererAssetDigestHelper(join(scratch, "does-not-exist.swift"), failedRunDir.path),
      /unable to compile descriptor-anchored renderer asset digest helper/,
    );
    assert.deepEqual(readdirSync(failedRunDir.path), []);

    // A completely independent, later, real compile is unaffected by the
    // earlier failure - nothing about this design can wedge future calls.
    const recoveredRunDir = createPrivateRendererAssetDigestRunDir(root);
    const helperPath = compilePrivateRendererAssetDigestHelper(swiftHelperSource, recoveredRunDir.path);
    assert.equal(existsSync(helperPath), true);
    assert.equal(lstatSync(helperPath).mode & 0o777, 0o500);
  });
});

// --- withPrivateRendererAssetDigestHelper: full lifecycle, abandoned directories ---

test("withPrivateRendererAssetDigestHelper creates a run directory that exists only while run() executes, and forwards its return value", () => {
  let observedRunDir;
  const result = withPrivateRendererAssetDigestHelper((runDirPath) => {
    observedRunDir = runDirPath;
    assert.equal(existsSync(runDirPath), true);
    assert.equal(lstatSync(runDirPath).mode & 0o777, 0o700);
    return "run-result";
  });

  assert.equal(result, "run-result");
  assert.equal(existsSync(observedRunDir), false);
});

test("withPrivateRendererAssetDigestHelper still cleans up its own run directory when run() throws, and propagates the original error", () => {
  let observedRunDir;
  assert.throws(() => {
    withPrivateRendererAssetDigestHelper((runDirPath) => {
      observedRunDir = runDirPath;
      throw new Error("run failure sentinel");
    });
  }, /run failure sentinel/);

  assert.equal(existsSync(observedRunDir), false);
});

test("an abandoned run directory left by a previously crashed call is never touched by, and never blocks, a later independent call", () => {
  ensurePrivateDirectory(rendererAssetDigestPrivateRunsRoot, "renderer asset digest private runs root");
  const abandoned = createPrivateRendererAssetDigestRunDir(rendererAssetDigestPrivateRunsRoot);
  writeFileSync(join(abandoned.path, "marker.txt"), "abandoned content"); // "crashed" before ever cleaning up.

  try {
    const result = withPrivateRendererAssetDigestHelper(() => "ok");
    assert.equal(result, "ok");

    // Inert leftover this call never enumerated, waited on, or touched.
    assert.equal(existsSync(abandoned.path), true);
    assert.equal(readFileSync(join(abandoned.path, "marker.txt"), "utf8"), "abandoned content");
  } finally {
    rmSync(abandoned.path, { recursive: true, force: true }); // test hygiene only.
  }
});

// --- Real concurrent OS processes: the design's core claim, end to end ---

test("many concurrent invocations each create and clean up their own distinct run directory, with no interference between them", async () => {
  const workerCount = 24;
  const results = await Promise.all(
    Array.from({ length: workerCount }, () => runChildAndCollect(runDirWorkerPath, [])),
  );

  for (const result of results) {
    assert.equal(result.code, 0, result.stderr);
  }

  const runDirPaths = results.map((result) => result.stdout.trim());
  assert.equal(new Set(runDirPaths).size, workerCount, "every concurrent call must use a distinct run directory");

  // No leftover run directories of any kind: every participant's own
  // cleanup succeeded independently, with no cross-talk between them.
  assert.deepEqual(readdirSync(rendererAssetDigestPrivateRunsRoot), []);
});

test("several concurrent, real end-to-end computeRendererAssetDigest calls against the same renderer root all succeed and agree on the exact same digest", async () => {
  const workerCount = 4;
  const results = await Promise.all(
    Array.from({ length: workerCount }, () => runChildAndCollect(fullPipelineWorkerPath, [rendererFixtureRoot])),
  );

  for (const result of results) {
    assert.equal(result.code, 0, result.stderr);
  }

  const digests = results.map((result) => result.stdout.trim());
  const expectedDigest = computeRendererAssetDigest(rendererFixtureRoot);
  for (const digest of digests) {
    assert.match(digest, /^[0-9a-f]{64}$/);
    assert.equal(digest, expectedDigest);
  }

  // No leftover run directories from any of the concurrent real compiles.
  assert.deepEqual(readdirSync(rendererAssetDigestPrivateRunsRoot), []);
});
