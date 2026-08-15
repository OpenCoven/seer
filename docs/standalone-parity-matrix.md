# Standalone macOS Parity Matrix

Manual parity evidence for the standalone macOS build (Task 13, Step 4 of
`docs/superpowers/plans/2026-08-10-seer-standalone-macos-distribution.md`).
This matrix is **not** a substitute for the automated integration tests in
`apps/macos/Seer/Tests/Integration/` — it exists to record *manual,
human-observed* parity between the existing Electron/Glaze application and
the standalone native app for scenarios that automated tests either cannot
fully observe (visual tray/menu state, real relaunch across process
restarts) or that this task's automated suite only partially exercises.

**No manual parity row in the Matrix section has been executed.** Every manual
`Result` cell is `TODO` and every manual evidence cell is a placeholder. Do not
mark any manual row `PASS` until a tester has actually performed that exact
scenario against both applications and attached real evidence (a screenshot
path or a log path) — never leave a row `PASS` on the strength of the automated
suite alone, and never edit a row's `Result` without also filling in `Date`,
`Tester`, `Build commit`, and the evidence paths for both applications.

## Task 18 automated evidence (not manual parity)

This section records local automated checks without changing any manual matrix
result. `VERIFIED (local)` means only that the named command exited zero on
this host. `OBSERVED` records a narrower fact and is not a UI pass. `BLOCKED`
means that no UI assertion was possible. None of these classifications is
clean-machine or release evidence.

Session-supplied evidence date: 2026-08-14 UTC-05:00; host Git clock stamped implementation commit b259509 on 2026-08-15 -05:00, so commit timestamp is recorded separately and not used as the session date.
Tester: **Cody** · Implementation commit:
**`b259509fbffc63db17db00da6df50812d5bd906b`** · Pinned-tool rerun checkout:
**`669a3fb558559451eea4b4a8801805cb5a4ce662`**. Logs are ignored,
worktree-relative files under `build/test-results/task18/`; paths in the logs
are redacted to `$REPO`/`$HOME`, and no log is a release artifact.

| Surface | Command | Result | Local log |
| --- | --- | --- | --- |
| Locked dependency install | `npm ci` | VERIFIED (local) | `build/test-results/task18/npm-ci.log` |
| Node suite, including release-manifest, package, draft-policy, and workflow static tests | `npm test` | VERIFIED (local) | `build/test-results/task18/npm-test.log` |
| Shared renderer tests | `npm run test:renderer` | VERIFIED (local) | `build/test-results/task18/test-renderer.log` |
| Glaze reference type-check | `npm run type-check` | VERIFIED (local) | `build/test-results/task18/type-check.log` |
| Glaze reference lint | `npm run lint` | VERIFIED with 8 warnings (local; 0 errors) | `build/test-results/task18/lint.log` |
| Glaze reference build | `npm run build` | VERIFIED (local) | `build/test-results/task18/build.log` |
| Standalone renderer build | `npm run build:standalone-renderer` | VERIFIED (local) | `build/test-results/task18/build-standalone-renderer.log` |
| Native project generation | `npm run generate:macos` | VERIFIED (local; XcodeGen 2.46.0, noncanonical Xcode 26.6) | `build/test-results/task18/generate-macos-pinned.log` |
| Native Swift tests | `npm run test:macos` | VERIFIED, 590 tests (local; XcodeGen 2.46.0, noncanonical Xcode 26.6) | `build/test-results/task18/test-macos-pinned.log` |
| Unsigned native app build | `npm run build:macos` | VERIFIED (local; XcodeGen 2.46.0, noncanonical Xcode 26.6) | `build/test-results/task18/build-macos-pinned.log` |
| Repository/bundle boundary scan | `npm run check:standalone-boundary` | VERIFIED (local; resulting pinned-XcodeGen bundle, noncanonical Xcode 26.6) | `build/test-results/task18/check-standalone-boundary-pinned.log` |
| Standalone boundary suite | `node --test tests/standalone-boundary.test.mjs` | VERIFIED, 32 tests (local) | `build/test-results/task18/standalone-boundary-test.log` |
| Patch whitespace validation | `git diff --check` | VERIFIED (local) | `build/test-results/task18/git-diff-check.log` |
| Unsigned launch/accessory smoke | `open build/macos/unsigned/Seer.app` | OBSERVED (exact-bundle process/identity only; not a UI pass) | `build/test-results/task18/smoke.log` |
| GUI smoke attempt | `open build/macos/unsigned/Seer.app`, then `osascript`/System Events accessibility query | BLOCKED (`osascript` denied assistive access, error `-25211`; no UI assertions) | `build/test-results/task18/ui-smoke-attempt.log` |

