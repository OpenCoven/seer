#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync, statSync, writeFileSync } from "node:fs";

const [command, metadataPath, _headersPath, releaseDir, notesPath, statePath, downloadsDir] =
  process.argv.slice(2);

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
};

const sourceRepository = required("SOURCE_REPOSITORY");
const sourceCommit = required("SOURCE_COMMIT");
const sourceTag = required("SOURCE_TAG");
const workflowRef = required("WORKFLOW_REF");
const workflowRun = required("WORKFLOW_RUN");
const workflowAttempt = required("WORKFLOW_ATTEMPT");
const version = required("VERSION");
const destinationRepository = required("GH_REPO");
const releaseWriter = {
  id: Number(required("RELEASE_WRITER_ID")),
  login: required("RELEASE_WRITER_LOGIN"),
};
const expectedTitle = `Seer ${version}`;
const expectedMarker =
  `<!-- seer-release-provenance:{"schema":1,"sourceRepository":"${sourceRepository}",` +
  `"sourceCommit":"${sourceCommit}","sourceTag":"${sourceTag}","workflowRef":"${workflowRef}",` +
  `"workflowRun":"${workflowRun}"} -->`;
const expectedBody =
  `${expectedMarker}\n\nSeer ${version} for Apple Silicon Macs running macOS 14 or later.\n`;
const expectedNames = [`Seer-v${version}-arm64.dmg`, "SHA256SUMS", "release-manifest.json"];
const expectedLockMetadata = {
  lockSchema: 1,
  sourceRepository,
  sourceCommit,
  sourceTag,
  workflowRef,
  workflowRun,
  workflowAttempt,
};
function fail(message) {
  throw new Error(message);
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function parseJSON(source, description) {
  try {
    return JSON.parse(source);
  } catch {
    return fail(`${description} is not valid JSON`);
  }
}

function readJSON(path, description) {
  return parseJSON(readFileSync(path, "utf8"), description);
}

async function readStdinJSON(description) {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return parseJSON(Buffer.concat(chunks).toString("utf8"), description);
}

function validateUser(value, description) {
  if (
    !value ||
    typeof value !== "object" ||
    !Number.isSafeInteger(value.id) ||
    value.id <= 0 ||
    typeof value.login !== "string" ||
    value.id !== releaseWriter.id ||
    value.login !== releaseWriter.login
  ) {
    fail(`${description} does not match the exact protected release writer identity`);
  }
  return { id: value.id, login: value.login };
}

function parseMetadata(value, { requireComplete, expectedDraft }) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("release metadata has an invalid shape");
  }
  const {
    id,
    draft,
    prerelease,
    immutable,
    tag_name: tagName,
    name: title,
    body,
    updated_at: updatedAt,
    author,
    assets,
  } = value;
  if (
    !Number.isSafeInteger(id) ||
    id <= 0 ||
    typeof draft !== "boolean" ||
    typeof prerelease !== "boolean" ||
    typeof immutable !== "boolean" ||
    typeof tagName !== "string" ||
    typeof title !== "string" ||
    typeof body !== "string" ||
    typeof updatedAt !== "string" ||
    updatedAt.length === 0 ||
    !Array.isArray(assets)
  ) {
    fail("release metadata has an invalid shape");
  }
  if (expectedDraft !== undefined && draft !== expectedDraft) {
    fail(expectedDraft ? "verified release is no longer a draft" : "post-publish release is still a draft");
  }
  if (prerelease !== false) fail("stable release workflow refuses prerelease metadata");
  if (!draft && !immutable) fail("published release is not protected by immutable releases");
  if (tagName !== sourceTag) fail(`draft release tag does not match ${sourceTag}`);
  if (title !== expectedTitle) fail("release canonical title does not match");
  if (body.split("\n", 1)[0] !== expectedMarker) {
    fail("draft provenance marker does not match the source commit, tag, repository, and workflow");
  }
  if (body !== expectedBody) fail("release canonical body does not match exactly");
  const normalizedAuthor = validateUser(author, "release author");

  const seenNames = new Set();
  const seenIDs = new Set();
  const normalizedAssets = assets.map((item) => {
    if (
      !item ||
      typeof item !== "object" ||
      !Number.isSafeInteger(item.id) ||
      item.id <= 0 ||
      typeof item.name !== "string" ||
      !Number.isSafeInteger(item.size) ||
      item.size < 0 ||
      !(item.digest === null || item.digest === undefined || typeof item.digest === "string")
    ) {
      fail("release asset metadata has an invalid shape");
    }
    if (!expectedNames.includes(item.name)) fail("draft contains a foreign release asset");
    if (seenNames.has(item.name) || seenIDs.has(item.id)) {
      fail("draft contains duplicate release asset metadata");
    }
    seenNames.add(item.name);
    seenIDs.add(item.id);
    if (typeof item.digest === "string" && !/^sha256:[0-9a-f]{64}$/.test(item.digest)) {
      fail(`release asset ${item.name} has an invalid digest`);
    }
    return {
      id: item.id,
      name: item.name,
      size: item.size,
      serverDigest: item.digest ?? null,
      uploader: validateUser(item.uploader, `release asset uploader for ${item.name}`),
    };
  });

  const complete =
    expectedNames.every((name) => seenNames.has(name)) &&
    normalizedAssets.length === expectedNames.length;
  if (requireComplete && !complete) {
    fail("draft release does not contain the complete public asset allowlist");
  }
  normalizedAssets.sort((a, b) => expectedNames.indexOf(a.name) - expectedNames.indexOf(b.name));
  return {
    id,
    draft,
    prerelease,
    immutable,
    tagName,
    title,
    body,
    updatedAt,
    author: normalizedAuthor,
    assets: normalizedAssets,
    complete,
  };
}

