// Spawned as a real, independent OS process by
// tests/renderer-asset-digest-private-helper.test.mjs to prove that
// `ensurePrivateDirectory` is safe when many processes race the very first
// creation of a shared private root that does not yet exist anywhere on
// disk - the classic "cold start" EEXIST race between one process's
// `mkdirSync` check and another's. Mirrors exactly what
// `withPrivateRendererAssetDigestHelper` does against the fixed production
// root (see renderer-asset-digest-run-dir-worker.mjs), except the root
// itself is supplied by the test via argv so a brand-new, never-yet-created
// scratch root can be raced on every test run.
import process from "node:process";

import {
  createPrivateRendererAssetDigestRunDir,
  ensurePrivateDirectory,
  removePrivateRendererAssetDigestRunDirIfSafe,
} from "../../scripts/renderer-build-identity.mjs";

const root = process.argv[2];
if (!root) {
  throw new Error("usage: renderer-asset-digest-cold-start-root-worker.mjs <root>");
}

ensurePrivateDirectory(root, "test private runs root");
const runDir = createPrivateRendererAssetDigestRunDir(root);
removePrivateRendererAssetDigestRunDirIfSafe(runDir);
process.stdout.write(`${runDir.path}\n`);
