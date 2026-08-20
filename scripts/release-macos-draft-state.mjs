#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";

const [
  command,
  metadataPath,
  _headersPath,
  releaseDir,
  notesPath,
  statePath,
  downloadsDir,
  publishedDir,
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
const workflowAttempt = required("WORKFLOW_ATTEMPT");
const version = required("VERSION");
const destinationRepository = required("GH_REPO");
const destinationAnchorCommit = process.env.DESTINATION_ANCHOR_COMMIT;
const releaseWriter = {
  id: Number(required("RELEASE_WRITER_ID")),
  login: required("RELEASE_WRITER_LOGIN"),
};
const expectedTitle = `Seer ${version}`;
const expectedMarker =
  `<!-- seer-release-provenance:{"schema":1,"sourceRepository":"${sourceRepository}",` +
  `"sourceCommit":"${sourceCommit}","sourceTag":"${sourceTag}","workflowRef":"${workflowRef}",` +
  `"workflowRun":"${workflowRun}"} -->`;
const expectedBody = `${expectedMarker}\n\nSeer ${version} for Apple Silicon Macs running macOS 14 or later.\n`;
function expectedAssetNames(tagName) {
  return [`Seer-${tagName}-arm64.dmg`, "SHA256SUMS", "release-manifest.json"];
}
const expectedNames = expectedAssetNames(sourceTag);
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

function normalizeReleaseAssets(assets, allowedNames, description, requireComplete) {
  if (!Array.isArray(assets)) fail(`${description} asset metadata has an invalid shape`);
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
      fail(`${description} asset metadata has an invalid shape`);
    }
    if (!allowedNames.includes(item.name)) {
      fail(`${description} contains a foreign release asset`);
    }
    if (seenNames.has(item.name) || seenIDs.has(item.id)) {
      fail(`${description} contains duplicate release asset metadata`);
    }
    seenNames.add(item.name);
    seenIDs.add(item.id);
    if (typeof item.digest === "string" && !/^sha256:[0-9a-f]{64}$/.test(item.digest)) {
      fail(`${description} asset ${item.name} has an invalid digest`);
    }
    return {
      id: item.id,
      name: item.name,
      size: item.size,
      serverDigest: item.digest ?? null,
      uploader: validateUser(item.uploader, `${description} asset uploader for ${item.name}`),
    };
  });
  const complete =
    allowedNames.every((name) => seenNames.has(name)) &&
    normalizedAssets.length === allowedNames.length;
  if (requireComplete && !complete) {
    fail(`${description} does not contain the complete public asset allowlist`);
  }
  normalizedAssets.sort((a, b) => allowedNames.indexOf(a.name) - allowedNames.indexOf(b.name));
  return { assets: normalizedAssets, complete };
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
    target_commitish: targetCommitish,
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
    typeof targetCommitish !== "string" ||
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
  if (
    !/^[0-9a-f]{40}$/.test(destinationAnchorCommit ?? "") ||
    targetCommitish !== destinationAnchorCommit
  ) {
    fail("release target does not match the exact destination anchor commit");
  }
  if (title !== expectedTitle) fail("release canonical title does not match");
  if (body.split("\n", 1)[0] !== expectedMarker) {
    fail("draft provenance marker does not match the source commit, tag, repository, and workflow");
  }
  if (body !== expectedBody) fail("release canonical body does not match exactly");
  const normalizedAuthor = validateUser(author, "release author");

  const normalized = normalizeReleaseAssets(assets, expectedNames, "draft", requireComplete);
  return {
    id,
    draft,
    prerelease,
    immutable,
    tagName,
    title,
    body,
    targetCommitish,
    updatedAt,
    author: normalizedAuthor,
    assets: normalized.assets,
    complete: normalized.complete,
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

function exactKeys(value, expected) {
  return (
    value &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort())
  );
}

// Canonical decimal strings keep ordering overflow-safe before any bounded conversion.
const maximumSafeIntegerDecimal = "9007199254740991";

function parseCanonicalSemverTag(tag, description) {
  if (typeof tag !== "string" || tag.length > 51) {
    fail(`${description} is not a canonical vMAJOR.MINOR.PATCH tag`);
  }
  const match = /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.exec(tag);
  if (!match) fail(`${description} is not a canonical vMAJOR.MINOR.PATCH tag`);
  const components = match.slice(1);
  for (const component of components) {
    if (
      component.length > maximumSafeIntegerDecimal.length ||
      (component.length === maximumSafeIntegerDecimal.length &&
        component > maximumSafeIntegerDecimal)
    ) {
      fail(`${description} contains an oversized semantic-version component`);
    }
  }
  return components;
}

