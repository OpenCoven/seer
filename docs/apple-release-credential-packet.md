# Seer Apple Release Credential Packet

This runbook prepares the credentials and GitHub controls required to sign,
notarize, and publish Seer's standalone macOS release.

It does not authorize creating repositories, configuring secrets, publishing
releases, or tagging builds. Those remain explicit external-action gates.

## Current state

Verified on 2026-08-12:

- `OpenCoven/seer` has no repository or release-environment Actions secrets.
- `OpenCoven/seer` has no `macos-release` environment.
- `OpenCoven/seer-releases` does not exist.
- This Mac has a valid `Developer ID Application: Soul Protocol LLC
  (9LR8Z8UQ9X)` signing identity.
- `OpenCoven/coven-cave` already uses the same Apple secret names successfully.
- The release workflow (`.github/workflows/release-macos.yml`) and packaging
  scripts (`scripts/release-macos-draft.sh`,
  `scripts/release-macos-draft-state.mjs`, and related `scripts/*macos*`
  tooling) are implemented and tested on the `feat/seer-standalone-macos`
  feature branch. They are not yet merged to the default branch, pushed to a
  release tag, or deployed. Every remote resource and credential this packet
  describes — `OpenCoven/seer-releases`, the `macos-release` environment, its
  secrets, and its variables — remains unconfigured.

Do not add credentials until the release workflow has merged and been reviewed
on the repository's default branch.
GitHub exposes existing secret names but never their values, so the working
`coven-cave` secrets cannot be copied out of GitHub. Load Seer's secrets again
from the approved original `.p12`, `.p8`, password, and account records.

## Required packet

Use the App Store Connect API-key path as the primary notarization method. The
Apple ID path is an optional fallback. A Developer ID Installer certificate is
not required for a DMG release.

### Required for signing

| GitHub environment secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE` | Single-line base64 encoding of a Developer ID Application `.p12` containing its private key |
| `APPLE_CERTIFICATE_PASSWORD` | Strong password chosen when exporting the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Exact Developer ID Application identity |
| `APPLE_TEAM_ID` | Apple Developer team ID |

### Required for primary notarization

| GitHub environment secret | Value |
| --- | --- |
| `APPLE_API_ISSUER` | App Store Connect API issuer UUID |
| `APPLE_API_KEY` | App Store Connect API key ID |
| `APPLE_API_KEY_BASE64` | Single-line base64 encoding of the downloaded `AuthKey_*.p8` |

### Optional notarization fallback

| GitHub environment secret | Value |
| --- | --- |
| `APPLE_ID` | Apple Developer account email |
| `APPLE_PASSWORD` | App-specific password created for notarization |

The packaging script must choose one complete notarization method. It must not
combine fields from two partial credential sets.

### Required for binary publication

| GitHub environment secret | Value |
| --- | --- |
| `RELEASES_REPO_TOKEN` | Fine-grained token limited to release writes in `OpenCoven/seer-releases` |

Create `RELEASES_REPO_TOKEN` only after the public release repository has been
explicitly approved and created. Grant access only to that repository, with:

- **Contents:** Read and write
- **Metadata:** Read-only, implicitly required by GitHub
- **Administration:** Read-only

`require_repository_governance` in `scripts/release-macos-draft.sh` runs
`GET repos/OpenCoven/seer-releases/immutable-releases` with this same token on
every invocation (`acquire-lock`, `reconcile-published`, `preflight`, `upload`,
`capture`, `publish`, and `release-lock`), because the GitHub REST API requires
repository `Administration: read` to read that endpoint — `Contents` and
`Metadata` access are not sufficient. Grant read-only, not read-and-write:
read is enough to verify the setting, and write would let this token enable or
disable repository-administration state that it must not control.

Do not grant organization administration, Administration write, Actions
administration, source-repo write access, or access to other repositories.

### Required release-writer identity variables

`.github/workflows/release-macos.yml` reads `vars.RELEASE_WRITER_LOGIN` and
`vars.RELEASE_WRITER_ID` from the `macos-release` environment. These are
GitHub Actions **environment variables**, not secrets — set them with
`gh variable set`, not `gh secret set`. The workflow rejects the run before any
credential is used if either is missing or malformed:

| GitHub environment variable | Format | Purpose |
| --- | --- | --- |
| `RELEASE_WRITER_LOGIN` | Exact GitHub login of the `RELEASES_REPO_TOKEN` owner; must match `^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$` | Pins the workflow to one specific token-owning account |
| `RELEASE_WRITER_ID` | Exact numeric GitHub user ID of that same account; must match `^[1-9][0-9]*$` | Prevents a login rename or account substitution from silently changing the trusted release writer |

`scripts/release-macos-draft.sh` and `scripts/release-macos-draft-state.mjs`
independently verify, on every mutating call, that `RELEASES_REPO_TOKEN`
authenticates as the GitHub user whose `id` and `login` exactly equal these
two values, and that the release's `author` matches them too. A token that
authenticates as any other account fails closed.

Determine the two values from the account that will hold
`RELEASES_REPO_TOKEN`, then set them once the `macos-release` environment
exists:

```bash
gh api user --jq '{login, id}'
```

```bash
gh variable set RELEASE_WRITER_LOGIN --repo OpenCoven/seer --env macos-release \
  --body "the-account-login"
