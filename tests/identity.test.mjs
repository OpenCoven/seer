import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import test from "node:test";
import yaml from "js-yaml";
import { STANDALONE_SAFE_TEST_FILES } from "../scripts/run-standalone-tests.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

function readText(relativePath) {
  return readFileSync(join(repoRoot, relativePath), "utf8");
}

function readJson(relativePath) {
  return JSON.parse(readText(relativePath));
}

const ciWorkflows = [
  { name: "standalone-ci.yml", path: ".github/workflows/standalone-ci.yml" },
  { name: "release-macos.yml", path: ".github/workflows/release-macos.yml" },
];

/**
 * Returns every job step across `workflowSource` whose string `run:` value
 * is exactly `exactRun` — a plain YAML-parsed equality check, not a scan of
 * shell tokens, so there is nothing here that needs to understand quoting,
 * comments, or control operators the way the deleted
 * tests/helpers/workflow-node-test-invocations.mjs shell tokenizer did.
 */
function findStepsByExactRun(workflowSource, exactRun) {
  const workflow = yaml.load(workflowSource);
  const steps = [];
  if (typeof workflow !== "object" || workflow === null || typeof workflow.jobs !== "object" || workflow.jobs === null) {
    return steps;
  }
  for (const job of Object.values(workflow.jobs)) {
    if (typeof job !== "object" || job === null || !Array.isArray(job.steps)) continue;
    for (const step of job.steps) {
      if (typeof step === "object" && step !== null && step.run === exactRun) {
        steps.push(step);
      }
    }
  }
  return steps;
}

function gitChangeSet() {
  return execFileSync(
    "git",
    ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
    { cwd: repoRoot, encoding: "utf8" },
  )
    .split("\0")
    .filter(Boolean);
}

function stagedGitlinks() {
  return execFileSync("git", ["ls-files", "--stage", "-z"], {
    cwd: repoRoot,
    encoding: "utf8",
  })
    .split("\0")
    .filter(Boolean)
    .flatMap((entry) => {
      const separator = entry.indexOf("\t");
      const mode = entry.slice(0, separator).split(" ", 1)[0];
      return mode === "160000" ? [entry.slice(separator + 1)] : [];
    });
}

function nestedGitEntries(directory = repoRoot, relativeDirectory = "") {
  const found = [];

  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const relativePath = relativeDirectory
      ? `${relativeDirectory}/${entry.name}`
      : entry.name;

    if (entry.name === ".git") {
      if (relativeDirectory) {
        found.push(relativePath);
      }
      continue;
    }

    if (!entry.isSymbolicLink() && entry.isDirectory()) {
      found.push(...nestedGitEntries(join(directory, entry.name), relativePath));
    }
  }

  return found;
}

test("Seer identity files are branded correctly", () => {
  const packageJson = readJson("package.json");
  const packageLock = readJson("package-lock.json");
  const traySource = readText("main/services/tray.ts");

  assert.equal(packageJson.id, "6f424aca");
  assert.equal(packageJson.name, "seer");
  assert.equal(packageJson.productName, "Seer");

  assert.equal(packageLock.name, "seer");
  assert.equal(packageLock.packages[""].name, "seer");

  assert.match(
    traySource,
    /const TRAY_GUID = "b2ffcd25-6e8c-4df5-899f-0bf17b7dc7d1";/,
  );
});

test("Glaze remix provenance stays intact", () => {
  const packageJson = readJson("package.json");

  assert.deepStrictEqual(packageJson.glaze.remix, {
    grantId: "5ae8fbb1-a558-4c99-b046-db06c54c988a",
    mode: "remix",
    attribution: false,
    sourceStoreAppId: "28bb9188-5063-4f9f-8b4a-d93df0ac2197",
    sourcePublicId: "4Z5mAG",
    sourceVersionId: "978af97f-aa32-4069-b733-d0849967fa20",
    sourceVersion: "6.0.0",
    sourceDisplayName: "Stay Awake",
    sourceAuthorId: "5c8368d0-a2d3-4642-b499-d3428dd3b0bf",
    sourceAuthorName: "Samuel Kraft",
    sourceAuthorUsername: "samuel",
    rootStoreAppId: "28bb9188-5063-4f9f-8b4a-d93df0ac2197",
    createdAt: "2026-08-08T17:09:11.443Z",
    setup: {
      status: "ready",
      updatedAt: "2026-08-08T17:09:20.607Z",
    },
  });
});

