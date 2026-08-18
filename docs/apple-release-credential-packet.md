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
  environment (with required-reviewer approval) and binds both the `prepare`
  and `sign-and-release` jobs to the object-form
  `runs-on: { group: seer-macos-release, labels: macos-14-xlarge }` for its
  build and signing/notarization work.

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
approved gate (required reviewers on `macos-release` plus the
`seer-macos-release` runner group with the `macos-14-xlarge` runner remain
mandatory) — it only identifies that the current plan cannot host that gate.

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
   workflow's fixed `labels: macos-14-xlarge` exactly; the workflow's
   `runs-on` value and its `uname -m == arm64` assertion in
   `.github/workflows/release-macos.yml` are not changed by this packet and
   must not be changed to accommodate a differently named runner.
3. The administrator must create (or reuse) an organization runner group
   named exactly `seer-macos-release` and add that runner to it. The
   workflow's `runs-on` binds to this exact group name in addition to the
   `macos-14-xlarge` label — see the "Runner group binding" note below for
   why the label alone is not sufficient. The administrator must grant
   `OpenCoven/seer` access to that group by adding `OpenCoven/seer` to the
   group's **selected repositories** list; prefer this over setting the
   group's visibility to all repositories, since all-repositories visibility
   would let every other repository in the org — not just `OpenCoven/seer` —
   schedule jobs onto this signing-capable runner. The administrator must
   also confirm the runner's status is `Ready` (not `Provisioning`,
   `Shutdown`, `Deleting`, or `Stuck`) before it is relied on.
4. The administrator must configure Actions billing for `OpenCoven` in
   **Organization settings > Billing & Licensing > Budgets and alerts**: add
   a valid payment method, and confirm every budget that applies to Actions
   usage or larger-runner usage (organization-wide, product-level, or
   SKU-level) still has spending headroom and that none of them is an
   exhausted **hard-stop** budget (a budget with "Stop usage when budget
   limit is reached" enabled at 100% used blocks all further Actions runs,
   including this workflow, until the next billing cycle or a raised limit).
   A runner that exists but has no payment method or has exhausted a
   hard-stop budget will fail jobs outright.
5. After the plan change, runner provisioning, runner-group creation and
   access grant, and billing configuration, verify all of the above before
   creating `macos-release` or running the workflow. This packet only reads
   state; it never changes billing, plan, runner, runner-group, or org
   settings.

### Runner group binding (why label alone is not enough)

A label-only `runs-on: macos-14-xlarge` schedules the job onto **any** runner
in the organization that carries that label, in any runner group the calling
repository can reach — not necessarily the specific runner this packet
verifies below. Anyone who can create or rename another organization runner
with the same `macos-14-xlarge` label (in a group `OpenCoven/seer` also has
access to) could have the `prepare` or credential-bearing `sign-and-release`
job scheduled onto it instead. `.github/workflows/release-macos.yml` closes
this gap by using GitHub Actions' object-form `runs-on`:

```yaml
runs-on:
  group: seer-macos-release
  labels: macos-14-xlarge
```

This binds the job to the exact `seer-macos-release` runner group **and**
the exact `macos-14-xlarge` label; both must match. Do not weaken this back
to a bare `runs-on: macos-14-xlarge` string, and do not repoint it at a
different group — either change would reopen the runner-substitution gap
this packet's verification below is designed to catch.

Read-only verification (safe to run repeatedly; none of these mutate state):

```bash
gh api orgs/OpenCoven --jq '{plan: .plan.name, seats: .plan.filled_seats}'
gh api repos/OpenCoven/seer --jq '{private, default_branch}'
gh api repos/OpenCoven/seer/environments --jq '.environments[].name'
# Organization hosted-runners list response uses `.runners[]`, not
# `.hosted_runners[]`. Print image_details and machine_size_details too —
# the runner's `name` is administrator-chosen and provable trust must come
# from these detail fields, not from the name matching `macos-14-xlarge`.
gh api orgs/OpenCoven/actions/hosted-runners \
  --jq '.total_count, (.runners[] | {name, status, runner_group_id, platform, image_details, machine_size_details})'
# Substitute the runner_group_id printed above, then confirm that group is
# named exactly seer-macos-release and grants OpenCoven/seer access.
RUNNER_GROUP_ID="paste-the-runner_group_id-from-above"
gh api "orgs/OpenCoven/actions/runner-groups/${RUNNER_GROUP_ID}" \
  --jq '{name, visibility, allows_public_repositories}'
gh api "orgs/OpenCoven/actions/runner-groups/${RUNNER_GROUP_ID}/repositories" \
  --jq '.repositories[].full_name'
```

