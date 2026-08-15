import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const workflowPath = join(repoRoot, ".github", "workflows", "release-macos.yml");
const source = existsSync(workflowPath) ? readFileSync(workflowPath, "utf8") : "";

function jobBlock(name, nextName) {
  const start = source.indexOf(`  ${name}:\n`);
  if (start === -1) return "";
  const end = nextName ? source.indexOf(`  ${nextName}:\n`, start + 1) : source.length;
  return source.slice(start, end === -1 ? source.length : end);
}

function stepBlocks(job) {
  const starts = [...job.matchAll(/^      - name: /gm)].map(({ index }) => index);
  return starts.map((start, index) => job.slice(start, starts[index + 1] ?? job.length));
}

test("release workflow exists and has only the protected tag trigger and minimal permissions", () => {
  assert.ok(existsSync(workflowPath), ".github/workflows/release-macos.yml must exist");
  assert.match(source, /^on:\n  push:\n    tags:\n      - "v\*\.\*\.\*"\n\npermissions:\n  contents: read\n  id-token: write$/m);
  assert.doesNotMatch(source, /\b(?:pull_request|workflow_dispatch|schedule):/);
  assert.deepEqual(
    [...source.matchAll(/^  ([a-z][a-z0-9-]*):\n    (?:name|needs|runs-on):/gm)].map((match) => match[1]),
    ["prepare", "sign-and-release"],
  );
});

