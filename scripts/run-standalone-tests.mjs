#!/usr/bin/env node
// Single source of truth for the "standalone-safe" Node test-runner
// invocation shared by the `test:standalone-safe` package script and,
// transitively, both `.github/workflows/standalone-ci.yml` and
// `.github/workflows/release-macos.yml`.
//
// These test files used to be hand-maintained twice, once in each
// workflow's `run:` step, as an explicit
// `node --test --test-concurrency=1 <files...>` shell command. Verifying a
// given file was actually registered (and not merely mentioned in a
// comment, an unrelated command, or a similarly-named file) then required
// parsing that shell text back out of the workflow YAML — first with a
// naive substring scan, then with a hand-rolled shell tokenizer
// (`tests/helpers/workflow-node-test-invocations.mjs`, now deleted) that
// had to reimplement quoting, comments, line continuations, and control
// operators just to answer "does this workflow really run this file?".
//
// That whole class of problem goes away by making the list live in one
// executable module (this file) instead of in workflow YAML text: both
// workflows now invoke the exact same fixed, argument-free command,
// `npm run test:standalone-safe`, so verifying they call it is a single
// exact-string comparison against the parsed YAML `run:` value — no shell
// parsing required. Verifying which test files actually run is a plain
// import of `STANDALONE_SAFE_TEST_FILES` below and an
// `Array.prototype.includes` check, never a scan of reconstituted shell
// text.
//
// Every file in `STANDALONE_SAFE_TEST_FILES` is safe to run in a
// `pull_request`-triggered CI job with no credentials and no real network
// access: the release-packaging/draft-policy tests stub every signing,
// notarization, `curl`, and `gh` invocation behind fakes placed first on
// `PATH` (see tests/release-macos-draft-policy.test.mjs), and the
// release-workflow test performs only static source/YAML analysis (see
// tests/release-macos-workflow.test.mjs) — neither ever contacts Apple's or
// GitHub's real APIs. That safety is what lets both workflows share one
// superset list instead of maintaining a second, separately-reviewed
// release-only list.
//
// `tests/standalone-boundary.test.mjs` is deliberately *not* in this list:
// it must run after the "Build unsigned Seer.app" step (its own final test
// shells out to `npm run build:macos` again, redundantly rebuilding the
// app), so both workflows still invoke it as its own explicit, later
// `node --test --test-concurrency=1` step. `tests/glaze-runtime-resolution.test.mjs`
// is also excluded: it exercises the Glaze/Electron SDK-resolution wrapper,
// which is out of scope for the credential-free standalone runners this
// list targets (see glaze.ts).
import { spawnSync } from "node:child_process";
import console from "node:console";
import { dirname } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

/** Repository root: this file always lives at `<repoRoot>/scripts/run-standalone-tests.mjs`. */
export const REPO_ROOT = dirname(here);

/**
 * Every standalone-safe test file, in the order `node --test` is invoked
 * with them. Node's test runner treats each file as its own worker process
 * regardless of listed order, so this order is not itself test-observable —
 * it is kept identical to the pre-existing hand-maintained
 * `release-macos.yml` list purely so history/diffs stay legible.
 */
export const STANDALONE_SAFE_TEST_FILES = Object.freeze([
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
  "tests/run-standalone-tests.test.mjs",
]);

/**
 * tests/standalone-renderer.test.mjs and tests/standalone-renderer-lock.test.mjs
 * both drive scripts/build-standalone-renderer.mjs against this
 * repository's real `.seer-standalone-renderer.lock` directory (the lock
 * test intentionally overwrites that directory to simulate stale/synthetic
 * lock owners). Node's test runner executes test *files* concurrently by
 * default, which would race both files over that same physical lock
 * directory and the `build/standalone-renderer` output, producing
 * nondeterministic EEXIST/owner-mismatch failures — so every file in
 * `STANDALONE_SAFE_TEST_FILES` is run in one single-worker
 * `--test-concurrency=1` invocation, never split across separately
 * concurrent invocations.
 */
export const TEST_CONCURRENCY = 1;

/**
 * Builds the exact argument list `node` is invoked with: `--test`, the
 * concurrency pin, then every file in order. Exported so tests can assert
 * on the precise shape (flag order, exact concurrency value) without
 * duplicating it.
 */
export function buildNodeTestArgs(files = STANDALONE_SAFE_TEST_FILES) {
  return ["--test", `--test-concurrency=${TEST_CONCURRENCY}`, ...files];
}

/**
 * Runs every standalone-safe test file in a single `node --test` child
 * process with inherited stdio (so CI/local output streams live, exactly as
 * if `node --test ...` had been typed directly), and returns the raw
 * `spawnSync` result for the caller to interpret (see `propagateResult`).
 * Never invoked through a shell — `spawnSync`'s `shell` option is left at
 * its default of `false` — so there is no shell quoting/parsing of any kind
 * between this process and the child.
 *
 * `env` defaults to this process's own environment (`spawnSync`'s own
 * default), exactly like a bare `npm run test:standalone-safe` invocation
 * from a shell. It is overridable so tests/run-standalone-tests.test.mjs can
 * exercise this function's real child-spawning behavior from *within* a
 * `node --test` worker without the child inheriting that worker's
 * `NODE_TEST_CONTEXT`/`NODE_TEST_WORKER_ID` — Node's test runner otherwise
 * detects the nested invocation as recursive and silently skips actually
 * running it, which would let a genuinely failing nested run report a false
 * clean exit.
 */
export function runStandaloneSafeTests({
  files = STANDALONE_SAFE_TEST_FILES,
  execPath = process.execPath,
  cwd = REPO_ROOT,
  env = process.env,
} = {}) {
  return spawnSync(execPath, buildNodeTestArgs(files), {
    cwd,
    env,
    stdio: "inherit",
  });
}

/**
 * Propagates a `spawnSync` result (from `runStandaloneSafeTests`) to this
 * process's own exit, synchronously and exhaustively, so a
 * failing/erroring/signaled child test run can never be silently treated
 * as success:
 *   - a spawn-level failure (e.g. `execPath` not found) throws the original
 *     `Error` rather than letting the process exit 0;
 *   - a child killed by a signal re-raises that exact signal against this
 *     process, matching how a shell reports a signal-terminated command,
 *     rather than exiting with an ordinary status code; and
 *   - a normal exit propagates the child's exact status code — including a
 *     real `0` (deliberately checked with `typeof result.status === "number"`
 *     rather than `result.status || 1`, since `0 || 1` would wrongly treat a
 *     clean pass as failure) — defaulting only to a failure (`1`) in the
 *     unexpected case neither a status nor a signal is present.
 */
export function propagateResult(result) {
  if (result.error) {
    throw result.error;
  }
  if (result.signal) {
    process.kill(process.pid, result.signal);
    return;
  }
  process.exitCode = typeof result.status === "number" ? result.status : 1;
}

function main() {
  try {
    propagateResult(runStandaloneSafeTests());
  } catch (error) {
    console.error(`error: ${error.message}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main();
}
