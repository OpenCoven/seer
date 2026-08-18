// Spawned as a real, independent OS process by
// tests/renderer-asset-digest-private-helper.test.mjs to prove that many
// concurrent invocations against the exact same shared private runs root
// each get their own distinct, unique run directory and never interfere
// with one another.
//
// Deliberately uses a trivial `run` callback (just returns the run
// directory's own path) rather than a real Swift compile, so this can
// exercise dozens of truly concurrent OS processes cheaply and quickly -
// the run-directory creation/validation/cleanup bookkeeping is what is
// under test here, not the compiler.
import process from "node:process";

import { withPrivateRendererAssetDigestHelper } from "../../scripts/renderer-build-identity.mjs";

const runDirPath = withPrivateRendererAssetDigestHelper((path) => path);
process.stdout.write(`${runDirPath}\n`);
