import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
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
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  acquireRendererAssetDigestHelperLock,
  reclaimAbandonedRendererAssetDigestHelperLockDirectory,
  readRendererAssetDigestHelperLockOwnerOrNull,
  releaseRendererAssetDigestHelperLock,
} from "../scripts/renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const workerPath = join(here, "helpers", "renderer-asset-digest-helper-lock-worker.mjs");

/**
 * A disposable scratch directory under `build/` (already gitignored, and
 * the same convention `tests/renderer-build-identity.test.mjs` uses for
 * its own fixture copies) so these tests never touch the real repository
 * tree and always clean up after themselves, pass or fail.
 */
function withScratchDir(run) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-asset-digest-helper-lock-"));
  try {
    return run(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

/** Async counterpart of {@link withScratchDir}: awaits `run` before cleanup. */
async function withAsyncScratchDir(run) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-asset-digest-helper-lock-"));
  try {
    return await run(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

/**
 * A pid guaranteed to be dead: `spawnSync` only returns after the child
 * has fully exited and been reaped, so by the time this returns, nothing
 * is running under `child.pid` (short of an adversarial, near-instant pid
 * reuse by the OS, which cannot happen within this synchronous call).
 */
function deadPid() {
  const child = spawnSync(process.execPath, ["-e", "process.exit(0)"]);
  assert.equal(child.status, 0, child.stderr?.toString());
  assert.ok(Number.isSafeInteger(child.pid) && child.pid > 0);
  return child.pid;
}

function writeOwnerFile(lockDir, pid) {
  writeFileSync(join(lockDir, "owner.json"), `${JSON.stringify({ pid })}\n`, { mode: 0o600 });
}

test("a lock directory abandoned mid-initialization (no owner.json, dead creator) past its grace period is reclaimed", () => {
  withScratchDir((scratch) => {
    const lockDir = join(scratch, "helper.lock");
    mkdirSync(lockDir); // simulates a crash between mkdirSync and the owner.json commit
    assert.equal(readdirSync(lockDir).length, 0);

    const lock = acquireRendererAssetDigestHelperLock(lockDir, { deadlineMs: 5_000, initGraceMs: 0 });
    assert.equal(lock.ownerInfo.pid, process.pid);
    assert.equal(existsSync(lockDir), true);

    releaseRendererAssetDigestHelperLock(lock);
    assert.equal(existsSync(lockDir), false);
  });
});

test("a lock directory still within its initialization grace period is never reclaimed and acquisition bounds its wait", () => {
  withScratchDir((scratch) => {
    const lockDir = join(scratch, "helper.lock");
    mkdirSync(lockDir); // freshly created "now" - well within any reasonable grace period

    assert.throws(
      () => acquireRendererAssetDigestHelperLock(lockDir, { deadlineMs: 100, initGraceMs: 60_000 }),
      /timed out waiting for renderer asset digest helper lock initialization/,
    );

    // Untouched: still exactly the empty, mid-initialization directory.
    assert.equal(existsSync(lockDir), true);
    assert.equal(readdirSync(lockDir).length, 0);
  });
});

test("a lock directory with a live owner is never reclaimed, even after its owner metadata could otherwise look stale", () => {
  withScratchDir((scratch) => {
    const lockDir = join(scratch, "helper.lock");
    mkdirSync(lockDir);
    writeOwnerFile(lockDir, process.pid); // this test process: unambiguously alive

    assert.throws(
      () => acquireRendererAssetDigestHelperLock(lockDir, { deadlineMs: 100, initGraceMs: 0 }),
      /timed out waiting for the live renderer asset digest helper lock owner/,
    );

    assert.equal(existsSync(lockDir), true);
    assert.deepEqual(JSON.parse(readFileSync(join(lockDir, "owner.json"), "utf8")), {
      pid: process.pid,
    });
  });
});

test("a lock directory abandoned by a dead owner (complete metadata) is reclaimed, allowing acquisition to proceed", () => {
  withScratchDir((scratch) => {
    const lockDir = join(scratch, "helper.lock");
    mkdirSync(lockDir);
    writeOwnerFile(lockDir, deadPid());

    const lock = acquireRendererAssetDigestHelperLock(lockDir, { deadlineMs: 5_000, initGraceMs: 0 });
    assert.equal(lock.ownerInfo.pid, process.pid);

    releaseRendererAssetDigestHelperLock(lock);
    assert.equal(existsSync(lockDir), false);
  });
});

test("two reclaimers racing over the same abandoned lock: exactly one reclaims, the other backs off without error", () => {
  withScratchDir((scratch) => {
    const lockDir = join(scratch, "helper.lock");
    mkdirSync(lockDir);
    writeOwnerFile(lockDir, deadPid());
    const expectedDirInfo = lstatSync(lockDir);
    const expectedOwnerInfo = readRendererAssetDigestHelperLockOwnerOrNull(lockDir);

    const first = reclaimAbandonedRendererAssetDigestHelperLockDirectory(
      lockDir,
      expectedDirInfo,
      expectedOwnerInfo,
    );
    assert.equal(first, "reclaimed");
    assert.equal(existsSync(lockDir), false);

    // A second reclaimer that captured the exact same "this looks
    // abandoned" snapshot before either of them acted - must never throw,
    // never resurrect anything, and must not claim to have reclaimed
    // something that is already gone.
    const second = reclaimAbandonedRendererAssetDigestHelperLockDirectory(
      lockDir,
      expectedDirInfo,
      expectedOwnerInfo,
    );
    assert.equal(second, "raced");
    assert.equal(existsSync(lockDir), false);
  });
});

test("a stale reclaimer never deletes a successor's freshly acquired lock at the same path", () => {
  withScratchDir((scratch) => {
    const lockDir = join(scratch, "helper.lock");
    mkdirSync(lockDir);
    writeOwnerFile(lockDir, deadPid());
    const staleDirInfo = lstatSync(lockDir);
    const staleOwnerInfo = readRendererAssetDigestHelperLockOwnerOrNull(lockDir);

    // One reclaimer wins and frees the path...
    assert.equal(
      reclaimAbandonedRendererAssetDigestHelperLockDirectory(lockDir, staleDirInfo, staleOwnerInfo),
      "reclaimed",
    );

    // ...and a successor immediately, legitimately acquires it.
    const successor = acquireRendererAssetDigestHelperLock(lockDir, {
      deadlineMs: 5_000,
      initGraceMs: 0,
    });
    assert.equal(successor.ownerInfo.pid, process.pid);

    // A second, slower reclaimer still holding the *original* stale
    // snapshot (captured before either reclaim happened) must never
    // touch the successor's lock.
    const result = reclaimAbandonedRendererAssetDigestHelperLockDirectory(
      lockDir,
      staleDirInfo,
      staleOwnerInfo,
    );
    assert.equal(result, "not-stale");

    // The successor's lock is completely intact.
    assert.equal(existsSync(lockDir), true);
    const currentOwner = readRendererAssetDigestHelperLockOwnerOrNull(lockDir);
    assert.equal(currentOwner.pid, process.pid);
    assert.equal(currentOwner.fileInfo.ino, successor.ownerInfo.fileInfo.ino);

    releaseRendererAssetDigestHelperLock(successor);
    assert.equal(existsSync(lockDir), false);
  });
});

test("final cleanup removes only the exact lock instance this process acquired, never a successor that replaced it", () => {
  withScratchDir((scratch) => {
    const lockDir = join(scratch, "helper.lock");
    const lock = acquireRendererAssetDigestHelperLock(lockDir, { deadlineMs: 5_000, initGraceMs: 0 });

    // Simulate the (should-be-impossible-in-practice) case where the lock
    // directory this process believes it owns has, by the time it
    // releases, actually been replaced by a successor's own lock at the
    // same path (defense in depth: this must never be silently deleted).
    rmSync(lockDir, { recursive: true, force: true });
    mkdirSync(lockDir);
    writeOwnerFile(lockDir, process.pid);
    const successorOwnerInfo = readRendererAssetDigestHelperLockOwnerOrNull(lockDir);
    const successorDirInfo = lstatSync(lockDir);

    assert.throws(
      () => releaseRendererAssetDigestHelperLock(lock),
      /renderer asset digest helper lock (owner metadata )?changed identity before release/,
    );

    // The successor's lock must remain exactly as it was: same directory
    // identity, same owner file identity, never removed or altered.
    assert.equal(existsSync(lockDir), true);
    const currentDirInfo = lstatSync(lockDir);
    assert.equal(currentDirInfo.ino, successorDirInfo.ino);
    const currentOwner = readRendererAssetDigestHelperLockOwnerOrNull(lockDir);
    assert.equal(currentOwner.pid, process.pid);
    assert.equal(currentOwner.fileInfo.ino, successorOwnerInfo.fileInfo.ino);

    rmSync(lockDir, { recursive: true, force: true });
  });
});

test("a symlinked lock path fails closed instead of being silently followed or reclaimed", () => {
  withScratchDir((scratch) => {
    const lockDir = join(scratch, "helper.lock");
    const elsewhere = join(scratch, "elsewhere");
    mkdirSync(elsewhere);
    symlinkSync(elsewhere, lockDir);

    assert.throws(
      () => acquireRendererAssetDigestHelperLock(lockDir, { deadlineMs: 100, initGraceMs: 0 }),
      /renderer asset digest helper lock path must be a real directory, never a symlink/,
    );

    // Fails closed: never deleted, never replaced, never followed.
    assert.equal(lstatSync(lockDir).isSymbolicLink(), true);
    assert.equal(existsSync(elsewhere), true);
  });
});

test("malformed owner.json fails closed instead of being treated as an abandoned lock", () => {
  withScratchDir((scratch) => {
    const lockDir = join(scratch, "helper.lock");
    mkdirSync(lockDir);
    writeFileSync(join(lockDir, "owner.json"), "not json");

    assert.throws(
      () => acquireRendererAssetDigestHelperLock(lockDir, { deadlineMs: 100, initGraceMs: 0 }),
      /renderer asset digest helper lock owner metadata is malformed/,
    );

    assert.equal(readFileSync(join(lockDir, "owner.json"), "utf8"), "not json");
  });
});

test("a symlinked owner.json fails closed instead of being treated as an abandoned lock", () => {
  withScratchDir((scratch) => {
    const lockDir = join(scratch, "helper.lock");
    mkdirSync(lockDir);
    const decoyTarget = join(scratch, "decoy.json");
    writeFileSync(decoyTarget, JSON.stringify({ pid: process.pid }));
    symlinkSync(decoyTarget, join(lockDir, "owner.json"));

    assert.throws(
      () => acquireRendererAssetDigestHelperLock(lockDir, { deadlineMs: 100, initGraceMs: 0 }),
      /renderer asset digest helper lock owner metadata must be a regular non-symlink file/,
    );

    assert.equal(lstatSync(join(lockDir, "owner.json")).isSymbolicLink(), true);
  });
});

test("real concurrent OS processes contending for the same lock never overlap and leave no lock artifacts behind", async () => {
  await withAsyncScratchDir(async (scratch) => {
    const lockDir = join(scratch, "helper.lock");
    const logPath = join(scratch, "log.txt");
    writeFileSync(logPath, "");

    const workerCount = 5;
    const children = Array.from({ length: workerCount }, () =>
      spawn(process.execPath, [workerPath, lockDir, logPath], {
        cwd: repoRoot,
        stdio: ["ignore", "pipe", "pipe"],
      }),
    );

    const results = await Promise.all(
      children.map(
        (child) =>
          new Promise((resolve, reject) => {
            let stderr = "";
            child.stderr.setEncoding("utf8");
            child.stderr.on("data", (chunk) => {
              stderr += chunk;
            });
            child.on("error", reject);
            child.on("close", (code) => resolve({ code, stderr }));
          }),
      ),
    );

    for (const result of results) {
      assert.equal(result.code, 0, result.stderr);
    }

    const intervals = readFileSync(logPath, "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => line.split(" ").map(Number))
      .sort(([leftStart], [rightStart]) => leftStart - rightStart);
    assert.equal(intervals.length, workerCount);
    for (let i = 1; i < intervals.length; i += 1) {
      const [, previousEnd] = intervals[i - 1];
      const [currentStart] = intervals[i];
      assert.ok(
        currentStart >= previousEnd,
        `held intervals overlapped: ${JSON.stringify(intervals)}`,
      );
    }

    assert.equal(existsSync(lockDir), false);
  });
});
