import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
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
const signingIdentity = "Developer ID Application: OpenCoven (ABCDEFGHIJ)";
const teamID = "ABCDEFGHIJ";
const buildNumber = "42";
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
    target: releaseRepoCommit,
    updatedAt: "2026-08-15T18:00:00Z",
    immutable: false,
    author: releaseWriter,
    assets: expectedAssets.map((name, index) => asset(name, 100 + index)),
    ...overrides,
  };
}

function stableAssetNames(tag) {
  return [`Seer-${tag}-arm64.dmg`, "SHA256SUMS", "release-manifest.json"];
}

function latestRelease(tag = "v1.2.2", id = 41, overrides = {}) {
  return {
    id,
    draft: false,
    prerelease: false,
    immutable: true,
    tag,
    title: `Seer ${tag.slice(1)}`,
    body: `previous release ${tag}\n`,
    target: releaseRepoCommit,
    updatedAt: "2026-08-14T18:00:00Z",
    author: releaseWriter,
    assets: stableAssetNames(tag).map((name, index) => asset(name, 300 + index)),
    ...overrides,
  };
}

function publishedAssets({
  dmgContents = "signed-and-notarized-dmg-generated-at-2026-08-15T18:02:00Z\n",
  manifestOverrides = {},
  checksumDigest,
} = {}) {
  const dmgName = expectedAssets[0];
  const dmgDigest = sha256(dmgContents);
  const manifest = {
    artifacts: [
      {
        name: dmgName,
        sha256: dmgDigest,
        size: Buffer.byteLength(dmgContents),
      },
    ],
    bundleIdentifier: "ai.opencoven.seer",
    notarization: "accepted",
    sourceCommit,
    version,
    workflowRun,
    ...manifestOverrides,
  };
  const contents = [
    dmgContents,
    `${checksumDigest ?? dmgDigest}  ${dmgName}\n`,
    `${JSON.stringify(manifest, null, 2)}\n`,
  ];
  return expectedAssets.map((name, index) => asset(name, 100 + index, contents[index]));
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
const releaseJSON = (release = state.release) => ({
  id: release.id,
  draft: release.draft,
  prerelease: release.prerelease,
  tag_name: release.tag,
  name: release.title,
  body: release.body,
  target_commitish: release.target,
  updated_at: release.updatedAt,
  immutable: release.immutable,
  author: release.author,
  assets: (release.assets ?? []).map(({ id, name, size, digest, uploader }) => ({
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
  const fields = Object.fromEntries(args.filter((arg) => arg.includes("=")).map((arg) => arg.split(/=(.*)/s).slice(0, 2)));
  if (fields.ref === "refs/tags/v1.2.3") {
    if (state.destinationTagRef) {
      save();
      console.error("gh: Reference already exists (HTTP 422)");
      process.exit(1);
    }
    state.destinationTagRef = { ref: fields.ref, object: { type: "commit", sha: fields.sha } };
    save();
    console.log(JSON.stringify(state.destinationTagRef));
    process.exit(0);
  }
  if (state.lock) {
    save();
    console.error("gh: Reference already exists (HTTP 422)");
    process.exit(1);
  }
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
} else if (args[0] === "api" && endpoint === "repos/OpenCoven/seer/git/ref/tags/v1.2.3") {
  if (!state.sourceTagRef) fail404();
  save();
  console.log(JSON.stringify(state.sourceTagRef));
} else if (args[0] === "api" && endpoint?.startsWith("repos/OpenCoven/seer/git/tags/")) {
  const sha = endpoint.split("/").at(-1);
  const tag = state.sourceTagObjects[sha];
  if (!tag) fail404();
  save();
  console.log(JSON.stringify(tag));
} else if (args[0] === "api" && endpoint === "repos/OpenCoven/seer-releases/git/ref/tags/v1.2.3") {
  if (!state.destinationTagRef) fail404();
  save();
  console.log(JSON.stringify(state.destinationTagRef));
} else if (args[0] === "api" && endpoint?.startsWith("repos/OpenCoven/seer-releases/git/tags/")) {
  const sha = endpoint.split("/").at(-1);
  const tag = state.destinationTagObjects[sha];
  if (!tag) fail404();
  save();
  console.log(JSON.stringify(tag));
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
} else if (args[0] === "api" && endpoint?.startsWith("repos/OpenCoven/seer-releases/releases?")) {
  // Models GitHub's real "list releases" endpoint: authenticated push-access
  // callers see drafts too, unlike the tag-lookup endpoint below.
  const query = new URLSearchParams(endpoint.split("?")[1] ?? "");
  const perPage = Number(query.get("per_page"));
  const page = Number(query.get("page"));
  state.releaseListRequests = state.releaseListRequests || [];
  state.releaseListRequests.push({ perPage, page });
  if (page === 1) state.releaseListScanCount += 1;
  if (
    page === 1 &&
    state.mutateDraftAtReleaseListScan !== null &&
    state.releaseListScanCount >= state.mutateDraftAtReleaseListScan &&
    !state.draftInventoryMutationApplied
  ) {
    const original = state.release.assets[0].contents;
    state.release.assets[0].contents = original.replace(/^./, original[0] === "X" ? "Y" : "X");
    state.draftInventoryMutationApplied = true;
  }
  if (
    page === 1 &&
    state.moveSourceTagAtReleaseListScan !== null &&
    state.releaseListScanCount >= state.moveSourceTagAtReleaseListScan
  ) {
    state.sourceTagRef.object.sha = "b".repeat(40);
  }
  if (
    page === 1 &&
    state.moveDestinationTagAtReleaseListScan !== null &&
    state.releaseListScanCount >= state.moveDestinationTagAtReleaseListScan
  ) {
    state.destinationTagRef.object.sha = "b".repeat(40);
  }
  if (
    page === 1 &&
    state.moveLockAnchorAtReleaseListScan !== null &&
    state.releaseListScanCount >= state.moveLockAnchorAtReleaseListScan
  ) {
    state.lock.tagObject.object.sha = "b".repeat(40);
  }
  const releaseListFailurePage =
    state.release?.draft === false && state.postReleaseListFailurePage !== null
      ? state.postReleaseListFailurePage
      : state.releaseListFailurePage;
  if (releaseListFailurePage === page) {
    save();
    console.error("gh: simulated authenticated release-list API failure");
    process.exit(1);
  }
  const targetPage = state.releaseListPage ?? 1;
  const fillers = Array.from({ length: Math.max(0, targetPage - 1) * perPage }, (_, index) => ({
    id: 500000 + index,
    draft: true,
    prerelease: false,
    immutable: false,
    tag: \`other-tag-\${index}\`,
    title: \`Other draft \${index}\`,
    body: "unrelated draft\\n",
    target: state.releaseRepoCommit,
    updatedAt: "2026-08-13T18:00:00Z",
    author: state.tokenUser,
    assets: [],
  }));
  const listed = [...fillers];
  if (state.release) {
    listed.push(state.release);
    if (state.releaseListDuplicateOnMatchPage) {
      listed.push({ ...state.release, id: state.release.id + 1 });
    }
  }
  let additional = state.release?.draft === false && state.postInventoryReleases !== null
    ? state.postInventoryReleases
    : state.inventoryReleases;
  if (
    state.releaseListMutationAfterScan !== null &&
    state.releaseListScanCount >= state.releaseListMutationAfterScan
  ) {
    additional = state.mutatedInventoryReleases;
  }
  listed.push(...additional);
  const start = (page - 1) * perPage;
  const items = listed.slice(start, start + perPage).map((release) => releaseJSON(release));
  save();
  console.log(JSON.stringify(items));
} else if (args[0] === "api" && endpoint?.includes("/releases/tags/")) {
  // Real GitHub only returns a *published* release from this endpoint; it 404s
  // for drafts even for authenticated users with push access.
  if (!state.release || state.release.draft) fail404();
  save();
  console.log(JSON.stringify(releaseJSON()));
} else if (args[0] === "release" && args[1] === "create") {
  if (state.release) {
    save();
    process.exit(1);
  }
  const notesIndex = args.indexOf("--notes-file");
  const titleIndex = args.indexOf("--title");
  const targetIndex = args.indexOf("--target");
  if (!args.includes("--verify-tag") || targetIndex === -1 || !state.destinationTagRef) process.exit(2);
  state.release = {
    id: 42,
    draft: true,
    prerelease: false,
    tag: args[2],
    title: args[titleIndex + 1],
    body: readFileSync(args[notesIndex + 1], "utf8"),
    target: args[targetIndex + 1],
    updatedAt: "2026-08-15T18:00:00Z",
    assets: [],
    immutable: false,
    author: state.tokenUser,
  };
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
import { dirname, join } from "node:path";

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
const writeOut = valueAfter("--write-out") ?? valueAfter("-w");
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
  if (writeOut !== null) {
    if (writeOut !== "%{http_code}") {
      save();
      console.error("curl: unsupported write-out format");
      process.exit(98);
    }
    process.stdout.write(String(status));
  }
};
const releaseJSON = (release = state.release) => JSON.stringify({
  id: release.id,
  draft: release.draft,
  prerelease: release.prerelease,
  tag_name: release.tag,
  name: release.title,
  body: release.body,
  target_commitish: release.target,
  updated_at: release.updatedAt,
  immutable: release.immutable,
  author: release.author,
  assets: (release.assets ?? []).map(({ id, name, size, digest, uploader }) => ({
    id, name, size, digest, uploader
  })),
});
const assetBytes = (item) =>
  item.contentsEncoding === "base64" ? Buffer.from(item.contents, "base64") : Buffer.from(item.contents);

if (method === "GET" && url?.endsWith("/releases/latest")) {
  state.latestGetCount += 1;
  const afterPatch = state.latestGetCount > 1 && state.release?.draft === false;
  const latest = afterPatch && Object.hasOwn(state, "postLatestRelease")
    ? state.postLatestRelease
    : state.latestRelease;
  const configuredStatus = afterPatch && state.postLatestResponseStatus !== null
    ? state.postLatestResponseStatus
    : state.latestResponseStatus;
  const status = configuredStatus ?? (latest ? 200 : 404);
  if (status !== 200) {
    writeResponse(
      status,
      state.latestResponseBody ?? JSON.stringify({
        message: status === 404 ? "Not Found" : "simulated latest release API failure",
      }),
    );
    save();
    process.exit(22);
  }
  writeResponse(200, state.latestResponseBody ?? releaseJSON(latest));
  save();
} else if (method === "GET" && url?.includes("/releases/tags/")) {
  // Real GitHub only returns a *published* release from this endpoint; it 404s
  // for drafts even for authenticated users with push access.
  if (!state.release || state.release.draft) {
    writeResponse(404, JSON.stringify({ message: "Not Found" }));
    save();
    process.exit(22);
  }
  writeResponse(200, releaseJSON());
  save();
} else if (method === "GET" && /\\/releases\\/[0-9]+$/.test(url ?? "")) {
  // Get-a-release-by-ID works for drafts and published releases alike.
  const id = Number(url.match(/\\/releases\\/([0-9]+)$/)[1]);
  if (!state.release || state.release.id !== id) {
    writeResponse(404, JSON.stringify({ message: "Not Found" }));
    save();
    process.exit(22);
  }
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
  if (state.patchOutcome === "lost-unchanged") {
    save();
    console.error("curl: response lost before apply");
    process.exit(28);
  }
  const patchPayload = JSON.parse(valueAfter("--data"));
  if (!["true", "false"].includes(patchPayload.make_latest)) {
    save();
    console.error("curl: make_latest must be explicit");
    process.exit(98);
  }
  state.release.draft = false;
  state.release.prerelease = false;
  state.release.immutable = state.immutableReleases;
  state.release.updatedAt = "2026-08-15T18:02:00Z";
  if (state.postPublishMutation === "title") state.release.title += " foreign";
  if (state.postPublishMutation === "asset-id") state.release.assets[0].id += 1000;
  if (state.postPublishMutation === "prerelease") state.release.prerelease = true;
  if (state.patchOutcome === "lost-mutated") state.release.title += " foreign";
  if (state.tamperDecisionFingerprint) {
    const decisionPath = join(dirname(process.env.VERIFIED_STATE), "latest-release-decision.json");
    const decision = JSON.parse(readFileSync(decisionPath, "utf8"));
    decision.inventory.fingerprint = "f".repeat(64);
    writeFileSync(decisionPath, JSON.stringify(decision));
  }
  if (patchPayload.make_latest === "true") {
    state.latestRelease = structuredClone(state.release);
  }
  if (state.patchOutcome === "lost-applied" || state.patchOutcome === "lost-mutated") {
    save();
    console.error("curl: response lost after apply");
    process.exit(28);
  }
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
    const githubOutput = join(scratch, "github-output");
    const platformLog = join(scratch, "platform-verifier.log");
    const platformVerifier = join(scratch, "platform-verifier.mjs");
    mkdirSync(releaseDir);
    writeFileSync(releaseBody, canonicalBody);
    for (const name of expectedAssets) writeFileSync(join(releaseDir, name), `${name}\n`);
    writeFileSync(
      platformVerifier,
      `import { appendFileSync } from "node:fs";
appendFileSync(process.env.FAKE_PLATFORM_LOG, JSON.stringify(process.argv.slice(2)) + "\\n");
if (process.env.FAKE_PLATFORM_RESULT === "fail") {
  console.error("stub: Apple signature or notarization validation failed");
  process.exit(1);
}
const report = [
  process.env.FAKE_PUBLISHED_DMG_AUTHORITY ?? process.env.APPLE_SIGNING_IDENTITY,
  process.env.FAKE_PUBLISHED_DMG_TEAM_ID ?? process.env.APPLE_TEAM_ID,
  process.env.FAKE_PUBLISHED_APP_AUTHORITY ?? process.env.APPLE_SIGNING_IDENTITY,
  process.env.FAKE_PUBLISHED_APP_TEAM_ID ?? process.env.APPLE_TEAM_ID,
  process.env.FAKE_PUBLISHED_BUNDLE_IDENTIFIER ?? "ai.opencoven.seer",
  process.env.FAKE_PUBLISHED_MARKETING_VERSION ?? process.env.VERSION,
  process.env.FAKE_PUBLISHED_BUILD_NUMBER ?? process.env.BUILD_NUMBER,
];
process.stdout.write(\`\${report.join("\\n")}\\n\`);
`,
    );
    chmodSync(platformVerifier, 0o755);
    const initialRelease = options.release === undefined ? matchingRelease() : options.release;
    const initialLatestRelease = Object.hasOwn(options, "latestRelease")
      ? options.latestRelease
      : initialRelease?.draft === false
        ? structuredClone(initialRelease)
        : null;
    const initialInventoryReleases =
      options.inventoryReleases ??
      (initialLatestRelease && initialLatestRelease.id !== initialRelease?.id
        ? [structuredClone(initialLatestRelease)]
        : []);
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
        sourceTagRef: options.sourceTagRef ?? {
          ref: `refs/tags/${sourceTag}`,
          object: { type: "commit", sha: sourceCommit },
        },
        sourceTagObjects: options.sourceTagObjects ?? {},
        destinationTagRef: options.destinationTagRef === undefined
          ? {
              ref: `refs/tags/${sourceTag}`,
              object: { type: "commit", sha: releaseRepoCommit },
            }
          : options.destinationTagRef,
        destinationTagObjects: options.destinationTagObjects ?? {},
        release: initialRelease,
        releaseListPage: options.releaseListPage ?? 1,
        releaseListDuplicateOnMatchPage: options.releaseListDuplicateOnMatchPage ?? false,
        releaseListFailurePage: options.releaseListFailurePage ?? null,
        postReleaseListFailurePage: options.postReleaseListFailurePage ?? null,
        inventoryReleases: initialInventoryReleases,
        postInventoryReleases: options.postInventoryReleases ?? null,
        latestRelease: initialLatestRelease,
        latestResponseStatus: options.latestResponseStatus ?? null,
        latestResponseBody: options.latestResponseBody ?? null,
        postLatestResponseStatus: options.postLatestResponseStatus ?? null,
        ...(Object.hasOwn(options, "postLatestRelease")
          ? { postLatestRelease: options.postLatestRelease }
          : {}),
        latestGetCount: 0,
        etag: options.etag ?? '"draft-etag"',
        postPublishMutation: null,
        tamperDecisionFingerprint: options.tamperDecisionFingerprint ?? false,
        patchOutcome: options.patchOutcome ?? "normal",
        nextAssetID: 200,
        calls: [],
        authenticatedRequests: [],
        releaseListRequests: [],
        releaseListScanCount: 0,
        releaseListMutationAfterScan: options.releaseListMutationAfterScan ?? null,
        mutatedInventoryReleases: options.mutatedInventoryReleases ?? [],
        mutateDraftAtReleaseListScan: options.mutateDraftAtReleaseListScan ?? null,
        draftInventoryMutationApplied: false,
        moveSourceTagAtReleaseListScan: options.moveSourceTagAtReleaseListScan ?? null,
        moveDestinationTagAtReleaseListScan: options.moveDestinationTagAtReleaseListScan ?? null,
        moveLockAnchorAtReleaseListScan: options.moveLockAnchorAtReleaseListScan ?? null,
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
          BUILD_NUMBER: buildNumber,
          APPLE_SIGNING_IDENTITY: signingIdentity,
          APPLE_TEAM_ID: teamID,
          RELEASE_WRITER_LOGIN: releaseWriter.login,
          RELEASE_WRITER_ID: String(releaseWriter.id),
          RELEASE_DIR: releaseDir,
          RELEASE_BODY: releaseBody,
          VERIFIED_STATE: verifiedState,
          STATE_WORK_DIR: scratch,
          GITHUB_OUTPUT: githubOutput,
          SEER_RELEASE_TEST_MODE: "1",
          SEER_RELEASE_TEST_PLATFORM_VERIFIER: platformVerifier,
          GITHUB_ACTIONS: "false",
          FAKE_PLATFORM_LOG: platformLog,
          ...env,
        },
      });

    return callback({
      run,
      readState,
      writeState,
      releaseDir,
      releaseBody,
      verifiedState,
      githubOutput,
      platformLog,
      scratch,
    });
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

test("test-mode verifier hooks are rejected inside GitHub Actions", () => {
  withHarness(({ run, readState }) => {
    const result = run("preflight", { GITHUB_ACTIONS: "true" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /SEER_RELEASE_TEST_MODE is forbidden when GITHUB_ACTIONS=true/);
    assert.deepEqual(readState().calls, []);
  });
});

test("newly-created and resumable draft releases are discovered via authenticated listing while the tag-lookup endpoint only exposes published releases", () => {
  // Case 1: no release exists yet. `upload` must create the draft and then
  // verify its own existence through the authenticated listing endpoint; the
  // real GitHub tag-lookup endpoint 404s for drafts even with push access, so
  // relying on it here would make the workflow abort on every new release.
  withHarness(({ run, readState }) => {
    const result = run("upload");
    assert.equal(result.status, 0, result.stderr);
    const state = readState();
    assert.equal(state.release.draft, true);
    assert.equal(state.release.tag, sourceTag);
    assert.ok(
      !state.calls.some(
        (call) => call[0] === "gh" && call.some((arg) => typeof arg === "string" && arg.includes("/releases/tags/")),
      ),
      "the tag-lookup endpoint (which cannot see drafts) must never be relied on to discover a draft",
    );
    assert.ok(
      state.releaseListRequests.length > 0,
      "the authenticated release listing endpoint must be used to discover the draft",
    );
  }, { release: null, destinationTagRef: null });

  // Case 2: an existing draft (for example from a prior, interrupted attempt)
  // must be resumed by discovering it through the same listing endpoint.
  withHarness(({ run, readState }) => {
    const result = run("preflight");
    assert.equal(result.status, 0, result.stderr);
    const state = readState();
    assert.equal(state.release.draft, true);
    assert.ok(
      state.releaseListRequests.length > 0,
      "the authenticated release listing endpoint must be used to resume the existing draft",
    );
  });
});

test("release discovery traverses bounded pagination to find a draft beyond the first page", () => {
  withHarness(({ run, readState }) => {
    const result = run("preflight", {
      SEER_RELEASE_TEST_LIST_PAGE_SIZE: "2",
      SEER_RELEASE_TEST_LIST_MAX_PAGES: "5",
    });
    assert.equal(result.status, 0, result.stderr);
    const state = readState();
    assert.equal(state.release.draft, true);
    assert.deepEqual(
      state.releaseListRequests.map(({ page }) => page),
      [1, 2, 3],
    );
  }, { releaseListPage: 3 });
});

test("release discovery fails closed when bounded pagination is exhausted without a definitive result", () => {
  withHarness(({ run, readState }) => {
    const result = run("preflight", {
      SEER_RELEASE_TEST_LIST_PAGE_SIZE: "2",
      SEER_RELEASE_TEST_LIST_MAX_PAGES: "3",
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /bounded page count/i);
    assert.ok(!readState().calls.some((call) => call.includes("PATCH")));
  }, { releaseListPage: 10 });
});

test("release discovery fails closed when multiple releases match the exact source tag", () => {
  withHarness(({ run, readState }) => {
    const result = run("preflight");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /multiple releases match/i);
    assert.ok(!readState().calls.some((call) => call.includes("PATCH")));
  }, { releaseListDuplicateOnMatchPage: true });
});

test("exact immutable published releases are accepted without mutation", () => {
  withHarness(({ run, readState }) => {
    const result = run("preflight");
    const state = readState();
    assert.equal(result.status, 0, result.stderr);
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
    assert.equal(captured.schema, 4);
    assert.equal(captured.releaseId, 42);
    assert.equal(captured.destinationAnchorCommit, releaseRepoCommit);
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
    assert.equal(
      requests.filter(({ url }) => /\/releases\/[0-9]+$/.test(url)).length,
      1,
    );
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

test("exact captured state with no prior latest publishes by release ID and explicitly becomes latest", () => {
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
    const payloadIndex = patch.indexOf("--data");
    assert.notEqual(payloadIndex, -1);
    assert.deepEqual(JSON.parse(patch[payloadIndex + 1]), {
      draft: false,
      prerelease: false,
      make_latest: "true",
    });
    assert.equal(state.authenticatedRequests.filter(({ method }) => method === "PATCH").length, 1);
    assert.equal(
      state.authenticatedRequests.filter(
        ({ method, url }) => method === "GET" && url.endsWith("/releases/latest"),
      ).length,
      2,
    );
    assert.equal(
      state.authenticatedRequests.filter(
        ({ method, url }) => method === "GET" && /\/releases\/[0-9]+$/.test(url),
      ).length,
      3,
    );
    assert.equal(state.latestRelease.id, state.release.id);
    assert.equal(state.latestRelease.tag, sourceTag);
    assert.equal(state.release.immutable, true);
    const patchCallIndex = state.calls.findIndex(
      (call) => call[0] === "curl" && call.includes("PATCH"),
    );
    const callEndpoint = (call) =>
      call.find((argument) => typeof argument === "string" && argument.startsWith("repos/")) ??
      call.find((argument) => /^https?:/.test(argument));
    assert.deepEqual(state.calls.slice(patchCallIndex - 6, patchCallIndex + 1).map(callEndpoint), [
      `repos/${sourceRepository}/git/ref/tags/${sourceTag}`,
      `repos/${destinationRepository}/git/commits/${releaseRepoCommit}`,
      `repos/${destinationRepository}/git/ref/tags/${sourceTag}`,
      `repos/${destinationRepository}/git/ref/tags/seer-release-lock-${sourceTag}`,
      `repos/${destinationRepository}/git/tags/${lockTagObjectSHA}`,
      `repos/${destinationRepository}/git/commits/${releaseRepoCommit}`,
      `https://api.github.test/repos/${destinationRepository}/releases/42`,
    ]);
    const finalDraftMetadataIndex = state.calls.findLastIndex(
      (call, index) =>
        index < patchCallIndex &&
        call[0] === "curl" &&
        call.includes("GET") &&
        call.some((argument) => argument.endsWith("/releases/42")),
    );
    const finalAssetIndexes = state.calls
      .map((call, index) => ({ call, index }))
      .filter(
        ({ call, index }) =>
          index < patchCallIndex &&
          call[0] === "curl" &&
          call.includes("GET") &&
          call.some((argument) => argument.includes("/releases/assets/")),
      )
      .slice(-expectedAssets.length)
      .map(({ index }) => index);
    const latestDecisionIndex = state.calls.findLastIndex(
      (call, index) =>
        index < finalDraftMetadataIndex &&
        call[0] === "curl" &&
        call.some((argument) => argument.endsWith("/releases/latest")),
    );
    const finalSourceTagIndex = patchCallIndex - 6;
    assert.ok(latestDecisionIndex < finalDraftMetadataIndex);
    assert.deepEqual(finalAssetIndexes, [
      finalDraftMetadataIndex + 1,
      finalDraftMetadataIndex + 2,
      finalDraftMetadataIndex + 3,
    ]);
    assert.equal(finalAssetIndexes.at(-1) + 1, finalSourceTagIndex);
    assert.doesNotMatch(
      `${result.stdout}\n${result.stderr}\n${JSON.stringify(state)}`,
      /test-token/,
    );
    assert.ok(
      !state.calls.some((call) => call[0] === "gh" && call[1] === "release" && call[2] === "edit"),
    );
    assert.ok(!state.calls.some((call) => call.includes("delete") || call.includes("DELETE")));
  });
});

test("a higher semantic version explicitly replaces the authenticated prior latest release", () => {
  withHarness(
    ({ run, readState, scratch }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish");
      assert.equal(result.status, 0, result.stderr);

      const state = readState();
      const patch = state.calls.find((call) => call[0] === "curl" && call.includes("PATCH"));
      const payloadIndex = patch.indexOf("--data");
      assert.equal(JSON.parse(patch[payloadIndex + 1]).make_latest, "true");
      assert.equal(state.latestRelease.id, state.release.id);
      assert.equal(state.latestRelease.tag, sourceTag);
      const inventory = JSON.parse(
        readFileSync(join(scratch, "pre-publish-inventory.json"), "utf8"),
      );
      const stable = inventory.releases.find(({ id }) => id === 41);
      assert.deepEqual(stable.author, releaseWriter);
      assert.deepEqual(
        stable.assets.map(({ name, uploader }) => ({ name, uploader })),
        stableAssetNames("v1.2.2").map((name) => ({ name, uploader: releaseWriter })),
      );
      assert.ok(
        !state.authenticatedRequests.some(({ url }) =>
          stable.assets.some(({ id }) => url.endsWith(`/releases/assets/${id}`)),
        ),
        "historical stable assets must be trusted from metadata without downloading bytes",
      );
    },
    { latestRelease: latestRelease("v1.2.2") },
  );
});

test("a lower backport publishes with make_latest false and preserves exact prior latest identity", () => {
  const priorLatest = latestRelease("v2.0.0", 84);
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish");
      assert.equal(result.status, 0, result.stderr);

      const state = readState();
      const patch = state.calls.find((call) => call[0] === "curl" && call.includes("PATCH"));
      const payloadIndex = patch.indexOf("--data");
      assert.equal(JSON.parse(patch[payloadIndex + 1]).make_latest, "false");
      assert.equal(state.release.draft, false);
      assert.equal(state.latestRelease.id, priorLatest.id);
      assert.equal(state.latestRelease.tag, priorLatest.tag);
    },
    { latestRelease: priorLatest },
  );
});

test("global release inventory exhausts multiple pages and excludes drafts and prereleases from the maximum", () => {
  const stableMaximum = latestRelease("v2.0.0", 84);
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish", {
        SEER_RELEASE_TEST_LIST_PAGE_SIZE: "2",
        SEER_RELEASE_TEST_LIST_MAX_PAGES: "5",
      });
      assert.equal(result.status, 0, result.stderr);

      const state = readState();
      const patch = state.calls.find((call) => call[0] === "curl" && call.includes("PATCH"));
      assert.equal(JSON.parse(patch[patch.indexOf("--data") + 1]).make_latest, "false");
      assert.ok(
        state.releaseListRequests.filter(({ page }) => page === 3).length >= 2,
        "pre- and post-publication inventory scans must reach the terminal third page",
      );
      assert.equal(state.latestRelease.id, stableMaximum.id);
    },
    {
      latestRelease: stableMaximum,
      inventoryReleases: [
        latestRelease("v99.0.0", 85, { draft: true, immutable: false }),
        latestRelease("v100.0.0", 86, { prerelease: true }),
        stableMaximum,
      ],
    },
  );
});

test("global release inventory fails closed when its configured final page is full", () => {
  const stableMaximum = latestRelease("v2.0.0", 84);
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish", {
        SEER_RELEASE_TEST_LIST_PAGE_SIZE: "2",
        SEER_RELEASE_TEST_LIST_MAX_PAGES: "2",
      });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /maximum|bounded|full page|truncat/i);
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    {
      latestRelease: stableMaximum,
      inventoryReleases: [
        stableMaximum,
        latestRelease("v99.0.0", 85, { draft: true, immutable: false }),
        latestRelease("v100.0.0", 86, { prerelease: true }),
      ],
    },
  );
});

