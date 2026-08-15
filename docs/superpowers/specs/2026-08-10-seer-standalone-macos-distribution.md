# Seer Standalone macOS Distribution Design

## Summary

Seer will gain a clean, standalone macOS application that users can download
from GitHub and run without Glaze or Node.js installed.

The standalone application will use an AppKit host, a WKWebView containing the
existing React panel, and native Swift services for agent detection, history,
settings, sleep prevention, updates, and application lifecycle. It will not
embed, copy, or redistribute Glaze host binaries or runtime code.

The current Glaze application will remain available during migration as the
behavioral reference. The standalone target replaces it only after both targets
pass the same parity matrix.

## Decisions

- Delivery is a signed and notarized standalone macOS application.
- The initial release supports Apple Silicon on macOS 14 or newer.
- Native lifecycle and services are implemented in Swift.
- The existing React panel is retained behind a platform-neutral bridge.
- The Glaze and standalone targets coexist until behavioral parity is proven.
- Standalone Seer starts with fresh settings and history.
- Updates are notify-only; Seer never downloads or executes an update.
- The app uses Hardened Runtime without App Sandbox.
- Source remains private.
- Public binaries are published through `OpenCoven/seer-releases`.
- Signing and notarization credentials are repository-scoped GitHub secrets.

## Goals

- Preserve Seer's agent detection, keep-awake modes, history calculations,
  menu-bar behavior, and panel experience.
- Remove Glaze and Node.js from the standalone runtime.
- Reuse the proven React UI without giving web content broad native access.
- Produce a Developer ID signed, notarized, and stapled arm64 application and
  DMG.
- Make every public artifact traceable to a private source revision without
  publishing source or source maps.
- Keep the Glaze application operational until the standalone target is ready.

## Non-Goals

- Intel support.
- macOS 13 or earlier.
- Mac App Store distribution or App Sandbox support.
- Automatic update installation.
- Importing settings or history from the Glaze application.
- Public source distribution.
- Permanent maintenance of two product editions.
- New agent families or changed detection heuristics during the migration.
- Redistributing any Glaze native host, SDK, runtime, or signing identity.

## Repository Layout

The existing Glaze target remains in place during the parity period:

```text
main/
renderer/
main-window.html
glaze.ts
```

The standalone target is added under:

```text
apps/macos/Seer/
  project.yml
  Config/
  Sources/
    App/
    Bridge/
    Detection/
    History/
    Power/
    Storage/
    Updates/
  Tests/
scripts/
  build-standalone-renderer.mjs
  build-macos-app.sh
  package-macos-release.sh
```

XcodeGen owns project generation. The generated `.xcodeproj`, DerivedData,
renderer output, archives, applications, DMGs, notarization logs, and release
staging directories are ignored and never committed.

## Application Identity

The standalone application uses:

- Product name: `Seer`
- Bundle identifier: `ai.opencoven.seer`
- Minimum system: macOS 14.0
- Architecture: arm64
- Activation policy: accessory
- Runtime: Hardened Runtime, not App Sandbox

`CFBundleShortVersionString` is the semantic version without the leading `v`.
`CFBundleVersion` is a monotonically increasing workflow build number. Release
tags use `vMAJOR.MINOR.PATCH`.

The bundle identifier and Application Support directory are independent of the
Glaze app ID. Both applications can run during parity testing without sharing
settings, history, tray placement identity, caches, or logs.

## Architecture

### AppKit Host

The AppKit target owns:

- application startup and termination
- accessory activation policy
- `NSStatusItem` creation and updates
- transient `NSPanel` creation, placement, focus, blur, and Escape behavior
- application and tray menus
- service initialization and orderly shutdown
- WKWebView configuration and navigation policy

The app has no Dock icon and no persistent main window. Left-clicking the
status item toggles the panel. Right-clicking opens native quick actions.
Clicking away or pressing Escape hides the panel. Quit flushes history, releases
power assertions, stops polling, and then terminates.

### Renderer

The Status and History views remain React and TypeScript. Renderer code stops
calling `window.glazeAPI` directly and instead depends on one
`RendererBridge` interface.

Two adapters implement that interface during migration:

- `GlazeRendererBridge` delegates to the existing allowlisted Glaze IPC calls.
- `StandaloneRendererBridge` delegates to the injected WKWebView bridge.

The shared interface exposes only Seer product operations:

- get the current application snapshot
- set the keep-awake mode
- clear history
- subscribe to snapshot changes
- request an update check
- open the current release page
- quit Seer

Glaze template APIs unrelated to Seer are not reproduced.

The standalone Vite entry emits hashed HTML, JavaScript, CSS, fonts, and images
into a generated resource directory. Production source maps are disabled.
WKWebView loads only bundled resources through a private scheme handler or
read-only bundle URL. Navigation to untrusted content is denied.

### Native Bridge

The native bridge is versioned independently of persisted data:

```text
seer.bridge.v1
```

Requests contain a unique request ID, a known method, and a method-specific
payload. Swift decodes each payload into a concrete `Decodable` type. Unknown
methods, extra privilege-bearing fields, invalid enum values, oversized
messages, and malformed JSON are rejected with typed errors.

The page never receives a generic command executor, shell API, filesystem API,
process API, URL opener, clipboard API, or raw WebKit message handler. Opening
an update is limited to the exact HTTPS release URL produced by the update
service.

Swift sends renderer events as structured values through
`callAsyncJavaScript`, not by interpolating JSON into executable source.
WKWebView developer tools are disabled in release builds.

### State Coordinator

A `@MainActor` application coordinator is the single authority for visible
state. It owns an immutable `AppSnapshot` containing:

- monitor state
- keep-awake state and selected mode
- history statistics
- update availability
- recoverable diagnostics
- app version

Background services return values or typed errors. The coordinator applies a
completed scan as one transition, then updates the power assertion, history,
tray, and renderer from that transition. Consumers never observe a partial
scan.

## Native Services

### Agent Detection

Detection preserves the current supported families and three-second cadence:

- Claude Code
- Codex
- Grok
- Gemini CLI
- Aider
- OpenCode
- Goose
- Amp
- Cursor
- Continue

The Swift detector is split into testable sources:

- a process snapshot source based on macOS process APIs
- session and transcript sources for agent-specific local data
- family-specific classifiers
- one merger that produces stable `ActiveAgent` values

Process inspection uses native APIs such as `libproc` and bounded `sysctl`
queries. It does not run a shell or concatenate user-controlled commands.
Session readers open only known agent paths beneath the current user's home
directory, cap file sizes and traversal counts, and reject paths that escape
their configured roots.

Scans run away from the main actor and cannot overlap. A failed scan preserves
the last successful state rather than falsely declaring all agents idle. The
failure is published as a diagnostic and cleared after the next successful
scan.

### Power Assertions

The Swift power service owns exactly one IOKit assertion.

- `system` prevents idle system sleep.
- `display` prevents idle display sleep and therefore system sleep.

Changing mode while active replaces the assertion atomically. Failed assertion
creation leaves `keepingAwake` false and surfaces a diagnostic; it is never
reported as success. Shutdown always releases the active assertion.

### Settings

Standalone settings begin with:

```json
{
  "version": 1,
  "keepAwakeMode": "system",
  "includePrereleaseUpdates": false
}
```

No Glaze settings are read or imported.

### History

The Swift history service preserves these existing invariants:

- three-second polling cadence
- at most fifteen seconds accumulated for one delayed tick
- sessions shorter than one second are discarded
- at most 100 stored sessions
- at most 40 recent sessions returned to the renderer
- at most 60 daily aggregate keys
- five-second debounced persistence while active
- synchronous close and flush during orderly shutdown

The renderer-facing `AwakeSession`, `AgentUsage`, and `HistoryStats` shapes
remain behaviorally equivalent to the TypeScript target.

### Storage

Standalone data lives under:

```text
~/Library/Application Support/ai.opencoven.seer/
  settings.json
  history.json
```

Both documents have explicit schema versions. Writes go to a sibling temporary
file, are flushed, and replace the destination atomically. Writes are serialized
per document.

Missing files create defaults. Unsupported future schema versions fail visibly
without overwriting the file. Invalid or corrupt files are renamed with a
timestamped `.corrupt-` suffix and surfaced in the panel before fresh data is
created. The app does not silently discard unreadable history.

### Notify-Only Updates

