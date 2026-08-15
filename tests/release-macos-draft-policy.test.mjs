import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
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
const destinationRepository = "OpenCoven/seer-releases";
const workflowRef = `${sourceRepository}/.github/workflows/release-macos.yml@refs/tags/${sourceTag}`;
const workflowRun = "123";
const expectedAssets = [`Seer-v${version}-arm64.dmg`, "SHA256SUMS", "release-manifest.json"];
const marker =
  `<!-- seer-release-provenance:{"schema":1,"sourceRepository":"${sourceRepository}",` +
  `"sourceCommit":"${sourceCommit}","sourceTag":"${sourceTag}","workflowRef":"${workflowRef}",` +
  `"workflowRun":"${workflowRun}"} -->`;
const canonicalBody = `${marker}\n\nSeer ${version} for Apple Silicon Macs running macOS 14 or later.\n`;
const canonicalTitle = `Seer ${version}`;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function asset(name, id, contents = `${name}\n`, digest = true) {
  return {
    id,
    name,
    contents,
    size: Buffer.byteLength(contents),
    digest: digest ? `sha256:${sha256(contents)}` : null,
  };
}

function matchingRelease(overrides = {}) {
  return {
    id: 42,
    draft: true,
    tag: sourceTag,
    title: canonicalTitle,
    body: canonicalBody,
    updatedAt: "2026-08-15T18:00:00Z",
    assets: expectedAssets.map((name, index) => asset(name, 100 + index)),
    ...overrides,
  };
}

function writeFakeGh(scratch) {
  const script = join(scratch, "fake-gh.mjs");
  const bin = join(scratch, "bin");
  mkdirSync(bin);
  writeFileSync(
    script,
    `import { basename } from "node:path";
import { createHash } from "node:crypto";
import { readFileSync, statSync, writeFileSync } from "node:fs";

const statePath = process.env.FAKE_RELEASE_STATE;
const state = JSON.parse(readFileSync(statePath, "utf8"));
const args = process.argv.slice(2);
state.calls.push(["gh", ...args]);
const save = () => writeFileSync(statePath, JSON.stringify(state));
const fail404 = () => {
  save();
  console.error("gh: Not Found (HTTP 404)");
  process.exit(1);
};
const endpoint = args.find((arg) => arg.startsWith("repos/"));
const releaseJSON = () => ({
  id: state.release.id,
  draft: state.release.draft,
  tag_name: state.release.tag,
  name: state.release.title,
  body: state.release.body,
  updated_at: state.release.updatedAt,
  assets: state.release.assets.map(({ id, name, size, digest }) => ({ id, name, size, digest })),
});

if (args[0] === "api" && endpoint === "repos/OpenCoven/seer-releases") {
  save();
  console.log(state.visibility);
} else if (args[0] === "api" && endpoint?.includes("/releases/tags/")) {
  if (!state.release) fail404();
  save();
  const jqIndex = args.indexOf("--jq");
  if (jqIndex !== -1) {
    const jq = args[jqIndex + 1];
    if (jq.includes("draft=")) {
      const firstLine = (state.release.body ?? "").split("\\n")[0];
      const expected = ["Seer-v1.2.3-arm64.dmg", "SHA256SUMS", "release-manifest.json"];
      const valid = state.release.assets.every((item) => expected.includes(item.name));
      const complete =
        JSON.stringify(state.release.assets.map((item) => item.name).sort()) === JSON.stringify([...expected].sort());
      console.log(
        \`draft=\${state.release.draft}\\ntag=\${state.release.tag}\\nmarker=\${firstLine}\` +
          \`\\nassetCount=\${state.release.assets.length}\\nassetsValid=\${valid}\\nassetsComplete=\${complete}\`,
      );
    } else {
      process.exit(2);
    }
  } else {
    console.log(JSON.stringify(releaseJSON()));
  }
} else if (args[0] === "api" && endpoint?.includes("/git/ref/tags/")) {
  if (!state.tagExists) fail404();
  save();
  console.log("{}");
} else if (args[0] === "release" && args[1] === "create") {
  if (state.release) {
    save();
    process.exit(1);
  }
  const notesIndex = args.indexOf("--notes-file");
  const titleIndex = args.indexOf("--title");
  state.release = {
    id: 42,
    draft: true,
    tag: args[2],
    title: args[titleIndex + 1],
    body: readFileSync(args[notesIndex + 1], "utf8"),
    updatedAt: "2026-08-15T18:00:00Z",
    assets: [],
  };
  state.tagExists = true;
  save();
} else if (args[0] === "release" && args[1] === "upload") {
  const clobberIndex = args.indexOf("--clobber");
  if (!state.release || clobberIndex === -1) process.exit(2);
  let nextID = state.nextAssetID;
  for (const path of args.slice(3, clobberIndex)) {
    const name = basename(path);
    const contents = readFileSync(path);
    state.release.assets = state.release.assets.filter((item) => item.name !== name);
    state.release.assets.push({
      id: nextID++,
      name,
      contents: contents.toString("base64"),
      contentsEncoding: "base64",
      size: statSync(path).size,
      digest: \`sha256:\${createHash("sha256").update(contents).digest("hex")}\`,
    });
  }
  state.nextAssetID = nextID;
  state.etag = '"uploaded"';
  state.release.updatedAt = "2026-08-15T18:01:00Z";
  save();
} else {
  save();
  console.error(\`unsupported gh invocation: \${args.join(" ")}\`);
  process.exit(2);
}
`,
  );
  writeFileSync(join(bin, "gh"), '#!/bin/bash\nexec "${NODE_BINARY}" "${FAKE_GH_SCRIPT}" "$@"\n');
  chmodSync(join(bin, "gh"), 0o755);
  return { bin, script };
}

