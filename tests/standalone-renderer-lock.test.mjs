import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { computeRendererBuildDigest } from "../scripts/renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const wrapperPath = join(repoRoot, "scripts", "build-standalone-renderer.mjs");
const testBuilderPath = join(here, "helpers", "renderer-lock-test-builder.mjs");
const consumerPath = join(here, "helpers", "assert-renderer-generation.mjs");
const failingProcessGroupPath = join(here, "helpers", "renderer-failing-process-group.mjs");
const exitedLeaderGroupPath = join(here, "helpers", "renderer-exited-leader-group.mjs");
const publicationKillHookPath = join(here, "helpers", "renderer-publication-kill-hook.mjs");

function runWrapper({ env = {}, consumerArgs = [] } = {}) {
  const args = [wrapperPath];
  if (consumerArgs.length > 0) args.push("--", ...consumerArgs);
  const child = spawn(process.execPath, args, {
    cwd: repoRoot,
    env: { ...process.env, ...env },
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
  const completed = new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
  return { child, completed };
}

async function waitForFile(path, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      statSync(path);
      return;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${path}`);
}

function currentBootIdentity() {
  const output = execFileSync("/usr/sbin/sysctl", ["-n", "kern.boottime"], {
    encoding: "utf8",
  });
  const match = output.match(/sec\s*=\s*(\d+),\s*usec\s*=\s*(\d+)/);
  assert.ok(match, `unexpected kern.boottime output: ${output}`);
  return `${match[1]}:${match[2]}`;
}

function processStartIdentity(pid) {
  return execFileSync("/bin/ps", ["-p", String(pid), "-o", "lstart="], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
  })
    .trim()
    .replaceAll(/\s+/g, " ");
}

function processStartIdentityOrNull(pid) {
  try {
    return processStartIdentity(pid);
  } catch (error) {
    if (Number.isInteger(error.status) && error.status !== 0) return null;
    throw error;
  }
}

function writeSyntheticLock(owner, child = null) {
  const lockDir = join(repoRoot, ".seer-standalone-renderer.lock");
  rmSync(lockDir, { recursive: true, force: true });
  mkdirSync(lockDir, { mode: 0o700 });
  writeFileSync(join(lockDir, "owner.json"), `${JSON.stringify(owner)}\n`, { mode: 0o600 });
  if (child) {
    writeFileSync(join(lockDir, "child.json"), `${JSON.stringify(child)}\n`, { mode: 0o600 });
  }
  return lockDir;
}

function isProcessGroupAlive(processGroupId) {
  try {
    process.kill(-processGroupId, 0);
    return true;
  } catch (error) {
    if (error.code === "EPERM") return true;
    if (error.code === "ESRCH") return false;
    throw error;
  }
}

async function waitForProcessGroupExit(processGroupId, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (isProcessGroupAlive(processGroupId)) {
    if (Date.now() >= deadline) {
      throw new Error(`timed out waiting for process group ${processGroupId} to exit`);
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

test("official macOS consumers build and hold the renderer lock instead of relying on an Xcode prebuild", () => {
  const packageJson = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8"));
  for (const scriptName of ["generate:macos", "test:macos", "build:macos"]) {
    assert.match(packageJson.scripts[scriptName], /build-standalone-renderer\.mjs --/);
  }
  const project = readFileSync(join(repoRoot, "apps", "macos", "Seer", "project.yml"), "utf8");
  assert.doesNotMatch(project, /preBuildScripts|Build standalone renderer/);
});

test("concurrent consumers never observe another generation or a mixed asset/manifest pair", async () => {
  const commonEnv = {
    SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
    SEER_RENDERER_LOCK_WAIT_MS: "120000",
  };
  const first = runWrapper({
    env: { ...commonEnv, SEER_RENDERER_BUILD_TEST_MARKER: "generation-a" },
    consumerArgs: [process.execPath, consumerPath, "generation-a", "300"],
  });
  const second = runWrapper({
    env: { ...commonEnv, SEER_RENDERER_BUILD_TEST_MARKER: "generation-b" },
    consumerArgs: [process.execPath, consumerPath, "generation-b", "300"],
  });

  const results = await Promise.all([first.completed, second.completed]);
  for (const result of results) {
    assert.equal(result.code, 0, `wrapper failed:\n${result.stdout}\n${result.stderr}`);
  }
});

test("a renderer source edit during the build discards stale assets and retries with one source identity", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-source-race-test-"));
  const sourcePath = join(repoRoot, "renderer", "bridge", "renderer-bridge-context.tsx");
  const originalSource = readFileSync(sourcePath, "utf8");
  const readyPath = join(scratch, "first-build-ready");
  const releasePath = join(scratch, "release-first-build");
  const counterPath = join(scratch, "build-count");
  const historyPath = join(scratch, "build-history");
  const originalSourcePath = join(scratch, "original-renderer-source");
  writeFileSync(originalSourcePath, originalSource);
  try {
    const run = runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "source-race",
        SEER_RENDERER_BUILD_TEST_COUNTER_PATH: counterPath,
        SEER_RENDERER_BUILD_TEST_HISTORY_PATH: historyPath,
        SEER_RENDERER_BUILD_TEST_BLOCK_FIRST_READY_PATH: readyPath,
        SEER_RENDERER_BUILD_TEST_BLOCK_FIRST_RELEASE_PATH: releasePath,
        SEER_RENDERER_BUILD_TEST_RESTORE_SOURCE_PATH: sourcePath,
        SEER_RENDERER_BUILD_TEST_RESTORE_SOURCE_FROM: originalSourcePath,
      },
    });
    await waitForFile(readyPath, 120_000);
    writeFileSync(sourcePath, `${originalSource}\n// deterministic source-race edit\n`);
    writeFileSync(releasePath, "release\n");

    const result = await run.completed;
    assert.equal(result.code, 0, `source-race build failed:\n${result.stdout}\n${result.stderr}`);
    const renderer = join(repoRoot, "build", "standalone-renderer", "Renderer");
    assert.equal(readFileSync(join(renderer, "generation-marker.txt"), "utf8"), "source-race-3\n");
    assert.equal(readFileSync(counterPath, "utf8"), "3\n");
    assert.equal(
      readFileSync(historyPath, "utf8"),
      "source-race-1\nsource-race-2\nsource-race-3\n",
    );
    assert.equal(
      JSON.parse(readFileSync(join(renderer, "build-manifest.json"), "utf8")).sourceDigest,
      computeRendererBuildDigest(repoRoot),
    );
  } finally {
    writeFileSync(releasePath, "release\n");
    writeFileSync(sourcePath, originalSource);
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("EEXIST followed by a disappearing lock retries across repeated handoffs", async () => {
  const env = {
    SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
    SEER_RENDERER_LOCK_TEST_EEXIST_DELAY_MS: "30",
    SEER_RENDERER_LOCK_POLL_MS: "1",
    SEER_RENDERER_LOCK_WAIT_MS: "120000",
  };
  const runs = Array.from({ length: 10 }, (_, index) =>
    runWrapper({
      env: { ...env, SEER_RENDERER_BUILD_TEST_MARKER: `handoff-${index}` },
    }).completed,
  );
  const results = await Promise.all(runs);
  for (const result of results) {
    assert.equal(result.code, 0, `handoff failed:\n${result.stdout}\n${result.stderr}`);
    assert.doesNotMatch(result.stderr, /ENOENT|no such file/i);
  }
});

test("a dead wrapper's known live child group prevents lock stealing and writes only to its private generation", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-child-lock-test-"));
  const childStarted = join(scratch, "child-started");
  try {
    const abandoned = runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "abandoned-writer",
        SEER_RENDERER_BUILD_TEST_CHILD_STARTED_PATH: childStarted,
        SEER_RENDERER_BUILD_TEST_CHILD_DELAY_MS: "500",
      },
    });
    await waitForFile(childStarted, 20_000);
    abandoned.child.kill("SIGKILL");

    const winner = runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "winner",
        SEER_RENDERER_LOCK_STALE_MS: "10",
        SEER_RENDERER_LOCK_POLL_MS: "10",
        SEER_RENDERER_LOCK_WAIT_MS: "5000",
      },
    });
    const result = await winner.completed;
    assert.equal(result.code, 0, `winner failed:\n${result.stdout}\n${result.stderr}`);
    const abandonedResult = await abandoned.completed;
    assert.equal(abandonedResult.signal, "SIGKILL");

    const publicMarker = readFileSync(
      join(repoRoot, "build", "standalone-renderer", "Renderer", "generation-marker.txt"),
      "utf8",
    );
    assert.equal(publicMarker, "winner\n", "the abandoned child must never write into the public Renderer");
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("a recorded child process group retains the stale lock after its leader exits until its descendant exits", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-exited-leader-test-"));
  const leaderReadyPath = join(scratch, "leader-ready");
  const leaderReleasePath = join(scratch, "leader-release");
  const descendantPidPath = join(scratch, "descendant-pid");
  const descendantExitedPath = `${descendantPidPath}.exited`;
  const descendantReleasePath = join(scratch, "descendant-release");
  const token = "leader-exited-descendant-live";
  const leader = spawn(
    process.execPath,
    [
      exitedLeaderGroupPath,
      leaderReadyPath,
      leaderReleasePath,
      descendantPidPath,
      descendantReleasePath,
    ],
    { cwd: repoRoot, detached: true, stdio: "ignore" },
  );
  const leaderCompleted = new Promise((resolve) => {
    leader.once("error", (error) => resolve({ error }));
    leader.once("close", () => resolve({ error: null }));
  });
  let lockDir = null;
  let descendantPid = null;
  let descendantStartIdentity = null;
  try {
    await waitForFile(leaderReadyPath);
    await waitForFile(descendantPidPath);
    descendantPid = Number(readFileSync(descendantPidPath, "utf8").trim());
    descendantStartIdentity = processStartIdentity(descendantPid);
    const leaderStartIdentity = processStartIdentity(leader.pid);
    writeFileSync(leaderReleasePath, "release\n");
    const leaderResult = await leaderCompleted;
    if (leaderResult.error) throw leaderResult.error;
    assert.equal(isProcessGroupAlive(leader.pid), true);

    const bootIdentity = currentBootIdentity();
    lockDir = writeSyntheticLock(
      {
        token,
        pid: 2147483647,
        createdAtMs: 0,
        bootIdentity,
        processStartIdentity: "dead-owner",
      },
      {
        token,
        pid: leader.pid,
        processGroupId: leader.pid,
        createdAtMs: 0,
        bootIdentity,
        processStartIdentity: leaderStartIdentity,
      },
    );

    const blocked = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_LOCK_STALE_MS: "0",
        SEER_RENDERER_LOCK_POLL_MS: "5",
        SEER_RENDERER_LOCK_WAIT_MS: "75",
      },
    }).completed;
    assert.notEqual(blocked.code, 0);
    assert.match(blocked.stderr, /process group.*still alive/i);
    assert.equal(existsSync(lockDir), true);

    writeFileSync(descendantReleasePath, "release\n");
    await waitForProcessGroupExit(leader.pid);
    const recovered = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "descendant-exited",
        SEER_RENDERER_LOCK_STALE_MS: "0",
        SEER_RENDERER_LOCK_WAIT_MS: "1000",
      },
    }).completed;
    assert.equal(recovered.code, 0, `stale child-group lock was retained:\n${recovered.stderr}`);
    assert.equal(existsSync(lockDir), false);
  } finally {
    writeFileSync(leaderReleasePath, "release\n");
    writeFileSync(descendantReleasePath, "release\n");
    await Promise.race([
      leaderCompleted,
      new Promise((resolve) => setTimeout(resolve, 2_000)),
    ]);
    if (leader.exitCode === null && leader.signalCode === null) {
      leader.kill("SIGKILL");
      await leaderCompleted;
    }
    if (!descendantPid && existsSync(descendantPidPath)) {
      descendantPid = Number(readFileSync(descendantPidPath, "utf8").trim());
      descendantStartIdentity = processStartIdentityOrNull(descendantPid);
    }
    try {
      await waitForFile(descendantExitedPath, 2_000);
    } catch (error) {
      if (error.message !== `timed out waiting for ${descendantExitedPath}`) {
        throw error;
      }
    }
    if (
      descendantPid &&
      descendantStartIdentity &&
      processStartIdentityOrNull(descendantPid) === descendantStartIdentity
    ) {
      process.kill(descendantPid, "SIGKILL");
    }
    if (lockDir) rmSync(lockDir, { recursive: true, force: true });
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("an unprovable recorded process-group identity retains the lock with bounded manual recovery diagnostics", async () => {
  const token = "unprovable-child-group";
  const bootIdentity = currentBootIdentity();
  const lockDir = writeSyntheticLock(
    {
      token,
      pid: 2147483647,
      createdAtMs: 0,
      bootIdentity,
      processStartIdentity: "dead-owner",
    },
    {
      token,
      pid: 2147483646,
      processGroupId: 2147483645,
      createdAtMs: 0,
      bootIdentity,
      processStartIdentity: "unknown-leader",
    },
  );
  try {
    const result = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_LOCK_STALE_MS: "0",
        SEER_RENDERER_LOCK_POLL_MS: "5",
        SEER_RENDERER_LOCK_WAIT_MS: "30",
      },
    }).completed;
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /cannot be proven stale/i);
    assert.match(result.stderr, /remove .*\.seer-standalone-renderer\.lock manually/i);
    assert.equal(existsSync(lockDir), true);
  } finally {
    rmSync(lockDir, { recursive: true, force: true });
  }
});

