import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
import { spawn, spawnSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
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
  computeAppDigest,
  loadBuildProvenance,
} from "../scripts/check-standalone-boundary.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const helperPath = join(repoRoot, "scripts", "publish-macos-app.py");

function makeFixtureApp(path, marker) {
  mkdirSync(join(path, "Contents", "MacOS"), { recursive: true });
  const executable = Buffer.alloc(32);
  executable.writeUInt32LE(0xfeedfacf, 0);
  executable.writeUInt32LE(0x0100000c, 4);
  executable.writeUInt32LE(2, 12);
  writeFileSync(join(path, "Contents", "MacOS", "Seer"), executable, { mode: 0o755 });
  writeFileSync(join(path, "Contents", "marker.txt"), marker);
  writeFileSync(join(path, "Contents", "Info.plist"), "<plist/>\n");
}

function publicationArgs({
  fixtureRepo,
  sourceApp,
  derivedData,
  testHook,
  testHookPhase,
  testFailpoint,
}) {
  const args = [
    helperPath,
    "--repo-root",
    fixtureRepo,
    "--source-app",
    sourceApp,
    "--derived-data-path",
    derivedData,
  ];
  if (testHook) {
    args.push("--test-hook", testHook);
  }
  if (testHookPhase) {
    args.push("--test-hook-phase", testHookPhase);
  }
  if (testFailpoint) {
    args.push("--test-failpoint", testFailpoint);
  }
  return args;
}