function writeFakeCurl(scratch, bin) {
  const script = join(scratch, "fake-curl.mjs");
  writeFileSync(
    script,
    `import { writeFileSync, readFileSync } from "node:fs";

const statePath = process.env.FAKE_RELEASE_STATE;
const state = JSON.parse(readFileSync(statePath, "utf8"));
const args = process.argv.slice(2);
state.calls.push(["curl", ...args]);
const valueAfter = (name) => {
  const index = args.lastIndexOf(name);
  return index === -1 ? null : args[index + 1];
};
const headers = args.flatMap((arg, index) => (arg === "--header" || arg === "-H" ? [args[index + 1]] : []));
const output = valueAfter("--output") ?? valueAfter("-o");
const headerPath = valueAfter("--dump-header") ?? valueAfter("-D");
const method = valueAfter("--request") ?? valueAfter("-X") ?? "GET";
const url = args.findLast((arg) => /^https?:/.test(arg));
const save = () => writeFileSync(statePath, JSON.stringify(state));
const writeResponse = (status, body, etag = state.etag) => {
  if (headerPath) writeFileSync(headerPath, \`HTTP/2 \${status}\\r\\netag: \${etag}\\r\\n\\r\\n\`);
  if (output) writeFileSync(output, body);
};
const releaseJSON = () => JSON.stringify({
  id: state.release.id,
  draft: state.release.draft,
  tag_name: state.release.tag,
  name: state.release.title,
  body: state.release.body,
  updated_at: state.release.updatedAt,
  assets: state.release.assets.map(({ id, name, size, digest }) => ({ id, name, size, digest })),
});
const assetBytes = (item) =>
  item.contentsEncoding === "base64" ? Buffer.from(item.contents, "base64") : Buffer.from(item.contents);

if (method === "GET" && url?.includes("/releases/tags/")) {
  writeResponse(200, releaseJSON());
  save();
} else if (method === "GET" && url?.includes("/releases/assets/")) {
  const id = Number(url.split("/").at(-1));
  const item = state.release.assets.find((candidate) => candidate.id === id);
  if (!item) {
    writeResponse(404, JSON.stringify({ message: "Not Found" }));
    save();
    process.exit(22);
  }
  writeResponse(200, assetBytes(item));
  save();
} else if (method === "PATCH" && url?.includes("/releases/")) {
  const ifMatch = headers.find((header) => header.startsWith("If-Match: "))?.slice("If-Match: ".length);
  if (state.etagConflictOnPatch || ifMatch !== state.etag) {
    writeResponse(412, JSON.stringify({ message: "Precondition Failed" }));
    save();
    process.exit(22);
  }
  state.release.draft = false;
  writeResponse(200, JSON.stringify({ ...JSON.parse(releaseJSON()), draft: false }));
  save();
} else {
  save();
  console.error(\`unsupported curl invocation: \${args.join(" ")}\`);
  process.exit(2);
}
`,
  );
  writeFileSync(join(bin, "curl"), '#!/bin/bash\nexec "${NODE_BINARY}" "${FAKE_CURL_SCRIPT}" "$@"\n');
  chmodSync(join(bin, "curl"), 0o755);
  return script;
}

