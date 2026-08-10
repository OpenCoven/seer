# Seer Source Transplant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transplant Stay Awake Remix's authored Glaze source into Seer, preserve its behavior and provenance, and give Seer independent product, storage, and tray identities.

**Architecture:** Import only authored source and required assets into a dedicated Seer worktree, excluding source history, dependencies, generated output, and local context. Add an identity contract test before rebranding the imported app, then verify the unchanged Glaze backend/renderer behavior through the existing build commands and a native menu-bar smoke check.

**Tech Stack:** Node.js 24+, TypeScript, React 19, Glaze SDK 0.13, TanStack Query/Router, macOS menu-bar APIs, Node's built-in test runner

---

## File Map

### Files copied without behavioral changes

- `glaze.ts` - resolves and launches the Glaze CLI.
- `main/handlers/*.ts` - exposes app, agent, and history IPC operations.
- `main/services/agent-detector.ts` - detects supported coding agents.
- `main/services/history-store.ts` - stores session history and aggregates.
- `main/services/keep-awake.ts` - controls the macOS power-save blocker.
- `main/services/monitor.ts` - polls agent state every three seconds.
- `main/services/settings-store.ts` - stores the selected keep-awake mode.
- `main/services/types.ts` - shared backend domain types.
- `main/windows/*.ts` - creates, positions, shows, and hides the tray panel.
- `renderer/components/panel-tabs.tsx` - switches Status and History routes.
- `renderer/lib/*.ts` - renderer IPC clients and shared response types.
- `renderer/main/*.tsx` - panel shell, routes, Status, and History views.
- `renderer/preload.ts` - renderer preload entry.
- `renderer/styles.css` and `renderer/vite-env.d.ts` - panel styling and Vite types.
- `main-window.html` - renderer HTML entry; its title changes to Seer.
- `main/tsconfig.json` and `tsconfig.json` - TypeScript configuration.
- `app-icon.icns` and `app-icon.png` - existing visual assets, preserved because this is not a restyle.

### Files modified for Seer

- `.gitignore` - excludes dependencies, generated Glaze output, local context, and logs while allowing required icons to be tracked.
- `package.json` - assigns Seer's package/product/app identity and test command while preserving `glaze.remix`.
- `package-lock.json` - records the `seer` package name at the root and root package entry.
- `main/index.ts` - replaces the old application-menu label and startup log with Seer.
- `main/services/tray.ts` - replaces old menu/tooltip branding and assigns Seer's stable tray GUID.
- `main-window.html` - replaces the old window title with Seer.
- `README.md` - documents Seer, its commands, architecture, and source provenance.

### Files created

- `tests/identity.test.mjs` - protects Seer's app ID, tray GUID, package branding, user-facing branding, provenance, and tracked-artifact boundary.

## Stable Identity Values

Use these values exactly:

- Glaze application ID: `6f424aca`
- Tray GUID: `b2ffcd25-6e8c-4df5-899f-0bf17b7dc7d1`

These values are intentionally different from the source app's identifiers and
must not be regenerated in later tasks.

### Task 1: Create the implementation worktree

**Files:**
- Worktree: `.worktrees/seer-source-transplant`
- Branch: `feat/seer-source-transplant`

- [ ] **Step 1: Confirm the main checkout is clean**

Run:

```bash
git status --short --branch
```

Expected: branch `main` with no modified or untracked files. If the plan file
itself is uncommitted, obtain explicit approval and commit only that file before
continuing.

- [ ] **Step 2: Create a dedicated implementation worktree**

Run:

```bash
git worktree add -b feat/seer-source-transplant .worktrees/seer-source-transplant main
```

Expected: Git reports a new worktree checked out on
`feat/seer-source-transplant`.

- [ ] **Step 3: Confirm the worktree starts from the approved design**

Run:

```bash
git -C .worktrees/seer-source-transplant log -1 --oneline
git -C .worktrees/seer-source-transplant status --short --branch
```