test("malformed stable published inventory entries fail before publication", () => {
  const stableMaximum = latestRelease("v2.0.0", 84);
  const malformed = [
    latestRelease("2.1.0", 85),
    latestRelease("v02.1.0", 85),
    latestRelease("v9007199254740992.0.0", 85),
    latestRelease("v2.1.0", 85, { immutable: false }),
    latestRelease("v2.1.0", 0),
  ];
  for (const entry of malformed) {
    withHarness(
      ({ run, readState }) => {
        assert.equal(run("capture").status, 0);
        const result = run("publish");
        assert.notEqual(result.status, 0, `${entry.tag}/${entry.id} must fail`);
        assert.match(
          result.stderr,
          /inventory|stable published|canonical|oversized|immutable|positive safe/i,
        );
        assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
      },
      {
        latestRelease: stableMaximum,
        inventoryReleases: [stableMaximum, entry],
      },
    );
  }
});

test("stable inventory rejects foreign authors and uploaders plus missing or extra assets", () => {
  const trusted = latestRelease("v2.0.0", 84);
  const foreign = { id: 99, login: "foreign-writer" };
  const cases = [
    ["foreign author", latestRelease("v2.0.0", 84, { author: foreign })],
    [
      "foreign uploader",
      latestRelease("v2.0.0", 84, {
        assets: trusted.assets.map((item, index) => ({
          ...item,
          ...(index === 0 ? { uploader: foreign } : {}),
        })),
      }),
    ],
    ["missing asset", latestRelease("v2.0.0", 84, { assets: trusted.assets.slice(1) })],
    [
      "extra asset",
      latestRelease("v2.0.0", 84, {
        assets: [...trusted.assets, asset("foreign-debug-symbols.zip", 999)],
      }),
    ],
  ];

  for (const [name, untrusted] of cases) {
    withHarness(
      ({ run, readState }) => {
        assert.equal(run("capture").status, 0);
        const result = run("publish");
        assert.notEqual(result.status, 0, `${name} must fail`);
        assert.match(result.stderr, /stable|author|uploader|asset|writer|allowlist/i);
        assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
      },
      {
        latestRelease: trusted,
        inventoryReleases: [untrusted],
      },
    );
  }
});

