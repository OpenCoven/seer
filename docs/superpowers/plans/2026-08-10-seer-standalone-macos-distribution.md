# Seer Standalone macOS Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an Apple Silicon, macOS 14+ standalone Seer menu-bar app with a Swift/AppKit host, the existing React panel, native monitoring services, and a signed GitHub binary-release pipeline that contains no Glaze runtime.

**Architecture:** Keep the current Glaze target operational while moving the renderer onto a narrow `RendererBridge` and local UI primitives. Add an XcodeGen-defined AppKit application whose main-actor coordinator owns immutable snapshots and composes isolated Swift services for detection, storage, history, IOKit power assertions, updates, WKWebView bridging, the status item, and the transient panel. Package only a signed, notarized, stapled arm64 DMG into the public release repository after automated boundary checks and an explicit release approval.

**Tech Stack:** Swift 6, AppKit, WebKit, IOKit, XCTest, XcodeGen, React 19, TypeScript, Vite 8, Tailwind CSS 4, TanStack Query/Router, Node.js 24, GitHub Actions, Apple `codesign`, `notarytool`, and `hdiutil`

---

## Delivery Rules

- Work only on a short-lived branch in `.worktrees/seer-standalone-macos`.
- Keep the current Glaze target working until a separate approved removal.
- Do not copy Glaze UI source, host binaries, SDK files, runtime files, or signing material.
- Do not create `OpenCoven/seer-releases`, configure secrets, push tags, publish releases, or remove the Glaze target while executing this plan. Those are explicit external-action gates.
- Synthetic detector fixtures must contain no real usernames, home paths, prompts, project names, or conversation content.
- The experimental Raycast log detector is not part of the supported-family matrix in the approved spec and is not ported.
- Commit after every task, but do not push without explicit approval.

## File Map

### Root build and verification

- Modify `.gitignore` to exclude generated Xcode, archive, renderer, notarization, and release-staging output.
- Modify `package.json` and `package-lock.json` to add standalone renderer, Swift, and boundary-check scripts without adding runtime dependencies.
- Create `tsconfig.standalone.json` for SDK-independent renderer and pure-policy type checking.
- Create `eslint.standalone.config.js` for SDK-independent renderer and pure-policy linting.
- Modify `README.md` to document both development targets and standalone requirements.
- Create `vite.standalone.config.ts` for the standalone renderer build.
- Create `standalone-window.html` with a production-only CSP and standalone entry.
- Create `scripts/build-macos-app.sh` to generate and build the unsigned local app.
- Create `scripts/package-macos-release.sh` to sign, notarize, staple, package, and verify a release.
- Create `scripts/check-standalone-boundary.mjs` to reject Glaze/runtime/source leakage.
- Create `scripts/write-release-manifest.mjs` to produce deterministic release metadata.
- Create `.github/workflows/standalone-ci.yml` for private pull-request checks.
- Create `.github/workflows/release-macos.yml` for protected tag releases.

### Shared React renderer

- Create `renderer/bridge/types.ts` for the versioned cross-platform domain contract.
- Create `renderer/bridge/renderer-bridge.ts` for the `RendererBridge` interface.
- Create `renderer/bridge/glaze-renderer-bridge.ts` for the existing Glaze adapter.
- Create `renderer/bridge/standalone-renderer-bridge.ts` for WKWebView request/response transport.
- Create `renderer/bridge/renderer-bridge-context.tsx` for dependency injection without bundling both adapters.
- Create `renderer/bridge/*.test.ts` for adapter and transport tests.
- Create `renderer/ui/primitives.tsx` for Seer-owned UI primitives.
- Create `renderer/ui/error-boundary.tsx` for a local route error surface.
- Create `renderer/main/app.tsx` for renderer mounting shared by both targets.
- Create `renderer/standalone/index.tsx` and `renderer/standalone/styles.css` for the standalone entry.
- Modify `renderer/main/index.tsx`, `router.tsx`, `root-view.tsx`, `home-view.tsx`, `history-view.tsx`, `components/panel-tabs.tsx`, and `styles.css` to use the bridge and local primitives.
- Modify `renderer/lib/agents.ts` and `renderer/lib/history.ts` to re-export shared domain types and retain formatting helpers.
- Keep `renderer/preload.ts` only for the Glaze target.

### macOS project and domain

- Create `apps/macos/Seer/project.yml` as the XcodeGen source of truth.
- Create `apps/macos/Seer/Config/Info.plist`, `Seer.entitlements`, and `Version.xcconfig`.
- Create `apps/macos/Seer/Resources/AppIcon.icns` from the approved Seer icon.
- Create `apps/macos/Seer/Sources/Domain/Models.swift` for renderer-compatible Codable models.
- Create `apps/macos/Seer/Sources/Domain/Clock.swift` for deterministic time.
- Create `apps/macos/Seer/Tests/Domain/ModelsTests.swift` for wire-format compatibility.

### Storage and history

- Create `apps/macos/Seer/Sources/Storage/AtomicJSONStore.swift` for serialized atomic JSON files and quarantine.
- Create `apps/macos/Seer/Sources/Storage/SettingsStore.swift` for versioned standalone settings.
- Create `apps/macos/Seer/Tests/Storage/AtomicJSONStoreTests.swift`.
- Create `apps/macos/Seer/Tests/Storage/SettingsStoreTests.swift`.
- Create `apps/macos/Seer/Sources/History/HistoryStore.swift` for session aggregation and persistence.
- Create `apps/macos/Seer/Tests/History/HistoryStoreTests.swift`.

### Detection and monitoring

- Create `apps/macos/Seer/Sources/Detection/AgentDefinitions.swift` for supported families and constants.
- Create `apps/macos/Seer/Sources/Detection/TurnAssessors.swift` for Claude, Codex, Grok, Cursor, and generic activity decisions.
- Create `apps/macos/Seer/Sources/Detection/ProcessSnapshotSource.swift` for native process enumeration.
- Create `apps/macos/Seer/Sources/Detection/SessionSnapshotSource.swift` for bounded known-root traversal and Cursor state.
- Create `apps/macos/Seer/Sources/Detection/AgentDetector.swift` for process/session merging and stable IDs.
- Create `apps/macos/Seer/Sources/Detection/AgentMonitor.swift` for non-overlapping three-second scans.
- Create `apps/macos/Seer/Tests/Detection/Fixtures/` with synthetic active, idle, complete, stale, and awaiting-user data.
- Create `apps/macos/Seer/Tests/Detection/TurnAssessorsTests.swift`, `AgentDetectorTests.swift`, and `AgentMonitorTests.swift`.

### Power, updates, bridge, and AppKit shell

- Create `apps/macos/Seer/Sources/Power/PowerAssertionService.swift` and its test.
- Create `apps/macos/Seer/Sources/Updates/SemanticVersion.swift`, `UpdateService.swift`, and their tests.
- Create `apps/macos/Seer/Sources/Bridge/BridgeModels.swift`, `BridgeMessageHandler.swift`, `RendererEventSink.swift`, and `SeerSchemeHandler.swift`.
- Create `apps/macos/Seer/Tests/Bridge/BridgeMessageHandlerTests.swift` and `SeerSchemeHandlerTests.swift`.
- Create `apps/macos/Seer/Sources/App/AppSnapshotCoordinator.swift` as the main-actor state authority.
- Create `apps/macos/Seer/Sources/App/PanelController.swift` for panel behavior.
- Create `apps/macos/Seer/Sources/App/StatusItemController.swift` for tray appearance and quick actions.
- Create `apps/macos/Seer/Sources/App/AppDelegate.swift` and `main.swift` for lifecycle.
- Create AppKit integration tests with injected services.

### Parity and release evidence

- Create `docs/standalone-parity-matrix.md` as the manual dual-target gate.
- Create `tests/standalone-boundary.test.mjs` for repository-level artifact rules.
- Create `tests/release-manifest.test.mjs` for public manifest behavior.

## Wire Contract

Use these names exactly in TypeScript and Swift:

```typescript
export const BRIDGE_VERSION = "seer.bridge.v1" as const;
export type KeepAwakeMode = "system" | "display";
export type AgentActivitySource = "process" | "session" | "both";

export interface ActiveAgent {
  id: string;
  name: string;
  detail: string;
  source: AgentActivitySource;
  pid?: number;
  cpuPercent?: number;
  lastActivityAt: number;
}

export interface AgentMonitorState {
  active: boolean;
  keepingAwake: boolean;
  keepAwakeMode: KeepAwakeMode;
  agents: ActiveAgent[];
  lastScanAt: number;
}

export interface AgentUsage {
  id: string;
  name: string;
  durationMs: number;
}

export interface AwakeSession {
  id: string;
  startedAt: number;
  endedAt: number | null;
  durationMs: number;
  mode: KeepAwakeMode;
  agents: AgentUsage[];
}

export interface HistoryStats {
  totalAwakeMs: number;
  todayAwakeMs: number;
  sessionCount: number;
  perAgent: AgentUsage[];
  currentSession: AwakeSession | null;
  recentSessions: AwakeSession[];
}

export interface UpdateState {
  checking: boolean;
  availableVersion: string | null;
  releaseURL: string | null;
  lastCheckedAt: number | null;
}

export interface Diagnostic {
  id: string;
  message: string;
  occurredAt: number;
}

export interface AppSnapshot {
  monitor: AgentMonitorState;
  history: HistoryStats;
  update: UpdateState;
  diagnostics: Diagnostic[];
  appVersion: string;
}
```

Bridge method names are:

```text
snapshot.get
keepAwakeMode.set
history.clear
updates.check
updates.open
app.quit
```

## Task 1: Create the standalone implementation worktree

**Files:**
- Worktree: `.worktrees/seer-standalone-macos`
- Branch: `feat/seer-standalone-macos`

- [ ] **Step 1: Confirm the approved spec and plan are present**

Run:

```bash
git status --short --branch
git log -2 --oneline
test -f docs/superpowers/specs/2026-08-10-seer-standalone-macos-distribution.md
test -f docs/superpowers/plans/2026-08-10-seer-standalone-macos-distribution.md
```

Expected: `main` contains design commit `a1f59e1`; only the approved plan may be
uncommitted. Obtain explicit approval before committing the plan.

- [ ] **Step 2: Create the implementation branch after the plan commit exists**

Run:

```bash
git worktree add -b feat/seer-standalone-macos .worktrees/seer-standalone-macos main
```

Expected: Git creates the worktree from the commit containing both approved
documents.

- [ ] **Step 3: Capture the baseline**

Run:

```bash
cd .worktrees/seer-standalone-macos
npm ci
npm test
npm run type-check
npm run lint
npm run build
git status --short --branch
```

Expected: all existing checks pass and the worktree is clean.

## Task 2: Introduce the product-level renderer bridge

**Files:**
- Create `renderer/bridge/types.ts`
- Create `renderer/bridge/renderer-bridge.ts`
- Create `renderer/bridge/glaze-renderer-bridge.ts`
- Create `renderer/bridge/standalone-renderer-bridge.ts`
- Create `renderer/bridge/renderer-bridge-context.tsx`
- Create `renderer/bridge/glaze-renderer-bridge.test.ts`
- Create `renderer/bridge/standalone-renderer-bridge.test.ts`
- Modify `renderer/lib/agents.ts`
- Modify `renderer/lib/history.ts`
- Modify `package.json`
- Modify `package-lock.json`

- [ ] **Step 1: Add a failing Glaze-adapter contract test**

Create the test around an injected IPC facade rather than the real host:

```typescript
import assert from "node:assert/strict";
import test from "node:test";
import { createGlazeRendererBridge } from "./glaze-renderer-bridge";

test("Glaze adapter assembles one immutable snapshot", async () => {
  const calls: string[] = [];
  const bridge = createGlazeRendererBridge({
    invoke: async (channel: string) => {
      calls.push(channel);
      if (channel === "agents:getState") {
        return { active: false, keepingAwake: false, keepAwakeMode: "system", agents: [], lastScanAt: 1 };
      }
      if (channel === "history:getStats") {
        return { totalAwakeMs: 0, todayAwakeMs: 0, sessionCount: 0, perAgent: [], currentSession: null, recentSessions: [] };
      }
      return { version: "1.0.0" };
    },
    onNotification: () => () => {},
  });

  const snapshot = await bridge.getSnapshot();
  assert.equal(snapshot.appVersion, "1.0.0");
  assert.deepEqual(calls, ["agents:getState", "history:getStats", "app:getInfo"]);
});
```

- [ ] **Step 2: Add and run the renderer test command**

Add:

```json
{
  "scripts": {
    "test:renderer": "tsx --test renderer/**/*.test.ts"
  }
}
```

Run:

```bash
npm install --package-lock-only
npm run test:renderer
```

Expected: FAIL because the bridge modules do not exist.

- [ ] **Step 3: Define the shared types and interface**

Put the exact wire types from this plan in `renderer/bridge/types.ts`, then
define:

```typescript
export interface RendererBridge {
  getSnapshot(): Promise<AppSnapshot>;
  setKeepAwakeMode(mode: KeepAwakeMode): Promise<AppSnapshot>;
  clearHistory(): Promise<AppSnapshot>;
  subscribe(listener: (snapshot: AppSnapshot) => void): () => void;
  requestUpdateCheck(): Promise<AppSnapshot>;
  openCurrentRelease(): Promise<void>;
  quit(): Promise<void>;
  disconnect(): void;
}
```

- [ ] **Step 4: Implement the Glaze adapter**

Use only the existing allowlisted channels. Keep the latest monitor/history
values in closure state so either notification can emit a complete snapshot.
Return an unavailable update state because Glaze is the migration reference:

```typescript
const EMPTY_UPDATE: UpdateState = {
  checking: false,
  availableVersion: null,
  releaseURL: null,
  lastCheckedAt: null,
};

export function createGlazeRendererBridge(ipc: GlazeIPC): RendererBridge {
  let latest: AppSnapshot | null = null;

  async function getSnapshot(): Promise<AppSnapshot> {
    const [monitor, history, info] = await Promise.all([
      ipc.invoke<AgentMonitorState>("agents:getState"),
      ipc.invoke<HistoryStats>("history:getStats"),
      ipc.invoke<{ version: string }>("app:getInfo"),
    ]);
    latest = { monitor, history, update: EMPTY_UPDATE, diagnostics: [], appVersion: info.version };
    return structuredClone(latest);
  }

  return {
    getSnapshot,
    async setKeepAwakeMode(mode) {
      const monitor = await ipc.invoke<AgentMonitorState>("agents:setKeepAwakeMode", { mode });
      latest = { ...(latest ?? await getSnapshot()), monitor };
      return structuredClone(latest);
    },
    async clearHistory() {
      const history = await ipc.invoke<HistoryStats>("history:clear");
      latest = { ...(latest ?? await getSnapshot()), history };
      return structuredClone(latest);
    },
    subscribe(listener) {
      const offAgents = ipc.onNotification("agents:state-changed", (monitor) => {
        if (!latest) return;
        latest = { ...latest, monitor: monitor as AgentMonitorState };
        listener(structuredClone(latest));
      });
      const offHistory = ipc.onNotification("history:changed", (history) => {
        if (!latest) return;
        latest = { ...latest, history: history as HistoryStats };
        listener(structuredClone(latest));
      });
      return () => { offAgents(); offHistory(); };
    },
    requestUpdateCheck: getSnapshot,
    async openCurrentRelease() {},
    quit: () => ipc.invoke<void>("app:quit"),
    disconnect: () => ipc.disconnect?.(),
  };
}
```

- [ ] **Step 5: Inject the adapter and remove duplicated domain types**

Create a React context that accepts only `RendererBridge`:

```typescript
const RendererBridgeContext = React.createContext<RendererBridge | null>(null);

export function RendererBridgeProvider(props: {
  bridge: RendererBridge;
  children: React.ReactNode;
}) {
  return (
    <RendererBridgeContext.Provider value={props.bridge}>
      {props.children}
    </RendererBridgeContext.Provider>
  );
}

export function useRendererBridge(): RendererBridge {
  const bridge = React.useContext(RendererBridgeContext);
  if (!bridge) throw new Error("RendererBridgeProvider is missing");
  return bridge;
}
```

Do not create a runtime selector that statically imports both adapters: that
would pull Glaze adapter strings into the standalone bundle. The Glaze and
standalone entry points each construct their own adapter and pass it to
`mountApp`. `renderer/lib/agents.ts` and `renderer/lib/history.ts` re-export
the matching types from `renderer/bridge/types.ts`.

- [ ] **Step 6: Implement and test the standalone JavaScript transport**

Use an injected message port so it can be tested before the Swift host exists:

```typescript
export function createStandaloneRendererBridge(port: {
  postMessage(message: BridgeRequest): void;
}): RendererBridge & { receive(message: BridgeResponse | BridgeEvent): void } {
  const pending = new Map<string, PendingRequest>();
  const listeners = new Set<(snapshot: AppSnapshot) => void>();

  function request<TResult>(method: BridgeMethod, payload: BridgeRequest["payload"]): Promise<TResult> {
    const id = crypto.randomUUID();
    port.postMessage({ id, version: BRIDGE_VERSION, method, payload });
    return registerPendingRequest<TResult>(pending, id, 10_000);
  }

  return createStandaloneBridgeMethods(request, pending, listeners);
}
```

The test correlates a `snapshot.get` response, rejects a native error, ignores
an unknown response ID, times out after ten seconds using a fake scheduler, and
delivers a `snapshot.changed` event to subscribers. The standalone entry later
passes `window.webkit.messageHandlers.seerBridge` as the port.

- [ ] **Step 7: Run focused and baseline checks**

Run:

```bash
npm run test:renderer
npm test
npm run type-check
```

Expected: all pass.

- [ ] **Step 8: Commit the bridge contract**

```bash
git add package.json package-lock.json renderer/bridge renderer/lib
git commit -m "refactor: add Seer renderer bridge"
```

## Task 3: Remove Glaze UI/runtime imports from shared panel code

**Files:**
- Create `renderer/ui/primitives.tsx`
- Create `renderer/ui/error-boundary.tsx`
- Create `renderer/main/app.tsx`
- Create `renderer/standalone/index.tsx`
- Create `renderer/standalone/styles.css`
- Create `standalone-window.html`
- Create `vite.standalone.config.ts`
- Create `tsconfig.standalone.json`
- Create `eslint.standalone.config.js`
- Create `tests/standalone-renderer.test.mjs`
- Modify `renderer/main/index.tsx`
- Modify `renderer/main/router.tsx`
- Modify `renderer/main/root-view.tsx`
- Modify `renderer/main/home-view.tsx`
- Modify `renderer/main/history-view.tsx`
- Modify `renderer/components/panel-tabs.tsx`
- Modify `renderer/styles.css`
- Modify `package.json`

- [ ] **Step 1: Add a failing standalone renderer boundary test**

```javascript
test("standalone renderer source has no Glaze imports", () => {
  const files = walk(join(repoRoot, "renderer"))
    .filter((file) => /\.(ts|tsx|css)$/.test(file))
    .filter((file) => !file.endsWith("preload.ts") && !file.includes("/dev/"));
  const offenders = files.filter((file) => readFileSync(file, "utf8").includes("@glaze/core"));
  assert.deepEqual(offenders, []);
});

test("standalone production build has no source maps or Glaze references", () => {
  execFileSync("npm", ["run", "build:standalone-renderer"], { cwd: repoRoot, stdio: "pipe" });
  const files = walk(join(repoRoot, "build", "standalone-renderer"));
  assert.equal(files.some((file) => file.endsWith(".map")), false);
  const text = files.filter((file) => /\.(html|js|css)$/.test(file))
    .map((file) => readFileSync(file, "utf8")).join("\n");
  assert.doesNotMatch(text, /@glaze\/core|glaze-core:|window\.glazeAPI/);
});
```

- [ ] **Step 2: Run the test and confirm the expected failure**

Run:

```bash
node --test tests/standalone-renderer.test.mjs
```

Expected: FAIL on current `@glaze/core/components`, hooks, and utility imports.

- [ ] **Step 3: Add Seer-owned UI primitives**

Implement semantic wrappers, not copied Glaze code:

```typescript
export function Button(props: React.ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: "muted" | "transparent";
  size?: "small";
}) {
  const { className, variant = "muted", ...buttonProps } = props;
  return <button className={cx("seer-button", `seer-button-${variant}`, className)} {...buttonProps} />;
}

export function SegmentedControl(props: {
  value: string;
  onValueChange(value: string): void;
  label: string;
  children: React.ReactNode;
}) {
  return <div role="radiogroup" aria-label={props.label} className="seer-segmented">{props.children}</div>;
}

export function SegmentedControlItem(props: {
  value: string;
  selected: boolean;
  onSelect(value: string): void;
  children: React.ReactNode;
}) {
  return (
    <button role="radio" aria-checked={props.selected} onClick={() => props.onSelect(props.value)}>
      {props.children}
    </button>
  );
}
```

