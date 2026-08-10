import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

/** Absolute paths (relative to repo root) excluded from the "no Glaze" source scan. */
const EXCLUDED_SOURCE_FILES = new Set([
  "renderer/preload.ts",
  "renderer/main/index.tsx",
  "renderer/bridge/glaze-renderer-bridge.ts",
  "renderer/bridge/glaze-renderer-bridge.test.ts",
]);

const EXCLUDED_SOURCE_DIRS = ["renderer/dev"];

const FORBIDDEN_PATTERNS = [/@glaze\/core/, /glaze-core:/, /window\.glazeAPI/];

function walk(directory, out = []) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const fullPath = join(directory, entry.name);
    const relPath = relative(repoRoot, fullPath);

    if (EXCLUDED_SOURCE_DIRS.some((dir) => relPath === dir || relPath.startsWith(`${dir}/`))) {
      continue;
    }

    if (entry.isDirectory()) {
      walk(fullPath, out);
      continue;
    }

    if (!/\.(ts|tsx)$/.test(entry.name)) {
      continue;
    }
    if (EXCLUDED_SOURCE_FILES.has(relPath)) {
      continue;
    }
    out.push(relPath);
  }
  return out;
}

test("shared/standalone renderer source contains no Glaze imports or globals", () => {
  const files = walk(join(repoRoot, "renderer"));
  assert.ok(files.length > 0, "expected to find renderer source files to scan");

  const offenders = [];
  for (const relPath of files) {
    const source = readFileSync(join(repoRoot, relPath), "utf8");
    for (const pattern of FORBIDDEN_PATTERNS) {
      if (pattern.test(source)) {
        offenders.push(`${relPath} matches ${pattern}`);
      }
    }
  }

  assert.deepEqual(offenders, []);
});

test("the standalone renderer builds a production bundle with no Glaze references", (t) => {
  t.diagnostic("Running npm run build:standalone-renderer — this shells out to vite build");

  execFileSync("npm", ["run", "build:standalone-renderer"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
  });

  const outDir = join(repoRoot, "build", "standalone-renderer", "Renderer");
  assert.ok(statSync(outDir).isDirectory(), "expected build/standalone-renderer/Renderer to exist");

  function collectAll(directory, out = []) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const fullPath = join(directory, entry.name);
      if (entry.isDirectory()) {
        collectAll(fullPath, out);
      } else {
        out.push(fullPath);
      }
    }
    return out;
  }

  const outputFiles = collectAll(outDir);
  assert.ok(outputFiles.length > 0, "expected emitted files in the standalone output directory");

  const disallowedExtensions = [".map", ".ts", ".tsx"];
  const disallowed = outputFiles.filter((file) =>
    disallowedExtensions.some((ext) => file.endsWith(ext)),
  );
  assert.deepEqual(
    disallowed.map((file) => relative(repoRoot, file)),
    [],
    "no source maps or TypeScript sources should be emitted",
  );

  const htmlFiles = outputFiles.filter((file) => file.endsWith(".html"));
  assert.ok(htmlFiles.length > 0, "expected an emitted HTML entry point");

  const combined = outputFiles
    .filter((file) => /\.(html|js|css)$/.test(file))
    .map((file) => readFileSync(file, "utf8"))
    .join("\n");

  for (const pattern of FORBIDDEN_PATTERNS) {
    assert.ok(!pattern.test(combined), `emitted output must not match ${pattern}`);
  }

  for (const htmlFile of htmlFiles) {
    const html = readFileSync(htmlFile, "utf8");

    // Every asset reference must be resolvable relative to the HTML file's
    // own location (no absolute `/...` URL that would only work when served
    // from a filesystem/URL root, rather than the bundled Renderer folder).
    const assetRefs = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map((match) => match[1]);
    assert.ok(assetRefs.length > 0, "expected at least one asset reference in the emitted HTML");
    for (const ref of assetRefs) {
      assert.ok(
        !ref.startsWith("/"),
        `asset reference "${ref}" in ${relative(repoRoot, htmlFile)} must be relative, not absolute`,
      );
    }

    assert.match(
      html,
      /<meta\s+http-equiv="Content-Security-Policy"\s+content="[^"]*default-src 'self'[^"]*"/,
      "expected a production Content-Security-Policy meta tag",
    );
    assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>[^<]+<\/script>/, "no inline scripts");
  }
});
