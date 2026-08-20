import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

/**
 * `main/services/tray.ts` builds its context menu with `Menu`/`Tray` from
 * `@glaze/core/backend`, which wraps real Electron classes that only work
 * inside a running Electron main process — there is no lightweight way to
 * construct/click a native `MenuItemConstructorOptions` outside of it, so
 * (consistent with the "UpdateService is constructed with the real packaged
 * app version" characterization test in tests/identity.test.mjs) this
 * verifies the fix by scanning the source for the exact failure-handling
 * shape rather than executing the click handler.
 */

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

function readText(relativePath) {
  return readFileSync(join(repoRoot, relativePath), "utf8");
}

test("tray's 'View Seer <version>' menu item attaches .catch to openCurrentRelease() so a rejection (e.g. shell.openExternal failing) cannot escape as an unhandled rejection", () => {
  const source = readText("main/services/tray.ts");

  const viewReleaseItemMatch = source.match(
    /label: `View Seer \$\{latestUpdate\.availableVersion\}`,\s*\n\s*click: \(\) => \{([\s\S]*?)\n\s*\},/,
  );
  assert.ok(viewReleaseItemMatch, "Expected to find the 'View Seer <version>' menu item's click handler in main/services/tray.ts");

  const clickBody = viewReleaseItemMatch[1];
  assert.match(
    clickBody,
    /void updateService\.openCurrentRelease\(\)\s*\.catch\(/,
    "The 'View Seer <version>' click handler must chain .catch onto openCurrentRelease() — an unhandled rejection here (e.g. from shell.openExternal) can terminate the Node 24 process",
  );
  assert.match(
    clickBody,
    /logger\.error\(\s*"tray"/,
    "The .catch handler must log through the same logger.error(\"tray\", ...) convention used by the other tray menu handlers (selectKeepAwakeMode, the prerelease toggle)",
  );
});

test("the prerelease-toggle tray menu handler (the existing sibling convention this fix follows) also guards against unhandled rejections", () => {
  const source = readText("main/services/tray.ts");

  const toggleItemMatch = source.match(
    /label: "Include Prerelease Updates",[\s\S]*?click: \(\) => \{([\s\S]*?)\n\s*\},/,
  );
  assert.ok(toggleItemMatch, "Expected to find the 'Include Prerelease Updates' menu item's click handler in main/services/tray.ts");

  const clickBody = toggleItemMatch[1];
  assert.match(
    clickBody,
    /\.catch\(\s*\(error: unknown\) => \{\s*\n\s*logger\.error\("tray"/,
    "The prerelease toggle handler is the established convention: void ...().catch((error: unknown) => logger.error(\"tray\", ...))",
  );
});