The smoke check observed a live exact-bundle process with bundle identifier
`ai.opencoven.seer`, `LSUIElement=true`, and Launch Services
`ApplicationType=UIElement`. Only that recorded PID was sent `SIGTERM`; no
exact-path process or Seer power assertion remained afterward. This does
**not** claim that a human observed the tray, panel, routes, modes, Escape, or
blur behavior.

The pinned-tool rerun downloaded Task 17's XcodeGen 2.46.0 archive, verified
both expected and actual SHA-256 as
`4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`,
prepended its `bin` directory to `PATH`, and removed the temporary local tool
directory afterward. `generate:macos`, `test:macos`, and `build:macos`
therefore used XcodeGen 2.46.0; the boundary command checked the resulting
bundle. The installed system XcodeGen remains 2.45.4.

The Apple Silicon host reported macOS 26.6.1. Inspection found only
`/Applications/Xcode.app`, reporting Xcode 26.6 (build 17F113); Xcode 16.2 was
not installed and was not downloaded. Therefore canonical Xcode 16.2
clean-machine validation remains incomplete even though the pinned XcodeGen
checks above are locally verified on Xcode 26.6.

The GUI attempt stopped as soon as System Events returned
`osascript is not allowed assistive access` (`-25211`) while querying the Seer
process's menu bars and windows. Because the status item could not be
identified reliably, no menu-bar click, panel visibility/title, Status or
History route, mode menu, Escape, blur, or Quit assertion was made, and no
machine-readable UI evidence was created. The blocker log records the command
and denial only. Cleanup by exact PID left no Seer process or Seer power
assertion. Every human UI matrix row remains incomplete and `TODO`, as do all
other manual parity rows; every clean-machine check remains incomplete.

These local results do not set `CLEAN_MACHINE_VERIFIED_COMMIT` or approve a
release. A real signing/notarization run was not attempted without credentials;
`npm test` uses only stubbed packaging tools.

## How to execute a row

1. Build the Glaze (Electron) app and the standalone app from the **same**
   commit SHA.
2. Perform the exact scenario in the `Scenario` column against the Glaze
   app first, capturing a screenshot (`docs/parity-evidence/<row-slug>-glaze.png`)
   or log excerpt (`docs/parity-evidence/<row-slug>-glaze.log`) as
   `Glaze evidence` — **redacted** per "Evidence redaction requirements"
   below before it is ever committed.
3. Perform the identical scenario against the standalone app, capturing
   `docs/parity-evidence/<row-slug>-standalone.png` or `.log` as
   `Standalone evidence` — likewise redacted before committing.
4. Fill in `Date` (ISO 8601), `Tester` (name/handle), and `Build commit`
   (the short SHA both builds were built from) in the `Notes` column.
5. Set `Result` to `PASS` only if both applications' observed behavior
   matches; set it to `FAIL` (with a description in `Notes`) otherwise.
   Leave `Result` as `TODO` until the row has actually been executed.

`docs/parity-evidence/` does not exist yet — create it (git-tracked) only
once the first row is actually executed; this document does not itself
create or claim any such artifact.

## Evidence redaction requirements

Every artifact committed under `docs/parity-evidence/` — screenshots and
`.log` files alike, for **every** row, not just the isolated-storage row
detailed below — must be redacted before it is ever committed. This
document, and the evidence it points to, is a permanent, publicly-visible
part of this git history; it must never leak the tester's real machine,
account, or in-progress work.

- **Paths: `$HOME`-relative only, never absolute-with-real-username.**
  Record filesystem locations as `$HOME/Library/Application Support/Seer/`
  (literal `$HOME`, not the tester's actual resolved home directory, e.g.
  never `/Users/alice/Library/...`). A path is "canonical" here precisely
  because it's the same string regardless of which account/machine ran the
  test — `$HOME`-relative satisfies that; a resolved absolute path does
  not, since it embeds the tester's real macOS username.
- **Synthetic sentinel identifiers/values only, never real ones.** Any
  identifier used to tag seeded state (e.g. the isolated-storage row's
  probe entries) must be a fixed, fictitious sentinel string committed to
  this document itself — e.g. `SEER-PARITY-SENTINEL-GLAZE-0001` /
  `SEER-PARITY-SENTINEL-STANDALONE-0001` — never a real working-directory
  name, real agent session ID, or a timestamp/UUID freshly generated at
  test time (a fresh value can't be reused as a stable "known-good"
  comparison across future re-runs, and risks embedding real local paths
  if derived from `pwd`).