function withHarness(callback, options = {}) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "release-draft-policy-"));
  try {
    const { bin, script: ghScript } = writeFakeGh(scratch);
    const curlScript = writeFakeCurl(scratch, bin);
    const statePath = join(scratch, "state.json");
    const releaseDir = join(scratch, "release");
    const releaseBody = join(scratch, "release-notes.md");
    const verifiedState = join(scratch, "verified-state.json");
    mkdirSync(releaseDir);
    writeFileSync(releaseBody, canonicalBody);
    for (const name of expectedAssets) writeFileSync(join(releaseDir, name), `${name}\n`);
    writeFileSync(
      statePath,
      JSON.stringify({
        visibility: "public",
        release: options.release === undefined ? matchingRelease() : options.release,
        tagExists: options.tagExists ?? true,
        etag: options.etag ?? '"draft-etag"',
        etagConflictOnPatch: false,
        nextAssetID: 200,
        calls: [],
      }),
    );

    const readState = () => JSON.parse(readFileSync(statePath, "utf8"));
    const writeState = (state) => writeFileSync(statePath, JSON.stringify(state));
    const run = (mode, env = {}) =>
      spawnSync("/bin/bash", [policyScript, mode], {
        cwd: repoRoot,
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          NODE_BINARY: process.execPath,
          FAKE_GH_SCRIPT: ghScript,
          FAKE_CURL_SCRIPT: curlScript,
          FAKE_RELEASE_STATE: statePath,
          GITHUB_API_URL: "https://api.github.test",
          GH_TOKEN: "test-token",
          GH_REPO: destinationRepository,
          SOURCE_REPOSITORY: sourceRepository,
          SOURCE_COMMIT: sourceCommit,
          SOURCE_TAG: sourceTag,
          WORKFLOW_REF: workflowRef,
          WORKFLOW_RUN: workflowRun,
          VERSION: version,
          RELEASE_DIR: releaseDir,
          RELEASE_BODY: releaseBody,
          VERIFIED_STATE: verifiedState,
          STATE_WORK_DIR: scratch,
          ...env,
        },
      });

    return callback({ run, readState, writeState, releaseDir, releaseBody, verifiedState });
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

test("published releases are rejected without mutation", () => {
  withHarness(({ run, readState }) => {
    const result = run("preflight");
    const state = readState();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /existing published release/);
    assert.ok(!state.calls.some((call) => call.includes("PATCH")));
  }, { release: matchingRelease({ draft: false }) });
});

test("preflight rejects modified title and any foreign or trailing release body", () => {
  for (const release of [
    matchingRelease({ title: `${canonicalTitle} modified` }),
    matchingRelease({ body: `${canonicalBody}foreign trailing note\n` }),
    matchingRelease({ body: canonicalBody.replace(sourceCommit, "b".repeat(40)) }),
  ]) {
    withHarness(({ run, readState }) => {
      const result = run("preflight");
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /canonical (title|body)|provenance/);
      assert.ok(!readState().calls.some((call) => call.includes("PATCH")));
    }, { release });
  }
});

test("drafts containing foreign assets are rejected", () => {
  withHarness(({ run, readState }) => {
    const result = run("preflight");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /foreign release asset/);
    assert.ok(!readState().calls.some((call) => call.includes("PATCH")));
  }, { release: matchingRelease({ assets: [asset("foreign-debug-symbols.zip", 999)] }) });
});

test("upload resumes only a canonical draft and clobbers the allowlisted assets", () => {
  withHarness(({ run, readState, writeState }) => {
    const state = readState();
    state.release.assets = [asset("SHA256SUMS", 101)];
    writeState(state);
    const result = run("upload");
    assert.equal(result.status, 0, result.stderr);
    const after = readState();
    assert.deepEqual(after.release.assets.map(({ name }) => name).sort(), [...expectedAssets].sort());
    assert.ok(after.calls.some((call) => call[0] === "gh" && call[1] === "release" && call[2] === "upload"));
    assert.ok(!after.calls.some((call) => call.includes("delete") || call.includes("DELETE")));
  });
});

test("upload rejects local notes with trailing or foreign bytes", () => {
  withHarness(({ run, releaseBody, readState }) => {
    writeFileSync(releaseBody, `${canonicalBody}\n`);
    const result = run("upload");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /canonical notes|release body/);
    assert.ok(!readState().calls.some((call) => call[0] === "gh" && call[1] === "release"));
  });
});

