#!/usr/bin/env node

import {
  lstatSync,
  readlinkSync,
  readdirSync,
} from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  checkEntitlements,
  checkInfoPlist,
  REPO_ROOT,
  scanBundle,
  scanSourceBoundary,
} from "./check-standalone-boundary.mjs";

const SOURCE_ENTITLEMENTS_PATH = join(
  REPO_ROOT,
  "apps",
  "macos",
  "Seer",
  "Config",
  "Seer.entitlements",
);

function lstatOrNull(path) {
  try {
    return lstatSync(path);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

export function validateDmgLayout(rootPath) {
  const offenders = [];
  const rootInfo = lstatOrNull(rootPath);
  if (!rootInfo || rootInfo.isSymbolicLink() || !rootInfo.isDirectory()) {
    return ["DMG root must be a real directory"];
  }

  const names = readdirSync(rootPath).sort();
  for (const name of names) {
    if (name !== "Seer.app" && name !== "Applications") {
      offenders.push(`unexpected DMG root entry: ${name}`);
    }
  }

  const appInfo = lstatOrNull(join(rootPath, "Seer.app"));
  if (!appInfo || appInfo.isSymbolicLink() || !appInfo.isDirectory()) {
    offenders.push("DMG Seer.app must be a real directory");
  }

  const applicationsPath = join(rootPath, "Applications");
  const applicationsInfo = lstatOrNull(applicationsPath);
  if (applicationsInfo) {
    if (!applicationsInfo.isSymbolicLink()) {
      offenders.push("DMG Applications entry must be a symlink");
    } else if (readlinkSync(applicationsPath) !== "/Applications") {
      offenders.push("DMG Applications symlink must target /Applications");
    }
  }
  return offenders;
}

export function checkReleaseApp(appPath, { forbiddenAbsolutePaths = [] } = {}) {
  return [
    ...scanSourceBoundary(REPO_ROOT),
    ...scanBundle(appPath, { forbiddenAbsolutePaths }),
    ...checkInfoPlist(appPath),
    ...checkEntitlements(appPath, {
      sourceEntitlementsPath: SOURCE_ENTITLEMENTS_PATH,
    }),
  ];
}

function parseArguments(args) {
  let appPath;
  let dmgRoot;
  const forbiddenAbsolutePaths = [];

  for (let index = 0; index < args.length; index += 2) {
    const option = args[index];
    const value = args[index + 1];
    if (value === undefined) {
      throw new Error(`missing value for ${option}`);
    }
    if (option === "--app" && appPath === undefined) {
      appPath = value;
    } else if (option === "--dmg-root" && dmgRoot === undefined) {
      dmgRoot = value;
    } else if (option === "--forbid-path") {
      forbiddenAbsolutePaths.push(value);
    } else {
      throw new Error(`unknown or duplicate argument ${JSON.stringify(option)}`);
    }
  }

  if ((appPath === undefined) === (dmgRoot === undefined)) {
    throw new Error("provide exactly one of --app or --dmg-root");
  }
  return { appPath, dmgRoot, forbiddenAbsolutePaths };
}

function main() {
  try {
    const { appPath, dmgRoot, forbiddenAbsolutePaths } = parseArguments(process.argv.slice(2));
    const offenders = [];
    const checkedAppPath = dmgRoot ? join(dmgRoot, "Seer.app") : appPath;
    if (dmgRoot) offenders.push(...validateDmgLayout(dmgRoot));
    if (!dmgRoot || offenders.length === 0) {
      offenders.push(...checkReleaseApp(checkedAppPath, { forbiddenAbsolutePaths }));
    }

    if (offenders.length > 0) {
      console.error(`release boundary check failed with ${offenders.length} offender(s):`);
      for (const offender of offenders) console.error(`  - ${offender}`);
      process.exitCode = 1;
      return;
    }
    console.log(`release boundary check passed for ${checkedAppPath}`);
  } catch (error) {
    console.error(`error: ${error.message}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main();
}