- **Normalized selected-field hashes/diffs, never raw file dumps.** When a
  row's evidence must prove something about `settings.json`/`history.json`
  contents, never `cat` (or paste) the raw file into committed evidence.
  Instead, record only the specific fields the row is actually testing
  (e.g. `keepAwakeMode`'s value, and whether the sentinel entry's `id` is
  present/absent — never the entry's real working-directory-derived
  fields), plus a `/usr/bin/shasum -a 256` digest (stock macOS; output is the
  same `<hash>  <filename>` format as GNU `sha256sum`) of the *entire* raw
  file so a future re-run can prove byte-for-byte identity/difference
  without ever re-exposing the bytes themselves.
- **Screenshots/logs: redact personal paths and session metadata.** Crop
  or blur any visible absolute path, real username, machine name, menu-bar
  clock, or any other session metadata before committing a screenshot;
  strip the equivalent from `.log` files (e.g. redact real working
  directories embedded in a history entry's tooltip/detail text down to
  just the sentinel identifier).
- **Explicitly prohibited in any committed evidence:**
  - Raw history/transcript identifiers — real agent session IDs, real
    working-directory paths from actual agent sessions, or any other
    identifier that could be traced back to real, in-progress work.
  - Unredacted JSON — a full `settings.json`/`history.json` (or any other
    application-state file) pasted or attached in its entirety. Only the
    selected-field extract and hash described above are permitted.

These requirements exist so this document can prove the two applications'
storage is genuinely isolated (bidirectional: neither app ever observes the
other's state) using only synthetic, redacted evidence — never by
committing anything that could identify the tester, their machine, or the
real work they were doing at the time.

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

## Clean-machine work still pending

Every matrix row above remains `TODO` and requires same-commit, human-observed
Glaze/standalone evidence. In addition, release approval still requires these
clean-machine checks on the pinned toolchain:

- Launch the standalone app on a fresh Apple Silicon macOS 14+ account with
  neither Glaze nor Node.js installed.
- Confirm fresh standalone storage is created only at
  `$HOME/Library/Application Support/ai.opencoven.seer/`, then execute the
  bidirectional isolated-storage row against Glaze.
- Observe idle/active tray identity, left/right click behavior, Status and
  History routes, both keep-awake modes and live mode replacement, history,
  relaunch persistence, Escape, blur, notify-only updates, and clean quit.
- Exercise each supported agent-family row with its approved fixture and
  capture redacted evidence for both targets.
- Observe power assertions during real active-agent work and prove assertion
  release after mode changes and quit with `pmset -g assertions`.
- Install and assess a genuinely Developer-ID-signed, notarized, and stapled
  DMG with Gatekeeper. Static/stubbed packaging tests are not a substitute.

Until those checks have evidence and approval, `PARITY_MATRIX_APPROVED` and
`CLEAN_MACHINE_VERIFIED_COMMIT` must not be set for public release.

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

All evidence this row produces must follow "Evidence redaction
requirements" above: `$HOME`-relative paths, synthetic sentinel
identifiers, normalized selected-field hashes/diffs instead of raw file
contents, and redacted screenshots/logs. No step below asks for (or
permits) a raw file dump, a real working-directory path, or any other
personally- or session-identifying value in committed evidence.

### 1. Resolve and record both applications' storage paths

Both applications store `settings.json` and `history.json` (identical file
names — the isolation is entirely about the *containing directory*):

| Application | Containing directory | Source |
| --- | --- | --- |
| Glaze (Electron) | `$HOME/Library/Application Support/Seer/` | Electron's default `app.getPath("userData")`, derived from `productName: "Seer"` in `package.json` — see `main/services/settings-store.ts`/`main/services/history-store.ts` |
| Standalone | `$HOME/Library/Application Support/ai.opencoven.seer/` | `SettingsFileLocation.directoryName`/`HistoryFileLocation`'s hard-coded `"ai.opencoven.seer"` — see `apps/macos/Seer/Sources/Storage/SettingsStore.swift`/`apps/macos/Seer/Sources/History/HistoryStore.swift` |

Confirm these two directories resolve as expected on the test Mac (e.g. via
`ls -la ~/"Library/Application Support/Seer" ~/"Library/Application Support/ai.opencoven.seer"`
run before touching either application) and record only the **canonical,
`$HOME`-relative** form shown in the table above in the `Notes` column —
never the tester's actual resolved absolute path (which embeds their real
macOS username). Also note in `Notes` whether either directory pre-existed
from earlier testing (if so, back it up or use a throwaway macOS
account/fresh user first, since a pre-existing directory would make
"neither app created the other's directory" unobservable) — a fact you can
record without quoting any of that pre-existing directory's actual
contents.

### 2. Seed unique, direction-tagged, synthetic sentinel state in each application

1. Quit both applications entirely (confirm via Activity Monitor or
   `ps aux | grep -i seer`).
