# Standalone macOS Parity Matrix

Manual parity evidence for the standalone macOS build (Task 13, Step 4 of
`docs/superpowers/plans/2026-08-10-seer-standalone-macos-distribution.md`).
This matrix is **not** a substitute for the automated integration tests in
`apps/macos/Seer/Tests/Integration/` — it exists to record *manual,
human-observed* parity between the existing Electron/Glaze application and
the standalone native app for scenarios that automated tests either cannot
fully observe (visual tray/menu state, real relaunch across process
restarts) or that this task's automated suite only partially exercises.

**No row in this document has been executed.** Every `Result` cell below is
`TODO` and every evidence cell is a placeholder. Do not mark any row `PASS`
until a tester has actually performed that exact scenario against both
applications and attached real evidence (a screenshot path or a log path)
— never leave a row `PASS` on the strength of the automated suite alone,
and never edit a row's `Result` without also filling in `Date`, `Tester`,
`Build commit`, and the evidence paths for both applications.

## How to execute a row

1. Build the Glaze (Electron) app and the standalone app from the **same**
   commit SHA.
2. Perform the exact scenario in the `Scenario` column against the Glaze
   app first, capturing a screenshot (`docs/parity-evidence/<row-slug>-glaze.png`)
   or log excerpt (`docs/parity-evidence/<row-slug>-glaze.log`) as
   `Glaze evidence`.
3. Perform the identical scenario against the standalone app, capturing
   `docs/parity-evidence/<row-slug>-standalone.png` or `.log` as
   `Standalone evidence`.
4. Fill in `Date` (ISO 8601), `Tester` (name/handle), and `Build commit`
   (the short SHA both builds were built from) in the `Notes` column.
5. Set `Result` to `PASS` only if both applications' observed behavior
   matches; set it to `FAIL` (with a description in `Notes`) otherwise.
   Leave `Result` as `TODO` until the row has actually been executed.

`docs/parity-evidence/` does not exist yet — create it (git-tracked) only
once the first row is actually executed; this document does not itself
create or claim any such artifact.

## Matrix

| Scenario | Glaze evidence | Standalone evidence | Result | Notes |
| --- | --- | --- | --- | --- |
| Idle tray icon/tooltip (no active agent) | TODO: `docs/parity-evidence/idle-tray-glaze.png` | TODO: `docs/parity-evidence/idle-tray-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Active tray icon/tooltip (one active agent) | TODO: `docs/parity-evidence/active-tray-glaze.png` | TODO: `docs/parity-evidence/active-tray-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Tray left-click toggles the panel directly (no menu) | TODO: `docs/parity-evidence/left-click-toggle-glaze.png` | TODO: `docs/parity-evidence/left-click-toggle-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Tray right-click presents the native menu (Open Seer, prevent-sleep mode, prerelease toggle, release link, Quit) | TODO: `docs/parity-evidence/right-click-menu-glaze.png` | TODO: `docs/parity-evidence/right-click-menu-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Route: main/status panel view | TODO: `docs/parity-evidence/route-status-glaze.png` | TODO: `docs/parity-evidence/route-status-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Route: `/history` panel view | TODO: `docs/parity-evidence/route-history-glaze.png` | TODO: `docs/parity-evidence/route-history-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Agent family detected: Claude Code (`claude-code`) | TODO: `docs/parity-evidence/family-claude-code-glaze.png` | TODO: `docs/parity-evidence/family-claude-code-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Agent family detected: Codex (`codex`) | TODO: `docs/parity-evidence/family-codex-glaze.png` | TODO: `docs/parity-evidence/family-codex-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Agent family detected: Grok (`grok`) | TODO: `docs/parity-evidence/family-grok-glaze.png` | TODO: `docs/parity-evidence/family-grok-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Agent family detected: Gemini (`gemini`) | TODO: `docs/parity-evidence/family-gemini-glaze.png` | TODO: `docs/parity-evidence/family-gemini-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Agent family detected: Aider (`aider`) | TODO: `docs/parity-evidence/family-aider-glaze.png` | TODO: `docs/parity-evidence/family-aider-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Agent family detected: opencode (`opencode`) | TODO: `docs/parity-evidence/family-opencode-glaze.png` | TODO: `docs/parity-evidence/family-opencode-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Agent family detected: Goose (`goose`) | TODO: `docs/parity-evidence/family-goose-glaze.png` | TODO: `docs/parity-evidence/family-goose-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Agent family detected: Amp (`amp`) | TODO: `docs/parity-evidence/family-amp-glaze.png` | TODO: `docs/parity-evidence/family-amp-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Agent family detected: Cursor (`cursor`) | TODO: `docs/parity-evidence/family-cursor-glaze.png` | TODO: `docs/parity-evidence/family-cursor-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Agent family detected: Continue (`continue`) | TODO: `docs/parity-evidence/family-continue-glaze.png` | TODO: `docs/parity-evidence/family-continue-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Keep-awake power mode: System (`system`) | TODO: `docs/parity-evidence/power-system-glaze.png` | TODO: `docs/parity-evidence/power-system-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Keep-awake power mode: Display (`display`) | TODO: `docs/parity-evidence/power-display-glaze.png` | TODO: `docs/parity-evidence/power-display-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Power-assertion mode replacement while an agent is still active (switch System → Display or back without dropping keep-awake) | TODO: `docs/parity-evidence/power-replace-glaze.png` | TODO: `docs/parity-evidence/power-replace-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| History rollups (today/total awake time, per-agent totals, recent sessions) | TODO: `docs/parity-evidence/history-rollups-glaze.png` | TODO: `docs/parity-evidence/history-rollups-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| History clear | TODO: `docs/parity-evidence/history-clear-glaze.png` | TODO: `docs/parity-evidence/history-clear-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Settings/history persistence across a relaunch (keep-awake mode, prerelease toggle, and history survive quit + relaunch) | TODO: `docs/parity-evidence/relaunch-persistence-glaze.png` | TODO: `docs/parity-evidence/relaunch-persistence-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Isolated storage under the same macOS account: seed unique, direction-tagged state in each app, relaunch both, and confirm neither observes the other's state (see "Isolated-storage row detail" below — a both-empty result is **not** valid evidence for this row) | TODO: `docs/parity-evidence/isolated-storage-glaze.log` + `docs/parity-evidence/isolated-storage-glaze.png` | TODO: `docs/parity-evidence/isolated-storage-standalone.log` + `docs/parity-evidence/isolated-storage-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Escape hides the panel | TODO: `docs/parity-evidence/escape-hides-glaze.png` | TODO: `docs/parity-evidence/escape-hides-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Clicking outside the panel (blur) hides it | TODO: `docs/parity-evidence/blur-hides-glaze.png` | TODO: `docs/parity-evidence/blur-hides-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Update notification (both apps checked against the same stubbed GitHub releases response — see note below) | TODO: `docs/parity-evidence/update-notification-glaze.png` or `.log` | TODO: `docs/parity-evidence/update-notification-standalone.png` or `.log` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Clean quit (Quit menu item / Cmd+Q terminates promptly, releases the power assertion, and flushes history) | TODO: `docs/parity-evidence/clean-quit-glaze.png` | TODO: `docs/parity-evidence/clean-quit-standalone.png` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |
| Power-assertion release on quit/deactivation is externally observable (`pmset -g assertions` shows no lingering Seer assertion after quit) | TODO: `docs/parity-evidence/assertion-release-glaze.log` | TODO: `docs/parity-evidence/assertion-release-standalone.log` | TODO | Date: TODO · Tester: TODO · Build commit: TODO |

