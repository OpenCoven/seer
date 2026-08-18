import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  cpSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

import {
  RENDERER_BUILD_MANIFEST_ALGORITHM,
  RENDERER_BUILD_MANIFEST_SCHEMA_VERSION,
  buildRendererBuildManifest,
  compareRendererAssetPaths,
  computeRendererAssetDigest,
  computeRendererBuildDigest,
  rendererBuildInputFiles,
} from "../scripts/renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

const HEX_SHA256 = /^[0-9a-f]{64}$/;
const assetDigestHook = join(here, "helpers", "renderer-asset-digest-test-hook.mjs");
const assetDigestHelper = join(repoRoot, "scripts", "renderer-asset-digest.py");
const buildIdentityModuleURL = pathToFileURL(
  join(repoRoot, "scripts", "renderer-build-identity.mjs"),
).href;

function afterCollectionHook(action, ...args) {
  return {
    executable: process.execPath,
    args: [assetDigestHook, action, ...args],
  };
}

function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function expectedAssetDigest(assets) {
  const manifestLines = [...assets]
    .sort((left, right) => compareRendererAssetPaths(left.relativePath, right.relativePath))
    .map((asset) => `${asset.relativePath}:${asset.sha256}\n`)
    .join("");
  return sha256Hex(Buffer.from(manifestLines, "utf8"));
}

function collectAssetsWithPythonHelper(rendererRoot) {
  // Independent oracle: this reads the helper's source bytes and pipes them to
  // `/usr/bin/python3 -` itself, deliberately not reusing
  // `spawnRendererAssetDigestHelper` from the module under test, so a bug in
  // that shared spawn plumbing cannot mask itself from this parity check.
  const source = readFileSync(assetDigestHelper);
  return JSON.parse(
    execFileSync("/usr/bin/python3", ["-", rendererRoot], {
      cwd: repoRoot,
      input: source,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    }),
  );
}

function twoAvailableLocales() {
  const available = execFileSync("locale", ["-a"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  })
    .split(/\r?\n/)
    .filter(Boolean);
  const byLowercaseName = new Map(available.map((locale) => [locale.toLowerCase(), locale]));
  const selected = [];
  for (const preferred of ["C", "en_US.UTF-8", "sv_SE.UTF-8", "de_DE.UTF-8", "tr_TR.UTF-8"]) {
    const locale = byLowercaseName.get(preferred.toLowerCase());
    if (locale && !selected.includes(locale)) selected.push(locale);
    if (selected.length === 2) return selected;
  }
  for (const locale of available) {
    if (!selected.includes(locale)) selected.push(locale);
    if (selected.length === 2) return selected;
  }
  assert.fail(`expected at least two available locales, found: ${available.join(", ") || "(none)"}`);
}

function assetDigestUnderLocale(rendererRoot, locale) {
  const program = [
    `import { computeRendererAssetDigest } from ${JSON.stringify(buildIdentityModuleURL)};`,
    `process.stdout.write(computeRendererAssetDigest(${JSON.stringify(rendererRoot)}));`,
  ].join("\n");
  return execFileSync(process.execPath, ["--input-type=module", "--eval", program], {
    cwd: repoRoot,
    encoding: "utf8",
    env: { ...process.env, LC_ALL: locale },
    stdio: ["ignore", "pipe", "pipe"],
  });
}

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
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const tmpRoot = mkdtempSync(join(repoRoot, "build", "renderer-build-identity-"));
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
    const rendererRoot = join(fixtureRepo, "renderer");
    const manifest = buildRendererBuildManifest(fixtureRepo, rendererRoot);
    assert.equal(manifest.schemaVersion, RENDERER_BUILD_MANIFEST_SCHEMA_VERSION);
    assert.equal(manifest.algorithm, RENDERER_BUILD_MANIFEST_ALGORITHM);
    assert.equal(manifest.algorithm, "sha256");
    assert.equal(manifest.sourceDigest, computeRendererBuildDigest(fixtureRepo));
    assert.equal(manifest.assetDigest, computeRendererAssetDigest(rendererRoot));
  });
});

test("computeRendererAssetDigest changes when an emitted asset changes and ignores build-manifest.json", () => {
  withFixtureCopy((fixtureRepo) => {
    const rendererRoot = join(fixtureRepo, "renderer");
    const before = computeRendererAssetDigest(rendererRoot);
    writeFileSync(join(rendererRoot, "build-manifest.json"), '{"untrusted":"self-reference"}\n');
    assert.equal(computeRendererAssetDigest(rendererRoot), before);
    writeFileSync(join(rendererRoot, "index.ts"), `${readFileSync(join(rendererRoot, "index.ts"), "utf8")}changed\n`);
    assert.notEqual(computeRendererAssetDigest(rendererRoot), before);
  });
});

