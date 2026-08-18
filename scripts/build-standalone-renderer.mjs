#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  appendFileSync,
  closeSync,
  constants,
  fchmodSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmdirSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  RENDERER_BUILD_MANIFEST_ALGORITHM,
  RENDERER_BUILD_MANIFEST_SCHEMA_VERSION,
  buildRendererBuildManifest,
  computeRendererAssetDigest,
  computeRendererBuildDigest,
  prepareRendererAssetDigestHelperImage,
  rendererBuildInputFiles,
  serializeRendererBuildManifest,
} from "./renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const lockDir = join(repoRoot, ".seer-standalone-renderer.lock");
const ownerPath = join(lockDir, "owner.json");
const childPath = join(lockDir, "child.json");
const consumerGatePath = join(here, "renderer-consumer-gate.mjs");
const legacyReclaimPath = `${lockDir}.reclaiming`;
const reclaimOwnerName = "reclaim.json";
const reclaimTempNamePattern = /^\.reclaim-([1-9][0-9]*)-[0-9a-f]{32}\.tmp$/;
const reclaimClaimPath = `${lockDir}.reclaim-claim`;
const reclaimClaimOwnerName = "claim.json";
const reclaimClaimTempNamePattern = /^\.claim-([1-9][0-9]*)-[0-9a-f]{32}\.tmp$/;
const lockQuarantineNamePattern = /^\.seer-standalone-renderer\.lock\.quarantine-[0-9a-f]{32}$/;
const lockQuarantinePrefix = ".seer-standalone-renderer.lock.quarantine-";
const rendererBuildRoot = join(repoRoot, "build", "standalone-renderer");
const publishedRenderer = join(rendererBuildRoot, "Renderer");
const publicationJournalPath = join(rendererBuildRoot, ".renderer-publication-transaction.json");
const publicationJournalTempPath = join(rendererBuildRoot, ".renderer-publication-transaction.new");
const publicationJournalSchemaVersion = 1;
const publicationJournalMaxBytes = 64 * 1024;
const rendererStageNamePattern = /^\.renderer-stage-[0-9a-f]{32}$/;
const rendererSnapshotNamePattern = /^\.renderer-snapshot-[0-9a-f]{32}$/;
const rendererBackupNamePattern = /^\.renderer-backup-[0-9a-f]{32}$/;
const legacyGenerationNamePattern = /^\.renderer-generation-[0-9a-f-]{36}$/;
const publicationPhases = new Set(["prepared", "old-backed-up", "new-published", "cleanup"]);

function positiveIntegerFromEnv(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return value;
}

const waitMs = positiveIntegerFromEnv("SEER_RENDERER_LOCK_WAIT_MS", 10 * 60 * 1000);
const staleMs = positiveIntegerFromEnv("SEER_RENDERER_LOCK_STALE_MS", 2 * 60 * 1000);
const pollMs = positiveIntegerFromEnv("SEER_RENDERER_LOCK_POLL_MS", 100);
const eexistDelayMs = positiveIntegerFromEnv("SEER_RENDERER_LOCK_TEST_EEXIST_DELAY_MS", 0);
const sourceChangeMaxRetries = positiveIntegerFromEnv("SEER_RENDERER_SOURCE_CHANGE_MAX_RETRIES", 2);
const lockInitializationGraceMs = Math.max(staleMs, 100);

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

function sameDirectoryIdentity(left, right) {
  return (
    sameIdentity(left, right) &&
    (!Number.isFinite(left.birthtimeMs) ||
      !Number.isFinite(right.birthtimeMs) ||
      left.birthtimeMs === right.birthtimeMs)
  );
}

function assertOwnedDirectory(info, label) {
  if (info.isSymbolicLink() || !info.isDirectory()) {
    throw new Error(`${label} must be a real directory, never a symlink`);
  }
  if (typeof process.getuid === "function" && info.uid !== process.getuid()) {
    throw new Error(`${label} is not owned by the current uid`);
  }
}

function lstatOrNull(path) {
  try {
    return lstatSync(path);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function ensureOwnedDirectory(path, label) {
  try {
    mkdirSync(path, { mode: 0o700 });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
  }
  const info = lstatSync(path);
  assertOwnedDirectory(info, label);
  if (realpathSync(path) !== path) {
    throw new Error(`${label} must already be canonical`);
  }
  return info;
}

function verifyRepoRoot() {
  if (realpathSync(repoRoot) !== repoRoot) {
    throw new Error(`repository root is not canonical: ${repoRoot}`);
  }
  const before = lstatSync(repoRoot);
  assertOwnedDirectory(before, "repository root");
  const after = lstatSync(repoRoot);
  if (!sameIdentity(before, after)) {
    throw new Error("repository root changed identity");
  }
}

function readJsonFileNoFollow(path, label) {
  const before = lstatSync(path);
  if (before.isSymbolicLink() || !before.isFile()) {
    throw new Error(`${label} must be a regular non-symlink file`);
  }
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const after = fstatSync(descriptor);
    if (!after.isFile() || !sameIdentity(before, after)) {
      throw new Error(`${label} changed identity while being opened`);
    }
    const source = readFileSync(descriptor, "utf8");
    try {
      return { info: after, value: JSON.parse(source) };
    } catch (error) {
      error.verifiedFileInfo = after;
      throw error;
    }
  } finally {
    closeSync(descriptor);
  }
}

function isPidAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === "EPERM") return true;
    if (error.code === "ESRCH") return false;
    throw error;
  }
}

function readBootIdentity() {
  if (process.platform === "darwin") {
    const result = spawnSync("/usr/sbin/sysctl", ["-n", "kern.boottime"], {
      encoding: "utf8",
    });
    if (result.error) throw result.error;
    if (result.status !== 0) {
      throw new Error(`unable to read Darwin boot identity: ${result.stderr.trim()}`);
    }
    const match = result.stdout.match(/sec\s*=\s*(\d+),\s*usec\s*=\s*(\d+)/);
    if (!match) throw new Error("Darwin kern.boottime had an unexpected format");
    return `${match[1]}:${match[2]}`;
  }
  try {
    return readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
  } catch (error) {
    throw new Error(`unable to read operating-system boot identity: ${error.message}`);
  }
}

const bootIdentity = readBootIdentity();

function readProcessStartIdentity(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return null;
  const result = spawnSync("/bin/ps", ["-p", String(pid), "-o", "lstart="], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
  });
  if (result.error) throw result.error;
  if (result.status !== 0) return null;
  const identity = result.stdout.trim().replaceAll(/\s+/g, " ");
  return identity || null;
}

function recordedProcessIsLive(record) {
  if (
    !record ||
    typeof record.bootIdentity !== "string" ||
    typeof record.processStartIdentity !== "string" ||
    record.bootIdentity !== bootIdentity ||
    !isPidAlive(record.pid)
  ) {
    return false;
  }
  try {
    const currentIdentity = readProcessStartIdentity(record.pid);
    // The PID passed kill(0) immediately above. If ps is transiently
    // unavailable under heavy contention, retaining the lock is safer than
    // declaring a potentially live owner stale.
    return currentIdentity === null || currentIdentity === record.processStartIdentity;
  } catch {
    return true;
  }
}

function isProcessGroupAlive(processGroupId) {
  if (!Number.isSafeInteger(processGroupId) || processGroupId <= 0) return false;
  try {
    process.kill(-processGroupId, 0);
    return true;
  } catch (error) {
    if (error.code === "EPERM") return true;
    if (error.code === "ESRCH") return false;
    throw error;
  }
}

function recordedChildGroupState(childRecord, owner) {
  if (!childRecord) return { state: "stale", diagnostic: null };
  const child = childRecord.value;
  if (
    !child ||
    typeof child !== "object" ||
    typeof child.token !== "string" ||
    !Number.isSafeInteger(child.pid) ||
    child.pid <= 0 ||
    typeof child.bootIdentity !== "string" ||
    typeof child.processStartIdentity !== "string"
  ) {
    return {
      state: "unknown",
      diagnostic: "recorded child process-group identity cannot be proven stale",
    };
  }
  if (owner && (typeof owner.token !== "string" || child.token !== owner.token)) {
    return {
      state: "unknown",
      diagnostic: "recorded child process-group identity cannot be proven stale",
    };
  }
  if (child.bootIdentity !== bootIdentity) {
    return { state: "stale", diagnostic: null };
  }

  const currentStartIdentity = readProcessStartIdentity(child.pid);
  if (currentStartIdentity) {
    if (currentStartIdentity === child.processStartIdentity) {
      return {
        state: "live",
        diagnostic: `recorded renderer child ${child.pid} is still alive`,
      };
    }
    return { state: "stale", diagnostic: null };
  }

  if (child.processGroupId === null && process.platform === "win32") {
    return { state: "stale", diagnostic: null };
  }
  if (
    !Number.isSafeInteger(child.processGroupId) ||
    child.processGroupId <= 0 ||
    child.processGroupId !== child.pid
  ) {
    return {
      state: "unknown",
      diagnostic: "recorded child process-group identity cannot be proven stale",
    };
  }
  if (isProcessGroupAlive(child.processGroupId)) {
    return {
      state: "live",
      diagnostic: `recorded renderer child process group ${child.processGroupId} is still alive`,
    };
  }
  return { state: "stale", diagnostic: null };
}

