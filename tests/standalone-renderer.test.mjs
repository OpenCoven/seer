import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  FORBIDDEN_PATTERNS,
  scanForbiddenPatterns,
  walkSourceFiles,
} from "./helpers/source-boundary-scan.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

function buildFixtureCss(fixtureRepo, outputName) {
  const outDir = join(fixtureRepo, outputName);
  execFileSync(
    join(repoRoot, "node_modules", ".bin", "vite"),
    ["build", "--config", "vite.standalone.config.ts", "--outDir", outDir],
    {
      cwd: fixtureRepo,
      encoding: "utf8",
      env: { ...process.env, SEER_RENDERER_PRIVATE_OUT_DIR: outDir },
      stdio: "pipe",
    },
  );
  return readdirSync(join(outDir, "assets"))
    .filter((name) => name.endsWith(".css"))
    .sort()
    .map((name) => readFileSync(join(outDir, "assets", name), "utf8"))
    .join("\n");
}

/** Absolute paths (relative to repo root) excluded from the "no Glaze" source scan. */
const EXCLUDED_SOURCE_FILES = new Set([
  "renderer/preload.ts",
  "renderer/main/index.tsx",
  "renderer/bridge/glaze-renderer-bridge.ts",
  "renderer/bridge/glaze-renderer-bridge.test.ts",
]);

const EXCLUDED_SOURCE_DIRS = ["renderer/dev"];

test("shared/standalone renderer source contains no Glaze imports or globals", () => {
  const files = walkSourceFiles(join(repoRoot, "renderer"), {
    root: repoRoot,
    excludedDirs: EXCLUDED_SOURCE_DIRS,
    excludedFiles: EXCLUDED_SOURCE_FILES,
  });
  assert.ok(files.length > 0, "expected to find renderer source files to scan");
  assert.ok(
    files.some((file) => file.endsWith(".css")),
    "expected the source boundary scan to include .css files",
  );

  const offenders = scanForbiddenPatterns(files, repoRoot);

  assert.deepEqual(offenders, []);
});

test("shared renderer CSS marks interactive controls inside drag regions/toolbars as no-drag", () => {
  const css = readFileSync(join(repoRoot, "renderer", "styles.css"), "utf8");

  // The draggable-region rule itself must still exist...
  assert.match(css, /\.drag-region\s*\{[^}]*-webkit-app-region:\s*drag/);

  // ...and every interactive-control selector scoped under `.drag-region`
  // and `[data-toolbar]` must be paired with `-webkit-app-region: no-drag`
  // in the same rule, so clicks on buttons/radios/etc. reach the control
  // instead of being swallowed as a window-drag gesture.
  const noDragRuleMatch = css.match(
    /((?:\.drag-region|\[data-toolbar\])[^{]*\{[^}]*-webkit-app-region:\s*no-drag[^}]*\})/,
  );
  assert.ok(noDragRuleMatch, "expected a no-drag rule scoped to .drag-region/[data-toolbar]");
  const [noDragRule] = noDragRuleMatch;

  for (const scope of [".drag-region", "[data-toolbar]"]) {
    for (const selector of ["button", '[role="radio"]']) {
      assert.ok(
        noDragRule.includes(`${scope} ${selector}`),
        `expected the no-drag rule to include selector "${scope} ${selector}"`,
      );
    }
  }
});

test("the standalone renderer's shell CSS fills the native window (html/body/#root height:100%, no body margin, shell overflow hidden) while staying transparent", () => {
  const css = readFileSync(join(repoRoot, "renderer", "standalone", "styles.css"), "utf8");

  const htmlBodyRootRuleMatch = css.match(/html,\s*body,\s*#root\s*\{([^}]*)\}/);
  assert.ok(htmlBodyRootRuleMatch, "expected a combined html, body, #root rule");
  const [, htmlBodyRootRule] = htmlBodyRootRuleMatch;
  assert.match(htmlBodyRootRule, /height:\s*100%/, "html/body/#root must fill the native window");
  assert.match(
    htmlBodyRootRule,
    /background:\s*transparent/,
    "html/body/#root must keep the transparent native window background",
  );

  const bodyRuleMatch = css.match(/(?<!html,\s*)body\s*\{([^}]*)\}/);
  assert.ok(bodyRuleMatch, "expected a standalone-specific body rule");
  const [, bodyRule] = bodyRuleMatch;
  assert.match(bodyRule, /margin:\s*0/, "body must have no default margin");
  assert.match(
    bodyRule,
    /overflow:\s*hidden/,
    "the shell (body) must not scroll — only the panel's own scroll area should own overflow",
  );

  // The panel's own scrollable content area (not the shell) owns overflow.
  const primitivesSource = readFileSync(join(repoRoot, "renderer", "ui", "primitives.tsx"), "utf8");
  assert.match(
    primitivesSource,
    /overflow-y-auto/,
    "ScrollPanel's content region must own its own vertical overflow",
  );
});

test("the source boundary scan rejects Glaze references found in CSS, not just TS/TSX", () => {
  // Proves CSS is genuinely included in the scan (not just .ts/.tsx) using a
  // disposable fixture directory under the OS tmpdir — never inside
  // `renderer/`, so this can never leak a forbidden-pattern file into
  // production sources (even if cleanup failed) or race with another test
  // run scanning the same repo path in parallel. `mkdtempSync` guarantees a
  // unique directory per invocation.
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-css-scan-"));
  const fixtureFile = join(tmpRoot, "forbidden.css");
  writeFileSync(fixtureFile, "body { color: red; } /* window.glazeAPI */\n");

  try {
    const files = walkSourceFiles(tmpRoot, { root: tmpRoot });
    assert.ok(files.includes("forbidden.css"), "expected the CSS fixture to be picked up by the scan");

    const offenders = scanForbiddenPatterns(files, tmpRoot);
    assert.ok(
      offenders.some((offender) => offender.startsWith("forbidden.css")),
      "expected the CSS fixture's forbidden Glaze reference to be flagged",
    );
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
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

test("Tailwind ignores class content outside declared renderer inputs but responds to renderer source", () => {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "tailwind-source-scope-test-"));
  const fixtureRepo = join(scratch, "repo");
  try {
    mkdirSync(fixtureRepo);
    cpSync(join(repoRoot, "renderer"), join(fixtureRepo, "renderer"), { recursive: true });
    cpSync(join(repoRoot, "standalone-window.html"), join(fixtureRepo, "standalone-window.html"));
    cpSync(
      join(repoRoot, "vite.standalone.config.ts"),
      join(fixtureRepo, "vite.standalone.config.ts"),
    );

    const baseline = buildFixtureCss(fixtureRepo, "out-baseline");
    writeFileSync(
      join(fixtureRepo, "outside-only.tsx"),
      'export const outside = <div className="bg-[#123456]" />;\n',
    );
    const outsideOnly = buildFixtureCss(fixtureRepo, "out-outside");
    assert.equal(
      outsideOnly,
      baseline,
      "a repository file outside the declared Tailwind/digest input scope must not alter emitted CSS",
    );

    writeFileSync(
      join(fixtureRepo, "renderer", "tailwind-source-probe.tsx"),
      'export const inside = <div className="text-[#abcdef]" />;\n',
    );
    const rendererChanged = buildFixtureCss(fixtureRepo, "out-renderer");
    assert.notEqual(
      rendererChanged,
      baseline,
      "a declared renderer TSX source must alter emitted CSS when it adds a class",
    );
    assert.match(rendererChanged, /#abcdef/i);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