function publish(options) {
  const { env = {} } = options;
  const args = publicationArgs(options);
  return spawnSync("/usr/bin/python3", args, {
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
}

function publishAsync(options) {
  return spawnPublisher(options).completion;
}

function spawnPublisher(options) {
  const { detached = false, env = {} } = options;
  const child = spawn("/usr/bin/python3", publicationArgs(options), {
    detached,
    encoding: "utf8",
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
  const completion = new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (status, signal) => resolve({ status, signal, stdout, stderr }));
  });
  return { child, completion, detached };
}

// Matches the bounded-poll convention used by the other long-running-process
// tests in this repo (tests/package-macos-release.test.mjs,
// tests/standalone-renderer-lock.test.mjs): a named, generous default that
// still fails fast on a genuinely stuck publisher, but does not flake under
// full-suite/CI resource contention the way a fixed 5s deadline did.
const HOOK_READY_TIMEOUT_MS = 20_000;
const PUBLISHER_TERMINATION_TIMEOUT_MS = 10_000;

async function waitForPath(path, child, timeoutMs = HOOK_READY_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs;
  while (!existsSync(path)) {
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(`publisher exited before creating ${path}`);
    }
    if (Date.now() >= deadline) {
      throw new Error(`timed out after ${timeoutMs}ms waiting for ${path}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function withTimeout(promise, timeoutMs, message) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), timeoutMs);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

// Guarantees a spawned publisher (and any hook it is blocked in) is reliably
// terminated and awaited on every path, including a readiness timeout or an
// assertion throwing mid-scenario, so a stuck child can never survive into
// later tests. Only ever signals the exact child pid, or its exact process
// group when the child was spawned detached -- never a name-based kill.
async function terminatePublisher(running, hook) {
  const { child, completion, detached } = running;
  if (hook) {
    try {
      writeFileSync(hook.releasePath, "release\n");
    } catch {
      // Best effort: unblock a hook that may still be polling for this file.
    }
  }
  if (child.exitCode === null && child.signalCode === null) {
    try {
      if (detached) {
        process.kill(-child.pid, "SIGKILL");
      } else {
        child.kill("SIGKILL");
      }
    } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }
  try {
    await withTimeout(
      completion,
      PUBLISHER_TERMINATION_TIMEOUT_MS,
      `publisher pid ${child.pid} did not exit within ${PUBLISHER_TERMINATION_TIMEOUT_MS}ms of termination`,
    );
  } catch (error) {
    // Cleanup must never mask the test's own assertion failure; surface a
    // loud warning instead so a genuinely undead process is still visible.
    console.error(error);
  }
}

function makeBlockingHook(scratch) {
  const hookPath = join(scratch, "block-publisher.sh");
  const readyPath = join(scratch, "hook-ready");
  const releasePath = join(scratch, "hook-release");
  writeFileSync(
    hookPath,
    [
      "#!/bin/bash",
      "set -euo pipefail",
      'printf "ready\\n" > "${SEER_TEST_READY_PATH}"',
      'while [[ ! -f "${SEER_TEST_RELEASE_PATH}" ]]; do sleep 0.01; done',
      "",
    ].join("\n"),
  );
  chmodSync(hookPath, 0o755);
  return {
    hookPath,
    readyPath,
    releasePath,
    env: {
      SEER_TEST_READY_PATH: readyPath,
      SEER_TEST_RELEASE_PATH: releasePath,
    },
  };
}

function transactionArtifacts(fixtureRepo) {
  const macosDir = join(fixtureRepo, "build", "macos");
  const unsignedDir = join(macosDir, "unsigned");
  return [
    ...readdirSync(macosDir)
      .filter((name) => name.startsWith(".seer-") && name !== ".seer-publication.lock")
      .map((name) => join(macosDir, name)),
    ...readdirSync(unsignedDir)
      .filter((name) => name.startsWith(".seer-"))
      .map((name) => join(unsignedDir, name)),
  ];
}

function unpreparedJournal(fixtureRepo) {
  const macosDir = join(fixtureRepo, "build", "macos");
  const unsignedDir = join(macosDir, "unsigned");
  return {
    schemaVersion: 1,
    phase: "staging",
    paths: {
      publicationParent: macosDir,
      unsignedParent: unsignedDir,
      app: join(unsignedDir, "Seer.app"),
      provenance: join(macosDir, "standalone-build-provenance.json"),
      stage: join(unsignedDir, `.seer-stage-${"1".repeat(32)}`),
      appBackup: join(unsignedDir, `.seer-backup-${"2".repeat(32)}`),
      provenanceTemp: join(macosDir, `.seer-provenance-${"3".repeat(32)}.json`),
      provenanceBackup: join(macosDir, `.seer-provenance-backup-${"4".repeat(32)}.json`),
    },
    oldApp: { present: null, identity: null },
    oldProvenance: { present: null, identity: null },
    newAppIdentity: null,
    newProvenanceIdentity: null,
  };
}

test("publication atomically replaces the old app and writes private provenance outside unsigned/", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-success-"));

  try {
    const fixtureRepo = join(scratch, "repo");
    const sourceApp = join(scratch, "source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const unsignedDir = join(fixtureRepo, "build", "macos", "unsigned");
    makeFixtureApp(sourceApp, "new executable\n");
    makeFixtureApp(join(unsignedDir, "Seer.app"), "old executable\n");
    mkdirSync(derivedData, { recursive: true });

    const result = publish({ fixtureRepo, sourceApp, derivedData });
    assert.equal(result.status, 0, `publication failed:\n${result.stdout}\n${result.stderr}`);
    assert.equal(
      readFileSync(join(unsignedDir, "Seer.app", "Contents", "marker.txt"), "utf8"),
      "new executable\n",
    );
    assert.deepEqual(
      readdirSync(unsignedDir).filter((name) => name.startsWith(".seer-")),
      [],
      "successful publication must remove its private staging and backup leaves",
    );

    const provenancePath = join(fixtureRepo, "build", "macos", "standalone-build-provenance.json");
    const provenance = JSON.parse(readFileSync(provenancePath, "utf8"));
    assert.equal(provenance.schemaVersion, 2);
    assert.equal(provenance.algorithm, "sha256");
    assert.equal(provenance.canonicalRepoRoot, fixtureRepo);
    assert.equal(provenance.effectiveDerivedDataPath, derivedData);
    assert.match(provenance.appDigest, /^[0-9a-f]{64}$/);
    assert.equal(provenance.generation, provenance.appDigest);
    assert.equal(provenance.appDigest, computeAppDigest(join(unsignedDir, "Seer.app")));
    assert.deepEqual(
      loadBuildProvenance(provenancePath, {
        expectedRepoRoot: fixtureRepo,
        appPath: join(unsignedDir, "Seer.app"),
      }).forbiddenAbsolutePaths,
      [fixtureRepo, derivedData],
    );
    assert.ok(!provenancePath.startsWith(unsignedDir), "provenance must stay outside public unsigned output");
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("Python publication and Node verification use identical UTF-8 byte ordering for app filenames", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-unicode-digest-"));

  try {
    const fixtureRepo = join(scratch, "repo");
    const sourceApp = join(scratch, "source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const contents = join(sourceApp, "Contents");
    const unsignedApp = join(fixtureRepo, "build", "macos", "unsigned", "Seer.app");
    makeFixtureApp(sourceApp, "unicode ordering\n");
    mkdirSync(fixtureRepo, { recursive: true });
    for (const name of ["Z.txt", "a.txt", "é.txt", "Ω.txt"]) {
      writeFileSync(join(contents, name), `${name}\n`);
    }
    mkdirSync(derivedData, { recursive: true });

    const result = publish({ fixtureRepo, sourceApp, derivedData });
    assert.equal(result.status, 0, `publication failed:\n${result.stdout}\n${result.stderr}`);
    const provenance = JSON.parse(
      readFileSync(
        join(fixtureRepo, "build", "macos", "standalone-build-provenance.json"),
        "utf8",
      ),
    );
    assert.equal(provenance.appDigest, computeAppDigest(unsignedApp));
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("publication rejects a symlinked Seer.app leaf without touching its external target", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-leaf-"));

  try {
    const fixtureRepo = join(scratch, "repo");
    const sourceApp = join(scratch, "source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const unsignedDir = join(fixtureRepo, "build", "macos", "unsigned");
    const victimDir = join(scratch, "leaf-victim");
    makeFixtureApp(sourceApp, "new executable\n");
    mkdirSync(unsignedDir, { recursive: true });
    mkdirSync(victimDir, { recursive: true });
    mkdirSync(derivedData, { recursive: true });
    writeFileSync(join(victimDir, "canary.txt"), "do-not-touch\n");
    symlinkSync(victimDir, join(unsignedDir, "Seer.app"));

    const result = publish({ fixtureRepo, sourceApp, derivedData });
    assert.notEqual(result.status, 0, "publication must reject a symlinked destination leaf");
    assert.match(result.stderr, /symlink/i);
    assert.equal(readFileSync(join(victimDir, "canary.txt"), "utf8"), "do-not-touch\n");
    assert.deepEqual(
      readdirSync(unsignedDir).filter((name) => name.startsWith(".seer-stage-")),
      [],
      "ordinary pre-publication rejection must clean verified private staging",
    );
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("publication fails closed if unsigned/ is replaced by an external symlink after staging", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-race-"));

  try {
    const fixtureRepo = join(scratch, "repo");
    const sourceApp = join(scratch, "source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const unsignedDir = join(fixtureRepo, "build", "macos", "unsigned");
    const heldUnsignedDir = `${unsignedDir}-held`;
    const victimDir = join(scratch, "external-victim");
    const hookPath = join(scratch, "swap-parent.sh");

    makeFixtureApp(sourceApp, "new executable\n");
    makeFixtureApp(join(unsignedDir, "Seer.app"), "old executable\n");
    mkdirSync(derivedData, { recursive: true });
    mkdirSync(join(victimDir, "Seer.app"), { recursive: true });
    writeFileSync(join(victimDir, "Seer.app", "canary.txt"), "do-not-touch\n");

    writeFileSync(
      hookPath,
      [
        "#!/bin/bash",
        "set -euo pipefail",
        'mv "${SEER_PUBLISH_PARENT_PATH}" "${SEER_PUBLISH_PARENT_PATH}-held"',
        'ln -s "${SEER_PUBLISH_VICTIM_PATH}" "${SEER_PUBLISH_PARENT_PATH}"',
        "",
      ].join("\n"),
    );
    chmodSync(hookPath, 0o755);

    const result = publish({
      fixtureRepo,
      sourceApp,
      derivedData,
      testHook: hookPath,
      env: { SEER_PUBLISH_VICTIM_PATH: victimDir },
    });

    assert.notEqual(result.status, 0, `publication unexpectedly succeeded:\n${result.stdout}\n${result.stderr}`);
    assert.match(result.stderr, /changed|symlink|identity/i);
    assert.equal(readFileSync(join(victimDir, "Seer.app", "canary.txt"), "utf8"), "do-not-touch\n");
    assert.equal(readFileSync(join(heldUnsignedDir, "Seer.app", "Contents", "marker.txt"), "utf8"), "old executable\n");
    assert.deepEqual(
      readdirSync(heldUnsignedDir).filter((name) => name.startsWith(".seer-stage-")),
      [],
      "a verified pre-publication stage must be removed even if the canonical parent was swapped",
    );
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("a failed paired swap rolls back both app and provenance and removes staging", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-rollback-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const oldSource = join(scratch, "old-source", "Seer.app");
    const newSource = join(scratch, "new-source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const unsignedDir = join(fixtureRepo, "build", "macos", "unsigned");
    const provenancePath = join(fixtureRepo, "build", "macos", "standalone-build-provenance.json");
    mkdirSync(fixtureRepo, { recursive: true });
    makeFixtureApp(oldSource, "old\n");
    makeFixtureApp(newSource, "new\n");
    mkdirSync(derivedData, { recursive: true });

    assert.equal(publish({ fixtureRepo, sourceApp: oldSource, derivedData }).status, 0);
    const oldProvenance = readFileSync(provenancePath, "utf8");
    const failed = publish({
      fixtureRepo,
      sourceApp: newSource,
      derivedData,
      testFailpoint: "after-app-publish",
    });
    assert.notEqual(failed.status, 0);
    assert.equal(readFileSync(join(unsignedDir, "Seer.app", "Contents", "marker.txt"), "utf8"), "old\n");
    assert.equal(readFileSync(provenancePath, "utf8"), oldProvenance);
    assert.deepEqual(readdirSync(unsignedDir).filter((name) => name.startsWith(".seer-")), []);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("concurrent publishers serialize complete app/provenance generations", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-concurrent-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const sourceA = join(scratch, "source-a", "Seer.app");
    const sourceB = join(scratch, "source-b", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const hookPath = join(scratch, "hold-lock.sh");
    mkdirSync(fixtureRepo, { recursive: true });
    makeFixtureApp(sourceA, "generation-a\n");
    makeFixtureApp(sourceB, "generation-b\n");
    mkdirSync(derivedData, { recursive: true });
    writeFileSync(hookPath, "#!/bin/bash\nset -euo pipefail\nsleep 0.2\n");
    chmodSync(hookPath, 0o755);

    const results = await Promise.all([
      publishAsync({ fixtureRepo, sourceApp: sourceA, derivedData, testHook: hookPath }),
      publishAsync({ fixtureRepo, sourceApp: sourceB, derivedData }),
    ]);
    for (const result of results) {
      assert.equal(result.status, 0, `publication failed:\n${result.stdout}\n${result.stderr}`);
    }

    const appPath = join(fixtureRepo, "build", "macos", "unsigned", "Seer.app");
    const provenancePath = join(fixtureRepo, "build", "macos", "standalone-build-provenance.json");
    assert.doesNotThrow(() =>
      loadBuildProvenance(provenancePath, { expectedRepoRoot: fixtureRepo, appPath }),
    );
    assert.deepEqual(
      readdirSync(join(fixtureRepo, "build", "macos", "unsigned"))
        .filter((name) => name.startsWith(".seer-")),
      [],
    );
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("scanner rejects mismatched provenance, app tampering, and a forged canonical repo", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-tamper-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const sourceA = join(scratch, "source-a", "Seer.app");
    const sourceB = join(scratch, "source-b", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const appPath = join(fixtureRepo, "build", "macos", "unsigned", "Seer.app");
    const provenancePath = join(fixtureRepo, "build", "macos", "standalone-build-provenance.json");
    mkdirSync(fixtureRepo, { recursive: true });
    makeFixtureApp(sourceA, "generation-a\n");
    makeFixtureApp(sourceB, "generation-b\n");
    mkdirSync(derivedData, { recursive: true });

    assert.equal(publish({ fixtureRepo, sourceApp: sourceA, derivedData }).status, 0);
    const provenanceA = readFileSync(provenancePath, "utf8");
    assert.equal(publish({ fixtureRepo, sourceApp: sourceB, derivedData }).status, 0);
    writeFileSync(provenancePath, provenanceA);
    assert.throws(
      () => loadBuildProvenance(provenancePath, { expectedRepoRoot: fixtureRepo, appPath }),
      /digest|generation|mismatch/i,
    );

    assert.equal(publish({ fixtureRepo, sourceApp: sourceB, derivedData }).status, 0);
    writeFileSync(join(appPath, "Contents", "marker.txt"), "tampered\n");
    assert.throws(
      () => loadBuildProvenance(provenancePath, { expectedRepoRoot: fixtureRepo, appPath }),
      /digest|tamper/i,
    );

    assert.equal(publish({ fixtureRepo, sourceApp: sourceB, derivedData }).status, 0);
    const forged = JSON.parse(readFileSync(provenancePath, "utf8"));
    forged.canonicalRepoRoot = scratch;
    writeFileSync(provenancePath, `${JSON.stringify(forged)}\n`);
    assert.throws(
      () => loadBuildProvenance(provenancePath, { expectedRepoRoot: fixtureRepo, appPath }),
      /repository|repo root|canonical/i,
    );
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("publisher rejects a universal private staged executable immediately before publication", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-universal-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const sourceApp = join(scratch, "source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    mkdirSync(fixtureRepo, { recursive: true });
    makeFixtureApp(sourceApp, "universal\n");
    copyFileSync("/bin/cat", join(sourceApp, "Contents", "MacOS", "Seer"));
    mkdirSync(derivedData, { recursive: true });

    const result = publish({ fixtureRepo, sourceApp, derivedData });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /lipo|exactly.*arm64|architect/i);
    const unsignedDir = join(fixtureRepo, "build", "macos", "unsigned");
    assert.deepEqual(readdirSync(unsignedDir).filter((name) => name.startsWith(".seer-stage-")), []);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("a source-copy failure removes its verified private staging directory", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-copy-failure-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const sourceApp = join(scratch, "source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    mkdirSync(fixtureRepo, { recursive: true });
    makeFixtureApp(sourceApp, "copy failure\n");
    symlinkSync("/does-not-matter", join(sourceApp, "Contents", "forbidden-link"));
    mkdirSync(derivedData, { recursive: true });

    const result = publish({ fixtureRepo, sourceApp, derivedData });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /symlink/i);
    const unsignedDir = join(fixtureRepo, "build", "macos", "unsigned");
    assert.deepEqual(readdirSync(unsignedDir).filter((name) => name.startsWith(".seer-stage-")), []);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("SIGINT during source copy rolls back the pair and exits 130", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-sigint-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const oldSource = join(scratch, "old-source", "Seer.app");
    const newSource = join(scratch, "new-source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const unsignedDir = join(fixtureRepo, "build", "macos", "unsigned");
    const provenancePath = join(fixtureRepo, "build", "macos", "standalone-build-provenance.json");
    mkdirSync(fixtureRepo, { recursive: true });
    makeFixtureApp(oldSource, "old\n");
    makeFixtureApp(newSource, "new\n");
    mkdirSync(derivedData, { recursive: true });
    assert.equal(publish({ fixtureRepo, sourceApp: oldSource, derivedData }).status, 0);
    const oldProvenance = readFileSync(provenancePath, "utf8");
    const hook = makeBlockingHook(scratch);

    const running = spawnPublisher({
      fixtureRepo,
      sourceApp: newSource,
      derivedData,
      testHook: hook.hookPath,
      testHookPhase: "during-copy",
      detached: true,
      env: hook.env,
    });
    let result;
    try {
      await waitForPath(hook.readyPath, running.child);
      process.kill(-running.child.pid, "SIGINT");
      writeFileSync(hook.releasePath, "release\n");
      result = await running.completion;
    } finally {
      await terminatePublisher(running, hook);
    }

    assert.equal(result.status, 130, `unexpected result:\n${result.stdout}\n${result.stderr}`);
    assert.equal(result.signal, null);
    assert.equal(readFileSync(join(unsignedDir, "Seer.app", "Contents", "marker.txt"), "utf8"), "old\n");
    assert.equal(readFileSync(provenancePath, "utf8"), oldProvenance);
    assert.doesNotThrow(() =>
      loadBuildProvenance(provenancePath, {
        expectedRepoRoot: fixtureRepo,
        appPath: join(unsignedDir, "Seer.app"),
      }),
    );
    assert.deepEqual(transactionArtifacts(fixtureRepo), []);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("SIGTERM between app and provenance swaps rolls back the pair and exits 143", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-sigterm-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const oldSource = join(scratch, "old-source", "Seer.app");
    const newSource = join(scratch, "new-source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const unsignedDir = join(fixtureRepo, "build", "macos", "unsigned");
    const provenancePath = join(fixtureRepo, "build", "macos", "standalone-build-provenance.json");
    mkdirSync(fixtureRepo, { recursive: true });
    makeFixtureApp(oldSource, "old\n");
    makeFixtureApp(newSource, "new\n");
    mkdirSync(derivedData, { recursive: true });
    assert.equal(publish({ fixtureRepo, sourceApp: oldSource, derivedData }).status, 0);
    const oldProvenance = readFileSync(provenancePath, "utf8");
    const hook = makeBlockingHook(scratch);

    const running = spawnPublisher({
      fixtureRepo,
      sourceApp: newSource,
      derivedData,
      testHook: hook.hookPath,
      testHookPhase: "after-app-publish",
      detached: true,
      env: hook.env,
    });
    let result;
    try {
      await waitForPath(hook.readyPath, running.child);
      process.kill(-running.child.pid, "SIGTERM");
      writeFileSync(hook.releasePath, "release\n");
      result = await running.completion;
    } finally {
      await terminatePublisher(running, hook);
    }

    assert.equal(result.status, 143, `unexpected result:\n${result.stdout}\n${result.stderr}`);
    assert.equal(result.signal, null);
    assert.equal(readFileSync(join(unsignedDir, "Seer.app", "Contents", "marker.txt"), "utf8"), "old\n");
    assert.equal(readFileSync(provenancePath, "utf8"), oldProvenance);
    assert.doesNotThrow(() =>
      loadBuildProvenance(provenancePath, {
        expectedRepoRoot: fixtureRepo,
        appPath: join(unsignedDir, "Seer.app"),
      }),
    );
    assert.deepEqual(transactionArtifacts(fixtureRepo), []);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("the next publisher recovers a SIGKILL-abandoned paired swap before staging", async () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-sigkill-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const oldSource = join(scratch, "old-source", "Seer.app");
    const newSource = join(scratch, "new-source", "Seer.app");
    const failingSource = join(scratch, "failing-source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const unsignedDir = join(fixtureRepo, "build", "macos", "unsigned");
    const provenancePath = join(fixtureRepo, "build", "macos", "standalone-build-provenance.json");
    mkdirSync(fixtureRepo, { recursive: true });
    makeFixtureApp(oldSource, "old\n");
    makeFixtureApp(newSource, "new\n");
    makeFixtureApp(failingSource, "must not publish\n");
    symlinkSync("/does-not-matter", join(failingSource, "Contents", "forbidden-link"));
    mkdirSync(derivedData, { recursive: true });
    assert.equal(publish({ fixtureRepo, sourceApp: oldSource, derivedData }).status, 0);
    const oldProvenance = readFileSync(provenancePath, "utf8");
    const hook = makeBlockingHook(scratch);

    const running = spawnPublisher({
      fixtureRepo,
      sourceApp: newSource,
      derivedData,
      testHook: hook.hookPath,
      testHookPhase: "after-app-publish",
      env: hook.env,
    });
    let killed;
    try {
      await waitForPath(hook.readyPath, running.child);
      assert.equal(running.child.kill("SIGKILL"), true);
      writeFileSync(hook.releasePath, "release\n");
      killed = await running.completion;
    } finally {
      await terminatePublisher(running, hook);
    }
    assert.equal(killed.signal, "SIGKILL");

    const recovery = publish({ fixtureRepo, sourceApp: failingSource, derivedData });
    assert.notEqual(recovery.status, 0);
    assert.match(recovery.stderr, /symlink/i);
    assert.equal(readFileSync(join(unsignedDir, "Seer.app", "Contents", "marker.txt"), "utf8"), "old\n");
    assert.equal(readFileSync(provenancePath, "utf8"), oldProvenance);
    assert.doesNotThrow(() =>
      loadBuildProvenance(provenancePath, {
        expectedRepoRoot: fixtureRepo,
        appPath: join(unsignedDir, "Seer.app"),
      }),
    );
    assert.deepEqual(transactionArtifacts(fixtureRepo), []);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("a malicious abandoned journal path is rejected without touching its canary", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-journal-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const oldSource = join(scratch, "old-source", "Seer.app");
    const newSource = join(scratch, "new-source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const macosDir = join(fixtureRepo, "build", "macos");
    const unsignedDir = join(macosDir, "unsigned");
    const provenancePath = join(macosDir, "standalone-build-provenance.json");
    const canary = join(scratch, "canary.txt");
    mkdirSync(fixtureRepo, { recursive: true });
    makeFixtureApp(oldSource, "old\n");
    makeFixtureApp(newSource, "new\n");
    mkdirSync(derivedData, { recursive: true });
    writeFileSync(canary, "do-not-touch\n");
    assert.equal(publish({ fixtureRepo, sourceApp: oldSource, derivedData }).status, 0);
    const oldProvenance = readFileSync(provenancePath, "utf8");
    writeFileSync(
      join(macosDir, ".seer-publication-transaction.json"),
      `${JSON.stringify({
        schemaVersion: 1,
        phase: "staging",
        paths: {
          publicationParent: macosDir,
          unsignedParent: unsignedDir,
          app: join(unsignedDir, "Seer.app"),
          provenance: provenancePath,
          stage: canary,
          appBackup: join(unsignedDir, `.seer-backup-${"a".repeat(32)}`),
          provenanceTemp: join(macosDir, `.seer-provenance-${"b".repeat(32)}.json`),
          provenanceBackup: join(macosDir, `.seer-provenance-backup-${"c".repeat(32)}.json`),
        },
        oldApp: { present: null, identity: null },
        oldProvenance: { present: null, identity: null },
        newAppIdentity: null,
        newProvenanceIdentity: null,
      })}\n`,
    );

    const result = publish({ fixtureRepo, sourceApp: newSource, derivedData });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /journal|transaction|path|publication parent/i);
    assert.equal(readFileSync(canary, "utf8"), "do-not-touch\n");
    assert.equal(readFileSync(join(unsignedDir, "Seer.app", "Contents", "marker.txt"), "utf8"), "old\n");
    assert.equal(readFileSync(provenancePath, "utf8"), oldProvenance);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("every torn journal temp prefix is discarded as uncommitted, with or without an authoritative primary", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-torn-journal-"));
  try {
    for (const primaryPresent of [false, true]) {
      const fixtureRepo = join(scratch, primaryPresent ? "with-primary" : "without-primary");
      const sourceApp = join(scratch, "source", "Seer.app");
      const derivedData = join(scratch, "derived-data");
      makeFixtureApp(sourceApp, "new\n");
      mkdirSync(derivedData, { recursive: true });

      const lengthFor = [
        () => 0,
        () => 1,
        (length) => Math.floor(length / 2),
        (length) => length - 1,
        (length) => length,
      ];
      for (const [index, journalLength] of lengthFor.entries()) {
        const caseRepo = `${fixtureRepo}-${index}`;
        const macosDir = join(caseRepo, "build", "macos");
        const unsignedDir = join(macosDir, "unsigned");
        const journal = `${JSON.stringify(unpreparedJournal(caseRepo))}\n`;
        mkdirSync(unsignedDir, { recursive: true });
        if (primaryPresent) {
          writeFileSync(join(macosDir, ".seer-publication-transaction.json"), journal);
        }
        writeFileSync(
          join(macosDir, ".seer-publication-transaction.new"),
          journal.slice(0, journalLength(journal.length)),
        );

        const result = publish({ fixtureRepo: caseRepo, sourceApp, derivedData });
        assert.equal(
          result.status,
          0,
          `${primaryPresent ? "primary" : "no primary"}, prefix ${index} failed:\n${result.stderr}`,
        );
        assert.equal(
          readFileSync(join(unsignedDir, "Seer.app", "Contents", "marker.txt"), "utf8"),
          "new\n",
        );
        assert.deepEqual(transactionArtifacts(caseRepo), []);
      }
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("an uncommitted temp payload is never parsed as an authoritative path record", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-untrusted-temp-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const sourceApp = join(scratch, "source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const macosDir = join(fixtureRepo, "build", "macos");
    const unsignedDir = join(macosDir, "unsigned");
    const canary = join(scratch, "canary.txt");
    const malicious = unpreparedJournal(fixtureRepo);
    malicious.paths.stage = canary;
    makeFixtureApp(sourceApp, "new\n");
    mkdirSync(unsignedDir, { recursive: true });
    mkdirSync(derivedData, { recursive: true });
    writeFileSync(canary, "do-not-touch\n");
    writeFileSync(
      join(macosDir, ".seer-publication-transaction.new"),
      `${JSON.stringify(malicious)}\n`,
    );

    const result = publish({ fixtureRepo, sourceApp, derivedData });
    assert.equal(result.status, 0, `publication failed:\n${result.stderr}`);
    assert.equal(readFileSync(canary, "utf8"), "do-not-touch\n");
    assert.equal(readFileSync(join(unsignedDir, "Seer.app", "Contents", "marker.txt"), "utf8"), "new\n");
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("a symlinked journal temp is rejected without touching its target", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-temp-symlink-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const sourceApp = join(scratch, "source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const macosDir = join(fixtureRepo, "build", "macos");
    const canary = join(scratch, "canary.txt");
    makeFixtureApp(sourceApp, "new\n");
    mkdirSync(join(macosDir, "unsigned"), { recursive: true });
    mkdirSync(derivedData, { recursive: true });
    writeFileSync(canary, "do-not-touch\n");
    symlinkSync(canary, join(macosDir, ".seer-publication-transaction.new"));

    const result = publish({ fixtureRepo, sourceApp, derivedData });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /temporary|journal|symlink/i);
    assert.equal(readFileSync(canary, "utf8"), "do-not-touch\n");
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});

test("an invalid primary journal fails closed instead of falling back to a valid temp", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "safe-publication-invalid-primary-"));
  try {
    const fixtureRepo = join(scratch, "repo");
    const oldSource = join(scratch, "old-source", "Seer.app");
    const newSource = join(scratch, "new-source", "Seer.app");
    const derivedData = join(scratch, "derived-data");
    const macosDir = join(fixtureRepo, "build", "macos");
    const unsignedDir = join(macosDir, "unsigned");
    makeFixtureApp(oldSource, "old\n");
    makeFixtureApp(newSource, "new\n");
    mkdirSync(fixtureRepo, { recursive: true });
    mkdirSync(derivedData, { recursive: true });
    assert.equal(publish({ fixtureRepo, sourceApp: oldSource, derivedData }).status, 0);
    writeFileSync(join(macosDir, ".seer-publication-transaction.json"), '{"phase":');
    writeFileSync(
      join(macosDir, ".seer-publication-transaction.new"),
      `${JSON.stringify(unpreparedJournal(fixtureRepo))}\n`,
    );

    const result = publish({ fixtureRepo, sourceApp: newSource, derivedData });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /journal|JSON/i);
    assert.equal(readFileSync(join(unsignedDir, "Seer.app", "Contents", "marker.txt"), "utf8"), "old\n");
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