test("latest endpoint rejects foreign authors and uploaders plus missing or extra assets", () => {
  const trusted = latestRelease("v2.0.0", 84);
  const foreign = { id: 99, login: "foreign-writer" };
  const cases = [
    ["foreign author", latestRelease("v2.0.0", 84, { author: foreign })],
    [
      "foreign uploader",
      latestRelease("v2.0.0", 84, {
        assets: trusted.assets.map((item, index) => ({
          ...item,
          ...(index === 0 ? { uploader: foreign } : {}),
        })),
      }),
    ],
    ["missing asset", latestRelease("v2.0.0", 84, { assets: trusted.assets.slice(1) })],
    [
      "extra asset",
      latestRelease("v2.0.0", 84, {
        assets: [...trusted.assets, asset("foreign-debug-symbols.zip", 999)],
      }),
    ],
  ];

  for (const [name, untrusted] of cases) {
    withHarness(
      ({ run, readState }) => {
        assert.equal(run("capture").status, 0);
        const result = run("publish");
        assert.notEqual(result.status, 0, `${name} must fail`);
        assert.match(result.stderr, /latest|author|uploader|asset|writer|allowlist/i);
        assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
      },
      {
        latestRelease: untrusted,
        inventoryReleases: [trusted],
      },
    );
  }
});

