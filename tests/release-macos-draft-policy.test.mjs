import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const policyScript = join(repoRoot, "scripts", "release-macos-draft.sh");
const sourceCommit = "a".repeat(40);
const sourceTag = "v1.2.3";
const version = "1.2.3";
const sourceRepository = "OpenCoven/seer";
const workflowRef = `${sourceRepository}/.github/workflows/release-macos.yml@refs/tags/${sourceTag}`;
const workflowRun = "123";
const expectedAssets = [`Seer-v${version}-arm64.dmg`, "SHA256SUMS", "release-manifest.json"];
const marker =
  `<!-- seer-release-provenance:{"schema":1,"sourceRepository":"${sourceRepository}",` +
  `"sourceCommit":"${sourceCommit}","sourceTag":"${sourceTag}","workflowRef":"${workflowRef}",` +
  `"workflowRun":"${workflowRun}"} -->`;

function withScratch(callback) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "release-draft-policy-"));
  try {
    return callback(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

function writeFakeGh(scratch) {
  const fakeGh = join(scratch, "fake-gh.mjs");
  const bin = join(scratch, "bin");
  mkdirSync(bin);
  writeFileSync(
    fakeGh,
    `import { basename } from "node:path";
import { readFileSync, writeFileSync } from "node:fs";

const statePath = process.env.FAKE_GH_STATE;
const state = JSON.parse(readFileSync(statePath, "utf8"));
const args = process.argv.slice(2);
state.calls.push(args);
const save = () => writeFileSync(statePath, JSON.stringify(state));
const fail404 = () => {
  save();
  console.error("gh: Not Found (HTTP 404)");
  process.exit(1);
};
const endpoint = args.find((arg) => arg.startsWith("repos/"));
const jqIndex = args.indexOf("--jq");
const jq = jqIndex === -1 ? "" : args[jqIndex + 1];

if (args[0] === "api" && endpoint === "repos/OpenCoven/seer-releases") {
  save();
  console.log(state.visibility);
} else if (args[0] === "api" && endpoint?.includes("/releases/tags/")) {
  if (!state.release) fail404();
  save();
  if (jq.includes("draft=")) {
    const firstLine = (state.release.body ?? "").split("\\n")[0];
    const expected = ["Seer-v1.2.3-arm64.dmg", "SHA256SUMS", "release-manifest.json"];
    const valid = state.release.assets.every((asset) => expected.includes(asset));
    const complete =
      JSON.stringify([...state.release.assets].sort()) === JSON.stringify([...expected].sort());
    console.log(
      \`draft=\${state.release.draft}\\ntag=\${state.release.tag}\\nmarker=\${firstLine}\` +
        \`\\nassetCount=\${state.release.assets.length}\\nassetsValid=\${valid}\\nassetsComplete=\${complete}\`,
    );
  } else if (jq === ".assets[].name") {
    process.stdout.write(state.release.assets.map((asset) => \`\${asset}\\n\`).join(""));
  } else {
    console.error(\`unsupported release jq: \${jq}\`);
    process.exit(2);
  }
} else if (args[0] === "api" && endpoint?.includes("/git/ref/tags/")) {
  if (!state.tagExists) fail404();
  save();
  console.log("{}");
} else if (args[0] === "release" && args[1] === "create") {
  if (state.release) {
    save();
    console.error("release already exists");
    process.exit(1);
  }
  const notesIndex = args.indexOf("--notes-file");
  state.release = {
    draft: true,
    tag: args[2],
    body: readFileSync(args[notesIndex + 1], "utf8"),
    assets: [],
  };
  state.tagExists = true;
  save();
} else if (args[0] === "release" && args[1] === "upload") {
  const clobberIndex = args.indexOf("--clobber");
  if (!state.release || clobberIndex === -1) process.exit(2);
  for (const path of args.slice(3, clobberIndex)) {
    const name = basename(path);
    state.release.assets = state.release.assets.filter((asset) => asset !== name);
    state.release.assets.push(name);
  }
  save();
} else if (args[0] === "release" && args[1] === "edit") {
  if (!state.release || !args.includes("--draft=false")) process.exit(2);
  state.release.draft = false;
  save();
} else {
  save();
  console.error(\`unsupported gh invocation: \${args.join(" ")}\`);
  process.exit(2);
}
`,
  );
  const wrapper = join(bin, "gh");
  writeFileSync(wrapper, '#!/bin/bash\nexec "${NODE_BINARY}" "${FAKE_GH_SCRIPT}" "$@"\n');
  chmodSync(wrapper, 0o755);
  return { bin, fakeGh };
}

function runPolicy(mode, { release = null, tagExists = false, createLocalAssets = false } = {}) {
  return withScratch((scratch) => {
    const { bin, fakeGh } = writeFakeGh(scratch);
    const statePath = join(scratch, "state.json");
    const releaseDir = join(scratch, "release");
    const releaseBody = join(scratch, "release-notes.md");
    writeFileSync(statePath, JSON.stringify({ visibility: "public", release, tagExists, calls: [] }));
    writeFileSync(releaseBody, `${marker}\n\nSeer ${version}\n`);
    if (createLocalAssets) {
      mkdirSync(releaseDir);
      for (const asset of expectedAssets) writeFileSync(join(releaseDir, asset), `${asset}\n`);
    }

    const result = spawnSync("/bin/bash", [policyScript, mode], {
      cwd: repoRoot,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        NODE_BINARY: process.execPath,
        FAKE_GH_SCRIPT: fakeGh,
        FAKE_GH_STATE: statePath,
        GH_REPO: "OpenCoven/seer-releases",
        SOURCE_REPOSITORY: sourceRepository,
        SOURCE_COMMIT: sourceCommit,
        SOURCE_TAG: sourceTag,
        WORKFLOW_REF: workflowRef,
        WORKFLOW_RUN: workflowRun,
        VERSION: version,
        RELEASE_DIR: releaseDir,
        RELEASE_BODY: releaseBody,
      },
    });
    return { result, state: JSON.parse(readFileSync(statePath, "utf8")) };
  });
}

function matchingRelease(overrides = {}) {
  return {
    draft: true,
    tag: sourceTag,
    body: `${marker}\n\nExisting notes\n`,
    assets: [],
    ...overrides,
  };
}

test("published releases are rejected without mutation", () => {
  const { result, state } = runPolicy("preflight", {
    release: matchingRelease({ draft: false }),
    tagExists: true,
  });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /existing published release/);
  assert.ok(!state.calls.some((args) => args[0] === "release"));
});

