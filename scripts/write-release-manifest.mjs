#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  lstatSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";

const BUNDLE_IDENTIFIER = "ai.opencoven.seer";
const STABLE_VERSION_PATTERN = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const SOURCE_COMMIT_PATTERN = /^[0-9a-f]{40}$/;
const WORKFLOW_RUN_PATTERN = /^[1-9][0-9]*$/;

function validateInputs({ version, sourceCommit, workflowRun, dmgPath, notarization }) {
  if (typeof version !== "string" || !STABLE_VERSION_PATTERN.test(version)) {
    throw new Error("version must be a stable semantic version in X.Y.Z form");
  }
  if (typeof sourceCommit !== "string" || !SOURCE_COMMIT_PATTERN.test(sourceCommit)) {
    throw new Error("source commit must be a lowercase 40-character SHA");
  }
  if (typeof workflowRun !== "string" || !WORKFLOW_RUN_PATTERN.test(workflowRun)) {
    throw new Error("workflow run must be a positive decimal identifier without leading zeros");
  }
  if (notarization !== "accepted") {
    throw new Error("notarization must be exactly accepted");
  }
  if (typeof dmgPath !== "string") {
    throw new Error("artifact path is required");
  }

  const expectedName = `Seer-v${version}-arm64.dmg`;
  if (basename(dmgPath) !== expectedName) {
    throw new Error(`artifact must be named exactly ${expectedName}`);
  }

  let artifactInfo;
  try {
    artifactInfo = lstatSync(dmgPath);
  } catch (error) {
    throw new Error(`unable to inspect artifact: ${error.message}`);
  }
  if (artifactInfo.isSymbolicLink() || !artifactInfo.isFile()) {
    throw new Error("artifact must be a regular file and not a symlink");
  }
}

export function buildManifest(input) {
  validateInputs(input);
  const bytes = readFileSync(input.dmgPath);
  return {
    artifacts: [
      {
        name: basename(input.dmgPath),
        sha256: createHash("sha256").update(bytes).digest("hex"),
        size: bytes.length,
      },
    ],
    bundleIdentifier: BUNDLE_IDENTIFIER,
    notarization: "accepted",
    sourceCommit: input.sourceCommit,
    version: input.version,
    workflowRun: input.workflowRun,
  };
}

export function serializeManifest(manifest) {
  return `${JSON.stringify(manifest, null, 2)}\n`;
}

export function formatChecksum(artifact) {
  return `${artifact.sha256}  ${artifact.name}\n`;
}

export function writeReleaseMetadata({
  manifestPath,
  checksumsPath,
  ...manifestInput
}) {
  if (typeof manifestPath !== "string" || typeof checksumsPath !== "string") {
    throw new Error("manifest and checksums output paths are required");
  }
  const manifest = buildManifest(manifestInput);
  writeFileSync(manifestPath, serializeManifest(manifest), {
    encoding: "utf8",
    flag: "wx",
    mode: 0o644,
  });
  writeFileSync(checksumsPath, formatChecksum(manifest.artifacts[0]), {
    encoding: "utf8",
    flag: "wx",
    mode: 0o644,
  });
  return manifest;
}

const CLI_OPTIONS = new Map([
  ["--version", "version"],
  ["--source-commit", "sourceCommit"],
  ["--workflow-run", "workflowRun"],
  ["--notarization", "notarization"],
  ["--artifact", "dmgPath"],
  ["--manifest", "manifestPath"],
  ["--checksums", "checksumsPath"],
]);

function parseArguments(args) {
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const option = args[index];
    const value = args[index + 1];
    const key = CLI_OPTIONS.get(option);
    if (!key) {
      throw new Error(`unknown argument ${JSON.stringify(option)}`);
    }
    if (value === undefined) {
      throw new Error(`missing value for ${option}`);
    }
    if (Object.hasOwn(parsed, key)) {
      throw new Error(`duplicate argument ${option}`);
    }
    parsed[key] = value;
  }

  for (const [option, key] of CLI_OPTIONS) {
    if (!Object.hasOwn(parsed, key)) {
      throw new Error(`missing required argument ${option}`);
    }
  }
  return parsed;
}

function main() {
  try {
    writeReleaseMetadata(parseArguments(process.argv.slice(2)));
  } catch (error) {
    console.error(`error: ${error.message}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main();
}