gh variable set RELEASE_WRITER_ID --repo OpenCoven/seer --env macos-release \
  --body "123456"
```

Environment variables are visible in plaintext (they identify an account, not
a credential), so verify them by reading their values directly instead of
only checking presence:

```bash
gh variable list --repo OpenCoven/seer --env macos-release
gh variable get RELEASE_WRITER_LOGIN --repo OpenCoven/seer --env macos-release
gh variable get RELEASE_WRITER_ID --repo OpenCoven/seer --env macos-release
```

## Export the signing certificate

Use Keychain Access on the trusted release Mac:

1. Open **My Certificates** in the login keychain.
2. Expand the `Developer ID Application: Soul Protocol LLC (9LR8Z8UQ9X)`
   certificate and confirm that a private key appears beneath it.
3. Export that certificate and private key together as
   `Seer-Developer-ID-Application.p12`.
4. Set a new strong export password. This becomes
   `APPLE_CERTIFICATE_PASSWORD`.
5. Do not export an Apple Development, Apple Distribution, or Developer ID
   Installer identity.

Confirm the expected identity without exposing private material:

```bash
security find-identity -v -p codesigning |
  grep -F "Developer ID Application: Soul Protocol LLC (9LR8Z8UQ9X)"
```

Keep the `.p12` and its password in separate secure records. Never place the
file beneath the Seer checkout, attach it to an issue, send it in chat, or add
it to shell history.

## Obtain notarization credentials

### App Store Connect API key

Use an existing organization-controlled key if its policy permits reuse;
otherwise create a dedicated key in App Store Connect under **Users and
Access > Integrations**.

Record:

- issuer UUID as `APPLE_API_ISSUER`
- key ID as `APPLE_API_KEY`
- the downloaded `AuthKey_*.p8` as the source for `APPLE_API_KEY_BASE64`

Apple permits the `.p8` file to be downloaded only once. Preserve the original
in the approved secrets vault before continuing.

### Apple ID fallback

If the fallback path is required, create a dedicated app-specific password for
the Apple Developer account and record it as `APPLE_PASSWORD`. Do not use the
account's normal password.

## Load protected environment secrets safely

Run these commands from a trusted local terminal. They stream files directly to
GitHub and avoid writing encoded copies to disk. Create and protect the
`macos-release` environment using the next section before running them.

```bash
cd /path/to/seer
P12_PATH="/secure/path/Seer-Developer-ID-Application.p12"
P8_PATH="/secure/path/AuthKey_EXAMPLE.p8"

base64 < "$P12_PATH" | tr -d '\n' |
  gh secret set APPLE_CERTIFICATE --repo OpenCoven/seer --env macos-release
base64 < "$P8_PATH" | tr -d '\n' |
  gh secret set APPLE_API_KEY_BASE64 --repo OpenCoven/seer --env macos-release
