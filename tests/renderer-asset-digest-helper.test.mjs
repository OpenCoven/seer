// Direct, low-level tests for the non-cached system-interpreter design:
// scripts/renderer-asset-digest.py itself (invoked exactly the way
// scripts/renderer-build-identity.mjs invokes it - `/usr/bin/python3 -I -`
// with the helper's own source bytes piped via stdin, never executed by a
// repository-relative pathname) and renderer-build-identity.mjs's own
// interpreter-trust/spawn seam.
//
// tests/renderer-build-identity.test.mjs already covers computeRendererAssetDigest's
// end-to-end contract (real repo digest stability, non-ASCII/locale
// ordering, top-level build-manifest.json exclusion, and the full
// swap-after-collection matrix via afterCollection). This file deliberately
// does not repeat that coverage; it instead exercises properties specific
// to *this* design - the exact-bytes-over-stdin contract, the interpreter
// trust check, the defensive size/count/path bounds, isolated-mode
// resistance to a hostile PYTHONPATH/sitecustomize/cwd shadow module, the
// declarative in-process test-action protocol, and the absence of any
// on-disk helper artifact - most of them directly against the raw helper
// (bypassing renderer-build-identity.mjs's own wiring entirely) so a bug in
// that shared wiring can never mask a regression here.
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
  sanitizedPythonEnvironment,
  spawnRendererAssetDigestHelper,
  systemInterpreterRejectionReason,
} from "../scripts/renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const TRUSTED_PYTHON3 = "/usr/bin/python3";
const helperPath = join(repoRoot, "scripts", "renderer-asset-digest.py");
const helperSourceBytes = readFileSync(helperPath);
const helperSourceText = helperSourceBytes.toString("utf8");

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
 * Replaces exactly one literal substring in `source` - used only to reach a
 * defensive bound (entry count, path length, per-file size, total size), or
 * to instrument a single specific line, in a test-sized fixture instead of
 * an unrealistically huge one. Asserting a single occurrence means a future
 * rename/reformat of the target line fails the test loudly instead of
 * silently turning the patch into a no-op. Composable: `source` need not be
 * the pristine committed text, so a second call can patch a first call's
 * own output.
 */
function withExactlyOneReplacement(source, literalLine, replacementLine) {
  const occurrences = source.split(literalLine).length - 1;
  assert.equal(
    occurrences,
    1,
    `expected exactly one occurrence of ${JSON.stringify(literalLine)} in the given source`,
  );
  return source.replace(literalLine, replacementLine);
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
  return withExactlyOneReplacement(helperSourceText, literalLine, replacementLine);
}