Expected: the approved design commit is present and the new worktree is clean.

### Task 2: Import only authored source

**Files:**
- Create: `app-icon.icns`
- Create: `app-icon.png`
- Create: `glaze.ts`
- Create: `main-window.html`
- Create: `main/**/*.ts`
- Create: `renderer/**/*.{ts,tsx,css}`
- Create: `package.json`
- Create: `package-lock.json`
- Create: `tsconfig.json`
- Modify: `.gitignore`

- [ ] **Step 1: Copy the source with explicit exclusions**

Run from the repository root:

```bash
SOURCE="/Users/buns/Library/Application Support/app.glaze.macos.main/apps/stay-awake-remix-local-5xc02mcz/.glaze-sources"
DEST="$PWD/.worktrees/seer-source-transplant"
rsync -a \
  --exclude='.git/' \
  --exclude='.glaze/' \
  --exclude='.glaze_memory/' \
  --exclude='.mcp.json' \
  --exclude='.icon-hash' \
  --exclude='node_modules/' \
  --exclude='tmp/' \
  --exclude='*.log' \
  --exclude='.DS_Store' \
  "$SOURCE/" "$DEST/"
```

Expected: authored source, configuration, package files, and both app icons are
present in the worktree. The existing Seer `README.md`, `docs/`, and root
`.git` remain intact.

- [ ] **Step 2: Replace the imported ignore rules**

Set `.worktrees/seer-source-transplant/.gitignore` to:

```gitignore
# Dependencies
node_modules/

# Generated Glaze output and local agent context
.glaze/
.glaze_memory/
.mcp.json
.icon-hash
tmp/

# Local visual brainstorming artifacts
.superpowers/

# Build caches and logs
*.tsbuildinfo
*.log

# OS files
.DS_Store
Thumbs.db
```

Do not ignore `app-icon.icns` or `app-icon.png`; both are required tracked
assets.

- [ ] **Step 3: Verify excluded artifacts were not copied**

Run:

```bash
ROOT=".worktrees/seer-source-transplant"
find "$ROOT" \
  -path "$ROOT/.git" -prune -o \
  \( -name node_modules -o -name .glaze -o -name .glaze_memory -o -name .mcp.json -o -name .icon-hash -o -name '*.log' \) \
  -print
```

Expected: no output.

- [ ] **Step 4: Inspect the import boundary**

Run:

```bash
git -C .worktrees/seer-source-transplant status --short
```

Expected: only authored application files, icons, package files, TypeScript
configuration, and `.gitignore` are new or modified. No nested repository,
dependency, generated output, memory, or MCP files appear.

- [ ] **Step 5: Commit the behavior-neutral import**

After Val explicitly approves this commit, run:

```bash
git -C .worktrees/seer-source-transplant add \
  .gitignore app-icon.icns app-icon.png glaze.ts main-window.html \
  main renderer package.json package-lock.json tsconfig.json
git -C .worktrees/seer-source-transplant commit -m "chore: import Seer application source"
```

Expected: one commit containing the source transplant with no rebranding yet.

### Task 3: Add the failing Seer identity contract

**Files:**
- Create: `tests/identity.test.mjs`

- [ ] **Step 1: Create the identity contract test**

Create `tests/identity.test.mjs` with:

```js
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path) => readFileSync(join(root, path), "utf8");
const packageJson = JSON.parse(read("package.json"));
const packageLock = JSON.parse(read("package-lock.json"));

test("Seer has an independent application identity", () => {
  assert.equal(packageJson.id, "6f424aca");
  assert.equal(packageJson.name, "seer");
  assert.equal(packageJson.productName, "Seer");
  assert.equal(packageLock.name, "seer");
  assert.equal(packageLock.packages[""].name, "seer");

  const tray = read("main/services/tray.ts");
  assert.match(
    tray,
    /const TRAY_GUID = "b2ffcd25-6e8c-4df5-899f-0bf17b7dc7d1";/,
  );
});

test("Seer preserves the Glaze remix provenance", () => {
  assert.deepEqual(packageJson.glaze.remix, {
    grantId: "5ae8fbb1-a558-4c99-b046-db06c54c988a",
    mode: "remix",
    attribution: false,
    sourceStoreAppId: "28bb9188-5063-4f9f-8b4a-d93df0ac2197",
    sourcePublicId: "4Z5mAG",
    sourceVersionId: "978af97f-aa32-4069-b733-d0849967fa20",
    sourceVersion: "6.0.0",
    sourceDisplayName: "Stay Awake",
    sourceAuthorId: "5c8368d0-a2d3-4642-b499-d3428dd3b0bf",
    sourceAuthorName: "Samuel Kraft",
    sourceAuthorUsername: "samuel",
    rootStoreAppId: "28bb9188-5063-4f9f-8b4a-d93df0ac2197",
    createdAt: "2026-08-08T17:09:11.443Z",
    setup: {
      status: "ready",
      updatedAt: "2026-08-08T17:09:20.607Z",
    },
  });
});

test("user-facing surfaces identify the app as Seer", () => {
  const surfaces = [
    "main/index.ts",
    "main/services/tray.ts",
    "main-window.html",
  ].map(read);

  for (const surface of surfaces) {
    assert.doesNotMatch(surface, /Stay Awake|Stay Awake Remix|Agent Sentinel/);
  }

  assert.match(read("main/index.ts"), /label: "Seer"/);
  assert.match(read("main-window.html"), /<title>Seer<\/title>/);
  assert.match(read("main/services/tray.ts"), /Open Seer/);
  assert.match(read("main/services/tray.ts"), /Quit Seer/);
});

test("generated and local source artifacts are not tracked", () => {
  const tracked = execFileSync("git", ["ls-files"], {
    cwd: root,
    encoding: "utf8",
  }).split("\n");

  const forbidden = [
    /^\.glaze\//,
    /^\.glaze_memory\//,
    /^\.mcp\.json$/,
    /^\.icon-hash$/,
    /(^|\/)node_modules\//,
    /\.log$/,
  ];

  for (const path of tracked) {
    for (const pattern of forbidden) {
      assert.doesNotMatch(path, pattern);
    }
  }
});
```

- [ ] **Step 2: Run the test and confirm it fails for the old identity**

Run:

```bash
cd .worktrees/seer-source-transplant
node --test tests/identity.test.mjs
```

Expected: FAIL because `package.json` still contains source ID `5xc02mcz`,
package name `stay-awake-remix`, and product name `Stay Awake Remix`.

### Task 4: Rebrand the application and lock independent identities

**Files:**
- Modify: `package.json`
- Modify: `package-lock.json`
- Modify: `main/index.ts`
- Modify: `main/services/tray.ts`
- Modify: `main-window.html`

- [ ] **Step 1: Update the package identity without changing provenance**

In `package.json`, replace only the top-level identity and scripts so they
contain:

```json
{
  "id": "6f424aca",
  "name": "seer",
  "version": "1.0.0",
  "productName": "Seer",
  "description": "Keeps your Mac awake while coding agents work",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "node glaze.ts build",
    "dev": "node glaze.ts dev",
    "dev:renderer": "node glaze.ts dev:renderer",
    "lint": "node glaze.ts lint",
    "type-check": "node glaze.ts type-check",
    "format": "node glaze.ts format",
    "test": "node --test tests/*.test.mjs"
  }
}
```

Keep all dependency, engine, `appConfig`, and `glaze` fields after this snippet
unchanged. In particular, do not edit any field inside `glaze.remix`.

- [ ] **Step 2: Update backend and window branding**

Apply these exact replacements in `main/index.ts`:

```ts
label: "Seer",
```

```ts
logger.info("main", "App ready — starting Seer");
```

