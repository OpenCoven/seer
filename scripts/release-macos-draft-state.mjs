#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync, statSync, writeFileSync } from "node:fs";

const [
  command,
  metadataPath,
  headersPath,
  releaseDir,
  notesPath,
  statePath,
  fallbackDir,
] = process.argv.slice(2);

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
const version = required("VERSION");
const destinationRepository = required("GH_REPO");
const expectedTitle = `Seer ${version}`;
const expectedMarker =
  `<!-- seer-release-provenance:{"schema":1,"sourceRepository":"${sourceRepository}",` +
  `"sourceCommit":"${sourceCommit}","sourceTag":"${sourceTag}","workflowRef":"${workflowRef}",` +
  `"workflowRun":"${workflowRun}"} -->`;
const expectedBody = `${expectedMarker}\n\nSeer ${version} for Apple Silicon Macs running macOS 14 or later.\n`;
const expectedNames = [`Seer-v${version}-arm64.dmg`, "SHA256SUMS", "release-manifest.json"];

function fail(message) {
  throw new Error(message);
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function readJSON(path, description) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return fail(`${description} is not valid JSON`);
  }
}

function parseMetadata(value, { requireComplete }) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("release metadata has an invalid shape");
  const { id, draft, tag_name: tagName, name: title, body, updated_at: updatedAt, assets } = value;
  if (
    !Number.isSafeInteger(id) ||
    id <= 0 ||
    typeof draft !== "boolean" ||
    typeof tagName !== "string" ||
    typeof title !== "string" ||
    typeof body !== "string" ||
    typeof updatedAt !== "string" ||
    updatedAt.length === 0 ||
    !Array.isArray(assets)
  ) {
    fail("release metadata has an invalid shape");
  }
  if (tagName !== sourceTag) fail(`draft release tag does not match ${sourceTag}`);
  if (title !== expectedTitle) fail("draft canonical title does not match");
  if (body.split("\n", 1)[0] !== expectedMarker) {
    fail("draft provenance marker does not match the source commit, tag, repository, and workflow");
  }
  if (body !== expectedBody) fail("draft canonical body does not match exactly");

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
    if (seenNames.has(item.name) || seenIDs.has(item.id)) fail("draft contains duplicate release asset metadata");
    seenNames.add(item.name);
    seenIDs.add(item.id);
    if (typeof item.digest === "string" && !/^sha256:[0-9a-f]{64}$/.test(item.digest)) {
      fail(`release asset ${item.name} has an invalid digest`);
    }
    return { id: item.id, name: item.name, size: item.size, digest: item.digest ?? null };
  });

  const complete = expectedNames.every((name) => seenNames.has(name)) && normalizedAssets.length === expectedNames.length;
  if (requireComplete && !complete) fail("draft release does not contain the complete public asset allowlist");
  normalizedAssets.sort((a, b) => expectedNames.indexOf(a.name) - expectedNames.indexOf(b.name));
  return { id, draft, tagName, title, body, updatedAt, assets: normalizedAssets, complete };
}

function readMetadata(path, options) {
  return parseMetadata(readJSON(path, "release metadata"), options);
}

function readETag(path) {
  const headers = readFileSync(path, "utf8");
  const matches = [...headers.matchAll(/^etag:\s*(.+?)\r?$/gim)];
  const etag = matches.at(-1)?.[1]?.trim();
  if (!etag) fail("release metadata response did not include an ETag");
  return etag;
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

function validateLocal(metadata, localDir, localNotes, downloadsDir) {
  const notes = regularFile(localNotes, "release notes");
  if (notes.bytes.toString("utf8") !== expectedBody) fail("local release notes do not match the canonical body");
  const boundAssets = [];

  for (const expectedName of expectedNames) {
    const remote = metadata.assets.find(({ name }) => name === expectedName);
    if (!remote) fail(`release metadata is missing ${expectedName}`);
    const local = regularFile(`${localDir}/${expectedName}`, `local release asset ${expectedName}`);
    if (local.size !== remote.size) fail(`release asset ${expectedName} size does not match local verified bytes`);
    const digest = sha256(local.bytes);
    if (remote.digest !== null) {
      if (remote.digest !== `sha256:${digest}`) {
        fail(`release asset ${expectedName} digest does not match local verified bytes`);
      }
    } else {
      const downloaded = regularFile(`${downloadsDir}/${remote.id}`, `fresh download for release asset ${expectedName}`);
      if (!downloaded.bytes.equals(local.bytes)) {
        fail(`fresh download for release asset ${expectedName} does not match local verified bytes`);
      }
    }
    boundAssets.push({ id: remote.id, name: expectedName, size: local.size, sha256: digest });
  }

  return {
    notes: { size: notes.size, sha256: sha256(notes.bytes) },
    assets: boundAssets,
  };
}

function validateStateShape(state) {
  if (
    !state ||
    state.schema !== 1 ||
    state.repository !== destinationRepository ||
    !Number.isSafeInteger(state.releaseId) ||
    state.releaseId <= 0 ||
    typeof state.etag !== "string" ||
    typeof state.updatedAt !== "string" ||
    state.tagName !== sourceTag ||
    state.title !== expectedTitle ||
    state.body !== expectedBody ||
    !state.notes ||
    !Number.isSafeInteger(state.notes.size) ||
    !/^[0-9a-f]{64}$/.test(state.notes.sha256) ||
    !Array.isArray(state.assets) ||
    state.assets.length !== expectedNames.length
  ) {
    fail("verified release state has an invalid shape or provenance");
  }
  for (const [index, item] of state.assets.entries()) {
    if (
      !item ||
      !Number.isSafeInteger(item.id) ||
      item.id <= 0 ||
      item.name !== expectedNames[index] ||
      !Number.isSafeInteger(item.size) ||
      item.size < 0 ||
      !/^[0-9a-f]{64}$/.test(item.sha256)
    ) {
      fail("verified release state has invalid asset bindings");
    }
  }
}

async function runInspect() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  let value;
  try {
    value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    fail("release metadata is not valid JSON");
  }
  const metadata = parseMetadata(value, { requireComplete: false });
  process.stdout.write(
    [
      `id=${metadata.id}`,
      `draft=${metadata.draft}`,
      `assetCount=${metadata.assets.length}`,
      `assetsComplete=${metadata.complete}`,
    ].join("\n") + "\n",
  );
}

