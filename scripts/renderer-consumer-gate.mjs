#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import process from "node:process";

const [, , command, ...args] = process.argv;
if (!command) throw new Error("renderer consumer gate requires a command");

const gateFD = Number(process.env.SEER_RENDERER_CONSUMER_GATE_FD);
if (!Number.isSafeInteger(gateFD) || gateFD < 3) {
  throw new Error("SEER_RENDERER_CONSUMER_GATE_FD must identify the inherited gate pipe");
}
const timeoutMs = Number(process.env.SEER_RENDERER_CONSUMER_GATE_TIMEOUT_MS ?? "30000");
if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 60_000) {
  throw new Error("renderer consumer gate timeout must be between 1 and 60000ms");
}

const gate = createReadStream("", { fd: gateFD, autoClose: true });
const released = await new Promise((resolve) => {
  let settled = false;
  const finish = (value) => {
    if (settled) return;
    settled = true;
    clearTimeout(timeout);
    gate.destroy();
    resolve(value);
  };
  const timeout = setTimeout(() => finish(false), timeoutMs);
  timeout.unref?.();
  gate.on("data", (chunk) => {
    if (chunk.includes(0x47)) finish(true);
  });
  gate.once("end", () => finish(false));
  gate.once("error", () => finish(false));
});

if (!released) {
  process.exitCode = 75;
} else {
  const child = spawn(command, args, {
    env: process.env,
    stdio: "inherit",
  });
  if (process.platform === "win32") {
    for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
      process.on(signal, () => child.kill(signal));
    }
  }
  const result = await new Promise((resolve) => {
    let spawnError = null;
    child.once("error", (error) => {
      spawnError = error;
    });
    child.once("close", (code, signal) => resolve({ code, signal, spawnError }));
  });
  if (result.spawnError) throw result.spawnError;
  if (result.signal) {
    process.kill(process.pid, result.signal);
  } else {
    process.exitCode = result.code ?? 1;
  }
}