2. Launch **only** Glaze. Set its keep-awake mode to **Display** and
   generate a history entry tagged with the fixed synthetic sentinel
   identifier `SEER-PARITY-SENTINEL-GLAZE-0001` (e.g. by naming the probed
   agent's working directory or session label exactly that literal string
   — never a real project path, real agent session ID, or a freshly
   generated timestamp/UUID). Quit Glaze.
3. Capture `docs/parity-evidence/isolated-storage-glaze.log`: for each of
   `settings.json` and `history.json`, record (a) a `/usr/bin/shasum -a 256`
   digest of
   the full raw file, and (b) only the specific fields this row tests —
   `keepAwakeMode`'s value, and whether an entry containing
   `SEER-PARITY-SENTINEL-GLAZE-0001` is present — never the raw file
   contents themselves. Also record whether
   `$HOME/Library/Application Support/ai.opencoven.seer` is absent or
   unchanged by this step (a directory-listing summary, e.g. "absent" or
   "present, digest unchanged from a prior baseline" — not a raw `ls -la`
   transcript of a directory that may contain real session metadata).
4. Launch **only** the standalone app. Set its keep-awake mode to
   **System** (the *other* mode, so the two applications' seeded state is
   never accidentally identical) and generate a history entry tagged with
   the fixed synthetic sentinel identifier
   `SEER-PARITY-SENTINEL-STANDALONE-0001`. Quit the standalone app.
5. Capture `docs/parity-evidence/isolated-storage-standalone.log`: the same
   two things as step 3 (per-file `/usr/bin/shasum -a 256` digest plus the
   `keepAwakeMode`/sentinel-presence extract) for
   `$HOME/Library/Application Support/ai.opencoven.seer/settings.json` and
   `history.json`, plus confirmation that Glaze's directory/files from step
   3 are byte-for-byte unchanged — proven by comparing the step-3
   `/usr/bin/shasum -a 256` digests against a freshly recomputed one, not by
   re-pasting file contents.

### 3. Relaunch both and verify neither observes the other's state

6. Relaunch Glaze. In its History view, confirm **only** the
   `SEER-PARITY-SENTINEL-GLAZE-0001` entry and **Display** keep-awake mode
   are present — the standalone app's
   `SEER-PARITY-SENTINEL-STANDALONE-0001` entry and **System** mode must be
   **absent**. Screenshot as `docs/parity-evidence/isolated-storage-glaze.png`,
   cropped/redacted to the History view itself (no visible file paths,
   username, machine name, or menu-bar clock).
7. Relaunch the standalone app. In its History view, confirm **only** the
   `SEER-PARITY-SENTINEL-STANDALONE-0001` entry and **System** keep-awake
   mode are present — Glaze's `SEER-PARITY-SENTINEL-GLAZE-0001` entry and
   **Display** mode must be **absent**. Screenshot as
   `docs/parity-evidence/isolated-storage-standalone.png`, redacted the
   same way.
8. Append the post-relaunch `/usr/bin/shasum -a 256` digests and `keepAwakeMode`/
   sentinel-presence extracts (the same normalized form as steps 3/5 — never
   a raw file dump) for both applications' `settings.json`/`history.json`
   to their respective `.log` files, so the evidence directly shows each
   file still contains only its own application's seeded state after both
   relaunches, without ever exposing either file's actual bytes.

### Why this row must never pass on "both empty"

A tester who launches both applications fresh, sees no state in either,
and marks this row `PASS` has proven nothing: two empty/absent directories
are indistinguishable from "the applications share one storage location
that happens to be empty." This row is only valid evidence once **both**
applications have been seeded with distinct, non-empty, uniquely-tagged
synthetic sentinel state (step 2 above) and relaunched — `PASS` requires
observing that each application's own seeded state persisted correctly
*and* that neither application's history/settings view ever displayed the
other's sentinel identifier or keep-awake mode. Mark `FAIL` (with the exact
sentinel identifier/mode that leaked, in `Notes`) if either application
ever shows the other's seeded state, or if either application's own seeded
state failed to persist across its own relaunch (that would be a real
regression in this row's own right, distinct from cross-application
isolation, but must not be conflated with a `PASS`).


## What automated coverage already provides

The scenarios below are exercised deterministically by
`apps/macos/Seer/Tests/Integration/RendererIntegrationTests.swift` and
`apps/macos/Seer/Tests/Integration/NavigationPolicyTests.swift` (run via the
official, lock-safe `npm run test:macos`, which generates the Xcode project
with `xcodegen` and runs `xcodebuild test` for the full `SeerTests` suite,
including `RendererIntegrationTests` and `NavigationPolicyTests`; do not invoke
`xcodebuild` directly, since that bypasses the renderer/generated-project lock
and assumes outputs that are gitignored on a clean checkout) and by the
broader `SeerTests`/`npm run test:renderer` suites, so this manual matrix does not
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