function currentSemver() {
  if (sourceTag !== `v${version}`) {
    fail("VERSION and SOURCE_TAG do not identify the same canonical semantic version");
  }
  return parseCanonicalSemverTag(sourceTag, "current release tag");
}

function compareCanonicalSemver(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left[index].length !== right[index].length) {
      return left[index].length < right[index].length ? -1 : 1;
    }
    if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1;
  }
  return 0;
}

function parseReleaseIDString(value, description) {
  if (
    typeof value !== "string" ||
    !/^[1-9][0-9]*$/.test(value) ||
    value.length > maximumSafeIntegerDecimal.length ||
    (value.length === maximumSafeIntegerDecimal.length && value > maximumSafeIntegerDecimal)
  ) {
    fail(`${description} is not a positive safe canonical integer`);
  }
  return Number(value);
}

function parseReleaseIDNumber(value, description) {
  if (!Number.isSafeInteger(value) || value <= 0) {
    fail(`${description} is not a positive safe canonical integer`);
  }
  return value;
}

function parsePositiveIntegerString(value, description, maximum = Number.MAX_SAFE_INTEGER) {
  const parsed = parseReleaseIDString(value, description);
  if (parsed > maximum) fail(`${description} exceeds its supported bound`);
  return parsed;
}

function compareReleaseIDs(left, right) {
  if (left.id === right.id) return 0;
  return left.id < right.id ? -1 : 1;
}

function normalizeStableReleaseTrust(value, tagName, description) {
  const author = validateUser(value.author, `${description} author`);
  const normalized = normalizeReleaseAssets(
    value.assets,
    expectedAssetNames(tagName),
    description,
    true,
  );
  return { author, assets: normalized.assets };
}

function stableReleaseIdentity(value) {
  return {
    id: value.id,
    tagName: value.tagName,
    author: value.author,
    assets: value.assets,
  };
}

function classifyInventoryEntries(values) {
  const releases = [];
  const stablePublished = [];
  const seenIDs = new Set();
  const seenTags = new Set();
  const seenStableVersions = new Map();

  for (const [index, value] of values.entries()) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      fail(`authenticated release inventory entry ${index + 1} has an invalid shape`);
    }
    const id = parseReleaseIDNumber(
      value.id,
      `authenticated release inventory entry ${index + 1} ID`,
    );
    const { draft, prerelease, immutable, tag_name: tagName } = value;
    if (
      typeof draft !== "boolean" ||
      typeof prerelease !== "boolean" ||
      typeof immutable !== "boolean" ||
      typeof tagName !== "string" ||
      tagName.length === 0
    ) {
      fail(`authenticated release inventory entry ${index + 1} has an invalid shape`);
    }
    if (seenIDs.has(id)) {
      fail(
        `authenticated release inventory contains duplicate release ID ${id}; ` +
          "the paginated list is ambiguous or mutated during enumeration",
      );
    }
    if (seenTags.has(tagName)) {
      fail(
        `authenticated release inventory contains duplicate release tag ${tagName}; ` +
          "the paginated list is ambiguous or mutated during enumeration",
      );
    }
    seenIDs.add(id);
    seenTags.add(tagName);

    const normalized = { id, tagName, draft, prerelease, immutable };
    if (draft || prerelease) {
      releases.push(normalized);
      continue;
    }
    if (!immutable) {
      fail(`stable published release ${tagName} (${id}) is not immutable`);
    }
    const semver = parseCanonicalSemverTag(tagName, `stable published release tag ${tagName}`);
    Object.assign(
      normalized,
      normalizeStableReleaseTrust(value, tagName, `stable published release ${tagName} (${id})`),
    );
    releases.push(normalized);
    const versionKey = semver.join(".");
    const prior = seenStableVersions.get(versionKey);
    if (prior) {
      fail(
        `duplicate canonical stable semantic version ${tagName} is published as ` +
          `release IDs ${prior.id} and ${id}`,
      );
    }
    const candidate = { id, tagName, semver };
    seenStableVersions.set(versionKey, candidate);
    stablePublished.push(candidate);
  }

  releases.sort(compareReleaseIDs);
  stablePublished.sort((left, right) => {
    const comparison = compareCanonicalSemver(left.semver, right.semver);
    return comparison === 0 ? compareReleaseIDs(left, right) : comparison;
  });
  return {
    releases,
    stablePublished: stablePublished.map(({ id, tagName }) => ({ id, tagName })),
    maximum:
      stablePublished.length === 0
        ? null
        : {
            id: stablePublished.at(-1).id,
            tagName: stablePublished.at(-1).tagName,
          },
  };
}