function removeVerifiedDirectory(
  directoryPath,
  expectedDirectory,
  knownEntries,
  label,
  hooks = {},
) {
  const currentDirectory = lstatSync(directoryPath);
  assertOwnedDirectory(currentDirectory, label);
  if (!sameDirectoryIdentity(expectedDirectory, currentDirectory)) {
    throw new Error(`${label} changed identity before cleanup`);
  }

  const names = readdirSync(directoryPath).sort();
  const expectedNames = [...knownEntries.keys()].sort();
  if (JSON.stringify(names) !== JSON.stringify(expectedNames)) {
    throw new Error(`${label} contains unexpected entries: ${names.join(", ")}`);
  }
  const orderedEntries = [...knownEntries].sort(([left], [right]) => {
    if (left === right) return 0;
    if (left === "owner.json") return 1;
    if (right === "owner.json") return -1;
    return left.localeCompare(right);
  });
  for (const [name, expectedInfo] of orderedEntries) {
    const path = join(directoryPath, name);
    const current = lstatSync(path);
    if (current.isSymbolicLink() || !current.isFile() || !sameIdentity(expectedInfo, current)) {
      throw new Error(`${label} ${name} changed identity before cleanup`);
    }
    unlinkSync(path);
    hooks.onEntryRemoved?.(name);
    fsyncDirectory(directoryPath);
  }
  rmdirSync(directoryPath);
  hooks.onDirectoryRemoved?.();
  fsyncDirectory(dirname(directoryPath));
}

function runReclaimTestHook(phase) {
  const hookPath = process.env.SEER_RENDERER_RECLAIM_TEST_HOOK;
  if (!hookPath || process.env.SEER_RENDERER_RECLAIM_TEST_PHASE !== phase) return;
  const result = spawnSync(process.execPath, [hookPath, phase], {
    env: process.env,
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`renderer reclaim test hook exited with status ${result.status}`);
  }
}

function runReleaseTestHook(phase) {
  const hookPath = process.env.SEER_RENDERER_RELEASE_TEST_HOOK;
  if (!hookPath || process.env.SEER_RENDERER_RELEASE_TEST_PHASE !== phase) return;
  const result = spawnSync(process.execPath, [hookPath, phase], {
    env: process.env,
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`renderer release test hook exited with status ${result.status}`);
  }
}

function runConsumerSetupTestHook(phase) {
  const hookPath = process.env.SEER_RENDERER_CONSUMER_SETUP_TEST_HOOK;
  if (!hookPath || process.env.SEER_RENDERER_CONSUMER_SETUP_TEST_PHASE !== phase) return;
  const result = spawnSync(process.execPath, [hookPath, phase], {
    env: process.env,
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`renderer consumer setup test hook exited with status ${result.status}`);
  }
}

function quarantineAndRemoveOwnedLock(expectedDirectory, ownerInfo) {
  const currentDirectory = lstatSync(lockDir);
  assertOwnedDirectory(currentDirectory, "renderer lock");
  if (!sameDirectoryIdentity(expectedDirectory, currentDirectory)) {
    throw new Error("renderer lock changed identity before release");
  }
  const names = readdirSync(lockDir);
  if (names.length !== 1 || names[0] !== "owner.json") {
    throw new Error(`renderer lock contains unexpected entries before release: ${names.join(", ")}`);
  }
  const currentOwner = lstatSync(ownerPath);
  if (
    currentOwner.isSymbolicLink() ||
    !currentOwner.isFile() ||
    !sameIdentity(ownerInfo, currentOwner)
  ) {
    throw new Error("renderer lock owner metadata changed identity before release");
  }
  const quarantinePath = uniqueLockQuarantinePath();
  renameSync(lockDir, quarantinePath);
  runReleaseTestHook("lock-quarantined");
  fsyncDirectory(repoRoot);
  runReleaseTestHook("quarantine-fsynced");

  const quarantinedDirectory = lstatSync(quarantinePath);
  if (!sameDirectoryIdentity(expectedDirectory, quarantinedDirectory)) {
    throw new Error("quarantined renderer lock changed identity");
  }
  const quarantinedOwnerPath = join(quarantinePath, "owner.json");
  const quarantinedOwner = lstatSync(quarantinedOwnerPath);
  if (
    quarantinedOwner.isSymbolicLink() ||
    !quarantinedOwner.isFile() ||
    !sameIdentity(ownerInfo, quarantinedOwner)
  ) {
    throw new Error("quarantined renderer lock owner metadata changed identity");
  }
  unlinkSync(quarantinedOwnerPath);
  runReleaseTestHook("owner-unlinked");
  fsyncDirectory(quarantinePath);
  runReleaseTestHook("owner-fsynced");
  rmdirSync(quarantinePath);
  runReleaseTestHook("quarantine-removed");
  fsyncDirectory(repoRoot);
}

function uniqueLockQuarantinePath() {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const name = `${lockQuarantinePrefix}${randomUUID().replaceAll("-", "")}`;
    const path = join(repoRoot, name);
    if (!lstatOrNull(path)) return path;
  }
  throw new Error("unable to allocate a unique renderer lock quarantine");
}

function assertReclaimTemp(directoryPath, directoryInfo, name) {
  const match = name.match(reclaimTempNamePattern);
  if (!match) throw new Error(`renderer lock contains unexpected entry: ${name}`);
  const currentDirectory = lstatSync(directoryPath);
  assertOwnedDirectory(currentDirectory, "renderer lock reclaim temp parent");
  if (!sameDirectoryIdentity(directoryInfo, currentDirectory)) {
    throw new Error("renderer lock changed identity while inspecting reclaim temp");
  }
  const path = join(directoryPath, name);
  const before = lstatSync(path);
  if (
    before.isSymbolicLink() ||
    !before.isFile() ||
    (typeof process.getuid === "function" && before.uid !== process.getuid())
  ) {
    throw new Error("renderer lock reclaim temp must be a regular non-symlink file owned by the current uid");
  }
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const opened = fstatSync(descriptor);
    if (!opened.isFile() || !sameIdentity(before, opened)) {
      throw new Error("renderer lock reclaim temp changed identity");
    }
  } finally {
    closeSync(descriptor);
  }
  return { info: before, path, pid: Number(match[1]) };
}