test("wrapper failure terminates and waits for the recorded child process group before releasing", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-process-group-test-"));
  const grandchildPidPath = join(scratch, "grandchild-pid");
  let grandchildPid = null;
  try {
    const run = runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "failure-cleanup",
      },
      consumerArgs: [process.execPath, failingProcessGroupPath, grandchildPidPath],
    });
    await waitForFile(grandchildPidPath);
    grandchildPid = Number(readFileSync(grandchildPidPath, "utf8").trim());
    const result = await run.completed;
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /status 17/);
    assert.throws(
      () => process.kill(grandchildPid, 0),
      (error) => error.code === "ESRCH",
      "the wrapper must wait until the failed consumer's process group is gone",
    );
    assert.throws(
      () => statSync(join(repoRoot, ".seer-standalone-renderer.lock")),
      (error) => error.code === "ENOENT",
    );
  } finally {
    if (grandchildPid) {
      try {
        process.kill(grandchildPid, "SIGKILL");
      } catch (error) {
        if (error.code !== "ESRCH") throw error;
      }
    }
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("the next wrapper recovers every SIGKILL publication phase under the lock", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-publication-kill-test-"));
  const buildRoot = join(repoRoot, "build", "standalone-renderer");
  const phases = [
    ["prepared", "old"],
    ["old-backed-up", "old"],
    ["new-published", "new"],
    ["cleanup", "new"],
    ["backup-cleaned", "new"],
  ];
  try {
    for (const [phase, expectedMarker] of phases) {
      const baseline = await runWrapper({
        env: {
          SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
          SEER_RENDERER_BUILD_TEST_MARKER: "old",
        },
      }).completed;
      assert.equal(baseline.code, 0, `baseline failed:\n${baseline.stderr}`);

      const readyPath = join(scratch, `${phase}-ready`);
      const killedRun = runWrapper({
        env: {
          SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
          SEER_RENDERER_BUILD_TEST_MARKER: "new",
          SEER_RENDERER_PUBLICATION_TEST_HOOK: publicationKillHookPath,
          SEER_RENDERER_PUBLICATION_TEST_PHASE: phase,
          SEER_RENDERER_PUBLICATION_TEST_READY_PATH: readyPath,
        },
      });
      const killed = await killedRun.completed;
      assert.equal(killed.signal, "SIGKILL", `${phase} did not hard-kill:\n${killed.stderr}`);
      assert.equal(readFileSync(readyPath, "utf8"), `${phase}\n`);

      const recovery = await runWrapper({
        env: {
          SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
          SEER_RENDERER_BUILD_TEST_FAIL: "1",
          SEER_RENDERER_LOCK_STALE_MS: "0",
          SEER_RENDERER_LOCK_POLL_MS: "5",
          SEER_RENDERER_LOCK_WAIT_MS: "5000",
        },
      }).completed;
      assert.notEqual(recovery.code, 0, "the post-recovery injected build must fail");
      assert.equal(
        readFileSync(join(buildRoot, "Renderer", "generation-marker.txt"), "utf8"),
        `${expectedMarker}\n`,
        `wrong recovered generation after ${phase}`,
      );
      assert.deepEqual(
        readdirSync(buildRoot).filter((name) => name.startsWith(".renderer-")),
        [],
        `transaction artifacts survived recovery after ${phase}`,
      );
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("backup-cleaned recovery validates the committed assets independently of edited source, then rebuilds", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-backup-cleaned-source-test-"));
  const buildRoot = join(repoRoot, "build", "standalone-renderer");
  const sourcePath = join(repoRoot, "renderer", "bridge", "renderer-bridge-context.tsx");
  const originalSource = readFileSync(sourcePath, "utf8");
  try {
    const baseline = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "old",
      },
    }).completed;
    assert.equal(baseline.code, 0, `baseline failed:\n${baseline.stderr}`);

    const readyPath = join(scratch, "backup-cleaned-ready");
    const killed = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "committed-before-edit",
        SEER_RENDERER_PUBLICATION_TEST_HOOK: publicationKillHookPath,
        SEER_RENDERER_PUBLICATION_TEST_PHASE: "backup-cleaned",
        SEER_RENDERER_PUBLICATION_TEST_READY_PATH: readyPath,
      },
    }).completed;
    assert.equal(killed.signal, "SIGKILL");

    writeFileSync(sourcePath, `${originalSource}\n// edited after committed publication\n`);
    const recovery = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "rebuilt-current-source",
        SEER_RENDERER_LOCK_STALE_MS: "0",
        SEER_RENDERER_LOCK_WAIT_MS: "5000",
      },
    }).completed;
    assert.equal(recovery.code, 0, `recovery/rebuild failed:\n${recovery.stdout}\n${recovery.stderr}`);
    assert.equal(
      readFileSync(join(buildRoot, "Renderer", "generation-marker.txt"), "utf8"),
      "rebuilt-current-source\n",
    );
    assert.equal(
      JSON.parse(readFileSync(join(buildRoot, "Renderer", "build-manifest.json"), "utf8"))
        .sourceDigest,
      computeRendererBuildDigest(repoRoot),
    );
    assert.deepEqual(
      readdirSync(buildRoot).filter((name) => name.startsWith(".renderer-")),
      [],
    );
  } finally {
    writeFileSync(sourcePath, originalSource);
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("recovery rolls back a corrupted newly published Renderer when an old backup is available", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-publication-corrupt-test-"));
  const buildRoot = join(repoRoot, "build", "standalone-renderer");
  try {
    const baseline = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "old",
      },
    }).completed;
    assert.equal(baseline.code, 0, `baseline failed:\n${baseline.stderr}`);

    const readyPath = join(scratch, "new-published-ready");
    const killed = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "new",
        SEER_RENDERER_PUBLICATION_TEST_HOOK: publicationKillHookPath,
        SEER_RENDERER_PUBLICATION_TEST_PHASE: "new-published",
        SEER_RENDERER_PUBLICATION_TEST_READY_PATH: readyPath,
      },
    }).completed;
    assert.equal(killed.signal, "SIGKILL");
    writeFileSync(join(buildRoot, "Renderer", "generation-marker.txt"), "corrupt\n");

    const recovery = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_FAIL: "1",
        SEER_RENDERER_LOCK_STALE_MS: "0",
        SEER_RENDERER_LOCK_WAIT_MS: "5000",
      },
    }).completed;
    assert.notEqual(recovery.code, 0);
    assert.equal(
      readFileSync(join(buildRoot, "Renderer", "generation-marker.txt"), "utf8"),
      "old\n",
    );
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("recovery fails closed without deleting a corrupted Renderer when its old backup was committed clean", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-publication-no-rollback-test-"));
  const buildRoot = join(repoRoot, "build", "standalone-renderer");
  try {
    const baseline = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "old",
      },
    }).completed;
    assert.equal(baseline.code, 0, `baseline failed:\n${baseline.stderr}`);

    const readyPath = join(scratch, "backup-cleaned-ready");
    const killed = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "new",
        SEER_RENDERER_PUBLICATION_TEST_HOOK: publicationKillHookPath,
        SEER_RENDERER_PUBLICATION_TEST_PHASE: "backup-cleaned",
        SEER_RENDERER_PUBLICATION_TEST_READY_PATH: readyPath,
      },
    }).completed;
    assert.equal(killed.signal, "SIGKILL");
    const markerPath = join(buildRoot, "Renderer", "generation-marker.txt");
    writeFileSync(markerPath, "corrupt-but-preserved\n");

    const recovery = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_FAIL: "1",
        SEER_RENDERER_LOCK_STALE_MS: "0",
        SEER_RENDERER_LOCK_WAIT_MS: "5000",
      },
    }).completed;
    assert.notEqual(recovery.code, 0);
    assert.match(recovery.stderr, /rollback|backup|validate|manifest|generation/i);
    assert.equal(
      readFileSync(markerPath, "utf8"),
      "corrupt-but-preserved\n",
      "fail-closed recovery must preserve the only remaining generation",
    );
    assert.equal(existsSync(join(buildRoot, ".renderer-publication-transaction.json")), true);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
    rmSync(buildRoot, { recursive: true, force: true });
  }
});

