// Spawned as a real, independent OS process by
// tests/renderer-asset-digest-helper-lock.test.mjs to prove the
// digest-helper lock still serializes true cross-process contention (not
// just contention simulated in-process). Acquires the lock, holds it for
// a short, deliberate pause (long enough that overlapping critical
// sections would be observable), records its held interval, then
// releases cleanly.
import { appendFileSync } from "node:fs";

import {
  acquireRendererAssetDigestHelperLock,
  releaseRendererAssetDigestHelperLock,
} from "../../scripts/renderer-build-identity.mjs";

const [, , lockDirPath, logPath] = process.argv;
if (!lockDirPath || !logPath) {
  throw new Error("expected lockDirPath and logPath arguments");
}

const lock = acquireRendererAssetDigestHelperLock(lockDirPath, {
  deadlineMs: 20_000,
  initGraceMs: 200,
});
const start = Date.now();
Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 40);
const end = Date.now();
appendFileSync(logPath, `${start} ${end}\n`);
releaseRendererAssetDigestHelperLock(lock);
