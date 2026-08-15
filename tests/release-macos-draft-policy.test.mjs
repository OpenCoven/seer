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
const workflowAttempt = "1";
const releaseWriter = { id: 7, login: "release-writer" };
const releaseRepoCommit = "c".repeat(40);
const lockTagObjectSHA = "d".repeat(40);
const lockRef = `refs/tags/seer-release-lock-${sourceTag}`;
function lockOwnership(overrides = {}) {
  const metadata = {
    lockSchema: 1,
    sourceRepository,
    sourceCommit,
    sourceTag,
    workflowRef,
    workflowRun,
    workflowAttempt,
    ...overrides,
  };
  return {
    tag: `seer-release-lock-${metadata.sourceTag}-${metadata.sourceCommit}-run-${metadata.workflowRun}-attempt-${metadata.workflowAttempt}`,
    message: `${JSON.stringify(metadata)}\n`,
  };
}
const { tag: lockTagName, message: lockMessage } = lockOwnership();
function lockFixture(overrides = {}, sha = "e".repeat(40)) {
  const ownership = lockOwnership(overrides);
  return {
    ref: lockRef,
    sha,
    tagObject: {
      sha,
      tag: ownership.tag,
      message: ownership.message,
      object: { type: "commit", sha: releaseRepoCommit },
    },
  };
}
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
    uploader: releaseWriter,
  };
}

function matchingRelease(overrides = {}) {
  return {
    id: 42,
    draft: true,
    prerelease: false,
    tag: sourceTag,
    title: canonicalTitle,
    body: canonicalBody,
    updatedAt: "2026-08-15T18:00:00Z",
    immutable: false,
    author: releaseWriter,
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
  prerelease: state.release.prerelease,
  tag_name: state.release.tag,
  name: state.release.title,
  body: state.release.body,
  updated_at: state.release.updatedAt,
  immutable: state.release.immutable,
  author: state.release.author,
  assets: state.release.assets.map(({ id, name, size, digest, uploader }) => ({
    id, name, size, digest, uploader
  })),
});