function readMetadata(path, options) {
  return parseMetadata(readJSON(path, "release metadata"), options);
}

function regularFile(path, description) {
  let stat;
  try {
    stat = statSync(path);
  } catch {
    return fail(`${description} is missing`);
  }
  if (!stat.isFile()) fail(`${description} is not a regular file`);
  return { bytes: readFileSync(path), size: stat.size };
}

function validateLocal(metadata, localDir, localNotes, freshDownloads) {
  const notes = regularFile(localNotes, "release notes");
  if (notes.bytes.toString("utf8") !== expectedBody) {
    fail("local release notes do not match the canonical body");
  }
  const assets = [];
  for (const expectedName of expectedNames) {
    const remote = metadata.assets.find(({ name }) => name === expectedName);
    if (!remote) fail(`release metadata is missing ${expectedName}`);
    const local = regularFile(`${localDir}/${expectedName}`, `local release asset ${expectedName}`);
    if (local.size !== remote.size) {
      fail(`release asset ${expectedName} size does not match local verified bytes`);
    }
    const digest = sha256(local.bytes);
    if (remote.serverDigest !== null && remote.serverDigest !== `sha256:${digest}`) {
      fail(`release asset ${expectedName} digest does not match local verified bytes`);
    }
    const downloaded = regularFile(
      `${freshDownloads}/${remote.id}`,
      `fresh download for release asset ${expectedName}`,
    );
    if (!downloaded.bytes.equals(local.bytes)) {
      fail(`fresh download for release asset ${expectedName} does not match local verified bytes`);
    }
    assets.push({ ...remote, sha256: digest });
  }
  return {
    notes: { size: notes.size, sha256: sha256(notes.bytes) },
    assets,
  };
}

function validateStateShape(state) {
  if (
    !state ||
    state.schema !== 3 ||
    state.repository !== destinationRepository ||
    !Number.isSafeInteger(state.releaseId) ||
    state.releaseId <= 0 ||
    typeof state.updatedAt !== "string" ||
    state.tagName !== sourceTag ||
    state.title !== expectedTitle ||
    state.body !== expectedBody ||
    state.prerelease !== false ||
    !state.notes ||
    !Number.isSafeInteger(state.notes.size) ||
    !/^[0-9a-f]{64}$/.test(state.notes.sha256) ||
    !Array.isArray(state.assets) ||
    state.assets.length !== expectedNames.length
  ) {
    fail("verified release state has an invalid shape or provenance");
  }
  validateUser(state.author, "verified release author");
  for (const [index, item] of state.assets.entries()) {
    if (
      !item ||
      !Number.isSafeInteger(item.id) ||
      item.id <= 0 ||
      item.name !== expectedNames[index] ||
      !Number.isSafeInteger(item.size) ||
      item.size < 0 ||
      !(item.serverDigest === null || /^sha256:[0-9a-f]{64}$/.test(item.serverDigest)) ||
      !/^[0-9a-f]{64}$/.test(item.sha256)
    ) {
      fail("verified release state has invalid asset bindings");
    }
    validateUser(item.uploader, `verified release asset uploader for ${item.name}`);
  }
}

