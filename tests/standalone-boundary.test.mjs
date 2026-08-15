import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  BUNDLE_FORBIDDEN_NAME_PATTERNS,
  checkArchitecture,
  checkEntitlements,
  checkExactlyOneMachO,
  checkInfoPlist,
  checkOtoolDependencies,
  classifyMachOFiles,
  DEFAULT_APP_PATH,
  EXPECTED_EXECUTABLE_RELATIVE_PATH,
  parseOtoolDependencies,
  scanBundle,
  scanFilesForForbiddenPatterns,
  scanSourceBoundary,
  SOURCE_FORBIDDEN_PATTERNS,
  walkBundle,
} from "../scripts/check-standalone-boundary.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

/** Writes a minimal but real `mach_header_64` (see `<mach-o/loader.h>`) — enough for `/usr/bin/file` to classify it as Mach-O. */
function writeFakeMachO(path, { cputype = 0x0100000c /* ARM64 */, filetype = 2 /* MH_EXECUTE */ } = {}) {
  const buf = Buffer.alloc(32);
  buf.writeUInt32LE(0xfeedfacf, 0); // 64-bit magic
  buf.writeUInt32LE(cputype, 4);
  buf.writeUInt32LE(0, 8); // cpusubtype
  buf.writeUInt32LE(filetype, 12);
  writeFileSync(path, buf);
}

const CPUTYPE_X86_64 = 0x01000007;

test("generated Xcode project and native build output stay gitignored", () => {
  const candidatePaths = [
    "apps/macos/Seer/Seer.xcodeproj/project.pbxproj",
    "apps/macos/Seer/build/some-derived-data-file",
    "DerivedData/some-file",
    "apps/macos/Seer/DerivedData/some-file",
    "build/macos/unsigned/Seer.app",
    "build/macos/derived-data/some-file",
    "build/standalone-renderer/Renderer/index.html",
    "release.xcarchive",
    "release.dmg",
    "apps/macos/Seer/notarization/upload.log",
    "apps/macos/Seer/release-staging/Seer.app",
  ];

  for (const candidate of candidatePaths) {
    assert.doesNotThrow(
      () => execFileSync("git", ["check-ignore", "-q", candidate], { cwd: repoRoot }),
      `expected "${candidate}" to be gitignored`,
    );
  }
});

test("standalone-safe source contains no @glaze/core, .glaze-core, glaze-core:, window.glazeAPI, or Glaze SDK binary paths", () => {
  const offenders = scanSourceBoundary(repoRoot);
  assert.deepEqual(offenders, []);
});