function testActionArg(action, args) {
  return Buffer.from(JSON.stringify({ action, args }), "utf8").toString("base64");
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

test("sanitizedPythonEnvironment keeps only its fixed allowlist, dropping every PYTHON-prefixed key, every toolchain-selection key, every DYLD_-prefixed key, and any other unrecognized key", () => {
  const sanitized = sanitizedPythonEnvironment({
    PATH: "/usr/bin:/bin",
    HOME: "/Users/real",
    TMPDIR: "/tmp/real",
    LANG: "en_US.UTF-8",
    LC_ALL: "en_US.UTF-8",
    LC_CTYPE: "en_US.UTF-8",
    PYTHONPATH: "/evil/pythonpath",
    PYTHONSTARTUP: "/evil/startup.py",
    PYTHONNOUSERSITE: "0",
    PYTHONHOME: "/evil/home",
    PYTHONSOMETHINGFUTURE: "whatever a future CPython release adds",
    DEVELOPER_DIR: "/evil/developer-dir",
    TOOLCHAINS: "com.evil.toolchain",
    SDKROOT: "/evil/sdk",
    DYLD_INSERT_LIBRARIES: "/evil/inject.dylib",
    DYLD_LIBRARY_PATH: "/evil/lib",
    DYLD_FRAMEWORK_PATH: "/evil/framework",
    DYLD_SOMETHINGFUTURE: "whatever a future dyld release adds",
    SOME_OTHER_UNRELATED_VAR: "should also be dropped",
  });
  assert.deepEqual(sanitized, {
    PATH: "/usr/bin:/bin",
    HOME: "/Users/real",
    TMPDIR: "/tmp/real",
    LANG: "en_US.UTF-8",
    LC_ALL: "en_US.UTF-8",
    LC_CTYPE: "en_US.UTF-8",
  });
});

test("sanitizedPythonEnvironment tolerates an undefined or empty source environment", () => {
  assert.deepEqual(sanitizedPythonEnvironment(undefined), {});
  assert.deepEqual(sanitizedPythonEnvironment({}), {});
});

test("computeRendererAssetDigest is unaffected by a hostile PYTHONPATH shadowing hashlib, and the shadow module never executes", () => {
  withScratchDir("hostile-pythonpath-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "index.ts"), "content\n");
    const trustedDigest = computeRendererAssetDigest(rendererRoot);

    const evilPythonPathDir = join(scratchRoot, "evil-pythonpath");
    mkdirSync(evilPythonPathDir, { recursive: true });
    const markerPath = join(scratchRoot, "hashlib-marker.txt");
    writeFileSync(
      join(evilPythonPathDir, "hashlib.py"),
      [
        `open(${JSON.stringify(markerPath)}, "w").write("EXECUTED")`,
        "class sha256:",
        "    def __init__(self, *args, **kwargs):",
        "        pass",
        "    def update(self, *args, **kwargs):",
        "        pass",
        "    def hexdigest(self):",
        "        return 'f' * 64",
        "",
      ].join("\n"),
    );

    const previousPythonPath = process.env.PYTHONPATH;
    process.env.PYTHONPATH = evilPythonPathDir;
    let digestUnderAttack;
    try {
      digestUnderAttack = computeRendererAssetDigest(rendererRoot);
    } finally {
      if (previousPythonPath === undefined) delete process.env.PYTHONPATH;
      else process.env.PYTHONPATH = previousPythonPath;
    }
    assert.equal(
      digestUnderAttack,
      trustedDigest,
      "a hostile PYTHONPATH-shadowed hashlib module must never be importable by the isolated helper",
    );
    assert.equal(
      existsSync(markerPath),
      false,
      "the hostile hashlib.py module body must never execute",
    );
  });
});

test("computeRendererAssetDigest is unaffected by a hostile cwd shadowing json, and the shadow module never executes", () => {
  withScratchDir("hostile-cwd-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "index.ts"), "content\n");
    const trustedDigest = computeRendererAssetDigest(rendererRoot);

    const markerPath = join(scratchRoot, "json-marker.txt");
    writeFileSync(
      join(scratchRoot, "json.py"),
      [
        `open(${JSON.stringify(markerPath)}, "w").write("EXECUTED")`,
        'raise SystemExit("hostile cwd-shadowed json module executed")',
        "",
      ].join("\n"),
    );

    // rendererRoot is already an absolute path, so relocating cwd never
    // changes which fixture directory is actually hashed - only whether a
    // `json.py` sitting in the new cwd is (wrongly) importable.
    const previousCwd = process.cwd();
    process.chdir(scratchRoot);
    let digestUnderAttack;
    try {
      digestUnderAttack = computeRendererAssetDigest(rendererRoot);
    } finally {
      process.chdir(previousCwd);
    }
    assert.equal(
      digestUnderAttack,
      trustedDigest,
      "a hostile cwd-shadowed json module must never be importable by the isolated helper",
    );
    assert.equal(
      existsSync(markerPath),
      false,
      "the hostile json.py module body must never execute",
    );
  });
});