test("User-facing surfaces are rebranded to Seer", () => {
  const files = [
    "main/index.ts",
    "main/handlers/app.ts",
    "main/services/tray.ts",
    "main-window.html",
  ];

  for (const file of files) {
    const source = readText(file);
    for (const forbidden of ["Stay Awake", "Stay Awake Remix", "Agent Sentinel"]) {
      assert.ok(
        !source.includes(forbidden),
        `${file} still contains ${forbidden}`,
      );
    }
  }

  assert.match(readText("main/index.ts"), /label:\s*"Seer"/);
  assert.match(
    readText("main/handlers/app.ts"),
    /return\s*\{[\s\S]*name:\s*"Seer"/,
  );
  assert.match(readText("main/services/tray.ts"), /label:\s*"Open Seer"/);
  assert.match(readText("main/services/tray.ts"), /label:\s*"Quit Seer"/);
  assert.match(readText("main-window.html"), /<title>Seer<\/title>/);
});

test("UpdateService is constructed with the real packaged app version, not a hardcoded stand-in", () => {
  const source = readText("main/index.ts");

  assert.match(
    source,
    /new UpdateService\(\{\s*\n\s*currentVersion:\s*app\.getVersion\(\)/,
    "main/index.ts must pass app.getVersion() as UpdateService's currentVersion so update comparisons reflect the actual packaged app version",
  );
  assert.ok(
    !/currentVersion:\s*"1\.0\.0"/.test(source),
    "main/index.ts must never hardcode UpdateService's currentVersion to a fixed string",
  );
});

for (const { name, path } of ciWorkflows) {
  test(`${name}: invokes the standalone-safe test suite via the shared npm script`, () => {
    // Both workflows used to hand-maintain their own explicit "node --test"
    // file list; verifying a given file was registered required parsing
    // that shell text back out of the YAML. Now both workflows invoke the
    // exact same fixed, argument-free command, so verifying that is a
    // single exact-string comparison against the parsed YAML `run:` value -
    // no shell parsing required. *Which* files that command runs is
    // asserted separately below, directly against
    // scripts/run-standalone-tests.mjs's exported list.
    const source = readText(path);
    const steps = findStepsByExactRun(source, "npm run test:standalone-safe");
    assert.equal(
      steps.length,
      1,
      `expected exactly one step in ${name} whose run: value is exactly "npm run test:standalone-safe" ` +
        "(a bare package-script invocation, not a variant with an inline pipe, comment, or additional " +
        "shell command)",
    );
  });
}

test("scripts/run-standalone-tests.mjs still registers tests/standalone-build-gate-serialization.test.mjs", () => {
  // tests/standalone-build-gate-serialization.test.mjs used to assert its
  // own registration in each workflow's explicit "node --test" file list,
  // but that self-check only ran if a worker process was still executing
  // that very file - if a future edit dropped the file from the shared
  // list, the assertion guarding against exactly that removal would
  // disappear along with it, and CI would stay green. This file
  // (tests/identity.test.mjs) is itself registered in
  // scripts/run-standalone-tests.mjs's STANDALONE_SAFE_TEST_FILES - the one
  // list both workflows run via `npm run test:standalone-safe`, asserted
  // above - so it keeps working even if
  // tests/standalone-build-gate-serialization.test.mjs is ever removed from
  // that list.
  assert.ok(
    STANDALONE_SAFE_TEST_FILES.includes("tests/standalone-build-gate-serialization.test.mjs"),
    "scripts/run-standalone-tests.mjs's STANDALONE_SAFE_TEST_FILES must directly list " +
      "tests/standalone-build-gate-serialization.test.mjs (not merely rely on it being reachable " +
      "through some other glob or transitively-included file)",
  );
});

test("No forbidden generated artifacts are in the change set", () => {
  const changeSet = gitChangeSet();
  const forbiddenComponents = new Set([
    ".glaze",
    ".glaze-core",
    ".glaze_memory",
    ".mcp.json",
    ".icon-hash",
    "node_modules",
    "build",
    ".git",
  ]);
  const forbidden = changeSet.filter(
    (path) =>
      path
        .split("/")
        .some((component) => forbiddenComponents.has(component)) ||
      path.endsWith(".log"),
  );

  assert.deepStrictEqual(forbidden, []);
  assert.deepStrictEqual(nestedGitEntries(), []);
  assert.deepStrictEqual(stagedGitlinks(), []);
});