function inventoryFingerprint(pageSize, pageCount, releases) {
  return sha256(
    Buffer.from(
      JSON.stringify({
        repository: destinationRepository,
        pageSize,
        pageCount,
        releases,
      }),
      "utf8",
    ),
  );
}

function createInventoryState(values, pageSize, pageCount) {
  const classified = classifyInventoryEntries(values);
  return {
    schema: 1,
    kind: "authenticated-release-inventory",
    repository: destinationRepository,
    pageSize,
    pageCount,
    releaseCount: classified.releases.length,
    stablePublishedCount: classified.stablePublished.length,
    fingerprint: inventoryFingerprint(pageSize, pageCount, classified.releases),
    releases: classified.releases,
    stablePublished: classified.stablePublished,
    maximum: classified.maximum,
  };
}

function readInventory(path, description = "authenticated release inventory") {
  const value = readJSON(path, description);
  if (
    !exactKeys(value, [
      "schema",
      "kind",
      "repository",
      "pageSize",
      "pageCount",
      "releaseCount",
      "stablePublishedCount",
      "fingerprint",
      "releases",
      "stablePublished",
      "maximum",
    ]) ||
    value.schema !== 1 ||
    value.kind !== "authenticated-release-inventory" ||
    value.repository !== destinationRepository ||
    !Number.isSafeInteger(value.pageSize) ||
    value.pageSize <= 0 ||
    value.pageSize > 100 ||
    !Number.isSafeInteger(value.pageCount) ||
    value.pageCount <= 0 ||
    !Array.isArray(value.releases)
  ) {
    fail(`${description} has an invalid shape`);
  }
  const sourceValues = value.releases.map((release, index) => {
    const stable = release?.draft === false && release?.prerelease === false;
    const expectedKeys = ["id", "tagName", "draft", "prerelease", "immutable"];
    if (stable) expectedKeys.push("author", "assets");
    if (!exactKeys(release, expectedKeys)) {
      fail(`${description} release entry ${index + 1} has an invalid shape`);
    }
    return {
      id: release.id,
      tag_name: release.tagName,
      draft: release.draft,
      prerelease: release.prerelease,
      immutable: release.immutable,
      ...(stable
        ? {
            author: release.author,
            assets: Array.isArray(release.assets)
              ? release.assets.map((asset) => ({
                  id: asset?.id,
                  name: asset?.name,
                  size: asset?.size,
                  digest: asset?.serverDigest,
                  uploader: asset?.uploader,
                }))
              : release.assets,
          }
        : {}),
    };
  });
  const rebuilt = createInventoryState(sourceValues, value.pageSize, value.pageCount);
  if (JSON.stringify(value) !== JSON.stringify(rebuilt)) {
    fail(`${description} bindings are malformed or inconsistent`);
  }
  return value;
}

function inventoryPage(path, pageSize) {
  const page = readJSON(path, "authenticated release inventory page");
  if (!Array.isArray(page) || page.length > pageSize) {
    fail("authenticated release inventory page has an invalid shape or exceeds the page size");
  }
  return page;
}

function runInventoryPage() {
  const pageSize = parsePositiveIntegerString(_headersPath, "release inventory page size", 100);
  process.stdout.write(`${inventoryPage(metadataPath, pageSize).length}\n`);
}

