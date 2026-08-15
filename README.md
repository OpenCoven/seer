# Seer

Seer is a macOS menu-bar utility that keeps the Mac awake while AI coding
agents work. It detects supported agents from local processes and session data,
shows live state without a Dock icon, records local history, and releases its
power assertion when work stops.

## Delivery targets

The existing Electron/Glaze app remains the reference target. It is not removed
or replaced by this delivery:

```bash
npm run dev
```

`npm run build`, `npm run type-check`, and `npm run lint` also address the Glaze
target and require its authorized private SDK/toolchain.

The standalone target is a native Swift/AppKit app with the shared renderer
bundled as local resources. Use its lock-safe entry points rather than invoking
Vite, XcodeGen, or `xcodebuild` directly:

```bash
npm run build:standalone-renderer
npm run generate:macos
npm run test:macos
npm run build:macos
```

The unsigned local app is published to
`build/macos/unsigned/Seer.app`. The standalone bundle contains neither Glaze
nor a Node.js runtime; Node is a build-time tool only.

## Requirements

- Apple Silicon Mac running macOS 14 or later
- Xcode 16.2
- XcodeGen 2.46.0; local runs must use this pinned version, and the release
  workflow downloads the pinned archive and verifies its SHA-256
- Node.js 24.11 or later and npm; install the lockfile exactly with `npm ci`
- Authorized Glaze SDK/host 0.13.0.0+ only when running the retained Glaze
  reference target

The native target has App Sandbox disabled because it must inspect local agent
process/session state. Signed distribution enables Hardened Runtime and uses a
Developer ID Application signature.

## Development and checks

Install dependencies:

```bash
npm ci
```

Shared and standalone checks:

```bash
npm test
npm run test:renderer
npm run type-check:standalone
npm run lint:standalone
npm run test:macos
npm run build:macos
npm run check:standalone-boundary
node --test tests/standalone-boundary.test.mjs
```

The generated Xcode project and every native build/release product are ignored.
Do not commit them.

## Architecture

- `main/` — retained Glaze lifecycle, detection, monitoring, storage, tray,
  panel, and IPC
- `renderer/` — shared Status and History UI plus the standalone bridge
- `apps/macos/Seer/` — native AppKit host, services, storage, and Swift tests
- `scripts/` — lock-safe renderer/native build and release boundary tooling
- `glaze.ts` — resolves the authorized Glaze SDK/CLI for the reference target

## Data and updates

The targets deliberately use separate local storage:

- Glaze: `~/Library/Application Support/Seer`
- Fresh standalone install:
  `~/Library/Application Support/ai.opencoven.seer`

Both store `settings.json` and `history.json`; the standalone app does not
import Glaze/Stay Awake/Remix state. Updates are notify-only: Seer checks GitHub
release metadata and can open the validated release page, but never downloads,
installs, or relaunches an update automatically.

## Release administration

`.github/workflows/release-macos.yml` is the private-source, stable-semver-tag
release interface. It has two intentionally separate runner contracts:

1. **Credential-free preparation** runs the full standalone gate on a clean
   Apple Silicon runner, then invokes
   `bash scripts/prepare-macos-release-input.sh`. Its non-secret interface is
   `VERSION`, `BUILD_NUMBER`, `SOURCE_COMMIT`, and `PREPARE_RUNNER_ID`. Every
   `APPLE_*` variable is forbidden. It emits only
   `Seer-unsigned-arm64.tar` and `unsigned-app-attestation.json`, with their
   SHA-256 values, under `build/macos/release-input/`.
2. **Signing and publication** runs on a fresh, distinct Apple Silicon runner
   in the protected `macos-release` environment. It downloads only those two
   exact attested files and invokes `bash scripts/package-macos-release.sh`;
   it does not install dependencies or rebuild source while credentials are
   present. Its non-secret interface is `VERSION`, `BUILD_NUMBER`,
   `SOURCE_COMMIT`, `WORKFLOW_RUN`, distinct `PREPARE_RUNNER_ID` and
   `SIGNING_RUNNER_ID`, `UNSIGNED_APP_ARCHIVE`,
   `UNSIGNED_APP_ATTESTATION`, `UNSIGNED_APP_SHA256`, and
   `UNSIGNED_APP_ATTESTATION_SHA256`.

Configure these secret *names* in `macos-release`; never put their values in
source, logs, artifacts, or documentation:

- Signing: `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, and `APPLE_TEAM_ID`
- Notarization: exactly one complete set — `APPLE_API_ISSUER`,
  `APPLE_API_KEY`, and `APPLE_API_KEY_BASE64`; or the fallback `APPLE_ID` and
  `APPLE_PASSWORD` (with `APPLE_TEAM_ID`)
- Publication: `RELEASES_REPO_TOKEN`, a fine-grained token restricted to
  release writes in `OpenCoven/seer-releases`, with no private-source access

The protected environment must require reviewers and define all three release
gates:

- `BINARY_DISTRIBUTION_APPROVED` must be exactly `true`
- `PARITY_MATRIX_APPROVED` must be exactly `true`
- `CLEAN_MACHINE_VERIFIED_COMMIT` must be the lowercase 40-character release
  commit and must equal the workflow's `GITHUB_SHA`

Only these public asset names are allowed:

```text
Seer-vX.Y.Z-arm64.dmg
SHA256SUMS
release-manifest.json
```

Release notes are generated separately without local paths. The workflow
creates/resumes a provenance-bound draft, downloads and verifies those assets,
and publishes only after signing, notarization, stapling, Gatekeeper, checksum,
and boundary checks pass.

Three external administrative actions each require a separate, explicit
approval: (1) create the public `OpenCoven/seer-releases` repository, (2)
configure the protected `macos-release` environment, reviewers, variables,
secrets, and fine-grained token, and (3) publish the first public binary.
Repository automation does not create or configure those resources, and
approval of one action does not approve either of the others.

## Provenance

Seer remains a Glaze remix of Stay Awake 6.0.0 by Samuel Kraft. The source
grant and version metadata remain in `package.json`; standalone delivery does
not remove the Glaze target or its provenance.
