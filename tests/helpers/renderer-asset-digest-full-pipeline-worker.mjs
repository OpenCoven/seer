// Spawned as a real, independent OS process by
// tests/renderer-asset-digest-private-helper.test.mjs to prove that several
// truly concurrent, real end-to-end `computeRendererAssetDigest` calls
// (each compiling, validating, spawning, revalidating, and cleaning up its
// own private Swift helper instance) against the exact same renderer root
// all succeed and agree on the exact same digest.
import process from "node:process";

import { computeRendererAssetDigest } from "../../scripts/renderer-build-identity.mjs";

const [, , rendererRoot] = process.argv;
if (!rendererRoot) {
  throw new Error("expected a rendererRoot argument");
}
process.stdout.write(`${computeRendererAssetDigest(rendererRoot)}\n`);
