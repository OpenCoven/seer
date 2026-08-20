# Seer public publication design

Date: 2026-08-20
Status: Approved

## Problem

`OpenCoven/seer` is private. Val wants it public. Making a repository public is
irreversible in practice: every commit on every branch, including the 166-commit
`feat/seer-standalone-macos` branch, becomes world-readable and mirrorable the
moment visibility flips. Anything sensitive in history stays retrievable even
after a later force-push, because forks and archives keep the objects.

So the publication cannot be a visibility toggle. It has to be a
harden-then-publish sequence where the leak defences exist and are proven before
the repository is exposed, and where the exposure itself is verified afterwards.

## Decisions

- **Harden first, publish second, verify third.** No visibility change until the
  pre-commit protocol, the ignore file, the CI scan, and the security policy are
  committed and pushed.
- **No history rewriting.** The single historical gitleaks finding is a verified
  false positive. Rewriting 172 commits to remove a synthetic test fixture would
  break every existing clone and the open feature branch for no security gain.
- **Suppress by fingerprint, never by path or rule.** A path-scoped allowlist on
  a test file would blind the scanner to a future real credential in that file.
- **Two independent scan layers.** A local pre-commit hook for fast feedback and
  a server-side CI workflow for enforcement. The hook can be bypassed with
  `--no-verify`; the workflow cannot.
- **Defence in depth with GitHub-native controls.** Secret scanning, push
  protection, Dependabot, and private vulnerability reporting are free on public
  repositories and cover pushes that never touch a local hook (web edits, other
  clones, other machines).
- **No open-source licence yet.** Public source with all rights reserved by
  default until the Glaze remix grant's redistribution terms are confirmed.
- **Both branches go public.** `main` and `feat/seer-standalone-macos` are both
  exposed. Both were scanned; neither carries a credential.

## Pre-publication audit

Run before any change, against the whole repository.

| Check | Result |
| --- | --- |
| `gitleaks git .` over all history | 172 commits, 4.49 MB, 1 finding |
| `gitleaks dir` on `origin/feat/seer-standalone-macos` tip | 5.75 MB, 1 finding (same fixture) |
| `gitleaks dir` on local `feat/seer-standalone-macos` tip | 5.87 MB, 1 finding (same fixture) |
| Risky paths in `git log --all --name-only` (`.env`, `.pem`, `.p12`, `.p8`, `id_rsa`, `credentials`, `keychain`, `authkey`) | none |
| `gh secret list` for `OpenCoven/seer` | zero secrets configured |
| Workflow token permissions on the feature branch | already `contents: read` least-privilege |
| `pull_request_target` / `workflow_run` triggers | none |

### The one finding

Rule `generic-api-key`, entropy 3.75, in `tests/package-macos-release.test.mjs`,
introduced by commit `0891bf5` ("fix: pin release signing keychain").

The test writes a throwaway shell script that impersonates `/usr/bin/codesign`
so it can assert which `--keychain` argument the packaging script passed. The
rule matches three shell locals declared inside that heredoc:

- a variable holding the expected keychain path, read at runtime from a file in
  a temp directory
- an empty-string accumulator for whichever `--keychain` argument was observed
- an integer counter of how many times `--keychain` appeared

The `keychain` keyword sitting next to a quoted assignment is what trips the
rule. The values are an empty string, a zero, and a temp path.

(The snippet is described rather than quoted on purpose: pasting it verbatim
into this document trips the same rule and would require a second suppression
for a document that contains no secret.) Verified by reading the fixture at both the introducing commit and
the current branch tip. This is a false positive.

## Components

### `.gitleaksignore`

Two fingerprints, both for the fixture above, each with a written justification:

- `0891bf5…:tests/package-macos-release.test.mjs:generic-api-key:1379` — the
  history-scan form, `<commit>:<path>:<rule>:<line>`.
- `tests/package-macos-release.test.mjs:generic-api-key:1444` — the tree-scan
  form, `<path>:<rule>:<line>`, needed because `gitleaks dir` and the
  pre-commit hook produce commit-less fingerprints and the line has moved since
  the introducing commit.

Line-pinned fingerprints fail closed: if that code moves, the suppression stops
matching and the finding reappears for re-review. That is the intended
behaviour, and the file header says so, so a future maintainer re-verifies
rather than broadening the suppression.

### `.pre-commit-config.yaml`

Mirrors the existing OpenCoven precedent in `OpenCoven/sdk`, pinned to the
gitleaks version actually installed locally (v8.30.1) rather than an older tag,
so local and CI results agree:

- `gitleaks` — staged-change secret scan
- `detect-private-key` — catches key material the generic rules miss
- `check-merge-conflict` — stops conflict markers reaching a public tree
- `check-added-large-files` (2 MB) — stops an accidental artifact or key blob

### `.github/workflows/secret-scan.yml`

The enforcing layer. Runs on every push and pull request, weekly on a schedule,
and on demand.

- `permissions: contents: read` — least privilege, matching the repo convention.
- `fetch-depth: 0` plus an explicit assertion that the clone is not shallow. A
  shallow clone would silently scan only the tip and report a false green.
- `persist-credentials: false` — the job never needs to write.
- Installs a **pinned, SHA256-verified** gitleaks 8.30.1 release binary rather
  than `gitleaks/gitleaks-action`, which requires a paid `GITLEAKS_LICENSE` for
  organisation-owned repositories and would fail closed on every run.
- Actions pinned to 40-character commit SHAs with a version comment, matching
  the pins already used in `standalone-ci.yml` and `release-macos.yml`.
- Scans both history (`gitleaks git`) and working tree (`gitleaks dir`) with
  `--exit-code 1`, and `--redact` so a real finding never prints the secret into
  public build logs.
- Uploads SARIF and JSON reports as artifacts with a 7-day retention.

### `SECURITY.md`

Private vulnerability reporting through GitHub Security Advisories, an explicit
in-scope/out-of-scope list, a statement that the repository holds no
credentials, and release-verification commands so a user can check a downloaded
build.

### `.gitignore`

Adds `*.profraw` (an untracked 503 KB LLVM profile file already sits in the
working tree) and `.worktrees/` (the isolated worktree used for this change).
Neither should ever be committed, least of all into a public repository.

### `README.md`

A `## Security` section documenting `pre-commit install`, the manual scan
commands, the suppression rules, and where Apple secrets actually live.

## Sequence

1. Build every component above in an isolated worktree so Val's unrelated
   uncommitted `js-yaml` dependency edits stay untouched.
2. Verify locally: gitleaks history and tree scans return zero findings, the
   ignore file suppresses exactly one finding and nothing more, `pre-commit
   run --all-files` passes, and the workflow YAML parses.
3. Commit signed, merge to `main`, push.
4. Flip visibility to public.
5. Enable secret scanning, push protection, Dependabot alerts and security
   updates, and private vulnerability reporting.
6. Protect `main`. This step is **only possible after** step 4: on this plan,
   rulesets and branch protection return HTTP 403 ("Upgrade to GitHub Pro or
   make this repository public") while the repository is private. That ordering
   constraint is why protection lands last rather than first.
7. Verify from outside: unauthenticated fetch of the repository, confirmed
   security settings, confirmed protection, and a green CI run.

## Failure handling

- **A scan finds a real credential at any point.** Stop. Do not publish. Rotate
  the credential first, then remediate history, then restart the sequence. A
  rotated secret is safe to leave in history; an unrotated one is not, and no
  amount of rewriting makes it safe once it has been pushed.
- **CI scan fails after publication.** The workflow exits non-zero and blocks
  the merge once required checks are on. Reports are redacted, so triage happens
  from the fingerprint and file, not from the logs.
- **A suppression stops matching.** Treated as a new finding by design.
  Re-verify the fixture, then re-pin the fingerprint.
- **Branch protection cannot be applied.** Publication still stands; protection
  is recorded as an outstanding gap rather than silently skipped.

## Out of scope

- Adding an open-source licence. Blocked on the Glaze remix grant's
  redistribution terms, which could not be verified from the local Glaze
  install (`/Applications/Glaze.app/Contents/Resources` is unreadable and the
  local grant metadata carries no terms).
- Publishing a binary release. The standalone spec already gates that on the
  same grant question plus the Apple credential packet.
- Rewriting history.
- Deleting or merging `feat/seer-standalone-macos`.

## Acceptance criteria

- `gitleaks git . --redact` and `gitleaks dir . --redact` both exit 0 on `main`.
- Removing `.gitleaksignore` reproduces exactly one finding, proving the file
  suppresses that finding and only that finding.
- `pre-commit run --all-files` passes.
- `gh api repos/OpenCoven/seer --jq .visibility` returns `public`.
- Secret scanning, push protection, Dependabot alerts, Dependabot security
  updates, and private vulnerability reporting all report as enabled.
- `main` requires signed commits and the `gitleaks` status check.
- An unauthenticated request reaches the repository.
