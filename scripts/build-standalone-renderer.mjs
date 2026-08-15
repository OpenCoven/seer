#!/usr/bin/env node
import { spawn } from "node:child_process";
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
import { dirname, join } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  buildRendererBuildManifest,
  serializeRendererBuildManifest,
} from "./renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const lockDir = join(repoRoot, ".seer-standalone-renderer.lock");
const ownerPath = join(lockDir, "owner.json");
const childPath = join(lockDir, "child.json");
const rendererBuildRoot = join(repoRoot, "build", "standalone-renderer");
const publishedRenderer = join(rendererBuildRoot, "Renderer");

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
  if (!directoryInfo) return true;
  assertOwnedDirectory(directoryInfo, "renderer lock");

  let ownerRecord = null;
  let childRecord = null;
  try {
    ownerRecord = readJsonFileNoFollow(ownerPath, "renderer lock owner metadata");
  } catch (error) {
    if (error.code !== "ENOENT" && Date.now() - directoryInfo.mtimeMs < staleMs) return false;
    if (error.code !== "ENOENT") {
      if (!error.verifiedFileInfo) throw error;
      ownerRecord = { info: error.verifiedFileInfo, value: null };
    }
  }
  try {
    childRecord = readJsonFileNoFollow(childPath, "renderer lock child metadata");
  } catch (error) {
    if (error.code !== "ENOENT" && Date.now() - directoryInfo.mtimeMs < staleMs) return false;
    if (error.code !== "ENOENT") {
      if (!error.verifiedFileInfo) throw error;
      childRecord = { info: error.verifiedFileInfo, value: null };
    }
  }

  const child = childRecord?.value;
  if (
    child &&
    (isPidAlive(child.pid) || isProcessGroupAlive(child.processGroupId))
  ) {
    return false;
  }
  const owner = ownerRecord?.value;
  if (owner && isPidAlive(owner.pid)) return false;

  const createdAtMs = Number.isSafeInteger(owner?.createdAtMs)
    ? owner.createdAtMs
    : directoryInfo.mtimeMs;
  if (Date.now() - createdAtMs < staleMs) return false;

  const knownEntries = new Map();
  if (ownerRecord) knownEntries.set("owner.json", ownerRecord.info);
  if (childRecord) knownEntries.set("child.json", childRecord.info);
  try {
    removeVerifiedLock(directoryInfo, knownEntries);
  } catch (error) {
    if (error.code === "ENOENT") return true;
    throw error;
  }
  return true;
}

function sleep(durationMs) {
  return new Promise((resolve) => setTimeout(resolve, durationMs));
}