Also implement focused `Badge`, `Text`, `Toolbar`, `ScrollPanel`,
`EmptyState`, and list-row primitives used by the two existing routes.

- [ ] **Step 4: Move renderer mounting into a shared function**

```typescript
export function mountApp(rootElement: HTMLElement, bridge: RendererBridge): void {
  ReactDOM.createRoot(rootElement).render(
    <React.StrictMode>
      <RendererBridgeProvider bridge={bridge}>
        <QueryClientProvider client={queryClient}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      </RendererBridgeProvider>
    </React.StrictMode>,
  );
}
```

The Glaze entry imports `renderer/styles.css`, constructs only
`createGlazeRendererBridge(window.glazeAPI.glaze.ipc)`, and calls `mountApp`.
The standalone entry imports `renderer/standalone/styles.css`, constructs only
`createStandaloneRendererBridge(window.webkit.messageHandlers.seerBridge)`,
and calls the same function.

- [ ] **Step 5: Convert both routes to `AppSnapshot`**

Use one query:

```typescript
const { data: snapshot = EMPTY_SNAPSHOT } = useQuery({
  queryKey: ["appSnapshot"],
  queryFn: () => rendererBridge.getSnapshot(),
});

const modeMutation = useMutation({
  mutationFn: (mode: KeepAwakeMode) => rendererBridge.setKeepAwakeMode(mode),
  onSuccess: (next) => queryClient.setQueryData(["appSnapshot"], next),
});
```

`RootView` subscribes once and updates `["appSnapshot"]`. `HomeView` reads
`snapshot.monitor`; `HistoryView` reads `snapshot.history`; both call
`rendererBridge.quit()`. Remove Glaze connection/environment diagnostics.
Render every `snapshot.diagnostics` entry in a visible dismiss-independent
diagnostic region with `role="status"`; storage and power failures must not
exist only in logs.

- [ ] **Step 6: Add the standalone HTML and Vite configuration**

Use:

```typescript
export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    outDir: "build/standalone-renderer/Renderer",
    emptyOutDir: true,
    sourcemap: false,
    rollupOptions: { input: resolve(__dirname, "standalone-window.html") },
  },
});
```

The standalone CSP permits only bundled content:

```html
<meta http-equiv="Content-Security-Policy"
  content="default-src 'self'; base-uri 'none'; object-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'none'; frame-src 'none'">
```

Create `tsconfig.standalone.json` extending the root config, include the shared
renderer except `preload.ts` and `dev/`, the standalone Vite config, and the
pure TypeScript detector/update policy modules. Create
`eslint.standalone.config.js` from the installed `@eslint/js`,
`@typescript-eslint/parser`, `@typescript-eslint/eslint-plugin`, and browser
globals; do not add a new dependency.

Add:

```json
{
  "scripts": {
    "type-check:standalone": "tsc -p tsconfig.standalone.json --noEmit",
    "lint:standalone": "eslint --config eslint.standalone.config.js renderer main/services/agent-detection-policy.ts main/services/update-check.ts vite.standalone.config.ts"
  }
}
```

- [ ] **Step 7: Define standalone styles explicitly**

`renderer/standalone/styles.css` imports Tailwind and shared styles:

```css
@import "tailwindcss";
@import "../styles.css";

:root {
  color-scheme: light dark;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  background: transparent;
}
```

Add Seer-owned CSS classes for every primitive and retain the 340-by-440 panel
layout, transparent root, compact spacing, green active state, and native system
font.

- [ ] **Step 8: Run both renderer targets**

Run:

```bash
npm run test:renderer
node --test tests/standalone-renderer.test.mjs
npm run type-check:standalone
npm run lint:standalone
npm run build
```

Expected: both renderer builds pass; the standalone output has no `.map` file
and no Glaze reference.

- [ ] **Step 9: Commit the shared standalone-safe renderer**

```bash
git add package.json package-lock.json standalone-window.html vite.standalone.config.ts \
  tsconfig.standalone.json eslint.standalone.config.js renderer tests/standalone-renderer.test.mjs
git commit -m "feat: add standalone-safe Seer renderer"
```

## Task 4: Scaffold the XcodeGen AppKit target and wire models

**Files:**
- Create `apps/macos/Seer/project.yml`
- Create `apps/macos/Seer/Config/Info.plist`
- Create `apps/macos/Seer/Config/Seer.entitlements`
- Create `apps/macos/Seer/Config/Version.xcconfig`
- Create `apps/macos/Seer/Resources/AppIcon.icns`
- Create `apps/macos/Seer/Sources/Domain/Models.swift`
- Create `apps/macos/Seer/Sources/Domain/Clock.swift`
- Create `apps/macos/Seer/Sources/App/main.swift`
- Create `apps/macos/Seer/Sources/App/AppDelegate.swift`
- Create `apps/macos/Seer/Tests/Domain/ModelsTests.swift`
- Modify `.gitignore`

- [ ] **Step 1: Write the failing wire-format test**

```swift
func testSnapshotUsesMillisecondTimestampsAndLowercaseEnums() throws {
    let snapshot = AppSnapshot.empty(version: "1.0.0")
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder.seer.encode(snapshot)) as? [String: Any]
    )
    let monitor = try XCTUnwrap(object["monitor"] as? [String: Any])
    XCTAssertEqual(monitor["keepAwakeMode"] as? String, "system")
    XCTAssertEqual(monitor["lastScanAt"] as? Int, 0)
}
```

- [ ] **Step 2: Create the XcodeGen project definition**

Set:

```yaml
name: Seer
options:
  deploymentTarget:
    macOS: "14.0"
settings:
  base:
    ARCHS: arm64
    ONLY_ACTIVE_ARCH: true
    SWIFT_VERSION: "6.0"
targets:
  Seer:
    type: application
    platform: macOS
    sources:
      - path: Sources
      - path: Resources
        buildPhase: resources
      - path: ../../../build/standalone-renderer/Renderer
        type: folder
        buildPhase: resources
    info:
      path: Config/Info.plist
    entitlements:
      path: Config/Seer.entitlements
    configFiles:
      Debug: Config/Version.xcconfig
      Release: Config/Version.xcconfig
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: ai.opencoven.seer
        CODE_SIGN_ENTITLEMENTS: Config/Seer.entitlements
        ENABLE_HARDENED_RUNTIME: true
  SeerTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests]
    dependencies:
      - target: Seer
```

- [ ] **Step 3: Add minimal identity configuration**

`Info.plist` must set `LSUIElement=true`, `CFBundleDisplayName=Seer`,
`NSPrincipalClass=NSApplication`, `NSHighResolutionCapable=true`, and
`CFBundleIconFile=AppIcon`.
`Seer.entitlements` is an empty dictionary because App Sandbox is disabled and
no additional entitlement is required. `Version.xcconfig` starts with:

```xcconfig
MARKETING_VERSION = 1.0.0
CURRENT_PROJECT_VERSION = 1
MACOSX_DEPLOYMENT_TARGET = 14.0
```

- [ ] **Step 4: Implement Codable domain models**

Use `Int64` Unix milliseconds for every renderer-facing timestamp and raw-string
enums:

```swift
enum KeepAwakeMode: String, Codable, Sendable { case system, display }
enum AgentActivitySource: String, Codable, Sendable { case process, session, both }

struct AppSnapshot: Codable, Equatable, Sendable {
    var monitor: AgentMonitorState
    var history: HistoryStats
    var update: UpdateState
    var diagnostics: [Diagnostic]
    var appVersion: String
}
```

Implement all wire types from the plan and an `AppSnapshot.empty(version:)`
factory.

- [ ] **Step 5: Add deterministic clock and minimal app entry**

```swift
protocol Clock: Sendable { func nowMilliseconds() -> Int64 }
struct SystemClock: Clock {
    func nowMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
```

The initial `AppDelegate` only preserves a strong self-owned delegate and
terminates after the last explicit quit, not after window close.

- [ ] **Step 6: Generate and run the model test**

Run:

```bash
npm run build:standalone-renderer
xcodegen generate --spec apps/macos/Seer/project.yml
xcodebuild test \
  -project apps/macos/Seer/Seer.xcodeproj \
  -scheme Seer \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Verify identity and sandbox settings**

Run:

```bash
xcodebuild -project apps/macos/Seer/Seer.xcodeproj -scheme Seer -showBuildSettings \
  | grep -E 'ARCHS = arm64|MACOSX_DEPLOYMENT_TARGET = 14.0|PRODUCT_BUNDLE_IDENTIFIER = ai.opencoven.seer|ENABLE_HARDENED_RUNTIME = YES'
grep -q '<key>LSUIElement</key>' apps/macos/Seer/Config/Info.plist
grep -q '<string>AppIcon</string>' apps/macos/Seer/Config/Info.plist
! grep -q 'com.apple.security.app-sandbox' apps/macos/Seer/Config/Seer.entitlements
```

Expected: all assertions succeed.

- [ ] **Step 8: Commit the native target skeleton**

```bash
git add .gitignore apps/macos/Seer
git commit -m "feat: scaffold standalone Seer app"
```

## Task 5: Add atomic standalone settings storage

**Files:**
- Create `apps/macos/Seer/Sources/Storage/AtomicJSONStore.swift`
- Create `apps/macos/Seer/Sources/Storage/SettingsStore.swift`
- Create `apps/macos/Seer/Tests/Storage/AtomicJSONStoreTests.swift`
- Create `apps/macos/Seer/Tests/Storage/SettingsStoreTests.swift`

- [ ] **Step 1: Write failing atomic-write and quarantine tests**

```swift
func testCorruptFileIsQuarantinedBeforeDefaultsAreWritten() async throws {
    let url = temporaryDirectory.appending(path: "settings.json")
    try Data("{broken".utf8).write(to: url)
    let store = AtomicJSONStore<SettingsDocument>(url: url, clock: FixedClock(1_723_000_000_000))

    let result = try await store.load(default: .default)

    XCTAssertEqual(result.value, .default)
    XCTAssertEqual(result.diagnostic?.id, "storage.settings.corrupt")
    XCTAssertTrue(fileManager.fileExists(atPath: url.path + ".corrupt-1723000000000"))
}

