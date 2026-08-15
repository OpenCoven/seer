#!/usr/bin/env node
import { spawn } from "node:child_process";
import {
  appendFileSync,
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmdirSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { randomUUID } from "node:crypto";
import { dirname, join } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const lockDir = join(repoRoot, ".seer-standalone-renderer.lock");
const ownerPath = join(lockDir, "owner.json");

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

function readOwnerNoFollow() {
  const before = lstatSync(ownerPath);
  if (before.isSymbolicLink() || !before.isFile()) {
    throw new Error("renderer lock owner metadata must be a regular non-symlink file");
  }
  const descriptor = openSync(ownerPath, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const after = fstatSync(descriptor);
    if (!after.isFile() || !sameIdentity(before, after)) {
      throw new Error("renderer lock owner metadata changed identity while being opened");
    }
    return {
      info: after,
      owner: JSON.parse(readFileSync(descriptor, "utf8")),
    };
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

function removeVerifiedLock(expectedDirectory, expectedOwnerInfo = null) {
  const currentDirectory = lstatSync(lockDir);
  assertOwnedDirectory(currentDirectory, "renderer lock");
  if (!sameIdentity(expectedDirectory, currentDirectory)) {
    throw new Error("renderer lock changed identity before cleanup");
  }

  if (expectedOwnerInfo) {
    const currentOwner = lstatSync(ownerPath);
    if (currentOwner.isSymbolicLink() || !currentOwner.isFile() || !sameIdentity(expectedOwnerInfo, currentOwner)) {
      throw new Error("renderer lock owner changed identity before cleanup");
    }
    unlinkSync(ownerPath);
  } else if (readdirSync(lockDir).length !== 0) {
    throw new Error("ownerless stale renderer lock is not empty; refusing recursive cleanup");
  }
  rmdirSync(lockDir);
}

function inspectAndMaybeRemoveStaleLock() {
  const directoryInfo = lstatSync(lockDir);
  assertOwnedDirectory(directoryInfo, "renderer lock");

  let ownerRecord;
  try {
    ownerRecord = readOwnerNoFollow();
  } catch (error) {
    if (error.code === "ENOENT") {
      if (Date.now() - directoryInfo.mtimeMs >= staleMs) {
        removeVerifiedLock(directoryInfo);
        return true;
      }
      return false;
    }
    if (Date.now() - directoryInfo.mtimeMs < staleMs) {
      return false;
    }
    const ownerInfo = lstatSync(ownerPath);
    if (ownerInfo.isSymbolicLink() || !ownerInfo.isFile()) {
      throw error;
    }
    removeVerifiedLock(directoryInfo, ownerInfo);
    return true;
  }

  const { owner, info: ownerInfo } = ownerRecord;
  if (
    typeof owner.token !== "string" ||
    !Number.isSafeInteger(owner.pid) ||
    !Number.isSafeInteger(owner.createdAtMs)
  ) {
    if (Date.now() - directoryInfo.mtimeMs >= staleMs) {
      removeVerifiedLock(directoryInfo, ownerInfo);
      return true;
    }
    return false;
  }
  if (isPidAlive(owner.pid)) return false;
  if (Date.now() - owner.createdAtMs < staleMs) return false;

  const reread = readOwnerNoFollow();
  if (!sameIdentity(ownerInfo, reread.info) || JSON.stringify(owner) !== JSON.stringify(reread.owner)) {
    throw new Error("renderer lock owner changed while stale ownership was verified");
  }
  removeVerifiedLock(directoryInfo, ownerInfo);
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
          // The original ownership error is more useful; no recursive cleanup is attempted.
        }
        throw error;
      }

      const { owner: recordedOwner, info: ownerInfo } = readOwnerNoFollow();
      if (recordedOwner.token !== token || recordedOwner.pid !== process.pid) {
        throw new Error("renderer lock ownership could not be verified after acquisition");
      }

      return {
        token,
        release() {
          const current = readOwnerNoFollow();
          if (current.owner.token !== token || current.owner.pid !== process.pid) {
            throw new Error("refusing to release a renderer lock owned by another process");
          }
          removeVerifiedLock(directoryInfo, ownerInfo);
        },
      };
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
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
  appendFileSync(tracePath, `${JSON.stringify({ event, token, pid: process.pid })}\n`, {
    encoding: "utf8",
    flag: "a",
  });
}

async function run(command, args) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: repoRoot,
      env: process.env,
      stdio: "inherit",
    });
    const handlers = new Map();
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
      const handler = () => child.kill(signal);
      handlers.set(signal, handler);
      process.once(signal, handler);
    }
    const cleanupHandlers = () => {
      for (const [signal, handler] of handlers) {
        process.off(signal, handler);
      }
    };
    child.once("error", (error) => {
      cleanupHandlers();
      reject(error);
    });
    child.once("exit", (code, signal) => {
      cleanupHandlers();
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`${command} exited ${signal ? `on ${signal}` : `with status ${code}`}`));
      }
    });
  });
}

async function main() {
  const lock = await acquireLock();
  trace("start", lock.token);
  try {
    const holdMs = positiveIntegerFromEnv("SEER_RENDERER_BUILD_TEST_HOLD_MS", 0);
    if (holdMs > 0) await sleep(holdMs);

    await run(join(repoRoot, "node_modules", ".bin", "vite"), [
      "build",
      "--config",
      "vite.standalone.config.ts",
    ]);
    await run(process.execPath, [
      join(repoRoot, "scripts", "renderer-build-identity.mjs"),
      repoRoot,
      join(repoRoot, "build", "standalone-renderer", "Renderer", "build-manifest.json"),
    ]);
  } finally {
    trace("end", lock.token);
    lock.release();
  }
}

main().catch((error) => {
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
});
