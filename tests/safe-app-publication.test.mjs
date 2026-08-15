import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
import { spawn, spawnSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
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

function publicationArgs({ fixtureRepo, sourceApp, derivedData, testHook, testFailpoint }) {
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
  const { env = {} } = options;
  const child = spawn("/usr/bin/python3", publicationArgs(options), {
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
  return new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
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
