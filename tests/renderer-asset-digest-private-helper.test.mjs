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
import { spawn, spawnSync } from "node:child_process";
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
  assertNoDarwinAclOrThrow,
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
  stripDarwinAclOrThrow,
  verifyPrivateDirectoryOrThrow,
  withPrivateRendererAssetDigestHelper,
} from "../scripts/renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const runDirWorkerPath = join(here, "helpers", "renderer-asset-digest-run-dir-worker.mjs");
const coldStartRootWorkerPath = join(here, "helpers", "renderer-asset-digest-cold-start-root-worker.mjs");
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

/** Sets `process.env[name]` to `value` for the duration of `run`, always restoring it afterward. */
function withEnv(name, value, run) {
  const previous = process.env[name];
  process.env[name] = value;
  try {
    return run();
  } finally {
    if (previous === undefined) delete process.env[name];
    else process.env[name] = previous;
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

/**
 * Directly shells out to `ls -lde` (the same mechanism
 * darwinAclEntryLines/assertNoDarwinAclOrThrow use internally) to count how
 * many macOS ACL entries currently exist on `path`, independent of the
 * module under test - so these tests can assert on ACL state without
 * depending on that module having already validated it.
 */
function aclEntryCount(path) {
  const result = spawnSync("/bin/ls", ["-lde", path], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.split("\n").filter((line) => line.length > 0).slice(1).length;
}

/** Applies a real macOS ACL entry directly to `path` (no inheritance involved). */
function applyDirectAcl(path) {
  const result = spawnSync("/bin/chmod", ["+a", "everyone allow read", path], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
}

/** Marks `path` so that fresh children created under it inherit an ACL entry automatically. */
function makeAclInheritable(path) {
  const result = spawnSync(
    "/bin/chmod",
    ["+a", "everyone allow read,file_inherit,directory_inherit", path],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);
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

// --- macOS ACLs: a permission layer entirely separate from POSIX mode bits ---

test("assertNoDarwinAclOrThrow accepts a real ACL-free directory and rejects the same directory once an ACL is added", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "clean");
    mkdirSync(target, { mode: 0o700 });
    assert.doesNotThrow(() => assertNoDarwinAclOrThrow(target, "test path"));

    applyDirectAcl(target);
    assert.throws(() => assertNoDarwinAclOrThrow(target, "test path"), /test path must not have a macOS ACL/);
  });
});

test("assertNoDarwinAclOrThrow fails closed with a clear error when the path does not exist", () => {
  withScratchDir((scratch) => {
    const missing = join(scratch, "does-not-exist");
    assert.throws(
      () => assertNoDarwinAclOrThrow(missing, "test path"),
      /unable to inspect test path for a macOS ACL/,
    );
  });
});

test("stripDarwinAclOrThrow removes a real ACL and is a safe no-op when none exists", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "target");
    mkdirSync(target, { mode: 0o700 });

    assert.doesNotThrow(() => stripDarwinAclOrThrow(target, "test path")); // no-op: nothing to strip yet.
    assert.equal(aclEntryCount(target), 0);

    applyDirectAcl(target);
    assert.equal(aclEntryCount(target), 1);
    stripDarwinAclOrThrow(target, "test path");
    assert.equal(aclEntryCount(target), 0);
  });
});

test("stripDarwinAclOrThrow fails closed with a clear error when the path does not exist", () => {
  withScratchDir((scratch) => {
    const missing = join(scratch, "does-not-exist");
    assert.throws(
      () => stripDarwinAclOrThrow(missing, "test path"),
      /unable to strip a macOS ACL from test path/,
    );
  });
});

