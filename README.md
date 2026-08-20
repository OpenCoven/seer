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

## Standalone macOS distribution

The standalone Swift/AppKit application and signed release pipeline are
implemented:

- [Standalone distribution design](docs/superpowers/specs/2026-08-10-seer-standalone-macos-distribution.md)
- [Standalone implementation plan](docs/superpowers/plans/2026-08-10-seer-standalone-macos-distribution.md)
- [Apple release credential packet](docs/apple-release-credential-packet.md)

Signing, notarization, and release credentials are secrets scoped to the
protected `macos-release` GitHub environment, not repository-scoped secrets.

## Security

This repository is public and contains no credentials. Before your first
commit, install the pre-commit protocol:

```sh
pre-commit install
```

That runs [gitleaks](https://github.com/gitleaks/gitleaks) and
`detect-private-key` against every staged change. The same gitleaks scan runs
server-side over the full history in
[`.github/workflows/secret-scan.yml`](.github/workflows/secret-scan.yml), so
skipping the hook does not skip the check.

To scan by hand:

```sh
gitleaks git . --redact      # full history
gitleaks dir . --redact      # working tree
```

`gitleaks dir` walks the whole directory, including untracked and ignored
local build output such as `build/`, `node_modules/`, and any `.worktrees/`
checkouts. Findings under those paths are local scratch, not repository
content — CI scans a clean checkout and never sees them. Confirm the path is
actually tracked (`git ls-files --error-unmatch <path>`) before treating a
`gitleaks dir` result as a leak.

Suppressions live in `.gitleaksignore` and are limited to fingerprint-pinned
false positives with a written justification. Never add a bare path or rule
suppression, and never commit a real credential — Apple signing and
notarization secrets belong only in the protected `macos-release` GitHub
environment (see
[`docs/apple-release-credential-packet.md`](docs/apple-release-credential-packet.md)).

Report vulnerabilities privately: see [`SECURITY.md`](SECURITY.md).

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
   `UNSIGNED_APP_ATTESTATION_SHA256`. The protected environment supplies all
   approval-critical release configuration through environment secrets.

Configure these sensitive secret *names* in `macos-release`; never put their
values in source, logs, artifacts, or documentation:

- Signing: `APPLE_CERTIFICATE` and `APPLE_CERTIFICATE_PASSWORD`
- Notarization: exactly one complete set — `APPLE_API_ISSUER`,
  `APPLE_API_KEY`, and `APPLE_API_KEY_BASE64`; or the fallback `APPLE_ID` and
  `APPLE_PASSWORD`
- Publication: `RELEASES_REPO_TOKEN`, a fine-grained token restricted to
  contents/release writes and read-only immutable-release configuration in
  `OpenCoven/seer-releases`, with no private-source access. That protected token
  identity must be the repository's sole release writer.

The following semantically non-sensitive protected configuration values must
be stored as `macos-release` environment secrets:
`BINARY_DISTRIBUTION_APPROVED`, `PARITY_MATRIX_APPROVED`,
`CLEAN_MACHINE_VERIFIED_COMMIT`, `RELEASE_WRITER_LOGIN`, `RELEASE_WRITER_ID`,
`APPLE_SIGNING_IDENTITY`, and `APPLE_TEAM_ID`. Do not store them as Actions
variables. Secret storage deliberately gives the environment copy precedence
over repository and organization secrets and binds it to environment approval.
Provision each of these seven names with
`gh secret set <NAME> --repo OpenCoven/seer --env macos-release`. Together with
the eight possible sensitive names above, they form the authoritative 15-name
union audit set; the active environment still contains exactly one notarization
method, never both. Same-named repository secrets must be absent, and
organization secrets must be absent or restricted so `OpenCoven/seer` cannot
access them. Verify only names and timestamps with the environment-scoped
`gh secret list --json name,updatedAt` command; never print values, including
the non-sensitive configuration.

The protected environment must require reviewers and define these release
gates and exact writer bindings:

- `BINARY_DISTRIBUTION_APPROVED` must be exactly `true`
- `PARITY_MATRIX_APPROVED` must be exactly `true`
- `CLEAN_MACHINE_VERIFIED_COMMIT` must be the lowercase 40-character release
  commit and must equal the workflow's `GITHUB_SHA`
- `RELEASE_WRITER_LOGIN` and `RELEASE_WRITER_ID` must exactly identify the
  fine-grained token owner returned by GitHub's API
- `APPLE_SIGNING_IDENTITY` must be the exact Developer ID Application authority,
  and `APPLE_TEAM_ID` must be its 10-character Apple team identifier

`OpenCoven/seer-releases` must have GitHub immutable releases enabled. The
workflow verifies that repository setting before release work and verifies the
published release is immutable. GitHub does not support `If-Match` compare and
swap for release `PATCH`: one repository-wide workflow concurrency group and an
atomically created, tag-scoped remote lock ref serialize cooperative runs. The
workflow twice exhaustively paginates the authenticated release list before the
first publication `PATCH` and requires the two normalized inventories to match.
Each bounded scan stops only on a short page; reaching the configured maximum
with a full page fails rather than silently truncating. Among all authenticated
stable published releases, every candidate must have a positive safe ID,
`draft=false`, `prerelease=false`, `immutable=true`, and one unique bounded
canonical `vMAJOR.MINOR.PATCH` tag. Each stable candidate and the authenticated
`/releases/latest` response must also have the exact protected release writer
as author and exactly its versioned three-name public asset allowlist, with
every uploader equal to that writer. Inventory validation uses metadata only;
it does not download historical assets. Drafts and prereleases cannot affect
the maximum, while the current draft must have its exact verified ID and tag in
the inventory. The authenticated `/releases/latest` identity must equal that
fully trusted global semantic-version maximum, or return the canonical 404 when
the stable set is empty. Only then does a strictly newer or first release use
explicit `make_latest: "true"`; a lower backport uses `make_latest: "false"`,
and a same version fails.

Inventory and `/releases/latest` selection finish before final draft
verification. The workflow then refetches the selected draft metadata and
freshly downloads the exact asset IDs, compares metadata, local notes,
uploaders, digests, and bytes with the captured verified state, and finally
rechecks the source tag, destination anchor/tag, and remote lock immediately
before `PATCH`. GitHub release `PATCH` has no supported `If-Match`
compare-and-swap, so an unavoidable non-atomic API boundary remains after the
final draft comparison. It contains only the required source-tag, destination,
and lock reads followed by `PATCH`; after the final remote-lock response,
`PATCH` is the immediate request. No scan, download, build, or other
long-running work occurs in that narrow boundary.

Post-publication verification refetches a fresh exhaustive inventory and
`/releases/latest`, requires the current release to appear as stable and
immutable, and proves that the pointer equals the fresh global maximum rather
than reusing the earlier decision. Published reconciliation on a retry likewise
refetches a fresh inventory and authenticated `/releases/latest` without an
earlier decision file. The current published release must appear exactly in the
inventory; an intervening higher release is accepted only when it is genuinely
the global maximum and `/releases/latest` has its exact ID and tag. Malformed or
duplicate stable entries, list mutation, truncation, pointer mismatch, ambiguous
responses, or API errors fail before `published=true`; reconciliation never
mutates immutable metadata. The annotated lock binds the source tag, commit,
workflow run, and attempt to an existing release-repository commit; every
mutating phase revalidates it, and an `always()` step deletes only that exact
owned lock ref.

Only these public asset names are allowed:

```text
Seer-vX.Y.Z-arm64.dmg
SHA256SUMS
release-manifest.json
```

Release notes are generated separately without local paths. The workflow
creates/resumes a provenance-bound draft, downloads and verifies those assets,
and publishes only after signing, notarization, stapling, Gatekeeper, checksum,
and boundary checks pass. Immediately before the supported publish `PATCH`, it
refetches metadata and freshly downloads every asset to compare IDs, sizes,
server digests, uploader identity, and hashes with captured verified state. It
refetches again after publication and fails loudly on any mismatch without
deleting the release.

Three external administrative actions each require a separate, explicit
approval: (1) create the public `OpenCoven/seer-releases` repository, (2)
configure the protected `macos-release` environment, required reviewers, and
its protected configuration and credential secrets (including the fine-grained
token), and (3) publish the first public binary.
Repository automation does not create or configure those resources, and
approval of one action does not approve either of the others.

## Provenance

Seer remains a Glaze remix of Stay Awake 6.0.0 by Samuel Kraft. The source
grant and version metadata remain in `package.json`; standalone delivery does
not remove the Glaze target or its provenance.