function cleanupAbandonedReclaimTemps(directoryPath, directoryInfo) {
  let names;
  try {
    names = readdirSync(directoryPath).filter((name) => name.startsWith(".reclaim-"));
  } catch (error) {
    if (error.code === "ENOENT" || error.code === "ENOTDIR") {
      return { cleaned: false, diagnostic: "renderer lock changed during reclaim temp cleanup" };
    }
    throw error;
  }
  if (names.length === 0) return { cleaned: true, diagnostic: null };
  const temps = [];
  for (const name of names) {
    try {
      temps.push(assertReclaimTemp(directoryPath, directoryInfo, name));
    } catch (error) {
      if (error.code === "ENOENT" || error.code === "ENOTDIR") {
        return { cleaned: false, diagnostic: "renderer lock changed during reclaim temp cleanup" };
      }
      throw error;
    }
  }
  for (const temp of temps) {
    if (isPidAlive(temp.pid)) {
      return {
        cleaned: false,
        diagnostic: `renderer lock reclaim temp belongs to live process ${temp.pid}`,
      };
    }
    if (Date.now() - temp.info.mtimeMs < lockInitializationGraceMs) {
      return {
        cleaned: false,
        diagnostic: "renderer lock reclaim temp is within its initialization grace period",
      };
    }
  }
  let changed = false;
  for (const temp of temps) {
    const current = lstatOrNull(temp.path);
    if (!current) continue;
    if (
      current.isSymbolicLink() ||
      !current.isFile() ||
      !sameIdentity(temp.info, current)
    ) {
      throw new Error("renderer lock reclaim temp changed before cleanup");
    }
    try {
      unlinkSync(temp.path);
      changed = true;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
  if (changed) {
    try {
      fsyncDirectory(directoryPath);
    } catch (error) {
      if (error.code !== "ENOENT" && error.code !== "ENOTDIR") throw error;
      return { cleaned: false, diagnostic: "renderer lock changed during reclaim temp cleanup" };
    }
  }
  return { cleaned: true, diagnostic: null };
}

function quarantineReclaimFile(directoryPath, directoryInfo, reclaimInfo) {
  const reclaimFile = join(directoryPath, reclaimOwnerName);
  const quarantineName =
    `.reclaim-${process.pid}-${randomUUID().replaceAll("-", "")}.tmp`;
  const quarantinePath = join(directoryPath, quarantineName);
  const currentDirectory = lstatSync(directoryPath);
  if (!sameDirectoryIdentity(directoryInfo, currentDirectory)) {
    return false;
  }
  const currentReclaim = lstatOrNull(reclaimFile);
  if (!currentReclaim) return false;
  if (
    currentReclaim.isSymbolicLink() ||
    !currentReclaim.isFile() ||
    !sameIdentity(reclaimInfo, currentReclaim)
  ) {
    throw new Error("renderer lock reclaim metadata changed before quarantine");
  }
  try {
    renameSync(reclaimFile, quarantinePath);
  } catch (error) {
    if (error.code === "ENOENT" || error.code === "ENOTDIR") return false;
    throw error;
  }
  fsyncDirectory(directoryPath);
  const quarantined = lstatSync(quarantinePath);
  if (
    quarantined.isSymbolicLink() ||
    !quarantined.isFile() ||
    !sameIdentity(reclaimInfo, quarantined)
  ) {
    throw new Error("quarantined renderer reclaim metadata changed identity");
  }
  unlinkSync(quarantinePath);
  fsyncDirectory(directoryPath);
  return true;
}

function persistReclaimClaimMetadata(directoryInfo, reclaimer) {
  const tempName = `.claim-${process.pid}-${randomUUID().replaceAll("-", "")}.tmp`;
  const tempPath = join(reclaimClaimPath, tempName);
  const claimFile = join(reclaimClaimPath, reclaimClaimOwnerName);
  let descriptor = null;
  let tempInfo = null;
  try {
    descriptor = openSync(
      tempPath,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
      0o600,
    );
    tempInfo = fstatSync(descriptor);
    runReclaimTestHook("claim-temp-created");
    writeFileSync(descriptor, `${JSON.stringify(reclaimer)}\n`, "utf8");
    runReclaimTestHook("claim-temp-written");
    fsyncSync(descriptor);
    runReclaimTestHook("claim-temp-fsynced");
    closeSync(descriptor);
    descriptor = null;

    const currentDirectory = lstatSync(reclaimClaimPath);
    if (!sameDirectoryIdentity(directoryInfo, currentDirectory)) {
      throw new Error("renderer reclaim claim changed identity before metadata commit");
    }
    if (lstatOrNull(claimFile)) {
      throw new Error("renderer reclaim claim metadata already exists");
    }
    const currentTemp = lstatSync(tempPath);
    if (
      currentTemp.isSymbolicLink() ||
      !currentTemp.isFile() ||
      !sameIdentity(tempInfo, currentTemp)
    ) {
      throw new Error("renderer reclaim claim temp changed before metadata commit");
    }
    renameSync(tempPath, claimFile);
    runReclaimTestHook("claim-committed");
    fsyncDirectory(reclaimClaimPath);
    const claimInfo = lstatSync(claimFile);
    if (
      claimInfo.isSymbolicLink() ||
      !claimInfo.isFile() ||
      !sameIdentity(tempInfo, claimInfo)
    ) {
      throw new Error("renderer reclaim claim metadata changed after commit");
    }
    return claimInfo;
  } catch (error) {
    if (descriptor !== null) closeSync(descriptor);
    if (tempInfo) {
      const currentTemp = lstatOrNull(tempPath);
      if (
        currentTemp &&
        currentTemp.isFile() &&
        !currentTemp.isSymbolicLink() &&
        sameIdentity(tempInfo, currentTemp)
      ) {
        unlinkSync(tempPath);
        fsyncDirectory(reclaimClaimPath);
      }
    }
    throw error;
  }
}

function tryAcquireReclaimClaim(reclaimer) {
  try {
    mkdirSync(reclaimClaimPath, { mode: 0o700 });
  } catch (error) {
    if (error.code === "EEXIST") return null;
    throw error;
  }
  const directoryInfo = lstatSync(reclaimClaimPath);
  assertOwnedDirectory(directoryInfo, "renderer reclaim claim");
  if (realpathSync(reclaimClaimPath) !== reclaimClaimPath) {
    throw new Error("renderer reclaim claim must already be canonical");
  }
  fsyncDirectory(repoRoot);
  runReclaimTestHook("claim-created");
  try {
    const ownerInfo = persistReclaimClaimMetadata(directoryInfo, reclaimer);
    return { directoryInfo, ownerInfo };
  } catch (error) {
    const current = lstatOrNull(reclaimClaimPath);
    if (current && sameDirectoryIdentity(directoryInfo, current)) {
      const knownEntries = new Map();
      for (const name of readdirSync(reclaimClaimPath)) {
        const info = lstatSync(join(reclaimClaimPath, name));
        if (info.isSymbolicLink() || !info.isFile()) throw error;
        knownEntries.set(name, info);
      }
      removeVerifiedDirectory(
        reclaimClaimPath,
        directoryInfo,
        knownEntries,
        "renderer reclaim claim",
      );
    }
    throw error;
  }
}

function releaseReclaimClaim(claim, withTestHooks = true) {
  const currentDirectory = lstatSync(reclaimClaimPath);
  assertOwnedDirectory(currentDirectory, "renderer reclaim claim");
  if (!sameDirectoryIdentity(claim.directoryInfo, currentDirectory)) {
    throw new Error("renderer reclaim claim changed identity before release");
  }
  const names = readdirSync(reclaimClaimPath);
  if (names.length !== 1 || names[0] !== reclaimClaimOwnerName) {
    throw new Error(`renderer reclaim claim contains unexpected entries: ${names.join(", ")}`);
  }
  const owner = lstatSync(join(reclaimClaimPath, reclaimClaimOwnerName));
  if (
    owner.isSymbolicLink() ||
    !owner.isFile() ||
    !sameIdentity(claim.ownerInfo, owner)
  ) {
    throw new Error("renderer reclaim claim metadata changed before release");
  }
  unlinkSync(join(reclaimClaimPath, reclaimClaimOwnerName));
  if (withTestHooks) runReclaimTestHook("claim-owner-unlinked");
  fsyncDirectory(reclaimClaimPath);
  rmdirSync(reclaimClaimPath);
  if (withTestHooks) runReclaimTestHook("claim-removed");
  fsyncDirectory(repoRoot);
}

function claimAndRemoveStaleLock(directoryInfo, claim) {
  let quarantinePath = null;
  let quarantineInfo = null;
  let knownEntries = null;
  try {
    const currentDirectory = lstatOrNull(lockDir);
    if (!currentDirectory || !sameDirectoryIdentity(directoryInfo, currentDirectory)) {
      releaseReclaimClaim(claim);
      return false;
    }
    const staleState = inspectStaleLockDirectory(lockDir, currentDirectory, "renderer lock");
    if (!staleState.stale) {
      releaseReclaimClaim(claim);
      return false;
    }
    knownEntries = new Map();
    if (staleState.ownerRecord) knownEntries.set("owner.json", staleState.ownerRecord.info);
    if (staleState.childRecord) knownEntries.set("child.json", staleState.childRecord.info);
    const names = readdirSync(lockDir).sort();
    const expectedNames = [...knownEntries.keys()].sort();
    if (JSON.stringify(names) !== JSON.stringify(expectedNames)) {
      throw new Error(`renderer lock contains unexpected entries: ${names.join(", ")}`);
    }
    for (const [name, expectedInfo] of knownEntries) {
      const current = lstatSync(join(lockDir, name));
      if (current.isSymbolicLink() || !current.isFile() || !sameIdentity(expectedInfo, current)) {
        releaseReclaimClaim(claim);
        return false;
      }
    }

    quarantinePath = uniqueLockQuarantinePath();
    renameSync(lockDir, quarantinePath);
    runReclaimTestHook("lock-quarantined");
    quarantineInfo = lstatSync(quarantinePath);
    if (!sameDirectoryIdentity(directoryInfo, quarantineInfo)) {
      throw new Error("renderer lock changed identity while entering quarantine");
    }
    fsyncDirectory(repoRoot);
    runReclaimTestHook("quarantine-fsynced");

    // The claim must stay held for the entire quarantine removal below: releasing
    // it any earlier would let another waiter's cleanupAbandonedLockQuarantines()
    // inspect or remove this exact quarantine directory concurrently, racing this
    // process's own unlinks and rmdir. Other waiters block on inspectReclaimClaim()
    // while this claim's owner is alive, so holding it here guarantees a single
    // remover for this quarantine. It is only released after removal fully
    // completes (or immediately below on a caught error, once this process has
    // stopped touching the filesystem) so a crash still leaves a recoverable,
    // unambiguously-owned claim/quarantine pair for the next waiter.
    removeVerifiedDirectory(
      quarantinePath,
      quarantineInfo,
      knownEntries,
      "renderer lock quarantine",
      {
        onEntryRemoved(name) {
          if (name === "owner.json") runReclaimTestHook("quarantine-owner-unlinked");
        },
        onDirectoryRemoved() {
          runReclaimTestHook("quarantine-removed");
        },
      },
    );
  } catch (error) {
    if (lstatOrNull(reclaimClaimPath)) {
      releaseReclaimClaim(claim);
    }
    throw error;
  }

  releaseReclaimClaim(claim);
  return true;
}

function inspectStaleLockDirectory(directoryPath, directoryInfo, label) {
  const freshnessMs = Math.max(directoryInfo.mtimeMs, directoryInfo.ctimeMs);
  let ownerRecord = null;
  let childRecord = null;
  try {
    ownerRecord = readJsonFileNoFollow(
      join(directoryPath, "owner.json"),
      `${label} owner metadata`,
    );
  } catch (error) {
    if (Date.now() - freshnessMs < lockInitializationGraceMs) {
      return { stale: false, live: false, diagnostic: `${label} owner metadata is not yet stale` };
    }
    if (error.code !== "ENOENT") {
      if (!error.verifiedFileInfo) throw error;
      ownerRecord = { info: error.verifiedFileInfo, value: null };
    }
  }
  try {
    childRecord = readJsonFileNoFollow(
      join(directoryPath, "child.json"),
      `${label} child metadata`,
    );
  } catch (error) {
    if (error.code !== "ENOENT" && Date.now() - freshnessMs < staleMs) {
      return { stale: false, live: false, diagnostic: `${label} child metadata is not yet stale` };
    }
    if (error.code !== "ENOENT") {
      if (!error.verifiedFileInfo) throw error;
      childRecord = { info: error.verifiedFileInfo, value: null };
    }
  }

  const owner = ownerRecord?.value;
  if (recordedProcessIsLive(owner)) {
    return {
      stale: false,
      live: true,
      diagnostic: `recorded renderer lock owner ${owner.pid} is still alive`,
    };
  }
  const childGroup = recordedChildGroupState(childRecord, owner);
  if (childGroup.state !== "stale") {
    return {
      stale: false,
      live: childGroup.state === "live",
      diagnostic: childGroup.diagnostic,
    };
  }
  const createdAtMs = Number.isSafeInteger(owner?.createdAtMs)
    ? owner.createdAtMs
    : freshnessMs;
  if (Date.now() - createdAtMs < staleMs) {
    return { stale: false, live: false, diagnostic: `${label} has not reached its stale age` };
  }
  const tempCleanup = cleanupAbandonedReclaimTemps(directoryPath, directoryInfo);
  if (!tempCleanup.cleaned) {
    return { stale: false, live: false, diagnostic: tempCleanup.diagnostic };
  }
  return { stale: true, live: false, diagnostic: null, ownerRecord, childRecord };
}

function inspectLegacyReclamation() {
  const directoryInfo = lstatOrNull(legacyReclaimPath);
  if (!directoryInfo) return { present: false, restored: false, diagnostic: null };
  assertOwnedDirectory(directoryInfo, "renderer lock reclamation");
  let reclaimRecord = null;
  try {
    reclaimRecord = readJsonFileNoFollow(
      join(legacyReclaimPath, reclaimOwnerName),
      "renderer lock reclamation owner metadata",
    );
  } catch (error) {
    const freshnessMs = Math.max(directoryInfo.mtimeMs, directoryInfo.ctimeMs);
    if (Date.now() - freshnessMs < lockInitializationGraceMs) {
      return {
        present: true,
        restored: false,
        diagnostic: "renderer lock reclamation owner metadata is initializing",
      };
    }
    if (error.code !== "ENOENT" && error.code !== "ENOTDIR") {
      if (!error.verifiedFileInfo) throw error;
      reclaimRecord = { info: error.verifiedFileInfo, value: null };
    }
  }
  if (reclaimRecord && recordedProcessIsLive(reclaimRecord.value)) {
    return {
      present: true,
      restored: false,
      diagnostic: `renderer lock is being reclaimed by process ${reclaimRecord.value.pid}`,
    };
  }
  const staleState = inspectStaleLockDirectory(
    legacyReclaimPath,
    directoryInfo,
    "renderer lock reclamation",
  );
  if (!staleState.stale) {
    return {
      present: true,
      restored: false,
      diagnostic: staleState.diagnostic,
    };
  }

  const currentLock = lstatOrNull(lockDir);
  if (!currentLock) {
    try {
      renameSync(legacyReclaimPath, lockDir);
      return { present: true, restored: true, diagnostic: null };
    } catch (error) {
      if (error.code === "EEXIST" || error.code === "ENOENT" || error.code === "ENOTDIR") {
        return { present: true, restored: false, diagnostic: "renderer lock reclamation changed" };
      }
      throw error;
    }
  }

  const knownEntries = new Map();
  for (const name of readdirSync(legacyReclaimPath)) {
    if (!["owner.json", "child.json", reclaimOwnerName].includes(name)) {
      throw new Error(`renderer lock reclamation contains unexpected entry: ${name}`);
    }
    const info = lstatSync(join(legacyReclaimPath, name));
    if (info.isSymbolicLink() || !info.isFile()) {
      throw new Error(`renderer lock reclamation ${name} must be a regular file`);
    }
    knownEntries.set(name, info);
  }
  removeVerifiedDirectory(
    legacyReclaimPath,
    directoryInfo,
    knownEntries,
    "abandoned renderer lock reclamation",
  );
  fsyncDirectory(repoRoot);
  return { present: true, restored: false, diagnostic: null };
}

function isRetryableLockRace(error) {
  return (
    ["EEXIST", "ENOENT", "ENOTDIR", "ENOTEMPTY"].includes(error?.code) ||
    /changed identity|changed during|changed before cleanup/i.test(error?.message ?? "")
  );
}

function inspectReclaimClaim() {
  const directoryInfo = lstatOrNull(reclaimClaimPath);
  if (!directoryInfo) return { present: false, diagnostic: null };
  assertOwnedDirectory(directoryInfo, "renderer reclaim claim");
  if (realpathSync(reclaimClaimPath) !== reclaimClaimPath) {
    throw new Error("renderer reclaim claim must already be canonical");
  }

  const knownEntries = new Map();
  let claimRecord = null;
  let freshnessMs = Math.max(directoryInfo.mtimeMs, directoryInfo.ctimeMs);
  for (const name of readdirSync(reclaimClaimPath)) {
    if (name !== reclaimClaimOwnerName && !reclaimClaimTempNamePattern.test(name)) {
      throw new Error(`renderer reclaim claim contains unexpected entry: ${name}`);
    }
    const path = join(reclaimClaimPath, name);
    const info = lstatSync(path);
    if (
      info.isSymbolicLink() ||
      !info.isFile() ||
      (typeof process.getuid === "function" && info.uid !== process.getuid())
    ) {
      throw new Error(`renderer reclaim claim ${name} must be an owned regular file`);
    }
    knownEntries.set(name, info);
    freshnessMs = Math.max(freshnessMs, info.mtimeMs, info.ctimeMs);
    if (name === reclaimClaimOwnerName) {
      try {
        claimRecord = readJsonFileNoFollow(path, "renderer reclaim claim metadata");
      } catch (error) {
        if (!error.verifiedFileInfo) throw error;
        claimRecord = { info: error.verifiedFileInfo, value: null };
      }
    }
  }

  if (claimRecord && recordedProcessIsLive(claimRecord.value)) {
    return {
      present: true,
      diagnostic: `renderer lock is being reclaimed by process ${claimRecord.value.pid}`,
    };
  }
  for (const name of knownEntries.keys()) {
    const match = name.match(reclaimClaimTempNamePattern);
    if (match && isPidAlive(Number(match[1]))) {
      return {
        present: true,
        diagnostic: `renderer reclaim claim is being initialized by process ${match[1]}`,
      };
    }
  }
  if (Date.now() - freshnessMs < lockInitializationGraceMs) {
    return {
      present: true,
      diagnostic: "renderer reclaim claim is within its initialization grace period",
    };
  }

  try {
    removeVerifiedDirectory(
      reclaimClaimPath,
      directoryInfo,
      knownEntries,
      "abandoned renderer reclaim claim",
    );
  } catch (error) {
    if (!isRetryableLockRace(error)) throw error;
  }
  return { present: false, diagnostic: null };
}

function lockQuarantineNames() {
  const names = readdirSync(repoRoot)
    .filter((name) => name.startsWith(lockQuarantinePrefix))
    .sort();
  for (const name of names) {
    if (!lockQuarantineNamePattern.test(name)) {
      throw new Error(`renderer lock quarantine has an invalid name: ${name}`);
    }
  }
  return names;
}

function cleanupAbandonedLockQuarantines() {
  let pending = false;
  let diagnostic = null;
  for (const name of lockQuarantineNames()) {
    const path = join(repoRoot, name);
    const directoryInfo = lstatSync(path);
    assertOwnedDirectory(directoryInfo, "renderer lock quarantine");
    if (realpathSync(path) !== path) {
      throw new Error("renderer lock quarantine must already be canonical");
    }
    const quarantineFreshnessMs = Math.max(directoryInfo.mtimeMs, directoryInfo.ctimeMs);
    if (Date.now() - quarantineFreshnessMs < lockInitializationGraceMs) {
      pending = true;
      diagnostic = "renderer lock quarantine is within its handoff grace period";
      continue;
    }
    const staleState = inspectStaleLockDirectory(path, directoryInfo, "renderer lock quarantine");
    if (!staleState.stale) {
      if (!staleState.live) {
        pending = true;
        diagnostic = staleState.diagnostic;
      }
      continue;
    }

    const knownEntries = new Map();
    for (const entryName of readdirSync(path)) {
      if (!["owner.json", "child.json"].includes(entryName)) {
        throw new Error(`renderer lock quarantine contains unexpected entry: ${entryName}`);
      }
      const info = lstatSync(join(path, entryName));
      if (
        info.isSymbolicLink() ||
        !info.isFile() ||
        (typeof process.getuid === "function" && info.uid !== process.getuid())
      ) {
        throw new Error(`renderer lock quarantine ${entryName} must be an owned regular file`);
      }
      knownEntries.set(entryName, info);
    }
    try {
      removeVerifiedDirectory(
        path,
        directoryInfo,
        knownEntries,
        "abandoned renderer lock quarantine",
      );
    } catch (error) {
      if (!isRetryableLockRace(error)) throw error;
    }
  }
  return { pending, diagnostic };
}

function inspectAndMaybeRemoveStaleLock(reclaimer) {
  const directoryInfo = lstatOrNull(lockDir);
  if (!directoryInfo) return { removed: true, diagnostic: null };
  assertOwnedDirectory(directoryInfo, "renderer lock");
  const staleState = inspectStaleLockDirectory(lockDir, directoryInfo, "renderer lock");
  if (!staleState.stale) {
    return { removed: false, diagnostic: staleState.diagnostic };
  }
  const reclaimFile = join(lockDir, reclaimOwnerName);
  const existingReclaimInfo = lstatOrNull(reclaimFile);
  if (existingReclaimInfo) {
    let reclaimRecord;
    try {
      reclaimRecord = readJsonFileNoFollow(
        reclaimFile,
        "renderer lock reclamation owner metadata",
      );
    } catch (error) {
      if (error.code === "ENOENT" || error.code === "ENOTDIR") {
        return { removed: true, diagnostic: null };
      }
      if (Date.now() - directoryInfo.mtimeMs < lockInitializationGraceMs) {
        return { removed: false, diagnostic: "renderer lock reclamation metadata is initializing" };
      }
      if (!error.verifiedFileInfo) throw error;
      const quarantined = quarantineReclaimFile(
        lockDir,
        directoryInfo,
        error.verifiedFileInfo,
      );
      return { removed: quarantined, diagnostic: quarantined ? null : "renderer lock changed" };
    }
    if (recordedProcessIsLive(reclaimRecord.value)) {
      return {
        removed: false,
        diagnostic: `renderer lock is being reclaimed by process ${reclaimRecord.value.pid}`,
      };
    }
    const quarantined = quarantineReclaimFile(lockDir, directoryInfo, existingReclaimInfo);
    return { removed: quarantined, diagnostic: quarantined ? null : "renderer lock changed" };
  }

  const claim = tryAcquireReclaimClaim(reclaimer);
  if (!claim) {
    return {
      removed: false,
      diagnostic: "another waiter is reclaiming the renderer lock",
    };
  }
  const removed = claimAndRemoveStaleLock(directoryInfo, claim);
  return {
    removed,
    diagnostic: removed ? null : "another waiter is reclaiming the renderer lock",
  };
}

function sleep(durationMs) {
  return new Promise((resolve) => setTimeout(resolve, durationMs));
}

async function acquireLock() {
  verifyRepoRoot();
  const token = randomUUID();
  const deadline = Date.now() + waitMs;
  const processStartIdentity = readProcessStartIdentity(process.pid);
  let lockDiagnostic = null;
  if (!processStartIdentity) {
    throw new Error("unable to identify the renderer lock owner process start");
  }
  const reclaimer = {
    token,
    pid: process.pid,
    createdAtMs: Date.now(),
    bootIdentity,
    processStartIdentity,
  };

  while (true) {
    try {
      const claimState = inspectReclaimClaim();
      if (claimState.present) {
        lockDiagnostic = claimState.diagnostic;
        if (Date.now() >= deadline) {
          const detail = lockDiagnostic ? `; ${lockDiagnostic}` : "";
          throw new Error(
            `timed out after ${waitMs}ms waiting for the standalone renderer build lock${detail}`,
          );
        }
        await sleep(pollMs);
        continue;
      }

      const reclamation = inspectLegacyReclamation();
      if (reclamation.present) {
        if (reclamation.restored) continue;
        lockDiagnostic = reclamation.diagnostic;
        if (Date.now() >= deadline) {
          const detail = lockDiagnostic ? `; ${lockDiagnostic}` : "";
          throw new Error(
            `timed out after ${waitMs}ms waiting for the standalone renderer build lock${detail}`,
          );
        }
        await sleep(pollMs);
        continue;
      }

      if (lockQuarantineNames().length > 0) {
        const cleanupClaim = tryAcquireReclaimClaim(reclaimer);
        if (!cleanupClaim) {
          lockDiagnostic = "another waiter is recovering a renderer lock quarantine";
          await sleep(pollMs);
          continue;
        }
        let cleanup;
        try {
          cleanup = cleanupAbandonedLockQuarantines();
        } finally {
          releaseReclaimClaim(cleanupClaim, false);
        }
        if (cleanup.pending) {
          lockDiagnostic = cleanup.diagnostic;
          if (Date.now() >= deadline) {
            const detail = lockDiagnostic ? `; ${lockDiagnostic}` : "";
            throw new Error(
              `timed out after ${waitMs}ms waiting for the standalone renderer build lock${detail}`,
            );
          }
          await sleep(pollMs);
          continue;
        }
      }
    } catch (error) {
      if (!isRetryableLockRace(error)) throw error;
      lockDiagnostic = "renderer lock identity changed during handoff";
      if (Date.now() >= deadline) {
        const detail = lockDiagnostic ? `; ${lockDiagnostic}` : "";
        throw new Error(
          `timed out after ${waitMs}ms waiting for the standalone renderer build lock${detail}`,
        );
      }
      await sleep(pollMs);
      continue;
    }

    try {
      mkdirSync(lockDir, { mode: 0o700 });
      const directoryInfo = lstatSync(lockDir);
      assertOwnedDirectory(directoryInfo, "renderer lock");
      const owner = {
        token,
        pid: process.pid,
        createdAtMs: Date.now(),
        bootIdentity,
        processStartIdentity,
      };
      try {
        writeFileSync(ownerPath, `${JSON.stringify(owner)}\n`, {
          encoding: "utf8",
          flag: "wx",
          mode: 0o600,
        });
      } catch (error) {
        try {
          rmdirSync(lockDir);
        } catch {
          // Preserve the original ownership failure.
        }
        throw error;
      }
      const ownerRecord = readJsonFileNoFollow(ownerPath, "renderer lock owner metadata");
      if (
        ownerRecord.value.token !== token ||
        ownerRecord.value.pid !== process.pid ||
        ownerRecord.value.bootIdentity !== bootIdentity ||
        ownerRecord.value.processStartIdentity !== processStartIdentity
      ) {
        throw new Error("renderer lock ownership could not be verified after acquisition");
      }

      let activeChildInfo = null;
      return {
        token,
        recordChild(pid, processGroupId, metadata = {}) {
          const childProcessStartIdentity = readProcessStartIdentity(pid);
          if (!childProcessStartIdentity) {
            throw new Error("unable to identify spawned renderer process start");
          }
          const encoded = `${JSON.stringify({
            token,
            pid,
            processGroupId,
            createdAtMs: Date.now(),
            bootIdentity,
            processStartIdentity: childProcessStartIdentity,
            ...metadata,
          })}\n`;
          let descriptor = null;
          let createdInfo = null;
          try {
            descriptor = openSync(
              childPath,
              constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
              0o600,
            );
            createdInfo = fstatSync(descriptor);
            if (!createdInfo.isFile()) {
              throw new Error("renderer child metadata was not created as a regular file");
            }
            writeFileSync(descriptor, encoded, "utf8");
            fsyncSync(descriptor);
            activeChildInfo = createdInfo;
          } catch (error) {
            if (descriptor !== null) {
              closeSync(descriptor);
              descriptor = null;
              if (createdInfo) {
                const current = lstatOrNull(childPath);
                if (current && sameIdentity(createdInfo, current)) unlinkSync(childPath);
              }
            }
            activeChildInfo = null;
            throw error;
          } finally {
            if (descriptor !== null) closeSync(descriptor);
          }
          fsyncDirectory(lockDir);
          return childProcessStartIdentity;
        },
        clearChild() {
          if (!activeChildInfo) return;
          const current = lstatSync(childPath);
          if (
            current.isSymbolicLink() ||
            !current.isFile() ||
            !sameIdentity(activeChildInfo, current)
          ) {
            throw new Error("renderer lock child metadata changed identity before cleanup");
          }
          unlinkSync(childPath);
          runReleaseTestHook("child-unlinked");
          fsyncDirectory(lockDir);
          activeChildInfo = null;
          runReleaseTestHook("child-fsynced");
        },
        release() {
          if (activeChildInfo) {
            throw new Error(
              "refusing to release renderer lock while a recorded child may still be alive",
            );
          }
          const current = readJsonFileNoFollow(ownerPath, "renderer lock owner metadata");
          if (
            current.value.token !== token ||
            current.value.pid !== process.pid ||
            current.value.bootIdentity !== bootIdentity ||
            current.value.processStartIdentity !== processStartIdentity
          ) {
            throw new Error("refusing to release a renderer lock owned by another process");
          }
          quarantineAndRemoveOwnedLock(directoryInfo, current.info);
        },
      };
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      if (eexistDelayMs > 0) await sleep(eexistDelayMs);
      let inspection;
      try {
        inspection = inspectAndMaybeRemoveStaleLock(reclaimer);
      } catch (inspectionError) {
        if (!isRetryableLockRace(inspectionError)) throw inspectionError;
        await sleep(pollMs);
        continue;
      }
      if (inspection.removed) continue;
      lockDiagnostic = inspection.diagnostic;
      if (Date.now() >= deadline) {
        const detail = lockDiagnostic ? `; ${lockDiagnostic}` : "";
        const manualRecovery = lockDiagnostic?.includes("cannot be proven stale")
          ? `; after verifying the recorded process group is gone, remove ${lockDir} manually`
          : "";
        throw new Error(
          `timed out after ${waitMs}ms waiting for the standalone renderer build lock${detail}${manualRecovery}`,
        );
      }
      await sleep(pollMs);
    }
  }
}

function trace(event, token) {
  const tracePath = process.env.SEER_RENDERER_BUILD_TEST_TRACE;
  if (!tracePath) return;
  appendFileSync(tracePath, `${JSON.stringify({ event, token, pid: process.pid })}\n`, "utf8");
}

function signalChild(child, processGroupId, processStartIdentity, signal, leaderExited = false) {
  if (Number.isSafeInteger(processGroupId) && processGroupId > 0) {
    const currentStartIdentity = readProcessStartIdentity(child.pid);
    if (
      currentStartIdentity &&
      (leaderExited ||
        (processStartIdentity !== null && currentStartIdentity !== processStartIdentity))
    ) {
      return;
    }
    if (
      !currentStartIdentity &&
      (processGroupId !== child.pid || !isProcessGroupAlive(processGroupId))
    ) {
      return;
    }
    try {
      process.kill(-processGroupId, signal);
      return;
    } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
    return;
  }
  child.kill(signal);
}

function remainingSpawnedProcessGroupIsAlive(child, processGroupId) {
  if (!Number.isSafeInteger(processGroupId) || processGroupId <= 0) {
    return false;
  }
  // This runs only from ChildProcess's close event, after the recorded leader
  // has exited. Any process now visible at that PID is recycled and unrelated.
  if (readProcessStartIdentity(child.pid)) return false;
  return isProcessGroupAlive(processGroupId);
}

async function terminateRemainingProcessGroup(child, processGroupId, processStartIdentity) {
  if (!remainingSpawnedProcessGroupIsAlive(child, processGroupId)) return;
  signalChild(child, processGroupId, processStartIdentity, "SIGTERM", true);
  const termDeadline = Date.now() + 2_000;
  while (Date.now() < termDeadline && remainingSpawnedProcessGroupIsAlive(child, processGroupId)) {
    await sleep(20);
  }
  if (!remainingSpawnedProcessGroupIsAlive(child, processGroupId)) return;
  signalChild(child, processGroupId, processStartIdentity, "SIGKILL", true);
  const killDeadline = Date.now() + 2_000;
  while (Date.now() < killDeadline && remainingSpawnedProcessGroupIsAlive(child, processGroupId)) {
    await sleep(20);
  }
  if (remainingSpawnedProcessGroupIsAlive(child, processGroupId)) {
    throw new Error(`spawned process group ${processGroupId} remained alive after termination`);
  }
}

async function run(
  lock,
  command,
  args,
  { cwd = repoRoot, env = process.env, consumerSetupHooks = false } = {},
) {
  await new Promise((resolve, reject) => {
    const detached = process.platform !== "win32";
    let child;
    try {
      child = spawn(process.execPath, [consumerGatePath, command, ...args], {
        cwd,
        env: {
          ...env,
          SEER_RENDERER_CONSUMER_GATE_FD: "3",
        },
        stdio: ["inherit", "inherit", "inherit", "pipe"],
        detached,
      });
    } catch (error) {
      reject(error);
      return;
    }

    let spawnError = null;
    let setupError = null;
    let exitResult = null;
    let childRecorded = false;
    let childProcessStartIdentity = null;
    let processGroupId =
      Number.isSafeInteger(child.pid) && child.pid > 0 && detached ? child.pid : null;
    const gate = child.stdio[3];
    const handlers = new Map();
    const failSetup = (error) => {
      setupError = error;
      gate?.destroy();
      try {
        signalChild(child, processGroupId, childProcessStartIdentity, "SIGTERM");
      } catch {
        // The setup error is authoritative.
      }
    };
    const cleanupHandlers = () => {
      for (const [signal, handler] of handlers) process.off(signal, handler);
    };
    child.once("error", (error) => {
      spawnError = error;
    });
    child.once("exit", (code, signal) => {
      exitResult = { code, signal };
    });
    child.once("close", (code, signal) => {
      cleanupHandlers();
      gate?.destroy();
      void (async () => {
        if (childRecorded || setupError) {
          await terminateRemainingProcessGroup(child, processGroupId, childProcessStartIdentity);
        }
        if (childRecorded) {
          lock.clearChild();
          childRecorded = false;
        }
        if (spawnError) {
          reject(spawnError);
        } else if (setupError) {
          reject(setupError);
        } else if (code === 0) {
          resolve();
        } else {
          const result = exitResult ?? { code, signal };
          reject(
            new Error(
              `${command} exited ${
                result.signal ? `on ${result.signal}` : `with status ${result.code}`
              }`,
            ),
          );
        }
      })().catch(reject);
    });
    try {
      if (consumerSetupHooks) runConsumerSetupTestHook("spawned");
    } catch (error) {
      failSetup(error);
      return;
    }

    if (!Number.isSafeInteger(child.pid) || child.pid <= 0) {
      setupError = new Error(`${command} spawned without a process id`);
      return;
    }
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
      const handler = () => signalChild(child, processGroupId, childProcessStartIdentity, signal);
      handlers.set(signal, handler);
      process.once(signal, handler);
    }
    try {
      if (consumerSetupHooks) runConsumerSetupTestHook("handlers");
    } catch (error) {
      failSetup(error);
      return;
    }
    try {
      childProcessStartIdentity = lock.recordChild(child.pid, processGroupId, {
        role: "consumer-gate",
        command,
        arguments: args,
      });
      childRecorded = true;
    } catch (error) {
      failSetup(error);
      return;
    }
    try {
      if (consumerSetupHooks) runConsumerSetupTestHook("metadata");
      if (!gate || !gate.writable) {
        throw new Error("renderer consumer gate pipe is unavailable");
      }
      if (consumerSetupHooks) runConsumerSetupTestHook("gate");
      gate.write("G");
      gate.end();
    } catch (error) {
      failSetup(error);
    }
  });
}

function removeTreeNoFollow(path) {
  const info = lstatSync(path);
  if (
    info.isSymbolicLink() ||
    !info.isDirectory() ||
    (typeof process.getuid === "function" && info.uid !== process.getuid())
  ) {
    throw new Error(`refusing to recursively remove unsafe or unowned directory: ${path}`);
  }
  const descriptor = openSync(
    path,
    constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
  );
  try {
    const opened = fstatSync(descriptor);
    if (!sameIdentity(info, opened)) {
      throw new Error(`directory changed identity before recursive removal: ${path}`);
    }
    fchmodSync(descriptor, opened.mode | 0o700);
  } finally {
    closeSync(descriptor);
  }
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const child = join(path, entry.name);
    if (entry.isDirectory() && !entry.isSymbolicLink()) {
      removeTreeNoFollow(child);
    } else {
      unlinkSync(child);
    }
  }
  rmdirSync(path);
}

