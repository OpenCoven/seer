import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  chmodSync,
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
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { validateDmgLayout } from "../scripts/check-release-boundary.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const packageScript = join(repoRoot, "scripts", "package-macos-release.sh");
const buildRoot = join(repoRoot, "build", "macos");
const releaseRoot = join(buildRoot, "release");

function withScratch(prefix, callback) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", prefix));
  try {
    return callback(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

function writeExecutable(path, source) {
  writeFileSync(path, `#!/bin/bash\nset -euo pipefail\n${source}`);
  chmodSync(path, 0o755);
}

function completeSigningEnvironment(overrides = {}) {
  return {
    PATH: process.env.PATH,
    VERSION: "1.2.3",
    BUILD_NUMBER: "42",
    APPLE_CERTIFICATE: Buffer.from("test certificate").toString("base64"),
    APPLE_CERTIFICATE_PASSWORD: "certificate-password",
    APPLE_SIGNING_IDENTITY: "Developer ID Application: OpenCoven (ABCDEFGHIJ)",
    APPLE_TEAM_ID: "ABCDEFGHIJ",
    SOURCE_COMMIT: "a".repeat(40),
    WORKFLOW_RUN: "123",
    ...overrides,
  };
}

function runPackage(env) {
  return spawnSync("/bin/bash", [packageScript], {
    cwd: repoRoot,
    encoding: "utf8",
    env,
  });
}

function assertNoPackagingLeaves() {
  const names = existsSync(buildRoot) ? readdirSync(buildRoot) : [];
  assert.ok(!names.includes(".release-package.lock"), `unexpected packaging lock: ${names.join(", ")}`);
  assert.deepEqual(
    names.filter((name) => name.startsWith(".release-work.")),
    [],
    `unexpected private work directory: ${names.join(", ")}`,
  );
}

function makeStubTools(scratch, { notaryStatus = "Accepted" } = {}) {
  const bin = join(scratch, "bin");
  const logPath = join(scratch, "tool.log");
  const appPointer = join(scratch, "archive-app-path");
  const keychainPointer = join(scratch, "temporary-keychain-path");
  mkdirSync(bin);

  writeExecutable(join(bin, "uname"), 'printf "arm64\\n"\n');
  writeExecutable(join(bin, "openssl"), 'printf "fixed-test-keychain-password\\n"\n');
  writeExecutable(join(bin, "base64"), 'cat >/dev/null\nprintf "decoded fixture bytes"\n');
  writeExecutable(join(bin, "xcodegen"), 'printf "xcodegen\\n" >> "${SEER_STUB_LOG}"\n');
  writeExecutable(
    join(bin, "xcodebuild"),
    `
archive=""
previous=""
for argument in "$@"; do
  if [[ "\${previous}" == "-archivePath" ]]; then archive="\${argument}"; fi
  previous="\${argument}"
done
[[ -n "\${archive}" ]]
app="\${archive}/Products/Applications/Seer.app"
mkdir -p "\${app}/Contents/MacOS"
printf "stub executable\\n" > "\${app}/Contents/MacOS/Seer"
chmod +x "\${app}/Contents/MacOS/Seer"
cat > "\${app}/Contents/Info.plist" <<'PLIST'
<plist><dict></dict></plist>
PLIST
printf "%s\\n" "\${app}" > "\${SEER_STUB_APP_POINTER}"
printf "xcodebuild:%s\\n" "$*" >> "\${SEER_STUB_LOG}"
`,
  );
  writeExecutable(join(bin, "strip"), 'printf "strip\\n" >> "${SEER_STUB_LOG}"\n');
  writeExecutable(join(bin, "lipo"), 'printf "arm64\\n"\n');
  writeExecutable(
    join(bin, "security"),
    `
operation="$1"
printf "security:%s\\n" "\${operation}" >> "\${SEER_STUB_LOG}"
case "\${operation}" in
  default-keychain)
    if [[ "\${2:-}" == "-d" ]]; then
      printf '"%s"\\n' "\${SEER_STUB_ORIGINAL_KEYCHAIN}"
    fi
    ;;
  create-keychain)
    last=""
    for argument in "$@"; do last="\${argument}"; done
    : > "\${last}"
    printf "%s\\n" "\${last}" > "\${SEER_STUB_KEYCHAIN_POINTER}"
    ;;
  delete-keychain)
    last=""
    for argument in "$@"; do last="\${argument}"; done
    rm -f "\${last}"
    ;;
  find-identity)
    printf '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "%s"\\n' "\${APPLE_SIGNING_IDENTITY}"
    ;;
esac
`,
  );
  writeExecutable(
    join(bin, "codesign"),
    `
display=0
verify=0
for argument in "$@"; do
  [[ "\${argument}" == "-d" ]] && display=1
  [[ "\${argument}" == "--verify" ]] && verify=1
done
if [[ "\${display}" == 1 ]]; then
  {
    printf "Authority=%s\\n" "\${APPLE_SIGNING_IDENTITY}"
    printf "TeamIdentifier=%s\\n" "\${APPLE_TEAM_ID}"
    printf "Timestamp=Aug 15, 2026 at 9:30:00 AM\\n"
    printf "flags=0x10000(runtime)\\n"
  } >&2
elif [[ "\${verify}" == 1 ]]; then
  printf "codesign:verify\\n" >> "\${SEER_STUB_LOG}"
else
  printf "codesign:sign\\n" >> "\${SEER_STUB_LOG}"
fi
`,
  );
  writeExecutable(
    join(bin, "plutil"),
    `
case "\${2:-}" in
  CFBundleShortVersionString) printf "%s\\n" "\${VERSION}" ;;
  CFBundleVersion) printf "%s\\n" "\${BUILD_NUMBER}" ;;
  CFBundleIdentifier) printf "ai.opencoven.seer\\n" ;;
  *) exit 2 ;;
esac
`,
  );
  writeExecutable(
    join(bin, "ditto"),
    `
if [[ "\${1:-}" == "-c" ]]; then
  last=""
  for argument in "$@"; do last="\${argument}"; done
  printf "notarization zip\\n" > "\${last}"
else
  /bin/cp -R "$1" "$2"
fi
printf "ditto\\n" >> "\${SEER_STUB_LOG}"
`,
  );
  writeExecutable(
    join(bin, "xcrun"),
    `
if [[ "$1" == "notarytool" ]]; then
  printf '{"status":"%s"}\\n' "\${SEER_STUB_NOTARY_STATUS}"
  printf "notarytool\\n" >> "\${SEER_STUB_LOG}"
else
  printf "stapler:%s\\n" "\${2:-}" >> "\${SEER_STUB_LOG}"
fi
`,
  );
  writeExecutable(
    join(bin, "hdiutil"),
    `
operation="$1"
printf "hdiutil:%s\\n" "\${operation}" >> "\${SEER_STUB_LOG}"
case "\${operation}" in
  create)
    last=""
    for argument in "$@"; do last="\${argument}"; done
    printf "deterministic stub dmg\\n" > "\${last}"
    ;;
  attach)
    mountpoint=""
    previous=""
    for argument in "$@"; do
      if [[ "\${previous}" == "-mountpoint" ]]; then mountpoint="\${argument}"; fi
      previous="\${argument}"
    done
    mkdir -p "\${mountpoint}"
    app="$(cat "\${SEER_STUB_APP_POINTER}")"
    /bin/cp -R "\${app}" "\${mountpoint}/Seer.app"
    ln -s /Applications "\${mountpoint}/Applications"
    ;;
esac
`,
  );
  writeExecutable(join(bin, "spctl"), 'printf "spctl\\n" >> "${SEER_STUB_LOG}"\n');
  writeExecutable(
    join(bin, "node"),
    `
if [[ "\${1:-}" == *"/scripts/check-release-boundary.mjs" ]]; then
  printf "boundary:%s\\n" "$*" >> "\${SEER_STUB_LOG}"
  exit 0
fi
exec "\${SEER_REAL_NODE}" "$@"
`,
  );

  return {
    env: {
      ...completeSigningEnvironment(),
      PATH: `${bin}:${process.env.PATH}`,
      APPLE_API_ISSUER: "00000000-0000-0000-0000-000000000000",
      APPLE_API_KEY: "TESTKEY123",
      APPLE_API_KEY_BASE64: Buffer.from("test api key").toString("base64"),
      SEER_REAL_NODE: process.execPath,
      SEER_RENDERER_LOCK_HELD: "1",
      SEER_STUB_APP_POINTER: appPointer,
      SEER_STUB_KEYCHAIN_POINTER: keychainPointer,
      SEER_STUB_LOG: logPath,
      SEER_STUB_NOTARY_STATUS: notaryStatus,
      SEER_STUB_ORIGINAL_KEYCHAIN: join(scratch, "login.keychain-db"),
    },
    keychainPointer,
    logPath,
  };
}

test("DMG layout accepts exactly Seer.app with an optional /Applications symlink", () => {
  withScratch("release-dmg-layout-", (scratch) => {
    const app = join(scratch, "Seer.app");
    mkdirSync(app);
    assert.deepEqual(validateDmgLayout(scratch), []);

    symlinkSync("/Applications", join(scratch, "Applications"));
    assert.deepEqual(validateDmgLayout(scratch), []);
  });
});

test("DMG layout rejects missing, extra, redirected, and symlinked app entries", () => {
  withScratch("release-dmg-layout-invalid-", (scratch) => {
    assert.match(validateDmgLayout(scratch).join("\n"), /Seer\.app/);

    const app = join(scratch, "Seer.app");
    mkdirSync(app);
    writeFileSync(join(scratch, "README.txt"), "unexpected\n");
    assert.match(validateDmgLayout(scratch).join("\n"), /unexpected DMG root entry/);
    rmSync(join(scratch, "README.txt"));

    symlinkSync("/Applications/Utilities", join(scratch, "Applications"));
    assert.match(validateDmgLayout(scratch).join("\n"), /must target \/Applications/);
    rmSync(join(scratch, "Applications"));

    rmSync(app, { recursive: true });
    symlinkSync("/Applications", app);
    assert.match(validateDmgLayout(scratch).join("\n"), /real directory/);
  });
});

test("package script statically contains the complete secure release gate", () => {
  const source = readFileSync(packageScript, "utf8");

  assert.match(source, /^#!\/bin\/bash\n[\s\S]*set -euo pipefail/m);
  assert.doesNotMatch(source, /set\s+-x|set\s+-[a-zA-Z]*x/);
  assert.match(source, /trap cleanup EXIT/);
  assert.match(source, /security create-keychain/);
  assert.match(source, /security default-keychain -s/);
  assert.match(source, /security delete-keychain/);
  assert.match(source, /API_KEY_PATH="\$\{WORK_ROOT\}\/notary-api-key\.p8"/);
  assert.doesNotMatch(source, /API_KEY_PATH=.*APPLE_API_KEY/);
  assert.match(source, /xcodebuild[\s\S]*archive/);
  assert.match(source, /-derivedDataPath "\$\{DERIVED_DATA_PATH\}"/);
  assert.match(source, /MARKETING_VERSION=/);
  assert.match(source, /CURRENT_PROJECT_VERSION=/);
  assert.match(source, /--options runtime/);
  assert.match(source, /--timestamp/);
  assert.match(source, /--entitlements/);
  assert.match(source, /codesign --verify --deep --strict/);
  assert.match(source, /codesign -d --verbose=4 "\$\{WORK_DMG\}"/);
  assert.match(source, /notarytool submit[\s\S]*--wait[\s\S]*--output-format json/);
  assert.match(source, /ditto -c -k --keepParent/);
  assert.match(source, /stapler staple/);
  assert.match(source, /stapler validate/);
  assert.match(source, /hdiutil create[\s\S]*-format UDZO/);
  assert.match(source, /spctl --assess[\s\S]*SIGNED_APP/);
  assert.match(source, /spctl --assess[\s\S]*WORK_DMG/);
  assert.match(source, /check-release-boundary\.mjs/);
  assert.match(source, /write-release-manifest\.mjs/);
  assert.doesNotMatch(source, /\bgh\b|curl|git push|gh release/);
});

test("credential-free invocation names APPLE_CERTIFICATE first and creates no packaging state", () => {
  rmSync(releaseRoot, { recursive: true, force: true });
  const result = runPackage({
    PATH: process.env.PATH,
    VERSION: "1.0.0",
    BUILD_NUMBER: "1",
  });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /error: missing required signing variable APPLE_CERTIFICATE/);
  assert.ok(!existsSync(releaseRoot));
  assertNoPackagingLeaves();
});

test("version and build number are validated before credentials or side effects", () => {
  for (const [name, env, pattern] of [
    ["version", { VERSION: "v1.0.0", BUILD_NUMBER: "1" }, /VERSION must be a stable semantic version/],
    ["build", { VERSION: "1.0.0", BUILD_NUMBER: "01" }, /BUILD_NUMBER must be a positive integer/],
  ]) {
    const result = runPackage({ PATH: process.env.PATH, ...env });
    assert.notEqual(result.status, 0, name);
    assert.match(result.stderr, pattern);
    assert.doesNotMatch(result.stderr, /APPLE_CERTIFICATE/, name);
    assertNoPackagingLeaves();
  }
});

test("notarization credential sets reject none, every partial set, and both complete sets", () => {
  const signing = completeSigningEnvironment();
  const invalidCases = [
    [{}, /exactly one complete notarization credential set is required/],
    [{ APPLE_API_ISSUER: "issuer" }, /partial API-key notarization credentials/],
    [
      { APPLE_API_ISSUER: "issuer", APPLE_API_KEY: "key" },
      /partial API-key notarization credentials/,
    ],
    [{ APPLE_ID: "developer@example.com" }, /partial Apple-ID notarization credentials/],
    [
      {
        APPLE_API_ISSUER: "issuer",
        APPLE_API_KEY: "key",
        APPLE_API_KEY_BASE64: "cDg=",
        APPLE_ID: "developer@example.com",
        APPLE_PASSWORD: "app-password",
      },
      /exactly one notarization credential set; both were provided/,
    ],
  ];

  for (const [credentials, pattern] of invalidCases) {
    const result = runPackage({ ...signing, ...credentials });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, pattern);
    assertNoPackagingLeaves();
  }
});

test("stubbed API-key flow gates fixed release outputs behind every verification", () => {
  withScratch("release-package-success-", (scratch) => {
    rmSync(releaseRoot, { recursive: true, force: true });
    const { env, keychainPointer, logPath } = makeStubTools(scratch);
    const result = runPackage(env);
    assert.equal(result.status, 0, `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`);

    assert.deepEqual(readdirSync(releaseRoot).sort(), [
      "SHA256SUMS",
      "Seer-v1.2.3-arm64.dmg",
      "release-manifest.json",
    ]);
    const dmgPath = join(releaseRoot, "Seer-v1.2.3-arm64.dmg");
    const hash = createHash("sha256").update(readFileSync(dmgPath)).digest("hex");
    assert.equal(readFileSync(join(releaseRoot, "SHA256SUMS"), "utf8"), `${hash}  Seer-v1.2.3-arm64.dmg\n`);
    assert.deepEqual(JSON.parse(readFileSync(join(releaseRoot, "release-manifest.json"), "utf8")), {
      artifacts: [{ name: "Seer-v1.2.3-arm64.dmg", sha256: hash, size: 23 }],
      bundleIdentifier: "ai.opencoven.seer",
      notarization: "accepted",
      sourceCommit: "a".repeat(40),
      version: "1.2.3",
      workflowRun: "123",
    });

    const log = readFileSync(logPath, "utf8");
    assert.match(log, /xcodebuild:.*-destination generic\/platform=macOS.*ARCHS=arm64/);
    assert.match(log, /xcodebuild:.*MARKETING_VERSION=1\.2\.3/);
    assert.match(log, /xcodebuild:.*CURRENT_PROJECT_VERSION=42/);
    assert.equal((log.match(/^notarytool$/gm) ?? []).length, 2);
    assert.equal((log.match(/^boundary:/gm) ?? []).length, 2);
    assert.equal((log.match(/^spctl$/gm) ?? []).length, 2);
    assert.equal((log.match(/^security:default-keychain$/gm) ?? []).length, 3);
    assert.equal((log.match(/^security:delete-keychain$/gm) ?? []).length, 1);

    const keychainPath = readFileSync(keychainPointer, "utf8").trim();
    assert.ok(!existsSync(keychainPath), "temporary keychain must be deleted");
    assertNoPackagingLeaves();
  });
});

test("notarization rejection cleans key material, restores keychain, and publishes nothing", () => {
  withScratch("release-package-failure-", (scratch) => {
    rmSync(releaseRoot, { recursive: true, force: true });
    const { env, keychainPointer, logPath } = makeStubTools(scratch, { notaryStatus: "Invalid" });
    const result = runPackage(env);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /notarization result was not Accepted/);
    assert.ok(!existsSync(releaseRoot), "failed packaging must not create fixed release output");
    const log = readFileSync(logPath, "utf8");
    assert.equal((log.match(/^security:default-keychain$/gm) ?? []).length, 3);
    assert.equal((log.match(/^security:delete-keychain$/gm) ?? []).length, 1);
    const keychainPath = readFileSync(keychainPointer, "utf8").trim();
    assert.ok(!existsSync(keychainPath), "failure cleanup must delete the temporary keychain");
    assertNoPackagingLeaves();
  });
});