```

Load text secrets without putting their values in command history:

```bash
read -r -s -p "APPLE_CERTIFICATE_PASSWORD: " VALUE; echo
printf '%s' "$VALUE" |
  gh secret set APPLE_CERTIFICATE_PASSWORD --repo OpenCoven/seer --env macos-release
unset VALUE

read -r -s -p "APPLE_API_ISSUER: " VALUE; echo
printf '%s' "$VALUE" |
  gh secret set APPLE_API_ISSUER --repo OpenCoven/seer --env macos-release
unset VALUE

read -r -s -p "APPLE_API_KEY: " VALUE; echo
printf '%s' "$VALUE" |
  gh secret set APPLE_API_KEY --repo OpenCoven/seer --env macos-release
unset VALUE

read -r -s -p "APPLE_TEAM_ID: " VALUE; echo
printf '%s' "$VALUE" |
  gh secret set APPLE_TEAM_ID --repo OpenCoven/seer --env macos-release
unset VALUE
```

The signing identity is not secret, but use the same input path for
consistency:

```bash
printf '%s' \
  "Developer ID Application: Soul Protocol LLC (9LR8Z8UQ9X)" |
  gh secret set APPLE_SIGNING_IDENTITY --repo OpenCoven/seer --env macos-release
```

If configuring the Apple ID fallback:

```bash
read -r -s -p "APPLE_ID: " VALUE; echo
printf '%s' "$VALUE" |
  gh secret set APPLE_ID --repo OpenCoven/seer --env macos-release
unset VALUE

read -r -s -p "APPLE_PASSWORD: " VALUE; echo
printf '%s' "$VALUE" |
  gh secret set APPLE_PASSWORD --repo OpenCoven/seer --env macos-release
unset VALUE
```

After `OpenCoven/seer-releases` exists and the fine-grained token is approved:

```bash
read -r -s -p "RELEASES_REPO_TOKEN: " VALUE; echo
printf '%s' "$VALUE" |
  gh secret set RELEASES_REPO_TOKEN --repo OpenCoven/seer --env macos-release
unset VALUE
```

Environment scope is intentional: repository-level secrets would be available
to other workflows without the release approval gate. The release job must
declare `environment: macos-release` before it can access these secrets.

## Configure the protected environment

Create a GitHub environment named `macos-release` only after the release
workflow has merged to the default branch.

Configure:

- required reviewer approval
- prevent self-review where the GitHub plan supports it
- deployment restrictions limited to semantic release tags
- no bypass for administrators unless emergency policy explicitly requires it

Initialize these environment variables:

| Variable | Initial value |
| --- | --- |
| `BINARY_DISTRIBUTION_APPROVED` | `false` |
| `PARITY_MATRIX_APPROVED` | `false` |
| `CLEAN_MACHINE_VERIFIED_COMMIT` | `UNVERIFIED` |

They become releasable only when:

- retained remix rights permit standalone binary distribution
- every parity row passes
- the exact release commit passes on a clean Apple Silicon macOS 14 machine

At that point set both approval variables to `true` and set
`CLEAN_MACHINE_VERIFIED_COMMIT` to the exact lowercase 40-character source
commit. The workflow must reject any other value.

## Enable and verify immutable releases in `OpenCoven/seer-releases`

`scripts/release-macos-draft.sh` and `scripts/release-macos-draft-state.mjs`
require GitHub's immutable-releases protection to already be enabled on
`OpenCoven/seer-releases` before they will draft, sign, or publish anything.
`require_repository_governance` in the shell script fetches
`GET repos/OpenCoven/seer-releases/immutable-releases` using
`RELEASES_REPO_TOKEN`, and `runImmutable` in the Node helper fails the run
unless the parsed response has `enabled === true`; it does not require the
response to contain only that field, so any additional fields GitHub returns
alongside `enabled` are accepted. Neither script enables the setting; both
only verify it.

Enabling the setting is a write, so it is out of scope for
`RELEASES_REPO_TOKEN`'s `Administration: read` grant. Enable it once, after
`OpenCoven/seer-releases` is created and before any tagged release runs, from
an account with administrative (write) access to that repository:

- In the GitHub UI: open `OpenCoven/seer-releases` → **Settings** → scroll to
  the **Releases** section → enable **Enable release immutability**.
- Equivalently, using an admin's own elevated session (not
  `RELEASES_REPO_TOKEN`):

  ```bash
  gh api --method PUT repos/OpenCoven/seer-releases/immutable-releases \
    -F enabled=true
  ```

  `-F` sends `enabled` as a typed JSON boolean; `-f` would send it as the
  string `"true"`, which the endpoint does not accept as a boolean.

Verify the setting with the same `Administration: read` access already
granted to `RELEASES_REPO_TOKEN` for this purpose — read access is sufficient
and does not require the elevated write access needed to enable the setting:

```bash
gh api repos/OpenCoven/seer-releases/immutable-releases --jq '.enabled'
```

This must print `true` before the first tagged release run. Once enabled,
immutability applies only to releases published from that point forward, and
the workflow's own read of this endpoint fails the job closed if it is ever
disabled or missing.

## Verify configuration without reading secrets

GitHub never returns secret values. Verify names and timestamps only:

```bash
gh secret list --repo OpenCoven/seer --env macos-release
gh variable list --repo OpenCoven/seer --env macos-release
gh api repos/OpenCoven/seer/environments/macos-release \
  --jq '{name, protection_rules, deployment_branch_policy}'
