import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
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

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const helperPath = join(repoRoot, "scripts", "publish-macos-app.py");

function makeFixtureApp(path, marker) {
  mkdirSync(join(path, "Contents", "MacOS"), { recursive: true });
  writeFileSync(join(path, "Contents", "MacOS", "Seer"), marker, { mode: 0o755 });
  writeFileSync(join(path, "Contents", "Info.plist"), "<plist/>\n");
}

function publish({ fixtureRepo, sourceApp, derivedData, testHook, env = {} }) {
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
  return spawnSync("/usr/bin/python3", args, {
    encoding: "utf8",
    env: { ...process.env, ...env },
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
      readFileSync(join(unsignedDir, "Seer.app", "Contents", "MacOS", "Seer"), "utf8"),
      "new executable\n",
    );
    assert.deepEqual(
      readdirSync(unsignedDir).filter((name) => name.startsWith(".seer-")),
      [],
      "successful publication must remove its private staging and backup leaves",
    );

    const provenancePath = join(fixtureRepo, "build", "macos", "standalone-build-provenance.json");
    const provenance = JSON.parse(readFileSync(provenancePath, "utf8"));
    assert.equal(provenance.schemaVersion, 1);
    assert.equal(provenance.canonicalRepoRoot, fixtureRepo);
    assert.equal(provenance.effectiveDerivedDataPath, derivedData);
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
    assert.equal(readFileSync(join(heldUnsignedDir, "Seer.app", "Contents", "MacOS", "Seer"), "utf8"), "old executable\n");
    assert.ok(
      readdirSync(heldUnsignedDir).some((name) => name.startsWith(".seer-stage-")),
      "the private staging directory should be retained for scoped cleanup after uncertainty",
    );
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
