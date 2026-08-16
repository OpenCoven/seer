import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const workflowPath = join(repoRoot, ".github", "workflows", "release-macos.yml");
const source = existsSync(workflowPath) ? readFileSync(workflowPath, "utf8") : "";
const draftPolicyPath = join(repoRoot, "scripts", "release-macos-draft.sh");
const draftPolicySource = existsSync(draftPolicyPath) ? readFileSync(draftPolicyPath, "utf8") : "";
const draftStateHelperPath = join(repoRoot, "scripts", "release-macos-draft-state.mjs");
const draftStateHelperSource = existsSync(draftStateHelperPath) ? readFileSync(draftStateHelperPath, "utf8") : "";
const draftPolicyImplementation = `${draftPolicySource}\n${draftStateHelperSource}`;

function jobBlock(name, nextName) {
  const start = source.indexOf(`  ${name}:\n`);
  if (start === -1) return "";
  const end = nextName ? source.indexOf(`  ${nextName}:\n`, start + 1) : source.length;
  return source.slice(start, end === -1 ? source.length : end);
}

function stepBlocks(job) {
  const starts = [...job.matchAll(/^ {6}- name: /gm)].map(({ index }) => index);
  return starts.map((start, index) => job.slice(start, starts[index + 1] ?? job.length));
}

