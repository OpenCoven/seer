import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

// Characterization test for the standalone renderer build-lock race:
//
// tests/standalone-renderer.test.mjs shells out to
// `npm run build:standalone-renderer`, and tests/standalone-renderer-lock.test.mjs
// both drives scripts/build-standalone-renderer.mjs directly *and* writes a
// synthetic lock directly into this repository's real
// `.seer-standalone-renderer.lock` path (see its `writeSyntheticLock`
// helper) to simulate stale/foreign lock owners. scripts/build-standalone-renderer.mjs
// always resolves that lock directory relative to its own file location
// (`dirname(here)`), i.e. the real repo root, regardless of which test
// invoked it or what `cwd` it was spawned with.
//
// Node's `--test` runner executes multiple test *files* in separate worker
// processes concurrently by default (tests within a single file remain
// sequential). Running these two files together without pinning
// `--test-concurrency=1` therefore races both processes over the same
// physical lock directory and `build/standalone-renderer` output,
// producing nondeterministic EEXIST/owner-mismatch failures.
//
// This test statically asserts that every official gate which runs both
// files (or the lock file at all) pins Node's test runner to
// `--test-concurrency=1`, so a future edit can't silently reintroduce the
// race by dropping the flag or splitting the files across differently
// concurrent invocations.

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

const packageJson = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8"));

const workflows = [
  { name: "standalone-ci.yml", path: join(repoRoot, ".github", "workflows", "standalone-ci.yml") },
  { name: "release-macos.yml", path: join(repoRoot, ".github", "workflows", "release-macos.yml") },
];

/**
 * Extracts every distinct `node --test ...` shell invocation from a workflow
 * source, keeping each invocation's continuation lines (`\` line
 * continuations) joined so the full file list can be inspected together.
 */
function extractNodeTestInvocations(source) {
  const invocations = [];
  const lines = source.split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    if (!/node --test\b/.test(lines[i])) continue;
    let block = lines[i];
    let j = i;
    while (block.trimEnd().endsWith("\\")) {
      j += 1;
      block += `\n${lines[j]}`;
    }
    invocations.push(block);
  }
  return invocations;
}

test("the root npm test script serializes all tests/*.test.mjs files (no default Node test-runner file concurrency)", () => {
  assert.equal(
    packageJson.scripts.test,
    "node --test --test-concurrency=1 tests/*.test.mjs",
    "npm test must pin --test-concurrency=1 so tests/standalone-renderer.test.mjs and " +
      "tests/standalone-renderer-lock.test.mjs (both of which touch the real " +
      ".seer-standalone-renderer.lock directory) never run as concurrent worker processes",
  );
});

for (const { name, path } of workflows) {
  test(`${name}: every node --test invocation that includes the renderer-lock test pins --test-concurrency=1`, () => {
    const source = readFileSync(path, "utf8");
    const invocations = extractNodeTestInvocations(source);
    assert.ok(invocations.length > 0, `expected at least one "node --test" invocation in ${name}`);

    const lockInvocations = invocations.filter((invocation) =>
      invocation.includes("tests/standalone-renderer-lock.test.mjs"),
    );
    assert.ok(
      lockInvocations.length > 0,
      `expected ${name} to invoke tests/standalone-renderer-lock.test.mjs at least once`,
    );

    for (const invocation of lockInvocations) {
      assert.match(
        invocation,
        /node --test --test-concurrency=1\b/,
        `${name} invocation of tests/standalone-renderer-lock.test.mjs must pin --test-concurrency=1:\n${invocation}`,
      );
      assert.ok(
        invocation.includes("tests/standalone-renderer.test.mjs"),
        `${name} must run tests/standalone-renderer.test.mjs in the same serialized invocation as ` +
          `tests/standalone-renderer-lock.test.mjs (both share the real renderer build lock):\n${invocation}`,
      );
    }
  });

  test(`${name}: the standalone-boundary test-suite invocation also pins --test-concurrency=1`, () => {
    const source = readFileSync(path, "utf8");
    const invocations = extractNodeTestInvocations(source);
    const boundaryInvocations = invocations.filter((invocation) =>
      invocation.includes("tests/standalone-boundary.test.mjs"),
    );
    assert.ok(
      boundaryInvocations.length > 0,
      `expected ${name} to invoke tests/standalone-boundary.test.mjs at least once`,
    );
    for (const invocation of boundaryInvocations) {
      assert.match(
        invocation,
        /node --test --test-concurrency=1\b/,
        `${name} invocation of tests/standalone-boundary.test.mjs must pin --test-concurrency=1:\n${invocation}`,
      );
    }
  });

  test(`${name}: includes the renderer asset digest helper test file alongside renderer-build-identity.test.mjs`, () => {
    // scripts/renderer-build-identity.mjs's system-interpreter design (Node
    // reads scripts/renderer-asset-digest.py's own source bytes and pipes
    // them to trusted /usr/bin/python3 over stdin - see its module doc
    // comment) replaced an earlier compiled-Swift/private-directory/cache
    // design that was rejected for compilation cost, publication/execution
    // TOCTOU, and ambient-permission flaws. tests/renderer-asset-digest-helper.test.mjs
    // is the only test file covering that design's own safety properties
    // directly (trusted-interpreter validation, exact-stdin-bytes execution
    // independent of any on-disk path, size/count/path limits, isolated-mode
    // (`-I`) resistance to a hostile PYTHONPATH/sitecustomize/cwd shadow
    // module, the declarative in-process test-action protocol, the overall
    // deadline, and malformed-output handling); a future edit dropping it
    // from either official gate would silently stop exercising all of that
    // in CI while tests/renderer-build-identity.test.mjs continued to look
    // green.
    const source = readFileSync(path, "utf8");
    const invocations = extractNodeTestInvocations(source);
    const assetDigestHelperInvocations = invocations.filter((invocation) =>
      invocation.includes("tests/renderer-asset-digest-helper.test.mjs"),
    );
    assert.ok(
      assetDigestHelperInvocations.length > 0,
      `expected ${name} to invoke tests/renderer-asset-digest-helper.test.mjs at least once`,
    );
    for (const invocation of assetDigestHelperInvocations) {
      assert.ok(
        invocation.includes("tests/renderer-build-identity.test.mjs"),
        `${name} should run tests/renderer-asset-digest-helper.test.mjs alongside ` +
          `tests/renderer-build-identity.test.mjs (both exercise scripts/renderer-build-identity.mjs):\n${invocation}`,
      );
    }
  });
}

test("scripts/build-standalone-renderer.mjs still resolves its lock directory relative to its own file location", () => {
  // Guards the premise above: if this ever changed to accept an injected
  // root/cwd, the synthetic-lock/build race this test file documents would
  // no longer apply the same way, and the serialization requirement above
  // would need to be revisited.
  const wrapperSource = readFileSync(join(repoRoot, "scripts", "build-standalone-renderer.mjs"), "utf8");
  assert.match(wrapperSource, /const repoRoot = dirname\(here\);/);
  assert.match(wrapperSource, /const lockDir = join\(repoRoot, "\.seer-standalone-renderer\.lock"\);/);
});