test("every external action is pinned to the resolved immutable SHA", () => {
  const expectedPins = new Map([
    ["actions/checkout", "11d5960a326750d5838078e36cf38b85af677262"],
    ["actions/setup-node", "49933ea5288caeca8642d1e84afbd3f7d6820020"],
    ["maxim-lobanov/setup-xcode", "ed7a3b1fda3918c0306d1b724322adc0b8cc0a90"],
    ["actions/upload-artifact", "ea165f8d65b6e75b540449e92b4886f43607fa02"],
    ["actions/download-artifact", "d3f86a106a0bac45b974a628896c90dbdf5c8093"],
  ]);
  const uses = [...source.matchAll(/^\s*uses:\s+([^@\s]+)@([^\s#]+)\s*$/gm)];

  assert.ok(uses.length >= expectedPins.size);
  for (const [, action, ref] of uses) {
    assert.match(ref, /^[0-9a-f]{40}$/, `${action} must use a lowercase commit SHA`);
    assert.equal(ref, expectedPins.get(action), `${action} pin differs from its resolved major ref`);
  }
  for (const action of expectedPins.keys()) {
    assert.ok(uses.some(([, usedAction]) => usedAction === action), `${action} must be used`);
  }
});

test("prepare is credential-free, runs the complete standalone gate, and uploads only attested input", () => {
  const prepare = jobBlock("prepare", "sign-and-release");

  assert.match(prepare, /runs-on: macos-14-xlarge/);
  assert.doesNotMatch(prepare, /\benvironment:|\$\{\{\s*secrets\./);
  assert.match(prepare, /\^v\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$/);
  assert.match(prepare, /SOURCE_REPOSITORY_PRIVATE/);
  assert.match(prepare, /uname -m/);
  assert.match(prepare, /github\.run_number/);
  assert.match(prepare, /MARKETING_VERSION/);
  assert.match(prepare, /ref: \$\{\{ github\.sha \}\}/);
  assert.match(prepare, /persist-credentials: false/);
  assert.match(prepare, /xcode-version: "16\.2"/);
  assert.match(prepare, /node-version: "24"/);
  for (const command of [
    "brew install xcodegen",
    "xcodebuild -version",
    "xcodegen --version",
    "node --version",
    "npm --version",
    "npm ci",
    "tests/package-macos-release.test.mjs",
    "tests/release-macos-workflow.test.mjs",
    "npm run test:renderer",
    "npm run type-check:standalone",
    "npm run lint:standalone",
    "npm run build:standalone-renderer",
    "npm run generate:macos",
    "npm run test:macos",
    "npm run build:macos",
    "tests/standalone-boundary.test.mjs",
    "npm run check:standalone-boundary",
    "scripts/prepare-macos-release-input.sh",
  ]) {
    assert.ok(prepare.includes(command), `prepare must run ${command}`);
  }
  assert.match(prepare, /PREPARE_RUNNER_ID: gha:\$\{\{ github\.run_id \}\}:\$\{\{ github\.run_attempt \}\}:prepare/);
  assert.match(prepare, /prepare-runner-id: \$\{\{ steps\.release-input\.outputs\.prepare-runner-id \}\}/);
  assert.match(prepare, /unsigned-archive-sha256: \$\{\{ steps\.release-input\.outputs\.unsigned-archive-sha256 \}\}/);
  assert.match(
    prepare,
    /unsigned-attestation-sha256: \$\{\{ steps\.release-input\.outputs\.unsigned-attestation-sha256 \}\}/,
  );
  assert.match(prepare, /artifact-id: \$\{\{ steps\.upload-release-input\.outputs\.artifact-id \}\}/);
  assert.match(
    prepare,
    /path: \|\n\s+build\/macos\/release-input\/Seer-unsigned-arm64\.tar\n\s+build\/macos\/release-input\/unsigned-app-attestation\.json/,
  );
  assert.equal((prepare.match(/actions\/upload-artifact@/g) ?? []).length, 1);
  assert.doesNotMatch(prepare, /build\/macos\/release-input\/\*|gh release|\bAPPLE_/);
});

test("signing uses a protected fresh job and rejects gates and identity mismatches before secrets", () => {
  const signing = jobBlock("sign-and-release");
  const firstSecret = signing.indexOf("${{ secrets.");

  assert.match(signing, /needs: prepare/);
  assert.match(signing, /runs-on: macos-14-xlarge/);
  assert.match(signing, /environment: macos-release/);
  assert.match(signing, /BINARY_DISTRIBUTION_APPROVED: \$\{\{ vars\.BINARY_DISTRIBUTION_APPROVED \}\}/);
  assert.match(signing, /PARITY_MATRIX_APPROVED: \$\{\{ vars\.PARITY_MATRIX_APPROVED \}\}/);
  assert.match(signing, /CLEAN_MACHINE_VERIFIED_COMMIT: \$\{\{ vars\.CLEAN_MACHINE_VERIFIED_COMMIT \}\}/);
  assert.match(signing, /\^v\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$/);
  assert.match(signing, /\^\[0-9a-f\]\{40\}\$/);
  assert.match(signing, /CLEAN_MACHINE_VERIFIED_COMMIT.*GITHUB_SHA|GITHUB_SHA.*CLEAN_MACHINE_VERIFIED_COMMIT/s);
  assert.ok(firstSecret > signing.indexOf("CLEAN_MACHINE_VERIFIED_COMMIT"));
  assert.match(signing, /SIGNING_RUNNER_ID: gha:\$\{\{ github\.run_id \}\}:\$\{\{ github\.run_attempt \}\}:sign/);
  assert.match(signing, /plutil -extract prepareRunnerId raw/);
  assert.match(signing, /attested_prepare_runner_id.*SIGNING_RUNNER_ID|SIGNING_RUNNER_ID.*attested_prepare_runner_id/s);
  assert.match(signing, /artifact-ids: \$\{\{ needs\.prepare\.outputs\.artifact-id \}\}/);
  assert.match(signing, /unsigned-app archive SHA-256 mismatch/);
  assert.match(signing, /unsigned-app attestation SHA-256 mismatch/);
  assert.doesNotMatch(signing, /\bnpm (?:ci|install|run)\b|\bnpx\b|\bxcodegen\b|node_modules/);
  assert.equal((signing.match(/\bxcodebuild\b/g) ?? []).length, 1);
  assert.match(signing, /xcodebuild -version/);
});

test("signing passes only the Task 16 interface and scopes the releases token to release commands", () => {
  const prepare = jobBlock("prepare", "sign-and-release");
  const signing = jobBlock("sign-and-release");
  const signingSecrets = new Set(
    [...signing.matchAll(/\$\{\{\s*secrets\.([A-Z0-9_]+)\s*\}\}/g)].map((match) => match[1]),
  );
  const expectedSecrets = new Set([
    "APPLE_CERTIFICATE",
    "APPLE_CERTIFICATE_PASSWORD",
    "APPLE_SIGNING_IDENTITY",
    "APPLE_TEAM_ID",
    "APPLE_API_ISSUER",
    "APPLE_API_KEY",
    "APPLE_API_KEY_BASE64",
    "APPLE_ID",
    "APPLE_PASSWORD",
    "RELEASES_REPO_TOKEN",
  ]);

  assert.deepEqual(signingSecrets, expectedSecrets);
  assert.doesNotMatch(prepare, /RELEASES_REPO_TOKEN/);
  assert.match(signing, /run: bash scripts\/package-macos-release\.sh/);

  const steps = stepBlocks(signing);
  for (const step of steps) {
    const hasToken = step.includes("secrets.RELEASES_REPO_TOKEN");
    const hasGhCommand = /\bgh (?:api|release)\b/.test(step);
    assert.equal(hasToken, hasGhCommand, "RELEASES_REPO_TOKEN and release-repository gh commands must share a step");
    if (hasToken) {
      assert.match(step, /GH_REPO: OpenCoven\/seer-releases/);
      assert.doesNotMatch(step, /secrets\.APPLE_/);
    }
  }
  assert.doesNotMatch(signing, /\bgh release delete\b|\bgh api\b[^\n]*-X DELETE/);
});

test("draft release contains only public outputs and is published only after downloaded-DMG verification", () => {
  const signing = jobBlock("sign-and-release");
  const create = signing.indexOf("gh release create");
  const upload = signing.indexOf("gh release upload");
  const download = signing.indexOf("gh release download");
  const scanner = signing.indexOf("node scripts/check-release-boundary.mjs", download);
  const publish = signing.indexOf("gh release edit");

  assert.match(signing, /expected=\("Seer-v\$\{VERSION\}-arm64\.dmg" "SHA256SUMS" "release-manifest\.json"\)/);
  assert.match(signing, /release-notes\.md/);
  assert.match(signing, /repos\/\$\{GH_REPO\}\/releases\/tags\/\$\{GITHUB_REF_NAME\}/);
  assert.match(signing, /repos\/\$\{GH_REPO\}\/git\/ref\/tags\/\$\{GITHUB_REF_NAME\}/);
  assert.match(signing, /gh release create "\$\{GITHUB_REF_NAME\}" --draft/);
  assert.match(
    signing,
    /gh release upload "\$\{GITHUB_REF_NAME\}" \\\n\s+"\$\{RELEASE_DIR\}\/Seer-v\$\{VERSION\}-arm64\.dmg" \\\n\s+"\$\{RELEASE_DIR\}\/SHA256SUMS" \\\n\s+"\$\{RELEASE_DIR\}\/release-manifest\.json"/,
  );
  assert.match(signing, /gh release download[\s\S]*--pattern "Seer-v\$\{VERSION\}-arm64\.dmg"[\s\S]*--pattern "SHA256SUMS"[\s\S]*--pattern "release-manifest\.json"/);
  assert.match(signing, /shasum -a 256 -c SHA256SUMS/);
  assert.match(signing, /trap cleanup EXIT/);
  assert.match(signing, /hdiutil attach[\s\S]*-readonly[\s\S]*-nobrowse[\s\S]*-noautoopen[\s\S]*-mountpoint/);
  assert.match(signing, /hdiutil detach/);
  assert.match(signing, /codesign --verify --deep --strict/);
  assert.match(signing, /spctl --assess --type execute/);
  assert.match(signing, /node scripts\/check-release-boundary\.mjs[\s\S]*--dmg-root/);
  assert.match(signing, /gh release edit "\$\{GITHUB_REF_NAME\}" --draft=false/);
  assert.doesNotMatch(signing, /--clobber/);
  assert.ok(create !== -1 && create < upload && upload < download && download < scanner && scanner < publish);
});