test("duplicate canonical stable versions and duplicate list identities fail closed", () => {
  const stableMaximum = latestRelease("v2.0.0", 84);
  for (const duplicate of [latestRelease("v2.0.0", 85), structuredClone(stableMaximum)]) {
    withHarness(
      ({ run, readState }) => {
        assert.equal(run("capture").status, 0);
        const result = run("publish", {
          SEER_RELEASE_TEST_LIST_PAGE_SIZE: "2",
          SEER_RELEASE_TEST_LIST_MAX_PAGES: "5",
        });
        assert.notEqual(result.status, 0);
        assert.match(result.stderr, /duplicate|semantic version|list mutation|ambiguous/i);
        assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
      },
      {
        latestRelease: stableMaximum,
        inventoryReleases: [stableMaximum, duplicate],
      },
    );
  }
});

test("release inventory mutation between exhaustive confirmation scans fails closed", () => {
  const stableMaximum = latestRelease("v2.0.0", 84);
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish");
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /inventory|list.*mutat|changed between/i);
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    {
      latestRelease: stableMaximum,
      inventoryReleases: [stableMaximum],
      releaseListMutationAfterScan: 4,
      mutatedInventoryReleases: [
        stableMaximum,
        latestRelease("v99.0.0", 85, { draft: true, immutable: false }),
      ],
    },
  );
});