function encodedIdentity(info) {
  return { dev: info.dev, ino: info.ino };
}

function validEncodedIdentity(value) {
  return (
    value &&
    typeof value === "object" &&
    Number.isSafeInteger(value.dev) &&
    value.dev >= 0 &&
    Number.isSafeInteger(value.ino) &&
    value.ino >= 0
  );
}

function identityMatches(info, expected) {
  return Boolean(
    info &&
    validEncodedIdentity(expected) &&
    info.dev === expected.dev &&
    info.ino === expected.ino,
  );
}

function assertExpectedDirectory(path, expectedIdentity, label) {
  const info = lstatSync(path);
  assertOwnedDirectory(info, label);
  if (expectedIdentity && !identityMatches(info, expectedIdentity)) {
    throw new Error(`${label} changed identity`);
  }
  if (dirname(path) !== rendererBuildRoot || realpathSync(path) !== path) {
    throw new Error(`${label} must be a canonical child of the renderer publication directory`);
  }
  return info;
}

function removeExpectedDirectory(path, expectedIdentity, label) {
  assertExpectedDirectory(path, expectedIdentity, label);
  removeTreeNoFollow(path);
}

function fsyncDirectory(path) {
  const descriptor = openSync(
    path,
    constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
  );
  try {
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
}

function prepareBuildRoot() {
  ensureOwnedDirectory(join(repoRoot, "build"), "repository build directory");
  ensureOwnedDirectory(rendererBuildRoot, "standalone renderer build directory");
}

function cleanupAbandonedSnapshots() {
  for (const entry of readdirSync(rendererBuildRoot, { withFileTypes: true })) {
    if (!rendererSnapshotNamePattern.test(entry.name)) continue;
    const path = join(rendererBuildRoot, entry.name);
    if (!entry.isDirectory() || entry.isSymbolicLink()) {
      throw new Error(`abandoned renderer snapshot must be a real directory: ${path}`);
    }
    removeExpectedDirectory(path, null, "abandoned renderer input snapshot");
  }
  fsyncDirectory(rendererBuildRoot);
}

function cleanupAbandonedStages() {
  for (const entry of readdirSync(rendererBuildRoot, { withFileTypes: true })) {
    if (
      !rendererStageNamePattern.test(entry.name) &&
      !legacyGenerationNamePattern.test(entry.name)
    ) {
      continue;
    }
    const path = join(rendererBuildRoot, entry.name);
    if (!entry.isDirectory() || entry.isSymbolicLink()) {
      throw new Error(`abandoned renderer stage must be a real directory: ${path}`);
    }
    removeExpectedDirectory(path, null, "abandoned renderer private directory");
  }
  fsyncDirectory(rendererBuildRoot);
}

function snapshotRelativePath(absolutePath) {
  return relative(repoRoot, absolutePath).split(sep).join("/");
}

function assertSnapshotSourceFile(path, label) {
  const info = lstatSync(path);
  if (info.isSymbolicLink() || !info.isFile()) {
    throw new Error(`${label} must be a regular non-symlink file`);
  }
  const canonicalParent = realpathSync(dirname(path));
  if (
    canonicalParent !== dirname(path) ||
    (!canonicalParent.startsWith(`${repoRoot}${sep}`) && canonicalParent !== repoRoot)
  ) {
    throw new Error(`${label} parent must be a canonical repository directory`);
  }
  return info;
}

function copySnapshotInput(sourcePath, destinationPath, relativePath) {
  const before = assertSnapshotSourceFile(sourcePath, `renderer build input ${relativePath}`);
  const sourceDescriptor = openSync(sourcePath, constants.O_RDONLY | constants.O_NOFOLLOW);
  let contents;
  let opened;
  try {
    opened = fstatSync(sourceDescriptor);
    if (!opened.isFile() || !sameIdentity(before, opened)) {
      throw new Error(`renderer build input ${relativePath} changed identity while opening`);
    }
    contents = readFileSync(sourceDescriptor);
    const afterRead = fstatSync(sourceDescriptor);
    if (
      !sameIdentity(opened, afterRead) ||
      opened.size !== afterRead.size ||
      opened.mtimeMs !== afterRead.mtimeMs ||
      opened.ctimeMs !== afterRead.ctimeMs
    ) {
      throw new Error(`renderer build input ${relativePath} changed while snapshotting`);
    }
  } finally {
    closeSync(sourceDescriptor);
  }

  const destinationDescriptor = openSync(
    destinationPath,
    constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
    0o600,
  );
  try {
    writeFileSync(destinationDescriptor, contents);
    fchmodSync(destinationDescriptor, opened.mode & 0o777);
    fsyncSync(destinationDescriptor);
  } finally {
    closeSync(destinationDescriptor);
  }
  const current = assertSnapshotSourceFile(sourcePath, `renderer build input ${relativePath}`);
  if (
    !sameIdentity(opened, current) ||
    opened.size !== current.size ||
    opened.mtimeMs !== current.mtimeMs ||
    opened.ctimeMs !== current.ctimeMs
  ) {
    throw new Error(`renderer build input ${relativePath} changed while snapshotting`);
  }
}

function freezeSnapshotTree(path) {
  const info = lstatSync(path);
  if (info.isSymbolicLink()) {
    throw new Error(`renderer input snapshot must not contain symlinks: ${path}`);
  }
  if (info.isDirectory()) {
    const descriptor = openSync(
      path,
      constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
    );
    try {
      for (const entry of readdirSync(path, { withFileTypes: true })) {
        freezeSnapshotTree(join(path, entry.name));
      }
      const opened = fstatSync(descriptor);
      if (!opened.isDirectory() || !sameIdentity(info, opened)) {
        throw new Error(`renderer input snapshot directory changed identity: ${path}`);
      }
      fchmodSync(descriptor, (opened.mode & 0o555) | 0o500);
    } finally {
      closeSync(descriptor);
    }
    return;
  }
  if (!info.isFile()) {
    throw new Error(`renderer input snapshot must contain only regular files: ${path}`);
  }
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const opened = fstatSync(descriptor);
    if (!opened.isFile() || !sameIdentity(info, opened)) {
      throw new Error(`renderer input snapshot file changed identity: ${path}`);
    }
    fchmodSync(descriptor, (opened.mode & 0o555) | 0o400);
  } finally {
    closeSync(descriptor);
  }
}