```

For the primary API-key path, the expected environment secret names are:

```text
APPLE_API_ISSUER
APPLE_API_KEY
APPLE_API_KEY_BASE64
APPLE_CERTIFICATE
APPLE_CERTIFICATE_PASSWORD
APPLE_SIGNING_IDENTITY
APPLE_TEAM_ID
RELEASES_REPO_TOKEN
```

`APPLE_ID` and `APPLE_PASSWORD` appear only when the fallback is configured.

The expected environment variable names (not secrets — safe to display in
full with `gh variable get`) are:

```text
BINARY_DISTRIBUTION_APPROVED
CLEAN_MACHINE_VERIFIED_COMMIT
PARITY_MATRIX_APPROVED
RELEASE_WRITER_ID
RELEASE_WRITER_LOGIN
```

Do not validate credentials by printing them, echoing them into logs, or
running an unreviewed workflow. The first live validation happens in the
protected release job after its credential-import and notarization steps have
been reviewed.

## Rotation and incident response

- Rotate the `.p12` when the certificate changes, expires, or may have leaked.
- Revoke and replace the App Store Connect API key if its `.p8` may have leaked.
- Revoke and replace the app-specific password independently of the Apple ID.
- Revoke `RELEASES_REPO_TOKEN` immediately if its scope or storage is in doubt.
- Update GitHub secrets before revoking credentials needed by the last known
  good release, then run the protected validation path.
- Treat any secret printed in terminal logs, CI logs, chat, or an issue as
  compromised.

## Completion checklist

- [ ] Release workflow implemented, reviewed, merged to the default branch,
      and pushed
- [ ] `OpenCoven/seer-releases` explicitly approved and created
- [ ] Immutable releases enabled on `OpenCoven/seer-releases` and verified by
      confirming `.enabled` is `true` in the API response (additional
      response fields are expected and do not affect the check)
- [ ] Developer ID Application `.p12` exported with private key
- [ ] `.p12` password stored separately
- [ ] App Store Connect issuer ID, key ID, and `.p8` secured
- [ ] Optional Apple ID fallback intentionally enabled or omitted
- [ ] Fine-grained release token scoped only to `seer-releases`
- [ ] Required `macos-release` environment secrets present by name
- [ ] `RELEASE_WRITER_LOGIN` and `RELEASE_WRITER_ID` set to the exact login
      and numeric ID of the `RELEASES_REPO_TOKEN` owner
- [ ] `macos-release` environment protection configured
- [ ] Approval variables remain false until parity and clean-machine gates pass
- [ ] Original `.p12` and `.p8` retained only in approved secure storage
