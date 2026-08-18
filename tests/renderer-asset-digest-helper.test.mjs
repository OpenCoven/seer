// Direct, low-level tests for the non-cached system-interpreter design:
// scripts/renderer-asset-digest.py itself (invoked exactly the way
// scripts/renderer-build-identity.mjs invokes it - `/usr/bin/python3 -` with
// the helper's own source bytes piped via stdin, never executed by a
// repository-relative pathname) and renderer-build-identity.mjs's own
// interpreter-trust/spawn seam.
//
// tests/renderer-build-identity.test.mjs already covers computeRendererAssetDigest's
// end-to-end contract (real repo digest stability, non-ASCII/locale
// ordering, top-level build-manifest.json exclusion, and the full
// swap-after-collection matrix via afterCollection). This file deliberately
// does not repeat that coverage; it instead exercises properties specific
// to *this* design - the exact-bytes-over-stdin contract, the interpreter
// trust check, the defensive size/count/path bounds, hook
// timeout/process-group cleanup, and the absence of any on-disk helper
// artifact - most of them directly against the raw helper (bypassing
// renderer-build-identity.mjs's own wiring entirely) so a bug in that
// shared wiring can never mask a regression here.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  constants as fsConstants,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  assertTrustedSystemInterpreterOrThrow,
  computeRendererAssetDigest,
  spawnRendererAssetDigestHelper,
  systemInterpreterRejectionReason,
} from "../scripts/renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const TRUSTED_PYTHON3 = "/usr/bin/python3";
const helperPath = join(repoRoot, "scripts", "renderer-asset-digest.py");
const helperSourceBytes = readFileSync(helperPath);
const helperSourceText = helperSourceBytes.toString("utf8");
const descendantHookScript = join(here, "helpers", "renderer-asset-digest-hook-descendant.mjs");
const swapHookScript = join(here, "helpers", "renderer-asset-digest-test-hook.mjs");

function scratchDir(prefix) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  return mkdtempSync(join(repoRoot, "build", prefix));
}

/**
 * Cleans up synchronously, immediately, for an ordinary synchronous `run` -
 * but if `run` returns a promise (an async callback), defers cleanup until
 * that promise settles instead of deleting the scratch directory out from
 * under still-pending async work. A plain `try/finally` around `run(dir)`
 * would run `finally` the instant an async `run` *returns its promise*, not
 * once that promise actually settles - exactly wrong for a callback that
 * still has an `await` in flight.
 */
function withScratchDir(prefix, run) {
  const dir = scratchDir(prefix);
  const cleanup = () => rmSync(dir, { recursive: true, force: true });
  let result;
  try {
    result = run(dir);
  } catch (error) {
    cleanup();
    throw error;
  }
  if (result && typeof result.then === "function") {
    return result.finally(cleanup);
  }
  cleanup();
  return result;
}

/**
 * Runs the exact committed helper source directly via stdin, independent of
 * renderer-build-identity.mjs's own spawn plumbing - the same independent-
 * oracle pattern tests/renderer-build-identity.test.mjs's
 * collectAssetsWithPythonHelper uses.
 */
function runHelperDirectly(source, args) {
  return execFileSync(TRUSTED_PYTHON3, ["-", ...args], {
    cwd: repoRoot,
    input: source,
    encoding: "utf8",
    stdio: ["pipe", "pipe", "pipe"],
    timeout: 20_000,
  });
}

/**
 * Returns a copy of the committed helper source with exactly one literal
 * substring replaced - used only to reach a defensive bound (entry count,
 * path length, per-file size, total size) in a test-sized fixture instead
 * of an unrealistically huge one. Asserting a single occurrence means a
 * future rename of the constant fails the test loudly instead of silently
 * turning the patch into a no-op.
 */
function patchedHelperSource(literalLine, replacementLine) {
  const occurrences = helperSourceText.split(literalLine).length - 1;
  assert.equal(
    occurrences,
    1,
    `expected exactly one occurrence of ${JSON.stringify(literalLine)} in the committed helper source`,
  );
  return helperSourceText.replace(literalLine, replacementLine);
}

function afterCollectionHookArg(executable, args) {
  return Buffer.from(JSON.stringify({ executable, args }), "utf8").toString("base64");
}