function createRendererInputSnapshot() {
  const snapshotPath = join(
    rendererBuildRoot,
    `.renderer-snapshot-${randomUUID().replaceAll("-", "")}`,
  );
  mkdirSync(snapshotPath, { mode: 0o700 });
  try {
    for (const relativePath of rendererBuildInputFiles(repoRoot)) {
      const sourcePath = join(repoRoot, ...relativePath.split("/"));
      const destinationPath = join(snapshotPath, ...relativePath.split("/"));
      const destinationParent = dirname(destinationPath);
      mkdirSync(destinationParent, { recursive: true, mode: 0o700 });
      if (
        snapshotRelativePath(sourcePath) !== relativePath ||
        !destinationPath.startsWith(`${snapshotPath}${sep}`)
      ) {
        throw new Error(`renderer build input path is unsafe: ${relativePath}`);
      }
      copySnapshotInput(sourcePath, destinationPath, relativePath);
    }
    freezeSnapshotTree(snapshotPath);
    const snapshotInfo = assertExpectedDirectory(
      snapshotPath,
      null,
      "private renderer input snapshot",
    );
    return {
      digest: computeRendererBuildDigest(snapshotPath),
      info: snapshotInfo,
      path: snapshotPath,
    };
  } catch (error) {
    if (lstatOrNull(snapshotPath)) {
      removeExpectedDirectory(snapshotPath, null, "failed renderer input snapshot");
    }
    throw error;
  }
}