test("computeRendererAssetDigest uses shared UTF-8 byte ordering for non-ASCII paths under differing locales", () => {
  withFixtureCopy((fixtureRepo) => {
    const rendererRoot = join(fixtureRepo, "renderer");
    mkdirSync(join(rendererRoot, "unicode", "中"), { recursive: true });
    for (const relativePath of [
      "unicode/B.txt",
      "unicode/a.txt",
      "unicode/z.txt",
      "unicode/ä.txt",
      "unicode/é.txt",
      "unicode/Ω.txt",
      "unicode/中/雪.txt",
    ]) {
      writeFileSync(join(rendererRoot, relativePath), `${relativePath}\n`);
    }

    const helperAssets = collectAssetsWithPythonHelper(rendererRoot);
    const helperPaths = helperAssets.map((asset) => asset.relativePath);
    assert.ok(
      helperPaths.some((relativePath) => /[^\0-\x7F]/.test(relativePath)),
      "the Python helper must collect the non-ASCII asset paths",
    );
    assert.deepEqual(
      helperPaths,
      [...helperPaths].sort(compareRendererAssetPaths),
      "the Python helper must emit the same UTF-8 byte order Node uses for asset manifests",
    );

    const expectedDigest = expectedAssetDigest(helperAssets);
    assert.equal(
      computeRendererAssetDigest(rendererRoot),
      expectedDigest,
      "Node must construct the same canonical UTF-8-byte-ordered manifest as the Python helper",
    );

    const [firstLocale, secondLocale] = twoAvailableLocales();
    assert.notEqual(firstLocale, secondLocale, "the locale-stability check requires distinct LC_ALL values");
    const firstDigest = assetDigestUnderLocale(rendererRoot, firstLocale);
    const secondDigest = assetDigestUnderLocale(rendererRoot, secondLocale);
    assert.equal(firstDigest, expectedDigest, `LC_ALL=${firstLocale} must not change the asset digest`);
    assert.equal(secondDigest, expectedDigest, `LC_ALL=${secondLocale} must not change the asset digest`);
    assert.equal(firstDigest, secondDigest, "different LC_ALL values must produce the same asset digest");
  });
});

test("computeRendererAssetDigest rejects an asset replaced by a symlink after collection", () => {
  withFixtureCopy((fixtureRepo) => {
    const rendererRoot = join(fixtureRepo, "renderer");
    const assetPath = join(rendererRoot, "index.ts");
    const symlinkTarget = join(fixtureRepo, "outside-renderer.txt");
    writeFileSync(symlinkTarget, "must never be hashed through a renderer asset path\n");

    assert.throws(
      () =>
        computeRendererAssetDigest(rendererRoot, {
          afterCollection: afterCollectionHook(
            "replace-file-with-symlink",
            assetPath,
            symlinkTarget,
          ),
        }),
      /renderer asset must not be a symlink: index\.ts/i,
    );
  });
});

test("computeRendererAssetDigest rejects an asset replaced by a different regular file after collection", () => {
  withFixtureCopy((fixtureRepo) => {
    const rendererRoot = join(fixtureRepo, "renderer");
    const assetPath = join(rendererRoot, "index.ts");
    const replacementPath = join(rendererRoot, "replacement.ts");
    writeFileSync(replacementPath, "replacement asset\n");

    assert.throws(
      () =>
        computeRendererAssetDigest(rendererRoot, {
          afterCollection: afterCollectionHook(
            "replace-file-with-file",
            replacementPath,
            assetPath,
          ),
        }),
      /renderer asset changed identity while being opened: index\.ts/i,
    );
  });
});

test("computeRendererAssetDigest rejects an asset replaced by a non-regular file after collection", () => {
  withFixtureCopy((fixtureRepo) => {
    const rendererRoot = join(fixtureRepo, "renderer");
    const assetPath = join(rendererRoot, "index.ts");

    assert.throws(
      () =>
        computeRendererAssetDigest(rendererRoot, {
          afterCollection: afterCollectionHook("replace-file-with-directory", assetPath),
        }),
      /renderer asset must be a regular file after opening: index\.ts/i,
    );
  });
});

