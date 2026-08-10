# Seer

Seer is a macOS menu-bar utility that keeps the Mac awake while AI coding agents work.

It detects supported agents from local processes and session data, starts a macOS power-save blocker while work is active, records local activity history, and runs as an accessory app with no Dock icon.

## Features

- Detects supported agents from local processes and session data: Claude Code, Codex, Grok, Gemini CLI, Aider, OpenCode, Goose, Amp, Cursor, and Continue
- Shows live agents and keep-awake status from the menu bar
- Retains both System and System + Display keep-awake modes
- Records local session totals, daily totals, and per-agent history
- Stores all settings and history locally in Seer's application data

## Requirements

- macOS
- Node.js 24.11 or newer
- Glaze SDK/host 0.13.0.0+

## Development

```bash
npm install
npm run dev
```

Checks:

```bash
npm test
npm run type-check
npm run lint
npm run build
```

## Architecture

- `main/` — lifecycle, agent detection, monitoring, storage, tray, panel, and IPC
- `renderer/` — Status and History panel routes
- `main-window.html` — renderer entry
- `glaze.ts` — resolves the installed Glaze SDK/CLI used by dev/build scripts

## Data

Seer stores `settings.json` and `history.json` in Seer’s own Glaze app data. It does not import settings or history from Stay Awake/Remix.

## Provenance

Seer is a Glaze remix of Stay Awake 6.0.0 by Samuel Kraft. The source grant and version metadata are retained in `package.json`.
