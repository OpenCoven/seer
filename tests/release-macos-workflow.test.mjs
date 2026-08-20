import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import yaml from "js-yaml";

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const workflowPath = join(repoRoot, ".github", "workflows", "release-macos.yml");
const source = existsSync(workflowPath) ? readFileSync(workflowPath, "utf8") : "";
const draftPolicyPath = join(repoRoot, "scripts", "release-macos-draft.sh");
const draftPolicySource = existsSync(draftPolicyPath) ? readFileSync(draftPolicyPath, "utf8") : "";
const draftStateHelperPath = join(repoRoot, "scripts", "release-macos-draft-state.mjs");
const draftStateHelperSource = existsSync(draftStateHelperPath) ? readFileSync(draftStateHelperPath, "utf8") : "";
const draftPolicyImplementation = `${draftPolicySource}\n${draftStateHelperSource}`;
const releaseDocumentationPaths = [
  join(repoRoot, "README.md"),
  join(repoRoot, "docs", "apple-release-credential-packet.md"),
  join(
    repoRoot,
    "docs",
    "superpowers",
    "specs",
    "2026-08-10-seer-standalone-macos-distribution.md",
  ),
];
const releaseDocumentation = releaseDocumentationPaths.map((path) => ({
  path,
  source: existsSync(path) ? readFileSync(path, "utf8") : "",
}));

function isYamlMap(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOidcWriteGrant(permissions) {
  return permissions === "write-all" || (isYamlMap(permissions) && permissions["id-token"] === "write");
}

function idTokenWriteScopes(workflowSource) {
  const workflow = yaml.load(workflowSource);
  if (!isYamlMap(workflow)) return [];

  const scopes = [];

  if (hasOidcWriteGrant(workflow.permissions)) {
    scopes.push("workflow");
  }

  if (!isYamlMap(workflow.jobs)) {
    return scopes;
  }

  for (const [jobName, job] of Object.entries(workflow.jobs)) {
    if (hasOidcWriteGrant(job?.permissions)) {
      scopes.push(`jobs.${jobName}`);
    }
  }

  return scopes;
}

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
  assert.match(source, /^on:\n {2}push:\n {4}tags:\n {6}- "v\*\.\*\.\*"\n\npermissions:\n {2}actions: read\n {2}contents: read$/m);
  assert.deepEqual(idTokenWriteScopes(source), [], "workflow must not grant OIDC-capable permissions at workflow or job scope");
  assert.doesNotMatch(source, /\b(?:pull_request|workflow_dispatch|schedule):/);
  assert.deepEqual(
    [...source.matchAll(/^ {2}([a-z][a-z0-9-]*):\n {4}(?:name|needs|runs-on):/gm)].map((match) => match[1]),
    ["prepare", "sign-and-release"],
  );
});

