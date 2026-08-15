import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

function runRendererBuild(tracePath) {
  return new Promise((resolve, reject) => {
    const child = spawn("npm", ["run", "build:standalone-renderer"], {
      cwd: repoRoot,
      env: {
        ...process.env,
        SEER_RENDERER_BUILD_TEST_HOLD_MS: "250",
        SEER_RENDERER_BUILD_TEST_TRACE: tracePath,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`renderer build exited ${code}\nstdout:\n${stdout}\nstderr:\n${stderr}`));
      }
    });
  });
}

test("the package renderer build wrapper serializes concurrent emptyOutDir builds", async () => {
  const packageJson = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8"));
  assert.match(
    packageJson.scripts["build:standalone-renderer"],
    /scripts\/build-standalone-renderer\.mjs/,
    "the package script must own the global renderer-build lock",
  );

  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-lock-test-"));
  const tracePath = join(scratch, "critical-sections.jsonl");

  try {
    await Promise.all([runRendererBuild(tracePath), runRendererBuild(tracePath)]);

    const events = readFileSync(tracePath, "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    assert.equal(events.length, 4, `expected two start/end pairs, got ${JSON.stringify(events)}`);

    const active = new Set();
    for (const event of events) {
      if (event.event === "start") {
        assert.equal(active.size, 0, `renderer critical sections overlapped: ${JSON.stringify(events)}`);
        active.add(event.token);
      } else {
        assert.equal(event.event, "end");
        assert.equal(active.delete(event.token), true, "end event must match the active lock owner");
      }
    }
    assert.equal(active.size, 0);

    assert.ok(statSync(join(repoRoot, "build", "standalone-renderer", "Renderer", "standalone-window.html")).isFile());
    assert.ok(statSync(join(repoRoot, "build", "standalone-renderer", "Renderer", "build-manifest.json")).isFile());
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