test("ensurePrivateDirectory strips an ACL inherited from its parent off a freshly created directory", () => {
  withScratchDir((scratch) => {
    const inheritingParent = join(scratch, "acl-inheriting-parent");
    mkdirSync(inheritingParent, { mode: 0o700 });
    makeAclInheritable(inheritingParent);

    const target = join(inheritingParent, "private");
    ensurePrivateDirectory(target, "test private directory");

    assert.equal(lstatSync(target).mode & 0o777, 0o700);
    assert.equal(aclEntryCount(target), 0);
  });
});

test("ensurePrivateDirectory fails closed on (never silently strips) a preexisting, otherwise-valid directory that already has a macOS ACL", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "private");
    mkdirSync(target, { mode: 0o700 });
    chmodSync(target, 0o700);
    applyDirectAcl(target);

    assert.throws(
      () => ensurePrivateDirectory(target, "test private directory"),
      /test private directory must not have a macOS ACL/,
    );

    // Never auto-repaired: the ACL this call did not itself create is left exactly as found.
    assert.equal(aclEntryCount(target), 1);
  });
});

test("verifyPrivateDirectoryOrThrow rejects a directory with a macOS ACL without repairing it", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "private");
    mkdirSync(target, { mode: 0o700 });
    chmodSync(target, 0o700);
    applyDirectAcl(target);

    assert.throws(
      () => verifyPrivateDirectoryOrThrow(target, "test private directory"),
      /test private directory must not have a macOS ACL/,
    );
    assert.equal(aclEntryCount(target), 1);
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

test("openValidatedPrivateRendererAssetDigestHelperFile rejects a preexisting helper file that has a macOS ACL", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "helper");
    writeTrivialScript(target);
    applyDirectAcl(target);

    assert.throws(
      () => openValidatedPrivateRendererAssetDigestHelperFile(target, "test helper file"),
      /test helper file must not have a macOS ACL/,
    );
    assert.equal(aclEntryCount(target), 1); // never auto-repaired
  });
});

