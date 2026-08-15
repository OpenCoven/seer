import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const wrapperPath = join(repoRoot, "scripts", "build-standalone-renderer.mjs");
const testBuilderPath = join(here, "helpers", "renderer-lock-test-builder.mjs");
const consumerPath = join(here, "helpers", "assert-renderer-generation.mjs");
const failingProcessGroupPath = join(here, "helpers", "renderer-failing-process-group.mjs");

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

async function waitForFile(path, timeoutMs = 3_000) {
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
    SEER_RENDERER_LOCK_WAIT_MS: "10000",
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

test("EEXIST followed by a disappearing lock retries across repeated handoffs", async () => {
  const env = {
    SEER_RENDERER_BUILD_TEST_BUILDER: testBuilderPath,
    SEER_RENDERER_LOCK_TEST_EEXIST_DELAY_MS: "30",
    SEER_RENDERER_LOCK_POLL_MS: "1",
    SEER_RENDERER_LOCK_WAIT_MS: "10000",
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
