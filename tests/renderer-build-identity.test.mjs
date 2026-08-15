import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  RENDERER_BUILD_MANIFEST_ALGORITHM,
  RENDERER_BUILD_MANIFEST_SCHEMA_VERSION,
  buildRendererBuildManifest,
  computeRendererBuildDigest,
  rendererBuildInputFiles,
} from "../scripts/renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

const HEX_SHA256 = /^[0-9a-f]{64}$/;

/**
 * A disposable copy of `tests/fixtures/renderer-build-identity/repo`,
 * mutable per-test without ever touching the real repository's own
 * `renderer/` tree. `Swift`'s `RendererBuildIdentityTests` reads the exact
 * same committed fixture (and its `expected-digest.txt` oracle) — neither
 * language restates the expected digest value, so a change to the shared
 * digest algorithm that only one implementation picks up shows up as a
 * cross-language mismatch, not a same-language tautology.
 */
function withFixtureCopy(run) {
  const fixtureSource = join(here, "fixtures", "renderer-build-identity", "repo");
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-renderer-build-identity-"));
  const fixtureRepo = join(tmpRoot, "repo");
  cpSync(fixtureSource, fixtureRepo, { recursive: true });
  try {
    return run(fixtureRepo);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
}

test("computeRendererBuildDigest is a stable, lowercase sha256 hex digest across repeated invocations over unchanged inputs", () => {
  withFixtureCopy((fixtureRepo) => {
    const first = computeRendererBuildDigest(fixtureRepo);
    const second = computeRendererBuildDigest(fixtureRepo);
    assert.match(first, HEX_SHA256, "expected a 64-character lowercase hex sha256 digest");
    assert.equal(first, second, "same inputs must produce the exact same digest every time");
  });
});

test("computeRendererBuildDigest matches the shared cross-language fixture oracle", () => {
  withFixtureCopy((fixtureRepo) => {
    const expectedDigest = readFileSync(
      join(here, "fixtures", "renderer-build-identity", "expected-digest.txt"),
      "utf8",
    ).trim();
    assert.equal(
      computeRendererBuildDigest(fixtureRepo),
      expectedDigest,
      "the JS digest must match the fixture oracle Swift's independent recomputation also reads",
    );
  });
});

test("buildRendererBuildManifest reports the expected schema version/algorithm alongside a matching digest", () => {
  withFixtureCopy((fixtureRepo) => {
    const manifest = buildRendererBuildManifest(fixtureRepo);
    assert.equal(manifest.schemaVersion, RENDERER_BUILD_MANIFEST_SCHEMA_VERSION);
    assert.equal(manifest.algorithm, RENDERER_BUILD_MANIFEST_ALGORITHM);
    assert.equal(manifest.algorithm, "sha256");
    assert.equal(manifest.digest, computeRendererBuildDigest(fixtureRepo));
  });
});

test("modifying a file under renderer/ changes the digest (stale bundle would be rejected)", () => {
  withFixtureCopy((fixtureRepo) => {
    const before = computeRendererBuildDigest(fixtureRepo);

    const rendererFile = join(fixtureRepo, "renderer", "index.ts");
    writeFileSync(rendererFile, `${readFileSync(rendererFile, "utf8")}// modified\n`);

    const after = computeRendererBuildDigest(fixtureRepo);
    assert.notEqual(after, before, "modifying tracked renderer source must change the digest");
  });
});

test("adding a new file under renderer/ changes the digest", () => {
  withFixtureCopy((fixtureRepo) => {
    const before = computeRendererBuildDigest(fixtureRepo);
    writeFileSync(join(fixtureRepo, "renderer", "new-file.ts"), "export const z = 3;\n");
    const after = computeRendererBuildDigest(fixtureRepo);
    assert.notEqual(after, before, "adding tracked renderer source must change the digest");
  });
});

test("modifying any fixed top-level input file changes the digest", () => {
  for (const relativePath of [
    "standalone-window.html",
    "vite.standalone.config.ts",
    "package.json",
    "package-lock.json",
    "tsconfig.standalone.json",
    "tsconfig.json",
  ]) {
    withFixtureCopy((fixtureRepo) => {
      const before = computeRendererBuildDigest(fixtureRepo);
      const filePath = join(fixtureRepo, relativePath);
      writeFileSync(filePath, `${readFileSync(filePath, "utf8")}\n// modified\n`);
      const after = computeRendererBuildDigest(fixtureRepo);
      assert.notEqual(after, before, `modifying ${relativePath} must change the digest`);
    });
  }
});

test("modifying the root tsconfig.json changes the digest (tsconfig.standalone.json `extends` it, so it genuinely affects how the renderer compiles)", () => {
  withFixtureCopy((fixtureRepo) => {
    const before = computeRendererBuildDigest(fixtureRepo);

    const rootTsconfigPath = join(fixtureRepo, "tsconfig.json");
    writeFileSync(rootTsconfigPath, `${readFileSync(rootTsconfigPath, "utf8")}\n// modified\n`);

    const after = computeRendererBuildDigest(fixtureRepo);
    assert.notEqual(
      after,
      before,
      "the root tsconfig.json is extended by tsconfig.standalone.json, so changing its bytes must change the digest",
    );
  });
});

test("a .DS_Store file anywhere under renderer/ (top-level or nested) never affects the digest", () => {
  withFixtureCopy((fixtureRepo) => {
    const before = computeRendererBuildDigest(fixtureRepo);

    writeFileSync(join(fixtureRepo, "renderer", ".DS_Store"), "finder metadata, never real source\n");
    writeFileSync(
      join(fixtureRepo, "renderer", "nested", ".DS_Store"),
      "finder metadata, never real source\n",
    );

    const after = computeRendererBuildDigest(fixtureRepo);
    assert.equal(
      after,
      before,
      ".DS_Store is Finder-generated metadata with no bearing on the build and must never poison the digest",
    );
  });
});

test("a hidden dotfile under renderer/ that is not .DS_Store is still treated as real build input", () => {
  withFixtureCopy((fixtureRepo) => {
    const before = computeRendererBuildDigest(fixtureRepo);

    writeFileSync(join(fixtureRepo, "renderer", ".hidden-but-intentional.ts"), "export const z = 5;\n");

    const after = computeRendererBuildDigest(fixtureRepo);
    assert.notEqual(
      after,
      before,
      "a dotfile that isn't .DS_Store may be genuine, intentionally-hidden source and must still affect the digest",
    );
  });
});

test("rendererBuildInputFiles excludes exactly-named .DS_Store files but includes other hidden files under renderer/", () => {
  withFixtureCopy((fixtureRepo) => {
    writeFileSync(join(fixtureRepo, "renderer", ".DS_Store"), "finder metadata\n");
    writeFileSync(join(fixtureRepo, "renderer", ".hidden-but-intentional.ts"), "export const z = 5;\n");

    const files = rendererBuildInputFiles(fixtureRepo);
    assert.ok(
      !files.includes("renderer/.DS_Store"),
      ".DS_Store must never be listed as a build input",
    );
    assert.ok(
      files.includes("renderer/.hidden-but-intentional.ts"),
      "a hidden dotfile that isn't .DS_Store must still be listed as a build input",
    );
  });
});

test("files outside the declared input set (not under renderer/, not one of the fixed top-level files) never affect the digest", () => {
  withFixtureCopy((fixtureRepo) => {
    const before = computeRendererBuildDigest(fixtureRepo);
    writeFileSync(join(fixtureRepo, "README.md"), "# unrelated\n");
    writeFileSync(join(fixtureRepo, "some-other-config.json"), "{}\n");
    const after = computeRendererBuildDigest(fixtureRepo);
    assert.equal(after, before, "unrelated files must never affect the build-identity digest");
  });
});

test("rendererBuildInputFiles returns only sorted, posix-relative paths — never absolute paths or backslashes", () => {
  withFixtureCopy((fixtureRepo) => {
    const files = rendererBuildInputFiles(fixtureRepo);
    assert.ok(files.length > 0);

    const sorted = [...files].sort();
    assert.deepEqual(files, sorted, "expected the returned file list to already be sorted");

    for (const relativePath of files) {
      assert.ok(!relativePath.startsWith("/"), `"${relativePath}" must not be an absolute path`);
      assert.ok(!relativePath.includes(fixtureRepo), `"${relativePath}" must not embed the repo root's absolute path`);
      assert.ok(!relativePath.includes("\\"), `"${relativePath}" must use posix "/" separators, never "\\"`);
    }
  });
});

test("the digest never embeds the repository's absolute filesystem path", () => {
  withFixtureCopy((fixtureRepo) => {
    const digest = computeRendererBuildDigest(fixtureRepo);
    assert.match(digest, HEX_SHA256);
    assert.ok(!digest.includes(fixtureRepo), "the digest itself must never contain the absolute repo path");
  });
});

test("two independent fixture copies with byte-identical relevant inputs produce the exact same digest, regardless of on-disk location", () => {
  const digests = [];
  withFixtureCopy((fixtureRepoA) => {
    digests.push(computeRendererBuildDigest(fixtureRepoA));
  });
  withFixtureCopy((fixtureRepoB) => {
    digests.push(computeRendererBuildDigest(fixtureRepoB));
  });
  assert.equal(digests[0], digests[1], "identical content at two different absolute locations must digest identically");
});

test("the real npm run build:standalone-renderer build writes a build-manifest.json whose digest matches an independent recomputation over the checked-out repo, with no timestamp/git-commit fields, and is stable across repeated builds", (t) => {
  t.diagnostic("Running npm run build:standalone-renderer twice — this shells out to vite build");

  const outputDir = join(repoRoot, "build", "standalone-renderer", "Renderer");
  const manifestPath = join(outputDir, "build-manifest.json");

  // The real build script (apps/macos/Seer/Scripts/build-standalone-renderer.sh)
  // is what Xcode actually runs; it wraps this exact same shared module.
  // Invoke that module the same way the build script does, twice in a row,
  // to prove the resulting manifest is byte-for-byte stable across builds
  // over the same (unchanged) source tree — never dependent on wall-clock
  // time or git state.
  execFileSync("npm", ["run", "build:standalone-renderer"], { cwd: repoRoot, encoding: "utf8", stdio: "pipe" });
  execFileSync(
    "node",
    [join(repoRoot, "scripts", "renderer-build-identity.mjs"), repoRoot, manifestPath],
    { cwd: repoRoot, encoding: "utf8", stdio: "pipe" },
  );
  const firstManifestText = readFileSync(manifestPath, "utf8");

  execFileSync("npm", ["run", "build:standalone-renderer"], { cwd: repoRoot, encoding: "utf8", stdio: "pipe" });
  execFileSync(
    "node",
    [join(repoRoot, "scripts", "renderer-build-identity.mjs"), repoRoot, manifestPath],
    { cwd: repoRoot, encoding: "utf8", stdio: "pipe" },
  );
  const secondManifestText = readFileSync(manifestPath, "utf8");

  assert.equal(
    secondManifestText,
    firstManifestText,
    "two builds over an unchanged checkout must produce a byte-identical build-manifest.json",
  );

  const manifest = JSON.parse(secondManifestText);
  assert.equal(manifest.schemaVersion, RENDERER_BUILD_MANIFEST_SCHEMA_VERSION);
  assert.equal(manifest.algorithm, "sha256");
  assert.match(manifest.digest, HEX_SHA256);
  assert.equal(
    manifest.digest,
    computeRendererBuildDigest(repoRoot),
    "the bundled manifest's digest must exactly match an independent recomputation over the checked-out repo",
  );
  assert.ok(!("builtAtEpochSeconds" in manifest), "the manifest must never carry a build timestamp");
  assert.ok(!("gitCommit" in manifest), "the manifest must never carry a git commit identity marker");
});
