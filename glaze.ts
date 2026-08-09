#!/usr/bin/env node

/**
 * Thin wrapper that resolves the glaze CLI from the Glaze SDK.
 * Uses explicit SDK paths so `npm run build` etc. work without
 * relying on PATH.
 */

import {
  existsSync,
  lstatSync,
  mkdirSync,
  readlinkSync,
  symlinkSync,
  unlinkSync,
} from "node:fs";
import { homedir } from "node:os";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const candidates = [
  ...(process.env.GLAZE_CORE_PATH
    ? [resolve(process.env.GLAZE_CORE_PATH)]
    : []),
  resolve(__dirname, "../glaze-core"),
  join(
    homedir(),
    "Library/Application Support/app.glaze.macos.main/sdk/current/@glaze/core",
  ),
];

const core = candidates.find((candidate) =>
  existsSync(join(candidate, "cli/glaze.js")),
);
if (!core) {
  console.error("[glaze] @glaze/core CLI not found. Searched:");
  candidates.forEach((candidate) =>
    console.error(`  - ${join(candidate, "cli/glaze.js")}`),
  );
  process.exit(1);
}

function ensureCoreLink(linkPath: string, corePath: string) {
  let linkStat;
  try {
    linkStat = lstatSync(linkPath);
  } catch (error) {
    const isMissingPath =
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      error.code === "ENOENT";
    if (!isMissingPath) {
      console.error(`[glaze] Unable to inspect ${linkPath}:`, error);
      process.exit(1);
    }
  }

  try {
    if (linkStat?.isSymbolicLink()) {
      const currentTarget = resolve(dirname(linkPath), readlinkSync(linkPath));
      if (currentTarget !== corePath) {
        unlinkSync(linkPath);
        symlinkSync(corePath, linkPath, "dir");
      }
    } else if (linkStat) {
      console.error(
        `[glaze] Cannot link SDK: ${linkPath} exists and is not a symlink.`,
      );
      process.exit(1);
    } else {
      symlinkSync(corePath, linkPath, "dir");
    }
  } catch (error) {
    console.error(`[glaze] Unable to link ${linkPath} -> ${corePath}:`, error);
    process.exit(1);
  }
}

const localCore = resolve(__dirname, ".glaze-core");
ensureCoreLink(localCore, core);

const runtimeCore = resolve(__dirname, "node_modules/@glaze/core");
mkdirSync(dirname(runtimeCore), { recursive: true });
ensureCoreLink(runtimeCore, core);

await import(join(localCore, "cli/glaze.js"));
