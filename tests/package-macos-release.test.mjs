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
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { validateDmgLayout } from "../scripts/check-release-boundary.mjs";
import {
  computeAppDigest,
  listStandaloneSourceFiles,
} from "../scripts/check-standalone-boundary.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const prepareScript = join(repoRoot, "scripts", "prepare-macos-release-input.sh");
const packageScript = join(repoRoot, "scripts", "package-macos-release.sh");
const releaseInputTool = join(repoRoot, "scripts", "macos-release-input.py");
const buildRoot = join(repoRoot, "build", "macos");
const releaseInputRoot = join(buildRoot, "release-input");
const releaseRoot = join(buildRoot, "release");
const signingIdentity = "Developer ID Application: OpenCoven (ABCDEFGHIJ)";
const apiIssuer = "00000000-0000-0000-0000-000000000000";
const apiKeyId = "TESTKEY123";
const appleId = "developer@example.com";
const prepareRunnerId = "prepare-hosted-runner-123";
const signingRunnerId = "signing-hosted-runner-456";
const credentialValues = [
  Buffer.from("test certificate").toString("base64"),
  "certificate-password",
  signingIdentity,
  "ABCDEFGHIJ",
  apiIssuer,
  apiKeyId,
  Buffer.from("test api key").toString("base64"),
  appleId,
  "app-password",
  "unrelated-apple-secret",
  "test certificate",
  "test api key",
];

function prepareBindingSha256({
  prepareRunner = prepareRunnerId,
  sourceCommit = "a".repeat(40),
  archiveSha256,
  appDigest,
  entryListSha256,
}) {
  return createHash("sha256")
    .update(
      `prepareRunnerId:${prepareRunner}\n` +
        `sourceCommit:${sourceCommit}\n` +
        `archiveSha256:${archiveSha256}\n` +
        `appDigest:${appDigest}\n` +
        `entryListSha256:${entryListSha256}\n`,
    )
    .digest("hex");
}

function canonicalReleaseInputAttestation({
  archiveSha256,
  archiveSize,
  entries,
  appDigest = "0".repeat(64),
  sourceCommit = "a".repeat(40),
  prepareRunner = prepareRunnerId,
}) {
  const entryListSha256 = createHash("sha256").update(`${entries.join("\n")}\n`).digest("hex");
  return {
    appDigest,
    appDigestAlgorithm: "sha256-files-v1",
    architecture: "arm64",
    archive: {
      entryCount: entries.length,
      entryListSha256,
      name: "Seer-unsigned-arm64.tar",
      sha256: archiveSha256,
      size: archiveSize,
    },
    archiveFormat: "ustar",
    boundary: "task14-release-v1",
    boundaryValidation: "passed",
    buildNumber: "42",
    bundleIdentifier: "ai.opencoven.seer",
    prepareBindingAlgorithm: "sha256-lines-v1",
    prepareBindingSha256: prepareBindingSha256({
      prepareRunner,
      sourceCommit,
      archiveSha256,
      appDigest,
      entryListSha256,
    }),
    prepareRunnerId: prepareRunner,
    schemaVersion: 2,
    sourceCommit,
    version: "1.2.3",
  };
}