test("compilePrivateRendererAssetDigestHelper's freshly compiled helper file has no macOS ACL", () => {
  withScratchDir((scratch) => {
    const root = join(scratch, "runs-root");
    ensurePrivateDirectory(root, "test private runs root");
    const runDir = createPrivateRendererAssetDigestRunDir(root);

    const helperPath = compilePrivateRendererAssetDigestHelper(swiftHelperSource, runDir.path);

    assert.equal(aclEntryCount(helperPath), 0);
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
        /test helper file is writable by a group or other user after the spawned child process exited/,
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

test("compilePrivateRendererAssetDigestHelper throws a clear ETIMEDOUT-aware error and leaves no partial helper file when swiftc exceeds its configured timeout", () => {
  withScratchDir((scratch) => {
    const root = join(scratch, "runs-root");
    ensurePrivateDirectory(root, "test private runs root");
    const runDir = createPrivateRendererAssetDigestRunDir(root);

    withEnv("SEER_RENDERER_ASSET_DIGEST_COMPILE_TIMEOUT_MS", "1", () => {
      assert.throws(
        () => compilePrivateRendererAssetDigestHelper(swiftHelperSource, runDir.path),
        /descriptor-anchored renderer asset digest helper compilation did not finish within 1ms and was killed/,
      );
    });
    assert.deepEqual(readdirSync(runDir.path), []);

    // A completely independent, later, real (untimed) compile still works -
    // one call's timeout can never wedge or poison a later, unrelated one.
    const recoveredRunDir = createPrivateRendererAssetDigestRunDir(root);
    const helperPath = compilePrivateRendererAssetDigestHelper(swiftHelperSource, recoveredRunDir.path);
    assert.equal(existsSync(helperPath), true);
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

test("orphaned run directories of several different shapes coexist untouched alongside many real concurrent invocations", async () => {
  ensurePrivateDirectory(rendererAssetDigestPrivateRunsRoot, "renderer asset digest private runs root");

  // Three abandoned run directories, each shaped like a plausible different
  // way a prior call could have crashed mid-flight: completely empty (died
  // right after `mkdirSync`), holding a lone file (died mid-materialize),
  // and holding a nested subdirectory (died mid something stranger still).
  // None of this module's own logic ever enumerates, repairs, or requires
  // the shared root be otherwise empty, so all three must simply persist,
  // byte-for-byte, no matter how many unrelated real calls run around them.
  const emptyOrphan = createPrivateRendererAssetDigestRunDir(rendererAssetDigestPrivateRunsRoot);

  const fileOrphan = createPrivateRendererAssetDigestRunDir(rendererAssetDigestPrivateRunsRoot);
  writeFileSync(join(fileOrphan.path, "helper"), "orphaned helper bytes");

  const nestedOrphan = createPrivateRendererAssetDigestRunDir(rendererAssetDigestPrivateRunsRoot);
  const nestedDir = join(nestedOrphan.path, "nested");
  mkdirSync(nestedDir, { mode: 0o700 });
  writeFileSync(join(nestedDir, "leftover.txt"), "nested orphaned content");

  const orphans = [emptyOrphan, fileOrphan, nestedOrphan];

  try {
    const workerCount = 24;
    const results = await Promise.all(
      Array.from({ length: workerCount }, () => runChildAndCollect(runDirWorkerPath, [])),
    );

    for (const result of results) {
      assert.equal(result.code, 0, result.stderr);
    }
    const runDirPaths = results.map((result) => result.stdout.trim());
    assert.equal(new Set(runDirPaths).size, workerCount, "every concurrent call must use a distinct run directory");

    // None of the real invocations' run directories may collide with any
    // orphan's path, and every real invocation must still have cleaned up
    // its own directory afterward.
    const orphanPaths = new Set(orphans.map((orphan) => orphan.path));
    for (const runDirPath of runDirPaths) {
      assert.equal(orphanPaths.has(runDirPath), false, "a real run dir must never collide with an orphan's path");
      assert.equal(existsSync(runDirPath), false, `expected ${runDirPath} to have been cleaned up`);
    }

    // Every orphan survives completely unchanged - neither deleted nor
    // mistaken for a stale directory to repair or reclaim.
    assert.equal(existsSync(emptyOrphan.path), true);
    assert.deepEqual(readdirSync(emptyOrphan.path), []);

    assert.equal(existsSync(fileOrphan.path), true);
    assert.equal(readFileSync(join(fileOrphan.path, "helper"), "utf8"), "orphaned helper bytes");

    assert.equal(existsSync(nestedDir), true);
    assert.equal(readFileSync(join(nestedDir, "leftover.txt"), "utf8"), "nested orphaned content");
  } finally {
    for (const orphan of orphans) {
      rmSync(orphan.path, { recursive: true, force: true }); // test hygiene only.
    }
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

  // Every participant's own run directory must be gone again - regardless
  // of whatever *other* run directories (an unrelated abandoned leftover
  // from a different crashed call, or another independent test in this
  // same file) may still coexist under the shared root: this design never
  // requires, or even checks, that the shared root is otherwise empty.
  for (const runDirPath of runDirPaths) {
    assert.equal(existsSync(runDirPath), false, `expected ${runDirPath} to have been cleaned up: ${runDirPath}`);
  }
});

test("many concurrent invocations racing the very first creation of a private root that does not yet exist all succeed with distinct run directories", async () => {
  // Deliberately does NOT create the root ahead of time (unlike every other
  // test in this file, which always calls ensurePrivateDirectory once,
  // sequentially, before spawning anything): the entire point is to race
  // dozens of real, independent OS processes against the exact instant a
  // shared root is first brought into existence, which is exactly where an
  // check-then-mkdir implementation would intermittently throw EEXIST.
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratchParent = mkdtempSync(join(repoRoot, "build", "renderer-asset-digest-cold-start-"));
  const root = join(scratchParent, "never-yet-created-root");
  assert.equal(existsSync(root), false);

  try {
    const workerCount = 32;
    const results = await Promise.all(
      Array.from({ length: workerCount }, () => runChildAndCollect(coldStartRootWorkerPath, [root])),
    );

    for (const result of results) {
      assert.equal(result.code, 0, result.stderr);
    }

    const runDirPaths = results.map((result) => result.stdout.trim());
    assert.equal(new Set(runDirPaths).size, workerCount, "every concurrent call must use a distinct run directory");
    for (const runDirPath of runDirPaths) {
      assert.equal(existsSync(runDirPath), false, `expected ${runDirPath} to have been cleaned up: ${runDirPath}`);
    }

    // Exactly one directory ever actually won the cold-start race and now
    // exists; it must be a fully valid, ACL-free 0700 private root no
    // matter which of the 32 racing processes happened to create it.
    assert.equal(existsSync(root), true);
    assert.equal(lstatSync(root).isDirectory(), true);
    assert.equal(lstatSync(root).uid, process.getuid());
    assert.equal(lstatSync(root).mode & 0o777, 0o700);
    assert.equal(aclEntryCount(root), 0);
    assert.deepEqual(readdirSync(root), []); // every worker's own run dir was cleaned up.
  } finally {
    rmSync(scratchParent, { recursive: true, force: true });
  }
});

test("several concurrent, real end-to-end computeRendererAssetDigest calls against the same renderer root all succeed and agree on the exact same digest", async () => {
  ensurePrivateDirectory(rendererAssetDigestPrivateRunsRoot, "renderer asset digest private runs root");
  const before = new Set(readdirSync(rendererAssetDigestPrivateRunsRoot));

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

  // No *new* leftover run directories from any of these concurrent real
  // compiles (or from the direct computeRendererAssetDigest call just
  // above) - never a requirement that the shared root was, or is now,
  // otherwise completely empty: an unrelated abandoned directory from a
  // different crashed call, or from another independent test in this same
  // file, is a legitimate, harmless coexisting sibling this assertion must
  // tolerate rather than reject.
  const after = readdirSync(rendererAssetDigestPrivateRunsRoot);
  const newEntries = after.filter((entry) => !before.has(entry));
  assert.deepEqual(newEntries, []);
});

// --- Subprocess timeouts: the compiled helper itself, end to end ---

test("computeRendererAssetDigest throws a clear ETIMEDOUT-aware error and leaves no run directory behind when the compiled helper (and its afterCollection hook) exceeds its configured timeout", () => {
  ensurePrivateDirectory(rendererAssetDigestPrivateRunsRoot, "renderer asset digest private runs root");
  const before = new Set(readdirSync(rendererAssetDigestPrivateRunsRoot));

  withEnv("SEER_RENDERER_ASSET_DIGEST_HELPER_TIMEOUT_MS", "200", () => {
    const startedAt = Date.now();
    assert.throws(
      () =>
        computeRendererAssetDigest(rendererFixtureRoot, {
          afterCollection: { executable: "/bin/sleep", args: ["5"] },
        }),
      /descriptor-anchored renderer asset digest helper did not finish within 200ms and was killed/,
    );
    // Genuinely killed near the configured 200ms bound, not merely
    // eventually failing after the hook's full 5-second sleep completed:
    // proves the timeout actually terminates the child rather than just
    // being reported after the fact.
    assert.ok(Date.now() - startedAt < 4000, "expected the helper to be killed well before the 5s hook would finish");
  });

  // No leftover run directory from the killed attempt, and a completely
  // independent, later, untimed call still succeeds - one call's timeout
  // can never wedge or poison a later, unrelated one.
  const after = readdirSync(rendererAssetDigestPrivateRunsRoot);
  const newEntries = after.filter((entry) => !before.has(entry));
  assert.deepEqual(newEntries, []);

  const digest = computeRendererAssetDigest(rendererFixtureRoot);
  assert.match(digest, /^[0-9a-f]{64}$/);
});
