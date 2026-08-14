import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

function readText(relativePath) {
  return readFileSync(join(repoRoot, relativePath), "utf8");
}

function readJson(relativePath) {
  return JSON.parse(readText(relativePath));
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