func testFutureSchemaIsNotOverwritten() async throws {
    try Data(#"{"version":99,"keepAwakeMode":"display","includePrereleaseUpdates":false}"#.utf8)
        .write(to: url)
    let result = await settings.load()
    XCTAssertEqual(result.value, .default)
    XCTAssertEqual(result.diagnostic?.id, "storage.settings.unsupported-version")
    XCTAssertFalse(result.writesEnabled)
    XCTAssertEqual(try String(contentsOf: url), original)
}

func testReadFailureReturnsVisibleReadOnlyDefaults() async {
    fileSystem.readError = CocoaError(.fileReadNoPermission)
    let result = await settings.load()
    XCTAssertEqual(result.value, .default)
    XCTAssertEqual(result.diagnostic?.id, "storage.settings.read-failed")
    XCTAssertFalse(result.writesEnabled)
}
```

- [ ] **Step 2: Run the storage tests and verify failure**

Run:

```bash
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/AtomicJSONStoreTests \
  -only-testing:SeerTests/SettingsStoreTests
```

Expected: compile failure because the stores do not exist.

- [ ] **Step 3: Implement serialized atomic storage**

Use an actor so writes cannot overlap:

```swift
actor AtomicJSONStore<Value: Codable & Sendable> {
    private let url: URL

    func save(_ value: Value) throws {
        let data = try JSONEncoder.seer.encode(value)
        let temporary = url.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: temporary, options: [.atomic])
        try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
```

Handle a missing destination by moving the temporary file. Before returning
defaults for malformed JSON, move the original to
`<name>.corrupt-<unixMilliseconds>` and return a diagnostic. Detect the
top-level `version` before decoding and return read-only in-memory defaults plus
an `unsupported-version` diagnostic without moving or rewriting future data.
Any permission or I/O read failure also returns read-only defaults plus a
`read-failed` diagnostic. A save attempted while writes are disabled throws a
typed error that the coordinator publishes; it never reports persistence
success.

- [ ] **Step 4: Implement fresh standalone settings**

```swift
struct SettingsDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let `default` = SettingsDocument(
        version: 1,
        keepAwakeMode: .system,
        includePrereleaseUpdates: false
    )
    var version: Int
    var keepAwakeMode: KeepAwakeMode
    var includePrereleaseUpdates: Bool
}
```

Resolve the root with:

```swift
let base = try FileManager.default.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
)
let root = base.appending(path: "ai.opencoven.seer", directoryHint: .isDirectory)
```

Never inspect Glaze paths.

- [ ] **Step 5: Run storage tests**

Run the focused command from Step 2.

Expected: all storage tests pass.

- [ ] **Step 6: Commit storage**

```bash
git add apps/macos/Seer/Sources/Storage apps/macos/Seer/Tests/Storage
git commit -m "feat: add standalone settings storage"
```

## Task 6: Port history semantics

**Files:**
- Create `apps/macos/Seer/Sources/History/HistoryStore.swift`
- Create `apps/macos/Seer/Tests/History/HistoryStoreTests.swift`

- [ ] **Step 1: Write failing invariant tests**

Cover exact constants:

```swift
func testDelayedTickIsCappedAtFifteenSeconds() async throws {
    let store = makeStore(now: 1_000)
    await store.record(activeState(at: 1_000))
    clock.now = 31_000
    await store.record(activeState(at: 31_000))
    XCTAssertEqual(await store.stats().totalAwakeMs, 15_000)
}

func testSubsecondSessionIsDiscarded() async throws {
    await store.record(activeState(at: 1_000))
    clock.now = 1_500
    await store.record(idleState(at: 1_500))
    XCTAssertEqual(await store.stats().sessionCount, 0)
}

func testCapsSessionsRecentSessionsAndDailyKeys() async throws {
    await seed(store, sessions: 101, dailyKeys: 61)
    let document = await store.persistedDocument()
    XCTAssertEqual(document.sessions.count, 100)
    XCTAssertEqual(document.daily.count, 60)
    XCTAssertEqual(await store.stats().recentSessions.count, 40)
}
```

Also test per-agent accumulation, mode changes, day rollover, clear, corrupt
history diagnostics, five-second debounce, and explicit shutdown flush.

- [ ] **Step 2: Run the history tests and verify failure**

Run:

```bash
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/HistoryStoreTests
```

Expected: compile failure because `HistoryStore` does not exist.

- [ ] **Step 3: Implement the actor and constants**

```swift
actor HistoryStore {
    static let maxTickDeltaMs: Int64 = 15_000
    static let minimumSessionMs: Int64 = 1_000
    static let maximumSessions = 100
    static let maximumRecentSessions = 40
    static let maximumDailyKeys = 60
    static let saveDebounceMs: Int64 = 5_000

    func record(_ state: AgentMonitorState) async {
        let now = clock.nowMilliseconds()
        let delta = min(max(now - lastTickAt, 0), Self.maxTickDeltaMs)
        defer { lastTickAt = now }
        apply(state: state, now: now, delta: delta)
    }
}
```

Persist all-time totals separately from the capped recent session list. Sort
per-agent totals descending, clone value types into snapshots, and use local
calendar dates for `todayAwakeMs`.

- [ ] **Step 4: Make shutdown flush awaitable**

`flush(at:)` closes the current session, cancels pending debounce work, trims
daily keys, and awaits the atomic save. App termination waits for this method
before returning from `applicationShouldTerminate`.

- [ ] **Step 5: Run history and storage tests**

Run:

```bash
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/HistoryStoreTests \
  -only-testing:SeerTests/AtomicJSONStoreTests
```

Expected: all pass.

- [ ] **Step 6: Commit history**

```bash
git add apps/macos/Seer/Sources/History apps/macos/Seer/Tests/History
git commit -m "feat: port Seer history service"
```

## Task 7: Port turn classifiers with synthetic fixtures

**Files:**
- Create `tests/fixtures/agent-detection/expected.json`
- Create `tests/fixtures/agent-detection/claude-active.jsonl`
- Create `tests/fixtures/agent-detection/claude-complete.jsonl`
- Create `tests/fixtures/agent-detection/codex-active.jsonl`
- Create `tests/fixtures/agent-detection/codex-complete.jsonl`
- Create `tests/fixtures/agent-detection/codex-awaiting-approval.jsonl`
- Create `tests/fixtures/agent-detection/grok-active.jsonl`
- Create `tests/fixtures/agent-detection/grok-complete.jsonl`
- Create `tests/fixtures/agent-detection/grok-awaiting-approval.jsonl`
- Create `tests/fixtures/agent-detection/gemini-recent.json`
- Create `tests/fixtures/agent-detection/opencode-recent.json`
- Create `tests/fixtures/agent-detection/goose-recent.json`
- Create `tests/fixtures/agent-detection/continue-recent.json`
- Create `tests/fixtures/agent-detection/cursor-active.json`
- Create `tests/fixtures/agent-detection/cursor-idle.json`
- Create `tests/fixtures/agent-detection/process-snapshots.json`
- Create `main/services/agent-detection-policy.ts`
- Create `tests/agent-detection-parity.test.mjs`
- Modify `main/services/agent-detector.ts`
- Create `apps/macos/Seer/Sources/Detection/AgentDefinitions.swift`
- Create `apps/macos/Seer/Sources/Detection/TurnAssessors.swift`
- Create `apps/macos/Seer/Tests/Detection/TurnAssessorsTests.swift`

- [ ] **Step 1: Add one shared sanitized fixture corpus**

Use fixed timestamps and generic paths, for example:

```json
{"timestamp":"2026-08-10T12:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-08-10T12:00:02.000Z","type":"event_msg","payload":{"type":"agent_reasoning"}}
```

The completed Codex fixture adds:

```json
{"timestamp":"2026-08-10T12:00:03.000Z","type":"event_msg","payload":{"type":"task_complete"}}
```

Use equivalent explicit start/end/permission signals for Claude and Grok, and
synthetic Cursor composer headers with no conversation text. Add timestamp-only
fixtures for Gemini, OpenCode, Goose, and Continue. Add synthetic process
snapshots proving Aider and Amp require at least 25 percent CPU and proving
Cursor CLI uses the same threshold.

`expected.json` contains the exact family, active flag, source, detail, and
stable ID expected for every fixture. Both TypeScript and Swift tests read this
same file from `tests/fixtures/agent-detection`.

- [ ] **Step 2: Characterize the Glaze detector against the shared fixtures**

Extract only pure definitions, timestamp parsing, friendly labels, and turn
assessors from `main/services/agent-detector.ts` into
`main/services/agent-detection-policy.ts`; the existing detector imports them
without behavior changes. Export a fixture-only `assessDetectionFixture`
function from that pure module.

`tests/agent-detection-parity.test.mjs` loads all rows from `expected.json`,
calls the TypeScript policy through `tsx --test`, and asserts exact results.
Run:

```bash
npx tsx --test tests/agent-detection-parity.test.mjs
npm test
```

Expected: characterization tests pass before Swift is implemented, proving the
shared fixture oracle describes the retained Glaze behavior.

- [ ] **Step 3: Write table-driven failing Swift tests**

```swift
func testFixtureAssessments() throws {
    let oracle = try loadExpectedOracle("tests/fixtures/agent-detection/expected.json")
    XCTAssertEqual(Set(oracle.map(\.family)), Set(AgentFamily.allCases))
    XCTAssertTrue(oracle.contains { $0.family == .aider && $0.source == .process })
    XCTAssertTrue(oracle.contains { $0.family == .amp && $0.source == .process })

    for expected in oracle {
        let result = try assessSharedFixture(expected.fixture, now: fixedNow)
        XCTAssertEqual(result, expected.result, expected.fixture)
    }
}
```

The Swift test locates the repository fixture directory from `#filePath`;
it does not copy or restate expected values. This forces TypeScript and Swift
to consume the same exact oracle, including Aider and Amp process snapshots.

- [ ] **Step 4: Run the classifier tests and verify failure**

Run:

```bash
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/TurnAssessorsTests
```

Expected: compile failure because the definitions and assessors do not exist.

- [ ] **Step 5: Define supported families and matching policy**

Define exactly the ten approved families, their existing process patterns,
known session roots, formats, and fallback policy. Preserve:

```swift
let sessionCandidateWindowMs: Int64 = 10 * 60_000
let turnActiveGraceMs: Int64 = 45_000
let toolTurnGraceMs: Int64 = 3 * 60_000
let openTurnGraceMs: Int64 = 8 * 60_000
let processOnlyCPUThreshold = 25.0
```

Claude, Codex, and Grok require session-turn evidence. Aider and Amp permit
high-CPU process-only evidence. Cursor prefers composer state and permits the
same strict CLI fallback. Generic-mtime families receive a 20-second window.

- [ ] **Step 6: Port pure classifiers**

Parse line-delimited JSON into lightweight `Decodable` values or
`JSONSerialization` dictionaries. Preserve explicit end markers and treat
approval/permission requests as idle. Keep project-label and friendly-activity
normalization as pure functions with direct tests.