function compareCanonical(metadata, local, state, { compareUpdatedAt, context }) {
  if (metadata.id !== state.releaseId) fail(`${context} release ID changed after verification`);
  if (
    metadata.tagName !== state.tagName ||
    metadata.title !== state.title ||
    metadata.body !== state.body ||
    metadata.prerelease !== state.prerelease ||
    JSON.stringify(metadata.author) !== JSON.stringify(state.author)
  ) {
    fail(`${context} canonical metadata changed after verification`);
  }
  if (compareUpdatedAt && metadata.updatedAt !== state.updatedAt) {
    fail(`${context} updated_at changed after verification`);
  }
  if (local.notes.size !== state.notes.size || local.notes.sha256 !== state.notes.sha256) {
    fail(`${context} local release notes changed after verification`);
  }
  if (JSON.stringify(local.assets) !== JSON.stringify(state.assets)) {
    fail(`${context} release asset identity, size, server digest, uploader, or bytes changed`);
  }
}

async function runInspect() {
  const metadata = parseMetadata(await readStdinJSON("release metadata"), {
    requireComplete: false,
  });
  process.stdout.write(
    [
      `id=${metadata.id}`,
      `draft=${metadata.draft}`,
      `prerelease=${metadata.prerelease}`,
      `assetCount=${metadata.assets.length}`,
      `assetsComplete=${metadata.complete}`,
    ].join("\n") + "\n",
  );
}

function runDownloads() {
  const metadata = readMetadata(metadataPath, { requireComplete: true });
  for (const item of metadata.assets) process.stdout.write(`${item.id}\t${item.name}\n`);
}

function runValidateNotes() {
  const notes = regularFile(metadataPath, "release notes");
  if (notes.bytes.toString("utf8") !== expectedBody) {
    fail("release body must exactly match the canonical notes and provenance marker");
  }
}