function runBuildInventory() {
  const pageCount = parsePositiveIntegerString(_headersPath, "release inventory page count");
  const pageSize = parsePositiveIntegerString(releaseDir, "release inventory page size", 100);
  let names;
  try {
    names = readdirSync(metadataPath).sort();
  } catch {
    fail("release inventory page directory is missing or unreadable");
  }
  const expectedNames = Array.from(
    { length: pageCount },
    (_, index) => `page-${String(index + 1).padStart(4, "0")}.json`,
  );
  if (JSON.stringify(names) !== JSON.stringify(expectedNames)) {
    fail("release inventory page directory does not contain the exact bounded page set");
  }

  const values = [];
  for (let pageNumber = 1; pageNumber <= pageCount; pageNumber += 1) {
    const page = inventoryPage(
      `${metadataPath}/page-${String(pageNumber).padStart(4, "0")}.json`,
      pageSize,
    );
    if (pageNumber < pageCount && page.length !== pageSize) {
      fail("release inventory contains a short page before its terminal page");
    }
    if (pageNumber === pageCount && page.length === pageSize) {
      fail("release inventory terminal page is full and may be truncated");
    }
    values.push(...page);
  }

  writeFileSync(
    notesPath,
    `${JSON.stringify(createInventoryState(values, pageSize, pageCount), null, 2)}\n`,
    {
      flag: "wx",
      mode: 0o600,
    },
  );
}

function runBindInventories() {
  const first = readInventory(metadataPath, "first authenticated release inventory");
  const second = readInventory(_headersPath, "confirming authenticated release inventory");
  if (
    first.pageSize !== second.pageSize ||
    first.releaseCount !== second.releaseCount ||
    first.fingerprint !== second.fingerprint ||
    JSON.stringify(first.releases) !== JSON.stringify(second.releases)
  ) {
    fail("authenticated release inventory changed between exhaustive confirmation scans");
  }
  writeFileSync(releaseDir, `${JSON.stringify(second, null, 2)}\n`, {
    flag: "wx",
    mode: 0o600,
  });
}

function parseLatestReleaseIdentity(value) {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    typeof value.tag_name !== "string"
  ) {
    fail("latest release response has an invalid shape");
  }
  if (value.draft !== false || value.prerelease !== false || value.immutable !== true) {
    fail("latest release state is not a stable immutable published release");
  }
  const id = parseReleaseIDNumber(value.id, "latest release ID");
  const tagName = value.tag_name;
  const semver = parseCanonicalSemverTag(tagName, "latest release tag");
  const trust = normalizeStableReleaseTrust(value, tagName, `latest release ${tagName} (${id})`);
  return {
    id,
    tagName,
    semver,
    ...trust,
  };
}

function readLatestReleaseResponse(path, httpStatus) {
  if (!/^[0-9]{3}$/.test(httpStatus ?? "")) {
    fail("latest release response has an invalid HTTP status");
  }
  const body = parseJSON(
    regularFile(path, "latest release response").bytes.toString("utf8"),
    "latest release response",
  );
  if (httpStatus === "404") {
    if (
      !body ||
      typeof body !== "object" ||
      Array.isArray(body) ||
      body.message !== "Not Found" ||
      "id" in body ||
      "tag_name" in body ||
      "draft" in body
    ) {
      fail("latest release 404 response does not unambiguously mean no releases");
    }
    return null;
  }
  if (httpStatus !== "200") {
    fail(`latest release request returned unexpected HTTP status ${httpStatus}`);
  }
  return parseLatestReleaseIdentity(body);
}

function inventoryIdentity(value, description) {
  if (
    !exactKeys(value, ["id", "tagName"]) ||
    !Number.isSafeInteger(value.id) ||
    value.id <= 0 ||
    typeof value.tagName !== "string"
  ) {
    fail(`${description} has an invalid release identity`);
  }
  parseCanonicalSemverTag(value.tagName, `${description} tag`);
  return value;
}

function bindCurrentInventoryRelease(inventory, currentReleaseID, expectedDraft) {
  const byID = inventory.releases.find((release) => release.id === currentReleaseID);
  const byTag = inventory.releases.find((release) => release.tagName === sourceTag);
  if (!byID && !byTag) {
    fail(
      `current ${expectedDraft ? "draft" : "published"} release is absent from the authenticated inventory`,
    );
  }
  if (!byID || !byTag || byID !== byTag) {
    fail(
      `current ${expectedDraft ? "draft" : "published"} release ID/tag is reused by another inventory entry`,
    );
  }
  if (expectedDraft) {
    if (byID.draft !== true || byID.prerelease !== false) {
      fail("current draft release inventory state is not the exact stable-channel draft");
    }
  } else if (byID.draft !== false || byID.prerelease !== false || byID.immutable !== true) {
    fail("current published release inventory state is not stable and immutable");
  }
  return byID;
}