Apply these exact replacements in `main/services/tray.ts`:

```ts
const TRAY_GUID = "b2ffcd25-6e8c-4df5-899f-0bf17b7dc7d1";
```

```ts
label: "Open Seer",
```

```ts
label: "Quit Seer",
```

```ts
count === 1
  ? `Seer · ${state.agents[0]?.name ?? "agent"} working`
  : `Seer · ${count} agents working`,
```

```ts
tray.setToolTip("Seer · sleep allowed");
```

In `main-window.html`, set:

```html
<title>Seer</title>
```

- [ ] **Step 3: Regenerate only package-lock metadata**

Run:

```bash
cd .worktrees/seer-source-transplant
npm install --package-lock-only --ignore-scripts
```

Expected: `package-lock.json` records `seer` for both the root `name` and
`packages[""].name`; dependency versions remain locked.

- [ ] **Step 4: Run the identity contract**

Run:

```bash
npm test
```

Expected: all four identity tests PASS.

- [ ] **Step 5: Scan for stale user-facing branding**

Run:

```bash
rg -n "Stay Awake|Stay Awake Remix|Agent Sentinel|stay-awake-remix|5xc02mcz|c3f8a1d2-6b4e-4f91-9a2c-8e5d7b0f3a16" \
  main renderer main-window.html package-lock.json
```

Expected: no output. The original source display name remains only inside the
approved `package.json` provenance object and design/plan documentation.

- [ ] **Step 6: Commit identity and contract changes**

After Val explicitly approves this commit, run:

```bash
git add package.json package-lock.json main/index.ts main/services/tray.ts \
  main-window.html tests/identity.test.mjs
git commit -m "feat: establish Seer application identity"
```

Expected: one commit containing the failing-test-first identity change.

### Task 5: Replace the placeholder README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace README content**

Set `README.md` to:

```markdown
# Seer

Seer is a macOS menu-bar utility that keeps your Mac awake while AI coding
agents are working.

It detects supported agents from local processes and session data, starts a
macOS power-save blocker while work is active, and records local activity
history. Seer runs as an accessory app with no Dock icon.

## Features

- Detects Claude Code, Codex, Grok, Gemini, Aider, OpenCode, Goose, Amp,
  Cursor, and Continue activity.
- Supports System and System + Display keep-awake modes.
- Shows live agents and keep-awake status from the menu bar.
- Records local session totals, daily totals, and per-agent history.
- Stores all settings and history locally in Seer's application data.

## Requirements

- macOS
- Node.js 24 or newer
- Glaze SDK and host 0.13.0.0 or newer

## Development

```bash
npm install
npm run dev
```

Available checks:

```bash
npm test
npm run type-check
npm run lint
npm run build
```

## Architecture

- `main/` contains lifecycle, agent detection, monitoring, storage, tray, panel,
  and IPC code.
- `renderer/` contains the Status and History panel routes.
- `main-window.html` is the renderer entry.
- `glaze.ts` resolves the Glaze CLI used by development and build scripts.

## Data

Seer writes `settings.json` and `history.json` under its own Glaze application
data directory. It does not import data from Stay Awake or Stay Awake Remix.

## Provenance

Seer is a Glaze remix of Stay Awake 6.0.0 by Samuel Kraft. The source grant and
version metadata are retained in `package.json`.
```

- [ ] **Step 2: Run the identity test after documentation changes**

Run:

```bash
npm test
```

Expected: all four tests PASS.

- [ ] **Step 3: Commit project documentation**

After Val explicitly approves this commit, run:

```bash
git add README.md
git commit -m "docs: document Seer development and provenance"
```

Expected: one documentation-only commit.

### Task 6: Run automated verification

**Files:**
- Verify: all imported and modified files

- [ ] **Step 1: Install dependencies from the lockfile**

Run:

```bash
npm ci
```

Expected: dependencies install without changing `package.json` or
`package-lock.json`.