test("inventory rejects reuse of the current draft ID by another listed release", () => {
  const stableMaximum = latestRelease("v2.0.0", 84);
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish");
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /current draft|duplicate release ID|list mutation|reuse/i);
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    {
      latestRelease: stableMaximum,
      inventoryReleases: [stableMaximum, latestRelease("v3.0.0", 42)],
    },
  );
});

test("publication rejects a pre-existing latest pointer that is not the inventory maximum", () => {
  const staleLatest = latestRelease("v2.0.0", 84);
  const actualMaximum = latestRelease("v3.0.0", 85);
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish");
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /latest.*global maximum|inventory maximum|invariant|mismatch/i);
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    {
      latestRelease: staleLatest,
      inventoryReleases: [staleLatest, actualMaximum],
    },
  );
});

test("post-publication verification uses a fresh inventory maximum rather than the prior decision", () => {
  const priorLatest = latestRelease("v1.2.2", 41);
  const interveningMaximum = latestRelease("v9.9.9", 99);
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish");
      assert.notEqual(result.status, 0);
      assert.match(
        result.stderr,
        /post-publish|post-publication|global maximum|invariant|mismatch/i,
      );

      const state = readState();
      assert.equal(state.release.draft, false);
      assert.equal(
        state.authenticatedRequests.filter(({ method }) => method === "PATCH").length,
        1,
      );
    },
    {
      latestRelease: priorLatest,
      inventoryReleases: [priorLatest],
      postInventoryReleases: [priorLatest, interveningMaximum],
    },
  );
});

test("post-publication verification binds the decision to its exact pre-publication inventory", () => {
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish");
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /decision.*inventory|inventory.*binding|fingerprint/i);
      assert.equal(readState().release.draft, false);
    },
    { tamperDecisionFingerprint: true },
  );
});

test("post-publication latest API failure cannot be mistaken for a verified pointer", () => {
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish");
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /latest release.*(?:HTTP|status|request)/i);
      assert.equal(readState().release.draft, false);
    },
    { postLatestResponseStatus: 500 },
  );
});

test("authenticated inventory API failures stop both pre- and post-publication verification", () => {
  const stableMaximum = latestRelease("v2.0.0", 84);
  for (const [phase, options, expectedDraft] of [
    ["pre-publication", { releaseListFailurePage: 2 }, true],
    ["post-publication", { postReleaseListFailurePage: 2 }, false],
  ]) {
    withHarness(
      ({ run, readState }) => {
        assert.equal(run("capture").status, 0);
        const result = run("publish", {
          SEER_RELEASE_TEST_LIST_PAGE_SIZE: "2",
          SEER_RELEASE_TEST_LIST_MAX_PAGES: "5",
        });
        assert.notEqual(result.status, 0, `${phase} failure must stop publication verification`);
        assert.match(result.stderr, /release.*(?:inventory|list).*(?:API|request|fail)/i);
        assert.equal(readState().release.draft, expectedDraft);
      },
      {
        latestRelease: stableMaximum,
        inventoryReleases: [
          stableMaximum,
          latestRelease("v99.0.0", 85, { draft: true, immutable: false }),
        ],
        ...options,
      },
    );
  }
});

test("malformed, noncanonical, and oversized latest semantic-version tags fail closed", () => {
  for (const tag of ["1.2.2", "v01.2.2", "v9007199254740992.0.0"]) {
    withHarness(
      ({ run, readState }) => {
        assert.equal(run("capture").status, 0);
        const result = run("publish");
        assert.notEqual(result.status, 0, `${tag} must fail`);
        assert.match(result.stderr, /latest release tag|canonical|semantic version|oversized/i);
        const state = readState();
        assert.equal(state.release.draft, true);
        assert.ok(!state.authenticatedRequests.some(({ method }) => method === "PATCH"));
      },
      { latestRelease: latestRelease(tag) },
    );
  }
});