test("computeRendererAssetDigest rejects an in-place asset mutation after collection", () => {
  withFixtureCopy((fixtureRepo) => {
    const rendererRoot = join(fixtureRepo, "renderer");
    const assetPath = join(rendererRoot, "index.ts");

    assert.throws(
      () =>
        computeRendererAssetDigest(rendererRoot, {
          afterCollection: afterCollectionHook("mutate-file", assetPath),
        }),
      /renderer asset changed identity while being opened: index\.ts/i,
    );
  });
});

test("computeRendererAssetDigest rejects a parent-directory symlink replacement even when hard-linked assets keep file identities", () => {
  withFixtureCopy((fixtureRepo) => {
    const rendererRoot = join(fixtureRepo, "renderer");
    const parentPath = join(rendererRoot, "nested");
    const originalAsset = join(parentPath, "util.ts");
    const replacementParent = join(fixtureRepo, "outside-parent");
    const replacementAsset = join(replacementParent, "util.ts");
    const parkedParent = join(rendererRoot, "nested-before-replacement");
    mkdirSync(replacementParent);
    linkSync(originalAsset, replacementAsset);

    assert.throws(
      () =>
        computeRendererAssetDigest(rendererRoot, {
          afterCollection: afterCollectionHook(
            "replace-directory-with-symlink",
            parentPath,
            parkedParent,
            replacementParent,
          ),
        }),
      /renderer asset directory must not be a symlink: nested/i,
    );
  });
});

test("computeRendererAssetDigest rejects a renderer-root symlink replacement even when every asset inode is preserved", () => {
  withFixtureCopy((fixtureRepo) => {
    const rendererRoot = join(fixtureRepo, "renderer");
    const replacementRoot = join(fixtureRepo, "outside-renderer");
    const parkedRoot = join(fixtureRepo, "renderer-before-replacement");
    mkdirSync(join(replacementRoot, "nested"), { recursive: true });
    for (const relativePath of [".DS_Store", ".hidden-source.ts", "index.ts", "nested/.DS_Store", "nested/util.ts"]) {
      linkSync(join(rendererRoot, relativePath), join(replacementRoot, relativePath));
    }

    assert.throws(
      () =>
        computeRendererAssetDigest(rendererRoot, {
          afterCollection: afterCollectionHook(
            "replace-directory-with-symlink",
            rendererRoot,
            parkedRoot,
            replacementRoot,
          ),
        }),
      /renderer root must not contain a symlink/i,
    );
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

test("the real renderer build manifest binds both checked-out source and emitted asset digests and is stable", (t) => {
  t.diagnostic("Running npm run build:standalone-renderer twice — this shells out to vite build");

  const outputDir = join(repoRoot, "build", "standalone-renderer", "Renderer");
  const manifestPath = join(outputDir, "build-manifest.json");

  // The package wrapper holds the renderer-build lock across both Vite's
  // emptyOutDir build and manifest generation. Run it twice to prove the
  // resulting manifest is stable over an unchanged source tree.
  execFileSync("npm", ["run", "build:standalone-renderer"], { cwd: repoRoot, encoding: "utf8", stdio: "pipe" });
  const firstManifestText = readFileSync(manifestPath, "utf8");

  execFileSync("npm", ["run", "build:standalone-renderer"], { cwd: repoRoot, encoding: "utf8", stdio: "pipe" });
  const secondManifestText = readFileSync(manifestPath, "utf8");

  assert.equal(
    secondManifestText,
    firstManifestText,
    "two builds over an unchanged checkout must produce a byte-identical build-manifest.json",
  );

  const manifest = JSON.parse(secondManifestText);
  assert.equal(manifest.schemaVersion, RENDERER_BUILD_MANIFEST_SCHEMA_VERSION);
  assert.equal(manifest.algorithm, "sha256");
  assert.match(manifest.sourceDigest, HEX_SHA256);
  assert.match(manifest.assetDigest, HEX_SHA256);
  assert.equal(
    manifest.sourceDigest,
    computeRendererBuildDigest(repoRoot),
    "the bundled manifest's digest must exactly match an independent recomputation over the checked-out repo",
  );
  assert.equal(
    manifest.assetDigest,
    computeRendererAssetDigest(outputDir),
    "the bundled manifest must bind every emitted asset in the published Renderer directory",
  );
  assert.ok(!("digest" in manifest), "the ambiguous schema-v1 digest field must not survive");
  assert.ok(!("builtAtEpochSeconds" in manifest), "the manifest must never carry a build timestamp");
  assert.ok(!("gitCommit" in manifest), "the manifest must never carry a git commit identity marker");
});