test("drafts with mismatched provenance markers are rejected", () => {
  const { result, state } = runPolicy("preflight", {
    release: matchingRelease({ body: `${marker.replace(sourceCommit, "b".repeat(40))}\n` }),
    tagExists: true,
  });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /provenance marker does not match/);
  assert.ok(!state.calls.some((args) => args[0] === "release"));
});

test("drafts containing foreign assets are rejected", () => {
  const { result, state } = runPolicy("preflight", {
    release: matchingRelease({ assets: ["foreign-debug-symbols.zip"] }),
    tagExists: true,
  });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /foreign release asset/);
  assert.ok(!state.calls.some((args) => args[0] === "release"));
});

test("a matching partial draft is resumed with allowlisted clobber uploads", () => {
  const { result, state } = runPolicy("upload", {
    release: matchingRelease({ assets: ["SHA256SUMS"] }),
    tagExists: true,
    createLocalAssets: true,
  });

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(state.release.assets.sort(), [...expectedAssets].sort());
  assert.ok(state.calls.some((args) => args[0] === "release" && args[1] === "upload" && args.includes("--clobber")));
  assert.ok(!state.calls.some((args) => args[0] === "release" && args[1] === "create"));
  assert.ok(!state.calls.some((args) => args.includes("delete") || args.includes("DELETE")));
});

test("an absent release is created as a provenance-bound draft", () => {
  const { result, state } = runPolicy("upload", { createLocalAssets: true });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(state.release.draft, true);
  assert.equal(state.release.body.split("\n")[0], marker);
  assert.deepEqual(state.release.assets.sort(), [...expectedAssets].sort());
  assert.ok(state.calls.some((args) => args[0] === "release" && args[1] === "create" && args.includes("--draft")));
});