test("a malicious renderer transaction path is rejected without touching its canary", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-publication-journal-test-"));
  const buildRoot = join(repoRoot, "build", "standalone-renderer");
  const canary = join(scratch, "canary.txt");
  try {
    const baseline = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "old",
      },
    }).completed;
    assert.equal(baseline.code, 0, `baseline failed:\n${baseline.stderr}`);
    writeFileSync(canary, "do-not-touch\n");
    writeFileSync(
      join(buildRoot, ".renderer-publication-transaction.json"),
      `${JSON.stringify({
        schemaVersion: 1,
        phase: "prepared",
        paths: {
          publicationParent: buildRoot,
          renderer: join(buildRoot, "Renderer"),
          stage: canary,
          backup: join(buildRoot, `.renderer-backup-${"a".repeat(32)}`),
        },
        oldRenderer: { present: true, identity: [1, 2] },
        newRendererIdentity: [3, 4],
      })}\n`,
    );

    const result = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "must-not-publish",
      },
    }).completed;
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /transaction|journal|path|stage/i);
    assert.equal(readFileSync(canary, "utf8"), "do-not-touch\n");
    assert.equal(
      readFileSync(join(buildRoot, "Renderer", "generation-marker.txt"), "utf8"),
      "old\n",
    );
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("a symlinked renderer transaction journal is rejected without touching its target", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-publication-symlink-test-"));
  const buildRoot = join(repoRoot, "build", "standalone-renderer");
  const canary = join(scratch, "canary.txt");
  try {
    rmSync(buildRoot, { recursive: true, force: true });
    mkdirSync(buildRoot, { recursive: true });
    writeFileSync(canary, "do-not-touch\n");
    symlinkSync(canary, join(buildRoot, ".renderer-publication-transaction.json"));

    const result = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "must-not-publish",
      },
    }).completed;
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /transaction|journal|symlink/i);
    assert.equal(readFileSync(canary, "utf8"), "do-not-touch\n");
    assert.equal(existsSync(join(buildRoot, "Renderer")), false);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
    rmSync(buildRoot, { recursive: true, force: true });
  }
});

