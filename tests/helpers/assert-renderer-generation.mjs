import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { computeRendererAssetDigest } from "../../scripts/renderer-build-identity.mjs";

const repoRoot =
  process.env.SEER_RENDERER_BUILD_TEST_CONSUMER_ROOT ??
  dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const rendererRoot = join(repoRoot, "build", "standalone-renderer", "Renderer");
const expectedMarker = process.argv[2];
const holdMs = Number(process.argv[3] ?? "300");

for (let elapsed = 0; elapsed <= holdMs; elapsed += 20) {
  assert.equal(readFileSync(join(rendererRoot, "generation-marker.txt"), "utf8"), `${expectedMarker}\n`);
  const manifest = JSON.parse(readFileSync(join(rendererRoot, "build-manifest.json"), "utf8"));
  assert.equal(manifest.assetDigest, computeRendererAssetDigest(rendererRoot));
  await new Promise((resolve) => setTimeout(resolve, 20));
}