The commands above confirm the runner is named `macos-14-xlarge`, is
`Ready`, and belongs to a runner group named exactly `seer-macos-release`
whose repository list includes `OpenCoven/seer` (selected-repositories
visibility is preferred over `all`; see requirement 3 above). Require —
do not just print — that `image_details` and `machine_size_details` prove
the runner is macOS 14 on arm64 at the XLarge size: `image_details` must
show a macOS 14 image (its `display_name`/`id` identifying `macos-14` and
`platform` reporting the arm64 architecture), and `machine_size_details`
must report the CPU-core and memory figures GitHub documents for the macOS
XLarge tier. Do not trust the runner's `name` field alone — a name is
administrator-chosen text and proves nothing about the underlying image or
machine size. The workflow's own `uname -m == arm64` runtime assertion stays
in place as defense in depth in case a runner is ever misconfigured despite
this check.

These commands do **not** prove Actions billing has payment-method or budget
headroom — GitHub's budgets API
(`GET /organizations/{org}/settings/billing/budgets`) requires organization
admin or billing-manager credentials this token may not carry, and its shape
varies by billing configuration. Verify billing directly in the GitHub UI
instead: **Organization settings > Billing & Licensing > Budgets and
alerts**. Confirm a valid payment method is on file, and confirm every
budget that applies to Actions or larger-runner usage still has remaining
headroom and that no such budget is an exhausted hard-stop budget (a budget
with "Stop usage when budget limit is reached" enabled and fully consumed).
Listing runners or runner-group membership above is not evidence of billing
headroom; check both, separately.

Checklist for this prerequisite:

- [ ] `orgs/OpenCoven` plan confirmed to support required reviewers on
      private-repository environments (Enterprise Cloud, or a GitHub-verified
      equivalent) — re-run the command above and confirm the plan name
      changed from `free`
- [ ] Larger-runner entitlement confirmed enabled for `OpenCoven`, and an
      arm64 macOS larger runner named exactly `macos-14-xlarge` has been
      provisioned and shows `status: Ready` via
      `gh api orgs/OpenCoven/actions/hosted-runners`
- [ ] That runner's `image_details` and `machine_size_details` (not its name
      alone) confirmed to prove macOS 14, arm64, and the XLarge machine size
- [ ] That runner belongs to an organization runner group named exactly
      `seer-macos-release`
- [ ] `OpenCoven/seer` confirmed present in that runner group's
      selected-repositories access list (via
      `.../runner-groups/<id>/repositories`); all-repositories visibility is
      used only if selected-repositories is not viable, and that choice is
      recorded here
- [ ] A valid payment method confirmed on file for `OpenCoven` via
      **Billing & Licensing > Budgets and alerts**
- [ ] Every budget applicable to Actions/larger-runner usage confirmed to
      have remaining headroom, and no such budget confirmed to be an
      exhausted hard-stop budget (not provable from the runner-list API
      alone)
- [ ] All controls above verified again immediately before `macos-release`
      is created (plan/billing/runner/runner-group/access changes can be
      reverted independently of this packet)

## Required packet