function verifyLatestGlobalMaximum(inventory, latest, context) {
  if (inventory.maximum === null) {
    if (latest !== null) {
      fail(`${context} latest endpoint is not a canonical 404 for an empty stable inventory`);
    }
    return;
  }
  if (
    latest === null ||
    latest.id !== inventory.maximum.id ||
    latest.tagName !== inventory.maximum.tagName
  ) {
    const expected = `${inventory.maximum.tagName} (${inventory.maximum.id})`;
    const actual = latest === null ? "canonical 404" : `${latest.tagName} (${latest.id})`;
    fail(
      `${context} latest release does not equal the authenticated inventory global maximum: ` +
        `expected ${expected}, received ${actual}`,
    );
  }
  const inventoryMaximum = inventory.releases.find(
    (release) =>
      release.id === inventory.maximum.id && release.tagName === inventory.maximum.tagName,
  );
  if (
    !inventoryMaximum ||
    JSON.stringify(stableReleaseIdentity(latest)) !==
      JSON.stringify(stableReleaseIdentity(inventoryMaximum))
  ) {
    fail(
      `${context} latest release protected author or asset identity does not match ` +
        "the authenticated inventory global maximum",
    );
  }
}

function decisionInventoryBinding(inventory) {
  return {
    fingerprint: inventory.fingerprint,
    releaseCount: inventory.releaseCount,
    stablePublishedCount: inventory.stablePublishedCount,
    maximum: inventory.maximum,
  };
}

function validateLatestDecisionState(value, currentReleaseID, boundInventory) {
  if (
    !exactKeys(value, [
      "schema",
      "kind",
      "repository",
      "currentRelease",
      "inventory",
      "observedLatest",
      "makeLatest",
    ]) ||
    value.schema !== 2 ||
    value.kind !== "latest-release-decision" ||
    value.repository !== destinationRepository ||
    !exactKeys(value.currentRelease, ["id", "tagName"]) ||
    value.currentRelease.id !== currentReleaseID ||
    value.currentRelease.tagName !== sourceTag ||
    !exactKeys(value.inventory, [
      "fingerprint",
      "releaseCount",
      "stablePublishedCount",
      "maximum",
    ]) ||
    !/^[0-9a-f]{64}$/.test(value.inventory.fingerprint) ||
    !Number.isSafeInteger(value.inventory.releaseCount) ||
    value.inventory.releaseCount < 0 ||
    !Number.isSafeInteger(value.inventory.stablePublishedCount) ||
    value.inventory.stablePublishedCount < 0 ||
    value.inventory.stablePublishedCount > value.inventory.releaseCount ||
    !["true", "false"].includes(value.makeLatest)
  ) {
    fail("latest release decision state is malformed or does not match the current release");
  }

  const current = currentSemver();
  if (boundInventory !== undefined) {
    bindCurrentInventoryRelease(boundInventory, currentReleaseID, true);
    if (
      JSON.stringify(value.inventory) !== JSON.stringify(decisionInventoryBinding(boundInventory))
    ) {
      fail("latest release decision inventory binding does not match pre-publication state");
    }
  }
  if (value.inventory.maximum === null) {
    if (
      value.inventory.stablePublishedCount !== 0 ||
      value.observedLatest !== null ||
      value.makeLatest !== "true"
    ) {
      fail("latest release decision is inconsistent with an empty stable inventory");
    }
    return value;
  }
  const maximum = inventoryIdentity(value.inventory.maximum, "recorded inventory maximum");
  const observed = inventoryIdentity(value.observedLatest, "recorded latest release");
  if (
    value.inventory.stablePublishedCount === 0 ||
    observed.id !== maximum.id ||
    observed.tagName !== maximum.tagName
  ) {
    fail("latest release decision is not bound to the recorded inventory maximum");
  }
  if (maximum.id === currentReleaseID) {
    fail("latest release decision reuses the current draft release ID as its inventory maximum");
  }
  const comparison = compareCanonicalSemver(
    current,
    parseCanonicalSemverTag(maximum.tagName, "recorded inventory maximum tag"),
  );
  if (comparison === 0) {
    fail("latest release decision has the same semantic version as the inventory maximum");
  }
  if (
    (comparison > 0 && value.makeLatest !== "true") ||
    (comparison < 0 && value.makeLatest !== "false")
  ) {
    fail("latest release decision is inconsistent with the inventory global maximum");
  }
  return value;
}

