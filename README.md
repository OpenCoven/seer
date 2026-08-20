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

## Standalone macOS distribution

The standalone Swift/AppKit application and signed release pipeline are
designed and planned but not yet implemented:

- [Standalone distribution design](docs/superpowers/specs/2026-08-10-seer-standalone-macos-distribution.md)
- [Standalone implementation plan](docs/superpowers/plans/2026-08-10-seer-standalone-macos-distribution.md)
- [Apple release credential packet](docs/apple-release-credential-packet.md)

Do not add Apple credentials until the release workflow has landed and been
reviewed.

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

- `main/` — lifecycle, agent detection, monitoring, storage, tray, panel, and IPC
- `renderer/` — Status and History panel routes
- `main-window.html` — renderer entry
- `glaze.ts` — resolves the installed Glaze SDK/CLI used by dev/build scripts

## Data

Seer stores `settings.json` and `history.json` in Seer’s own Glaze app data. It does not import settings or history from Stay Awake/Remix.

## Provenance

Seer is a Glaze remix of Stay Awake 6.0.0 by Samuel Kraft. The source grant and version metadata are retained in `package.json`.
