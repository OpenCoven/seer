import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  buildNodeTestArgs,
  STANDALONE_SAFE_TEST_FILES,
  TEST_CONCURRENCY,
} from "../scripts/run-standalone-tests.mjs";

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
// Both official gates (.github/workflows/standalone-ci.yml and
// .github/workflows/release-macos.yml) now run every standalone-safe test
// file, including the renderer and renderer-lock files, through the single
// `npm run test:standalone-safe` package script, which always invokes
// scripts/run-standalone-tests.mjs's exported `STANDALONE_SAFE_TEST_FILES`
// with `--test-concurrency=1` (see `buildNodeTestArgs`). Because there is
// only one shared invocation left (not a per-workflow hand-maintained
// list), asserting the concurrency pin and the file list directly against
// that module - rather than re-parsing each workflow's shell text - fully
// covers both workflows at once; a future edit can no longer silently
// reintroduce the race by dropping the flag or splitting the files across
// differently concurrent invocations, since there is nowhere left in
// workflow YAML to do that.

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

const packageJson = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8"));

const workflows = [
  { name: "standalone-ci.yml", path: join(repoRoot, ".github", "workflows", "standalone-ci.yml") },
  { name: "release-macos.yml", path: join(repoRoot, ".github", "workflows", "release-macos.yml") },
];

test("the root npm test script serializes all tests/*.test.mjs files (no default Node test-runner file concurrency)", () => {
  assert.equal(
    packageJson.scripts.test,
    "node --test --test-concurrency=1 tests/*.test.mjs",
    "npm test must pin --test-concurrency=1 so tests/standalone-renderer.test.mjs and " +
      "tests/standalone-renderer-lock.test.mjs (both of which touch the real " +
      ".seer-standalone-renderer.lock directory) never run as concurrent worker processes",
  );
});

test("scripts/run-standalone-tests.mjs pins --test-concurrency=1 for the standalone-safe test list", () => {
  assert.equal(TEST_CONCURRENCY, 1);
  const args = buildNodeTestArgs();
  assert.equal(args[0], "--test");
  assert.equal(args[1], "--test-concurrency=1");
});

test("the standalone-safe list runs tests/standalone-renderer-lock.test.mjs in the same serialized invocation as tests/standalone-renderer.test.mjs", () => {
  assert.ok(
    STANDALONE_SAFE_TEST_FILES.includes("tests/standalone-renderer-lock.test.mjs"),
    "STANDALONE_SAFE_TEST_FILES must include tests/standalone-renderer-lock.test.mjs",
  );
  assert.ok(
    STANDALONE_SAFE_TEST_FILES.includes("tests/standalone-renderer.test.mjs"),
    "STANDALONE_SAFE_TEST_FILES must run tests/standalone-renderer.test.mjs in the same serialized " +
      "invocation as tests/standalone-renderer-lock.test.mjs (both share the real renderer build lock)",
  );
});

test("the standalone-safe list includes the renderer asset digest helper test file alongside renderer-build-identity.test.mjs", () => {
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
  // deadline, and malformed-output handling); dropping it from
  // STANDALONE_SAFE_TEST_FILES would silently stop exercising all of that
  // in CI while tests/renderer-build-identity.test.mjs continued to look
  // green. This direct central-list assertion (rather than a re-parse of
  // either workflow's shell text) is what still catches that removal.
  assert.ok(
    STANDALONE_SAFE_TEST_FILES.includes("tests/renderer-asset-digest-helper.test.mjs"),
    "STANDALONE_SAFE_TEST_FILES must include tests/renderer-asset-digest-helper.test.mjs",
  );
  assert.ok(
    STANDALONE_SAFE_TEST_FILES.includes("tests/renderer-build-identity.test.mjs"),
    "STANDALONE_SAFE_TEST_FILES should run tests/renderer-asset-digest-helper.test.mjs alongside " +
      "tests/renderer-build-identity.test.mjs (both exercise scripts/renderer-build-identity.mjs)",
  );
});

for (const { name, path } of workflows) {
  test(`${name}: the standalone-boundary test-suite invocation still pins --test-concurrency=1`, () => {
    // tests/standalone-boundary.test.mjs is deliberately not part of
    // STANDALONE_SAFE_TEST_FILES (it must run after the "Build unsigned
    // Seer.app" step - see scripts/run-standalone-tests.mjs), so it remains
    // its own literal, single-file `node --test` shell command in each
    // workflow. That command is fixed and narrow enough (one file, no
    // other arguments) that a plain substring/regex check against the raw
    // YAML text is sufficient here and does not require re-introducing a
    // general shell-command parser.
    const source = readFileSync(path, "utf8");
    assert.match(
      source,
      /node --test --test-concurrency=1 tests\/standalone-boundary\.test\.mjs\b/,
      `expected ${name} to invoke tests/standalone-boundary.test.mjs with --test-concurrency=1`,
    );
  });

  // Registration of *this* file (tests/standalone-build-gate-serialization.test.mjs)
  // in ${name}'s explicit test-file list used to be self-checked right here,
  // but a self-check can only run if a worker process is still executing
  // this very file - if a future edit dropped it from ${name}'s list, the
  // assertion guarding against exactly that removal would disappear along
  // with it, and CI would stay green. That guard now lives in
  // tests/identity.test.mjs instead, which is registered independently (and
  // first) in scripts/run-standalone-tests.mjs's STANDALONE_SAFE_TEST_FILES,
  // so it keeps working even if this file is removed from CI.
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
