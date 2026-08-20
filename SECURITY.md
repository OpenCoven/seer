# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Report privately through GitHub's private vulnerability reporting:

<https://github.com/OpenCoven/seer/security/advisories/new>

Include the affected version or commit, what an attacker gains, and the
smallest set of steps that reproduces the issue. If you cannot use GitHub
Security Advisories, open a public issue that says only that you have a
security report and asks for a private channel — no details.

You should get an acknowledgement within 7 days. Please give us 90 days before
public disclosure, or less if we agree a fix has shipped.

## Scope

Seer is a macOS menu-bar utility that prevents the system from sleeping while
long-running agent work is in flight. In scope:

- the app itself and its build, packaging, signing, and notarization scripts
- the GitHub Actions workflows in this repository
- anything that could let a third party tamper with a release artifact

Out of scope:

- vulnerabilities in Apple's operating system, `caffeinate`, or `pmset`
- vulnerabilities in the upstream Glaze host application
- findings that require an attacker to already have local administrator or
  physical access to the machine
- reports produced solely by an automated scanner with no demonstrated impact

## Secrets and credentials

This repository is public and holds **no** credentials.

- Apple signing and notarization secrets live only in the protected
  `macos-release` GitHub environment, never in the repository, never in a
  workflow file, and never in an issue or pull request. See
  [`docs/apple-release-credential-packet.md`](docs/apple-release-credential-packet.md).
- Every commit is scanned by [gitleaks](https://github.com/gitleaks/gitleaks),
  locally through `.pre-commit-config.yaml` and again server-side through
  [`.github/workflows/secret-scan.yml`](.github/workflows/secret-scan.yml).
- GitHub secret scanning and push protection are enabled on this repository.

If you believe a credential has been committed here, treat it as live: report
it privately using the process above and do not use it. Suppressions in
`.gitleaksignore` are limited to fingerprint-pinned, individually justified
false positives.

## Releases

Signed and notarized builds are produced only by the protected release
workflow. Do not trust a Seer binary that did not come from a GitHub release in
this organisation, and verify with:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/Seer.app
spctl --assess --type execute --verbose /Applications/Seer.app
```