test("unacceptable latest release state fails closed before publication", () => {
  for (const overrides of [{ prerelease: true }, { immutable: false }, { draft: true }]) {
    withHarness(
      ({ run, readState }) => {
        assert.equal(run("capture").status, 0);
        const result = run("publish");
        assert.notEqual(result.status, 0);
        assert.match(result.stderr, /latest release state|stable|published|immutable/i);
        assert.equal(readState().release.draft, true);
        assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
      },
      { latestRelease: latestRelease("v1.2.2", 41, overrides) },
    );
  }
});

test("latest release API failure stops publication without treating it as no releases", () => {
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish");
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /latest release.*(?:HTTP|status|request)/i);
      const state = readState();
      assert.equal(state.release.draft, true);
      assert.ok(!state.authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    { latestResponseStatus: 500 },
  );
});

test("same-version prior latest with a different release identity is ambiguous and fails closed", () => {
  withHarness(
    ({ run, readState }) => {
      const result = run("capture");
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /multiple releases match|same semantic version|ambiguous/i);
      assert.equal(readState().release.draft, true);
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    { latestRelease: latestRelease(sourceTag, 84) },
  );
});

for (const tag of ["v1.2.2", "v2.0.0"]) {
  test(`latest decision rejects current draft release ID reuse by prior latest ${tag}`, () => {
    withHarness(
      ({ run, readState }) => {
        assert.equal(run("capture").status, 0);
        const result = run("publish");

        assert.notEqual(result.status, 0, `${tag} must fail`);
        assert.match(
          result.stderr,
          /current draft release ID|canonical 404|global maximum|malformed/i,
        );
        const state = readState();
        assert.equal(state.release.draft, true);
        assert.ok(!state.authenticatedRequests.some(({ method }) => method === "PATCH"));
      },
      { latestRelease: latestRelease(tag, 42) },
    );
  });
}

test("post-publish latest mismatch fails after exact immutable publication verification", () => {
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish");
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /post-publish|post-publication.*latest release|global maximum/i);

      const state = readState();
      assert.equal(state.release.draft, false);
      assert.equal(state.release.immutable, true);
      assert.equal(
        state.authenticatedRequests.filter(({ method }) => method === "PATCH").length,
        1,
      );
    },
    {
      latestRelease: latestRelease("v1.2.2"),
      postLatestRelease: latestRelease("v9.9.9", 99),
    },
  );
});

test("ambiguous publish responses are reconciled against exact post-request state", () => {
  for (const [outcome, expectedStatus, expectedDraft] of [
    ["lost-applied", 0, false],
    ["lost-unchanged", 1, true],
    ["lost-mutated", 1, false],
  ]) {
    withHarness(
      ({ run, readState }) => {
        assert.equal(run("capture").status, 0);
        const result = run("publish");
        assert.equal(result.status === 0 ? 0 : 1, expectedStatus, `${outcome}: ${result.stderr}`);
        assert.equal(readState().release.draft, expectedDraft);
        assert.equal(
          readState().authenticatedRequests.filter(({ method }) => method === "PATCH").length,
          1,
        );
        if (outcome === "lost-unchanged") assert.match(result.stderr, /draft.*unchanged|retry/i);
        if (outcome === "lost-mutated") assert.match(result.stderr, /differs|canonical|mismatch/i);
      },
      { patchOutcome: outcome },
    );
  }
});

test("publish requires independent evidence for a preexisting immutable release", () => {
  withHarness(({ run, readState, writeState }) => {
    assert.equal(run("capture").status, 0);
    const state = readState();
    state.release.draft = false;
    state.release.immutable = true;
    state.release.updatedAt = "2026-08-15T18:02:00Z";
    writeState(state);

    const result = run("publish");

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /existing-published-state evidence is required/i);
    assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
  });
});

test("upload never clobbers an immutable published release", () => {
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("preflight").status, 0);
      const result = run("upload");

      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /reconciled|refusing to overwrite/i);
      assert.ok(
        !readState().calls.some(
          (call) => call[0] === "gh" && call[1] === "release" && call[2] === "upload",
        ),
      );
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    {
      release: matchingRelease({
        draft: false,
        immutable: true,
        updatedAt: "2026-08-15T18:02:00Z",
      }),
    },
  );
});