Notarization has two mutually exclusive credential configurations: the App
Store Connect API-key method and the Apple ID method. These are **not** a
primary path with an optional fallback that can be layered on top of it —
`.github/workflows/release-macos.yml` reads all nine `APPLE_*` secrets: 4
signing secrets that are always required (`APPLE_CERTIFICATE`,
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_TEAM_ID`) plus
5 notarization-related secrets split across the two mutually exclusive
methods (3 API-key fields — `APPLE_API_ISSUER`, `APPLE_API_KEY`,
`APPLE_API_KEY_BASE64` — and 2 Apple ID fields — `APPLE_ID`,
`APPLE_PASSWORD`). All nine are read unconditionally and passed to
`scripts/package-macos-release.sh`, which counts how many of the 5
notarization fields are present for each method and `fail`s the run if
either method is only partially configured (1–2 of the 3 API-key fields, or
1 of the 2 Apple ID fields), **and also fails the run if both methods are
fully configured at once** — it does not attempt either method automatically
as a fallback for the other. Configure exactly one complete notarization
credential set (3 or 2 secrets, never both) as an environment secret, and
leave every secret belonging to the other method entirely absent (not empty)
from `macos-release`. **Recommended: the App Store Connect API-key method.**
A Developer ID Installer certificate is not required for a DMG release.

### Required for signing

| GitHub environment secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE` | Single-line base64 encoding of a Developer ID Application `.p12` containing its private key |
| `APPLE_CERTIFICATE_PASSWORD` | Strong password chosen when exporting the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Exact Developer ID Application identity |
| `APPLE_TEAM_ID` | Apple Developer team ID |

### Notarization method A: App Store Connect API key (recommended)

| GitHub environment secret | Value |
| --- | --- |
| `APPLE_API_ISSUER` | App Store Connect API issuer UUID |
| `APPLE_API_KEY` | App Store Connect API key ID |
| `APPLE_API_KEY_BASE64` | Single-line base64 encoding of the downloaded `AuthKey_*.p8` |

Configure all three of these, and do not configure any Method B (Apple ID)
secret below in the same environment.

### Notarization method B: Apple ID (alternative — do not combine with method A)

| GitHub environment secret | Value |
| --- | --- |
| `APPLE_ID` | Apple Developer account email |
| `APPLE_PASSWORD` | App-specific password created for notarization |

Configure both of these only if Method A is not usable, and only if neither
`APPLE_API_ISSUER`, `APPLE_API_KEY`, nor `APPLE_API_KEY_BASE64` is present in
`macos-release`.

The packaging script requires exactly one complete notarization method. It
rejects a run with zero complete sets, a partial set for either method, or two
complete sets configured simultaneously — it never combines fields from two
partial sets and never falls back from one method to the other
automatically. If you switch methods later, remove every secret belonging to
the method you are no longer using (see "Load protected environment secrets
safely" and "Verify configuration without reading secrets" below) before
running the release workflow again.

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

Choose one method below. Do not complete both — see "Required packet" above
for why the packaging script rejects the run if both are configured.

### Method A: App Store Connect API key (recommended)

Use an existing organization-controlled key if its policy permits reuse;
otherwise create a dedicated key in App Store Connect under **Users and
Access > Integrations**.

Record:

- issuer UUID as `APPLE_API_ISSUER`
- key ID as `APPLE_API_KEY`
- the downloaded `AuthKey_*.p8` as the source for `APPLE_API_KEY_BASE64`

Apple permits the `.p8` file to be downloaded only once. Preserve the original
in the approved secrets vault before continuing.

### Method B: Apple ID (alternative)

If Method A is not usable, create a dedicated app-specific password for the
Apple Developer account and record it as `APPLE_PASSWORD`, along with the
account email as `APPLE_ID`. Do not use the account's normal password.

## Load protected environment secrets safely

Run these commands from a trusted local terminal, in an **explicit Bash
shell**. macOS's default interactive shell is zsh, and zsh's `read -p` does
not silence or terminate input the same way Bash's `read -r -s -p` does, and
zsh's history/pipeline handling differs from Bash's. Do not paste this block
into a zsh prompt: start `bash` first, or save the block as a script and run
`bash load-secrets.sh`. Create and protect the `macos-release` environment
using the next section before running this.

The block below is written for Method A (App Store Connect API key), the
recommended notarization method: it loads only `APPLE_API_ISSUER`,
`APPLE_API_KEY`, and `APPLE_API_KEY_BASE64`, and does **not** include
`APPLE_ID` or `APPLE_PASSWORD`. If Method B (Apple ID) is being configured
instead, replace the "Notarization method A" section with calls to
`set_text_secret APPLE_ID "APPLE_ID"` and
`set_text_secret APPLE_PASSWORD "APPLE_PASSWORD"`, and omit the three
`APPLE_API_*` calls entirely — do not run both sections in the same pass.
`gh secret set` only sets the secret it is given; it never removes a secret
left over from the other method, so if `macos-release` was previously
configured with the other method's secrets, delete them explicitly before
switching (see "Switching notarization methods safely" below) rather than
relying on this block to overwrite or clear them.

The block below fails closed if shell xtrace is already enabled (checked
first, before any other line runs), is Bash-only (`set -euo pipefail`), reads
every sensitive value with `IFS= read -r -s ... < /dev/tty` — directly from
the controlling terminal (so it can't silently accept an empty value piped in
from elsewhere) and with `IFS=` cleared (so leading/trailing whitespace in the
entered value is preserved instead of being stripped by `read`) — rejects
blank input instead of setting an empty secret, validates that
certificate/key files are readable, ordinary, non-symlink, non-empty files
before encoding them, keeps `pipefail` in effect across every
`base64 | tr | gh` pipeline, and unsets every value it reads once it has been
sent to GitHub. It never prints a secret value or writes an encoded copy to
disk.

```bash
# Fail closed if shell xtrace is enabled, before any secret value or file is
# touched. `set -x` (or an inherited PS4/BASH_XTRACEFD trace, or a wrapping
# script/profile that turned tracing on) echoes every command this script
# runs, with its expanded arguments, to stderr — which means a secret held
# in a shell variable would be printed in cleartext to the terminal,
# scrollback buffer, or a captured log the moment it was passed to `base64`,
# `tr`, `gh`, or any other command. Checking `$-` (the flags of the running
# shell) for an `x` catches this regardless of how tracing was turned on,
# and exits before `set -euo pipefail` or any secret-handling function
# below ever runs.
case "$-" in
  *x*)
    echo "error: shell xtrace (set -x) is enabled; disable it before loading secrets" >&2
    exit 1
    ;;
esac

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

# --- Notarization method A: App Store Connect API key (recommended) ---
# Active by default. Do not also uncomment the Method B section below in the
# same pass: the packaging script rejects a run that has both a complete
# API-key set and a complete Apple ID set configured. If Method A is not
# usable for this release, comment out these three lines instead of leaving
# them alongside Method B.
P8_PATH="/secure/path/AuthKey_EXAMPLE.p8"
set_file_secret APPLE_API_KEY_BASE64 "${P8_PATH}"
set_text_secret APPLE_API_ISSUER "APPLE_API_ISSUER"
set_text_secret APPLE_API_KEY "APPLE_API_KEY"

# --- Notarization method B: Apple ID (alternative) ---
# Commented out by default. Uncomment these two lines only if Method A above
# is commented out instead, and only after deleting any Method A secrets left
# over from a previous pass (see "Switching notarization methods safely"
# below).
# set_text_secret APPLE_ID "APPLE_ID"
# set_text_secret APPLE_PASSWORD "APPLE_PASSWORD"

# --- Required for binary publication: run only after OpenCoven/seer-releases
#     exists, is initialized with a reviewed default-branch commit, and the
#     fine-grained token is approved ---
set_text_secret RELEASES_REPO_TOKEN "RELEASES_REPO_TOKEN"

unset P12_PATH P8_PATH
```

Run only the sections that apply to this pass — exactly one of the two
notarization method sections above should be uncommented, never both — and
omit `RELEASES_REPO_TOKEN` until `OpenCoven/seer-releases` exists and is
initialized. Each `set_*_secret` call is independent and can be copied out of
the block on its own once `require_safe_secret_file`, `set_file_secret`,
`read_required_value`, and `set_text_secret` are defined in the same shell.

### The authoritative sensitive-secret name set

Every audit and deletion command in this section and the two below it
operates on the same fixed set of ten names — the nine `APPLE_*` secrets
`.github/workflows/release-macos.yml` reads unconditionally (see "Required
packet" above: 4 always-required signing secrets, 3 Method A notarization
secrets, and 2 Method B notarization secrets) plus `RELEASES_REPO_TOKEN`:

```text
APPLE_CERTIFICATE
APPLE_CERTIFICATE_PASSWORD
APPLE_SIGNING_IDENTITY
APPLE_TEAM_ID
APPLE_API_ISSUER
APPLE_API_KEY
APPLE_API_KEY_BASE64
APPLE_ID
APPLE_PASSWORD
RELEASES_REPO_TOKEN
```

`APPLE_SIGNING_IDENTITY`'s value (a Developer ID Application identity
string) is not itself confidential, but the release job reads it via
`secrets.APPLE_SIGNING_IDENTITY`, so it is bound by the same
`environment: macos-release` gate as the other nine names and must be
included in every audit below — a repository- or organization-level
`APPLE_SIGNING_IDENTITY` bypasses the approval gate exactly like a leaked
signing secret would, even though the value alone needs no confidentiality.
Audit **all ten** names at repository and organization scope every time —
not only the currently-unused notarization method's names. A stray
repository- or organization-level copy of the *active* method's names, or
of a signing secret or `RELEASES_REPO_TOKEN`, is just as capable of
silently shadowing this environment on some future rotation as a copy of
the unused method's names is today.

### Switching notarization methods safely

If `macos-release` was previously configured with one notarization method and
you are now switching to the other, `gh secret set` for the new method's
secrets does not remove the old method's secrets — they remain configured and
the packaging script will fail the run with "provide exactly one notarization
credential set; both were provided" (`scripts/package-macos-release.sh`)
until they are deleted. Follow this sequence in order; do not delete or load
any secret before completing the earlier steps, because a release run that
is still queued, waiting, or in progress when secrets are deleted can carry
forward a stale credential (see step 2's explanation below).

#### 1. Prevent new release tag runs

```bash
# Blocks the workflow from starting on any new "v*.*.*" tag push for the
# duration of the maintenance window. Documented for the operator to run
# manually; this packet does not run it.
gh workflow disable release-macos.yml --repo OpenCoven/seer
```

Also coordinate with any other maintainer who could push a release tag
during this window — disabling the workflow prevents new runs from
starting, but does not itself communicate that a credential switch is in
progress.

#### 2. List and drain every queued, waiting, or in-progress release run

```bash
# Read-only, exhaustively paginated REST enumeration — walks every page via
# the API's Link-header pagination, so (unlike a --limit-bounded `gh run
# list`) no fixed page count can hide an older queued/waiting run, and this
# keeps working once step 1 disables the workflow (a disabled workflow's
# past runs remain listable via this endpoint; only new runs stop being
# created). Fails closed in every case: if the enumeration call itself
# fails (API error, auth failure, network error, 404 — e.g. the workflow
# file was renamed or moved), that is a verification failure, not zero
# active runs, and must not be treated as "drained"; if any non-completed
# run is found, it is listed; the success message below prints only once
# the exhaustive check actually completed and found none.
if ! active_runs="$(gh api --paginate \
  'repos/OpenCoven/seer/actions/workflows/release-macos.yml/runs?per_page=100' \
  --jq '.workflow_runs[] | select(.status != "completed") | [.id, .status] | @tsv')"; then
  echo "Failed to verify release-macos.yml run status (gh api error: auth, network, or 404) — treat as unverified, not as zero active runs." >&2
  exit 1
fi
if [ -n "$active_runs" ]; then
  echo "Active (non-completed) release-macos.yml runs found:" >&2
  printf '%s\n' "$active_runs" >&2
  exit 1
fi
echo "No active release-macos.yml runs (exhaustive paginated check)."
```

If this exits nonzero, resolve the cause before continuing: a printed
verification-failed message means the enumeration itself could not be
trusted (fix the underlying `gh api` error and re-run), while a listing of
run IDs means drain each listed run:

```bash
# Documented for the operator to run manually, once per run ID returned
# above. This packet does not run it and cancels nothing on its own.
gh run cancel <run-id> --repo OpenCoven/seer
```

Re-run the read-only enumeration command and confirm it exits zero with no
listed run IDs before proceeding to step 3.

Draining first closes a fallback window that deleting-then-verifying alone
does not: the release job's `environment: macos-release` secrets are
(re)resolved fresh at that job's start, but repository- and
organization-level ("lower-scope") secrets are effectively fixed for a run
once GitHub schedules it — a run already queued or waiting snapshots
lower-scope secrets earlier in its lifecycle than the point where
environment secrets are actually read. A run queued before the operator
removes a lower-scope duplicate (step 3) or deletes the unused-method
environment secrets (step 5) can therefore still execute against a stale
lower-scope credential even after the environment-scoped switch is
complete elsewhere — silently reviving exactly the credential this
maintenance is meant to retire. Draining every non-completed run before
touching any secret removes any run that could carry such a stale
snapshot forward.

#### 3. Remove or restrict lower-scope duplicates of the full name set

Audit repository and organization scope for **all ten** names from "The
authoritative sensitive-secret name set" above before deleting anything
from the `macos-release` environment. GitHub Actions resolves a same-named
secret with `environment > repository > organization` precedence: if a
repository-level or organization-level secret with one of these ten names
is visible to `OpenCoven/seer`, it becomes the effective value the moment a
same-named environment secret is deleted — silently reviving the unused
notarization method (or an old signing credential, or an old
`RELEASES_REPO_TOKEN`) instead of leaving it absent. Use
name/metadata-only commands that never print a secret value:

```bash
# Repository-scope secrets (outside the macos-release environment)
gh secret list --repo OpenCoven/seer

# Organization secrets, with their visibility to member repositories
gh secret list --org OpenCoven \
  --json name,visibility,numSelectedRepos,selectedReposURL

# For any org secret above with visibility "selected", confirm whether
# OpenCoven/seer is one of the selected repositories. --paginate is
# required: this endpoint pages at 30 repositories per response, and
# without it a selected-repositories list longer than one page silently
# truncates to page 1 — if OpenCoven/seer happens to fall on page 2 or
# later, an unpaginated call reports it as not-selected when it actually
# is, hiding a real precedence risk.
gh api --paginate "orgs/OpenCoven/actions/secrets/<SECRET_NAME>/repositories" \
  --jq '.repositories[].full_name'
```

Every selected-repository organization-secret visibility enumeration in this
packet must include `--paginate` for the same reason — never rely on a
single unpaginated page to conclude `OpenCoven/seer` is absent from a
"selected" secret's repository list.

If `gh secret list --repo OpenCoven/seer` lists any of the ten names at
repository scope, delete each one — a leftover repository-level secret is
otherwise inert only for as long as the higher-precedence environment copy
exists:

```bash
# Repository-scope deletion, one example per notarization method. Run only
# for names actually listed at repository scope; omit --env.
gh secret delete APPLE_ID --repo OpenCoven/seer
gh secret delete APPLE_PASSWORD --repo OpenCoven/seer
```

Likewise, if `gh secret list --org OpenCoven` shows an organization secret
with one of these ten names and its `visibility` field is `all`, or
`private` and `OpenCoven/seer` is a private repository, or `selected` and
`OpenCoven/seer` appears in that secret's repository list, remove
`OpenCoven/seer`'s access to it before continuing — either by deleting the
organization secret (if no other repository requires it) or by narrowing
its visibility to exclude `OpenCoven/seer`. These are org-admin-scoped
actions outside this packet's operator role for `OpenCoven/seer` alone;
coordinate with an organization owner rather than running them unreviewed.
As with the repository-scope deletions above, all repository- and
organization-scope commands in this section are documented for the
operator (or organization owner) to run manually — this packet does not
run them and makes no claim that any repository or organization secret has
been read, changed, or deleted.

Environment scope is intentional: repository-level secrets would be
available to other workflows without the release approval gate. The
release job must declare `environment: macos-release` before it can access
these secrets. That intent holds only while no same-named repository- or
organization-level secret among the ten names above is also visible to
`OpenCoven/seer`.

#### 4. Verify absence

Re-run the three read-only commands in step 3 and confirm none of the ten
names from "The authoritative sensitive-secret name set" remain visible to
`OpenCoven/seer` at repository or organization scope. Do not proceed to
step 5 until this is confirmed.

#### 5. Delete the unused method's environment secrets, then load the replacement set

Only once steps 1–4 are complete, delete the unused notarization method's
secrets from the `macos-release` environment:

```bash
# Switching to Method A (API key): delete Method B (Apple ID) secrets first.
gh secret delete APPLE_ID --repo OpenCoven/seer --env macos-release
gh secret delete APPLE_PASSWORD --repo OpenCoven/seer --env macos-release
```

```bash
# Switching to Method B (Apple ID): delete Method A (API key) secrets first.
gh secret delete APPLE_API_ISSUER --repo OpenCoven/seer --env macos-release
gh secret delete APPLE_API_KEY --repo OpenCoven/seer --env macos-release
gh secret delete APPLE_API_KEY_BASE64 --repo OpenCoven/seer --env macos-release
```

These commands are documented here for the operator to run manually when
switching methods; this packet does not run them. Confirm the deletion with
`gh secret list --repo OpenCoven/seer --env macos-release` (see "Verify
configuration without reading secrets" below), then load the new method's
complete secret set per "Load protected environment secrets safely" above
before re-enabling the workflow:

```bash
# Re-allow new release tag runs once the replacement set is fully loaded
# and verified.
gh workflow enable release-macos.yml --repo OpenCoven/seer
```

## Configure the protected environment

Create a GitHub environment named `macos-release` only after the release
workflow has merged to the default branch **and** the plan and billing
prerequisite above has been verified — required reviewers cannot be enabled on
a private-repository environment, and this environment cannot be scheduled
onto the `seer-macos-release` group's `macos-14-xlarge` runner, until that
upgrade is confirmed.

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

# Repository- and organization-scope secrets, checked for the same-name
# precedence risk described in "Switching notarization methods safely" >
# "Remove or restrict lower-scope duplicates of the full name set" above
gh secret list --repo OpenCoven/seer
gh secret list --org OpenCoven \
  --json name,visibility,numSelectedRepos,selectedReposURL

# Read-only, exhaustively paginated REST enumeration: confirm no release
# workflow run is queued, waiting, or in-progress (see "Switching
# notarization methods safely" > step 2 above for why this must be empty
# before, and stay empty during, any secret change). --paginate walks every
# page, so no --limit value can hide an older non-completed run, and this
# keeps working once the workflow is disabled. Fails closed in every case:
# if the enumeration call itself fails (API error, auth failure, network
# error, 404), that is a verification failure, not zero active runs, and
# must not be treated as safe to proceed; if any non-completed run is
# found, it is listed; the success message below prints only once the
# exhaustive check actually completed and found none.
if ! active_runs="$(gh api --paginate \
  'repos/OpenCoven/seer/actions/workflows/release-macos.yml/runs?per_page=100' \
  --jq '.workflow_runs[] | select(.status != "completed") | [.id, .status] | @tsv')"; then
  echo "Failed to verify release-macos.yml run status (gh api error: auth, network, or 404) — treat as unverified, not as zero active runs." >&2
  exit 1
fi
if [ -n "$active_runs" ]; then
  echo "Active (non-completed) release-macos.yml runs found:" >&2
  printf '%s\n' "$active_runs" >&2
  exit 1
fi
echo "No active release-macos.yml runs (exhaustive paginated check)."
```

For Method A (App Store Connect API key, recommended), the expected
environment secret names are:

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

`APPLE_ID` and `APPLE_PASSWORD` must **not** appear in this listing. If they
do, the packaging script will fail the run (`fail "provide exactly one
notarization credential set; both were provided"` in
`scripts/package-macos-release.sh`) — delete them per "Switching
notarization methods safely" above. Both names must also be absent from
`gh secret list --repo OpenCoven/seer` (repository scope) and unreachable
from `OpenCoven/seer` through any `OpenCoven` organization secret (per
"Switching notarization methods safely" > "Remove or restrict lower-scope
duplicates of the full name set" above) — an environment-scope listing
alone does not rule out a same-named secret resurfacing through repository
or organization precedence once the environment copy is deleted.

For Method B (Apple ID, alternative), the expected environment secret names
are instead:

```text
APPLE_CERTIFICATE
APPLE_CERTIFICATE_PASSWORD
APPLE_ID
APPLE_PASSWORD
APPLE_SIGNING_IDENTITY
APPLE_TEAM_ID
RELEASES_REPO_TOKEN
```

`APPLE_API_ISSUER`, `APPLE_API_KEY`, and `APPLE_API_KEY_BASE64` must **not**
appear in this listing; delete them per "Switching notarization methods
safely" above if they do. All three names must also be absent from `gh
secret list --repo OpenCoven/seer` (repository scope) and unreachable from
`OpenCoven/seer` through any `OpenCoven` organization secret (per
"Switching notarization methods safely" > "Remove or restrict lower-scope
duplicates of the full name set" above), for the same precedence-fallback
reason as the Method A check. Exactly one of these two lists — never a
mix, and never neither — must match `gh secret list`'s output (aside from
`RELEASES_REPO_TOKEN`, which is independent of the notarization method).

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
- If notarization methods are ever switched, confirm the previously used
  method's secrets were deleted (not merely superseded) at every applicable
  scope — environment, repository, and any visible organization secret — see
  "Switching notarization methods safely" above (including its "drain queued
  runs" and "authoritative sensitive-secret name set" steps) — so a leaked
  or rotated credential from the unused method cannot silently remain
  configured, resurface through secret precedence, or run to completion in
  a queued job that started before the switch.

## Completion checklist

- [ ] `OpenCoven` organization plan/billing upgraded from Free and verified to
      support required reviewers on private-repository environments plus
      `macos-14-xlarge` larger-runner entitlement in the `seer-macos-release`
      runner group (verified via `image_details`/`machine_size_details`, not
      the runner name alone), with a valid payment method and headroom on
      every applicable Actions/larger-runner budget in **Budgets and alerts**
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
- [ ] Exactly one notarization method chosen: App Store Connect API key
      (recommended: issuer ID, key ID, and `.p8` secured) **or** Apple ID
      (app-specific password and account email) — not both, not neither
- [ ] Every secret name belonging to the notarization method **not** chosen
      is confirmed absent at every applicable scope: the `macos-release`
      environment (deleted via `gh secret delete ... --env macos-release` if
      it was configured for a previous release under the other method), the
      `OpenCoven/seer` repository (via `gh secret list --repo
      OpenCoven/seer`), and any `OpenCoven` organization secret visible to
      `OpenCoven/seer` (deleted or restricted so its visibility excludes
      `OpenCoven/seer`, confirmed with `--paginate` on the selected-repository
      enumeration) — see "Switching notarization methods safely" > "Remove or
      restrict lower-scope duplicates of the full name set"; the intended
      environment-only design otherwise still leaves the unused method
      reachable via repository/organization precedence once only the
      environment copy is removed
- [ ] All ten names in "The authoritative sensitive-secret name set" —
      not only the unused notarization method's names — confirmed absent
      from repository and organization scope visible to `OpenCoven/seer`,
      including the always-required signing/certificate secrets and
      `RELEASES_REPO_TOKEN`
- [ ] Before any notarization-method switch: the release workflow disabled
      (`gh workflow disable release-macos.yml`), every queued, waiting, or
      in-progress release run drained (confirmed by the exhaustively
      paginated `gh api --paginate
      repos/OpenCoven/seer/actions/workflows/release-macos.yml/runs` check
      in "List and drain every queued, waiting, or in-progress release run"
      exiting zero with no active runs listed), and lower-scope
      duplicates removed — all completed **before** deleting the unused
      method's environment secrets or loading the replacement set, and the
      workflow re-enabled only after the replacement set is loaded and
      verified
- [ ] Fine-grained release token scoped only to `seer-releases`
- [ ] Required `macos-release` environment secrets present by name, matching
      exactly one of the two expected-name lists in "Verify configuration
      without reading secrets"
- [ ] `RELEASE_WRITER_LOGIN` and `RELEASE_WRITER_ID` set to the exact login
      and numeric ID of the `RELEASES_REPO_TOKEN` owner
- [ ] `macos-release` environment protection configured
- [ ] Approval variables remain false until parity and clean-machine gates pass
- [ ] Original `.p12` and `.p8` retained only in approved secure storage
- [ ] Secret-loading shell confirmed to run with xtrace (`set -x`) disabled
      before any secret value or file is read or piped