function runLatestDecision() {
  const inventory = readInventory(metadataPath);
  const latest = readLatestReleaseResponse(_headersPath, releaseDir);
  const currentReleaseID = parseReleaseIDString(notesPath, "current release ID");
  bindCurrentInventoryRelease(inventory, currentReleaseID, true);
  verifyLatestGlobalMaximum(inventory, latest, "pre-publication");

  const current = currentSemver();
  let makeLatest;
  if (inventory.maximum === null) {
    makeLatest = "true";
  } else {
    if (inventory.maximum.id === currentReleaseID) {
      fail("inventory maximum impossibly reuses the current draft release ID");
    }
    const comparison = compareCanonicalSemver(
      current,
      parseCanonicalSemverTag(inventory.maximum.tagName, "inventory maximum tag"),
    );
    if (comparison === 0) {
      fail("a stable published release has the current semantic version; publication is ambiguous");
    }
    makeLatest = comparison > 0 ? "true" : "false";
  }

  const state = {
    schema: 2,
    kind: "latest-release-decision",
    repository: destinationRepository,
    currentRelease: { id: currentReleaseID, tagName: sourceTag },
    inventory: decisionInventoryBinding(inventory),
    observedLatest: latest === null ? null : { id: latest.id, tagName: latest.tagName },
    makeLatest,
  };
  writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`, {
    flag: "wx",
    mode: 0o600,
  });
  process.stdout.write(`${makeLatest}\n`);
}

function runVerifyGlobalLatest() {
  const inventory = readInventory(metadataPath, "post-publication authenticated release inventory");
  const latest = readLatestReleaseResponse(_headersPath, releaseDir);
  const currentReleaseID = parseReleaseIDString(notesPath, "current published release ID");
  const prePublicationInventory = readInventory(
    downloadsDir,
    "pre-publication authenticated release inventory",
  );
  validateLatestDecisionState(
    readJSON(statePath, "latest release decision state"),
    currentReleaseID,
    prePublicationInventory,
  );
  bindCurrentInventoryRelease(inventory, currentReleaseID, false);
  verifyLatestGlobalMaximum(inventory, latest, "post-publication");
}

function runReconcilePublishedLatest() {
  const inventory = readInventory(
    metadataPath,
    "published reconciliation authenticated release inventory",
  );
  const latest = readLatestReleaseResponse(_headersPath, releaseDir);
  const currentReleaseID = parseReleaseIDString(notesPath, "current published release ID");
  bindCurrentInventoryRelease(inventory, currentReleaseID, false);
  verifyLatestGlobalMaximum(inventory, latest, "published reconciliation");
}

function validatePublishedDownloads(metadata, freshDownloads) {
  const downloaded = new Map();
  for (const remote of metadata.assets) {
    const file = regularFile(
      `${freshDownloads}/${remote.id}`,
      `fresh download for release asset ${remote.name}`,
    );
    if (file.size !== remote.size) {
      fail(`release asset ${remote.name} size does not match its fresh download`);
    }
    const digest = sha256(file.bytes);
    if (remote.serverDigest !== null && remote.serverDigest !== `sha256:${digest}`) {
      fail(`release asset ${remote.name} digest does not match its fresh download`);
    }
    downloaded.set(remote.name, { ...file, sha256: digest });
  }

  const dmgName = expectedNames[0];
  const dmg = downloaded.get(dmgName);
  const checksums = downloaded.get("SHA256SUMS");
  const expectedChecksums = `${dmg.sha256}  ${dmgName}\n`;
  if (checksums.bytes.toString("utf8") !== expectedChecksums) {
    fail("SHA256SUMS does not contain the exact published DMG hash");
  }

  const manifestFile = downloaded.get("release-manifest.json");
  const manifest = parseJSON(manifestFile.bytes.toString("utf8"), "release manifest");
  const manifestKeys = [
    "artifacts",
    "bundleIdentifier",
    "notarization",
    "sourceCommit",
    "version",
    "workflowRun",
  ];
  if (!exactKeys(manifest, manifestKeys)) {
    fail("release manifest schema is invalid");
  }
  if (manifest.version !== version) fail("release manifest version does not match");
  if (manifest.sourceCommit !== sourceCommit) {
    fail("release manifest source commit does not match");
  }
  if (manifest.bundleIdentifier !== "ai.opencoven.seer") {
    fail("release manifest bundle identifier does not match");
  }
  if (manifest.notarization !== "accepted") {
    fail("release manifest notarization status is not accepted");
  }
  if (manifest.workflowRun !== workflowRun) {
    fail("release manifest workflow run does not match");
  }
  if (
    !Array.isArray(manifest.artifacts) ||
    manifest.artifacts.length !== 1 ||
    !exactKeys(manifest.artifacts[0], ["name", "sha256", "size"])
  ) {
    fail("release manifest artifact schema is invalid");
  }
  const artifact = manifest.artifacts[0];
  if (
    artifact.name !== dmgName ||
    artifact.sha256 !== dmg.sha256 ||
    artifact.size !== dmg.size ||
    !Number.isSafeInteger(artifact.size) ||
    artifact.size < 0
  ) {
    fail("release manifest DMG hash, size, or name does not match the published DMG");
  }

  return {
    manifest,
    assets: metadata.assets.map((remote) => ({
      ...remote,
      sha256: downloaded.get(remote.name).sha256,
    })),
    downloaded,
  };
}

function buildExistingPublishedState(metadata, validated) {
  return {
    schema: 1,
    kind: "existing-published-state",
    repository: destinationRepository,
    releaseId: metadata.id,
    updatedAt: metadata.updatedAt,
    tagName: metadata.tagName,
    destinationAnchorCommit,
    title: metadata.title,
    body: metadata.body,
    prerelease: metadata.prerelease,
    immutable: metadata.immutable,
    author: metadata.author,
    assets: validated.assets,
    manifest: validated.manifest,
    platformChecks: [
      "apple-signature",
      "notarization",
      "gatekeeper",
      "mounted-volume-allowlist",
      "arm64-mach-o",
      "system-dependencies",
      "standalone-boundary",
    ],
  };
}

function validateExistingPublishedStateShape(state) {
  if (
    !state ||
    state.schema !== 1 ||
    state.kind !== "existing-published-state" ||
    state.repository !== destinationRepository ||
    !Number.isSafeInteger(state.releaseId) ||
    state.releaseId <= 0 ||
    typeof state.updatedAt !== "string" ||
    state.tagName !== sourceTag ||
    state.destinationAnchorCommit !== destinationAnchorCommit ||
    state.title !== expectedTitle ||
    state.body !== expectedBody ||
    state.prerelease !== false ||
    state.immutable !== true ||
    !Array.isArray(state.assets) ||
    state.assets.length !== expectedNames.length ||
    JSON.stringify(state.platformChecks) !==
      JSON.stringify([
        "apple-signature",
        "notarization",
        "gatekeeper",
        "mounted-volume-allowlist",
        "arm64-mach-o",
        "system-dependencies",
        "standalone-boundary",
      ])
  ) {
    fail("existing-published-state evidence has an invalid shape or provenance");
  }
  validateUser(state.author, "existing published release author");
}

function validateMaterializedPublished(validated, directory) {
  for (const name of expectedNames) {
    const materialized = regularFile(
      `${directory}/${name}`,
      `materialized published release asset ${name}`,
    );
    const downloaded = validated.downloaded.get(name);
    if (materialized.size !== downloaded.size || !materialized.bytes.equals(downloaded.bytes)) {
      fail(`materialized published release asset ${name} changed after validation`);
    }
  }
}

function runMaterializePublished() {
  const metadata = readMetadata(metadataPath, { requireComplete: true, expectedDraft: false });
  const validated = validatePublishedDownloads(metadata, downloadsDir);
  for (const name of expectedNames) {
    writeFileSync(`${publishedDir}/${name}`, validated.downloaded.get(name).bytes, {
      flag: "wx",
      mode: 0o644,
    });
  }
}

function runCaptureExistingPublished() {
  const metadata = readMetadata(metadataPath, { requireComplete: true, expectedDraft: false });
  const validated = validatePublishedDownloads(metadata, downloadsDir);
  validateMaterializedPublished(validated, releaseDir);
  const state = buildExistingPublishedState(metadata, validated);
  writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`, { flag: "wx", mode: 0o600 });
}