function withScratch(prefix, callback) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", prefix));
  try {
    return callback(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

async function withScratchAsync(prefix, callback) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", prefix));
  try {
    return await callback(scratch);
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
    APPLE_CERTIFICATE: credentialValues[0],
    APPLE_CERTIFICATE_PASSWORD: "certificate-password",
    APPLE_SIGNING_IDENTITY: signingIdentity,
    APPLE_TEAM_ID: "ABCDEFGHIJ",
    APPLE_UNRELATED_SECRET: "unrelated-apple-secret",
    SOURCE_COMMIT: "a".repeat(40),
    WORKFLOW_RUN: "123",
    PREPARE_RUNNER_ID: prepareRunnerId,
    SIGNING_RUNNER_ID: signingRunnerId,
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

function runPackageAsync(env) {
  const child = spawn("/bin/bash", [packageScript], {
    cwd: repoRoot,
    detached: true,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  const completed = new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
  return { child, completed };
}

async function waitForFile(path, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${path}`);
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

function removePackagingLeavesForTest() {
  if (!existsSync(buildRoot)) return;
  for (const name of readdirSync(buildRoot)) {
    if (name === ".release-package.lock" || name.startsWith(".release-work.")) {
      rmSync(join(buildRoot, name), { recursive: true, force: true });
    }
  }
}

function makeStubTools(
  scratch,
  { notaryStatus = "Accepted", notarizationMode = "api-key", pauseAt = "" } = {},
) {
  const bin = join(scratch, "bin");
  const logPath = join(scratch, "tool.log");
  const captureDir = join(scratch, "captured-environments");
  const appPointer = join(scratch, "archive-app-path");
  const keychainPointer = join(scratch, "temporary-keychain-path");
  const defaultKeychainState = join(scratch, "default-keychain");
  const mountPointer = join(scratch, "mounted-dmg-path");
  const pauseReady = join(scratch, "pause-ready");
  const precredentialAttackMarker = join(scratch, "precredential-helper-daemonized");
  const credentialsDestroyedMarker = join(scratch, "credentials-destroyed");
  const precredentialCommandLog = join(scratch, "precredential-commands.log");
  const signedState = join(scratch, "codesign-signed");
  mkdirSync(bin);
  mkdirSync(captureDir);
  writeFileSync(defaultKeychainState, `${join(scratch, "login.keychain-db")}\n`);

  writeExecutable(join(bin, "uname"), 'printf "arm64\\n"\n');
  writeExecutable(join(bin, "openssl"), 'printf "fixed-test-keychain-password\\n"\n');
  writeExecutable(
    join(bin, "base64"),
    'cat >/dev/null\nprintf "base64:decode\\n" >> "${SEER_STUB_LOG}"\nprintf "decoded fixture bytes"\n',
  );
  writeExecutable(
    join(bin, "xcodegen"),
    '"/usr/bin/env" > "${SEER_STUB_CAPTURE_DIR}/xcodegen.env"\nprintf "xcodegen\\n" >> "${SEER_STUB_LOG}"\n',
  );
  writeExecutable(
    join(bin, "xcodebuild"),
    `
"/usr/bin/env" > "\${SEER_STUB_CAPTURE_DIR}/xcodebuild.env"
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
  writeExecutable(
    join(bin, "lipo"),
    'printf "lipo\\n" >> "${SEER_STUB_LOG}"\nprintf "arm64\\n"\n',
  );
  writeExecutable(
    join(bin, "security"),
    `
operation="$1"
printf "security:%s\\n" "\${operation}" >> "\${SEER_STUB_LOG}"
"/usr/bin/env" > "\${SEER_STUB_CAPTURE_DIR}/security.env"
case "\${operation}" in
  default-keychain)
    if [[ "\${2:-}" == "-d" ]]; then
      printf '"%s"\\n' "$(cat "\${SEER_STUB_DEFAULT_KEYCHAIN_STATE}")"
    elif [[ "\${2:-}" == "-s" ]]; then
      printf "%s\\n" "\${3}" > "\${SEER_STUB_DEFAULT_KEYCHAIN_STATE}"
    fi
    ;;
  create-keychain)
    last=""
    for argument in "$@"; do last="\${argument}"; done
    : > "\${last}"
    printf "%s\\n" "\${last}" > "\${SEER_STUB_KEYCHAIN_POINTER}"
    ;;
  set-keychain-settings)
    if [[ "\${SEER_STUB_PAUSE_AT:-}" == "after-keychain" ]]; then
      printf "ready\\n" > "\${SEER_STUB_PAUSE_READY}"
      while :; do /bin/sleep 1; done
    fi
    ;;
  import)
    [[ "$*" == *" -P certificate-password "* ]]
    printf "security:import-explicit-password\\n" >> "\${SEER_STUB_LOG}"
    ;;
  delete-keychain)
    last=""
    for argument in "$@"; do last="\${argument}"; done
    rm -f "\${last}"
    printf "destroyed\\n" > ${JSON.stringify(credentialsDestroyedMarker)}
    ;;
  find-identity)
    printf '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: OpenCoven (ABCDEFGHIJ)"\\n'
    ;;
esac
`,
  );
  writeExecutable(
    join(bin, "codesign"),
    `
display=0
verify=0
"/usr/bin/env" > "\${SEER_STUB_CAPTURE_DIR}/codesign.env"
for argument in "$@"; do
  [[ "\${argument}" == "-d" ]] && display=1
  [[ "\${argument}" == "--verify" ]] && verify=1
done
if [[ "\${display}" == 1 ]]; then
  {
    printf "Authority=Developer ID Application: OpenCoven (ABCDEFGHIJ)\\n"
    printf "TeamIdentifier=ABCDEFGHIJ\\n"
    printf "Timestamp=Aug 15, 2026 at 9:30:00 AM\\n"
    printf "flags=0x10000(runtime)\\n"
  } >&2
elif [[ "\${verify}" == 1 ]]; then
  printf "codesign:verify\\n" >> "\${SEER_STUB_LOG}"
else
  [[ "$*" == *" --sign Developer ID Application: OpenCoven (ABCDEFGHIJ) "* ]]
  printf "codesign:sign\\n" >> "\${SEER_STUB_LOG}"
fi
`,
  );
  writeExecutable(
    join(bin, "plutil"),
    `
case "\${2:-}" in
  CFBundleShortVersionString) printf "plutil\\n" >> "\${SEER_STUB_LOG}"; printf "1.2.3\\n" ;;
  CFBundleVersion) printf "plutil\\n" >> "\${SEER_STUB_LOG}"; printf "42\\n" ;;
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
  "/usr/bin/env" > "\${SEER_STUB_CAPTURE_DIR}/xcrun.env"
  case "\${SEER_STUB_NOTARY_MODE}" in
    api-key)
      [[ "$*" == *" --issuer 00000000-0000-0000-0000-000000000000 "* ]]
      [[ "$*" == *" --key-id TESTKEY123 "* ]]
      [[ "$*" == *" --key "* ]]
      [[ "$*" != *" --apple-id "* && "$*" != *" --password "* && "$*" != *" --team-id "* ]]
      printf "notarytool:api-key\\n" >> "\${SEER_STUB_LOG}"
      ;;
    apple-id)
      [[ "$*" == *" --apple-id developer@example.com "* ]]
      [[ "$*" == *" --password app-password "* ]]
      [[ "$*" == *" --team-id ABCDEFGHIJ"* ]]
      [[ "$*" != *" --issuer "* && "$*" != *" --key-id "* && "$*" != *" --key "* ]]
      printf "notarytool:apple-id\\n" >> "\${SEER_STUB_LOG}"
      ;;
    *) exit 2 ;;
  esac
  printf '{"status":"%s"}\\n' "\${SEER_STUB_NOTARY_STATUS}"
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
    printf "%s\\n" "\${mountpoint}" > "\${SEER_STUB_MOUNT_POINTER}"
    ;;
  detach)
    rm -rf "$2"
    ;;
esac
`,
  );
  writeExecutable(join(bin, "spctl"), 'printf "spctl\\n" >> "${SEER_STUB_LOG}"\n');
  writeExecutable(
    join(bin, "node"),
    `
if [[ "\${1:-}" == *"/scripts/check-release-boundary.mjs" ]]; then
  if [[ "\${SEER_STUB_PAUSE_AT:-}" == "after-dmg-attach" && "$*" == *" --dmg-root "* ]]; then
    printf "ready\\n" > "\${SEER_STUB_PAUSE_READY}"
    while :; do /bin/sleep 1; done
  fi
  printf "boundary:%s\\n" "$*" >> "\${SEER_STUB_LOG}"
  exit 0
fi
if [[ "\${1:-}" == *"/scripts/build-standalone-renderer.mjs" ]]; then
  "/usr/bin/env" > "\${SEER_STUB_CAPTURE_DIR}/renderer.env"
  shift
  [[ "\${1:-}" == "--" ]]
  shift
  SEER_RENDERER_LOCK_HELD="stub-renderer-lock" exec "$@"
fi
exec "\${SEER_REAL_NODE}" "$@"
`,
  );

  return {
    env: {
      ...completeSigningEnvironment(),
      PATH: `${bin}:${process.env.PATH}`,
      ...(notarizationMode === "api-key"
        ? {
            APPLE_API_ISSUER: apiIssuer,
            APPLE_API_KEY: apiKeyId,
            APPLE_API_KEY_BASE64: credentialValues[6],
          }
        : {
            APPLE_ID: appleId,
            APPLE_PASSWORD: "app-password",
          }),
      SEER_REAL_NODE: process.execPath,
      SEER_STUB_APP_POINTER: appPointer,
      SEER_STUB_CAPTURE_DIR: captureDir,
      SEER_STUB_DEFAULT_KEYCHAIN_STATE: defaultKeychainState,
      SEER_STUB_KEYCHAIN_POINTER: keychainPointer,
      SEER_STUB_LOG: logPath,
      SEER_STUB_MOUNT_POINTER: mountPointer,
      SEER_STUB_NOTARY_MODE: notarizationMode,
      SEER_STUB_NOTARY_STATUS: notaryStatus,
      SEER_TEST_MODE: "1",
      SEER_TEST_SYSTEM_TOOLS_DIR: bin,
      SEER_TEST_COMMAND_LOG: precredentialCommandLog,
      SEER_STUB_PAUSE_AT: pauseAt,
      SEER_STUB_PAUSE_READY: pauseReady,
    },
    captureDir,
    defaultKeychainState,
    keychainPointer,
    logPath,
    mountPointer,
    pauseReady,
  };
}

function assertCredentialFreeEnvironment(path) {
  const captured = readFileSync(path, "utf8");
  assert.doesNotMatch(captured, /^APPLE_/m, path);
  for (const value of credentialValues) {
    assert.ok(!captured.includes(value), `${path} exposed credential value ${value}`);
  }
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
  assert.match(source, /trap ['"]?handle_signal 1['"]? HUP/);
  assert.match(source, /trap ['"]?handle_signal 2['"]? INT/);
  assert.match(source, /trap ['"]?handle_signal 15['"]? TERM/);
  assert.ok(
    source.indexOf("trap cleanup EXIT") <
      source.indexOf('run_system_tool "${SYSTEM_MKDIR}" -p "${BUILD_ROOT}"'),
    "signal and EXIT traps must be installed before packaging side effects",
  );
  assert.match(source, /unset "\$\{apple_variable\}"/);
  const firstCredentialUnset = source.indexOf(
    'for apple_variable in "${!APPLE_@}"',
    source.indexOf("export -n"),
  );
  assert.ok(
    firstCredentialUnset < source.indexOf("SCRIPT_DIR="),
    "signing variables must be unexported before the first command substitution",
  );
  assert.match(source, /SYSTEM_SECURITY=\/usr\/bin\/security/);
  assert.match(source, /SYSTEM_SECURITY}" create-keychain/);
  assert.match(source, /SYSTEM_SECURITY}" default-keychain -s/);
  assert.match(source, /SYSTEM_SECURITY}" delete-keychain/);
  assert.match(source, /API_KEY_PATH="\$\{CREDENTIAL_ROOT\}\/notary-api-key\.p8"/);
  assert.doesNotMatch(source, /API_KEY_PATH=.*APPLE_API_KEY/);
  assert.match(source, /archive exact entry allowlist/);
  assert.match(source, /extracted app digest does not match/);
  assert.doesNotMatch(source, /\b(?:npm|npx|vite|xcodegen|xcodebuild)\b/);
  assert.match(source, /--options runtime/);
  assert.match(source, /--timestamp/);
  assert.doesNotMatch(source, /--entitlements/);
  assert.match(source, /SYSTEM_CODESIGN}" --verify --deep --strict/);
  assert.match(source, /SYSTEM_CODESIGN}" -d --verbose=4 "\$\{WORK_DMG\}"/);
  assert.match(source, /notarytool submit[\s\S]*--wait[\s\S]*--output-format json/);
  assert.match(source, /SYSTEM_DITTO}" -c -k --keepParent/);
  assert.match(source, /stapler staple/);
  assert.match(source, /stapler validate/);
  assert.match(source, /SYSTEM_HDIUTIL}" create[\s\S]*-format UDZO/);
  assert.match(source, /SYSTEM_SPCTL}" --assess[\s\S]*SIGNED_APP/);
  assert.match(source, /SYSTEM_SPCTL}" --assess[\s\S]*WORK_DMG/);
  assert.match(source, /check-release-boundary\.mjs/);
  assert.match(source, /write-release-manifest\.mjs/);
  assert.doesNotMatch(source, /\bgh\b|curl|git push|gh release/);
});

test("precredential signing verification uses only fixed system tools and shell built-ins", () => {
  const source = readFileSync(packageScript, "utf8");
  const credentialBoundary = source.indexOf("# CREDENTIAL PHASE");
  assert.notEqual(credentialBoundary, -1, "signing script must mark the credential phase boundary");
  const precredential = source.slice(0, credentialBoundary);

  assert.doesNotMatch(
    precredential,
    /scripts\/.*\.(?:mjs|py)|\/usr\/bin\/python3|\b(?:node|npm|npx|git|xcodegen|xcodebuild)\b/,
  );
  for (const tool of ["codesign", "lipo", "plutil", "shasum", "stat", "tar", "uname"]) {
    assert.match(precredential, new RegExp(`/usr/bin/${tool}\\b`), tool);
  }
  assert.match(precredential, /UNSIGNED_APP_ATTESTATION_SHA256/);
  assert.match(precredential, /PREPARE_RUNNER_ID/);
  assert.match(precredential, /SIGNING_RUNNER_ID/);
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

test("stubbed Apple-ID flow passes only Apple-ID notary arguments without logging credentials", () => {
  withScratch("release-package-apple-id-", (scratch) => {
    rmSync(releaseRoot, { recursive: true, force: true });
    const input = createAttestedInput(scratch);
    const { env, logPath } = makeSigningOnlyStubs(scratch, input, {
      notarizationMode: "apple-id",
    });
    const result = runPackage(env);
    assert.equal(result.status, 0, `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`);

    const log = readFileSync(logPath, "utf8");
    assert.equal((log.match(/^notarytool:apple-id$/gm) ?? []).length, 2);
    for (const value of credentialValues) {
      assert.ok(!`${result.stdout}${result.stderr}${log}`.includes(value), `logged credential value ${value}`);
    }
    assertNoPackagingLeaves();
  });
});

test("notarization rejection cleans key material, restores keychain, and publishes nothing", () => {
  withScratch("release-package-failure-", (scratch) => {
    rmSync(releaseRoot, { recursive: true, force: true });
    const input = createAttestedInput(scratch);
    const { env, keychainPointer, logPath } = makeSigningOnlyStubs(scratch, input, {
      notaryStatus: "Invalid",
    });
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

test("unsigned preparation rejects every APPLE variable before running build tooling", () => {
  withScratch("release-prepare-secret-", (scratch) => {
    const marker = join(scratch, "build-tool-ran");
    const bin = join(scratch, "bin");
    mkdirSync(bin);
    for (const tool of ["node", "xcodegen", "xcodebuild"]) {
      writeExecutable(join(bin, tool), `printf "%s\\n" "${tool}" >> ${JSON.stringify(marker)}\n`);
    }

    const result = spawnSync("/bin/bash", [prepareScript], {
      cwd: repoRoot,
      encoding: "utf8",
      env: {
        PATH: `${bin}:${process.env.PATH}`,
        VERSION: "1.2.3",
        BUILD_NUMBER: "42",
        SOURCE_COMMIT: "a".repeat(40),
        APPLE_UNRELATED_SECRET: "must-never-reach-a-build-runner",
      },
    });

    assert.equal(result.status, 1);
    assert.match(result.stderr, /credential-free build job.*distinct runner/i);
    assert.ok(!existsSync(marker), "build tooling must not run when an APPLE variable is present");
  });
});

test("unsigned preparation requires a runner identity before invoking repository tooling", () => {
  withScratch("release-prepare-runner-id-", (scratch) => {
    const marker = join(scratch, "tool-ran");
    const bin = join(scratch, "bin");
    mkdirSync(bin);
    for (const tool of ["git", "node", "uname", "xcodegen", "xcodebuild"]) {
      writeExecutable(join(bin, tool), `printf "%s\\n" "${tool}" >> ${JSON.stringify(marker)}\n`);
    }

    const result = spawnSync("/bin/bash", [prepareScript], {
      cwd: repoRoot,
      encoding: "utf8",
      env: {
        PATH: `${bin}:${process.env.PATH}`,
        VERSION: "1.2.3",
        BUILD_NUMBER: "42",
        SOURCE_COMMIT: "a".repeat(40),
      },
    });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /PREPARE_RUNNER_ID/);
    assert.ok(!existsSync(marker), "runner identity must be checked before repository tooling");
  });
});

test("unsigned preparation builds and attests the fixed release input without signing state", () => {
  withScratch("release-prepare-success-", (scratch) => {
    rmSync(releaseInputRoot, { recursive: true, force: true });
    const bin = join(scratch, "bin");
    const log = join(scratch, "prepare.log");
    const capturedEnvironment = join(scratch, "xcodebuild.env");
    mkdirSync(bin);
    const sourceCommit = "b".repeat(40);
    writeExecutable(
      join(bin, "git"),
      `
if [[ "\${1:-}" == "rev-parse" ]]; then printf "${sourceCommit}\\n"; exit 0; fi
if [[ "\${1:-}" == "status" ]]; then exit 0; fi
exit 2
`,
    );
    writeExecutable(join(bin, "uname"), 'printf "arm64\\n"\n');
    writeExecutable(
      join(bin, "node"),
      `
if [[ "\${1:-}" == *"/scripts/build-standalone-renderer.mjs" ]]; then
  printf "renderer\\n" >> ${JSON.stringify(log)}
  shift
  [[ "\${1:-}" == "--" ]]
  shift
  SEER_RENDERER_LOCK_HELD=stub exec "$@"
fi
if [[ "\${1:-}" == *"/scripts/check-release-boundary.mjs" ]]; then
  printf "boundary\\n" >> ${JSON.stringify(log)}
  exit 0
fi
exit 2
`,
    );
    writeExecutable(join(bin, "xcodegen"), `printf "xcodegen\\n" >> ${JSON.stringify(log)}\n`);
    writeExecutable(
      join(bin, "xcodebuild"),
      `
"/usr/bin/env" > ${JSON.stringify(capturedEnvironment)}
archive=""
previous=""
for argument in "$@"; do
  if [[ "\${previous}" == "-archivePath" ]]; then archive="\${argument}"; fi
  previous="\${argument}"
done
app="\${archive}/Products/Applications/Seer.app"
mkdir -p "\${app}/Contents/MacOS"
printf "unsigned executable\\n" > "\${app}/Contents/MacOS/Seer"
chmod +x "\${app}/Contents/MacOS/Seer"
printf "plist fixture\\n" > "\${app}/Contents/Info.plist"
printf "xcodebuild:%s\\n" "$*" >> ${JSON.stringify(log)}
`,
    );
    writeExecutable(
      join(bin, "plutil"),
      `
case "\${2:-}" in
  CFBundleShortVersionString) printf "1.2.3\\n" ;;
  CFBundleVersion) printf "42\\n" ;;
  CFBundleIdentifier) printf "ai.opencoven.seer\\n" ;;
  *) exit 2 ;;
esac
`,
    );
    writeExecutable(join(bin, "strip"), `printf "strip\\n" >> ${JSON.stringify(log)}\n`);
    writeExecutable(join(bin, "lipo"), 'printf "arm64\\n"\n');

    const result = spawnSync("/bin/bash", [prepareScript], {
      cwd: repoRoot,
      encoding: "utf8",
      env: {
        PATH: `${bin}:${process.env.PATH}`,
        VERSION: "1.2.3",
        BUILD_NUMBER: "42",
        SOURCE_COMMIT: sourceCommit,
        PREPARE_RUNNER_ID: prepareRunnerId,
      },
    });

    assert.equal(result.status, 0, `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
    assert.deepEqual(readdirSync(releaseInputRoot).sort(), [
      "Seer-unsigned-arm64.tar",
      "unsigned-app-attestation.json",
    ]);
    const metadata = JSON.parse(
      readFileSync(join(releaseInputRoot, "unsigned-app-attestation.json"), "utf8"),
    );
    assert.equal(metadata.sourceCommit, sourceCommit);
    assert.equal(metadata.prepareRunnerId, prepareRunnerId);
    assert.equal(metadata.boundaryValidation, "passed");
    assert.equal(
      metadata.prepareBindingSha256,
      prepareBindingSha256({
        archiveSha256: metadata.archive.sha256,
        appDigest: metadata.appDigest,
        entryListSha256: metadata.archive.entryListSha256,
        sourceCommit,
      }),
    );
    assert.equal(metadata.archive.sha256, createHash("sha256")
      .update(readFileSync(join(releaseInputRoot, "Seer-unsigned-arm64.tar")))
      .digest("hex"));
    assert.match(result.stdout, new RegExp(`PREPARE_RUNNER_ID=${prepareRunnerId}`));
    assert.match(result.stdout, new RegExp(`UNSIGNED_APP_SHA256=${metadata.archive.sha256}`));
    assert.match(result.stdout, /UNSIGNED_APP_ATTESTATION_SHA256=[0-9a-f]{64}/);
    const toolEnvironment = readFileSync(capturedEnvironment, "utf8");
    assert.doesNotMatch(toolEnvironment, /^APPLE_/m);
    assert.match(readFileSync(log, "utf8"), /renderer\nxcodegen\nxcodebuild:[^\n]+\nstrip\nboundary\n/);
  });
});

test("signing script has no build-tool execution path and requires attested unsigned input", () => {
  const source = readFileSync(packageScript, "utf8");

  assert.doesNotMatch(source, /\b(?:npm|npx|vite|xcodegen|xcodebuild)\b/);
  assert.doesNotMatch(source, /build-standalone-renderer/);
  assert.match(source, /UNSIGNED_APP_ARCHIVE/);
  assert.match(source, /UNSIGNED_APP_ATTESTATION/);
  assert.match(source, /UNSIGNED_APP_SHA256/);
  assert.match(source, /distinct (?:machine|runner)/i);
});

test("standalone source boundary includes both release-phase implementations", () => {
  const { files, offenders } = listStandaloneSourceFiles(repoRoot);
  assert.deepEqual(offenders, []);
  assert.ok(files.includes("scripts/prepare-macos-release-input.sh"));
  assert.ok(files.includes("scripts/macos-release-input.py"));
});

test("release-input tool creates deterministic no-link archives and source-bound attestations", () => {
  withScratch("release-input-tool-", (scratch) => {
    const app = join(scratch, "Seer.app");
    const executable = join(app, "Contents", "MacOS", "Seer");
    mkdirSync(dirname(executable), { recursive: true });
    writeFileSync(executable, "arm64 executable fixture\n");
    chmodSync(executable, 0o755);
    writeFileSync(join(app, "Contents", "Info.plist"), "plist fixture\n");

    const outputs = [];
    for (const suffix of ["one", "two"]) {
      const outputDirectory = join(scratch, suffix);
      mkdirSync(outputDirectory);
      const archive = join(outputDirectory, "Seer-unsigned-arm64.tar");
      const attestation = join(outputDirectory, "unsigned-app-attestation.json");
      const result = spawnSync(
        "/usr/bin/python3",
        [
          releaseInputTool,
          "create",
          "--app",
          app,
          "--archive",
          archive,
          "--attestation",
          attestation,
          "--source-commit",
          "a".repeat(40),
          "--version",
          "1.2.3",
          "--build-number",
          "42",
          "--bundle-identifier",
          "ai.opencoven.seer",
          "--architecture",
          "arm64",
          "--prepare-runner-id",
          prepareRunnerId,
        ],
        { cwd: repoRoot, encoding: "utf8" },
      );
      assert.equal(result.status, 0, result.stderr);
      outputs.push({ archive, attestation });
    }

    assert.deepEqual(readFileSync(outputs[0].archive), readFileSync(outputs[1].archive));
    const archiveBytes = readFileSync(outputs[0].archive);
    const metadata = JSON.parse(readFileSync(outputs[0].attestation, "utf8"));
    assert.deepEqual(Object.keys(metadata).sort(), [
      "appDigest",
      "appDigestAlgorithm",
      "architecture",
      "archive",
      "archiveFormat",
      "boundary",
      "boundaryValidation",
      "buildNumber",
      "bundleIdentifier",
      "prepareBindingAlgorithm",
      "prepareBindingSha256",
      "prepareRunnerId",
      "schemaVersion",
      "sourceCommit",
      "version",
    ]);
    assert.equal(metadata.archive.sha256, createHash("sha256").update(archiveBytes).digest("hex"));
    assert.equal(metadata.archive.size, archiveBytes.length);
    assert.equal(metadata.sourceCommit, "a".repeat(40));
    assert.equal(metadata.prepareRunnerId, prepareRunnerId);
    assert.equal(metadata.architecture, "arm64");
    assert.equal(metadata.bundleIdentifier, "ai.opencoven.seer");
    assert.equal(metadata.appDigest, computeAppDigest(app));
  });
});

test("release-input creation rejects non-fixed artifact names", () => {
  withScratch("release-input-name-", (scratch) => {
    const app = join(scratch, "Seer.app");
    mkdirSync(app);
    const result = spawnSync(
      "/usr/bin/python3",
      [
        releaseInputTool,
        "create",
        "--app",
        app,
        "--archive",
        join(scratch, "renamed.tar"),
        "--attestation",
        join(scratch, "renamed.json"),
        "--source-commit",
        "a".repeat(40),
        "--version",
        "1.2.3",
        "--build-number",
        "42",
        "--bundle-identifier",
        "ai.opencoven.seer",
        "--architecture",
        "arm64",
        "--prepare-runner-id",
        prepareRunnerId,
      ],
      { cwd: repoRoot, encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /fixed artifact name/i);
  });
});

test("release-input creation never follows a symlinked app ancestor", () => {
  withScratch("release-input-source-link-", (scratch) => {
    const external = join(scratch, "external");
    const app = join(external, "Seer.app");
    mkdirSync(app, { recursive: true });
    const redirectedParent = join(scratch, "redirected");
    symlinkSync(external, redirectedParent);
    const result = spawnSync(
      "/usr/bin/python3",
      [
        releaseInputTool,
        "create",
        "--app",
        join(redirectedParent, "Seer.app"),
        "--archive",
        join(scratch, "Seer-unsigned-arm64.tar"),
        "--attestation",
        join(scratch, "unsigned-app-attestation.json"),
        "--source-commit",
        "a".repeat(40),
        "--version",
        "1.2.3",
        "--build-number",
        "42",
        "--bundle-identifier",
        "ai.opencoven.seer",
        "--architecture",
        "arm64",
        "--prepare-runner-id",
        prepareRunnerId,
      ],
      { cwd: repoRoot, encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /symlink|not a directory/i);
    assert.ok(!existsSync(join(scratch, "Seer-unsigned-arm64.tar")));
  });
});

test("release-input validation safely extracts only an attested Seer.app", () => {
  withScratch("release-input-validate-", (scratch) => {
    const app = join(scratch, "Seer.app");
    const executable = join(app, "Contents", "MacOS", "Seer");
    mkdirSync(dirname(executable), { recursive: true });
    writeFileSync(executable, "arm64 executable fixture\n");
    chmodSync(executable, 0o755);
    writeFileSync(join(app, "Contents", "Info.plist"), "plist fixture\n");
    const archive = join(scratch, "Seer-unsigned-arm64.tar");
    const attestation = join(scratch, "unsigned-app-attestation.json");
    let result = spawnSync(
      "/usr/bin/python3",
      [
        releaseInputTool,
        "create",
        "--app",
        app,
        "--archive",
        archive,
        "--attestation",
        attestation,
        "--source-commit",
        "a".repeat(40),
        "--version",
        "1.2.3",
        "--build-number",
        "42",
        "--bundle-identifier",
        "ai.opencoven.seer",
        "--architecture",
        "arm64",
        "--prepare-runner-id",
        prepareRunnerId,
      ],
      { cwd: repoRoot, encoding: "utf8" },
    );
    assert.equal(result.status, 0, result.stderr);
    const archiveSha256 = createHash("sha256").update(readFileSync(archive)).digest("hex");
    const destination = join(scratch, "extracted");
    mkdirSync(destination, { mode: 0o700 });

    result = spawnSync(
      "/usr/bin/python3",
      [
        releaseInputTool,
        "validate",
        "--archive",
        archive,
        "--attestation",
        attestation,
        "--expected-archive-sha256",
        archiveSha256,
        "--expected-source-commit",
        "a".repeat(40),
        "--expected-version",
        "1.2.3",
        "--expected-build-number",
        "42",
        "--expected-prepare-runner-id",
        prepareRunnerId,
        "--destination",
        destination,
      ],
      { cwd: repoRoot, encoding: "utf8" },
    );

    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(join(destination, "Seer.app", "Contents", "MacOS", "Seer"), "utf8"), "arm64 executable fixture\n");
    assert.equal(readdirSync(destination).join(","), "Seer.app");
  });
});

for (const [kind, maliciousName] of [
  ["traversal", "Seer.app/../../escaped"],
  ["symlink", "Seer.app/Contents/redirect"],
]) {
  test(`release-input validation rejects ${kind} entries before extraction`, () => {
    withScratch(`release-input-${kind}-`, (scratch) => {
      const archive = join(scratch, "Seer-unsigned-arm64.tar");
      const python = `
import io, tarfile
with tarfile.open(${JSON.stringify(archive)}, "w", format=tarfile.USTAR_FORMAT) as output:
    root = tarfile.TarInfo("Seer.app")
    root.type = tarfile.DIRTYPE
    root.mode = 0o755
    output.addfile(root)
    bad = tarfile.TarInfo(${JSON.stringify(maliciousName)})
    ${kind === "symlink" ? 'bad.type = tarfile.SYMTYPE\n    bad.linkname = "/etc/passwd"\n    output.addfile(bad)' : 'bad.size = 4\n    output.addfile(bad, io.BytesIO(b"evil"))'}
`;
      const created = spawnSync("/usr/bin/python3", ["-c", python], { encoding: "utf8" });
      assert.equal(created.status, 0, created.stderr);
      const bytes = readFileSync(archive);
      const archiveSha256 = createHash("sha256").update(bytes).digest("hex");
      const attestation = join(scratch, "unsigned-app-attestation.json");
      writeFileSync(
        attestation,
        `${JSON.stringify(
          canonicalReleaseInputAttestation({
            archiveSha256,
            archiveSize: bytes.length,
            entries: ["Seer.app/", maliciousName],
          }),
          null,
          2,
        )}\n`,
      );
      const destination = join(scratch, "extracted");
      mkdirSync(destination, { mode: 0o700 });

      const result = spawnSync(
        "/usr/bin/python3",
        [
          releaseInputTool,
          "validate",
          "--archive",
          archive,
          "--attestation",
          attestation,
          "--expected-archive-sha256",
          archiveSha256,
          "--expected-source-commit",
          "a".repeat(40),
          "--expected-version",
          "1.2.3",
          "--expected-build-number",
          "42",
          "--expected-prepare-runner-id",
          prepareRunnerId,
          "--destination",
          destination,
        ],
        { cwd: repoRoot, encoding: "utf8" },
      );

      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /unsafe archive entry|links are forbidden/i);
      assert.deepEqual(readdirSync(destination), []);
      assert.ok(!existsSync(join(scratch, "escaped")));
    });
  });
}

function createAttestedInput(scratch, sourceCommit = "a".repeat(40)) {
  const input = join(scratch, "input");
  const app = join(scratch, "input-app", "Seer.app");
  const executable = join(app, "Contents", "MacOS", "Seer");
  mkdirSync(dirname(executable), { recursive: true });
  writeFileSync(executable, "unsigned arm64 executable fixture\n");
  chmodSync(executable, 0o755);
  writeFileSync(join(app, "Contents", "Info.plist"), "plist fixture\n");
  mkdirSync(input);
  const archive = join(input, "Seer-unsigned-arm64.tar");
  const attestation = join(input, "unsigned-app-attestation.json");
  const result = spawnSync(
    "/usr/bin/python3",
    [
      releaseInputTool,
      "create",
      "--app",
      app,
      "--archive",
      archive,
      "--attestation",
      attestation,
      "--source-commit",
      sourceCommit,
      "--version",
      "1.2.3",
      "--build-number",
      "42",
      "--bundle-identifier",
      "ai.opencoven.seer",
      "--architecture",
      "arm64",
      "--prepare-runner-id",
      prepareRunnerId,
    ],
    { cwd: repoRoot, encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);
  return {
    archive,
    attestation,
    sha256: createHash("sha256").update(readFileSync(archive)).digest("hex"),
  };
}

function makeSigningOnlyStubs(
  scratch,
  input,
  {
    notaryStatus = "Accepted",
    notarizationMode = "api-key",
    backgroundAttack = false,
    credentialCleanupFailure = false,
    pauseAt = "",
    signingSourceCommit = "a".repeat(40),
  } = {},
) {
  const bin = join(scratch, "signing-bin");
  const logPath = join(scratch, "signing.log");
  const nodeEnvironment = join(scratch, "node.env");
  const backgroundEnvironment = join(scratch, "background.env");
  const defaultKeychainState = join(scratch, "default-keychain");
  const keychainPointer = join(scratch, "keychain-path");
  const dmgImage = join(scratch, "dmg-image");
  const mountPointer = join(scratch, "mount-path");
  const pauseReady = join(scratch, "pause-ready");
  const precredentialAttackMarker = join(scratch, "precredential-helper-daemonized");
  const credentialsDestroyedMarker = join(scratch, "credentials-destroyed");
  const precredentialCommandLog = join(scratch, "precredential-commands.log");
  const signedState = join(scratch, "codesign-signed");
  const sourceCommit = signingSourceCommit;
  mkdirSync(bin);
  writeFileSync(defaultKeychainState, `${join(scratch, "login.keychain-db")}\n`);

  writeExecutable(join(bin, "uname"), 'printf "arm64\\n"\n');
  writeExecutable(
    join(bin, "git"),
    `
if [[ "\${1:-}" == "rev-parse" ]]; then printf "${sourceCommit}\\n"; exit 0; fi
if [[ "\${1:-}" == "status" ]]; then exit 0; fi
exit 2
`,
  );
  for (const tool of ["npm", "npx", "vite", "xcodegen", "xcodebuild"]) {
    writeExecutable(
      join(bin, tool),
      `printf "FORBIDDEN-BUILD-TOOL:${tool}\\n" >> ${JSON.stringify(logPath)}\nexit 97\n`,
    );
  }
  writeExecutable(
    join(bin, "node"),
    `
printf '%s\\n' "--- node $* ---" >> ${JSON.stringify(nodeEnvironment)}
"/usr/bin/env" >> ${JSON.stringify(nodeEnvironment)}
if [[ "\${1:-}" == *"/scripts/check-release-boundary.mjs" ]]; then
  printf "node:boundary\\n" >> ${JSON.stringify(logPath)}
  if [[ ! -e ${JSON.stringify(credentialsDestroyedMarker)} ]]; then
    ("/bin/sleep" 1; printf "repository helper daemon ran\\n" > ${JSON.stringify(precredentialAttackMarker)}) &
  fi
  ${backgroundAttack ? `("/bin/sleep" 1; "/usr/bin/env" > ${JSON.stringify(backgroundEnvironment)}) &` : ""}
  exit 0
fi
if [[ "\${1:-}" == *"/scripts/write-release-manifest.mjs" ]]; then
  printf "node:manifest\\n" >> ${JSON.stringify(logPath)}
  exec ${JSON.stringify(process.execPath)} "$@"
fi
exit 2
`,
  );
  writeExecutable(
    join(bin, "security"),
    `
operation="$1"
printf "security:%s\\n" "\${operation}" >> ${JSON.stringify(logPath)}
case "\${operation}" in
  default-keychain)
    if [[ "\${2:-}" == "-d" ]]; then
      printf '"%s"\\n' "$(cat ${JSON.stringify(defaultKeychainState)})"
    elif [[ "\${2:-}" == "-s" ]]; then
      printf "%s\\n" "\${3}" > ${JSON.stringify(defaultKeychainState)}
    fi
    ;;
  create-keychain)
    last=""
    for argument in "$@"; do last="\${argument}"; done
    : > "\${last}"
    printf "%s\\n" "\${last}" > ${JSON.stringify(keychainPointer)}
    ;;
  set-keychain-settings)
    if [[ ${JSON.stringify(pauseAt)} == "after-keychain" ]]; then
      printf "ready\\n" > ${JSON.stringify(pauseReady)}
      while :; do /bin/sleep 1; done
    fi
    ;;
  import)
    [[ "$*" == *" -P certificate-password "* ]]
    ;;
  find-identity)
    printf '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: OpenCoven (ABCDEFGHIJ)"\\n'
    ;;
  delete-keychain)
    last=""
    for argument in "$@"; do last="\${argument}"; done
    rm -f "\${last}"
    printf "destroyed\\n" > ${JSON.stringify(credentialsDestroyedMarker)}
    ${credentialCleanupFailure ? "exit 98" : ""}
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
  if [[ ! -e ${JSON.stringify(signedState)} ]]; then
    {
      printf "Signature=adhoc\\n"
      printf "TeamIdentifier=not set\\n"
    } >&2
  else
    {
      printf "Authority=Developer ID Application: OpenCoven (ABCDEFGHIJ)\\n"
      printf "TeamIdentifier=ABCDEFGHIJ\\n"
      printf "Timestamp=Aug 15, 2026 at 9:30:00 AM\\n"
      printf "flags=0x10000(runtime)\\n"
    } >&2
  fi
elif [[ "\${verify}" == 1 ]]; then
  printf "codesign:verify\\n" >> ${JSON.stringify(logPath)}
else
  printf "signed\\n" > ${JSON.stringify(signedState)}
  printf "codesign:sign\\n" >> ${JSON.stringify(logPath)}
fi
`,
  );
  writeExecutable(
    join(bin, "plutil"),
    `
case "\${2:-}" in
  CFBundleShortVersionString) printf "1.2.3\\n" ;;
  CFBundleVersion) printf "42\\n" ;;
  CFBundleIdentifier) printf "ai.opencoven.seer\\n" ;;
  status) cat >/dev/null; printf "${notaryStatus}\\n" ;;
  *) exit 2 ;;
esac
`,
  );
  writeExecutable(join(bin, "lipo"), 'printf "arm64\\n"\n');
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
printf "ditto\\n" >> ${JSON.stringify(logPath)}
`,
  );
  writeExecutable(
    join(bin, "xcrun"),
    `
if [[ "\${1:-}" == "notarytool" ]]; then
  if [[ ${JSON.stringify(notarizationMode)} == "api-key" ]]; then
    [[ "$*" == *" --issuer ${apiIssuer} "* ]]
    [[ "$*" == *" --key-id ${apiKeyId} "* ]]
    [[ "$*" == *" --key "* ]]
    [[ "$*" != *" --apple-id "* && "$*" != *" --password "* ]]
  else
    [[ "$*" == *" --apple-id ${appleId} "* ]]
    [[ "$*" == *" --password app-password "* ]]
    [[ "$*" == *" --team-id ABCDEFGHIJ"* ]]
    [[ "$*" != *" --issuer "* && "$*" != *" --key-id "* ]]
  fi
  printf "notarytool:${notarizationMode}\\n" >> ${JSON.stringify(logPath)}
  printf '{"status":"${notaryStatus}"}\\n'
else
  printf "stapler\\n" >> ${JSON.stringify(logPath)}
fi
`,
  );
  writeExecutable(
    join(bin, "hdiutil"),
    `
operation="$1"
printf "hdiutil:%s\\n" "\${operation}" >> ${JSON.stringify(logPath)}
case "\${operation}" in
  create)
    source=""
    last=""
    previous=""
    for argument in "$@"; do
      if [[ "\${previous}" == "-srcfolder" ]]; then source="\${argument}"; fi
      previous="\${argument}"
      last="\${argument}"
    done
    rm -rf ${JSON.stringify(dmgImage)}
    /bin/cp -R "\${source}" ${JSON.stringify(dmgImage)}
    printf "deterministic stub dmg\\n" > "\${last}"
    ;;
  attach)
    mountpoint=""
    previous=""
    for argument in "$@"; do
      if [[ "\${previous}" == "-mountpoint" ]]; then mountpoint="\${argument}"; fi
      previous="\${argument}"
    done
    /bin/cp -R ${JSON.stringify(`${dmgImage}/.`)} "\${mountpoint}/"
    printf "%s\\n" "\${mountpoint}" > ${JSON.stringify(mountPointer)}
    if [[ ${JSON.stringify(pauseAt)} == "after-dmg-attach" ]]; then
      printf "ready\\n" > ${JSON.stringify(pauseReady)}
      while :; do /bin/sleep 1; done
    fi
    ;;
  detach)
    rm -rf "$2"
    ;;
esac
`,
  );
  writeExecutable(join(bin, "spctl"), `printf "spctl\\n" >> ${JSON.stringify(logPath)}\n`);

  return {
    env: {
      ...completeSigningEnvironment({
        PATH: `${bin}:${process.env.PATH}`,
        SOURCE_COMMIT: sourceCommit,
        UNSIGNED_APP_ARCHIVE: input.archive,
        UNSIGNED_APP_ATTESTATION: input.attestation,
        UNSIGNED_APP_SHA256: input.sha256,
        UNSIGNED_APP_ATTESTATION_SHA256: createHash("sha256")
          .update(readFileSync(input.attestation))
          .digest("hex"),
      }),
      ...(notarizationMode === "api-key"
        ? {
            APPLE_API_ISSUER: apiIssuer,
            APPLE_API_KEY: apiKeyId,
            APPLE_API_KEY_BASE64: credentialValues[6],
          }
        : {
            APPLE_ID: appleId,
            APPLE_PASSWORD: "app-password",
          }),
      SEER_TEST_MODE: "1",
      SEER_TEST_SYSTEM_TOOLS_DIR: bin,
      SEER_TEST_COMMAND_LOG: precredentialCommandLog,
    },
    backgroundEnvironment,
    defaultKeychainState,
    keychainPointer,
    logPath,
    mountPointer,
    nodeEnvironment,
    pauseReady,
    precredentialAttackMarker,
    precredentialCommandLog,
  };
}

test("same runner identity is rejected before keychain creation", () => {
  withScratch("release-sign-same-runner-", (scratch) => {
    const input = createAttestedInput(scratch);
    const { env, logPath } = makeSigningOnlyStubs(scratch, input);
    const result = runPackage({
      ...env,
      PREPARE_RUNNER_ID: signingRunnerId,
      SIGNING_RUNNER_ID: signingRunnerId,
    });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /runner identit(?:y|ies).*distinct|same runner/i);
    const log = existsSync(logPath) ? readFileSync(logPath, "utf8") : "";
    assert.doesNotMatch(log, /security:create-keychain|codesign:sign|notarytool/);
  });
});

test("signing rejects an explicit preparation identity that differs from attestation", () => {
  withScratch("release-sign-prepare-id-mismatch-", (scratch) => {
    const input = createAttestedInput(scratch);
    const { env, logPath } = makeSigningOnlyStubs(scratch, input);
    const result = runPackage({ ...env, PREPARE_RUNNER_ID: "different-prepare-runner" });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /attestation PREPARE_RUNNER_ID mismatch/i);
    const log = existsSync(logPath) ? readFileSync(logPath, "utf8") : "";
    assert.doesNotMatch(log, /security:create-keychain|codesign:sign|notarytool/);
  });
});

test("GITHUB_ACTIONS cannot enable test-only system-tool overrides", () => {
  withScratch("release-sign-ci-stub-rejection-", (scratch) => {
    const input = createAttestedInput(scratch);
    const { env, logPath } = makeSigningOnlyStubs(scratch, input);
    const result = runPackage({ ...env, GITHUB_ACTIONS: "true" });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /test mode.*GitHub Actions|GITHUB_ACTIONS/i);
    assert.ok(!existsSync(logPath), "CI test-mode rejection must precede tool execution");
  });
});

test("signing rejects tampered archive bytes before credential materialization", () => {
  withScratch("release-sign-tampered-", (scratch) => {
    const input = createAttestedInput(scratch);
    writeFileSync(input.archive, Buffer.concat([readFileSync(input.archive), Buffer.from("tampered")]));
    const { env, logPath } = makeSigningOnlyStubs(scratch, input);

    const result = runPackage(env);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /archive SHA-256 mismatch/i);
    const log = existsSync(logPath) ? readFileSync(logPath, "utf8") : "";
    assert.doesNotMatch(log, /security:create-keychain|codesign:sign|notarytool/);
    assert.doesNotMatch(log, /FORBIDDEN-BUILD-TOOL/);
  });
});

test("signing rejects app-digest and source-attestation mismatches before credentials", () => {
  for (const mismatch of ["app digest", "source commit"]) {
    withScratch(`release-sign-${mismatch.replace(" ", "-")}-`, (scratch) => {
      const input = createAttestedInput(scratch);
      let options = {};
      if (mismatch === "app digest") {
        const metadata = JSON.parse(readFileSync(input.attestation, "utf8"));
        metadata.appDigest = "0".repeat(64);
        metadata.prepareBindingSha256 = prepareBindingSha256({
          archiveSha256: metadata.archive.sha256,
          appDigest: metadata.appDigest,
          entryListSha256: metadata.archive.entryListSha256,
        });
        writeFileSync(input.attestation, `${JSON.stringify(metadata, null, 2)}\n`);
      } else {
        options = { signingSourceCommit: "b".repeat(40) };
      }
      const { env, logPath } = makeSigningOnlyStubs(scratch, input, options);

      const result = runPackage(env);

      assert.notEqual(result.status, 0, mismatch);
      assert.match(result.stderr, /digest does not match|sourceCommit mismatch/i, mismatch);
      const log = existsSync(logPath) ? readFileSync(logPath, "utf8") : "";
      assert.doesNotMatch(log, /security:create-keychain|codesign:sign|notarytool/, mismatch);
    });
  }
});

test("signing rejects traversal and symlink archives before credential materialization", () => {
  for (const [kind, memberSetup] of [
    [
      "traversal",
      `
bad = tarfile.TarInfo("Seer.app/../../escaped")
bad.mode = 0o644
bad.size = 4
output.addfile(bad, io.BytesIO(b"evil"))
`,
    ],
    [
      "symlink",
      `
bad = tarfile.TarInfo("Seer.app/redirect")
bad.type = tarfile.SYMTYPE
bad.linkname = "/etc/passwd"
output.addfile(bad)
`,
    ],
  ]) {
    withScratch(`release-sign-${kind}-`, (scratch) => {
      const inputDir = join(scratch, "input");
      mkdirSync(inputDir);
      const archive = join(inputDir, "Seer-unsigned-arm64.tar");
      const python = `
import io, tarfile
with tarfile.open(${JSON.stringify(archive)}, "w", format=tarfile.USTAR_FORMAT) as output:
    root = tarfile.TarInfo("Seer.app")
    root.type = tarfile.DIRTYPE
    root.mode = 0o755
    output.addfile(root)
    ${memberSetup.trim().replaceAll("\n", "\n    ")}
`;
      const created = spawnSync("/usr/bin/python3", ["-c", python], { encoding: "utf8" });
      assert.equal(created.status, 0, created.stderr);
      const bytes = readFileSync(archive);
      const sha256 = createHash("sha256").update(bytes).digest("hex");
      const attestation = join(inputDir, "unsigned-app-attestation.json");
      writeFileSync(
        attestation,
        `${JSON.stringify(
          canonicalReleaseInputAttestation({
            archiveSha256: sha256,
            archiveSize: bytes.length,
            entries: [
              "Seer.app/",
              kind === "traversal" ? "Seer.app/../../escaped" : "Seer.app/redirect",
            ],
          }),
          null,
          2,
        )}\n`,
      );
      const input = { archive, attestation, sha256 };
      const { env, logPath } = makeSigningOnlyStubs(scratch, input);

      const result = runPackage(env);

      assert.notEqual(result.status, 0, kind);
      assert.match(result.stderr, /unsafe archive entry|links are forbidden/i, kind);
      const log = existsSync(logPath) ? readFileSync(logPath, "utf8") : "";
      assert.doesNotMatch(log, /security:create-keychain|codesign:sign|notarytool/, kind);
      assert.ok(!existsSync(join(scratch, "escaped")));
    });
  }
});

test("signing-only flow cleans credentials before repository code and never runs build tools", async () => {
  await withScratchAsync("release-sign-success-", async (scratch) => {
    rmSync(releaseRoot, { recursive: true, force: true });
    const input = createAttestedInput(scratch);
    const {
      backgroundEnvironment,
      defaultKeychainState,
      env,
      keychainPointer,
      logPath,
      nodeEnvironment,
      precredentialAttackMarker,
      precredentialCommandLog,
    } = makeSigningOnlyStubs(scratch, input, { backgroundAttack: true });

    const result = runPackage(env);

    assert.equal(result.status, 0, `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
    assert.deepEqual(readdirSync(releaseRoot).sort(), [
      "SHA256SUMS",
      "Seer-v1.2.3-arm64.dmg",
      "release-manifest.json",
    ]);
    const dmgPath = join(releaseRoot, "Seer-v1.2.3-arm64.dmg");
    const dmgSha256 = createHash("sha256").update(readFileSync(dmgPath)).digest("hex");
    assert.equal(
      readFileSync(join(releaseRoot, "SHA256SUMS"), "utf8"),
      `${dmgSha256}  Seer-v1.2.3-arm64.dmg\n`,
    );
    assert.deepEqual(JSON.parse(readFileSync(join(releaseRoot, "release-manifest.json"), "utf8")), {
      artifacts: [{ name: "Seer-v1.2.3-arm64.dmg", sha256: dmgSha256, size: 23 }],
      bundleIdentifier: "ai.opencoven.seer",
      notarization: "accepted",
      sourceCommit: "a".repeat(40),
      version: "1.2.3",
      workflowRun: "123",
    });
    const log = readFileSync(logPath, "utf8");
    assert.doesNotMatch(log, /FORBIDDEN-BUILD-TOOL/);
    assert.equal((log.match(/^notarytool:api-key$/gm) ?? []).length, 2);
    assert.equal((log.match(/^spctl$/gm) ?? []).length, 2);
    assert.equal((log.match(/^node:boundary$/gm) ?? []).length, 2);
    assert.ok(
      log.indexOf("security:delete-keychain") < log.indexOf("node:manifest"),
      `credential cleanup must precede manifest code:\n${log}`,
    );
    assert.ok(
      log.indexOf("security:delete-keychain") < log.lastIndexOf("node:boundary"),
      `credential cleanup must precede final boundary code:\n${log}`,
    );
    assert.equal(
      readFileSync(defaultKeychainState, "utf8").trim(),
      join(scratch, "login.keychain-db"),
    );
    const keychainPath = readFileSync(keychainPointer, "utf8").trim();
    assert.ok(!existsSync(keychainPath));

    const capturedNodeEnvironment = readFileSync(nodeEnvironment, "utf8");
    assert.doesNotMatch(capturedNodeEnvironment, /^APPLE_/m);
    for (const value of credentialValues) {
      assert.ok(!capturedNodeEnvironment.includes(value), `repository Node received ${value}`);
    }
    await waitForFile(backgroundEnvironment);
    const capturedBackgroundEnvironment = readFileSync(backgroundEnvironment, "utf8");
    assert.doesNotMatch(capturedBackgroundEnvironment, /^APPLE_/m);
    for (const value of credentialValues) {
      assert.ok(!capturedBackgroundEnvironment.includes(value), `background process received ${value}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 1_100));
    assert.ok(
      !existsSync(precredentialAttackMarker),
      "a repository helper must never execute early enough to daemonize before credential teardown",
    );
    const allowedPrecredentialTools = new Set([
      "/bin/mkdir",
      "/bin/rm",
      "/bin/rmdir",
      "/usr/bin/codesign",
      "/usr/bin/lipo",
      "/usr/bin/mktemp",
      "/usr/bin/plutil",
      "/usr/bin/shasum",
      "/usr/bin/stat",
      "/usr/bin/tar",
      "/usr/bin/uname",
    ]);
    const commandLog = readFileSync(precredentialCommandLog, "utf8").trim().split("\n");
    const credentialMarker = commandLog.indexOf("# CREDENTIAL PHASE");
    assert.notEqual(credentialMarker, -1);
    for (const command of commandLog.slice(0, credentialMarker)) {
      assert.ok(allowedPrecredentialTools.has(command), `unexpected precredential command: ${command}`);
    }
    assertNoPackagingLeaves();
  });
});

test("repository code stays blocked if credential teardown fails", () => {
  withScratch("release-sign-cleanup-failure-", (scratch) => {
    rmSync(releaseRoot, { recursive: true, force: true });
    const input = createAttestedInput(scratch);
    const { env, logPath, nodeEnvironment } = makeSigningOnlyStubs(scratch, input, {
      credentialCleanupFailure: true,
    });

    const result = runPackage(env);

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /credential teardown/i);
    const log = readFileSync(logPath, "utf8");
    assert.doesNotMatch(log, /^node:/m);
    assert.ok(!existsSync(nodeEnvironment));
    assert.ok(!existsSync(releaseRoot));
    assertNoPackagingLeaves();
  });
});

for (const [signal, pauseAt, expectedStatus] of [
  ["SIGINT", "after-keychain", 130],
  ["SIGTERM", "after-dmg-attach", 143],
]) {
  test(`${signal} signing interruption ${pauseAt} destroys private state`, async () => {
    await withScratchAsync(`release-sign-${signal.toLowerCase()}-`, async (scratch) => {
      rmSync(releaseRoot, { recursive: true, force: true });
      removePackagingLeavesForTest();
      const input = createAttestedInput(scratch);
      const {
        defaultKeychainState,
        env,
        keychainPointer,
        logPath,
        mountPointer,
        pauseReady,
      } = makeSigningOnlyStubs(scratch, input, { pauseAt });
      const run = runPackageAsync(env);
      let closed = false;
      run.completed.then(() => {
        closed = true;
      });
      try {
        await waitForFile(pauseReady);
        process.kill(-run.child.pid, signal);
        const result = await run.completed;
        assert.equal(result.signal, null);
        assert.equal(result.code, expectedStatus, `stdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
        assert.equal(
          readFileSync(defaultKeychainState, "utf8").trim(),
          join(scratch, "login.keychain-db"),
        );
        const keychainPath = readFileSync(keychainPointer, "utf8").trim();
        assert.ok(!existsSync(keychainPath), "temporary keychain must be deleted");
        const log = readFileSync(logPath, "utf8");
        assert.match(log, /^security:delete-keychain$/m);
        if (pauseAt === "after-dmg-attach") {
          const mountPath = readFileSync(mountPointer, "utf8").trim();
          assert.ok(!existsSync(mountPath), "mounted DMG must be detached");
          assert.match(log, /^hdiutil:detach$/m);
        }
        assert.ok(!existsSync(releaseRoot));
        assertNoPackagingLeaves();
      } finally {
        if (!closed) {
          try {
            process.kill(-run.child.pid, "SIGKILL");
          } catch (error) {
            if (error.code !== "ESRCH") throw error;
          }
          await run.completed;
        }
        removePackagingLeavesForTest();
      }
    });
  });
}
