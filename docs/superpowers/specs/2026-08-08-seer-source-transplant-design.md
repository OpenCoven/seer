# Seer Source Transplant Design

## Summary

Seer will become a macOS menu-bar utility that keeps the Mac awake while AI
coding agents are active. The implementation will transplant the authored
Glaze project from Stay Awake Remix into the existing Seer repository, preserve
its behavior, and replace its user-facing identity with Seer.

This is a behavior-preserving import and rebrand. It does not add Coven, Cave,
network, or external-service integrations.

## Goals

- Preserve the source application's agent detection, keep-awake behavior,
  activity history, tray controls, panel UI, and IPC behavior.
- Make Seer the only user-facing product and package identity.
- Give Seer independent settings and history storage.
- Preserve the source application's Glaze remix provenance and grant metadata.
- Keep the existing Seer Git history authoritative.
- Import only maintainable source and required project assets.

## Non-Goals

- Migrating settings or history from Stay Awake Remix.
- Importing the source repository's Git history.
- Restyling the panel or adding OpenCoven visual branding.
- Changing agent-detection heuristics or monitor cadence.
- Adding new agent types, features, services, or integrations.
- Publishing, committing, pushing, tagging, or releasing the result.

## Transplant Strategy

Use a clean source transplant from the source project's authored files into the
Seer repository.

Include:

- application entry points and Glaze configuration
- backend handlers, services, and window management
- renderer components, routes, styles, and preload code
- package manifest and lockfile
- TypeScript configuration
- required application icons and HTML entry points
- repository ignore rules that remain relevant to Seer

Exclude:

- the source `.git` directory
- `node_modules`
- generated `.glaze` build output
- `.glaze_memory`
- `.mcp.json`
- local caches, logs, and other machine-generated artifacts

The existing Seer `README.md` will be replaced with useful Seer project
documentation describing the product, requirements, development commands,
architecture, and verification commands.

## Identity and Storage

The package name will be `seer`, the product name will be `Seer`, and
user-facing descriptions will identify Seer as the utility that keeps a Mac
awake while coding agents work.

Seer will receive a new, stable eight-character Glaze application ID during
implementation. The ID will be generated once, recorded in the package
manifest, and differ from the source ID so Glaze assigns Seer an independent
application identity and `userData` location. Seer will not inspect or copy the
source application's settings or history.

The `glaze.remix` object will remain intact, including the grant, source app,
source version, and source author fields. Other generated timestamps may be
updated only when required by Glaze tooling.

Seer will receive a new, stable tray GUID during implementation. The source GUID
will not be reused because both applications may coexist; sharing it could make
macOS treat their menu-bar placement identities as the same item. The new GUID
will be generated once and then remain unchanged across Seer launches.

## Architecture

Seer remains a Glaze macOS accessory application with no Dock icon and no
persistent main window. Its principal surfaces are an always-visible menu-bar
tray and a frameless panel opened from that tray.

### Backend

- `main/index.ts` owns application lifecycle, service initialization, monitor
  startup, history flushing, and shutdown.
- `main/services/agent-detector.ts` detects supported coding agents from local
  processes and session/transcript data.
- `main/services/monitor.ts` polls every three seconds, publishes current agent
  state, updates history, and drives sleep prevention.
- `main/services/keep-awake.ts` wraps macOS power-save blocking for System and
  System + Display modes.
- `main/services/settings-store.ts` persists the selected keep-awake mode under
  Seer's fresh application data directory.
- `main/services/history-store.ts` persists activity sessions and aggregates
  under Seer's fresh application data directory.
- `main/services/tray.ts` renders idle/active tray states, opens the panel on
  left click, and provides quick controls on right click.
- `main/windows/panel-window.ts` owns panel creation, tray-relative placement,
  vibrancy, and blur-to-hide behavior.
- `main/handlers` exposes application, agent, history, and window operations to
  the renderer over Glaze IPC.

### Renderer

- `renderer/main/root-view.tsx` owns shared live-state subscriptions, Escape
  handling, and the route outlet.
- `renderer/main/home-view.tsx` shows current keep-awake state, mode selection,
  active agents, and Quit.
- `renderer/main/history-view.tsx` shows aggregate statistics, current
  activity, per-agent totals, recent sessions, and history clearing.
- `renderer/components/panel-tabs.tsx` switches between Status and History.
- React Query loads initial state through IPC and receives live updates through
  backend notifications.

Each component retains its current responsibility. The transplant does not
combine services or introduce new cross-component dependencies.

## Data Flow

1. Application startup initializes settings and history, creates the tray, and
   starts the monitor.
2. The monitor asks the detector for active agents every three seconds.
3. The resulting state drives the keep-awake service and history store.
4. State changes update the tray and are broadcast to the renderer.
5. The renderer updates React Query caches and refreshes Status and History.
6. User mode changes travel over IPC, persist to Seer's settings, and update
   the active blocker without changing agent detection.
7. Shutdown synchronously flushes any in-progress history session before exit.

## Error Handling

The transplant preserves current error semantics. It will not add broad
exception handling, silent defaults, or success-shaped fallbacks.

- Agent-scan failures remain non-fatal and follow existing logging/state paths.
- Storage errors continue through existing settings/history error paths.
- IPC failures remain visible to callers and development diagnostics.
- Build or startup failures are treated as transplant defects rather than
  hidden behind fallback behavior.

## Behavioral Invariants

The following must remain unchanged:

- three-second monitor cadence
- supported agent families and detection heuristics
- automatic blocker activation and deactivation
- System and System + Display modes
- always-visible tray with distinct idle and active states
- left-click panel toggle and right-click quick menu
- Status and History panel routes
- history calculations and shutdown flush
- Escape and blur behavior for hiding the panel

## Verification

Implementation is complete only after:

1. Dependencies install successfully from Seer's lockfile.
2. `npm run type-check` passes.
3. `npm run lint` passes.
4. `npm run build` passes.
5. A repository scan confirms no nested source `.git`, `.glaze`,
   `.glaze_memory`, `.mcp.json`, `node_modules`, caches, or logs were
   transplanted.
6. A branding scan confirms user-facing Stay Awake and Stay Awake Remix
   references are gone while source names inside `glaze.remix` provenance
   remain unchanged.
7. A startup smoke test confirms tray creation, monitor startup, and use of
   Seer's independent application identity.
8. A focused manual panel check confirms Status, History, mode switching,
   history clearing, Escape/blur hiding, and Quit.

If native menu-bar automation is unavailable, the manual panel check is
reported separately and is not represented as completed.

## Delivery Boundary

Implementation may modify files and run focused validation inside the Seer
repository. It will not commit, push, publish, tag, merge, or release without
Val's separate explicit approval.