test("a live PID with the wrong process-start identity is recovered as a stale lock", async () => {
  const lockDir = writeSyntheticLock({
    token: "recycled-pid",
    pid: process.pid,
    createdAtMs: 0,
    bootIdentity: currentBootIdentity(),
    processStartIdentity: "not-this-process",
  });
  try {
    const result = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "wrong-identity-recovered",
        SEER_RENDERER_LOCK_STALE_MS: "0",
        SEER_RENDERER_LOCK_WAIT_MS: "1000",
      },
    }).completed;
    assert.equal(result.code, 0, `stale recycled PID lock was retained:\n${result.stderr}`);
    assert.equal(existsSync(lockDir), false);
  } finally {
    rmSync(lockDir, { recursive: true, force: true });
  }
});

test("a live PID with matching boot and process-start identities retains the lock", async () => {
  const lockDir = writeSyntheticLock({
    token: "actual-live-owner",
    pid: process.pid,
    createdAtMs: 0,
    bootIdentity: currentBootIdentity(),
    processStartIdentity: processStartIdentity(process.pid),
  });
  try {
    const result = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_LOCK_STALE_MS: "0",
        SEER_RENDERER_LOCK_POLL_MS: "5",
        SEER_RENDERER_LOCK_WAIT_MS: "50",
      },
    }).completed;
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /timed out.*renderer.*lock/i);
    assert.equal(existsSync(lockDir), true);
  } finally {
    rmSync(lockDir, { recursive: true, force: true });
  }
});

test("a live PID recorded under an old boot identity is recovered as stale", async () => {
  const lockDir = writeSyntheticLock({
    token: "old-boot-owner",
    pid: process.pid,
    createdAtMs: 0,
    bootIdentity: "0:0",
    processStartIdentity: processStartIdentity(process.pid),
  });
  try {
    const result = await runWrapper({
      env: {
        SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
        SEER_RENDERER_BUILD_TEST_MARKER: "old-boot-recovered",
        SEER_RENDERER_LOCK_STALE_MS: "0",
        SEER_RENDERER_LOCK_WAIT_MS: "1000",
      },
    }).completed;
    assert.equal(result.code, 0, `old-boot lock was retained:\n${result.stderr}`);
    assert.equal(existsSync(lockDir), false);
  } finally {
    rmSync(lockDir, { recursive: true, force: true });
  }
});