test("systemInterpreterRejectionReason", async (t) => {
  await t.test("accepts a plausible root-owned, mode-0755 regular file", () => {
    const reason = systemInterpreterRejectionReason("/usr/bin/python3", {
      isSymbolicLink: () => false,
      isFile: () => true,
      uid: 0,
      mode: 0o100755,
    });
    assert.equal(reason, null);
  });

  await t.test("rejects a missing path", () => {
    assert.match(
      systemInterpreterRejectionReason("/usr/bin/python3", null),
      /does not exist/,
    );
  });

  await t.test("rejects a symlink", () => {
    assert.match(
      systemInterpreterRejectionReason("/usr/bin/python3", {
        isSymbolicLink: () => true,
        isFile: () => true,
        uid: 0,
        mode: 0o100755,
      }),
      /must not be a symlink/,
    );
  });

  await t.test("rejects a non-regular file", () => {
    assert.match(
      systemInterpreterRejectionReason("/usr/bin/python3", {
        isSymbolicLink: () => false,
        isFile: () => false,
        uid: 0,
        mode: 0o40755,
      }),
      /must be a regular file/,
    );
  });

  await t.test("rejects a non-root-owned file", () => {
    assert.match(
      systemInterpreterRejectionReason("/usr/bin/python3", {
        isSymbolicLink: () => false,
        isFile: () => true,
        uid: 501,
        mode: 0o100755,
      }),
      /must be owned by root/,
    );
  });

  await t.test("rejects a group-writable file", () => {
    assert.match(
      systemInterpreterRejectionReason("/usr/bin/python3", {
        isSymbolicLink: () => false,
        isFile: () => true,
        uid: 0,
        mode: 0o100775,
      }),
      /must not be group- or other-writable/,
    );
  });

  await t.test("rejects an other-writable file", () => {
    assert.match(
      systemInterpreterRejectionReason("/usr/bin/python3", {
        isSymbolicLink: () => false,
        isFile: () => true,
        uid: 0,
        mode: 0o100757,
      }),
      /must not be group- or other-writable/,
    );
  });

  await t.test("rejects a non-owner-executable file", () => {
    assert.match(
      systemInterpreterRejectionReason("/usr/bin/python3", {
        isSymbolicLink: () => false,
        isFile: () => true,
        uid: 0,
        mode: 0o100644,
      }),
      /must be owner-executable/,
    );
  });
});

test("assertTrustedSystemInterpreterOrThrow", async (t) => {
  await t.test("accepts the real /usr/bin/python3 on this machine", () => {
    assert.doesNotThrow(() => assertTrustedSystemInterpreterOrThrow(TRUSTED_PYTHON3));
  });

  await t.test("throws a clear error for a path that does not exist", () => {
    assert.throws(
      () => assertTrustedSystemInterpreterOrThrow("/usr/bin/this-does-not-exist-either"),
      /refusing to invoke untrusted system interpreter.*does not exist/,
    );
  });
});

test("spawnRendererAssetDigestHelper executes the exact bytes supplied over stdin, independent of any on-disk path", () => {
  withScratchDir("stdin-exact-bytes-", (scratchRoot) => {
    const scratchCopy = join(scratchRoot, "renderer-asset-digest-copy.py");
    copyFileSync(helperPath, scratchCopy);
    // No execute bit at all: if renderer-build-identity.mjs ever executed a
    // file by path instead of piping bytes via stdin, this would fail
    // immediately with EACCES.
    chmodSync(scratchCopy, 0o600);
    const sourceBytes = readFileSync(scratchCopy);
    rmSync(scratchCopy);
    assert.equal(existsSync(scratchCopy), false, "the scratch copy must really be gone");

    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "index.ts"), "content\n");

    const assets = spawnRendererAssetDigestHelper(sourceBytes, [rendererRoot]);
    assert.deepEqual(
      assets.map((asset) => asset.relativePath),
      ["index.ts"],
    );
  });
});

test("spawnRendererAssetDigestHelper runs an arbitrary custom source, not the committed helper file, proving stdin bytes (not the file on disk) are what execute", () => {
  const customSource = "import json, sys\nsys.stdout.write(json.dumps([{'relativePath': 'fixed.txt', 'sha256': '0' * 64}]))\n";
  const assets = spawnRendererAssetDigestHelper(Buffer.from(customSource, "utf8"), ["ignored-arg"]);
  assert.deepEqual(assets, [{ relativePath: "fixed.txt", sha256: "0".repeat(64) }]);
});

test("spawnRendererAssetDigestHelper rejects timeoutMs of 0 or a negative number before ever spawning", () => {
  assert.throws(
    () => spawnRendererAssetDigestHelper(helperSourceBytes, ["/tmp"], { timeoutMs: 0 }),
    /timeout must be a positive integer/,
  );
  assert.throws(
    () => spawnRendererAssetDigestHelper(helperSourceBytes, ["/tmp"], { timeoutMs: -5 }),
    /timeout must be a positive integer/,
  );
});