if (args[0] === "api" && args.includes("user")) {
  save();
  console.log(JSON.stringify(state.tokenUser));
} else if (args[0] === "api" && endpoint === "repos/OpenCoven/seer-releases") {
  save();
  console.log(JSON.stringify({ visibility: state.visibility, default_branch: "main" }));
} else if (args[0] === "api" && endpoint === "repos/OpenCoven/seer-releases/immutable-releases") {
  save();
  console.log(JSON.stringify({ enabled: state.immutableReleases, enforced_by_owner: false }));
} else if (args[0] === "api" && endpoint === "repos/OpenCoven/seer-releases/git/ref/heads/main") {
  save();
  console.log(JSON.stringify({ ref: "refs/heads/main", object: { type: "commit", sha: state.releaseRepoCommit } }));
} else if (args[0] === "api" && endpoint === \`repos/OpenCoven/seer-releases/git/commits/\${state.releaseRepoCommit}\`) {
  save();
  console.log(JSON.stringify({ sha: state.releaseRepoCommit }));
} else if (args[0] === "api" && endpoint === "repos/OpenCoven/seer-releases/git/tags" && args.includes("POST")) {
  const valueAfter = (name) => {
    const index = args.lastIndexOf(name);
    return index === -1 ? null : args[index + 1];
  };
  state.pendingLockTag = {
    sha: state.lockTagObjectSHA,
    tag: valueAfter("--raw-field")?.startsWith("tag=")
      ? valueAfter("--raw-field").slice(4)
      : args.find((arg) => arg.startsWith("tag="))?.slice(4),
  };
  const fields = Object.fromEntries(args.filter((arg) => arg.includes("=")).map((arg) => arg.split(/=(.*)/s).slice(0, 2)));
  state.pendingLockTag = {
    sha: state.lockTagObjectSHA,
    tag: fields.tag,
    message: fields.message,
    object: { type: fields.type, sha: fields.object },
  };
  save();
  console.log(JSON.stringify(state.pendingLockTag));
} else if (args[0] === "api" && endpoint === "repos/OpenCoven/seer-releases/git/refs" && args.includes("POST")) {
  if (state.lock) {
    save();
    console.error("gh: Reference already exists (HTTP 422)");
    process.exit(1);
  }
  const fields = Object.fromEntries(args.filter((arg) => arg.includes("=")).map((arg) => arg.split(/=(.*)/s).slice(0, 2)));
  state.lock = { ref: fields.ref, sha: fields.sha, tagObject: state.pendingLockTag };
  if (state.createRefLostResponse) {
    state.createRefLostResponse = false;
    save();
    console.error("gh: response lost after create");
    process.exit(1);
  }
  save();
  console.log(JSON.stringify({ ref: state.lock.ref, object: { type: "tag", sha: state.lock.sha } }));
} else if (args[0] === "api" && endpoint === "repos/OpenCoven/seer-releases/git/ref/tags/seer-release-lock-v1.2.3") {
  if (!state.lock) fail404();
  save();
  console.log(JSON.stringify({ ref: state.lock.ref, object: { type: "tag", sha: state.lock.sha } }));
} else if (args[0] === "api" && endpoint === \`repos/OpenCoven/seer-releases/git/tags/\${state.lock?.sha}\`) {
  if (!state.lock) fail404();
  save();
  console.log(JSON.stringify(state.lock.tagObject));
} else if (
  args[0] === "api" &&
  endpoint === "repos/OpenCoven/seer-releases/git/refs/tags/seer-release-lock-v1.2.3" &&
  args.includes("DELETE")
) {
  if (!state.lock) fail404();
  state.lock = null;
  save();
} else if (args[0] === "api" && endpoint?.startsWith("repos/OpenCoven/seer/actions/runs/")) {
  state.sourceRunQueries.push(endpoint);
  if (process.env.GH_TOKEN !== process.env.FAKE_SOURCE_TOKEN || state.sourceRunResponse === "api-error") {
    save();
    console.error("gh: source Actions run unavailable");
    process.exit(1);
  }
  const parts = endpoint.split("/");
  const runID = Number(parts[parts.indexOf("runs") + 1]);
  const attempt = Number(parts[parts.indexOf("attempts") + 1]);
  save();
  console.log(JSON.stringify(
    state.sourceRunResponse ?? {
      id: runID,
      run_attempt: attempt,
      status: state.sourceRunStatus,
      conclusion: state.sourceRunConclusion,
    },
  ));
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
    prerelease: false,
    tag: args[2],
    title: args[titleIndex + 1],
    body: readFileSync(args[notesIndex + 1], "utf8"),
    updatedAt: "2026-08-15T18:00:00Z",
    assets: [],
    immutable: false,
    author: state.tokenUser,
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
      uploader: state.tokenUser,
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
const redactedArgs = args.map((arg) =>
  arg.startsWith("Authorization: ") ? "Authorization: [REDACTED]" : arg
);
state.calls.push(["curl", ...redactedArgs]);
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
const authorization = headers.find((header) => header.startsWith("Authorization: "));
if (authorization !== \`Authorization: Bearer \${process.env.FAKE_EXPECTED_TOKEN}\`) {
  save();
  console.error("curl: request authentication rejected");
  process.exit(97);
}
state.authenticatedRequests.push({ method, url });
const writeResponse = (status, body, etag = state.etag) => {
  if (headerPath) writeFileSync(headerPath, \`HTTP/2 \${status}\\r\\netag: \${etag}\\r\\n\\r\\n\`);
  if (output) writeFileSync(output, body);
};
const releaseJSON = () => JSON.stringify({
  id: state.release.id,
  draft: state.release.draft,
  prerelease: state.release.prerelease,
  tag_name: state.release.tag,
  name: state.release.title,
  body: state.release.body,
  updated_at: state.release.updatedAt,
  immutable: state.release.immutable,
  author: state.release.author,
  assets: state.release.assets.map(({ id, name, size, digest, uploader }) => ({
    id, name, size, digest, uploader
  })),
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
  state.release.draft = false;
  state.release.prerelease = false;
  state.release.immutable = state.immutableReleases;
  state.release.updatedAt = "2026-08-15T18:02:00Z";
  if (state.postPublishMutation === "title") state.release.title += " foreign";
  if (state.postPublishMutation === "asset-id") state.release.assets[0].id += 1000;
  if (state.postPublishMutation === "prerelease") state.release.prerelease = true;
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
        immutableReleases: options.immutableReleases ?? true,
        tokenUser: options.tokenUser ?? releaseWriter,
        releaseRepoCommit,
        lockTagObjectSHA,
        lock:
          options.lock === undefined
            ? {
                ref: lockRef,
                sha: lockTagObjectSHA,
                tagObject: {
                  sha: lockTagObjectSHA,
                  tag: lockTagName,
                  message: lockMessage,
                  object: { type: "commit", sha: releaseRepoCommit },
                },
              }
            : options.lock,
        createRefLostResponse: options.createRefLostResponse ?? false,
        sourceRunStatus: options.sourceRunStatus ?? "completed",
        sourceRunConclusion: options.sourceRunConclusion ?? "success",
        sourceRunResponse: options.sourceRunResponse ?? null,
        sourceRunQueries: [],
        release: options.release === undefined ? matchingRelease() : options.release,
        tagExists: options.tagExists ?? true,
        etag: options.etag ?? '"draft-etag"',
        postPublishMutation: null,
        nextAssetID: 200,
        calls: [],
        authenticatedRequests: [],
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
          FAKE_EXPECTED_TOKEN: "test-token",
          FAKE_SOURCE_TOKEN: "source-token",
          FAKE_RELEASE_STATE: statePath,
          GITHUB_API_URL: "https://api.github.test",
          GH_TOKEN: "test-token",
          SOURCE_GITHUB_TOKEN: "source-token",
          GH_REPO: destinationRepository,
          SOURCE_REPOSITORY: sourceRepository,
          SOURCE_COMMIT: sourceCommit,
          SOURCE_TAG: sourceTag,
          WORKFLOW_REF: workflowRef,
          WORKFLOW_RUN: workflowRun,
          WORKFLOW_ATTEMPT: workflowAttempt,
          VERSION: version,
          RELEASE_WRITER_LOGIN: releaseWriter.login,
          RELEASE_WRITER_ID: String(releaseWriter.id),
          RELEASE_DIR: releaseDir,
          RELEASE_BODY: releaseBody,
          VERIFIED_STATE: verifiedState,
          STATE_WORK_DIR: scratch,
          ...env,
        },
      });

    return callback({ run, readState, writeState, releaseDir, releaseBody, verifiedState, scratch });
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
  }, { release: matchingRelease({ draft: false, immutable: true }) });
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

test("prerelease drafts are rejected before any upload", () => {
  withHarness(({ run, readState }) => {
    const result = run("upload");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /prerelease|stable release/i);
    assert.ok(
      !readState().calls.some(
        (call) => call[0] === "gh" && call[1] === "release" && call[2] === "upload",
      ),
    );
  }, { release: matchingRelease({ prerelease: true }) });
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
    assert.equal(captured.prerelease, false);
    assert.equal(captured.updatedAt, "2026-08-15T18:00:00Z");
    assert.equal(captured.tagName, sourceTag);
    assert.equal(captured.title, canonicalTitle);
    assert.equal(captured.body, canonicalBody);
    assert.deepEqual(captured.author, releaseWriter);
    assert.equal(captured.notes.sha256, sha256(canonicalBody));
    assert.deepEqual(captured.assets.map(({ id }) => id), [100, 101, 102]);
    assert.deepEqual(
      captured.assets.map(({ name, size, sha256: digest, serverDigest, uploader }) => ({
        name,
        size,
        digest,
        serverDigest,
        uploader,
      })),
      expectedAssets.map((name) => ({
        name,
        size: Buffer.byteLength(`${name}\n`),
        digest: sha256(`${name}\n`),
        serverDigest: `sha256:${sha256(`${name}\n`)}`,
        uploader: releaseWriter,
      })),
    );
  });
});

test("capture authenticates release metadata and asset downloads with the injected token", () => {
  withHarness(({ run, readState, writeState }) => {
    const state = readState();
    for (const item of state.release.assets) item.digest = null;
    writeState(state);

    const result = run("capture", { GH_TOKEN: "auth-test-token", FAKE_EXPECTED_TOKEN: "auth-test-token" });
    assert.equal(result.status, 0, result.stderr);
    const requests = readState().authenticatedRequests;
    assert.equal(requests.filter(({ url }) => url.includes("/releases/tags/")).length, 1);
    assert.equal(requests.filter(({ url }) => url.includes("/releases/assets/")).length, expectedAssets.length);
    assert.doesNotMatch(`${result.stdout}\n${result.stderr}\n${JSON.stringify(readState())}`, /auth-test-token/);
  });
});

test("capture fails closed when the token is missing or rejected without logging it", () => {
  for (const [name, env] of [
    ["missing", { GH_TOKEN: "" }],
    ["wrong", { GH_TOKEN: "wrong-auth-test-token", FAKE_EXPECTED_TOKEN: "expected-auth-test-token" }],
  ]) {
    withHarness(({ run, readState }) => {
      const result = run("capture", env);
      assert.notEqual(result.status, 0, `${name} authentication must fail`);
      if (name === "missing") assert.match(result.stderr, /GH_TOKEN is required/);
      const observable = `${result.stdout}\n${result.stderr}\n${JSON.stringify(readState())}`;
      assert.doesNotMatch(observable, /(?:wrong|expected)-auth-test-token/);
      assert.equal(readState().release.draft, true);
    });
  }
});

test("release policy rejects inherited xtrace before the token can be logged", () => {
  withHarness(({ run }) => {
    const result = run("capture", {
      GH_TOKEN: "xtrace-auth-test-token",
      FAKE_EXPECTED_TOKEN: "xtrace-auth-test-token",
      SHELLOPTS: "braceexpand:hashall:interactive-comments:xtrace",
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /xtrace/i);
    assert.doesNotMatch(`${result.stdout}\n${result.stderr}`, /xtrace-auth-test-token/);
  });
});

test("publish fails closed when canonical release or asset identity state changes", () => {
  const mutations = [
    ["title", (state) => { state.release.title += " changed"; }],
    ["body", (state) => { state.release.body += "foreign\n"; }],
    ["author", (state) => { state.release.author = { id: 99, login: "foreign-writer" }; }],
    ["prerelease", (state) => { state.release.prerelease = true; }],
    ["asset id", (state) => { state.release.assets[0].id = 999; }],
    ["asset size", (state) => { state.release.assets[0].size += 1; }],
    ["asset digest", (state) => { state.release.assets[0].digest = `sha256:${"f".repeat(64)}`; }],
    ["asset uploader", (state) => {
      state.release.assets[0].uploader = { id: 99, login: "foreign-writer" };
    }],
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
    assert.equal(assetDownloads.length, expectedAssets.length * 3);
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

test("atomic tag-scoped lock acquisition adopts its exact owner and releases it", () => {
  withHarness(({ run, readState }) => {
    const acquired = run("acquire-lock");
    assert.equal(acquired.status, 0, acquired.stderr);
    const held = readState().lock;
    assert.equal(held.ref, lockRef);
    assert.equal(held.tagObject.tag, lockTagName);
    assert.equal(held.tagObject.message, lockMessage);
    assert.deepEqual(held.tagObject.object, { type: "commit", sha: releaseRepoCommit });

    const collision = run("acquire-lock");
    assert.equal(collision.status, 0, collision.stderr);
    assert.deepEqual(readState().lock, held);

    const released = run("release-lock");
    assert.equal(released.status, 0, released.stderr);
    assert.equal(readState().lock, null);
  }, { lock: null });
});

test("lost create-ref response is adopted after exact ownership refetch", () => {
  withHarness(({ run, readState, scratch }) => {
    const output = join(scratch, "github-output");
    const result = run("acquire-lock", { GITHUB_OUTPUT: output });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(output, "utf8"), "acquired=true\n");
    assert.equal(readState().lock.tagObject.message, lockMessage);
  }, { lock: null, createRefLostResponse: true });
});

test("cleanup reconciles and removes an exact current lock even before acquired output was set", () => {
  withHarness(({ run, readState }) => {
    const result = run("release-lock", { RELEASE_LOCK_ACQUIRED: "" });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(readState().lock, null);
  });
});

test("a definitively completed previous attempt is reclaimed with the source Actions token", () => {
  const previous = lockFixture({ workflowAttempt: "1" });
  withHarness(({ run, readState }) => {
    const result = run("acquire-lock", { WORKFLOW_ATTEMPT: "2" });

    assert.equal(result.status, 0, result.stderr);
    const state = readState();
    assert.equal(state.lock.tagObject.message, lockOwnership({ workflowAttempt: "2" }).message);
    assert.deepEqual(
      state.sourceRunQueries,
      [`repos/${sourceRepository}/actions/runs/${workflowRun}/attempts/1`],
    );
  }, {
    lock: previous,
    sourceRunStatus: "completed",
    sourceRunConclusion: "success",
  });
});

test("active or unknown previous attempts are preserved and fail closed", () => {
  const cases = [
    { name: "active", options: { sourceRunStatus: "in_progress", sourceRunConclusion: null } },
    {
      name: "unknown",
      options: {
        sourceRunResponse: {
          id: Number(workflowRun),
          run_attempt: 1,
          status: "mystery",
          conclusion: null,
        },
      },
    },
  ];
  for (const { name, options } of cases) {
    const previous = lockFixture({ workflowAttempt: "1" });
    withHarness(({ run, readState }) => {
      const result = run("acquire-lock", { WORKFLOW_ATTEMPT: "2" });

      assert.notEqual(result.status, 0, `${name} lock must not be reclaimed`);
      assert.deepEqual(readState().lock, previous);
      assert.ok(!readState().calls.some((call) => call.includes("DELETE")));
    }, { lock: previous, ...options });
  }
});

test("foreign cleanup and malicious ownership metadata never delete the lock", () => {
  const cases = [
    {
      name: "foreign previous attempt",
      lock: lockFixture({ workflowAttempt: "1" }),
      mode: "release-lock",
    },
    {
      name: "malicious repository",
      lock: lockFixture({ sourceRepository: "attacker/repository" }),
      mode: "acquire-lock",
    },
  ];
  for (const entry of cases) {
    withHarness(({ run, readState }) => {
      const result = run(entry.mode, { WORKFLOW_ATTEMPT: "2" });

      assert.notEqual(result.status, 0, `${entry.name} must fail closed`);
      assert.deepEqual(readState().lock, entry.lock);
      assert.equal(readState().sourceRunQueries.length, 0);
      assert.ok(!readState().calls.some((call) => call.includes("DELETE")));
    }, { lock: entry.lock });
  }
});

test("foreign lock ownership, release author, and asset uploader fail closed", () => {
  const cases = [
    {
      name: "lock",
      options: {
        lock: {
          ref: lockRef,
          sha: "e".repeat(40),
          tagObject: {
            sha: "e".repeat(40),
            tag: `${lockTagName}-foreign`,
            message: `${lockMessage}foreign`,
            object: { type: "commit", sha: releaseRepoCommit },
          },
        },
      },
    },
    {
      name: "author",
      options: { release: matchingRelease({ author: { id: 99, login: "foreign-writer" } }) },
    },
    {
      name: "uploader",
      options: {
        release: matchingRelease({
          assets: expectedAssets.map((name, index) => ({
            ...asset(name, 100 + index),
            ...(index === 0 ? { uploader: { id: 99, login: "foreign-writer" } } : {}),
          })),
        }),
      },
    },
  ];
  for (const { name, options } of cases) {
    withHarness(({ run, readState }) => {
      const result = run("preflight");
      assert.notEqual(result.status, 0, `${name} must fail`);
      assert.match(result.stderr, /lock|author|uploader|writer/i);
      assert.equal(readState().release.draft, true);
    }, options);
  }
});

test("immutable release repository protection is mandatory and verifiable", () => {
  withHarness(({ run, readState }) => {
    const result = run("preflight");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /immutable releases/i);
    assert.equal(readState().release.draft, true);
  }, { immutableReleases: false });
});

test("post-publish mismatch fails loudly without deleting the release", () => {
  for (const mutation of ["title", "asset-id", "prerelease"]) {
    withHarness(({ run, readState, writeState }) => {
      assert.equal(run("capture").status, 0);
      const state = readState();
      state.postPublishMutation = mutation;
      writeState(state);
      const result = run("publish");
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /post-publish release state|canonical metadata|asset identity/i);
      const after = readState();
      assert.equal(after.release.draft, false);
      assert.ok(!after.calls.some((call) => call[0] === "gh" && call[1] === "release" && call[2] === "delete"));
      assert.ok(!after.calls.some((call) => call.includes("/releases/") && call.includes("DELETE")));
    });
  }
});

test("exact captured state publishes by release ID with supported REST PATCH and refetch", () => {
  withHarness(({ run, readState }) => {
    assert.equal(run("capture").status, 0);
    const result = run("publish");
    assert.equal(result.status, 0, result.stderr);
    const state = readState();
    assert.equal(state.release.draft, false);
    const patch = state.calls.find((call) => call[0] === "curl" && call.includes("PATCH"));
    assert.ok(patch);
    assert.ok(patch.some((arg) => arg.endsWith("/releases/42")));
    assert.ok(!patch.some((arg) => arg.startsWith("If-Match:")));
    assert.ok(patch.includes("Authorization: [REDACTED]"));
    assert.equal(state.authenticatedRequests.filter(({ method }) => method === "PATCH").length, 1);
    assert.equal(
      state.authenticatedRequests.filter(
        ({ method, url }) => method === "GET" && url.includes("/releases/tags/"),
      ).length,
      3,
    );
    assert.equal(state.release.immutable, true);
    assert.doesNotMatch(`${result.stdout}\n${result.stderr}\n${JSON.stringify(state)}`, /test-token/);
    assert.ok(!state.calls.some((call) => call[0] === "gh" && call[1] === "release" && call[2] === "edit"));
    assert.ok(!state.calls.some((call) => call.includes("delete") || call.includes("DELETE")));
  });
});