test("published retry accepts the current release only when fresh latest has its exact identity", () => {
  const release = matchingRelease({
    draft: false,
    immutable: true,
    updatedAt: "2026-08-15T18:02:00Z",
    assets: publishedAssets(),
  });
  withHarness(
    ({ run, readState, githubOutput }) => {
      const result = run("reconcile-published");

      assert.equal(result.status, 0, result.stderr);
      assert.match(readFileSync(githubOutput, "utf8"), /^published=true$/m);
      const state = readState();
      assert.equal(
        state.authenticatedRequests.filter(
          ({ method, url }) => method === "GET" && url.endsWith("/releases/latest"),
        ).length,
        1,
      );
      assert.ok(!state.authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    { release, latestRelease: structuredClone(release) },
  );
});

test("published backport retry accepts an intervening higher release only as the fresh global maximum", () => {
  const higherLatest = latestRelease("v2.0.0", 84);
  withHarness(
    ({ run, readState, githubOutput }) => {
      const result = run("reconcile-published");

      assert.equal(result.status, 0, result.stderr);
      assert.match(readFileSync(githubOutput, "utf8"), /^published=true$/m);
      const state = readState();
      assert.equal(state.latestRelease.id, higherLatest.id);
      assert.equal(
        state.authenticatedRequests.filter(
          ({ method, url }) => method === "GET" && url.endsWith("/releases/latest"),
        ).length,
        1,
      );
      assert.ok(!state.authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    {
      release: matchingRelease({
        draft: false,
        immutable: true,
        updatedAt: "2026-08-15T18:02:00Z",
        assets: publishedAssets(),
      }),
      latestRelease: higherLatest,
    },
  );
});

test("published retry fails when latest is not the fresh inventory maximum", () => {
  const staleLatest = latestRelease("v2.0.0", 84);
  const interveningMaximum = latestRelease("v3.0.0", 85);
  withHarness(
    ({ run, readState, githubOutput }) => {
      const result = run("reconcile-published");

      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /latest.*global maximum|inventory maximum|invariant|mismatch/i);
      assert.equal(existsSync(githubOutput), false);
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    {
      release: matchingRelease({
        draft: false,
        immutable: true,
        updatedAt: "2026-08-15T18:02:00Z",
        assets: publishedAssets(),
      }),
      latestRelease: staleLatest,
      inventoryReleases: [staleLatest, interveningMaximum],
    },
  );
});

test("published retry rejects a lower latest because the current release should be latest", () => {
  withHarness(
    ({ run, readState, githubOutput }) => {
      const result = run("reconcile-published");

      assert.notEqual(result.status, 0);
      assert.match(
        result.stderr,
        /global maximum|current published release.*should be latest|lower latest/i,
      );
      assert.equal(existsSync(githubOutput), false);
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    {
      release: matchingRelease({
        draft: false,
        immutable: true,
        updatedAt: "2026-08-15T18:02:00Z",
        assets: publishedAssets(),
      }),
      latestRelease: latestRelease("v1.2.2", 41),
    },
  );
});

test("published retry rejects a same-version latest release with a different ID", () => {
  withHarness(
    ({ run, readState, githubOutput }) => {
      const result = run("reconcile-published");

      assert.notEqual(result.status, 0);
      assert.match(
        result.stderr,
        /multiple releases match|same semantic version|exact release identity|release ID/i,
      );
      assert.equal(existsSync(githubOutput), false);
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    {
      release: matchingRelease({
        draft: false,
        immutable: true,
        updatedAt: "2026-08-15T18:02:00Z",
        assets: publishedAssets(),
      }),
      latestRelease: latestRelease(sourceTag, 84),
    },
  );
});

test("published retry rejects the current release ID paired with a different latest tag", () => {
  withHarness(
    ({ run, readState, githubOutput }) => {
      const result = run("reconcile-published");

      assert.notEqual(result.status, 0);
      assert.match(
        result.stderr,
        /global maximum|current release ID.*different tag|identity.*malformed/i,
      );
      assert.equal(existsSync(githubOutput), false);
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
    },
    {
      release: matchingRelease({
        draft: false,
        immutable: true,
        updatedAt: "2026-08-15T18:02:00Z",
        assets: publishedAssets(),
      }),
      latestRelease: latestRelease("v2.0.0", 42),
    },
  );
});

for (const entry of [
  {
    name: "absent",
    options: { latestRelease: null },
    pattern:
      /global maximum|canonical 404|latest release endpoint returned no release|published release.*latest/i,
  },
  {
    name: "malformed",
    options: { latestResponseBody: JSON.stringify({ id: 42, tag_name: sourceTag }) },
    pattern: /latest release response.*invalid shape|latest release state/i,
  },
  {
    name: "API error",
    options: { latestResponseStatus: 500 },
    pattern: /latest release.*(?:HTTP|status|request)/i,
  },
]) {
  test(`published retry fails closed when latest is ${entry.name}`, () => {
    withHarness(
      ({ run, readState, githubOutput }) => {
        const result = run("reconcile-published");

        assert.notEqual(result.status, 0, `${entry.name} must fail`);
        assert.match(result.stderr, entry.pattern);
        assert.equal(existsSync(githubOutput), false);
        assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
      },
      {
        release: matchingRelease({
          draft: false,
          immutable: true,
          updatedAt: "2026-08-15T18:02:00Z",
          assets: publishedAssets(),
        }),
        ...entry.options,
      },
    );
  });
}

test("published reconciliation validates remote timestamped assets without comparing rebuilt bytes", () => {
  const remoteAssets = publishedAssets();
  withHarness(
    ({ run, readState, releaseDir, githubOutput, platformLog, scratch }) => {
      assert.notEqual(
        readFileSync(join(releaseDir, expectedAssets[0])),
        remoteAssets[0].contents,
        "the rebuilt test artifact must differ from the published timestamped artifact",
      );

      const result = run("reconcile-published");

      assert.equal(result.status, 0, result.stderr);
      const outputs = readFileSync(githubOutput, "utf8");
      assert.match(outputs, /^published=true$/m);
      assert.match(outputs, /^existing-published-state=.+$/m);
      assert.match(outputs, /^release-directory=.+$/m);
      assert.equal(readFileSync(platformLog, "utf8").trim().split("\n").length, 1);
      assert.ok(
        !readState().calls.some(
          (call) => call[0] === "gh" && call[1] === "release" && call[2] === "upload",
        ),
      );
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
      assert.ok(
        readFileSync(join(scratch, "existing-published-state.json"), "utf8").includes(
          '"kind": "existing-published-state"',
        ),
      );
    },
    {
      release: matchingRelease({
        draft: false,
        immutable: true,
        updatedAt: "2026-08-15T18:02:00Z",
        assets: remoteAssets,
      }),
    },
  );
});

test("published reconciliation rejects exact DMG/app identity and mounted app metadata mismatches", () => {
  const cases = [
    {
      name: "DMG signer authority",
      env: { FAKE_PUBLISHED_DMG_AUTHORITY: "Developer ID Application: Other (ABCDEFGHIJ)" },
      pattern: /published DMG authority does not match APPLE_SIGNING_IDENTITY/i,
    },
    {
      name: "DMG Team ID",
      env: { FAKE_PUBLISHED_DMG_TEAM_ID: "ZZZZZZZZZZ" },
      pattern: /published DMG team identifier does not match APPLE_TEAM_ID/i,
    },
    {
      name: "app signer authority",
      env: { FAKE_PUBLISHED_APP_AUTHORITY: "Developer ID Application: Other (ABCDEFGHIJ)" },
      pattern: /published app authority does not match APPLE_SIGNING_IDENTITY/i,
    },
    {
      name: "app Team ID",
      env: { FAKE_PUBLISHED_APP_TEAM_ID: "ZZZZZZZZZZ" },
      pattern: /published app team identifier does not match APPLE_TEAM_ID/i,
    },
    {
      name: "bundle identifier",
      env: { FAKE_PUBLISHED_BUNDLE_IDENTIFIER: "example.invalid.seer" },
      pattern: /published app bundle identifier is not ai\.opencoven\.seer/i,
    },
    {
      name: "marketing version",
      env: { FAKE_PUBLISHED_MARKETING_VERSION: "9.9.9" },
      pattern: /published app CFBundleShortVersionString does not match VERSION/i,
    },
    {
      name: "build number",
      env: { FAKE_PUBLISHED_BUILD_NUMBER: "999" },
      pattern: /published app CFBundleVersion does not match BUILD_NUMBER/i,
    },
  ];

  for (const entry of cases) {
    withHarness(
      ({ run, readState }) => {
        const result = run("reconcile-published", entry.env);
        assert.notEqual(result.status, 0, `${entry.name} mismatch must fail`);
        assert.match(result.stderr, entry.pattern);
        assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
      },
      {
        release: matchingRelease({
          draft: false,
          immutable: true,
          updatedAt: "2026-08-15T18:02:00Z",
          assets: publishedAssets(),
        }),
      },
    );
  }
});

test("published reconciliation rejects unsafe expected signing identities before platform verification", () => {
  const cases = [
    {
      name: "empty identity",
      env: { APPLE_SIGNING_IDENTITY: "" },
      pattern: /APPLE_SIGNING_IDENTITY is required/i,
    },
    {
      name: "line feed",
      env: { APPLE_SIGNING_IDENTITY: `${signingIdentity}\nignored` },
      pattern: /APPLE_SIGNING_IDENTITY must not contain CR or LF/i,
    },
    {
      name: "carriage return",
      env: { APPLE_SIGNING_IDENTITY: `${signingIdentity}\rignored` },
      pattern: /APPLE_SIGNING_IDENTITY must not contain CR or LF/i,
    },
    {
      name: "wrong authority kind",
      env: { APPLE_SIGNING_IDENTITY: "Apple Development: OpenCoven (ABCDEFGHIJ)" },
      pattern: /exact Developer ID Application authority for APPLE_TEAM_ID/i,
    },
    {
      name: "wrong authority team",
      env: { APPLE_SIGNING_IDENTITY: "Developer ID Application: OpenCoven (ZZZZZZZZZZ)" },
      pattern: /exact Developer ID Application authority for APPLE_TEAM_ID/i,
    },
    {
      name: "invalid expected team",
      env: { APPLE_TEAM_ID: "abcdefghij" },
      pattern: /APPLE_TEAM_ID must be a 10-character uppercase Apple team identifier/i,
    },
  ];

  for (const entry of cases) {
    withHarness(
      ({ run, readState, platformLog }) => {
        const result = run("reconcile-published", entry.env);
        assert.notEqual(result.status, 0, `${entry.name} must fail`);
        assert.match(result.stderr, entry.pattern);
        assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
        assert.equal(existsSync(platformLog), false);
      },
      {
        release: matchingRelease({
          draft: false,
          immutable: true,
          updatedAt: "2026-08-15T18:02:00Z",
          assets: publishedAssets(),
        }),
      },
    );
  }
});

test("published reconciliation fails closed on source, manifest, hash, or signature mismatch", () => {
  const cases = [
    {
      name: "source",
      release: matchingRelease({
        draft: false,
        immutable: true,
        body: canonicalBody.replace(sourceCommit, "b".repeat(40)),
        assets: publishedAssets(),
      }),
      env: {},
      pattern: /provenance|source/i,
    },
    {
      name: "manifest",
      release: matchingRelease({
        draft: false,
        immutable: true,
        assets: publishedAssets({ manifestOverrides: { sourceCommit: "b".repeat(40) } }),
      }),
      env: {},
      pattern: /manifest.*source commit/i,
    },
    {
      name: "hash",
      release: matchingRelease({
        draft: false,
        immutable: true,
        assets: publishedAssets({ checksumDigest: "f".repeat(64) }),
      }),
      env: {},
      pattern: /SHA256SUMS|checksum|DMG hash/i,
    },
    {
      name: "signature",
      release: matchingRelease({
        draft: false,
        immutable: true,
        assets: publishedAssets(),
      }),
      env: { FAKE_PLATFORM_RESULT: "fail" },
      pattern: /signature|notarization/i,
    },
  ];

  for (const entry of cases) {
    withHarness(
      ({ run, readState }) => {
        const result = run("reconcile-published", entry.env);
        assert.notEqual(result.status, 0, `${entry.name} mismatch must fail`);
        assert.match(result.stderr, entry.pattern);
        assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
        assert.ok(
          !readState().calls.some(
            (call) => call[0] === "gh" && call[1] === "release" && call[2] === "upload",
          ),
        );
      },
      { release: entry.release },
    );
  }
});

test("published reconciliation rejects foreign assets and never mutates the release", () => {
  withHarness(
    ({ run, readState }) => {
      const result = run("reconcile-published");
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /foreign release asset/);
      assert.ok(
        !readState().calls.some(
          (call) => call.includes("DELETE") || call.includes("PATCH") || call.includes("upload"),
        ),
      );
    },
    {
      release: matchingRelease({
        draft: false,
        immutable: true,
        assets: [...publishedAssets(), asset("foreign-debug-symbols.zip", 999)],
      }),
    });
});

test("publish accepts independently reconciled existing-published-state evidence", () => {
    const remoteAssets = publishedAssets();
    withHarness(({ run, releaseDir, readState }) => {
      assert.equal(run("reconcile-published").status, 0);
      writeFileSync(
        join(releaseDir, expectedAssets[0]),
        "different-locally-rebuilt-timestamped-signature\n",
      );

      const result = run("publish", {
        EXISTING_PUBLISHED_STATE: join(dirname(releaseDir), "existing-published-state.json"),
      });

      assert.equal(result.status, 0, result.stderr);
      assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
    }, {
      release: matchingRelease({
        draft: false,
        immutable: true,
        updatedAt: "2026-08-15T18:02:00Z",
        assets: remoteAssets,
      }),
    });
});

test("full workflow retry rejects a foreign immutable published release", () => {
  withHarness(({ run }) => {
    const result = run("preflight");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /canonical title|published/i);
  }, {
    release: matchingRelease({
      draft: false,
      immutable: true,
      title: `${canonicalTitle} foreign`,
    }),
  });
});

test("source tag verification peels annotated tags and rejects force-moves", () => {
  const annotatedSHA = "f".repeat(40);
  withHarness(({ run }) => {
    const result = run("verify-source-tag");
    assert.equal(result.status, 0, result.stderr);
  }, {
    sourceTagRef: {
      ref: `refs/tags/${sourceTag}`,
      object: { type: "tag", sha: annotatedSHA },
    },
    sourceTagObjects: {
      [annotatedSHA]: {
        sha: annotatedSHA,
        tag: sourceTag,
        object: { type: "commit", sha: sourceCommit },
      },
    },
  });

  withHarness(({ run }) => {
    const result = run("verify-source-tag");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /source tag.*moved|source commit/i);
  }, {
    sourceTagRef: {
      ref: `refs/tags/${sourceTag}`,
      object: { type: "commit", sha: "b".repeat(40) },
    },
  });
});

test("publish re-resolves the source tag after capture and before PATCH", () => {
  withHarness(({ run, readState, writeState }) => {
    assert.equal(run("capture").status, 0);
    const state = readState();
    state.sourceTagRef.object.sha = "b".repeat(40);
    writeState(state);

    const result = run("publish");

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /source tag moved/i);
    assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
  });
});

test("draft mutation during inventory is caught by final byte verification before PATCH", () => {
  withHarness(
    ({ run, readState }) => {
      assert.equal(run("capture").status, 0);
      const result = run("publish");

      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /fresh download|verified bytes|release asset/i);
      const state = readState();
      assert.equal(state.draftInventoryMutationApplied, true);
      assert.equal(state.release.draft, true);
      assert.ok(!state.authenticatedRequests.some(({ method }) => method === "PATCH"));
      const latestIndex = state.calls.findLastIndex(
        (call) =>
          call[0] === "curl" && call.some((argument) => argument.endsWith("/releases/latest")),
      );
      const finalAssetIndex = state.calls.findLastIndex(
        (call) =>
          call[0] === "curl" && call.some((argument) => argument.includes("/releases/assets/")),
      );
      assert.ok(
        finalAssetIndex > latestIndex,
        "fresh byte verification must run after inventory/latest",
      );
    },
    { mutateDraftAtReleaseListScan: 3 },
  );
});

test("source tag, destination tag, and destination anchor movement during inventory fail in final pre-PATCH checks", () => {
  for (const [name, option, pattern] of [
    ["source", "moveSourceTagAtReleaseListScan", /source tag moved/i],
    ["destination", "moveDestinationTagAtReleaseListScan", /destination tag|anchor/i],
    ["anchor", "moveLockAnchorAtReleaseListScan", /lock destination anchor changed/i],
  ]) {
    withHarness(
      ({ run, readState }) => {
        assert.equal(run("capture").status, 0);
        const result = run("publish");

        assert.notEqual(result.status, 0, `${name} tag movement must fail`);
        assert.match(result.stderr, pattern);
        assert.equal(readState().release.draft, true);
        assert.ok(!readState().authenticatedRequests.some(({ method }) => method === "PATCH"));
      },
      { [option]: 3 },
    );
  }
});

test("destination tag is atomically anchored before draft creation and exact on retry", () => {
  withHarness(({ run, readState }) => {
    const result = run("upload");
    assert.equal(result.status, 0, result.stderr);
    const state = readState();
    assert.deepEqual(state.destinationTagRef, {
      ref: `refs/tags/${sourceTag}`,
      object: { type: "commit", sha: releaseRepoCommit },
    });
    const create = state.calls.find((call) => call[0] === "gh" && call[1] === "release" && call[2] === "create");
    assert.ok(create.includes("--verify-tag"));
    assert.deepEqual(create.slice(create.indexOf("--target"), create.indexOf("--target") + 2), [
      "--target",
      releaseRepoCommit,
    ]);
  }, { release: null, destinationTagRef: null });

  const annotatedSHA = "9".repeat(40);
  withHarness(({ run }) => {
    const result = run("preflight");
    assert.equal(result.status, 0, result.stderr);
  }, {
    destinationTagRef: {
      ref: `refs/tags/${sourceTag}`,
      object: { type: "tag", sha: annotatedSHA },
    },
    destinationTagObjects: {
      [annotatedSHA]: {
        sha: annotatedSHA,
        tag: sourceTag,
        object: { type: "commit", sha: releaseRepoCommit },
      },
    },
  });

  withHarness(({ run }) => {
    const result = run("preflight");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /destination tag|anchor|collision/i);
  }, {
    release: null,
    destinationTagRef: {
      ref: `refs/tags/${sourceTag}`,
      object: { type: "commit", sha: "b".repeat(40) },
    },
  });
});