function runCapture() {
  const metadata = readMetadata(metadataPath, { requireComplete: true, expectedDraft: true });
  const local = validateLocal(metadata, releaseDir, notesPath, downloadsDir);
  const state = {
    schema: 3,
    repository: destinationRepository,
    releaseId: metadata.id,
    updatedAt: metadata.updatedAt,
    tagName: metadata.tagName,
    title: metadata.title,
    body: metadata.body,
    prerelease: metadata.prerelease,
    author: metadata.author,
    notes: local.notes,
    assets: local.assets,
  };
  writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`, { flag: "wx", mode: 0o600 });
}

function runCompare({ published }) {
  const metadata = readMetadata(metadataPath, {
    requireComplete: true,
    expectedDraft: !published,
  });
  const state = readJSON(statePath, "verified release state");
  validateStateShape(state);
  const local = validateLocal(metadata, releaseDir, notesPath, downloadsDir);
  compareCanonical(metadata, local, state, {
    compareUpdatedAt: !published,
    context: published ? "post-publish release state" : "pre-publish release state",
  });
  process.stdout.write(`${state.releaseId}\n`);
}

async function runIdentity() {
  validateUser(await readStdinJSON("authenticated user"), "authenticated token user");
}

async function runRepository() {
  const repository = await readStdinJSON("release repository metadata");
  if (
    !repository ||
    repository.visibility !== "public" ||
    typeof repository.default_branch !== "string" ||
    !/^[A-Za-z0-9._/-]+$/.test(repository.default_branch)
  ) {
    fail("release destination must be public with a canonical default branch");
  }
  process.stdout.write(`${repository.default_branch}\n`);
}

async function runImmutable() {
  const setting = await readStdinJSON("immutable releases setting");
  if (!setting || setting.enabled !== true) {
    fail("immutable releases must be enabled for the release repository");
  }
}

async function runRef() {
  const ref = await readStdinJSON("Git reference");
  if (
    !ref ||
    typeof ref.ref !== "string" ||
    !ref.object ||
    !["commit", "tag"].includes(ref.object.type) ||
    !/^[0-9a-f]{40}$/.test(ref.object.sha)
  ) {
    fail("Git reference has an invalid shape");
  }
  process.stdout.write(`${ref.object.type}\n${ref.object.sha}\n`);
}

async function runLockTag() {
  const tag = await readStdinJSON("release lock tag");
  const parsed = parseLockTag(tag);
  if (!parsed.current) {
    fail("release lock ownership metadata does not match this tag and source run");
  }
  process.stdout.write(`${parsed.tagSHA}\n${parsed.commitSHA}\n`);
}

function parseLockTag(tag) {
  if (
    !tag ||
    !/^[0-9a-f]{40}$/.test(tag.sha) ||
    typeof tag.tag !== "string" ||
    typeof tag.message !== "string" ||
    !tag.object ||
    tag.object.type !== "commit" ||
    !/^[0-9a-f]{40}$/.test(tag.object.sha)
  ) {
    fail("release lock ownership metadata has an invalid shape");
  }
  const message = tag.message.endsWith("\n") ? tag.message.slice(0, -1) : fail("release lock message is not canonical");
  const metadata = parseJSON(message, "release lock ownership metadata");
  const keys = [
    "lockSchema",
    "sourceRepository",
    "sourceCommit",
    "sourceTag",
    "workflowRef",
    "workflowRun",
    "workflowAttempt",
  ];
  if (
    !metadata ||
    typeof metadata !== "object" ||
    Array.isArray(metadata) ||
    JSON.stringify(Object.keys(metadata)) !== JSON.stringify(keys) ||
    metadata.lockSchema !== 1 ||
    metadata.sourceRepository !== sourceRepository ||
    metadata.sourceCommit !== sourceCommit ||
    metadata.sourceTag !== sourceTag ||
    metadata.workflowRef !== workflowRef ||
    typeof metadata.workflowRun !== "string" ||
    !/^[1-9][0-9]*$/.test(metadata.workflowRun) ||
    typeof metadata.workflowAttempt !== "string" ||
    !/^[1-9][0-9]*$/.test(metadata.workflowAttempt)
  ) {
    fail("release lock ownership metadata is untrusted or malformed");
  }
  const canonicalTag =
    `seer-release-lock-${metadata.sourceTag}-${metadata.sourceCommit}` +
    `-run-${metadata.workflowRun}-attempt-${metadata.workflowAttempt}`;
  if (tag.tag !== canonicalTag || tag.message !== `${JSON.stringify(metadata)}\n`) {
    fail("release lock tag and ownership metadata do not match");
  }
  return {
    tagSHA: tag.sha,
    commitSHA: tag.object.sha,
    workflowRun: metadata.workflowRun,
    workflowAttempt: metadata.workflowAttempt,
    current:
      metadata.workflowRun === expectedLockMetadata.workflowRun &&
      metadata.workflowAttempt === expectedLockMetadata.workflowAttempt,
  };
}

async function runLockOwner() {
  const parsed = parseLockTag(await readStdinJSON("release lock tag"));
  process.stdout.write(
    [
      `tagSha=${parsed.tagSHA}`,
      `commitSha=${parsed.commitSHA}`,
      `workflowRun=${parsed.workflowRun}`,
      `workflowAttempt=${parsed.workflowAttempt}`,
      `current=${parsed.current}`,
    ].join("\n") + "\n",
  );
}

async function runStatus() {
  const runID = metadataPath;
  const runAttempt = _headersPath;
  if (!/^[1-9][0-9]*$/.test(runID ?? "") || !/^[1-9][0-9]*$/.test(runAttempt ?? "")) {
    fail("recorded source workflow identity is invalid");
  }
  const status = await readStdinJSON("source workflow run status");
  const definitiveConclusions = new Set([
    "action_required",
    "cancelled",
    "failure",
    "neutral",
    "skipped",
    "stale",
    "startup_failure",
    "success",
    "timed_out",
  ]);
  if (
    !status ||
    !Number.isSafeInteger(status.id) ||
    String(status.id) !== runID ||
    !Number.isSafeInteger(status.run_attempt) ||
    String(status.run_attempt) !== runAttempt ||
    status.status !== "completed" ||
    !definitiveConclusions.has(status.conclusion)
  ) {
    fail("recorded source workflow run is active, unknown, or not definitively completed");
  }
}

async function runCommit() {
  const commit = await readStdinJSON("release lock target commit");
  if (!commit || commit.sha !== metadataPath || !/^[0-9a-f]{40}$/.test(commit.sha)) {
    fail("release lock does not point to the verified release-repository commit");
  }
}

try {
  switch (command) {
    case "inspect":
      await runInspect();
      break;
    case "downloads":
      runDownloads();
      break;
    case "validate-notes":
      runValidateNotes();
      break;
    case "capture":
      runCapture();
      break;
    case "compare":
      runCompare({ published: false });
      break;
    case "compare-published":
      runCompare({ published: true });
      break;
    case "identity":
      await runIdentity();
      break;
    case "repository":
      await runRepository();
      break;
    case "immutable":
      await runImmutable();
      break;
    case "ref":
      await runRef();
      break;
    case "lock-tag":
      await runLockTag();
      break;
    case "lock-owner":
      await runLockOwner();
      break;
    case "run-status":
      await runStatus();
      break;
    case "commit":
      await runCommit();
      break;
    default:
      fail(
        "usage: release-macos-draft-state.mjs inspect|downloads|validate-notes|capture|compare|" +
          "compare-published|identity|repository|immutable|ref|lock-tag|lock-owner|run-status|commit",
      );
  }
} catch (error) {
  console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
}