function runMissing() {
  const metadata = readMetadata(metadataPath, { requireComplete: true });
  for (const item of metadata.assets) {
    if (item.digest === null) process.stdout.write(`${item.id}\t${item.name}\n`);
  }
}

function runValidateNotes() {
  const notes = regularFile(metadataPath, "release notes");
  if (notes.bytes.toString("utf8") !== expectedBody) {
    fail("release body must exactly match the canonical notes and provenance marker");
  }
}

function runCapture() {
  const metadata = readMetadata(metadataPath, { requireComplete: true });
  if (!metadata.draft) fail("existing published release cannot be captured as a draft");
  const etag = readETag(headersPath);
  const local = validateLocal(metadata, releaseDir, notesPath, fallbackDir);
  const state = {
    schema: 1,
    repository: destinationRepository,
    releaseId: metadata.id,
    etag,
    updatedAt: metadata.updatedAt,
    tagName: metadata.tagName,
    title: metadata.title,
    body: metadata.body,
    notes: local.notes,
    assets: local.assets,
  };
  writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`, { flag: "wx", mode: 0o600 });
}

function runCompare() {
  const metadata = readMetadata(metadataPath, { requireComplete: true });
  if (!metadata.draft) fail("verified draft is no longer a draft");
  const etag = readETag(headersPath);
  const state = readJSON(statePath, "verified release state");
  validateStateShape(state);
  const local = validateLocal(metadata, releaseDir, notesPath, fallbackDir);

  if (metadata.id !== state.releaseId) fail("release ID changed after verification");
  if (etag !== state.etag) fail("release ETag changed after verification");
  if (metadata.updatedAt !== state.updatedAt) fail("release updated_at changed after verification");
  if (metadata.tagName !== state.tagName || metadata.title !== state.title || metadata.body !== state.body) {
    fail("release canonical metadata changed after verification");
  }
  if (local.notes.size !== state.notes.size || local.notes.sha256 !== state.notes.sha256) {
    fail("local release notes changed after verification");
  }
  if (JSON.stringify(local.assets) !== JSON.stringify(state.assets)) {
    fail("release asset identity, size, or digest changed after verification");
  }
  process.stdout.write(`${state.releaseId}\n${state.etag}\n`);
}

function runVerifyPatch() {
  const response = readJSON(metadataPath, "publish response");
  const state = readJSON(statePath, "verified release state");
  validateStateShape(state);
  if (
    response.id !== state.releaseId ||
    response.draft !== false ||
    response.tag_name !== state.tagName ||
    response.name !== state.title ||
    response.body !== state.body
  ) {
    fail("conditional publish response did not match the verified release");
  }
}

try {
  switch (command) {
    case "inspect":
      await runInspect();
      break;
    case "missing":
      runMissing();
      break;
    case "validate-notes":
      runValidateNotes();
      break;
    case "capture":
      runCapture();
      break;
    case "compare":
      runCompare();
      break;
    case "verify-patch":
      runVerifyPatch();
      break;
    default:
      fail("usage: release-macos-draft-state.mjs inspect|missing|validate-notes|capture|compare|verify-patch");
  }
} catch (error) {
  console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
}