test("computeRendererAssetDigest is unaffected by a hostile sitecustomize.py reachable only via a hostile HOME, and it never executes", () => {
  withScratchDir("hostile-home-", (scratchRoot) => {
    const fakeHome = join(scratchRoot, "fake-home");
    mkdirSync(fakeHome, { recursive: true });

    // Ask a real, non-isolated interpreter what user site-packages
    // directory *it* computes for this fake HOME on this machine/platform,
    // so the attack targets the exact path this Python actually consults
    // instead of a guessed, possibly stale/wrong location.
    const userSiteDir = execFileSync(
      TRUSTED_PYTHON3,
      ["-c", "import site, sys; sys.stdout.write(site.getusersitepackages())"],
      { env: { ...process.env, HOME: fakeHome }, encoding: "utf8" },
    ).trim();
    assert.ok(
      userSiteDir.startsWith(fakeHome),
      `expected the computed per-user site dir (${userSiteDir}) to live under the fake HOME (${fakeHome})`,
    );
    mkdirSync(userSiteDir, { recursive: true });
    const markerPath = join(scratchRoot, "sitecustomize-marker.txt");
    writeFileSync(
      join(userSiteDir, "sitecustomize.py"),
      `open(${JSON.stringify(markerPath)}, "w").write("EXECUTED")\n`,
    );

    // Prove this fake HOME is a live attack against a non-isolated
    // interpreter first, so a future change to Python's own per-user
    // site-lookup rules can never silently turn the rest of this test into
    // a no-op that "passes" without actually proving anything.
    execFileSync(TRUSTED_PYTHON3, ["-c", "pass"], { env: { ...process.env, HOME: fakeHome } });
    assert.equal(
      existsSync(markerPath),
      true,
      "the fake HOME fixture itself must be a real sitecustomize attack against a non-isolated interpreter",
    );
    rmSync(markerPath, { force: true });

    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "index.ts"), "content\n");
    const trustedDigest = computeRendererAssetDigest(rendererRoot);

    const previousHome = process.env.HOME;
    process.env.HOME = fakeHome;
    let digestUnderAttack;
    try {
      digestUnderAttack = computeRendererAssetDigest(rendererRoot);
    } finally {
      if (previousHome === undefined) delete process.env.HOME;
      else process.env.HOME = previousHome;
    }
    assert.equal(
      digestUnderAttack,
      trustedDigest,
      "a hostile per-user sitecustomize.py must never be importable by the isolated helper even under a hostile HOME",
    );
    assert.equal(
      existsSync(markerPath),
      false,
      "the hostile sitecustomize.py module body must never execute",
    );
  });
});