async function acquireLock() {
  verifyRepoRoot();
  const token = randomUUID();
  const deadline = Date.now() + waitMs;

  while (true) {
    try {
      mkdirSync(lockDir, { mode: 0o700 });
      const directoryInfo = lstatSync(lockDir);
      assertOwnedDirectory(directoryInfo, "renderer lock");
      const owner = { token, pid: process.pid, createdAtMs: Date.now() };
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
      if (ownerRecord.value.token !== token || ownerRecord.value.pid !== process.pid) {
        throw new Error("renderer lock ownership could not be verified after acquisition");
      }

      let activeChildInfo = null;
      return {
        token,
        recordChild(pid, processGroupId) {
          writeFileSync(
            childPath,
            `${JSON.stringify({ token, pid, processGroupId, createdAtMs: Date.now() })}\n`,
            { encoding: "utf8", flag: "wx", mode: 0o600 },
          );
          activeChildInfo = lstatSync(childPath);
        },
        clearChild() {
          if (!activeChildInfo) return;
          const current = lstatSync(childPath);
          if (current.isSymbolicLink() || !current.isFile() || !sameIdentity(activeChildInfo, current)) {
            throw new Error("renderer lock child metadata changed identity before cleanup");
          }
          unlinkSync(childPath);
          activeChildInfo = null;
        },
        release() {
          if (activeChildInfo) {
            throw new Error("refusing to release renderer lock while a recorded child may still be alive");
          }
          const current = readJsonFileNoFollow(ownerPath, "renderer lock owner metadata");
          if (current.value.token !== token || current.value.pid !== process.pid) {
            throw new Error("refusing to release a renderer lock owned by another process");
          }
          removeVerifiedLock(directoryInfo, new Map([["owner.json", current.info]]));
        },
      };
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      if (eexistDelayMs > 0) await sleep(eexistDelayMs);
      if (inspectAndMaybeRemoveStaleLock()) continue;
      if (Date.now() >= deadline) {
        throw new Error(`timed out after ${waitMs}ms waiting for the standalone renderer build lock`);
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

function signalChild(child, processGroupId, signal) {
  if (Number.isSafeInteger(processGroupId) && processGroupId > 0) {
    try {
      process.kill(-processGroupId, signal);
      return;
    } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }
  child.kill(signal);
}

async function terminateRemainingProcessGroup(child, processGroupId) {
  if (!isProcessGroupAlive(processGroupId)) return;
  signalChild(child, processGroupId, "SIGTERM");
  const termDeadline = Date.now() + 2_000;
  while (Date.now() < termDeadline && isProcessGroupAlive(processGroupId)) {
    await sleep(20);
  }
  if (!isProcessGroupAlive(processGroupId)) return;
  signalChild(child, processGroupId, "SIGKILL");
  const killDeadline = Date.now() + 2_000;
  while (Date.now() < killDeadline && isProcessGroupAlive(processGroupId)) {
    await sleep(20);
  }
  if (isProcessGroupAlive(processGroupId)) {
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
    try {
      lock.recordChild(child.pid, processGroupId);
    } catch (error) {
      signalChild(child, processGroupId, "SIGTERM");
      child.once("close", () => reject(error));
      return;
    }

    let spawnError = null;
    const handlers = new Map();
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
      const handler = () => signalChild(child, processGroupId, signal);
      handlers.set(signal, handler);
      process.once(signal, handler);
    }
    const cleanupHandlers = () => {
      for (const [signal, handler] of handlers) process.off(signal, handler);
    };
    child.once("error", (error) => {
      spawnError = error;
      try {
        signalChild(child, processGroupId, "SIGTERM");
      } catch {
        // The original spawn error is authoritative.
      }
    });
    child.once("close", (code, signal) => {
      cleanupHandlers();
      void (async () => {
        await terminateRemainingProcessGroup(child, processGroupId);
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

function fsyncDirectory(path) {
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
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

function cleanupAbandonedGenerations() {
  for (const entry of readdirSync(rendererBuildRoot, { withFileTypes: true })) {
    if (!entry.name.startsWith(".renderer-generation-")) continue;
    const path = join(rendererBuildRoot, entry.name);
    if (entry.isDirectory() && !entry.isSymbolicLink()) {
      removeTreeNoFollow(path);
    } else {
      unlinkSync(path);
    }
  }
}

function publishRendererGeneration(generationDir, rendererDir) {
  const existing = lstatOrNull(publishedRenderer);
  let backupPath = null;
  if (existing) {
    assertOwnedDirectory(existing, "published Renderer");
    backupPath = join(rendererBuildRoot, `.renderer-backup-${randomUUID()}`);
    renameSync(publishedRenderer, backupPath);
  }
  let newRendererPublished = false;
  try {
    renameSync(rendererDir, publishedRenderer);
    newRendererPublished = true;
    fsyncDirectory(rendererBuildRoot);
  } catch (error) {
    if (newRendererPublished) {
      renameSync(publishedRenderer, rendererDir);
    }
    if (backupPath) renameSync(backupPath, publishedRenderer);
    fsyncDirectory(rendererBuildRoot);
    throw error;
  }
  if (backupPath) removeTreeNoFollow(backupPath);
  rmdirSync(generationDir);
  fsyncDirectory(rendererBuildRoot);
}

async function buildAndPublish(lock) {
  prepareBuildRoot();
  cleanupAbandonedGenerations();
  const token = randomUUID();
  const generationDir = join(rendererBuildRoot, `.renderer-generation-${token}`);
  const rendererDir = join(generationDir, "Renderer");
  mkdirSync(generationDir, { mode: 0o700 });
  try {
    const testBuilder = process.env.SEER_RENDERER_BUILD_TEST_BUILDER;
    if (testBuilder) {
      await run(lock, process.execPath, [testBuilder, rendererDir]);
    } else {
      await run(
        lock,
        join(repoRoot, "node_modules", ".bin", "vite"),
        ["build", "--config", "vite.standalone.config.ts", "--outDir", rendererDir],
        { env: { ...process.env, SEER_RENDERER_PRIVATE_OUT_DIR: rendererDir } },
      );
    }
    const rendererInfo = lstatSync(rendererDir);
    assertOwnedDirectory(rendererInfo, "private renderer generation");
    const manifestPath = join(rendererDir, "build-manifest.json");
    const manifest = buildRendererBuildManifest(repoRoot, rendererDir);
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
    fsyncDirectory(rendererDir);
    publishRendererGeneration(generationDir, rendererDir);
  } catch (error) {
    if (lstatOrNull(generationDir)) removeTreeNoFollow(generationDir);
    throw error;
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
  } finally {
    trace("end", lock.token);
    lock.release();
  }
}

main().catch((error) => {
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
});