function runCompareExistingPublished() {
  const metadata = readMetadata(metadataPath, { requireComplete: true, expectedDraft: false });
  const validated = validatePublishedDownloads(metadata, downloadsDir);
  const state = readJSON(statePath, "existing-published-state evidence");
  validateExistingPublishedStateShape(state);
  const current = buildExistingPublishedState(metadata, validated);
  if (JSON.stringify(current) !== JSON.stringify(state)) {
    fail("existing-published-state evidence does not match the current immutable published release");
  }
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
    state.schema !== 4 ||
    state.repository !== destinationRepository ||
    !Number.isSafeInteger(state.releaseId) ||
    state.releaseId <= 0 ||
    typeof state.updatedAt !== "string" ||
    state.tagName !== sourceTag ||
    state.destinationAnchorCommit !== destinationAnchorCommit ||
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
    metadata.targetCommitish !== state.destinationAnchorCommit ||
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

async function runListPage() {
  const page = await readStdinJSON("release list page");
  if (!Array.isArray(page)) fail("release list page has an invalid shape");
  const matches = page.filter(
    (item) => item && typeof item === "object" && !Array.isArray(item) && item.tag_name === sourceTag,
  );
  if (matches.length > 1) {
    fail("multiple releases match the exact source tag; refusing to disambiguate");
  }
  const lines = [`pageCount=${page.length}`, `matchCount=${matches.length}`];
  if (matches.length === 1) {
    const metadata = parseMetadata(matches[0], { requireComplete: false });
    lines.push(
      `id=${metadata.id}`,
      `draft=${metadata.draft}`,
      `prerelease=${metadata.prerelease}`,
      `assetCount=${metadata.assets.length}`,
      `assetsComplete=${metadata.complete}`,
    );
  }
  process.stdout.write(lines.join("\n") + "\n");
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
  const metadata = readMetadata(metadataPath, { requireComplete: true });
  const local = validateLocal(metadata, releaseDir, notesPath, downloadsDir);
  const state = {
    schema: 4,
    repository: destinationRepository,
    releaseId: metadata.id,
    updatedAt: metadata.updatedAt,
    tagName: metadata.tagName,
    destinationAnchorCommit,
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

function runVerifyPublishedLocal() {
  const metadata = readMetadata(metadataPath, { requireComplete: true, expectedDraft: false });
  validateLocal(metadata, releaseDir, notesPath, downloadsDir);
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

async function runTagTarget() {
  const tag = await readStdinJSON("annotated Git tag");
  if (
    !tag ||
    !/^[0-9a-f]{40}$/.test(tag.sha) ||
    !tag.object ||
    !["commit", "tag"].includes(tag.object.type) ||
    !/^[0-9a-f]{40}$/.test(tag.object.sha)
  ) {
    fail("annotated Git tag has an invalid target");
  }
  process.stdout.write(`${tag.object.type}\n${tag.object.sha}\n`);
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
    case "list-page":
      await runListPage();
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
    case "verify-published-local":
      runVerifyPublishedLocal();
      break;
    case "materialize-published":
      runMaterializePublished();
      break;
    case "capture-existing-published":
      runCaptureExistingPublished();
      break;
    case "compare-existing-published":
      runCompareExistingPublished();
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
    case "inventory-page":
      runInventoryPage();
      break;
    case "build-inventory":
      runBuildInventory();
      break;
    case "bind-inventories":
      runBindInventories();
      break;
    case "latest-decision":
      runLatestDecision();
      break;
    case "verify-global-latest":
      runVerifyGlobalLatest();
      break;
    case "reconcile-published-latest":
      runReconcilePublishedLatest();
      break;
    case "ref":
      await runRef();
      break;
    case "tag-target":
      await runTagTarget();
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
        "usage: release-macos-draft-state.mjs inspect|list-page|downloads|validate-notes|capture|" +
          "compare|compare-published|verify-published-local|materialize-published|" +
          "capture-existing-published|compare-existing-published|identity|repository|immutable|" +
          "inventory-page|build-inventory|bind-inventories|latest-decision|" +
          "verify-global-latest|reconcile-published-latest|ref|tag-target|lock-tag|lock-owner|" +
          "run-status|commit",
      );
  }
} catch (error) {
  console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
}