test("all semantic-version tags share one repository-scoped max release concurrency queue", () => {
  const workflow = yaml.load(source);
  assert.deepEqual(workflow.concurrency, {
    group: "release-macos-OpenCoven-seer-releases",
    "cancel-in-progress": false,
    queue: "max",
  });
  assert.doesNotMatch(workflow.concurrency.group, /\$\{\{|github\.ref|github\.ref_name/);
});

test("latest release publication proves the exhaustive global semantic-version maximum", () => {
  assert.match(source, /authenticated exhaustive release inventory/i);
  assert.match(draftPolicySource, /repos\/\$\{GH_REPO\}\/releases\/latest/);
  assert.match(draftPolicySource, /make_latest.*\$\{make_latest\}/);
  assert.match(draftPolicySource, /fetch_release_inventory/);
  assert.match(draftStateHelperSource, /build-inventory/);
  assert.match(draftStateHelperSource, /latest-decision/);
  assert.match(draftStateHelperSource, /verify-global-latest/);
  assert.match(draftStateHelperSource, /reconcile-published-latest/);
  assert.match(draftStateHelperSource, /compareCanonicalSemver/);
  assert.match(draftStateHelperSource, /maximumSafeIntegerDecimal/);
  assert.match(draftStateHelperSource, /normalizeStableReleaseTrust/);
  assert.match(draftStateHelperSource, /stable published release[\s\S]*author/);
  assert.match(draftStateHelperSource, /stable published release[\s\S]*asset uploader/);
  assert.doesNotMatch(draftPolicyImplementation, /make_latest.*legacy/);
  assert.match(
    draftPolicySource,
    /reconcile_published\(\)[\s\S]*fetch_release_inventory "\$\{STATE_WORK_DIR\}\/existing-published-inventory"[\s\S]*fetch_latest_release "\$\{STATE_WORK_DIR\}\/existing-published-latest"[\s\S]*reconcile-published-latest[\s\S]*printf 'published=true/,
  );

  for (const { path, source: documentation } of releaseDocumentation) {
    assert.ok(documentation.length > 0, `${path} must exist`);
    assert.match(
      documentation,
      /all authenticated\s+stable published releases/i,
      `${path} must define the global candidate set`,
    );
    assert.match(
      documentation,
      /exhaustive(?:ly)?[\s\S]{0,120}paginat/i,
      `${path} must document exhaustive bounded pagination`,
    );
    assert.match(
      documentation,
      /full page[\s\S]{0,120}(?:fail|refus|truncat)/i,
      `${path} must document max-page truncation failure`,
    );
    assert.match(documentation, /make_latest: "true"/, `${path} must document promotion`);
    assert.match(documentation, /make_latest: "false"/, `${path} must document backports`);
    assert.match(
      documentation,
      /stable[\s\S]{0,300}(?:release writer|protected writer)[\s\S]{0,100}author[\s\S]{0,300}(?:every|asset) uploader/i,
      `${path} must document protected stable author and uploader identity`,
    );
    assert.match(
      documentation,
      /(?:historical[\s\S]{0,160}without downloading|does not download[\s\S]{0,80}historical)/i,
      `${path} must document metadata-only historical inventory validation`,
    );
    assert.match(
      documentation,
      /inventory[\s\S]{0,160}(?:latest|\/releases\/latest)[\s\S]{0,160}(?:before|finish)[\s\S]{0,160}final draft/i,
      `${path} must place final draft verification after inventory/latest selection`,
    );
    assert.match(
      documentation,
      /source tag[\s\S]{0,300}destination\s+anchor\/tag[\s\S]{0,300}remote lock[\s\S]{0,300}(?:before|immediately)[\s\S]{0,120}`?PATCH`?/i,
      `${path} must document the final pre-PATCH verification order`,
    );
    assert.match(
      documentation,
      /(?:unavoidable|cannot be removed)[\s\S]{0,400}(?:no|contains no)[\s\S]{0,120}long-running/i,
      `${path} must document the narrow unsupported-If-Match API boundary`,
    );
    assert.match(
      documentation,
      /(?:post-publication|post-publish|After[^\n]{0,80}publication)[\s\S]{0,400}(?:fresh|refetch)[\s\S]{0,250}global (?:semantic-version )?maximum/i,
      `${path} must document fresh post-publication global-maximum verification`,
    );
    assert.match(
      documentation,
      /published\s+reconciliation[\s\S]{0,400}(?:fresh|refetch)[\s\S]{0,250}(?:inventory|all authenticated\s+stable published releases)[\s\S]{0,300}\/releases\/latest/i,
      `${path} must document independent retry inventory and latest checks`,
    );
    assert.match(
      documentation,
      /current published release[\s\S]{0,300}(?:appear(?:s)?|present)[\s\S]{0,250}(?:inventory|candidate set)/i,
      `${path} must bind the current release into retry inventory`,
    );
    assert.doesNotMatch(documentation, /make_latest.*legacy/i);
  }
});

test("inventory/latest precede final draft bytes and final reference checks immediately precede PATCH", () => {
  const publishCase = draftPolicySource.slice(draftPolicySource.indexOf("  publish)"));
  const inventory = publishCase.indexOf("fetch_release_inventory");
  const latest = publishCase.indexOf("fetch_latest_release");
  const finalMetadata = publishCase.indexOf("publish-final-draft");
  const finalCompare = publishCase.indexOf('node "${STATE_HELPER}" compare', finalMetadata);
  const sourceTag = publishCase.indexOf("verify_source_tag", finalCompare);
  const destination = publishCase.indexOf("verify_destination_anchor_and_tag", sourceTag);
  const lock = publishCase.indexOf("verify_remote_lock", destination);
  const patch = publishCase.indexOf("--request PATCH", lock);

  assert.ok(
    inventory !== -1 &&
      inventory < latest &&
      latest < finalMetadata &&
      finalMetadata < finalCompare &&
      finalCompare < sourceTag &&
      sourceTag < destination &&
      destination < lock &&
      lock < patch,
  );
  assert.equal(
    publishCase.slice(lock, patch),
    "verify_remote_lock\n    set +e\n    curl --fail-with-body --silent --show-error \\\n      ",
  );
  assert.doesNotMatch(
    publishCase.slice(finalCompare, patch),
    /fetch_release_inventory|fetch_latest_release/,
  );
});

test("the 15-name secret set is a union audit set while notarization methods remain exclusive", () => {
  const distributionSpec = releaseDocumentation[2].source;
  assert.match(distributionSpec, /15-name[\s\S]{0,100}union audit set/i);
  assert.match(
    distributionSpec,
    /notarization[\s\S]{0,200}exactly one complete[\s\S]{0,160}(?:API-key|Apple ID)[\s\S]{0,160}(?:never both|mutually exclusive)/i,
  );
  assert.doesNotMatch(
    distributionSpec,
    /APPLE_ID[^.\n]*APPLE_PASSWORD[^.\n]*APPLE_TEAM_ID[^.\n]*provide the documented fallback/i,
  );
});

test("protected configuration is consistently described as environment secrets", () => {
  const [readme, credentialPacket, distributionSpec] = releaseDocumentation.map(
    ({ source: documentation }) => documentation,
  );

  assert.doesNotMatch(source, /signing identity variables/i);
  assert.doesNotMatch(readme, /reviewers,\s*variables,\s*secrets/i);
  assert.doesNotMatch(credentialPacket, /environment,\s*its\s+secrets,\s*and\s+its\s+variables/i);
  for (const documentation of [readme, credentialPacket, distributionSpec]) {
    assert.match(documentation, /protected configuration[\s\S]{0,160}environment secrets/i);
  }
});

test("prepare and sign-and-release are bound to the exact seer-macos-release runner group, not label-only scheduling", () => {
  const workflow = yaml.load(source);
  assert.ok(isYamlMap(workflow?.jobs), "workflow must parse to a map of jobs");

  const expectedRunsOn = { group: "seer-macos-release", labels: "macos-14-xlarge" };

  for (const jobName of ["prepare", "sign-and-release"]) {
    const job = workflow.jobs[jobName];
    assert.ok(isYamlMap(job), `${jobName} job must exist`);
    // A bare string (label-only, e.g. "macos-14-xlarge") or an object bound
    // to any group other than seer-macos-release must fail this check: both
    // would let another runner in the org that merely carries the
    // macos-14-xlarge label receive this job, defeating the credential
    // packet's runner-group verification.
    assert.ok(
      isYamlMap(job["runs-on"]),
      `${jobName}.runs-on must be the object form ({ group, labels }), not a bare label string`,
    );
    assert.deepEqual(
      job["runs-on"],
      expectedRunsOn,
      `${jobName}.runs-on must bind exactly to group "seer-macos-release" and label "macos-14-xlarge"`,
    );
  }

  // Guard the raw source too, so a reformatted-but-equivalent YAML can't
  // silently drift the group name or reintroduce label-only scheduling
  // undetected by the parsed check above.
  const runsOnObjectForm = /runs-on:\n {6}group: seer-macos-release\n {6}labels: macos-14-xlarge\n/g;
  assert.equal(
    [...source.matchAll(runsOnObjectForm)].length,
    2,
    "both jobs must use the identical group+labels runs-on block",
  );
  assert.doesNotMatch(
    source,
    /runs-on: *macos-14-xlarge *\n/,
    "no job may use label-only runs-on scheduling",
  );
});

test("permission scanning rejects workflow-level and job-level OIDC-capable grants after YAML parsing", () => {
  const cases = [
    {
      name: "workflow-level write-all grant",
      source: `name: Example

permissions: write-all

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: true
`,
      expected: ["workflow"],
    },
    {
      name: "plain workflow-level grant",
      source: `name: Example

permissions:
  actions: read
  id-token: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: true
`,
      expected: ["workflow"],
    },
    {
      name: "quoted workflow-level grant",
      source: `name: Example

permissions:
  actions: read
  id-token: "write"

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: true
`,
      expected: ["workflow"],
    },
    {
      name: "folded workflow-level grant",
      source: `name: Example

permissions:
  actions: read
  id-token: >-
    write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: true
`,
      expected: ["workflow"],
    },
    {
      name: "literal workflow-level grant",
      source: `name: Example

permissions:
  actions: read
  id-token: |-
    write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: true
`,
      expected: ["workflow"],
    },
    {
      name: "job-level write-all grant",
      source: `name: Example

permissions:
  contents: read

jobs:
  release:
    runs-on: ubuntu-latest
    permissions: write-all
    steps:
      - run: true
`,
      expected: ["jobs.release"],
    },
    {
      name: "quoted job-level grant",
      source: `name: Example

permissions:
  contents: read

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: 'write'
    steps:
      - run: true
`,
      expected: ["jobs.release"],
    },
    {
      name: "inline quoted job-level grant",
      source: `name: Example

permissions:
  contents: read

jobs:
  release:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: "write" }
    steps:
      - run: true
`,
      expected: ["jobs.release"],
    },
    {
      name: "folded job-level grant",
      source: `name: Example

permissions:
  contents: read

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: >-
        write
    steps:
      - run: true
`,
      expected: ["jobs.release"],
    },
    {
      name: "literal job-level grant",
      source: `name: Example

permissions:
  contents: read

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: |-
        write
    steps:
      - run: true
`,
      expected: ["jobs.release"],
    },
  ];

  for (const { name, source: workflowSource, expected } of cases) {
    assert.deepEqual(idTokenWriteScopes(workflowSource), expected, name);
  }
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

  assert.match(prepare, /runs-on:\n {6}group: seer-macos-release\n {6}labels: macos-14-xlarge/);
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
    "npm run test:standalone-safe",
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

test("signing uses a protected fresh job and rejects gates and identity mismatches before credentials", () => {
  const signing = jobBlock("sign-and-release");
  const gateIndex = signing.indexOf("Enforce protected release gates before any credential");
  const firstCredential = signing.indexOf("${{ secrets.RELEASES_REPO_TOKEN }}");

  assert.match(signing, /needs: prepare/);
  assert.match(signing, /runs-on:\n {6}group: seer-macos-release\n {6}labels: macos-14-xlarge/);
  assert.match(signing, /environment: macos-release/);
  assert.match(
    signing,
    /BINARY_DISTRIBUTION_APPROVED: \$\{\{ secrets\.BINARY_DISTRIBUTION_APPROVED \}\}/,
  );
  assert.match(signing, /PARITY_MATRIX_APPROVED: \$\{\{ secrets\.PARITY_MATRIX_APPROVED \}\}/);
  assert.match(
    signing,
    /CLEAN_MACHINE_VERIFIED_COMMIT: \$\{\{ secrets\.CLEAN_MACHINE_VERIFIED_COMMIT \}\}/,
  );
  assert.match(signing, /\^v\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$/);
  assert.match(signing, /\^\[0-9a-f\]\{40\}\$/);
  assert.match(
    signing,
    /CLEAN_MACHINE_VERIFIED_COMMIT.*GITHUB_SHA|GITHUB_SHA.*CLEAN_MACHINE_VERIFIED_COMMIT/s,
  );
  assert.ok(gateIndex !== -1 && firstCredential > gateIndex);
  assert.match(
    signing,
    /SIGNING_RUNNER_ID: gha:\$\{\{ github\.run_id \}\}:\$\{\{ github\.run_attempt \}\}:sign/,
  );
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

test("protected non-sensitive Apple identity secrets are shared by reconciliation and packaging", () => {
  const signing = jobBlock("sign-and-release");
  const steps = stepBlocks(signing);
  const gate = steps.find((step) =>
    step.includes("Enforce protected release gates before any credential"),
  );
  const reconciliation = steps.find((step) =>
    step.includes("release-macos-draft.sh reconcile-published"),
  );
  const packaging = steps.find((step) => step.includes("scripts/package-macos-release.sh"));

  for (const [name, step] of [
    ["protected gate", gate],
    ["published reconciliation", reconciliation],
    ["packaging", packaging],
  ]) {
    assert.ok(step, `${name} step must exist`);
    assert.match(step, /APPLE_SIGNING_IDENTITY: \$\{\{ secrets\.APPLE_SIGNING_IDENTITY \}\}/);
    assert.match(step, /APPLE_TEAM_ID: \$\{\{ secrets\.APPLE_TEAM_ID \}\}/);
    assert.doesNotMatch(step, /vars\.APPLE_(?:SIGNING_IDENTITY|TEAM_ID)/);
  }

  assert.match(reconciliation, /BUILD_NUMBER: \$\{\{ github\.run_number \}\}/);
  assert.match(packaging, /BUILD_NUMBER: \$\{\{ github\.run_number \}\}/);
  assert.match(gate, /\[\[ "\$\{APPLE_TEAM_ID\}" =~ \^\[A-Z0-9\]\{10\}\$ \]\]/);
  assert.match(gate, /\[\[ -n "\$\{APPLE_SIGNING_IDENTITY\}" \]\]/);
  assert.match(
    gate,
    /\[\[ "\$\{APPLE_SIGNING_IDENTITY\}" != \*\$'\\n'\* && "\$\{APPLE_SIGNING_IDENTITY\}" != \*\$'\\r'\* \]\]/,
  );
  assert.match(
    gate,
    /\[\[ "\$\{APPLE_SIGNING_IDENTITY\}" =~ \^Developer\\ ID\\ Application:\\ \.\+\\ \\\(\$\{APPLE_TEAM_ID\}\\\)\$ \]\]/,
  );
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
    "BINARY_DISTRIBUTION_APPROVED",
    "PARITY_MATRIX_APPROVED",
    "CLEAN_MACHINE_VERIFIED_COMMIT",
    "RELEASE_WRITER_LOGIN",
    "RELEASE_WRITER_ID",
    "RELEASES_REPO_TOKEN",
  ]);

  assert.deepEqual(signingSecrets, expectedSecrets);
  assert.doesNotMatch(signing, /\$\{\{\s*vars\./);
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
      assert.doesNotMatch(
        step,
        /secrets\.APPLE_(?:CERTIFICATE(?:_PASSWORD)?|API_ISSUER|API_KEY(?:_BASE64)?|ID|PASSWORD)\b/,
      );
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

  const appleCredentialSteps = steps.filter((step) =>
    /\$\{\{\s*secrets\.APPLE_(?:CERTIFICATE(?:_PASSWORD)?|API_ISSUER|API_KEY(?:_BASE64)?|ID|PASSWORD)\s*\}\}/.test(
      step,
    ),
  );
  assert.ok(appleCredentialSteps.length > 0);
  for (const step of appleCredentialSteps) {
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
  assert.match(signing, /RELEASE_WRITER_LOGIN: \$\{\{ secrets\.RELEASE_WRITER_LOGIN \}\}/);
  assert.match(signing, /RELEASE_WRITER_ID: \$\{\{ secrets\.RELEASE_WRITER_ID \}\}/);
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
  const approval = signing.indexOf("Enforce protected release gates before any credential");
  const sourceVerification = signing.indexOf(
    "Verify source tag still resolves to the attested commit",
  );
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