- [ ] **Step 7: Run both implementations against the same corpus**

Run:

```bash
npx tsx --test tests/agent-detection-parity.test.mjs
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/TurnAssessorsTests
```

Expected: both implementations pass every shared fixture case.

- [ ] **Step 8: Commit classifier parity**

```bash
git add main/services/agent-detector.ts main/services/agent-detection-policy.ts \
  tests/agent-detection-parity.test.mjs tests/fixtures/agent-detection \
  apps/macos/Seer/Sources/Detection/AgentDefinitions.swift \
  apps/macos/Seer/Sources/Detection/TurnAssessors.swift \
  apps/macos/Seer/Tests/Detection
git commit -m "feat: port Seer turn classifiers"
```

## Task 8: Add native process/session sources, detector merging, and monitor

**Files:**
- Create `apps/macos/Seer/Sources/Detection/ProcessSnapshotSource.swift`
- Create `apps/macos/Seer/Sources/Detection/SessionSnapshotSource.swift`
- Create `apps/macos/Seer/Sources/Detection/AgentDetector.swift`
- Create `apps/macos/Seer/Sources/Detection/AgentMonitor.swift`
- Create `apps/macos/Seer/Tests/Detection/AgentDetectorTests.swift`
- Create `apps/macos/Seer/Tests/Detection/AgentMonitorTests.swift`

- [ ] **Step 1: Write failing merge and monitor tests**

```swift
func testSessionAndProcessEvidenceMergeToBoth() async throws {
    let detector = AgentDetector(
        processes: StubProcesses([.init(pid: 42, cpuPercent: 2, command: "codex")]),
        sessions: StubSessions([activeCodexTurn(identity: "/fixtures/codex-active.jsonl")])
    )
    let agents = try await detector.detect(now: fixedNow)
    XCTAssertEqual(agents.count, 1)
    let agent = try XCTUnwrap(agents.first)
    XCTAssertEqual(agent.source, .both)
    XCTAssertEqual(agent.id, "codex:/fixtures/codex-active.jsonl")
}

func testFailedScanRetainsLastSuccessfulState() async {
    let monitor = AgentMonitor(detector: SequenceDetector([.success([activeCodex]), .failure(TestError())]))
    await monitor.scan()
    await monitor.scan()
    XCTAssertEqual(await monitor.state.agents, [activeCodex])
    XCTAssertEqual(await monitor.diagnostic?.id, "monitor.scan.failed")
}

func testConcurrentScanIsSkipped() async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await monitor.scan() }
        group.addTask { await monitor.scan() }
    }
    XCTAssertEqual(await detector.invocationCount, 1)
}
```

- [ ] **Step 2: Run detector tests and verify failure**

Run:

```bash
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/AgentDetectorTests \
  -only-testing:SeerTests/AgentMonitorTests
```

Expected: compile failure because the sources do not exist.

- [ ] **Step 3: Implement native process enumeration**

Use `proc_listallpids`, `proc_pidpath`, and `proc_pid_rusage`. Never invoke a
shell. Return bounded `ProcessSnapshot` values and skip Seer's own PID. CPU
percentage is calculated from two samples by a stateful source; a first sample
cannot trigger process-only activity.

- [ ] **Step 4: Implement bounded session traversal**

Canonicalize every configured root beneath the current home directory and
reject any standardized child path that is not prefixed by that root. Preserve:

```swift
let maximumWalkDepth = 5
let maximumFilesPerRoot = 400
let maximumAssessedCandidates = 24
let sessionTailBytes = 120_000
let codexHeadBytes = 32_000
```

Skip `.git`, `node_modules`, `cache`, symlinked directories, and `subagents`.
Reject symlinked files too: inspect each entry with `lstat`, skip any symbolic
link, standardize the candidate path, and verify it remains beneath its
canonical configured root immediately before opening. Open transcript files
with `O_NOFOLLOW` and reject `ELOOP`. Read only known extensions and
`events.jsonl` for Grok. Apply the same no-symlink/root check to Cursor's known
`state.vscdb`, then use SQLite C APIs in read-only mode; do not run
`/usr/bin/sqlite3`.

Add tests with a symlinked transcript and symlinked `state.vscdb` targeting a
file outside the fixture root; both must produce no session candidate and no
file read.

- [ ] **Step 5: Implement detector merging**

Sort active turns by activity time, preserve stable IDs, include top process
metadata when present, and apply strict process-only fallback:

```swift
if !activeTurns.isEmpty {
    let source: AgentActivitySource = topProcess == nil ? .session : .both
    return activeTurns.map { turn in
        ActiveAgent(
            id: "\(definition.id):\(turn.identity)",
            name: definition.name,
            detail: friendlyDetail(label: turn.label, reason: turn.reason),
            source: source,
            pid: topProcess?.pid,
            cpuPercent: topProcess?.cpuPercent,
            lastActivityAt: turn.lastActivityAt
        )
    }
}
```

- [ ] **Step 6: Implement the non-overlapping monitor**

Use an actor for scan exclusion and a detached utility-priority task for
detection. The timer sleeps for three seconds between completed scans instead
of launching overlapping fixed-rate work. A failure retains state, publishes a
diagnostic, and the next success clears it.

- [ ] **Step 7: Run detection tests**

Run the focused command from Step 2.

Expected: all pass.

- [ ] **Step 8: Commit native detection**

```bash
git add apps/macos/Seer/Sources/Detection apps/macos/Seer/Tests/Detection
git commit -m "feat: add native agent monitoring"
```

## Task 9: Add IOKit power assertions and the snapshot coordinator

**Files:**
- Create `apps/macos/Seer/Sources/Power/PowerAssertionService.swift`
- Create `apps/macos/Seer/Sources/App/AppSnapshotCoordinator.swift`
- Create `apps/macos/Seer/Tests/Power/PowerAssertionServiceTests.swift`
- Create `apps/macos/Seer/Tests/App/AppSnapshotCoordinatorTests.swift`

- [ ] **Step 1: Write failing power lifecycle tests**

```swift
func testChangingModeReplacesOneActiveAssertion() throws {
    let backend = FakeAssertionBackend()
    let service = PowerAssertionService(backend: backend)
    try service.setDesired(active: true, mode: .system)
    try service.setDesired(active: true, mode: .display)
    XCTAssertEqual(backend.createdTypes, [.preventUserIdleSystemSleep, .preventUserIdleDisplaySleep])
    XCTAssertEqual(backend.releasedIDs, [1])
    XCTAssertEqual(service.activeAssertionID, 2)
}

func testCreationFailureNeverReportsKeepingAwake() {
    let service = PowerAssertionService(backend: FailingAssertionBackend())
    XCTAssertThrowsError(try service.setDesired(active: true, mode: .system))
    XCTAssertFalse(service.isActive)
}
```

- [ ] **Step 2: Write a failing atomic coordinator transition test**

```swift
@MainActor
func testCompletedScanUpdatesPowerHistoryAndSnapshotTogether() async {
    await coordinator.applyScan([activeCodex], scannedAt: 2_000)
    XCTAssertTrue(coordinator.snapshot.monitor.active)
    XCTAssertTrue(coordinator.snapshot.monitor.keepingAwake)
    XCTAssertEqual(coordinator.snapshot.history.currentSession?.agents.first?.id, activeCodex.id)
    XCTAssertEqual(renderer.emittedSnapshots, [coordinator.snapshot])
}
```

- [ ] **Step 3: Run focused tests and verify failure**

Run:

```bash
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/PowerAssertionServiceTests \
  -only-testing:SeerTests/AppSnapshotCoordinatorTests
```

Expected: compile failure.

- [ ] **Step 4: Implement the IOKit boundary**

Map:

```swift
case .system:
    kIOPMAssertionTypePreventUserIdleSystemSleep
case .display:
    kIOPMAssertionTypePreventUserIdleDisplaySleep
```

Wrap `IOPMAssertionCreateWithName` and `IOPMAssertionRelease` behind
`PowerAssertionBackend`. Release old assertions only after a replacement has
been created successfully; release the replacement during shutdown.

- [ ] **Step 5: Implement the main-actor coordinator**

The coordinator owns `private(set) var snapshot`, applies monitor results,
persists mode changes, records history, and emits exactly once per completed
transition. Convert service errors into stable diagnostic IDs:

```text
monitor.scan.failed
power.assertion.failed
storage.settings.corrupt
storage.history.corrupt
storage.settings.unsupported-version
storage.history.unsupported-version
storage.settings.read-failed
storage.history.read-failed
updates.check.failed
```

Do not swallow errors or report `keepingAwake=true` after assertion failure.
Seed the initial snapshot with every diagnostic returned while loading settings
and history so the renderer's diagnostic region visibly reports startup
failures.

- [ ] **Step 6: Run coordinator tests**

Run the command from Step 3.

Expected: all pass.

- [ ] **Step 7: Commit power and state coordination**

```bash
git add apps/macos/Seer/Sources/Power apps/macos/Seer/Sources/App/AppSnapshotCoordinator.swift \
  apps/macos/Seer/Tests/Power apps/macos/Seer/Tests/App
git commit -m "feat: coordinate Seer power and state"
```

## Task 10: Implement the versioned WKWebView bridge and resource scheme

**Files:**
- Create `renderer/bridge/standalone-renderer-bridge.ts`
- Create `renderer/bridge/standalone-renderer-bridge.test.ts`
- Create `apps/macos/Seer/Sources/Bridge/BridgeModels.swift`
- Create `apps/macos/Seer/Sources/Bridge/BridgeMessageHandler.swift`
- Create `apps/macos/Seer/Sources/Bridge/RendererEventSink.swift`
- Create `apps/macos/Seer/Sources/Bridge/SeerSchemeHandler.swift`
- Create `apps/macos/Seer/Tests/Bridge/BridgeMessageHandlerTests.swift`
- Create `apps/macos/Seer/Tests/Bridge/SeerSchemeHandlerTests.swift`

- [ ] **Step 1: Write failing TypeScript transport tests**

```typescript
test("standalone bridge correlates responses and emits snapshots", async () => {
  const posted: unknown[] = [];
  const native = createStandaloneRendererBridge({
    postMessage: (message) => posted.push(message),
  });
  const promise = native.getSnapshot();
  const request = posted[0] as { id: string; version: string; method: string };
  assert.equal(request.version, "seer.bridge.v1");
  assert.equal(request.method, "snapshot.get");
  native.receive({ id: request.id, ok: true, result: EMPTY_SNAPSHOT });
  assert.deepEqual(await promise, EMPTY_SNAPSHOT);
});
```