At startup and no more than once every 24 hours while running, the update
service requests:

```text
https://api.github.com/repos/OpenCoven/seer-releases/releases/latest
```

The request is unauthenticated, uses an explicit User-Agent, honors ETag
caching, has a short timeout, and sends no local agent, history, path, or
machine data.

Versions are compared as semantic versions. The stable channel uses
`releases/latest`. If the user enables prereleases, the service instead requests
the bounded releases list and chooses the newest semantic version. Drafts are
always ignored. When a newer release exists, the panel and native menu show an
update notice. User action opens the exact HTTPS GitHub release page. Seer does
not download, mount, install, replace, or execute update content.

Network failures are non-fatal and do not interrupt monitoring.

## Parallel Migration and Cutover

The targets coexist only during migration.

1. Introduce the platform-neutral renderer interface without changing Glaze
   behavior.
2. Add the AppKit shell and standalone renderer build.
3. Port detection, power, settings, and history into isolated Swift services.
4. Add update notification and release packaging.
5. Run both targets against the same fixture corpus and manual parity matrix.
6. Release standalone Seer only after every gate passes.
7. Remove the Glaze runtime target in a separate, explicitly approved change.

The two targets never share writable application data. Standalone Seer starts
fresh, as requested.

## Build and Test Strategy

### Pull Requests

Private-repository CI runs:

- `npm ci`
- renderer unit tests
- renderer type checking and linting
- standalone renderer production build with no source maps
- XcodeGen project generation
- Swift formatting or linting already adopted by the repository
- Swift unit tests
- arm64 Debug and Release builds
- source-boundary scans proving no Glaze imports or binaries enter the
  standalone target

Signing and notarization do not run on untrusted pull-request code.

### Swift Unit Tests

Tests cover:

- Codable bridge and storage schemas
- rejection of invalid bridge methods and payloads
- agent-family classifiers with captured, sanitized fixtures
- process/session merge behavior and stable IDs
- scan overlap prevention and error-state retention
- both power modes through an injected assertion boundary
- history accumulation, caps, debounce, day rollover, and shutdown flush
- atomic writes and corrupt-file quarantine
- semantic-version and prerelease comparison
- update response validation and ETag behavior

### Integration Tests

Integration tests launch the AppKit target with injected fake services and
verify:

- WKWebView bootstrap and initial snapshot
- native-to-renderer event delivery
- renderer-to-native mode changes and history clearing
- tray state transitions
- panel toggle, Escape, blur, and quit behavior
- navigation denial and release-URL allowlisting

### Manual Parity Matrix

Before release, both targets must pass:

- idle and active tray states
- left-click panel toggle
- right-click quick menu
- Status and History routes
- all supported agent fixtures
- System and System + Display modes
- blocker start, mode replacement, and stop
- history totals, per-agent totals, recent sessions, and clear
- relaunch persistence
- fresh standalone storage
- Escape and blur hiding
- notify-only update prompt
- clean shutdown and assertion release

## Signing, Notarization, and Packaging

The release target uses Hardened Runtime and no App Sandbox entitlement. The
entitlements file contains only capabilities demonstrated to be necessary.
The app is signed with an OpenCoven Developer ID Application identity.

Repository secrets follow the existing OpenCoven macOS convention:

| Secret | Purpose |
| --- | --- |
| `APPLE_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Exact Developer ID identity |
| `APPLE_API_ISSUER` | App Store Connect issuer UUID |
| `APPLE_API_KEY` | App Store Connect key ID |
| `APPLE_API_KEY_BASE64` | Base64-encoded `.p8` key |
| `APPLE_ID` | Apple ID for the supported notarization fallback |
| `APPLE_PASSWORD` | App-specific password for the notarization fallback |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `RELEASES_REPO_TOKEN` | Fine-grained token limited to contents/release writes and immutable-release configuration reads in `OpenCoven/seer-releases`; its exact identity is the sole release writer |

App Store Connect API-key authentication is the default notarization path.
`APPLE_ID`, `APPLE_PASSWORD`, and `APPLE_TEAM_ID` provide the documented
fallback if API-key authentication is unavailable; the workflow selects one
complete credential set and fails rather than mixing partial sets.

The workflow creates a temporary keychain and deletes key material and the
keychain in an `always()` cleanup step. Secret values are never written to
artifacts or logs.

The release workflow:

1. Checks out the exact private source tag.
2. verifies the tag matches the app version.
3. Runs the complete pull-request gate.
4. Builds the production renderer without source maps.
5. Archives an arm64 Release application for macOS 14+.
6. Signs nested code and the app with Hardened Runtime and a secure timestamp.
7. Verifies signatures with `codesign --verify --deep --strict`.
8. Submits the app to `notarytool` and waits for acceptance.
9. Staples and validates the notarization ticket.
10. Builds and signs `Seer-vX.Y.Z-arm64.dmg`.
11. Verifies Gatekeeper acceptance with `spctl`.
12. Generates `SHA256SUMS` and a release manifest containing version, bundle
    identifier, source commit, workflow run, artifact hashes, and notarization
    result.
13. Creates a draft release in `OpenCoven/seer-releases`.
14. Uploads only the DMG, checksum file, release manifest, and release notes.
15. Downloads and re-verifies every uploaded artifact.
16. Publishes the release only after all checks pass.

Before step 13, the workflow acquires a tag-scoped lock ref atomically in the
release repository. Its annotated tag binds the source tag, source commit,
workflow run, and attempt to a verified existing release-repository commit.
Workflow concurrency and this lock replace unsupported release `If-Match`
compare-and-swap semantics. Every mutating phase verifies exact lock ownership;
an `always()` step removes only the owned lock ref.

The public release repository contains a product README and release metadata,
not application source. Its automatically generated source archive therefore
contains only that public repository's metadata.

## Release Security and Failure Handling

- Public release is impossible until all build, signature, notarization,
  Gatekeeper, checksum, and upload-verification steps pass.
- Failed workflows leave no published partial release. A draft may remain for
  maintainers to inspect or delete.
- The cross-repository token is fine-grained and cannot read private source.
- GitHub immutable releases must be enabled and is verified through the
  repository API before release work. The published release must report itself
  immutable.
- The protected token's API login and numeric ID must match the configured
  writer, and every release author and asset uploader must match that identity.
- Immediately before publication, the workflow refetches canonical metadata
  and freshly downloads every asset to compare release/asset IDs, sizes, server
  digests, uploader identities, and hashes with captured state. It refetches
  after the normal `draft:false` PATCH; any mismatch fails loudly and never
  deletes the release.
- Release jobs use a protected GitHub environment with required approval.
- Workflow actions are pinned to immutable commit SHAs.
- The build fails if the runner is not arm64.
- Release archives are scanned for source maps, source files, local absolute
  paths, credentials, Glaze binaries, and Glaze runtime imports.
- A public binary release additionally requires confirmation that the retained
  remix grant permits binary distribution. The workflow does not substitute for
  that legal/product approval.

## Public Artifacts

The public release contains only:

```text
Seer-vX.Y.Z-arm64.dmg
SHA256SUMS
release-manifest.json
release notes
```

It does not contain:

- private source
- source maps
- test fixtures
- development logs
- symbol archives
- signing credentials
- App Store Connect credentials
- local paths or user data
- Glaze host, SDK, runtime, or signing material

## Acceptance Criteria

Standalone GitHub delivery is ready only when:

1. The app launches on a clean Apple Silicon Mac running macOS 14 without Glaze
   or Node.js installed.
2. The complete automated test suite and manual parity matrix pass.
3. `codesign`, `notarytool`, stapling validation, and `spctl` all succeed.
4. The DMG installs a working accessory app with the correct identity and icon.
5. No Glaze binary or runtime dependency exists in the standalone bundle.
6. No private source, source map, secret, or local path exists in public
   artifacts.
7. Update notification identifies a newer public release and opens only its
   GitHub page.
8. Fresh standalone storage remains isolated from the Glaze application.
9. Release checksums match freshly downloaded public assets.
10. Val separately approves the first public binary release.

## Delivery Boundary

This design authorizes planning and implementation inside the private Seer
repository after the written specification is approved. It does not by itself
authorize creating the public repository, configuring secrets, publishing
binaries, tagging a release, deleting the Glaze target, or making the source
public. Each irreversible or externally visible action still requires explicit
approval.