test("capture emits exact release, metadata, asset, byte, and notes bindings", () => {
  withHarness(({ run, verifiedState }) => {
    const result = run("capture");
    assert.equal(result.status, 0, result.stderr);
    const captured = JSON.parse(readFileSync(verifiedState, "utf8"));
    assert.equal(captured.releaseId, 42);
    assert.equal(captured.etag, '"draft-etag"');
    assert.equal(captured.updatedAt, "2026-08-15T18:00:00Z");
    assert.equal(captured.tagName, sourceTag);
    assert.equal(captured.title, canonicalTitle);
    assert.equal(captured.body, canonicalBody);
    assert.equal(captured.notes.sha256, sha256(canonicalBody));
    assert.deepEqual(captured.assets.map(({ id }) => id), [100, 101, 102]);
    assert.deepEqual(
      captured.assets.map(({ name, size, sha256: digest }) => ({ name, size, digest })),
      expectedAssets.map((name) => ({ name, size: Buffer.byteLength(`${name}\n`), digest: sha256(`${name}\n`) })),
    );
  });
});

test("publish fails closed when title, notes body, asset id, size, or digest changes", () => {
  const mutations = [
    ["title", (state) => { state.release.title += " changed"; }],
    ["body", (state) => { state.release.body += "foreign\n"; }],
    ["asset id", (state) => { state.release.assets[0].id = 999; }],
    ["asset size", (state) => { state.release.assets[0].size += 1; }],
    ["asset digest", (state) => { state.release.assets[0].digest = `sha256:${"f".repeat(64)}`; }],
  ];

  for (const [name, mutate] of mutations) {
    withHarness(({ run, readState, writeState }) => {
      assert.equal(run("capture").status, 0);
      const state = readState();
      mutate(state);
      writeState(state);
      const result = run("publish");
      assert.notEqual(result.status, 0, `${name} mutation must fail`);
      const after = readState();
      assert.equal(after.release.draft, true);
      assert.ok(!after.calls.some((call) => call.includes("PATCH")));
    });
  }
});

test("publish detects modified local notes after capture", () => {
  withHarness(({ run, releaseBody, readState }) => {
    assert.equal(run("capture").status, 0);
    writeFileSync(releaseBody, `${canonicalBody}local mutation\n`);
    const result = run("publish");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /notes/);
    assert.equal(readState().release.draft, true);
  });
});

test("publish re-downloads and re-hashes exact asset IDs when API digests are unavailable", () => {
  withHarness(({ run, readState, writeState }) => {
    const state = readState();
    for (const item of state.release.assets) item.digest = null;
    writeState(state);
    assert.equal(run("capture").status, 0);
    const result = run("publish");
    assert.equal(result.status, 0, result.stderr);
    const after = readState();
    const assetDownloads = after.calls.filter(
      (call) => call[0] === "curl" && call.some((arg) => arg.includes("/releases/assets/")),
    );
    assert.equal(assetDownloads.length, expectedAssets.length * 2);
  });
});

test("publish rejects changed remote bytes when API digests are unavailable", () => {
  withHarness(({ run, readState, writeState }) => {
    const state = readState();
    for (const item of state.release.assets) item.digest = null;
    writeState(state);
    assert.equal(run("capture").status, 0);

    const changed = readState();
    const original = changed.release.assets[0].contents;
    changed.release.assets[0].contents = original.replace(/^./, original[0] === "X" ? "Y" : "X");
    writeState(changed);

    const result = run("publish");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /fresh download|verified bytes/);
    assert.equal(readState().release.draft, true);
  });
});

test("publish fails closed on an If-Match precondition conflict", () => {
  withHarness(({ run, readState, writeState }) => {
    assert.equal(run("capture").status, 0);
    const state = readState();
    state.etagConflictOnPatch = true;
    writeState(state);
    const result = run("publish");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /precondition|conditional|publish/i);
    assert.equal(readState().release.draft, true);
  });
});

test("exact captured state publishes by release ID with conditional REST PATCH only", () => {
  withHarness(({ run, readState }) => {
    assert.equal(run("capture").status, 0);
    const result = run("publish");
    assert.equal(result.status, 0, result.stderr);
    const state = readState();
    assert.equal(state.release.draft, false);
    const patch = state.calls.find((call) => call[0] === "curl" && call.includes("PATCH"));
    assert.ok(patch);
    assert.ok(patch.some((arg) => arg.endsWith("/releases/42")));
    assert.ok(patch.includes('If-Match: "draft-etag"'));
    assert.ok(!state.calls.some((call) => call[0] === "gh" && call[1] === "release" && call[2] === "edit"));
    assert.ok(!state.calls.some((call) => call.includes("delete") || call.includes("DELETE")));
  });
});