- [ ] **Step 2: Run the complete available check set**

Run:

```bash
npm test && npm run type-check && npm run lint && npm run build
```

Expected: identity tests, TypeScript checks, lint, and production build all
exit successfully.

- [ ] **Step 3: Confirm the lockfile did not drift**

Run:

```bash
git diff -- package.json package-lock.json
```

Expected: no output.

- [ ] **Step 4: Confirm forbidden artifacts are not tracked**

Run:

```bash
git ls-files | rg '(^|/)(node_modules|\.glaze|\.glaze_memory)(/|$)|(^|/)\.mcp\.json$|(^|/)\.icon-hash$|\.log$'
```

Expected: no output.

- [ ] **Step 5: Confirm only approved provenance retains source identity**

Run:

```bash
rg -n "Stay Awake|Stay Awake Remix|Agent Sentinel|stay-awake-remix|5xc02mcz|c3f8a1d2-6b4e-4f91-9a2c-8e5d7b0f3a16" \
  --glob '!package.json' \
  --glob '!docs/superpowers/specs/**' \
  --glob '!docs/superpowers/plans/**' \
  --glob '!node_modules/**' \
  --glob '!.glaze/**'
```

Expected: only the README provenance paragraph may match `Stay Awake`; no
runtime, renderer, lockfile, or configuration file matches.

- [ ] **Step 6: Inspect the final diff**

Run:

```bash
git status --short --branch
git diff main...HEAD --stat
git diff main...HEAD --check
```

Expected: the branch is clean, the diff contains only the transplant,
identity contract, rebrand, and README, and `git diff --check` emits no output.

### Task 7: Perform the native menu-bar smoke check

**Files:**
- Verify: `main/index.ts`
- Verify: `main/services/tray.ts`
- Verify: `main/windows/panel-window.ts`
- Verify: `renderer/main/home-view.tsx`
- Verify: `renderer/main/history-view.tsx`

- [ ] **Step 1: Launch Seer in development**

Run:

```bash
npm run dev
```

Expected: Glaze starts Seer and logs application readiness, tray creation,
history-store loading, and monitor startup without reporting the old app name.

- [ ] **Step 2: Verify the tray and Status panel**

Using the native menu bar:

1. Confirm Seer has an always-visible tray icon while idle.
2. Left-click the icon and confirm the Status panel opens.
3. Confirm Status shows the current awake/sleep state and active-agent list.
4. Switch between System and System + Display and confirm the selection updates.
5. Press Escape and confirm the panel hides.

Expected: all interactions match the source behavior with Seer branding.

- [ ] **Step 3: Verify History and tray controls**

1. Reopen the panel and select History.
2. Confirm stat tiles, per-agent totals, recent sessions, and Clear are usable.
3. Blur the panel and confirm it hides.
4. Right-click the tray and confirm Open Seer, mode radios, and Quit Seer.
5. Quit Seer and confirm the development process exits cleanly.

Expected: all interactions work and shutdown flushes history without an error.

- [ ] **Step 4: Record any manual-only limitation accurately**

If native menu-bar interaction cannot be performed in the execution
environment, do not mark Steps 2-3 complete. Report automated checks separately
from the unverified manual surface.

### Task 8: Final handoff

**Files:**
- Review: complete branch diff

- [ ] **Step 1: Summarize the branch**

Run:

```bash
git log --oneline main..HEAD
git diff --stat main...HEAD
git status --short --branch
```

Expected: three scoped implementation commits after the approved design, with
a clean worktree and no push or publication.

- [ ] **Step 2: Prepare the handoff**

Report:

- the source transplant and explicit exclusions
- Seer's app ID and tray GUID
- preserved `glaze.remix` provenance
- changed files and behavior boundaries
- exact automated check results
- native smoke-check result or its explicit manual limitation
- that the branch remains local and unpushed

Do not merge, push, publish, tag, or release without Val's separate explicit
approval.
