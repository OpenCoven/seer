import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import process from "node:process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  buildNodeTestArgs,
  propagateResult,
  REPO_ROOT,
  runStandaloneSafeTests,
  STANDALONE_SAFE_TEST_FILES,
  TEST_CONCURRENCY,
} from "../scripts/run-standalone-tests.mjs";

// Direct unit coverage for scripts/run-standalone-tests.mjs itself - the one
// module both .github/workflows/standalone-ci.yml and
// .github/workflows/release-macos.yml now depend on transitively through
// `npm run test:standalone-safe`. tests/identity.test.mjs and
// tests/standalone-build-gate-serialization.test.mjs already assert that
// both workflows call the shared package script and that specific
// individually-important files (this repo's gate-serialization and
// renderer-asset-digest-helper tests) stay registered; this file instead
// covers the runner module's own contract: the full required-file set, list
// shape (no duplicates), argument construction, and - most importantly -
// that a failing, erroring, or signaled child run can never be silently
// treated as a clean exit.

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

// Every test file the task's architecture explicitly names as
// standalone-safe, by role: identity, renderer identity, the Python digest
// helper, renderer build/lock, gate serialization, safe publication, the
// release manifest, packaging, release-only draft/workflow policy coverage
// (folded into this same superset list - see the module doc comment in
// scripts/run-standalone-tests.mjs for why that's safe), agent parity, and
// tray update.
const REQUIRED_TEST_FILES = [
  "tests/identity.test.mjs",
  "tests/renderer-build-identity.test.mjs",
  "tests/renderer-asset-digest-helper.test.mjs",
  "tests/standalone-renderer.test.mjs",
  "tests/standalone-renderer-lock.test.mjs",
  "tests/standalone-build-gate-serialization.test.mjs",
  "tests/safe-app-publication.test.mjs",
  "tests/release-manifest.test.mjs",
  "tests/package-macos-release.test.mjs",
  "tests/release-macos-draft-policy.test.mjs",
  "tests/release-macos-workflow.test.mjs",
  "tests/agent-detection-parity.test.mjs",
  "tests/tray-update-error-handling.test.mjs",
];

