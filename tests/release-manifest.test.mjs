import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  buildManifest,
  formatChecksum,
  serializeManifest,
  writeReleaseMetadata,
} from "../scripts/write-release-manifest.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const manifestScript = join(repoRoot, "scripts", "write-release-manifest.mjs");

function withScratch(prefix, callback) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", prefix));
  try {
    return callback(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

function validInput(scratch, overrides = {}) {
  const dmgPath = join(scratch, "Seer-v1.0.0-arm64.dmg");
  writeFileSync(dmgPath, Buffer.from("deterministic dmg bytes\n"));
  return {
    version: "1.0.0",
    sourceCommit: "a".repeat(40),
    workflowRun: "123",
    dmgPath,
    notarization: "accepted",
    ...overrides,
  };
}

test("release manifest contains only deterministic public traceability fields", () => {
  withScratch("release-manifest-shape-", (scratch) => {
    const input = validInput(scratch);
    const bytes = readFileSync(input.dmgPath);
    const manifest = buildManifest(input);

    assert.deepEqual(Object.keys(manifest), [
      "artifacts",
      "bundleIdentifier",
      "notarization",
      "sourceCommit",
      "version",
      "workflowRun",
    ]);
    assert.deepEqual(manifest.artifacts, [
      {
        name: "Seer-v1.0.0-arm64.dmg",
        sha256: createHash("sha256").update(bytes).digest("hex"),
        size: bytes.length,
      },
    ]);
    assert.deepEqual(Object.keys(manifest.artifacts[0]), ["name", "sha256", "size"]);
    assert.equal(manifest.bundleIdentifier, "ai.opencoven.seer");
    assert.equal(manifest.notarization, "accepted");
    assert.equal(manifest.sourceCommit, "a".repeat(40));
    assert.equal(manifest.version, "1.0.0");
    assert.equal(manifest.workflowRun, "123");
    assert.doesNotMatch(JSON.stringify(manifest), /Users|APPLE_|password|token|release-manifest-shape/i);
  });
});

test("manifest JSON is stable two-space output with one trailing newline", () => {
  withScratch("release-manifest-json-", (scratch) => {
    const manifest = buildManifest(validInput(scratch));
    const serialized = serializeManifest(manifest);

    assert.equal(serialized, `${JSON.stringify(manifest, null, 2)}\n`);
    assert.ok(serialized.includes('\n  "artifacts": [\n'));
    assert.ok(!serialized.endsWith("\n\n"));
  });
});

test("SHA256SUMS is exactly lowercase hash, two spaces, filename, and newline", () => {
  withScratch("release-manifest-checksum-", (scratch) => {
    const input = validInput(scratch);
    const artifact = buildManifest(input).artifacts[0];

    assert.equal(
      formatChecksum(artifact),
      `${createHash("sha256").update(readFileSync(input.dmgPath)).digest("hex")}  Seer-v1.0.0-arm64.dmg\n`,
    );
  });
});

test("metadata writer emits only the approved deterministic files", () => {
  withScratch("release-manifest-write-", (scratch) => {
    const input = validInput(scratch);
    const outputDirectory = join(scratch, "release");
    mkdirSync(outputDirectory);
    const manifestPath = join(outputDirectory, "release-manifest.json");
    const checksumsPath = join(outputDirectory, "SHA256SUMS");

    const manifest = writeReleaseMetadata({ ...input, manifestPath, checksumsPath });

    assert.equal(readFileSync(manifestPath, "utf8"), serializeManifest(manifest));
    assert.equal(readFileSync(checksumsPath, "utf8"), formatChecksum(manifest.artifacts[0]));
  });
});

test("CLI requires explicit arguments and writes byte-identical metadata", () => {
  withScratch("release-manifest-cli-", (scratch) => {
    const input = validInput(scratch);
    const manifestPath = join(scratch, "release-manifest.json");
    const checksumsPath = join(scratch, "SHA256SUMS");
    const result = spawnSync(
      process.execPath,
      [
        manifestScript,
        "--version",
        input.version,
        "--source-commit",
        input.sourceCommit,
        "--workflow-run",
        input.workflowRun,
        "--notarization",
        input.notarization,
        "--artifact",
        input.dmgPath,
        "--manifest",
        manifestPath,
        "--checksums",
        checksumsPath,
      ],
      { encoding: "utf8" },
    );

    assert.equal(result.status, 0, result.stderr);
    const manifest = buildManifest(input);
    assert.equal(readFileSync(manifestPath, "utf8"), serializeManifest(manifest));
    assert.equal(readFileSync(checksumsPath, "utf8"), formatChecksum(manifest.artifacts[0]));
    assert.equal(result.stdout, "");
  });
});

test("strict stable versions reject prefixes, prereleases, metadata, and leading zeros", () => {
  withScratch("release-manifest-version-", (scratch) => {
    for (const version of [
      "",
      "v1.0.0",
      "1.0",
      "1.0.0-beta.1",
      "1.0.0+build.1",
      "01.0.0",
      "1.00.0",
      "1.0.00",
      "1.0.0 ",
    ]) {
      assert.throws(
        () => buildManifest(validInput(scratch, { version })),
        /version must be a stable semantic version/,
        version,
      );
    }
  });
});

test("artifact filename must exactly match the validated version", () => {
  withScratch("release-manifest-name-", (scratch) => {
    const wrongName = join(scratch, "Seer-v2.0.0-arm64.dmg");
    writeFileSync(wrongName, "wrong version\n");

    assert.throws(
      () => buildManifest(validInput(scratch, { dmgPath: wrongName })),
      /artifact must be named exactly Seer-v1\.0\.0-arm64\.dmg/,
    );
  });
});

test("artifact must be a real regular file rather than a symlink", () => {
  withScratch("release-manifest-artifact-", (scratch) => {
    const input = validInput(scratch);
    const realPath = join(scratch, "real.dmg");
    writeFileSync(realPath, "real bytes\n");
    rmSync(input.dmgPath);
    symlinkSync(realPath, input.dmgPath);

    assert.throws(() => buildManifest(input), /artifact must be a regular file and not a symlink/);
  });
});

test("source commit must be exactly one lowercase 40-character SHA", () => {
  withScratch("release-manifest-sha-", (scratch) => {
    for (const sourceCommit of [
      "a".repeat(39),
      "a".repeat(41),
      "A".repeat(40),
      "g".repeat(40),
      `${"a".repeat(40)}\n`,
    ]) {
      assert.throws(
        () => buildManifest(validInput(scratch, { sourceCommit })),
        /source commit must be a lowercase 40-character SHA/,
        sourceCommit,
      );
    }
  });
});

test("workflow run must be a positive canonical decimal identifier", () => {
  withScratch("release-manifest-workflow-", (scratch) => {
    for (const workflowRun of ["", "0", "00", "0123", "-1", "1.0", "abc", "123\n", 123]) {
      assert.throws(
        () => buildManifest(validInput(scratch, { workflowRun })),
        /workflow run must be a positive decimal identifier/,
        String(workflowRun),
      );
    }
  });
});

test("notarization accepts only the public accepted state", () => {
  withScratch("release-manifest-notarization-", (scratch) => {
    for (const notarization of ["Accepted", "invalid", "in progress", "", true]) {
      assert.throws(
        () => buildManifest(validInput(scratch, { notarization })),
        /notarization must be exactly accepted/,
        String(notarization),
      );
    }
  });
});

test("CLI rejects missing, duplicate, and unknown arguments without outputs", () => {
  withScratch("release-manifest-cli-invalid-", (scratch) => {
    const input = validInput(scratch);
    const manifestPath = join(scratch, "release-manifest.json");
    const checksumsPath = join(scratch, "SHA256SUMS");
    const common = [
      "--version",
      input.version,
      "--source-commit",
      input.sourceCommit,
      "--workflow-run",
      input.workflowRun,
      "--notarization",
      input.notarization,
      "--artifact",
      input.dmgPath,
      "--manifest",
      manifestPath,
      "--checksums",
      checksumsPath,
    ];

    for (const args of [
      common.slice(0, -2),
      [...common, "--version", "1.0.0"],
      [...common, "--unexpected", "value"],
    ]) {
      rmSync(manifestPath, { force: true });
      rmSync(checksumsPath, { force: true });
      const result = spawnSync(process.execPath, [manifestScript, ...args], { encoding: "utf8" });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /error:/);
      assert.throws(() => readFileSync(manifestPath), /ENOENT/);
      assert.throws(() => readFileSync(checksumsPath), /ENOENT/);
    }
  });
});
