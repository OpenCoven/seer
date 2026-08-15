#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  appendFileSync,
  closeSync,
  constants,
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
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  RENDERER_BUILD_MANIFEST_ALGORITHM,
  RENDERER_BUILD_MANIFEST_SCHEMA_VERSION,
  buildRendererBuildManifest,
  computeRendererAssetDigest,
  computeRendererBuildDigest,
  serializeRendererBuildManifest,
} from "./renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const lockDir = join(repoRoot, ".seer-standalone-renderer.lock");
const ownerPath = join(lockDir, "owner.json");
const childPath = join(lockDir, "child.json");
const rendererBuildRoot = join(repoRoot, "build", "standalone-renderer");
const publishedRenderer = join(rendererBuildRoot, "Renderer");
const publicationJournalPath = join(rendererBuildRoot, ".renderer-publication-transaction.json");
const publicationJournalTempPath = join(rendererBuildRoot, ".renderer-publication-transaction.new");
const publicationJournalSchemaVersion = 1;
const publicationJournalMaxBytes = 64 * 1024;
const rendererStageNamePattern = /^\.renderer-stage-[0-9a-f]{32}$/;
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
const sourceChangeMaxRetries = positiveIntegerFromEnv(
  "SEER_RENDERER_SOURCE_CHANGE_MAX_RETRIES",
  2,
);

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
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
  return readProcessStartIdentity(record.pid) === record.processStartIdentity;
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
    typeof child.processStartIdentity !== "string" ||
    !owner ||
    typeof owner.token !== "string" ||
    child.token !== owner.token
  ) {
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

function removeVerifiedLock(expectedDirectory, knownEntries) {
  const currentDirectory = lstatSync(lockDir);
  assertOwnedDirectory(currentDirectory, "renderer lock");
  if (!sameIdentity(expectedDirectory, currentDirectory)) {
    throw new Error("renderer lock changed identity before cleanup");
  }

  const names = readdirSync(lockDir).sort();
  const expectedNames = [...knownEntries.keys()].sort();
  if (JSON.stringify(names) !== JSON.stringify(expectedNames)) {
    throw new Error(`renderer lock contains unexpected entries: ${names.join(", ")}`);
  }
  for (const [name, expectedInfo] of knownEntries) {
    const path = join(lockDir, name);
    const current = lstatSync(path);
    if (current.isSymbolicLink() || !current.isFile() || !sameIdentity(expectedInfo, current)) {
      throw new Error(`renderer lock ${name} changed identity before cleanup`);
    }
    unlinkSync(path);
  }
  rmdirSync(lockDir);
}

function inspectAndMaybeRemoveStaleLock() {
  const directoryInfo = lstatOrNull(lockDir);
  if (!directoryInfo) return { removed: true, diagnostic: null };
  assertOwnedDirectory(directoryInfo, "renderer lock");

  let ownerRecord = null;
  let childRecord = null;
  try {
    ownerRecord = readJsonFileNoFollow(ownerPath, "renderer lock owner metadata");
  } catch (error) {
    if (error.code !== "ENOENT" && Date.now() - directoryInfo.mtimeMs < staleMs) {
      return { removed: false, diagnostic: "renderer lock owner metadata is not yet stale" };
    }
    if (error.code !== "ENOENT") {
      if (!error.verifiedFileInfo) throw error;
      ownerRecord = { info: error.verifiedFileInfo, value: null };
    }
  }
  try {
    childRecord = readJsonFileNoFollow(childPath, "renderer lock child metadata");
  } catch (error) {
    if (error.code !== "ENOENT" && Date.now() - directoryInfo.mtimeMs < staleMs) {
      return { removed: false, diagnostic: "renderer lock child metadata is not yet stale" };
    }
    if (error.code !== "ENOENT") {
      if (!error.verifiedFileInfo) throw error;
      childRecord = { info: error.verifiedFileInfo, value: null };
    }
  }

  const owner = ownerRecord?.value;
  if (recordedProcessIsLive(owner)) {
    return {
      removed: false,
      diagnostic: `recorded renderer lock owner ${owner.pid} is still alive`,
    };
  }
  const childGroup = recordedChildGroupState(childRecord, owner);
  if (childGroup.state !== "stale") {
    return { removed: false, diagnostic: childGroup.diagnostic };
  }

  const createdAtMs = Number.isSafeInteger(owner?.createdAtMs)
    ? owner.createdAtMs
    : directoryInfo.mtimeMs;
  if (Date.now() - createdAtMs < staleMs) {
    return { removed: false, diagnostic: "renderer lock has not reached its stale age" };
  }

  const knownEntries = new Map();
  if (ownerRecord) knownEntries.set("owner.json", ownerRecord.info);
  if (childRecord) knownEntries.set("child.json", childRecord.info);
  try {
    removeVerifiedLock(directoryInfo, knownEntries);
  } catch (error) {
    if (error.code === "ENOENT") return { removed: true, diagnostic: null };
    throw error;
  }
  return { removed: true, diagnostic: null };
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

  while (true) {
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
        recordChild(pid, processGroupId) {
          const childProcessStartIdentity = readProcessStartIdentity(pid);
          if (!childProcessStartIdentity) {
            throw new Error("unable to identify spawned renderer process start");
          }
          writeFileSync(
            childPath,
            `${JSON.stringify({
              token,
              pid,
              processGroupId,
              createdAtMs: Date.now(),
              bootIdentity,
              processStartIdentity: childProcessStartIdentity,
            })}\n`,
            { encoding: "utf8", flag: "wx", mode: 0o600 },
          );
          activeChildInfo = lstatSync(childPath);
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
          activeChildInfo = null;
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
          removeVerifiedLock(directoryInfo, new Map([["owner.json", current.info]]));
        },
      };
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      if (eexistDelayMs > 0) await sleep(eexistDelayMs);
      const inspection = inspectAndMaybeRemoveStaleLock();
      if (inspection.removed) continue;
      lockDiagnostic = inspection.diagnostic;
      if (Date.now() >= deadline) {
        const detail = lockDiagnostic ? `; ${lockDiagnostic}` : "";
        const manualRecovery =
          lockDiagnostic?.includes("cannot be proven stale")
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
      (leaderExited || currentStartIdentity !== processStartIdentity)
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

async function run(lock, command, args, { env = process.env } = {}) {
  await new Promise((resolve, reject) => {
    const detached = process.platform !== "win32";
    const child = spawn(command, args, {
      cwd: repoRoot,
      env,
      stdio: "inherit",
      detached,
    });
    const processGroupId = detached ? child.pid : null;
    let childProcessStartIdentity;
    try {
      childProcessStartIdentity = lock.recordChild(child.pid, processGroupId);
    } catch (error) {
      child.once("close", () => reject(error));
      return;
    }

    let spawnError = null;
    const handlers = new Map();
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
      const handler = () =>
        signalChild(child, processGroupId, childProcessStartIdentity, signal);
      handlers.set(signal, handler);
      process.once(signal, handler);
    }
    const cleanupHandlers = () => {
      for (const [signal, handler] of handlers) process.off(signal, handler);
    };
    child.once("error", (error) => {
      spawnError = error;
      try {
        signalChild(child, processGroupId, childProcessStartIdentity, "SIGTERM");
      } catch {
        // The original spawn error is authoritative.
      }
    });
    child.once("close", (code, signal) => {
      cleanupHandlers();
      void (async () => {
        await terminateRemainingProcessGroup(child, processGroupId, childProcessStartIdentity);
        lock.clearChild();
        if (spawnError) {
          reject(spawnError);
        } else if (code === 0) {
          resolve();
        } else {
          reject(new Error(`${command} exited ${signal ? `on ${signal}` : `with status ${code}`}`));
        }
      })().catch(reject);
    });
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
    removeExpectedDirectory(path, null, "abandoned renderer stage");
  }
  fsyncDirectory(rendererBuildRoot);
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
  recoverRendererPublication();
  cleanupAbandonedStages();
  for (let attempt = 0; attempt <= sourceChangeMaxRetries; attempt += 1) {
    const token = randomUUID().replaceAll("-", "");
    const stagePath = join(rendererBuildRoot, `.renderer-stage-${token}`);
    mkdirSync(stagePath, { mode: 0o700 });
    let transactionStarted = false;
    try {
      const testBuilder = process.env.SEER_RENDERER_BUILD_TEST_BUILDER;
      const sourceDigestBeforeBuild = computeRendererBuildDigest(repoRoot);
      if (testBuilder) {
        await run(lock, process.execPath, [testBuilder, stagePath]);
      } else {
        await run(
          lock,
          join(repoRoot, "node_modules", ".bin", "vite"),
          ["build", "--config", "vite.standalone.config.ts", "--outDir", stagePath],
          { env: { ...process.env, SEER_RENDERER_PRIVATE_OUT_DIR: stagePath } },
        );
      }
      const sourceDigestAfterBuild = computeRendererBuildDigest(repoRoot);
      if (sourceDigestAfterBuild !== sourceDigestBeforeBuild) {
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
      const manifest = buildRendererBuildManifest(
        repoRoot,
        stagePath,
        sourceDigestBeforeBuild,
      );
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
  const lock = await acquireLock();
  let operationError = null;
  trace("start", lock.token);
  try {
    await buildAndPublish(lock);
    if (consumer.length > 0) {
      trace("consumer-start", lock.token);
      await run(lock, consumer[0], consumer.slice(1), {
        env: { ...process.env, SEER_RENDERER_LOCK_HELD: lock.token },
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