test("release workflow exists and has only the protected tag trigger and scoped source-run read permission", () => {
  assert.ok(existsSync(workflowPath), ".github/workflows/release-macos.yml must exist");
  assert.match(source, /^on:\n {2}push:\n {4}tags:\n {6}- "v\*\.\*\.\*"\n\npermissions:\n {2}actions: read\n {2}contents: read\n {2}id-token: write$/m);
  assert.doesNotMatch(source, /\b(?:pull_request|workflow_dispatch|schedule):/);
  assert.match(
    source,
    /concurrency:\n {2}group: release-macos-OpenCoven-seer-releases-\$\{\{ github\.ref_name \}\}\n {2}cancel-in-progress: false/,
  );
  assert.deepEqual(
    [...source.matchAll(/^ {2}([a-z][a-z0-9-]*):\n {4}(?:name|needs|runs-on):/gm)].map((match) => match[1]),
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

test("prepare pins XcodeGen and runs the complete standalone gate without credentials", () => {
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
  assert.doesNotMatch(prepare, /\bbrew install xcodegen\b/);
  assert.match(prepare, /https:\/\/github\.com\/yonaskolb\/XcodeGen\/releases\/download\/2\.46\.0\/xcodegen\.zip/);
  assert.match(prepare, /4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806/);
  assert.match(prepare, /\/usr\/bin\/curl --fail --location --retry 3 --retry-all-errors --retry-delay 2/);
  assert.match(prepare, /\/usr\/bin\/shasum -a 256 -c -/);
  assert.match(prepare, /xcodegen_root="\$\{RUNNER_TEMP\}\/xcodegen-2\.46\.0"/);
  assert.match(prepare, /printf '%s\\n' "\$\{xcodegen_bin\}" >> "\$\{GITHUB_PATH\}"/);
  assert.match(prepare, /\[\[ "\$\("\$\{xcodegen_bin\}\/xcodegen" --version\)" == "Version: 2\.46\.0" \]\]/);
  for (const command of [
    "xcodebuild -version",
    "xcodegen --version",
    "node --version",
    "npm --version",
    "npm ci",
    "tests/package-macos-release.test.mjs",
    "tests/release-macos-draft-policy.test.mjs",
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
  assert.match(prepare, /artifact-name: \$\{\{ steps\.release-input\.outputs\.artifact-name \}\}/);
  assert.match(
    prepare,
    /ARTIFACT_NAME: seer-unsigned-release-input-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}/,
  );
  assert.match(prepare, /printf 'artifact-name=%s\\n' "\$\{ARTIFACT_NAME\}" >> "\$\{GITHUB_OUTPUT\}"/);
  assert.match(prepare, /name: \$\{\{ steps\.release-input\.outputs\.artifact-name \}\}/);
  assert.match(
    prepare,
    /path: \|\n\s+build\/macos\/release-input\/Seer-unsigned-arm64\.tar\n\s+build\/macos\/release-input\/unsigned-app-attestation\.json/,
  );
  assert.equal((prepare.match(/actions\/upload-artifact@/g) ?? []).length, 1);
  assert.doesNotMatch(prepare, /build\/macos\/release-input\/\*|gh release|\bAPPLE_/);
  assert.doesNotMatch(prepare, /artifact-id/);
  assert.match(prepare, /retention-days: 90/);
  assert.doesNotMatch(prepare, /retention-days: 1(?:\D|$)/);
});

test("prepared release input is downloaded by exact name into a flat root and checked for exactly two files before signing", () => {
  const signing = jobBlock("sign-and-release");
  const steps = stepBlocks(signing);
  const downloadStep = steps.find((step) => step.includes("actions/download-artifact@"));
  const verifyStep = steps.find((step) => step.includes("id: signing-input"));

  // download-artifact only extracts directly into `path` (no artifact-named
  // subdirectory) when it resolves a single artifact via `name:`. Passing
  // `artifact-ids:` instead — even with one ID — nests output one directory
  // deeper unless `merge-multiple: true` is also set, which would break the
  // flat `release-input/{archive,attestation}` paths used below and in the
  // prepare job's own local checks.
  assert.ok(downloadStep, "download-artifact step must exist in the signing job");
  assert.match(downloadStep, /name: \$\{\{ needs\.prepare\.outputs\.artifact-name \}\}/);
  assert.doesNotMatch(downloadStep, /^\s+artifact-ids:/m);
  assert.match(downloadStep, /path: build\/macos\/release-input/);

  assert.ok(verifyStep, "signing-input verification step must exist");
  assert.match(
    verifyStep,
    /entry_count="\$\(find "\$\{input_dir\}" -mindepth 1 -maxdepth 1 -print \| wc -l \| tr -d ' '\)"/,
  );
  assert.match(verifyStep, /\[\[ "\$\{entry_count\}" == "2" \]\]/);
  assert.match(verifyStep, /archive="\$\{input_dir\}\/Seer-unsigned-arm64\.tar"/);
  assert.match(verifyStep, /attestation="\$\{input_dir\}\/unsigned-app-attestation\.json"/);
  assert.match(verifyStep, /\[\[ -f "\$\{archive\}" && ! -L "\$\{archive\}" \]\]/);
  assert.match(verifyStep, /\[\[ -f "\$\{attestation\}" && ! -L "\$\{attestation\}" \]\]/);

  // The extras-rejecting entry-count check must run before any signing or
  // notarization step touches the downloaded input.
  const downloadIndex = signing.indexOf(downloadStep);
  const verifyIndex = signing.indexOf(verifyStep);
  const signIndex = signing.indexOf("Sign and notarize attested input");
  assert.ok(downloadIndex < verifyIndex && verifyIndex < signIndex);
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
  assert.match(signing, /name: \$\{\{ needs\.prepare\.outputs\.artifact-name \}\}/);
  assert.doesNotMatch(signing, /^\s+artifact-ids:|^\s+merge-multiple:/m);
  assert.match(signing, /unsigned-app archive SHA-256 mismatch/);
  assert.match(signing, /unsigned-app attestation SHA-256 mismatch/);
  assert.doesNotMatch(signing, /\bnpm (?:ci|install|run)\b|\bnpx\b|\bxcodegen\b|node_modules/);
  assert.equal((signing.match(/\bxcodebuild\b/g) ?? []).length, 1);
  assert.match(signing, /xcodebuild -version/);
});

test("signing keeps build tools out and scopes the releases token to release policy commands", () => {
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
    const hasReleasePolicy =
      /scripts\/release-macos-draft\.sh (?:acquire-lock|reconcile-published|preflight|upload|capture|publish|release-lock)/.test(
        step,
      );
    assert.equal(
      hasToken,
      hasGhCommand || hasReleasePolicy,
      "RELEASES_REPO_TOKEN and release-repository commands must share a step",
    );
    if (hasToken) {
      assert.match(step, /GH_REPO: OpenCoven\/seer-releases/);
      assert.doesNotMatch(step, /secrets\.APPLE_/);
    }
  }
  assert.doesNotMatch(
    `${signing}\n${draftPolicySource}`,
    /\bgh release delete\b|\/releases(?:\/[^\s"']*)?["']?\s+(?:--method|-X)\s+DELETE/,
  );
});

test("a valid published reconciliation skips every signing, packaging, upload, and publish step", () => {
  const signing = jobBlock("sign-and-release");
  const steps = stepBlocks(signing);
  const reconciliation = steps.find((step) =>
    step.includes("release-macos-draft.sh reconcile-published"),
  );
  const reconcileIndex = signing.indexOf(reconciliation ?? "missing");
  const packageIndex = signing.indexOf("bash scripts/package-macos-release.sh");

  assert.ok(reconciliation, "the signing job must reconcile a published release");
  assert.match(reconciliation, /id: published-reconciliation/);
  assert.match(reconciliation, /GH_TOKEN: \$\{\{ secrets\.RELEASES_REPO_TOKEN \}\}/);
  assert.match(reconciliation, /existing-published-state/);
  assert.ok(reconcileIndex < packageIndex);

  const skippedNames = [
    "Create empty release-input destination",
    "Download only the prepared input artifact",
    "Verify attested input and distinct runner identity",
    "Sign and notarize attested input",
    "Allowlist public package outputs",
    "Create or resume draft and upload only public assets",
    "Capture the exact verified draft state",
    "Publish only the verified draft",
  ];
  for (const name of skippedNames) {
    const step = steps.find((candidate) => candidate.includes(`- name: ${name}`));
    assert.ok(step, `${name} step must exist`);
    assert.match(
      step,
      /^\s+if: steps\.published-reconciliation\.outputs\.published != 'true'$/m,
      `${name} must be skipped after successful published reconciliation`,
    );
  }

  const appleSecretSteps = steps.filter((step) => /\$\{\{\s*secrets\.APPLE_/.test(step));
  assert.ok(appleSecretSteps.length > 0);
  for (const step of appleSecretSteps) {
    assert.match(step, /^\s+if: steps\.published-reconciliation\.outputs\.published != 'true'$/m);
  }
});

test("draft policy resumes only bound allowlisted drafts and publishes after fresh verification", () => {
  const signing = jobBlock("sign-and-release");
  const acquire = signing.indexOf("scripts/release-macos-draft.sh acquire-lock");
  const preflight = signing.indexOf("scripts/release-macos-draft.sh preflight");
  const upload = signing.indexOf("scripts/release-macos-draft.sh upload");
  const download = signing.indexOf("gh release download");
  const scanner = signing.indexOf("node scripts/check-release-boundary.mjs", download);
  const capture = signing.indexOf("scripts/release-macos-draft.sh capture");
  const publish = signing.indexOf("scripts/release-macos-draft.sh publish");

  assert.match(signing, /expected=\("Seer-v\$\{VERSION\}-arm64\.dmg" "SHA256SUMS" "release-manifest\.json"\)/);
  assert.match(signing, /release-notes\.md/);
  assert.match(signing, /SOURCE_REPOSITORY: \$\{\{ github\.repository \}\}/);
  assert.match(signing, /SOURCE_COMMIT: \$\{\{ github\.sha \}\}/);
  assert.match(signing, /SOURCE_TAG: \$\{\{ github\.ref_name \}\}/);
  assert.match(signing, /WORKFLOW_REF: \$\{\{ github\.workflow_ref \}\}/);
  assert.match(signing, /WORKFLOW_RUN: \$\{\{ github\.run_id \}\}/);
  assert.match(draftPolicyImplementation, /seer-release-provenance:/);
  assert.match(draftPolicyImplementation, /sourceRepository/);
  assert.match(draftPolicyImplementation, /sourceCommit/);
  assert.match(draftPolicyImplementation, /sourceTag/);
  assert.match(draftPolicyImplementation, /workflowRef/);
  assert.match(draftPolicyImplementation, /workflowRun/);
  assert.match(draftPolicyImplementation, /workflowAttempt/);
  assert.match(draftPolicySource, /immutable-releases/);
  assert.match(draftPolicyImplementation, /release author/);
  assert.match(draftPolicyImplementation, /release asset uploader/);
  assert.match(draftPolicySource, /git\/tags/);
  assert.match(draftPolicySource, /git\/refs/);
  assert.match(draftPolicySource, /seer-release-lock-/);
  assert.match(draftPolicySource, /gh release create "\$\{SOURCE_TAG\}" --draft --verify-tag/);
  assert.match(draftPolicySource, /--target "\$\{DESTINATION_ANCHOR_COMMIT\}"/);
  assert.match(draftPolicySource, /gh release upload "\$\{SOURCE_TAG\}"[\s\S]*--clobber/);
  assert.match(draftPolicyImplementation, /existing-published-state evidence/);
  assert.match(draftPolicyImplementation, /provenance marker does not match/);
  assert.match(draftPolicyImplementation, /foreign release asset/);
  assert.match(signing, /gh release download[\s\S]*--pattern "Seer-v\$\{VERSION\}-arm64\.dmg"[\s\S]*--pattern "SHA256SUMS"[\s\S]*--pattern "release-manifest\.json"/);
  assert.match(signing, /shasum -a 256 -c SHA256SUMS/);
  assert.match(signing, /trap cleanup EXIT/);
  assert.match(signing, /hdiutil attach[\s\S]*-readonly[\s\S]*-nobrowse[\s\S]*-noautoopen[\s\S]*-mountpoint/);
  assert.match(signing, /hdiutil detach/);
  assert.match(signing, /codesign --verify --deep --strict/);
  assert.match(signing, /spctl --assess --type execute/);
  assert.match(signing, /node scripts\/check-release-boundary\.mjs[\s\S]*--dmg-root/);
  assert.match(signing, /VERIFIED_STATE: \$\{\{ steps\.public-assets\.outputs\.verified-state \}\}/);
  assert.match(signing, /RELEASE_BODY: \$\{\{ steps\.release-notes\.outputs\.path \}\}/);
  assert.match(signing, /RELEASE_DIR: \$\{\{ steps\.public-assets\.outputs\.directory \}\}/);
  assert.match(draftPolicySource, /--request PATCH/);
  assert.doesNotMatch(draftPolicySource, /If-Match:/);
  assert.match(draftPolicySource, /releases\/\$\{release_id\}/);
  assert.doesNotMatch(draftPolicySource, /gh release edit/);
  assert.ok(
    acquire !== -1 &&
      acquire < preflight &&
      preflight < upload &&
      upload < download &&
      download < scanner &&
      scanner < capture &&
      capture < publish,
  );
});

test("release lock is always relinquished and governance identity is protected-environment state", () => {
  const signing = jobBlock("sign-and-release");
  const steps = stepBlocks(signing);
  const acquire = steps.find((step) => step.includes("release-macos-draft.sh acquire-lock"));
  const release = steps.find((step) => step.includes("release-macos-draft.sh release-lock"));

  assert.ok(acquire, "atomic release-lock acquisition step must exist");
  assert.ok(release, "release-lock cleanup step must exist");
  assert.match(release, /^\s+if: always\(\)$/m);
  assert.doesNotMatch(release, /RELEASE_LOCK_ACQUIRED/);
  assert.match(acquire, /SOURCE_GITHUB_TOKEN: \$\{\{ github\.token \}\}/);
  assert.match(draftPolicySource, /SOURCE_GITHUB_TOKEN/);
  assert.match(
    draftPolicySource,
    /GH_TOKEN="\$\{SOURCE_GITHUB_TOKEN\}" gh api[\s\S]*actions\/runs\/\$\{run_id\}\/attempts\/\$\{run_attempt\}/,
  );
  assert.match(signing, /RELEASE_WRITER_LOGIN: \$\{\{ vars\.RELEASE_WRITER_LOGIN \}\}/);
  assert.match(signing, /RELEASE_WRITER_ID: \$\{\{ vars\.RELEASE_WRITER_ID \}\}/);
  assert.match(signing, /WORKFLOW_ATTEMPT: \$\{\{ github\.run_attempt \}\}/);
  assert.match(draftPolicySource, /--method POST[\s\S]*repos\/\$\{GH_REPO\}\/git\/refs/);
  assert.match(
    draftPolicySource,
    /--method DELETE[\s\S]*git\/refs\/tags\/\$\{LOCK_REF_NAME\}/,
  );
  assert.match(draftPolicyImplementation, /post-publish release state/);
});

test("source and destination tags remain cryptographically bound at publication", () => {
  const signing = jobBlock("sign-and-release");
  const approval = signing.indexOf("Enforce protected release gates before any secret");
  const sourceVerification = signing.indexOf("Verify source tag still resolves to the attested commit");
  const signingStep = signing.indexOf("Sign and notarize attested input");
  const publishStep = stepBlocks(signing).find((step) =>
    step.includes("release-macos-draft.sh publish"),
  );

  assert.ok(approval !== -1 && approval < sourceVerification && sourceVerification < signingStep);
  assert.match(
    signing.slice(sourceVerification, signingStep),
    /SOURCE_GITHUB_TOKEN: \$\{\{ github\.token \}\}/,
  );
  assert.match(
    signing.slice(sourceVerification, signingStep),
    /release-macos-draft\.sh verify-source-tag/,
  );
  assert.ok(publishStep);
  assert.match(publishStep, /SOURCE_GITHUB_TOKEN: \$\{\{ github\.token \}\}/);
  assert.match(draftPolicySource, /resolve_remote_tag_commit/);
  assert.match(draftPolicySource, /destination tag collision/);
  assert.match(draftStateHelperSource, /target_commitish/);
});