## Update-notification row detail

The update-notification row must be executed against **both** the Glaze
`GlazeRendererBridge`/main-process update-check handler and the standalone
`UpdateService`, each pointed at the **same stubbed GitHub releases API
response** (an identical canned `GET /repos/OpenCoven/seer-releases/releases/latest`
JSON body — same `tag_name`, `html_url`, `draft`, `prerelease` fields —
served to both applications, e.g. via a local stub server or intercepted
request), never two independently-crafted fixtures. This is what makes the
comparison a genuine parity check rather than two unrelated update-UI
smoke tests: both applications must reach the identical notification
copy/version/`View release` destination from the identical upstream
response, including the `View release` action opening exactly that
response's `html_url` and nothing else.

The standalone side of this exact contract already has automated,
deterministic coverage:
`apps/macos/Seer/Tests/Updates/UpdateServiceTests.swift` stubs the GitHub
response via `MockURLProtocol`, and
`apps/macos/Seer/Tests/Integration/NavigationPolicyTests.swift`
(`testOpenCurrentReleaseOnlyOpensAValidatedGitHubURLNeverATamperedCacheValue`,
`testUpdatesOpenBridgeRequestRejectsAnyRendererSuppliedPayload`) prove
`UpdateService.openCurrentRelease()` only ever opens the already-validated,
cached `https://github.com/...` URL — never a tampered cache value, and
never anything a renderer could supply through the bridge, since
`updates.open`'s wire payload is structurally required to be empty. This
manual row is what additionally confirms the *visual* Glaze notification
and the standalone notification agree when driven from that same stubbed
response — the automated suite does not, and cannot, compare the two
applications' rendered UI against each other.

## Isolated-storage row detail

The isolated-storage row must be executed against the **same macOS user
account** on the same Mac — not two different accounts, and not two
different machines — since the entire point of this row is proving the two
applications never collide on that one account's storage.

### 1. Resolve and record both applications' storage paths

Both applications store `settings.json` and `history.json` (identical file
names — the isolation is entirely about the *containing directory*):

| Application | Containing directory | Source |
| --- | --- | --- |
| Glaze (Electron) | `~/Library/Application Support/Seer/` | Electron's default `app.getPath("userData")`, derived from `productName: "Seer"` in `package.json` — see `main/services/settings-store.ts`/`main/services/history-store.ts` |
| Standalone | `~/Library/Application Support/ai.opencoven.seer/` | `SettingsFileLocation.directoryName`/`HistoryFileLocation`'s hard-coded `"ai.opencoven.seer"` — see `apps/macos/Seer/Sources/Storage/SettingsStore.swift`/`apps/macos/Seer/Sources/History/HistoryStore.swift` |