test("the source pattern scan flags each forbidden Glaze reference when present", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-source-boundary-"));
  try {
    mkdirSync(join(tmpRoot, "renderer"), { recursive: true });
    writeFileSync(join(tmpRoot, "renderer", "offender.ts"), 'import x from "@glaze/core";\n');
    writeFileSync(join(tmpRoot, "clean.ts"), "export const clean = true;\n");

    const offenders = scanFilesForForbiddenPatterns(
      ["renderer/offender.ts", "clean.ts"],
      tmpRoot,
      SOURCE_FORBIDDEN_PATTERNS,
    );

    assert.equal(offenders.length, 1);
    assert.match(offenders[0], /renderer\/offender\.ts/);
    assert.match(offenders[0], /@glaze\/core/);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("the bundle walker rejects a symlink anywhere in the bundle", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-bundle-symlink-"));
  try {
    mkdirSync(join(tmpRoot, "Contents", "MacOS"), { recursive: true });
    writeFakeMachO(join(tmpRoot, "Contents", "MacOS", "Seer"));
    symlinkSync("/usr/lib/libSystem.B.dylib", join(tmpRoot, "Contents", "MacOS", "sneaky-link"));

    const { offenders } = walkBundle(tmpRoot);
    assert.ok(
      offenders.some((offender) => offender.includes("sneaky-link") && offender.includes("symlink")),
      `expected a symlink offender, got: ${JSON.stringify(offenders)}`,
    );
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("the bundle walker rejects forbidden names/extensions: source maps, TS sources, native addons, Node executables, Glaze-named files, fixtures, and lockfiles", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-bundle-names-"));
  try {
    const resources = join(tmpRoot, "Contents", "Resources");
    mkdirSync(join(resources, "Fixtures"), { recursive: true });
    writeFileSync(join(resources, "app.js.map"), "{}");
    writeFileSync(join(resources, "leftover.ts"), "export {};");
    writeFileSync(join(resources, "addon.node"), "binary");
    writeFileSync(join(resources, "node"), "binary");
    writeFileSync(join(resources, "GlazeHelper.txt"), "text");
    writeFileSync(join(resources, "Fixtures", "sample.json"), "{}");
    writeFileSync(join(resources, "package-lock.json"), "{}");
    writeFileSync(join(resources, "clean.html"), "<html></html>");

    const { offenders } = walkBundle(tmpRoot);
    const offenderText = offenders.join("\n");

    for (const name of [
      "app.js.map",
      "leftover.ts",
      "addon.node",
      "Contents/Resources/node",
      "GlazeHelper.txt",
      "Fixtures/sample.json",
      "package-lock.json",
    ]) {
      assert.ok(offenderText.includes(name), `expected an offender mentioning "${name}", got:\n${offenderText}`);
    }
    assert.ok(!offenderText.includes("clean.html"), "clean.html must not be flagged");
    assert.ok(BUNDLE_FORBIDDEN_NAME_PATTERNS.length > 0);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("the bundle walker rejects absolute /Users/ paths, the current home directory, and @glaze/core content leaks", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-bundle-content-"));
  try {
    const resources = join(tmpRoot, "Contents", "Resources");
    mkdirSync(resources, { recursive: true });
    writeFileSync(join(resources, "manifest.json"), '{"path":"/Users/someone/project/seer"}');
    writeFileSync(join(resources, "home.txt"), `built at ${homedir()}/checkout\n`);
    writeFileSync(join(resources, "bridge.js"), 'import x from "@glaze/core";\n');
    writeFileSync(join(resources, "scheme.js"), 'fetch("glaze-core://resource")\n');
    writeFileSync(join(resources, "clean.json"), '{"ok":true}');

    const { offenders } = walkBundle(tmpRoot);
    const offenderText = offenders.join("\n");

    assert.match(offenderText, /manifest\.json.*absolute \/Users\/ path/);
    assert.match(offenderText, /home\.txt.*home directory/);
    assert.match(offenderText, /bridge\.js.*@glaze\/core/);
    assert.match(offenderText, /scheme\.js.*glaze-core:/);
    assert.ok(!offenderText.includes("clean.json"), "clean.json must not be flagged");
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("classifyMachOFiles + checkExactlyOneMachO require exactly one Mach-O file, at Contents/MacOS/Seer", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-macho-count-"));
  try {
    mkdirSync(join(tmpRoot, "Contents", "MacOS"), { recursive: true });
    mkdirSync(join(tmpRoot, "Contents", "Frameworks"), { recursive: true });
    writeFileSync(join(tmpRoot, "Contents", "PkgInfo"), "APPL????");

    // Case 1: zero Mach-O files.
    {
      const { offenders } = checkExactlyOneMachO(classifyMachOFiles(tmpRoot, ["Contents/PkgInfo"]), EXPECTED_EXECUTABLE_RELATIVE_PATH);
      assert.equal(offenders.length, 1);
      assert.match(offenders[0], /found 0/);
    }

    writeFakeMachO(join(tmpRoot, "Contents", "MacOS", "Seer"));

    // Case 2: exactly one, at the right place.
    {
      const { offenders, entry } = checkExactlyOneMachO(
        classifyMachOFiles(tmpRoot, ["Contents/PkgInfo", "Contents/MacOS/Seer"]),
        EXPECTED_EXECUTABLE_RELATIVE_PATH,
      );
      assert.deepEqual(offenders, []);
      assert.equal(entry.relPath, "Contents/MacOS/Seer");
    }

    // Case 3: a second embedded Mach-O (a renamed embedded runtime) must be rejected.
    writeFakeMachO(join(tmpRoot, "Contents", "Frameworks", "EmbeddedRuntime"));
    {
      const { offenders } = checkExactlyOneMachO(
        classifyMachOFiles(tmpRoot, ["Contents/PkgInfo", "Contents/MacOS/Seer", "Contents/Frameworks/EmbeddedRuntime"]),
        EXPECTED_EXECUTABLE_RELATIVE_PATH,
      );
      assert.equal(offenders.length, 1);
      assert.match(offenders[0], /found 2/);
    }
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("checkExactlyOneMachO rejects a single Mach-O found at the wrong bundle path", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-macho-wrong-path-"));
  try {
    mkdirSync(join(tmpRoot, "Contents", "Helpers"), { recursive: true });
    writeFakeMachO(join(tmpRoot, "Contents", "Helpers", "Seer"));

    const { offenders, entry } = checkExactlyOneMachO(
      classifyMachOFiles(tmpRoot, ["Contents/Helpers/Seer"]),
      EXPECTED_EXECUTABLE_RELATIVE_PATH,
    );
    assert.equal(entry, null);
    assert.equal(offenders.length, 1);
    assert.match(offenders[0], /Contents\/Helpers\/Seer/);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("checkArchitecture requires a 64-bit arm64 executable, not x86_64 or another type", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-arch-"));
  try {
    const arm64Path = join(tmpRoot, "arm64bin");
    const x86Path = join(tmpRoot, "x86bin");
    writeFakeMachO(arm64Path, { cputype: 0x0100000c });
    writeFakeMachO(x86Path, { cputype: CPUTYPE_X86_64 });

    const [arm64Entry] = classifyMachOFiles(tmpRoot, ["arm64bin"]);
    const [x86Entry] = classifyMachOFiles(tmpRoot, ["x86bin"]);

    assert.deepEqual(checkArchitecture(arm64Entry), []);
    const x86Offenders = checkArchitecture(x86Entry);
    assert.equal(x86Offenders.length, 1);
    assert.match(x86Offenders[0], /arm64/);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("parseOtoolDependencies allows only /System/Library and /usr/lib, and rejects @rpath embedded frameworks", () => {
  const clean = [
    "/some/path/to/Seer:",
    "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)",
    "\t/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (compatibility version 45.0.0, current version 100.0.0)",
  ].join("\n");
  assert.deepEqual(parseOtoolDependencies(clean), []);

  const rpathEmbedded = [
    "/some/path/to/Seer:",
    "\t@rpath/EmbeddedRuntime.framework/Versions/A/EmbeddedRuntime (compatibility version 1.0.0, current version 1.0.0)",
  ].join("\n");
  const rpathOffenders = parseOtoolDependencies(rpathEmbedded);
  assert.equal(rpathOffenders.length, 1);
  assert.match(rpathOffenders[0], /@rpath/);

  const outsideAllowlist = [
    "/some/path/to/Seer:",
    "\t/opt/homebrew/lib/libsomething.dylib (compatibility version 1.0.0, current version 1.0.0)",
  ].join("\n");
  const outsideOffenders = parseOtoolDependencies(outsideAllowlist);
  assert.equal(outsideOffenders.length, 1);
  assert.match(outsideOffenders[0], /outside \/System\/Library and \/usr\/lib/);
});

test("scanBundle composes the walk and Mach-O/otool checks into a single clean pass on a well-formed synthetic bundle", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-scan-bundle-clean-"));
  try {
    mkdirSync(join(tmpRoot, "Contents", "MacOS"), { recursive: true });
    mkdirSync(join(tmpRoot, "Contents", "Resources"), { recursive: true });
    writeFakeMachO(join(tmpRoot, "Contents", "MacOS", "Seer"));
    writeFileSync(join(tmpRoot, "Contents", "Resources", "clean.html"), "<html></html>");

    // The fake executable has zero load commands, so otool -L reports no
    // dependencies at all — trivially within the allowlist.
    const offenders = scanBundle(tmpRoot);
    assert.deepEqual(offenders, []);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("checkInfoPlist validates bundle id, executable name, minimum system version, and accessory (LSUIElement) identity", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-info-plist-"));
  try {
    const contentsDir = join(tmpRoot, "Contents");
    mkdirSync(contentsDir, { recursive: true });
    execFileSync("/usr/bin/plutil", [
      "-create",
      "xml1",
      join(contentsDir, "Info.plist"),
    ]);
    const set = (key, type, value) =>
      execFileSync("/usr/bin/plutil", ["-replace", key, `-${type}`, value, join(contentsDir, "Info.plist")]);
    set("CFBundleIdentifier", "string", "ai.opencoven.seer");
    set("CFBundleExecutable", "string", "Seer");
    set("LSMinimumSystemVersion", "string", "14.0");
    set("LSUIElement", "bool", "true");

    assert.deepEqual(checkInfoPlist(tmpRoot), []);

    set("CFBundleIdentifier", "string", "com.example.wrong");
    const offenders = checkInfoPlist(tmpRoot);
    assert.equal(offenders.length, 1);
    assert.match(offenders[0], /CFBundleIdentifier/);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

/**
 * Builds a minimal but real, `codesign`-recognizable `.app` bundle (a
 * proper `Contents/Info.plist` plus a real Mach-O executable — `codesign`
 * rejects the 32-byte `writeFakeMachO` header used elsewhere in this file
 * with "bundle format unrecognized", since it lacks real load commands)
 * under a fresh temp directory, ad-hoc-signs it (optionally with a given
 * entitlements plist), and returns its path. Ad-hoc signing (`-s -`) needs
 * no certificate/keychain access and never touches this repository's own
 * build output — it exists purely so `checkEntitlements`'s `codesign`
 * calls have something realistic to inspect.
 */
function buildSignedFixtureBundle(baseDir, { entitlementsPath } = {}) {
  const appDir = join(baseDir, "Seer.app");
  mkdirSync(join(appDir, "Contents", "MacOS"), { recursive: true });
  copyFileSync("/bin/cat", join(appDir, "Contents", "MacOS", "Seer"));
  writeFileSync(
    join(appDir, "Contents", "Info.plist"),
    '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>CFBundleExecutable</key>\n\t<string>Seer</string>\n\t<key>CFBundleIdentifier</key>\n\t<string>ai.opencoven.seer.fixture</string>\n\t<key>CFBundlePackageType</key>\n\t<string>APPL</string>\n</dict>\n</plist>\n',
  );

  const codesignArgs = ["-s", "-", "-f"];
  if (entitlementsPath) {
    codesignArgs.push("--entitlements", entitlementsPath);
  }
  codesignArgs.push(appDir);
  execFileSync("/usr/bin/codesign", codesignArgs, { encoding: "utf8", stdio: "pipe" });

  return appDir;
}

test("checkEntitlements passes a signed bundle with no entitlements at all (the unsigned-build ad-hoc-linker-signed case)", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-entitlements-none-"));
  try {
    const appDir = buildSignedFixtureBundle(tmpRoot);
    const cleanEntitlementsPath = join(tmpRoot, "clean.entitlements");
    writeFileSync(
      cleanEntitlementsPath,
      '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n</dict>\n</plist>\n',
    );

    assert.deepEqual(checkEntitlements(appDir, { sourceEntitlementsPath: cleanEntitlementsPath }), []);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("checkEntitlements flags an effective App Sandbox entitlement embedded in a signed bundle", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-entitlements-sandbox-"));
  try {
    const sandboxEntitlementsPath = join(tmpRoot, "sandboxed.entitlements");
    writeFileSync(
      sandboxEntitlementsPath,
      '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>com.apple.security.app-sandbox</key>\n\t<true/>\n</dict>\n</plist>\n',
    );
    const appDir = buildSignedFixtureBundle(tmpRoot, { entitlementsPath: sandboxEntitlementsPath });

    const offenders = checkEntitlements(appDir, {});
    assert.equal(offenders.length, 1);
    assert.match(offenders[0], /app-sandbox/);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("checkEntitlements flags an app-sandbox entry in the source entitlements file even when the effective bundle has none", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-entitlements-source-"));
  try {
    const appDir = buildSignedFixtureBundle(tmpRoot);
    const sandboxEntitlementsPath = join(tmpRoot, "sandboxed.entitlements");
    writeFileSync(
      sandboxEntitlementsPath,
      '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>com.apple.security.app-sandbox</key>\n\t<true/>\n</dict>\n</plist>\n',
    );

    const offenders = checkEntitlements(appDir, { sourceEntitlementsPath: sandboxEntitlementsPath });
    assert.equal(offenders.length, 1);
    assert.match(offenders[0], /source entitlements file/);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("checkEntitlements never silently passes an unrecognizable bundle (an ambiguous codesign outcome is always an offender)", () => {
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-entitlements-unrecognized-"));
  try {
    // No Contents/Info.plist, no Mach-O — codesign refuses to inspect
    // this at all ("bundle format unrecognized"), which must never be
    // mistaken for the valid "signed, no entitlements" pass case.
    mkdirSync(tmpRoot, { recursive: true });
    const offenders = checkEntitlements(tmpRoot, {});
    assert.equal(offenders.length, 1);
    assert.match(offenders[0], /unable to inspect effective entitlements/);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});

test("the repository's real entitlements file declares no App Sandbox entitlement", () => {
  const sourceEntitlementsPath = join(repoRoot, "apps", "macos", "Seer", "Config", "Seer.entitlements");
  const tmpRoot = mkdtempSync(join(tmpdir(), "seer-real-entitlements-"));
  try {
    const appDir = buildSignedFixtureBundle(tmpRoot);
    assert.deepEqual(checkEntitlements(appDir, { sourceEntitlementsPath }), []);
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
});


test("npm run build:macos produces an unsigned arm64 Release Seer.app that passes every boundary check", (t) => {
  t.diagnostic("Running npm run build:macos — this shells out to xcodegen and xcodebuild and can take a few minutes");

  execFileSync("npm", ["run", "build:macos"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
    timeout: 15 * 60 * 1000,
  });

  assert.equal(DEFAULT_APP_PATH, join(repoRoot, "build", "macos", "unsigned", "Seer.app"));

  const executablePath = join(DEFAULT_APP_PATH, EXPECTED_EXECUTABLE_RELATIVE_PATH);
  const fileOutput = execFileSync("/usr/bin/file", ["-b", executablePath], { encoding: "utf8" });
  assert.match(fileOutput, /Mach-O 64-bit executable arm64/);

  const bundleOffenders = scanBundle(DEFAULT_APP_PATH);
  assert.deepEqual(bundleOffenders, [], `bundle boundary offenders: ${JSON.stringify(bundleOffenders, null, 2)}`);

  const otoolOffenders = checkOtoolDependencies(executablePath);
  assert.deepEqual(otoolOffenders, [], `otool -L offenders: ${JSON.stringify(otoolOffenders, null, 2)}`);

  const plistOffenders = checkInfoPlist(DEFAULT_APP_PATH);
  assert.deepEqual(plistOffenders, [], `Info.plist offenders: ${JSON.stringify(plistOffenders, null, 2)}`);

  const sourceEntitlementsPath = join(repoRoot, "apps", "macos", "Seer", "Config", "Seer.entitlements");
  const entitlementsOffenders = checkEntitlements(DEFAULT_APP_PATH, { sourceEntitlementsPath });
  assert.deepEqual(
    entitlementsOffenders,
    [],
    `entitlements offenders: ${JSON.stringify(entitlementsOffenders, null, 2)}`,
  );

  execFileSync("node", ["scripts/check-standalone-boundary.mjs"], { cwd: repoRoot, encoding: "utf8", stdio: "pipe" });
});
