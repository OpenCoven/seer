// Spawned as a real, independent OS process by
// tests/renderer-asset-digest-publish.test.mjs to prove that many
// concurrent publishers racing to publish *different* content to the same
// canonical path resolve to exactly one winner, with every participant -
// winner and losers alike - independently reading back the exact same
// published content afterward.
//
// Writes its own uniquely named, same-directory staging file (mirroring
// exactly how `compiledRendererAssetDigestHelper()` names its own staging
// path: pid *and* random bytes, never a predictable name), publishes it via
// the real production primitive, and reports what actually ended up
// published as a single line of JSON on stdout. Never sleeps - the race is
// driven entirely by real OS process scheduling, not by any timing
// assumption.
import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import process from "node:process";

import { publishRendererAssetDigestHelperCandidate } from "../../scripts/renderer-build-identity.mjs";

const [, , canonicalPath, workerLabel] = process.argv;
if (!canonicalPath || !workerLabel) {
  throw new Error("expected canonicalPath and workerLabel arguments");
}

const ownContent = `worker-${workerLabel}-${process.pid}-${randomBytes(4).toString("hex")}`;
const stagingPath = join(
  dirname(canonicalPath),
  `.worker-staging-${process.pid}-${randomBytes(8).toString("hex")}`,
);
writeFileSync(stagingPath, ownContent);
chmodSync(stagingPath, 0o755);

publishRendererAssetDigestHelperCandidate(stagingPath, canonicalPath);

process.stdout.write(
  `${JSON.stringify({
    workerLabel,
    ownContent,
    resolvedContent: readFileSync(canonicalPath, "utf8"),
    stagingRemains: existsSync(stagingPath),
  })}\n`,
);