test("computeRendererAssetDigest is unaffected by a hostile DEVELOPER_DIR/TOOLCHAINS/SDKROOT/PYTHONPATH combination, and none of the attacker content they point at ever selects or executes", () => {
  withScratchDir("hostile-toolchain-env-", (scratchRoot) => {
    // A fake "developer directory" carrying its own `usr/bin/xcrun`: this is
    // exactly the shape `/usr/bin/python3`'s own dispatch shim looks for
    // once `DEVELOPER_DIR` points somewhere else (see the discussion above
    // `TRUSTED_SYSTEM_PYTHON3_PATH` in scripts/renderer-build-identity.mjs).
    // If `DEVELOPER_DIR` ever reached the child, the shim would re-exec
    // *this* attacker-controlled `xcrun` instead of the real one - so this
    // fixture writes a marker and fails loudly the moment it is ever
    // invoked with any arguments at all.
    const fakeDeveloperDir = join(scratchRoot, "fake-developer-dir");
    const fakeXcrunPath = join(fakeDeveloperDir, "usr", "bin", "xcrun");
    mkdirSync(dirname(fakeXcrunPath), { recursive: true });
    const xcrunMarkerPath = join(scratchRoot, "attacker-xcrun-marker.txt");
    writeFileSync(
      fakeXcrunPath,
      [
        "#!/bin/sh",
        `echo "ATTACKER XCRUN EXECUTED: $@" > ${JSON.stringify(xcrunMarkerPath)}`,
        'echo "attacker xcrun executed" >&2',
        "exit 1",
        "",
      ].join("\n"),
    );
    chmodSync(fakeXcrunPath, 0o755);

    // Prove this fixture is a live attack against a raw, non-isolated
    // invocation of the real system interpreter first (bypassing this
    // module's own env sanitization entirely), so a future change to how
    // `/usr/bin/python3` resolves `DEVELOPER_DIR` can never silently turn
    // the rest of this test into a no-op that "passes" without actually
    // proving anything. The fake `xcrun` above always exits non-zero, so
    // this raw invocation is expected to throw - only the marker file it
    // leaves behind (or doesn't) is under test here.
    try {
      execFileSync(TRUSTED_PYTHON3, ["-I", "-c", "print(1)"], {
        env: { DEVELOPER_DIR: fakeDeveloperDir },
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch {
      // Expected: the fake xcrun always exits non-zero.
    }
    assert.equal(
      existsSync(xcrunMarkerPath),
      true,
      "the fake DEVELOPER_DIR fixture itself must be a real attack against a raw, non-isolated /usr/bin/python3 invocation",
    );
    rmSync(xcrunMarkerPath, { force: true });

    // A hostile PYTHONPATH directory shadowing both hashlib and
    // sitecustomize, exactly like the dedicated PYTHONPATH/sitecustomize
    // tests above, combined here alongside the toolchain-selection vectors
    // so this test proves none of them - together - ever reach the child.
    const evilPythonPathDir = join(scratchRoot, "evil-pythonpath");
    mkdirSync(evilPythonPathDir, { recursive: true });
    const hashlibMarkerPath = join(scratchRoot, "attacker-hashlib-marker.txt");
    writeFileSync(
      join(evilPythonPathDir, "hashlib.py"),
      [
        `open(${JSON.stringify(hashlibMarkerPath)}, "w").write("EXECUTED")`,
        "class sha256:",
        "    def __init__(self, *args, **kwargs):",
        "        pass",
        "    def update(self, *args, **kwargs):",
        "        pass",
        "    def hexdigest(self):",
        "        return 'f' * 64",
        "",
      ].join("\n"),
    );
    const sitecustomizeMarkerPath = join(scratchRoot, "attacker-sitecustomize-marker.txt");
    writeFileSync(
      join(evilPythonPathDir, "sitecustomize.py"),
      `open(${JSON.stringify(sitecustomizeMarkerPath)}, "w").write("EXECUTED")\n`,
    );

    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "index.ts"), "content\n");
    const trustedDigest = computeRendererAssetDigest(rendererRoot);

    const hostileOverrides = {
      DEVELOPER_DIR: fakeDeveloperDir,
      TOOLCHAINS: "com.attacker.evil-toolchain",
      SDKROOT: join(scratchRoot, "evil-sdk"),
      PYTHONPATH: evilPythonPathDir,
    };
    const previousValues = {};
    for (const key of Object.keys(hostileOverrides)) {
      previousValues[key] = process.env[key];
      process.env[key] = hostileOverrides[key];
    }
    let digestUnderAttack;
    try {
      digestUnderAttack = computeRendererAssetDigest(rendererRoot);
    } finally {
      for (const key of Object.keys(hostileOverrides)) {
        if (previousValues[key] === undefined) delete process.env[key];
        else process.env[key] = previousValues[key];
      }
    }

    assert.equal(
      digestUnderAttack,
      trustedDigest,
      "a hostile DEVELOPER_DIR/TOOLCHAINS/SDKROOT/PYTHONPATH combination must never change the computed digest",
    );
    assert.equal(
      existsSync(xcrunMarkerPath),
      false,
      "a hostile DEVELOPER_DIR must never cause the child interpreter's own toolchain resolution to run an attacker-controlled xcrun",
    );
    assert.equal(
      existsSync(hashlibMarkerPath),
      false,
      "a hostile PYTHONPATH-shadowed hashlib module must never execute even alongside a hostile DEVELOPER_DIR/TOOLCHAINS/SDKROOT",
    );
    assert.equal(
      existsSync(sitecustomizeMarkerPath),
      false,
      "a hostile PYTHONPATH-reachable sitecustomize.py must never execute even alongside a hostile DEVELOPER_DIR/TOOLCHAINS/SDKROOT",
    );

    // Directly confirm none of the hostile keys - nor a DYLD_-prefixed
    // injection variable added for good measure - ever reach the child's
    // own environment in the first place, not merely that this particular
    // fixture happened to have no observable effect.
    const sanitizedUnderAttack = sanitizedPythonEnvironment({
      ...process.env,
      ...hostileOverrides,
      DYLD_INSERT_LIBRARIES: "/evil/inject.dylib",
    });
    for (const key of [
      "DEVELOPER_DIR",
      "TOOLCHAINS",
      "SDKROOT",
      "PYTHONPATH",
      "DYLD_INSERT_LIBRARIES",
    ]) {
      assert.equal(
        Object.hasOwn(sanitizedUnderAttack, key),
        false,
        `${key} must never be present in the environment handed to the child interpreter`,
      );
    }
  });
});

test("the raw helper rejects a symlinked asset present from the start (no test-action/race involved)", () => {
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

test("the raw helper's own --test-action rejects a symlink swap, proving swap resistance is intrinsic to the helper itself, not just Node's wiring", () => {
  withScratchDir("swap-resistance-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    const assetPath = join(rendererRoot, "index.ts");
    writeFileSync(assetPath, "content\n");
    const symlinkTarget = join(scratchRoot, "outside-renderer.txt");
    writeFileSync(symlinkTarget, "must never be hashed through a renderer asset path\n");

    const actionArg = testActionArg("replace-file-with-symlink", [assetPath, symlinkTarget]);
    assert.throws(
      () =>
        runHelperDirectly(helperSourceBytes, [rendererRoot, "--test-action", actionArg]),
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

test("directory_entry_names rejects a directory of far more real entries than a tiny MAX_ENTRY_COUNT without ever visiting them all", () => {
  withScratchDir("limit-entry-count-bounded-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    const realEntryCount = 50;
    for (let index = 0; index < realEntryCount; index += 1) {
      writeFileSync(join(rendererRoot, `f${index}.txt`), "x");
    }

    // Instruments the exact `names.append(entry.name)` line inside
    // directory_entry_names's os.scandir loop to also append one byte to
    // visitCounterPath every time an entry is actually visited - the only
    // way to observe, from outside the helper's own process, how many of
    // the real 50 on-disk entries were ever read before the bound fired,
    // rather than merely observing that the final error message is
    // correct (which a helper that still fully materializes the directory
    // first, then checks a count, would also produce).
    const patchedEntryCount = 5;
    const visitCounterPath = join(scratchRoot, "scandir-visit-counter");
    writeFileSync(visitCounterPath, "");
    const instrumentedSource = withExactlyOneReplacement(
      patchedHelperSource("MAX_ENTRY_COUNT = 200_000", `MAX_ENTRY_COUNT = ${patchedEntryCount}`),
      "                names.append(entry.name)\n",
      "                names.append(entry.name)\n" +
        `                with open(${JSON.stringify(visitCounterPath)}, "a") as _scandir_visit_counter:\n` +
        '                    _scandir_visit_counter.write("x")\n',
    );

    assert.throws(
      () => spawnRendererAssetDigestHelper(Buffer.from(instrumentedSource, "utf8"), [rendererRoot]),
      new RegExp(`exceeds the maximum entry count of ${patchedEntryCount}`),
    );
    const visitedEntryCount = readFileSync(visitCounterPath, "utf8").length;
    assert.ok(
      visitedEntryCount <= patchedEntryCount,
      `expected at most ${patchedEntryCount} entries to ever be appended before the bound fired, observed ${visitedEntryCount}`,
    );
    assert.ok(
      visitedEntryCount < realEntryCount,
      `expected the real ${realEntryCount}-entry directory to never be fully materialized before rejection, observed ${visitedEntryCount} visited entries`,
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

test("the overall --deadline-seconds preempts a declarative delay test action that has not yet finished", () => {
  withScratchDir("overall-deadline-", (scratchRoot) => {
    const rendererRoot = join(scratchRoot, "renderer");
    mkdirSync(rendererRoot, { recursive: true });
    writeFileSync(join(rendererRoot, "index.ts"), "content\n");

    // The "delay" test action is a plain, in-process time.sleep - there is
    // no subprocess of any kind for the helper to separately bound, so the
    // helper's own overall SIGALRM deadline (see _on_alarm/main in
    // renderer-asset-digest.py) is the only thing that can ever preempt it.
    const actionArg = testActionArg("delay", ["30"]);
    const started = Date.now();
    assert.throws(
      () =>
        runHelperDirectly(helperSourceBytes, [
          rendererRoot,
          "--test-action",
          actionArg,
          "--deadline-seconds",
          "1",
        ]),
      /descriptor-anchored renderer asset digest helper exceeded its overall deadline/,
    );
    const elapsedMs = Date.now() - started;
    assert.ok(
      elapsedMs < 10_000,
      `expected the 1s overall deadline to fire well before the requested 30s delay, took ${elapsedMs}ms`,
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