Also test typed rejection, duplicate/unknown response IDs, and snapshot events.

- [ ] **Step 2: Write failing Swift allowlist tests**

```swift
func testUnknownMethodIsRejected() async {
    let response = await handler.handle(message(
        method: "shell.execute",
        payload: ["command": "open"]
    ))
    XCTAssertEqual(response.error?.code, "unknown_method")
    XCTAssertEqual(coordinator.receivedCommands.count, 0)
}

func testOversizedMessageIsRejectedBeforeDecode() async {
    let response = await handler.handle(rawBody: Data(repeating: 0x61, count: 65_537))
    XCTAssertEqual(response.error?.code, "message_too_large")
}
```

- [ ] **Step 3: Run focused bridge tests and verify failure**

Run:

```bash
npm run test:renderer
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/BridgeMessageHandlerTests \
  -only-testing:SeerTests/SeerSchemeHandlerTests
```

Expected: failures because standalone transports do not exist.

- [ ] **Step 4: Implement request/response transport**

Requests have:

```typescript
type BridgeRequest = {
  id: string;
  version: "seer.bridge.v1";
  method: BridgeMethod;
  payload: Record<string, never> | { mode: KeepAwakeMode };
};
```

Use `crypto.randomUUID()`, a pending-request map, a 10-second timeout, and
`window.webkit.messageHandlers.seerBridge.postMessage`. Expose only:

```typescript
window.seerNative = Object.freeze({
  version: BRIDGE_VERSION,
  receive(message: BridgeResponse | BridgeEvent) {
    bridge.receive(message);
  },
});
```

There is no generic method invocation function on the global.

- [ ] **Step 5: Decode each Swift method into a concrete payload**

Switch over a closed `BridgeMethod` enum and reject unknown payload keys by
checking the raw dictionary before decoding. Limit messages to 64 KiB. Route
commands to typed coordinator methods; there is no generic command or URL
method.

- [ ] **Step 6: Emit snapshots without source interpolation**

Use:

```swift
try await webView.callAsyncJavaScript(
    "window.seerNative.receive(message)",
    arguments: ["message": encodedJSONObject],
    in: nil,
    contentWorld: .page
)
```

Responses and `snapshot.changed` events both use structured arguments.

- [ ] **Step 7: Serve only bundled renderer resources**

`SeerSchemeHandler` maps `seer://app/<path>` to
`Bundle.main/Contents/Resources/Renderer`, rejects traversal and missing files,
sets exact MIME types, and never serves outside the renderer root. Navigation
policy permits only the initial `seer://app/standalone-window.html` document.

- [ ] **Step 8: Run bridge tests**

Run the focused command from Step 3.

Expected: all pass.

- [ ] **Step 9: Commit the bridge**

```bash
git add renderer/bridge apps/macos/Seer/Sources/Bridge apps/macos/Seer/Tests/Bridge
git commit -m "feat: add versioned native renderer bridge"
```

## Task 11: Add notify-only GitHub update checks

**Files:**
- Modify `main/index.ts`
- Create `main/services/update-check.ts`
- Create `main/services/update-check.test.ts`
- Create `main/handlers/updates.ts`
- Modify `main/handlers/index.ts`
- Modify `main/services/settings-store.ts`
- Modify `main/services/types.ts`
- Modify `main/services/tray.ts`
- Create `apps/macos/Seer/Sources/Updates/SemanticVersion.swift`
- Create `apps/macos/Seer/Sources/Updates/UpdateService.swift`
- Create `apps/macos/Seer/Tests/Updates/SemanticVersionTests.swift`
- Create `apps/macos/Seer/Tests/Updates/UpdateServiceTests.swift`
- Modify `apps/macos/Seer/Sources/Storage/SettingsStore.swift`
- Modify `apps/macos/Seer/Tests/Storage/SettingsStoreTests.swift`
- Modify `renderer/bridge/glaze-renderer-bridge.ts`
- Modify `renderer/bridge/glaze-renderer-bridge.test.ts`
- Modify `renderer/main/home-view.tsx`

- [ ] **Step 1: Write failing version tests**

```swift
func testSemanticOrdering() throws {
    XCTAssertLessThan(try SemanticVersion("1.2.3"), try SemanticVersion("1.3.0"))
    XCTAssertLessThan(try SemanticVersion("2.0.0-beta.1"), try SemanticVersion("2.0.0"))
    XCTAssertEqual(try SemanticVersion("v1.2.3"), try SemanticVersion("1.2.3"))
}
```

- [ ] **Step 2: Write failing update-service tests with `URLProtocol`**

Verify:

- stable mode requests `/releases/latest`
- prerelease mode requests a bounded `/releases?per_page=20`
- drafts are ignored
- ETag is sent through `If-None-Match`
- HTTP 304 retains the previous result and updates check time
- a second check inside 24 hours does not hit the network unless forced
- an app left running starts one new check when the clock reaches 24 hours
- release URLs must use HTTPS and host `github.com`
- no request body or local state header is sent

Use:

```swift
XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Seer/1.0.0")
XCTAssertNil(request.httpBody)
XCTAssertEqual(request.timeoutInterval, 10)
```

- [ ] **Step 3: Run update tests and verify failure**

Run:

```bash
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/SemanticVersionTests \
  -only-testing:SeerTests/UpdateServiceTests
```

Expected: compile failure.

- [ ] **Step 4: Implement semantic versions and service**

Parse numeric major/minor/patch and dot-separated prerelease identifiers.
Reject malformed tags. Use an ephemeral `URLSessionConfiguration`, a 10-second
resource timeout, and no cookies or credential storage.

Persist only `lastCheckedAt`, ETag, and last valid release metadata in the
standalone settings document. A network error returns a typed error without
affecting monitoring.

Add an update scheduler that sleeps until `lastCheckedAt + 24 hours`, performs
one non-forced check, and reschedules from the completed check time. Inject the
clock and sleeper so the 24-hour behavior is deterministic in tests. Cancel the
scheduler during application shutdown.

- [ ] **Step 5: Persist update metadata and preserve the prerelease setting**

Extend `SettingsDocument` and its tests with:

```swift
var updateETag: String?
var lastUpdateCheckAt: Int64?
var lastRelease: CachedRelease?
```

Decode absent fields as nil so version 1 files remain valid. Add a native
coordinator method that persists `includePrereleaseUpdates`, clears cached
release metadata, and forces one check. Task 12 exposes that method through a
right-click checkbox labeled `Include Prerelease Updates`; no renderer bridge
method is needed for this setting.

- [ ] **Step 6: Add matching update behavior to the Glaze reference**

Implement a small Node service with the same endpoints, 24-hour gate, semantic
comparison, URL allowlist, and in-memory ETag cache. Register only:

```text
updates:getState
updates:check
updates:open
```

`updates:open` receives no renderer URL; it opens only the validated URL held
by the service. Update `GlazeRendererBridge` so `requestUpdateCheck` and
`openCurrentRelease` call these handlers and update its snapshot. Add adapter
tests for both methods.

Extend the existing Glaze `AppSettings` and `SettingsStore` with
`includePrereleaseUpdates` defaulting to false. Add `UpdateService` state
subscription to `main/services/tray.ts`; its right-click menu gets both
`Include Prerelease Updates` and
`` `View Seer ${update.availableVersion}` `` when applicable. Toggling
prereleases persists through the Glaze settings store and forces a check. This
makes the update-notification and prerelease-menu rows executable against both
targets.

Add `main/services/update-check.test.ts` with the same stable/prerelease,
24-hour, draft, ETag, HTTPS-host, and no-request-body cases as the Swift suite,
using an injected fetch implementation and clock.

Initialize the Glaze update service during `main/index.ts` startup after
settings load. Broadcast `updates:changed` after the startup check and every
later state change. `GlazeRendererBridge.getSnapshot()` includes
`updates:getState`, while `subscribe()` merges `updates:changed` into the
complete snapshot. Adapter tests prove an update available at startup appears
in the first panel snapshot and a later broadcast updates the query cache.

- [ ] **Step 7: Restrict release opening**

`openCurrentRelease()` succeeds only for the release URL already validated and
stored by `UpdateService`; it calls `NSWorkspace.shared.open`. It accepts no URL
from JavaScript.

- [ ] **Step 8: Add the update notice**

When `snapshot.update.availableVersion` is non-null, render a compact notice
with `View release` and `Check again` actions. Do not add download/install copy.

- [ ] **Step 9: Run update and renderer checks**

Run:

```bash
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/SemanticVersionTests \
  -only-testing:SeerTests/UpdateServiceTests
npm run test:renderer
npx tsx --test main/services/update-check.test.ts
npm run type-check
npm test
```

Expected: all pass.

- [ ] **Step 10: Commit notify-only updates**

```bash
git add main/index.ts main/services/update-check.ts main/services/update-check.test.ts main/handlers main/services/settings-store.ts \
  main/services/types.ts main/services/tray.ts \
  apps/macos/Seer/Sources/Updates apps/macos/Seer/Tests/Updates \
  apps/macos/Seer/Sources/Storage/SettingsStore.swift \
  apps/macos/Seer/Tests/Storage/SettingsStoreTests.swift \
  renderer/bridge renderer/main/home-view.tsx
git commit -m "feat: add notify-only update checks"
```

## Task 12: Implement the AppKit panel, status item, and lifecycle

**Files:**
- Create `apps/macos/Seer/Sources/App/PanelController.swift`
- Create `apps/macos/Seer/Sources/App/StatusItemController.swift`
- Modify `apps/macos/Seer/Sources/App/AppDelegate.swift`
- Modify `apps/macos/Seer/Sources/App/AppSnapshotCoordinator.swift`
- Create `apps/macos/Seer/Tests/App/PanelControllerTests.swift`
- Create `apps/macos/Seer/Tests/App/StatusItemControllerTests.swift`
- Create `apps/macos/Seer/Tests/App/AppLifecycleTests.swift`

- [ ] **Step 1: Write failing panel geometry and toggle tests**

```swift
func testPanelCentersBelowTrayAndClampsToVisibleFrame() {
    let origin = PanelGeometry.origin(
        tray: NSRect(x: 990, y: 780, width: 22, height: 22),
        visibleFrame: NSRect(x: 0, y: 0, width: 1_000, height: 800),
        panelSize: NSSize(width: 340, height: 440)
    )
    XCTAssertEqual(origin.x, 652)
    XCTAssertGreaterThanOrEqual(origin.y, 8)
}

func testTrayClickWithinBlurGuardDoesNotReopenPanel() {
    controller.hide(now: 1_000)
    controller.toggle(now: 1_200, trayBounds: trayBounds)
    XCTAssertFalse(panel.isVisible)
}
```