function validatePublicationPath(path, expectedNamePattern, label) {
  if (
    typeof path !== "string" ||
    !isAbsolute(path) ||
    path !== resolve(path) ||
    dirname(path) !== rendererBuildRoot ||
    !expectedNamePattern.test(basename(path))
  ) {
    throw new Error(`renderer publication journal ${label} path is invalid`);
  }
}

function validatePublicationJournal(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("renderer publication transaction journal root must be an object");
  }
  if (payload.schemaVersion !== publicationJournalSchemaVersion) {
    throw new Error("unsupported renderer publication transaction journal schema");
  }
  if (!publicationPhases.has(payload.phase)) {
    throw new Error("renderer publication transaction journal phase is invalid");
  }
  const paths = payload.paths;
  if (!paths || typeof paths !== "object" || Array.isArray(paths)) {
    throw new Error("renderer publication transaction journal paths must be an object");
  }
  if (paths.publicationParent !== rendererBuildRoot || paths.renderer !== publishedRenderer) {
    throw new Error("renderer publication transaction journal fixed path is invalid");
  }
  validatePublicationPath(paths.stage, rendererStageNamePattern, "stage");
  validatePublicationPath(paths.backup, rendererBackupNamePattern, "backup");

  const oldRenderer = payload.oldRenderer;
  if (
    !oldRenderer ||
    typeof oldRenderer !== "object" ||
    typeof oldRenderer.present !== "boolean" ||
    (oldRenderer.present
      ? !validEncodedIdentity(oldRenderer.identity)
      : oldRenderer.identity !== null)
  ) {
    throw new Error("renderer publication transaction journal old Renderer record is invalid");
  }
  if (!validEncodedIdentity(payload.newRendererIdentity)) {
    throw new Error("renderer publication transaction journal new Renderer identity is invalid");
  }
  return payload;
}