test("spawnRendererAssetDigestHelper reports a clear, ETIMEDOUT-aware error and kills a helper invocation that overruns Node's own outer timeout", () => {
  const sleepySource = "import time\ntime.sleep(30)\n";
  assert.throws(
    () => spawnRendererAssetDigestHelper(Buffer.from(sleepySource, "utf8"), [], { timeoutMs: 200 }),
    /did not finish within 200ms and was killed/,
  );
});

test("spawnRendererAssetDigestHelper rejects non-JSON stdout", () => {
  const source = "sys_stdout_not_imported_on_purpose = 1\nprint('not json at all')\n";
  assert.throws(
    () => spawnRendererAssetDigestHelper(Buffer.from(source, "utf8"), []),
    /returned invalid JSON/,
  );
});

test("spawnRendererAssetDigestHelper rejects JSON that is not an array", () => {
  const source = "import json, sys\nsys.stdout.write(json.dumps({'not': 'an array'}))\n";
  assert.throws(
    () => spawnRendererAssetDigestHelper(Buffer.from(source, "utf8"), []),
    /returned invalid assets/,
  );
});

test("spawnRendererAssetDigestHelper rejects array elements missing relativePath or sha256", () => {
  const source = "import json, sys\nsys.stdout.write(json.dumps([{'relativePath': 'a.txt'}]))\n";
  assert.throws(
    () => spawnRendererAssetDigestHelper(Buffer.from(source, "utf8"), []),
    /returned invalid assets/,
  );
});

test("spawnRendererAssetDigestHelper rejects a sha256 value that is not exactly 64 lowercase hex characters", () => {
  const source =
    "import json, sys\nsys.stdout.write(json.dumps([{'relativePath': 'a.txt', 'sha256': 'NOT-HEX'}]))\n";
  assert.throws(
    () => spawnRendererAssetDigestHelper(Buffer.from(source, "utf8"), []),
    /returned invalid assets/,
  );
});

test("spawnRendererAssetDigestHelper propagates a non-zero exit's stderr message", () => {
  const source = "import sys\nsys.stderr.write('deliberate helper failure\\n')\nsys.exit(1)\n";
  assert.throws(
    () => spawnRendererAssetDigestHelper(Buffer.from(source, "utf8"), []),
    /deliberate helper failure/,
  );
});

test("spawnRendererAssetDigestHelper fails clearly (never hangs, never returns truncated JSON as success) when stdout exceeds the bounded buffer", () => {
  const source = "import sys\nsys.stdout.write(chr(120) * (33 * 1024 * 1024))\n";
  assert.throws(
    () => spawnRendererAssetDigestHelper(Buffer.from(source, "utf8"), [], { timeoutMs: 10_000 }),
    /ENOBUFS|maxBuffer|descriptor-anchored renderer asset digest helper failed/,
  );
});

test("the raw helper rejects a symlinked asset present from the start (no hook/race involved)", () => {
  withScratchDir("symlink-base-case-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "index.ts"), "content\n");
    symlinkSync(join(rendererRoot, "index.ts"), join(rendererRoot, "link.ts"));
    assert.throws(
      () => runHelperDirectly(helperSourceBytes, [rendererRoot]),
      /renderer asset must not be a symlink: link\.ts/,
    );
  });
});

test("the raw helper rejects a special file (a FIFO) present from the start", () => {
  withScratchDir("fifo-base-case-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    execFileSync("/usr/bin/mkfifo", [join(rendererRoot, "fifo.ts")]);
    assert.throws(
      () => runHelperDirectly(helperSourceBytes, [rendererRoot]),
      /renderer asset must be a regular file after opening: fifo\.ts/,
    );
  });
});

test("the raw helper excludes only a top-level build-manifest.json, never a nested one of the same name", () => {
  withScratchDir("nested-manifest-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(join(rendererRoot, "assets"), { recursive: true });
    writeFileSync(join(rendererRoot, "build-manifest.json"), '{"top":"level"}\n');
    writeFileSync(join(rendererRoot, "assets", "build-manifest.json"), '{"nested":"asset"}\n');
    const assets = JSON.parse(runHelperDirectly(helperSourceBytes, [rendererRoot]));
    assert.deepEqual(
      assets.map((asset) => asset.relativePath).sort(),
      ["assets/build-manifest.json"],
      "only the exact top-level build-manifest.json is excluded; a nested file of the same name is a real asset",
    );
  });
});

