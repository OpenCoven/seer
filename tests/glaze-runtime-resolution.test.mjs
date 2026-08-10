import assert from "node:assert/strict";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));

test("the app provides the Glaze component runtime dependency", async () => {
  const packageJson = JSON.parse(
    await readFile(join(projectRoot, "package.json"), "utf8"),
  );

  assert.equal(packageJson.dependencies.sonner, "^2.0.7");
});

test("the Glaze wrapper makes SDK imports resolvable by spawned Node processes", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "seer-glaze-resolution-"));
  const appRoot = join(tempRoot, "app");
  const coreRoot = join(tempRoot, "sdk", "@glaze", "core");

  try {
    await mkdir(join(coreRoot, "cli"), { recursive: true });
    await mkdir(appRoot, { recursive: true });
    await copyFile(join(projectRoot, "glaze.ts"), join(appRoot, "glaze.ts"));
    await writeFile(
      join(coreRoot, "package.json"),
      JSON.stringify({
        name: "@glaze/core",
        type: "module",
        exports: { "./backend": "./backend.js" },
      }),
    );
    await writeFile(join(coreRoot, "backend.js"), "export const ready = true;\n");
    await writeFile(join(coreRoot, "cli", "glaze.js"), "");

    const wrapper = spawnSync(process.execPath, ["glaze.ts", "help"], {
      cwd: appRoot,
      env: { ...process.env, GLAZE_CORE_PATH: coreRoot },
      encoding: "utf8",
    });
    assert.equal(wrapper.status, 0, wrapper.stderr);

    const child = spawnSync(
      process.execPath,
      [
        "--input-type=module",
        "--eval",
        "await import('@glaze/core/backend')",
      ],
      { cwd: appRoot, encoding: "utf8" },
    );

    assert.equal(child.status, 0, child.stderr);
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }
});