function withScratchDir(prefix, callback) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", prefix));
  try {
    return callback(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

/**
 * This file is itself a `node --test` worker, which sets `NODE_TEST_CONTEXT`
 * (and `NODE_TEST_WORKER_ID`) in its own environment. `spawnSync` inherits
 * `process.env` by default, and a nested `node --test` child that inherits
 * `NODE_TEST_CONTEXT` gets silently detected by Node as a recursive test run
 * and skips actually executing its files — reporting a clean exit
 * regardless of what the nested fixture files would really do. Stripping
 * just those two variables (via `runStandaloneSafeTests`'s `env` override)
 * lets the tests below exercise real child-process spawning/exit-code
 * propagation without that false-positive.
 */
function envWithoutNestedTestContext() {
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  delete env.NODE_TEST_WORKER_ID;
  return env;
}

test("REPO_ROOT resolves to this repository's real root", () => {
  assert.equal(REPO_ROOT, repoRoot);
});

test("STANDALONE_SAFE_TEST_FILES includes every required standalone-safe test file", () => {
  for (const file of REQUIRED_TEST_FILES) {
    assert.ok(
      STANDALONE_SAFE_TEST_FILES.includes(file),
      `STANDALONE_SAFE_TEST_FILES must include ${file}`,
    );
  }
});

test("STANDALONE_SAFE_TEST_FILES contains no duplicate entries", () => {
  assert.equal(
    new Set(STANDALONE_SAFE_TEST_FILES).size,
    STANDALONE_SAFE_TEST_FILES.length,
    "every standalone-safe test file must be listed exactly once",
  );
});

test("STANDALONE_SAFE_TEST_FILES is frozen so callers cannot mutate the shared list", () => {
  assert.ok(Object.isFrozen(STANDALONE_SAFE_TEST_FILES));
  assert.throws(() => {
    STANDALONE_SAFE_TEST_FILES.push("tests/should-not-be-added.test.mjs");
  }, TypeError);
});

test("every listed file is a tests/*.test.mjs path that actually exists on disk", () => {
  for (const file of STANDALONE_SAFE_TEST_FILES) {
    assert.match(
      file,
      /^tests\/[\w.-]+\.test\.mjs$/,
      `${file} should be a tests/*.test.mjs-shaped path`,
    );
    assert.doesNotThrow(
      () => statSync(join(REPO_ROOT, file)),
      `${file} is listed in STANDALONE_SAFE_TEST_FILES but does not exist on disk`,
    );
  }
});

test("this file registers itself in STANDALONE_SAFE_TEST_FILES", () => {
  assert.ok(
    STANDALONE_SAFE_TEST_FILES.includes("tests/run-standalone-tests.test.mjs"),
    "scripts/run-standalone-tests.mjs's own test file must be part of the list it runs",
  );
});

test("tests/standalone-boundary.test.mjs and tests/glaze-runtime-resolution.test.mjs are deliberately excluded", () => {
  // See the module doc comment in scripts/run-standalone-tests.mjs: the
  // boundary suite must run after the "Build unsigned Seer.app" step (its
  // own later, unchanged `node --test` step in both workflows), and the
  // Glaze-runtime suite is out of scope for a credential-free standalone
  // runner list.
  assert.ok(!STANDALONE_SAFE_TEST_FILES.includes("tests/standalone-boundary.test.mjs"));
  assert.ok(!STANDALONE_SAFE_TEST_FILES.includes("tests/glaze-runtime-resolution.test.mjs"));
});

test("TEST_CONCURRENCY pins to 1", () => {
  assert.equal(TEST_CONCURRENCY, 1);
});

test("buildNodeTestArgs defaults to --test, the concurrency pin, then every standalone-safe file in order", () => {
  assert.deepEqual(buildNodeTestArgs(), [
    "--test",
    "--test-concurrency=1",
    ...STANDALONE_SAFE_TEST_FILES,
  ]);
});

test("buildNodeTestArgs accepts an override file list without mutating the default export", () => {
  const args = buildNodeTestArgs(["tests/a.test.mjs", "tests/b.test.mjs"]);
  assert.deepEqual(args, [
    "--test",
    "--test-concurrency=1",
    "tests/a.test.mjs",
    "tests/b.test.mjs",
  ]);
  assert.deepEqual(buildNodeTestArgs(), [
    "--test",
    "--test-concurrency=1",
    ...STANDALONE_SAFE_TEST_FILES,
  ]);
});

test("propagateResult throws the original spawn-level error instead of exiting cleanly", () => {
  const spawnError = new Error("spawnSync ENOENT");
  assert.throws(
    () => propagateResult({ error: spawnError, status: null, signal: null }),
    (thrown) => thrown === spawnError,
  );
});

test("propagateResult re-raises a child's signal against this process rather than exiting with an ordinary status", () => {
  const originalKill = process.kill;
  const calls = [];
  process.kill = (pid, signal) => {
    calls.push([pid, signal]);
  };
  try {
    const outcome = propagateResult({ error: null, status: null, signal: "SIGTERM" });
    assert.equal(outcome, undefined);
  } finally {
    process.kill = originalKill;
  }
  assert.deepEqual(calls, [[process.pid, "SIGTERM"]]);
});

test("propagateResult sets process.exitCode to a real 0 status without the `status || 1` bug", () => {
  const original = process.exitCode;
  try {
    propagateResult({ error: null, status: 0, signal: null });
    assert.equal(
      process.exitCode,
      0,
      "a clean status 0 must never be coerced into a failing exit code by `status || 1`-style logic",
    );
  } finally {
    process.exitCode = original;
  }
});

test("propagateResult sets process.exitCode to the child's exact non-zero status", () => {
  const original = process.exitCode;
  try {
    propagateResult({ error: null, status: 7, signal: null });
    assert.equal(process.exitCode, 7);
  } finally {
    process.exitCode = original;
  }
});

test("propagateResult never silently succeeds when both status and signal are absent", () => {
  const original = process.exitCode;
  try {
    propagateResult({ error: null, status: null, signal: null });
    assert.equal(process.exitCode, 1);
  } finally {
    process.exitCode = original;
  }
});

test("runStandaloneSafeTests spawns node --test with inherited stdio and reports a clean status for a passing fixture", () => {
  withScratchDir("run-standalone-tests-pass-", (scratch) => {
    const fixture = join(scratch, "fixture-pass.test.mjs");
    writeFileSync(fixture, 'import test from "node:test";\ntest("passes", () => {});\n');

    const result = runStandaloneSafeTests({
      files: [fixture],
      cwd: repoRoot,
      env: envWithoutNestedTestContext(),
    });

    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    assert.equal(result.status, 0);
    assert.equal(result.stdout, null, "stdio must be inherited, never captured/piped");
    assert.equal(result.stderr, null, "stdio must be inherited, never captured/piped");
  });
});

test("runStandaloneSafeTests reports the child's real failing status for a failing fixture, and propagateResult never turns it into success", () => {
  withScratchDir("run-standalone-tests-fail-", (scratch) => {
    const fixture = join(scratch, "fixture-fail.test.mjs");
    writeFileSync(
      fixture,
      'import test from "node:test";\ntest("fails", () => { throw new Error("boom"); });\n',
    );

    const result = runStandaloneSafeTests({
      files: [fixture],
      cwd: repoRoot,
      env: envWithoutNestedTestContext(),
    });

    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    assert.notEqual(result.status, 0, "a failing test file must not report a clean exit status");

    const original = process.exitCode;
    try {
      propagateResult(result);
      assert.notEqual(
        process.exitCode,
        0,
        "propagateResult must never turn a failing standalone-safe run into a clean exit code",
      );
    } finally {
      process.exitCode = original;
    }
  });
});

test("runStandaloneSafeTests surfaces a spawn-level error (e.g. a missing execPath) instead of exiting cleanly", () => {
  const result = runStandaloneSafeTests({
    files: [],
    execPath: join(repoRoot, "does-not-exist-nonexistent-binary"),
    cwd: repoRoot,
  });

  assert.ok(result.error, "spawnSync should report an error for a nonexistent execPath");
  assert.equal(result.error.code, "ENOENT");
  assert.throws(() => propagateResult(result), (thrown) => thrown === result.error);
});