test("the raw helper has no hidden-file exclusion of its own: a leading-dot asset is collected and hashed like any other", () => {
  withScratchDir("hidden-dotfile-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, ".hidden-asset"), "secret\n");
    writeFileSync(join(rendererRoot, "visible.txt"), "visible\n");
    const assets = JSON.parse(runHelperDirectly(helperSourceBytes, [rendererRoot]));
    assert.deepEqual(
      assets.map((asset) => asset.relativePath).sort(),
      [".hidden-asset", "visible.txt"],
    );
  });
});

test("the raw helper's own --after-collection-hook rejects a symlink swap, proving swap resistance is intrinsic to the helper itself, not just Node's wiring", () => {
  withScratchDir("swap-resistance-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    const assetPath = join(rendererRoot, "index.ts");
    writeFileSync(assetPath, "content\n");
    const symlinkTarget = join(scratchRoot, "outside-renderer.txt");
    writeFileSync(symlinkTarget, "must never be hashed through a renderer asset path\n");

    const hookArg = afterCollectionHookArg(process.execPath, [
      swapHookScript,
      "replace-file-with-symlink",
      assetPath,
      symlinkTarget,
    ]);
    assert.throws(
      () =>
        runHelperDirectly(helperSourceBytes, [
          rendererRoot,
          "--after-collection-hook",
          hookArg,
        ]),
      /renderer asset must not be a symlink: index\.ts/,
    );
  });
});

test("computeRendererAssetDigest byte-patched to a tiny MAX_ENTRY_COUNT rejects a fixture with too many entries", () => {
  withScratchDir("limit-entry-count-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    for (let index = 0; index < 5; index += 1) {
      writeFileSync(join(rendererRoot, `f${index}.txt`), "x");
    }
    const patchedSource = patchedHelperSource("MAX_ENTRY_COUNT = 200_000", "MAX_ENTRY_COUNT = 3");
    assert.throws(
      () => spawnRendererAssetDigestHelper(Buffer.from(patchedSource, "utf8"), [rendererRoot]),
      /exceeds the maximum entry count of 3/,
    );
  });
});

test("computeRendererAssetDigest byte-patched to a tiny MAX_RELATIVE_PATH_BYTES rejects a fixture with a too-long relative path", () => {
  withScratchDir("limit-path-bytes-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "this-name-is-long-enough.txt"), "x");
    const patchedSource = patchedHelperSource(
      "MAX_RELATIVE_PATH_BYTES = 4096",
      "MAX_RELATIVE_PATH_BYTES = 8",
    );
    assert.throws(
      () => spawnRendererAssetDigestHelper(Buffer.from(patchedSource, "utf8"), [rendererRoot]),
      /exceeds the maximum length of 8 bytes/,
    );
  });
});

test("computeRendererAssetDigest byte-patched to a tiny MAX_ASSET_BYTES rejects a fixture with a too-large single file", () => {
  withScratchDir("limit-asset-bytes-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "big.txt"), "0123456789");
    const patchedSource = patchedHelperSource(
      "MAX_ASSET_BYTES = 512 * 1024 * 1024",
      "MAX_ASSET_BYTES = 4",
    );
    assert.throws(
      () => spawnRendererAssetDigestHelper(Buffer.from(patchedSource, "utf8"), [rendererRoot]),
      /exceeds the maximum size of 4 bytes: big\.txt/,
    );
  });
});

test("computeRendererAssetDigest byte-patched to a tiny MAX_TOTAL_ASSET_BYTES rejects a fixture whose combined asset size is too large", () => {
  withScratchDir("limit-total-bytes-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "a.txt"), "abcd");
    writeFileSync(join(rendererRoot, "b.txt"), "abcd");
    const patchedSource = patchedHelperSource(
      "MAX_TOTAL_ASSET_BYTES = 4 * 1024 * 1024 * 1024",
      "MAX_TOTAL_ASSET_BYTES = 6",
    );
    assert.throws(
      () => spawnRendererAssetDigestHelper(Buffer.from(patchedSource, "utf8"), [rendererRoot]),
      /exceeds the maximum total size of 6 bytes/,
    );
  });
});