function readPublicationJournal() {
  const info = lstatOrNull(publicationJournalPath);
  if (!info) return { info: null, payload: null };
  if (info.size > publicationJournalMaxBytes) {
    throw new Error("renderer publication transaction journal exceeds the size limit");
  }
  const record = readJsonFileNoFollow(
    publicationJournalPath,
    "renderer publication transaction journal",
  );
  if (typeof process.getuid === "function" && record.info.uid !== process.getuid()) {
    throw new Error("renderer publication transaction journal is not owned by the current uid");
  }
  return { info: record.info, payload: validatePublicationJournal(record.value) };
}

function validateUncommittedPublicationJournalTemp() {
  const before = lstatOrNull(publicationJournalTempPath);
  if (!before) return null;
  if (
    before.isSymbolicLink() ||
    !before.isFile() ||
    (typeof process.getuid === "function" && before.uid !== process.getuid())
  ) {
    throw new Error(
      "renderer publication transaction journal temp must be a regular non-symlink file owned by the current uid",
    );
  }
  const descriptor = openSync(
    publicationJournalTempPath,
    constants.O_RDONLY | constants.O_NOFOLLOW,
  );
  try {
    const opened = fstatSync(descriptor);
    if (!sameIdentity(before, opened)) {
      throw new Error("renderer publication transaction journal temp changed identity");
    }
  } finally {
    closeSync(descriptor);
  }
  return before;
}

function discardUncommittedPublicationJournalTemp() {
  const tempInfo = validateUncommittedPublicationJournalTemp();
  if (!tempInfo) return;
  const current = lstatSync(publicationJournalTempPath);
  if (!sameIdentity(tempInfo, current)) {
    throw new Error("renderer publication transaction journal temp changed before cleanup");
  }
  unlinkSync(publicationJournalTempPath);
  fsyncDirectory(rendererBuildRoot);
}

