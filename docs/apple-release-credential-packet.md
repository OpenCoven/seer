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
  feature branch. That branch is local only: it is unpushed and absent from
  `origin`, and is not yet merged to the default branch, pushed to a release
  tag, or deployed. Every remote resource and credential this packet
  describes — `OpenCoven/seer-releases`, the `macos-release` environment, its
  secrets, and its variables — remains unconfigured.

Do not add credentials until the release workflow has merged and been reviewed
on the repository's default branch.
GitHub exposes existing secret names but never their values, so the working
`coven-cave` secrets cannot be copied out of GitHub. Load Seer's secrets again
from the approved original `.p12`, `.p8`, password, and account records.

## Plan and billing prerequisite (blocking)

Verified with read-only `gh api` calls on 2026-08-17:

- The `OpenCoven` organization's GitHub plan is `free`.
- `OpenCoven/seer` is private with default branch `main`.
- `repos/OpenCoven/seer/environments` lists only `copilot`; `macos-release`
  does not exist yet.
- `.github/workflows/release-macos.yml` requires the protected `macos-release`
  environment (with required-reviewer approval) and `runs-on: macos-14-xlarge`
  for its signing/notarization job.

GitHub's required-reviewers environment protection is only available on
private repositories under GitHub Enterprise Cloud — it is public-repository
only on Free, Pro, and Team. Larger GitHub-hosted runners such as
`macos-14-xlarge` additionally require an organization on GitHub Team or
Enterprise Cloud with larger-runner/Actions billing enabled; Free-plan
organizations cannot provision them at all. `OpenCoven` on its current Free
plan can supply **neither** control this workflow's approved security gate
depends on, for a repository that must stay private
(`SOURCE_REPOSITORY_PRIVATE` is asserted `true` in the workflow's first step).

This is a hard blocker on the release path, independent of and prior to every
other step in this packet. It does not change, weaken, or redesign the
approved gate (required reviewers on `macos-release` plus `macos-14-xlarge`
remain mandatory) — it only identifies that the current plan cannot host that
gate.

**Required external action (Val/admin only, not performed by this packet):**

1. Upgrade or reassign the `OpenCoven` organization to a GitHub plan —
   GitHub Enterprise Cloud, or another plan/billing configuration GitHub
   currently documents as supporting both required reviewers on private-repo
   environments and `macos-14-xlarge` larger-runner entitlement — and enable
   the Actions billing/runner entitlement it requires.
2. After the plan change, an organization administrator must provision an
   arm64 macOS larger runner whose usable workflow label — the runner's
   `name`, which is what a GitHub-hosted larger runner is addressed by in
   `runs-on:` — is exactly `macos-14-xlarge`. This name must match the
   workflow's fixed `runs-on: macos-14-xlarge` exactly; the workflow's
   `runs-on` value and its `uname -m == arm64` assertion in
   `.github/workflows/release-macos.yml` are not changed by this packet and
   must not be changed to accommodate a differently named runner.
3. The administrator must grant `OpenCoven/seer` access to that runner
   through the runner group it belongs to (either by setting the group's
   visibility to all repositories, or by adding `OpenCoven/seer` to the
   group's selected-repositories list) and must confirm the runner's status
   is `Ready` (not `Provisioning`, `Shutdown`, `Deleting`, or `Stuck`) before
   it is relied on.
4. The administrator must configure Actions billing for `OpenCoven` with a
   nonzero budget/spending limit, since a runner that exists but has no
   spending headroom will fail jobs once the included usage is exhausted.
5. After the plan change, runner provisioning, access grant, and billing
   configuration, verify all four before creating `macos-release` or running
   the workflow. This packet only reads state; it never changes billing,
   plan, runner, runner-group, or org settings.

Read-only verification (safe to run repeatedly; none of these mutate state):

```bash
gh api orgs/OpenCoven --jq '{plan: .plan.name, seats: .plan.filled_seats}'
gh api repos/OpenCoven/seer --jq '{private, default_branch}'
gh api repos/OpenCoven/seer/environments --jq '.environments[].name'
# Organization hosted-runners list response uses `.runners[]`, not
# `.hosted_runners[]`.
gh api orgs/OpenCoven/actions/hosted-runners \
  --jq '.total_count, (.runners[] | {name, status, runner_group_id, platform})'
# Substitute the runner_group_id printed above, then confirm that group
# grants OpenCoven/seer access.
RUNNER_GROUP_ID="paste-the-runner_group_id-from-above"
gh api "orgs/OpenCoven/actions/runner-groups/${RUNNER_GROUP_ID}" \
  --jq '{name, visibility, allows_public_repositories}'
gh api "orgs/OpenCoven/actions/runner-groups/${RUNNER_GROUP_ID}/repositories" \
  --jq '.repositories[].full_name'
```

The commands above confirm the runner exists, is named `macos-14-xlarge`, is
`Ready`, and belongs to a group whose repository list (or `all`/`private`
visibility) includes `OpenCoven/seer`. They do **not** prove Actions billing
has a nonzero budget — GitHub's budgets API
(`GET /organizations/{org}/settings/billing/budgets`) requires organization
admin or billing-manager credentials this token may not carry, and its shape
varies by billing configuration. Verify the spending limit directly in the
GitHub UI instead: **Organization settings > Billing and licensing > Spending
limits > Actions**, and confirm the configured limit is greater than zero (or
that "Unlimited" is deliberately selected). Listing runners or runner-group
membership above is not evidence of a nonzero budget; check both,
separately.

Checklist for this prerequisite:

- [ ] `orgs/OpenCoven` plan confirmed to support required reviewers on
      private-repository environments (Enterprise Cloud, or a GitHub-verified
      equivalent) — re-run the command above and confirm the plan name
      changed from `free`
- [ ] Larger-runner entitlement confirmed enabled for `OpenCoven`, and an
      arm64 macOS larger runner named exactly `macos-14-xlarge` has been
      provisioned and shows `status: Ready` via
      `gh api orgs/OpenCoven/actions/hosted-runners`
- [ ] `OpenCoven/seer` confirmed present in that runner's runner-group
      access (via `.../runner-groups/<id>/repositories`, or the group's
      visibility is `all`)
- [ ] Actions billing spending limit confirmed nonzero for `OpenCoven` via
      the Billing and licensing UI (not provable from the runner-list API
      alone)
- [ ] All four controls verified again immediately before `macos-release` is
      created (plan/billing/runner/access changes can be reverted
      independently of this packet)

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
explicitly approved and created, **and** initialized with a reviewed commit on
its default branch — for example a product `README` added as part of the
repository's initial creation. This packet does not create
`OpenCoven/seer-releases`; that remains an explicit external action.

An empty default branch (no commits) fails `acquire_remote_lock` in
`scripts/release-macos-draft.sh`: it calls
`GET repos/OpenCoven/seer-releases/git/ref/heads/<default_branch>` and requires
the response to resolve to an object of `type == "commit"` with a
40-character lowercase SHA, aborting the release with "release repository
default branch does not point to a commit" otherwise. Verify this precondition
read-only before provisioning the token or using the workflow:

```bash
default_branch="$(gh api repos/OpenCoven/seer-releases --jq '.default_branch')"
gh api "repos/OpenCoven/seer-releases/git/ref/heads/${default_branch}" \
  --jq '{type: .object.type, sha: .object.sha}'
```

This must print `{"type":"commit","sha":"<40 lowercase hex characters>"}`
before the token is created or the release workflow is run.

Grant access only to that repository, with:

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

Run these commands from a trusted local terminal, in an **explicit Bash
shell**. macOS's default interactive shell is zsh, and zsh's `read -p` does
not silence or terminate input the same way Bash's `read -r -s -p` does, and
zsh's history/pipeline handling differs from Bash's. Do not paste this block
into a zsh prompt: start `bash` first, or save the block as a script and run
`bash load-secrets.sh`. Create and protect the `macos-release` environment
using the next section before running this.

The block below is Bash-only (`set -euo pipefail`), reads every sensitive
value with `IFS= read -r -s ... < /dev/tty` — directly from the controlling
terminal (so it can't silently accept an empty value piped in from
elsewhere) and with `IFS=` cleared (so leading/trailing whitespace in the
entered value is preserved instead of being stripped by `read`) — rejects
blank input instead of setting an empty secret, validates that
certificate/key files are readable, ordinary, non-symlink, non-empty files
before encoding them, keeps `pipefail` in effect across every
`base64 | tr | gh` pipeline, and unsets every value it reads once it has been
sent to GitHub. It never prints a secret value or writes an encoded copy to
disk.

```bash
set -euo pipefail

cd /path/to/seer

require_safe_secret_file() {
  local path="$1"
  [[ ! -L "${path}" ]] || { echo "error: ${path} must not be a symlink" >&2; return 1; }
  [[ -e "${path}" ]] || { echo "error: ${path} does not exist" >&2; return 1; }
  [[ -f "${path}" ]] || { echo "error: ${path} is not a regular file" >&2; return 1; }
  [[ -r "${path}" ]] || { echo "error: ${path} is not readable" >&2; return 1; }
  [[ -s "${path}" ]] || { echo "error: ${path} is empty" >&2; return 1; }
}

set_file_secret() {
  local secret_name="$1"
  local path="$2"
  require_safe_secret_file "${path}"
  base64 < "${path}" | tr -d '\n' |
    gh secret set "${secret_name}" --repo OpenCoven/seer --env macos-release
}

read_required_value() {
  # Reads from the controlling terminal, not stdin, so this cannot be
  # satisfied by piping in an empty (or any) value, and fails closed on a
  # blank answer instead of setting an empty secret.
  local prompt="$1"
  local value
  # IFS= preserves leading/trailing whitespace in the entered value instead
  # of letting `read` strip it.
  IFS= read -r -s -p "${prompt}: " value < /dev/tty
  echo >&2
  [[ -n "${value}" ]] || { echo "error: ${prompt} must not be empty" >&2; return 1; }
  printf '%s' "${value}"
}

set_text_secret() {
  local secret_name="$1"
  local prompt="$2"
  local value
  value="$(read_required_value "${prompt}")"
  printf '%s' "${value}" |
    gh secret set "${secret_name}" --repo OpenCoven/seer --env macos-release
  unset value
}

# --- Required for signing ---
P12_PATH="/secure/path/Seer-Developer-ID-Application.p12"
set_file_secret APPLE_CERTIFICATE "${P12_PATH}"
set_text_secret APPLE_CERTIFICATE_PASSWORD "APPLE_CERTIFICATE_PASSWORD"
# Not secret, but sent the same way for consistency.
printf '%s' "Developer ID Application: Soul Protocol LLC (9LR8Z8UQ9X)" |
  gh secret set APPLE_SIGNING_IDENTITY --repo OpenCoven/seer --env macos-release
set_text_secret APPLE_TEAM_ID "APPLE_TEAM_ID"

# --- Required for primary notarization ---
P8_PATH="/secure/path/AuthKey_EXAMPLE.p8"
set_file_secret APPLE_API_KEY_BASE64 "${P8_PATH}"
set_text_secret APPLE_API_ISSUER "APPLE_API_ISSUER"
set_text_secret APPLE_API_KEY "APPLE_API_KEY"

# --- Optional Apple ID fallback: run only if configuring it ---
set_text_secret APPLE_ID "APPLE_ID"
set_text_secret APPLE_PASSWORD "APPLE_PASSWORD"

# --- Required for binary publication: run only after OpenCoven/seer-releases
#     exists, is initialized with a reviewed default-branch commit, and the
#     fine-grained token is approved ---
set_text_secret RELEASES_REPO_TOKEN "RELEASES_REPO_TOKEN"

unset P12_PATH P8_PATH
```

Run only the sections that apply to this pass (for example, omit the Apple ID
fallback block if that path isn't being configured, and omit
`RELEASES_REPO_TOKEN` until `OpenCoven/seer-releases` exists and is
initialized). Each `set_*_secret` call is independent and can be copied out of
the block on its own once `require_safe_secret_file`, `set_file_secret`,
`read_required_value`, and `set_text_secret` are defined in the same shell.

Environment scope is intentional: repository-level secrets would be available
to other workflows without the release approval gate. The release job must
declare `environment: macos-release` before it can access these secrets.

## Configure the protected environment

Create a GitHub environment named `macos-release` only after the release
workflow has merged to the default branch **and** the plan and billing
prerequisite above has been verified — required reviewers cannot be enabled on
a private-repository environment, and this environment cannot be scheduled
onto `macos-14-xlarge`, until that upgrade is confirmed.

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
  gh api --method PUT repos/OpenCoven/seer-releases/immutable-releases
  ```

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

- [ ] `OpenCoven` organization plan/billing upgraded from Free and verified to
      support required reviewers on private-repository environments plus
      `macos-14-xlarge` larger-runner entitlement
- [ ] Release workflow implemented, reviewed, merged to the default branch,
      and pushed
- [ ] `OpenCoven/seer-releases` explicitly approved and created
- [ ] `OpenCoven/seer-releases` default branch initialized with a reviewed
      commit (e.g. an initial product `README`) and verified to resolve to a
      `commit` object via `git/ref/heads/<default_branch>`, matching
      `acquire_remote_lock`'s precondition
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