Record the **actual, resolved, absolute paths** you observed on the test
Mac in the `Notes` column (not just this table) — e.g. via
`ls -la ~/"Library/Application Support/Seer" ~/"Library/Application Support/ai.opencoven.seer"`
run before touching either application, to also capture whether either
directory pre-existed from earlier testing (if so, back it up or use a
throwaway macOS account/fresh user first, since a pre-existing directory
would make "neither app created the other's directory" unobservable).

### 2. Seed unique, direction-tagged state in each application

1. Quit both applications entirely (confirm via Activity Monitor or
   `ps aux | grep -i seer`).
2. Launch **only** Glaze. Set its keep-awake mode to **Display** and open
   an agent session (or otherwise generate a history entry) tagged in a way
   that is unmistakably Glaze's own — e.g. an agent working directory named
   `~/glaze-isolation-probe-<ISO8601 timestamp>`. Quit Glaze.
3. Capture `docs/parity-evidence/isolated-storage-glaze.log`: the full
   contents of `~/Library/Application Support/Seer/settings.json` and
   `history.json` at this point (`cat` both files into the log), plus
   `ls -la ~/"Library/Application Support/ai.opencoven.seer"` showing it is
   either absent or unchanged by this step.
4. Launch **only** the standalone app. Set its keep-awake mode to
   **System** (the *other* mode, so the two applications' seeded state is
   never accidentally identical) and generate a history entry tagged
   distinctly from Glaze's — e.g.
   `~/standalone-isolation-probe-<ISO8601 timestamp>`. Quit the standalone
   app.
5. Capture `docs/parity-evidence/isolated-storage-standalone.log`: the full
   contents of `~/Library/Application Support/ai.opencoven.seer/settings.json`
   and `history.json`, plus `ls -la ~/"Library/Application Support/Seer"`
   showing Glaze's directory/files from step 3 are byte-for-byte unchanged
   (compare modification timestamps and content, not merely "still
   exists").

### 3. Relaunch both and verify neither observes the other's state

6. Relaunch Glaze. In its History view, confirm **only** the
   `glaze-isolation-probe-*` entry and **Display** keep-awake mode are
   present — the standalone app's `standalone-isolation-probe-*` entry and
   **System** mode must be **absent**. Screenshot as
   `docs/parity-evidence/isolated-storage-glaze.png`.
7. Relaunch the standalone app. In its History view, confirm **only** the
   `standalone-isolation-probe-*` entry and **System** keep-awake mode are
   present — Glaze's `glaze-isolation-probe-*` entry and **Display** mode
   must be **absent**. Screenshot as
   `docs/parity-evidence/isolated-storage-standalone.png`.
8. Append the post-relaunch contents of both applications' `settings.json`/
   `history.json` to their respective `.log` files from steps 3/5, so the
   evidence directly shows each file still contains only its own
   application's seeded state after both relaunches.

### Why this row must never pass on "both empty"

A tester who launches both applications fresh, sees no state in either,
and marks this row `PASS` has proven nothing: two empty/absent directories
are indistinguishable from "the applications share one storage location
that happens to be empty." This row is only valid evidence once **both**
applications have been seeded with distinct, non-empty, uniquely-tagged
state (step 2 above) and relaunched — `PASS` requires observing that each
application's own seeded state persisted correctly *and* that neither
application's history/settings view ever displayed the other's tagged
entry or keep-awake mode. Mark `FAIL` (with the exact entry/mode that
leaked, in `Notes`) if either application ever shows the other's seeded
state, or if either application's own seeded state failed to persist
across its own relaunch (that would be a real regression in this row's own
right, distinct from cross-application isolation, but must not be
conflated with a `PASS`).

## What automated coverage already provides

The scenarios below are exercised deterministically by
`apps/macos/Seer/Tests/Integration/RendererIntegrationTests.swift` and
`apps/macos/Seer/Tests/Integration/NavigationPolicyTests.swift` (run via
`xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer
-destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
-only-testing:SeerTests/RendererIntegrationTests
-only-testing:SeerTests/NavigationPolicyTests`) and by the broader
`SeerTests`/`npm run test:renderer` suites, so this manual matrix does not
need to re-prove them — only the genuinely manual, cross-application
scenarios above still require human execution:

- The bundled renderer document loads through the real `seer://` scheme
  handler and exposes `window.seerNative.version === "seer.bridge.v1"`.
- A synthetic `AppSnapshot` (via a real, scripted agent scan) visibly
  updates the panel's Status text through the real
  `BridgeMessageHandler`/`RendererEventSink` path.
- `keepAwakeMode.set` and `history.clear` reach a typed fake coordinator
  with the exact requested arguments, driven through the real DOM-relay
  contract (`BridgeRelayUserScript`), never a direct unit-level call.
- Navigation to an external host, a `file://` URL, a `javascript:` URL, an
  unrecognized `seer://` host, and a percent-encoded `../` resource
  traversal are all denied by the real navigation delegate/scheme handler.
- `updates.open` cannot carry or open a renderer-supplied URL, and only
  ever opens an already-validated `https://github.com/...` release URL.