function persistPublicationJournal(payload) {
  validatePublicationJournal(payload);
  const encoded = `${JSON.stringify(payload)}\n`;
  if (Buffer.byteLength(encoded) > publicationJournalMaxBytes) {
    throw new Error("renderer publication transaction journal exceeds the size limit");
  }
  if (lstatOrNull(publicationJournalTempPath)) {
    throw new Error("renderer publication transaction journal temp already exists");
  }
  const descriptor = openSync(
    publicationJournalTempPath,
    constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
    0o600,
  );
  try {
    writeFileSync(descriptor, encoded, "utf8");
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
  renameSync(publicationJournalTempPath, publicationJournalPath);
  fsyncDirectory(rendererBuildRoot);
}

function removePublicationJournal() {
  const record = readJsonFileNoFollow(
    publicationJournalPath,
    "renderer publication transaction journal",
  );
  const current = lstatSync(publicationJournalPath);
  if (!sameIdentity(record.info, current)) {
    throw new Error("renderer publication transaction journal changed before cleanup");
  }
  unlinkSync(publicationJournalPath);
  fsyncDirectory(rendererBuildRoot);
}

function validateRendererGeneration(path, expectedIdentity, label) {
  assertExpectedDirectory(path, expectedIdentity, label);
  const manifestPath = join(path, "build-manifest.json");
  const manifestRecord = readJsonFileNoFollow(manifestPath, `${label} build manifest`);
  if (typeof process.getuid === "function" && manifestRecord.info.uid !== process.getuid()) {
    throw new Error(`${label} build manifest is not owned by the current uid`);
  }
  const actual = manifestRecord.value;
  const expectedKeys = ["algorithm", "assetDigest", "schemaVersion", "sourceDigest"];
  if (
    !actual ||
    typeof actual !== "object" ||
    Array.isArray(actual) ||
    JSON.stringify(Object.keys(actual).sort()) !== JSON.stringify(expectedKeys) ||
    actual.schemaVersion !== RENDERER_BUILD_MANIFEST_SCHEMA_VERSION ||
    actual.algorithm !== RENDERER_BUILD_MANIFEST_ALGORITHM ||
    typeof actual.sourceDigest !== "string" ||
    !/^[0-9a-f]{64}$/.test(actual.sourceDigest) ||
    typeof actual.assetDigest !== "string" ||
    !/^[0-9a-f]{64}$/.test(actual.assetDigest) ||
    actual.assetDigest !== computeRendererAssetDigest(path)
  ) {
    throw new Error(`${label} build manifest does not validate the complete generation`);
  }
}

function inspectRecoveryDirectory(path, expectedIdentity, label) {
  const info = lstatOrNull(path);
  if (!info) return null;
  assertExpectedDirectory(path, expectedIdentity, label);
  return info;
}

function rollbackRendererPublication(payload) {
  const { stage, backup } = payload.paths;
  let rendererInfo = inspectRecoveryDirectory(
    publishedRenderer,
    null,
    "published Renderer during rollback",
  );
  let stageInfo = inspectRecoveryDirectory(
    stage,
    payload.newRendererIdentity,
    "private renderer stage during rollback",
  );
  let backupInfo = inspectRecoveryDirectory(
    backup,
    payload.oldRenderer.identity,
    "private Renderer backup during rollback",
  );

  if (
    rendererInfo &&
    identityMatches(rendererInfo, payload.newRendererIdentity) &&
    payload.oldRenderer.present &&
    !backupInfo
  ) {
    throw new Error(
      "cannot roll back the new Renderer because the committed old backup is no longer available",
    );
  }
  if (rendererInfo && identityMatches(rendererInfo, payload.newRendererIdentity)) {
    removeExpectedDirectory(
      publishedRenderer,
      payload.newRendererIdentity,
      "new published Renderer during rollback",
    );
    rendererInfo = null;
  }
  if (rendererInfo && !identityMatches(rendererInfo, payload.oldRenderer.identity)) {
    throw new Error("published Renderer has an unknown identity during rollback");
  }

  if (payload.oldRenderer.present) {
    if (rendererInfo) {
      if (backupInfo) {
        throw new Error("duplicate old Renderer found during rollback");
      }
    } else {
      if (!backupInfo) {
        throw new Error("old Renderer backup is missing during rollback");
      }
      renameSync(backup, publishedRenderer);
      backupInfo = null;
    }
  } else if (rendererInfo || backupInfo) {
    throw new Error("unexpected old Renderer artifact during rollback");
  }

  if (stageInfo) {
    removeExpectedDirectory(
      stage,
      payload.newRendererIdentity,
      "private renderer stage during rollback",
    );
    stageInfo = null;
  }
  fsyncDirectory(rendererBuildRoot);
  removePublicationJournal();
}

function runPublicationTestHook(phase) {
  const hookPath = process.env.SEER_RENDERER_PUBLICATION_TEST_HOOK;
  if (!hookPath || process.env.SEER_RENDERER_PUBLICATION_TEST_PHASE !== phase) return;
  const result = spawnSync(process.execPath, [hookPath, phase], {
    cwd: repoRoot,
    env: process.env,
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`renderer publication test hook exited with status ${result.status}`);
  }
}

function finishCommittedRendererPublication(payload) {
  const { stage, backup } = payload.paths;
  validateRendererGeneration(
    publishedRenderer,
    payload.newRendererIdentity,
    "new published Renderer",
  );
  if (lstatOrNull(stage)) {
    throw new Error("private renderer stage still exists beside the published generation");
  }

  if (payload.phase !== "cleanup") {
    payload.phase = "cleanup";
    persistPublicationJournal(payload);
  }
  runPublicationTestHook("cleanup");

  const backupInfo = lstatOrNull(backup);
  if (backupInfo) {
    if (!payload.oldRenderer.present) {
      throw new Error("unexpected private Renderer backup during cleanup");
    }
    removeExpectedDirectory(
      backup,
      payload.oldRenderer.identity,
      "private Renderer backup during cleanup",
    );
    fsyncDirectory(rendererBuildRoot);
  }
  runPublicationTestHook("backup-cleaned");
  removePublicationJournal();
}

function recoverRendererPublication() {
  const { payload } = readPublicationJournal();
  discardUncommittedPublicationJournalTemp();
  if (!payload) return;

  const { stage, backup } = payload.paths;
  const rendererInfo = inspectRecoveryDirectory(
    publishedRenderer,
    null,
    "published Renderer during recovery",
  );
  const stageInfo = inspectRecoveryDirectory(
    stage,
    payload.newRendererIdentity,
    "private renderer stage during recovery",
  );
  inspectRecoveryDirectory(
    backup,
    payload.oldRenderer.identity,
    "private Renderer backup during recovery",
  );
  if (rendererInfo && identityMatches(rendererInfo, payload.newRendererIdentity) && !stageInfo) {
    try {
      validateRendererGeneration(
        publishedRenderer,
        payload.newRendererIdentity,
        "new published Renderer during recovery",
      );
    } catch (error) {
      rollbackRendererPublication(payload);
      return;
    }
    finishCommittedRendererPublication(payload);
    return;
  }
  rollbackRendererPublication(payload);
}

function publishRendererStage(stagePath, stageInfo) {
  const existing = lstatOrNull(publishedRenderer);
  if (existing) assertOwnedDirectory(existing, "published Renderer");
  const backupPath = join(
    rendererBuildRoot,
    `.renderer-backup-${randomUUID().replaceAll("-", "")}`,
  );
  const journal = {
    schemaVersion: publicationJournalSchemaVersion,
    phase: "prepared",
    paths: {
      publicationParent: rendererBuildRoot,
      renderer: publishedRenderer,
      stage: stagePath,
      backup: backupPath,
    },
    oldRenderer: {
      present: Boolean(existing),
      identity: existing ? encodedIdentity(existing) : null,
    },
    newRendererIdentity: encodedIdentity(stageInfo),
  };
  persistPublicationJournal(journal);
  runPublicationTestHook("prepared");

  try {
    if (existing) {
      renameSync(publishedRenderer, backupPath);
      fsyncDirectory(rendererBuildRoot);
    }
    journal.phase = "old-backed-up";
    persistPublicationJournal(journal);
    runPublicationTestHook("old-backed-up");

    renameSync(stagePath, publishedRenderer);
    fsyncDirectory(rendererBuildRoot);
    journal.phase = "new-published";
    persistPublicationJournal(journal);
    runPublicationTestHook("new-published");
    finishCommittedRendererPublication(journal);
  } catch (error) {
    recoverRendererPublication();
    throw error;
  }
}

async function buildAndPublish(lock) {
  prepareBuildRoot();
  cleanupAbandonedSnapshots();
  recoverRendererPublication();
  cleanupAbandonedStages();
  for (let attempt = 0; attempt <= sourceChangeMaxRetries; attempt += 1) {
    const token = randomUUID().replaceAll("-", "");
    const stagePath = join(rendererBuildRoot, `.renderer-stage-${token}`);
    mkdirSync(stagePath, { mode: 0o700 });
    let transactionStarted = false;
    let snapshot = null;
    try {
      const testBuilder = process.env.SEER_RENDERER_BUILD_TEST_BUILDER;
      snapshot = createRendererInputSnapshot();
      if (testBuilder) {
        await run(lock, process.execPath, [testBuilder, stagePath]);
      } else {
        await run(
          lock,
          process.env.SEER_RENDERER_BUILD_TEST_VITE_EXECUTABLE ??
            join(repoRoot, "node_modules", ".bin", "vite"),
          [
            "build",
            "--config",
            join(snapshot.path, "vite.standalone.config.ts"),
            "--outDir",
            stagePath,
          ],
          {
            cwd: snapshot.path,
            env: { ...process.env, SEER_RENDERER_PRIVATE_OUT_DIR: stagePath },
          },
        );
      }
      const sourceDigestAfterBuild = computeRendererBuildDigest(repoRoot);
      if (sourceDigestAfterBuild !== snapshot.digest) {
        removeExpectedDirectory(stagePath, null, "source-raced private renderer stage");
        fsyncDirectory(rendererBuildRoot);
        if (attempt === sourceChangeMaxRetries) {
          throw new Error(
            `renderer sources changed during ${attempt + 1} consecutive build attempts; retry after edits settle`,
          );
        }
        continue;
      }
      const stageInfo = assertExpectedDirectory(stagePath, null, "private renderer stage");
      const manifestPath = join(stagePath, "build-manifest.json");
      const manifest = buildRendererBuildManifest(snapshot.path, stagePath, snapshot.digest);
      const descriptor = openSync(
        manifestPath,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
        0o600,
      );
      try {
        writeFileSync(descriptor, serializeRendererBuildManifest(manifest), "utf8");
        fsyncSync(descriptor);
      } finally {
        closeSync(descriptor);
      }
      fsyncDirectory(stagePath);
      transactionStarted = true;
      publishRendererStage(stagePath, stageInfo);
      return;
    } catch (error) {
      if (!transactionStarted && lstatOrNull(stagePath)) {
        removeExpectedDirectory(stagePath, null, "failed private renderer stage");
        fsyncDirectory(rendererBuildRoot);
      }
      throw error;
    } finally {
      if (snapshot && lstatOrNull(snapshot.path)) {
        removeExpectedDirectory(snapshot.path, snapshot.info, "private renderer input snapshot");
        fsyncDirectory(rendererBuildRoot);
      }
    }
  }
}

function consumerArguments() {
  const args = process.argv.slice(2);
  if (args.length === 0) return [];
  if (args[0] !== "--" || args.length === 1) {
    throw new Error("usage: build-standalone-renderer.mjs [-- <consumer-command> [args...]]");
  }
  return args.slice(1);
}

async function main() {
  const consumer = consumerArguments();
  // Compile (or, in tests, load) the renderer asset digest helper's image
  // once, before ever acquiring the renderer build lock below, so that
  // real compile - the only one this whole process ever pays for, see
  // loadOrCompileRendererAssetDigestHelperImageOnce - never consumes any of
  // the lock's own liveness budget. Every computeRendererAssetDigest call
  // made later in this process, including ones made while the lock is
  // held, reuses this same cached image.
  prepareRendererAssetDigestHelperImage();
  const lock = await acquireLock();
  let operationError = null;
  trace("start", lock.token);
  try {
    await buildAndPublish(lock);
    if (consumer.length > 0) {
      trace("consumer-start", lock.token);
      await run(lock, consumer[0], consumer.slice(1), {
        env: { ...process.env, SEER_RENDERER_LOCK_HELD: lock.token },
        consumerSetupHooks: true,
      });
      trace("consumer-end", lock.token);
    }
  } catch (error) {
    operationError = error;
    throw error;
  } finally {
    trace("end", lock.token);
    try {
      lock.release();
    } catch (releaseError) {
      if (!operationError) throw releaseError;
      operationError.message += `; renderer lock cleanup also failed: ${releaseError.message}`;
    }
  }
}

main().catch((error) => {
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
});