- [ ] **Step 2: Write failing tray appearance tests**

```swift
func testActiveSnapshotUsesAmberBoltAndAgentTooltip() {
    controller.apply(activeSnapshot)
    XCTAssertEqual(statusItem.imageName, "bolt.fill")
    XCTAssertEqual(statusItem.contentTintColor, NSColor(hex: "#F2A93B"))
    XCTAssertEqual(statusItem.toolTip, "Seer · Codex working")
}
```

Also test idle `bolt.slash`, plural agent tooltip, left-click toggle, right-click
menu, both mode radio actions, update item visibility, and quit.

- [ ] **Step 3: Run AppKit tests and verify failure**

Run:

```bash
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/PanelControllerTests \
  -only-testing:SeerTests/StatusItemControllerTests \
  -only-testing:SeerTests/AppLifecycleTests
```

Expected: compile failure.

- [ ] **Step 4: Implement the transient panel**

Use a 340-by-440 `NSPanel`, minimum height 280, non-resizable, transparent,
vibrant popover appearance, hidden window buttons, `.transient` and
`.fullScreenAuxiliary` collection behavior, and floating level. Center below
the status item with a six-point gap, clamp to eight-point screen margins, and
fall back above when needed.

A custom `NSPanel.cancelOperation` hides on Escape. `windowDidResignKey` hides
on blur. Preserve the 300 ms blur/click guard.

- [ ] **Step 5: Configure WKWebView securely**

Use a nonpersistent data store, disable JavaScript window opening, install only
the `seerBridge` handler and `seer` scheme, deny all external navigation, and
set `isInspectable=false` in Release. Load
`seer://app/standalone-window.html`.

- [ ] **Step 6: Implement status item and native menus**

Use native SF Symbols and exact labels:

```text
Open Seer
Prevent Sleep
System Only
System & Display
Include Prerelease Updates
View Seer v1.1.0
Quit Seer
```

The displayed version is generated from `snapshot.update.availableVersion`;
`v1.1.0` is the deterministic test value, not a hard-coded production label.

Left-click toggles the panel. Right-click builds a fresh menu from the latest
snapshot. Application menu contains About, Services, Hide, Hide Others, Show
All, and Quit.

- [ ] **Step 7: Wire lifecycle and orderly termination**

At launch:

1. set accessory activation
2. load settings and history
3. create coordinator, bridge, panel, and status item
4. perform the initial scan
5. begin the three-second monitor loop
6. schedule the startup update check

At quit, return `.terminateLater`, stop monitor work, await history flush,
release the power assertion, remove bridge handlers, then call
`reply(toApplicationShouldTerminate: true)`.

- [ ] **Step 8: Run AppKit tests and build**

Run:

```bash
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: tests pass and `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit the AppKit shell**

```bash
git add apps/macos/Seer/Sources/App apps/macos/Seer/Tests/App
git commit -m "feat: add Seer AppKit menu bar shell"
```

## Task 13: Add integration tests and the parity matrix

**Files:**
- Create `apps/macos/Seer/Tests/Integration/RendererIntegrationTests.swift`
- Create `apps/macos/Seer/Tests/Integration/NavigationPolicyTests.swift`
- Create `docs/standalone-parity-matrix.md`

- [ ] **Step 1: Add failing renderer integration tests**

Launch the panel with fake detector, storage, history, power, and update
services. Wait for the bundled document to load, then verify:

```swift
let title = try await webView.evaluateJavaScript("document.title") as? String
XCTAssertEqual(title, "Seer")
let bridgeVersion = try await webView.evaluateJavaScript("window.seerNative.version") as? String
XCTAssertEqual(bridgeVersion, "seer.bridge.v1")
```

Send a synthetic snapshot and assert Status text changes. Invoke
`keepAwakeMode.set` and `history.clear` through the page bridge and assert the
typed fake coordinator received the exact commands.

- [ ] **Step 2: Add navigation security tests**

Verify `https://example.com`, `file:///etc/passwd`, `javascript:`, unknown
`seer://` hosts, and `../` resource paths are denied. Verify the update method
can open only a validated GitHub release URL.

- [ ] **Step 3: Run integration tests**

Run:

```bash
xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -only-testing:SeerTests/RendererIntegrationTests \
  -only-testing:SeerTests/NavigationPolicyTests
```

Expected: tests pass.

- [ ] **Step 4: Write the executable manual parity matrix**

Create a table with columns:

```text
Scenario | Glaze evidence | Standalone evidence | Result | Notes
```

Include every approved scenario: idle/active tray, both click paths, both
routes, ten supported families, both power modes, blocker replacement, history
rollups and clear, relaunch persistence, isolated fresh storage, Escape, blur,
update notification, clean quit, and assertion release. Each row requires a
date, tester, build commit, and screenshot or log path.

The update-notification row runs against both the Glaze handler and Swift
service with the same stubbed GitHub response.

- [ ] **Step 5: Commit integration evidence**

```bash
git add apps/macos/Seer/Tests/Integration docs/standalone-parity-matrix.md
git commit -m "test: add standalone parity gates"
```

## Task 14: Add local build scripts and artifact boundary checks

**Files:**
- Create `scripts/build-macos-app.sh`
- Create `scripts/check-standalone-boundary.mjs`
- Create `tests/standalone-boundary.test.mjs`
- Modify `.gitignore`
- Modify `package.json`
- Modify `package-lock.json`

- [ ] **Step 1: Write failing repository boundary tests**

Assert:

- generated Xcode projects and build output are ignored
- standalone sources contain no `@glaze/core`, `.glaze-core`, or Glaze binary
  paths
- the built `.app` contains no Node executable, `.node`, `.map`, `.ts`, `.tsx`,
  package lock, test fixture, or Glaze-named file
- the bundle contains exactly one Mach-O file, `Contents/MacOS/Seer`
- `otool -L Contents/MacOS/Seer` lists only `/System/Library` or `/usr/lib`
  dependencies and no `@rpath` embedded framework
- `Info.plist` has arm64/macOS 14/accessory identity
- entitlements do not contain App Sandbox

```javascript
assert.deepEqual(findBundleEntries(appPath, [
  /\.map$/, /\.tsx?$/, /\.node$/, /node(?:js)?$/i, /glaze/i, /Fixtures\//,
]), []);
```

- [ ] **Step 2: Run the boundary test and verify failure**

Run:

```bash
node --test tests/standalone-boundary.test.mjs
```

Expected: FAIL because the build and check scripts do not exist.

- [ ] **Step 3: Implement the unsigned local build**

`scripts/build-macos-app.sh` uses `set -euo pipefail`, requires arm64, builds
the renderer, generates Xcode, builds Release with
`CODE_SIGNING_ALLOWED=NO`, and copies `Seer.app` to
`build/macos/unsigned/Seer.app`. It accepts `CONFIGURATION` and
`DERIVED_DATA_PATH` environment overrides but no arbitrary shell fragments.

- [ ] **Step 4: Implement the boundary scanner**

Walk source and bundle trees with Node filesystem APIs. Reject symlinks in the
bundle, forbidden extensions/names, source maps, absolute `/Users/` strings,
the current home path, `@glaze/core`, and `glaze-core:`. Print every offender
and exit nonzero. Invoke `/usr/bin/file` for every regular bundle file and fail
unless the only Mach-O result is `Contents/MacOS/Seer`. Invoke `/usr/bin/otool
-L` for that executable and fail on any dependency outside `/System/Library`
and `/usr/lib`. This structural allowlist rejects renamed embedded runtimes,
not only files that retain a Glaze name.

- [ ] **Step 5: Add package scripts**

```json
{
  "scripts": {
    "build:standalone-renderer": "vite build --config vite.standalone.config.ts",
    "generate:macos": "xcodegen generate --spec apps/macos/Seer/project.yml",
    "test:macos": "xcodebuild test -project apps/macos/Seer/Seer.xcodeproj -scheme Seer -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO",
    "build:macos": "bash scripts/build-macos-app.sh",
    "check:standalone-boundary": "node scripts/check-standalone-boundary.mjs"
  }
}
```

- [ ] **Step 6: Run local build and boundary checks**

Run:

```bash
npm run build:macos
npm run check:standalone-boundary
node --test tests/standalone-boundary.test.mjs
file build/macos/unsigned/Seer.app/Contents/MacOS/Seer
```

Expected: checks pass; `file` reports `Mach-O 64-bit executable arm64`.

- [ ] **Step 7: Commit build and boundary tooling**

```bash
git add .gitignore package.json package-lock.json scripts/build-macos-app.sh \
  scripts/check-standalone-boundary.mjs tests/standalone-boundary.test.mjs
git commit -m "build: add standalone macOS checks"
```

## Task 15: Add private pull-request CI

**Files:**
- Create `.github/workflows/standalone-ci.yml`

- [ ] **Step 1: Resolve immutable action SHAs**

Run and record the returned commit SHAs:

```bash
gh api repos/actions/checkout/git/ref/tags/v4 --jq .object.sha
gh api repos/actions/setup-node/git/ref/tags/v4 --jq .object.sha
gh api repos/actions/upload-artifact/git/ref/tags/v4 --jq .object.sha
gh api repos/maxim-lobanov/setup-xcode/git/ref/tags/v1 --jq .object.sha
```

If a tag object is annotated, dereference its object through the GitHub API
until the result type is `commit`. Use those exact 40-character SHAs in the
workflow.

- [ ] **Step 2: Create pull-request CI**

Use one `standalone` job on GitHub's Apple Silicon label `macos-14-xlarge` and
immediately assert `uname -m` is `arm64`. Sequential steps:

1. `npm ci`
2. standalone-safe Node and renderer tests
3. `npm run type-check:standalone` and `npm run lint:standalone`
4. build the standalone renderer
5. generate Xcode and run Swift tests
6. run `npm run build:macos` to create the unsigned app
7. run repository and built-app boundary checks

The job does not invoke the Glaze CLI because clean GitHub runners do not
possess the private Glaze SDK. Keeping these steps in one job guarantees the
generated renderer and unsigned app exist before Swift resource and boundary
checks.

Do not reference signing or release secrets in this workflow. Upload only test
results on failure; do not upload the app from pull requests.

Use the pinned `maxim-lobanov/setup-xcode` action with
`xcode-version: "16.2"`, run `xcodebuild -version`, install XcodeGen with
`brew install xcodegen`, and print `xcodegen --version`. The standalone-safe
Node command is:

```bash
node --test tests/identity.test.mjs tests/standalone-renderer.test.mjs \
  tests/release-manifest.test.mjs
npx tsx --test tests/agent-detection-parity.test.mjs \
  main/services/update-check.test.ts renderer/**/*.test.ts
```

Local/manual parity still runs `npm run build` where the authorized Glaze SDK
is installed. After `npm run build:macos`, CI runs
`node --test tests/standalone-boundary.test.mjs` and
`npm run check:standalone-boundary`.

- [ ] **Step 3: Validate workflow syntax locally**

Run:

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/standalone-ci.yml"); puts "valid yaml"'
grep -n 'uses:' .github/workflows/standalone-ci.yml \
  | grep -Ev 'uses: [^@]+@[0-9a-f]{40}$' && exit 1 || true
```

Expected: `valid yaml`; every action reference is a 40-character SHA.

- [ ] **Step 4: Commit CI**

```bash
git add .github/workflows/standalone-ci.yml
git commit -m "ci: verify standalone macOS app"
```

## Task 16: Add signed packaging and deterministic release metadata

**Files:**
- Create `scripts/package-macos-release.sh`
- Create `scripts/write-release-manifest.mjs`
- Create `tests/release-manifest.test.mjs`

- [ ] **Step 1: Write failing manifest tests**

```javascript
test("release manifest contains only public traceability fields", () => {
  const manifest = buildManifest({
    version: "1.0.0",
    sourceCommit: "a".repeat(40),
    workflowRun: "123",
    dmgPath,
    notarization: "accepted",
  });
  assert.deepEqual(Object.keys(manifest).sort(), [
    "artifacts", "bundleIdentifier", "notarization", "sourceCommit", "version", "workflowRun",
  ]);
  assert.equal(manifest.bundleIdentifier, "ai.opencoven.seer");
  assert.match(manifest.artifacts[0].sha256, /^[0-9a-f]{64}$/);
  assert.doesNotMatch(JSON.stringify(manifest), /Users|APPLE_|password|token/i);
});
```

- [ ] **Step 2: Run manifest tests and verify failure**

Run:

```bash
node --test tests/release-manifest.test.mjs
```

Expected: FAIL because the manifest script does not exist.

- [ ] **Step 3: Implement manifest and checksum generation**

The script accepts explicit CLI arguments, reads artifact bytes, and writes
stable two-space JSON. `SHA256SUMS` uses:

```text
<lowercase sha256><two spaces>Seer-vX.Y.Z-arm64.dmg
```

Reject non-semantic versions, non-40-character source SHAs, unexpected
artifact names, and notarization states other than `accepted`.

- [ ] **Step 4: Implement signing and notarization script**

Require:

```text
VERSION
BUILD_NUMBER
APPLE_CERTIFICATE
APPLE_CERTIFICATE_PASSWORD
APPLE_SIGNING_IDENTITY
APPLE_TEAM_ID
```

Select exactly one complete notarization set:

```text
APPLE_API_ISSUER + APPLE_API_KEY + APPLE_API_KEY_BASE64
```

or:

```text
APPLE_ID + APPLE_PASSWORD + APPLE_TEAM_ID
```

The script creates a temporary keychain, imports the certificate, builds the
arm64 archive, signs with Hardened Runtime and timestamp, verifies with
`codesign --verify --deep --strict`, creates `Seer-notarization.zip` with
`ditto -c -k --keepParent`, submits that ZIP and waits with `notarytool`,
deletes the ZIP after acceptance, staples and validates the app, builds a
compressed DMG with `hdiutil`, signs the DMG, submits the DMG to `notarytool`,
staples and validates the DMG, checks both app and DMG with `spctl`, runs
boundary checks, writes checksums/manifest, and deletes key material and the
temporary keychain in an EXIT trap.

- [ ] **Step 5: Test failure paths without credentials**

Run:

```bash
env -i PATH="$PATH" VERSION=1.0.0 BUILD_NUMBER=1 bash scripts/package-macos-release.sh
```

Expected: nonzero exit naming the first missing signing variable, with no
keychain or release artifact created.

- [ ] **Step 6: Run manifest and existing checks**

Run:

```bash
node --test tests/release-manifest.test.mjs
npm test
```

Expected: all pass.

- [ ] **Step 7: Commit release packaging**

```bash
git add scripts/package-macos-release.sh scripts/write-release-manifest.mjs \
  tests/release-manifest.test.mjs
git commit -m "build: add signed macOS packaging"
```

## Task 17: Add the protected cross-repository release workflow

**Files:**
- Create `.github/workflows/release-macos.yml`

- [ ] **Step 1: Resolve immutable action SHAs**

Resolve and pin commit SHAs for `actions/checkout`, `actions/setup-node`, and
`maxim-lobanov/setup-xcode` through `gh api`. Do not use floating major tags in
the committed workflow.

- [ ] **Step 2: Implement protected tag release workflow**

Trigger only:

```yaml
on:
  push:
    tags:
      - "v*.*.*"
```

Use a protected `macos-release` environment. Grant the private workflow only
`contents: read` and `id-token: write`; use `RELEASES_REPO_TOKEN` only for
commands against `OpenCoven/seer-releases`.

Run on `macos-14-xlarge`, assert arm64, select Xcode 16.2 with the pinned setup
action, install XcodeGen with Homebrew, and print both tool versions before the
gate. Do not run the Glaze CLI on this clean release runner; run the shared
TypeScript fixture suite and all standalone renderer/Swift/boundary tests.

Immediately reject non-release tags with:

```bash
[[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "tag must be vMAJOR.MINOR.PATCH" >&2
  exit 1
}
```

The job must:

1. verify arm64 runner
2. verify tag equals `MARKETING_VERSION`
3. run the complete test/build/boundary gate
4. call `package-macos-release.sh`
5. create a draft release in `OpenCoven/seer-releases`
6. upload only DMG, `SHA256SUMS`, `release-manifest.json`, and release notes
7. download those assets into a fresh directory
8. verify checksums, attach the downloaded DMG read-only with `hdiutil`, run
   signature, Gatekeeper, Mach-O, dependency, source-map, path, and Glaze
   boundary checks against the mounted `Seer.app`, then detach it in an EXIT
   trap
9. publish the draft only after successful re-verification

Use `gh release create --draft`, `gh release upload`, `gh release download`,
and `gh release edit --draft=false` with `GH_REPO=OpenCoven/seer-releases`.

Before scanning the mounted app, walk the entire mounted volume without
following links. Permit exactly `Seer.app` and an optional `Applications`
symlink whose target is `/Applications`; reject every other top-level entry,
hidden file, regular file, directory, and symlink. Then scan every regular file
inside `Seer.app` with the same source, path, Mach-O, dependency, signature, and
Glaze checks used before upload.

- [ ] **Step 3: Add explicit legal/product and repository gates**

Require protected-environment approval and an environment variable:

```text
BINARY_DISTRIBUTION_APPROVED=true
PARITY_MATRIX_APPROVED=true
```

Fail before signing unless both booleans are exactly `true` and
the protected environment variable `CLEAN_MACHINE_VERIFIED_COMMIT` is a
40-character lowercase Git commit equal to `GITHUB_SHA`. The
protected-environment
approver sets these only after every parity row is PASS and the same commit has
been exercised on a clean Apple Silicon macOS 14 machine.

Document that maintainers must
create the public repository, fine-grained token, protected environment, and
secrets separately with explicit approval; the workflow never creates or
configures them.

- [ ] **Step 4: Validate workflow statically**

Run:

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release-macos.yml"); puts "valid yaml"'
grep -n 'uses:' .github/workflows/release-macos.yml \
  | grep -Ev 'uses: [^@]+@[0-9a-f]{40}$' && exit 1 || true
grep -q 'environment: macos-release' .github/workflows/release-macos.yml
grep -q 'BINARY_DISTRIBUTION_APPROVED' .github/workflows/release-macos.yml
grep -q 'PARITY_MATRIX_APPROVED' .github/workflows/release-macos.yml
grep -q 'CLEAN_MACHINE_VERIFIED_COMMIT' .github/workflows/release-macos.yml
```

Expected: every assertion succeeds.

- [ ] **Step 5: Commit the release workflow**

```bash
git add .github/workflows/release-macos.yml
git commit -m "ci: add protected Seer release workflow"
```

Do not push a tag or dispatch the workflow.

## Task 18: Update documentation and run the complete local gate

**Files:**
- Modify `README.md`
- Modify `docs/standalone-parity-matrix.md`

- [ ] **Step 1: Document standalone development**

README must distinguish:

```text
npm run dev                 # existing Glaze reference target
npm run build:standalone-renderer
npm run generate:macos
npm run test:macos
npm run build:macos
```

Document Apple Silicon, macOS 14+, Xcode, XcodeGen, fresh storage at
`~/Library/Application Support/ai.opencoven.seer`, notify-only updates, and the
no-Glaze/Node standalone runtime.

- [ ] **Step 2: Document release administration without performing it**

List the required secrets from the spec, the protected `macos-release`
environment, the fine-grained cross-repository token, public artifact names,
and the separate approvals required to create the public repository and
publish the first binary.

- [ ] **Step 3: Run the complete gate**

Run:

```bash
npm ci
npm test
npm run test:renderer
npm run type-check
npm run lint
npm run build
npm run build:standalone-renderer
npm run test:macos
npm run build:macos
npm run check:standalone-boundary
git diff --check
```

Expected: every command passes.

- [ ] **Step 4: Run standalone smoke checks**

Launch the unsigned local app:

```bash
open build/macos/unsigned/Seer.app
```

Manually verify it appears only in the menu bar, opens and hides the panel,
renders Status and History, changes both modes, hides on Escape/blur, and quits
without leaving a power assertion. Record results in
`docs/standalone-parity-matrix.md`; do not mark Glaze/standalone parity complete
until every row has evidence.

- [ ] **Step 5: Inspect the final change set**

Run:

```bash
git status --short
git diff --stat main...HEAD
git diff --name-only main...HEAD
git log --oneline main..HEAD
```

Expected: only scoped standalone migration, tests, workflows, and documentation
changes are present; the Glaze target remains.

- [ ] **Step 6: Commit documentation and final evidence**

```bash
git add README.md docs/standalone-parity-matrix.md
git commit -m "docs: document standalone Seer delivery"
```

- [ ] **Step 7: Stop at the external-action gate**

Report:

- branch name and commit list
- complete automated gate results
- parity rows still requiring a clean-machine test
- signing/notarization test status
- exact external setup still awaiting approval

Do not push, open a PR, create `OpenCoven/seer-releases`, configure secrets,
tag, publish, or remove the Glaze target without explicit instructions.