test("a hook that itself exceeds --hook-timeout-seconds is killed, with a clear error, well before its own sleep would finish", () => {
  withScratchDir("hook-own-timeout-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "index.ts"), "content\n");

    const hookArg = afterCollectionHookArg("/bin/sleep", ["30"]);
    const started = Date.now();
    assert.throws(
      () =>
        runHelperDirectly(helperSourceBytes, [
          rendererRoot,
          "--after-collection-hook",
          hookArg,
          "--deadline-seconds",
          "20",
          "--hook-timeout-seconds",
          "1",
        ]),
      /renderer asset collection hook did not finish within 1s and was killed/,
    );
    const elapsedMs = Date.now() - started;
    assert.ok(
      elapsedMs < 10_000,
      `expected the hook's own 1s timeout to fire well before its 30s sleep, took ${elapsedMs}ms`,
    );
  });
});

test("the overall --deadline-seconds preempts and cleans up a hook whose own --hook-timeout-seconds has not yet elapsed", () => {
  withScratchDir("overall-deadline-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "index.ts"), "content\n");

    const hookArg = afterCollectionHookArg("/bin/sleep", ["30"]);
    const started = Date.now();
    assert.throws(
      () =>
        runHelperDirectly(helperSourceBytes, [
          rendererRoot,
          "--after-collection-hook",
          hookArg,
          "--deadline-seconds",
          "1",
          "--hook-timeout-seconds",
          "20",
        ]),
      /descriptor-anchored renderer asset digest helper exceeded its overall deadline/,
    );
    const elapsedMs = Date.now() - started;
    assert.ok(
      elapsedMs < 10_000,
      `expected the 1s overall deadline to fire well before the hook's own 20s timeout, took ${elapsedMs}ms`,
    );
  });
});

test("a hook's own background descendant is still reaped even when the hook itself exits promptly and successfully", async () => {
  await withScratchDir("hook-descendant-", async (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "index.ts"), "content\n");
    const markerPath = join(scratchRoot, "descendant-marker.txt");

    // The hook process itself spawns a background grandchild that would
    // write markerPath after 3s, then exits immediately (selfDelayMs=0).
    const hookArg = afterCollectionHookArg(process.execPath, [
      descendantHookScript,
      markerPath,
      "3000",
      "0",
    ]);
    const assets = JSON.parse(
      runHelperDirectly(helperSourceBytes, [
        rendererRoot,
        "--after-collection-hook",
        hookArg,
        "--deadline-seconds",
        "10",
        "--hook-timeout-seconds",
        "5",
      ]),
    );
    assert.deepEqual(
      assets.map((asset) => asset.relativePath),
      ["index.ts"],
    );
    assert.equal(existsSync(markerPath), false, "the hook returned promptly; its descendant has not run yet");

    await new Promise((resolvePromise) => setTimeout(resolvePromise, 3_500));
    assert.equal(
      existsSync(markerPath),
      false,
      "the hook's process group must be terminated as a whole, reaping its background descendant, even though the hook process itself already exited successfully",
    );
  });
});

test("a real invocation creates no on-disk helper artifact anywhere under build/", () => {
  const buildRoot = join(repoRoot, "build");
  mkdirSync(buildRoot, { recursive: true });
  const before = readdirSync(buildRoot).sort();
  computeRendererAssetDigest(join(repoRoot, "renderer"));
  const after = readdirSync(buildRoot).sort();
  assert.deepEqual(after, before, "computing a real digest must not create, remove, or rename anything under build/");
});

test("an abandoned prior-design run-root directory is ignored outright: not required to be empty, not read, not deleted", () => {
  const abandonedRoot = join(repoRoot, "build", "standalone-renderer", ".renderer-asset-digest-runs");
  const abandonedFile = join(abandonedRoot, "some-abandoned-run", "leftover-file");
  mkdirSync(dirname(abandonedFile), { recursive: true });
  writeFileSync(abandonedFile, "junk left behind by a previous, deleted design\n");
  try {
    const digest = computeRendererAssetDigest(join(repoRoot, "renderer"));
    assert.match(digest, /^[0-9a-f]{64}$/);
    assert.equal(existsSync(abandonedFile), true, "an abandoned directory must be left completely untouched, not cleaned up");
  } finally {
    rmSync(join(repoRoot, "build", "standalone-renderer"), { recursive: true, force: true });
  }
});

test("fsConstants sanity: the trust check's writable/executable bit tests use the real POSIX mode bits", () => {
  // Guards the synthetic-stats tests above against a wrong hand-rolled octal
  // constant ever silently drifting from what systemInterpreterRejectionReason
  // itself imports from node:fs.
  assert.equal(fsConstants.S_IWGRP, 0o020);
  assert.equal(fsConstants.S_IWOTH, 0o002);
  assert.equal(fsConstants.S_IXUSR, 0o100);
});
