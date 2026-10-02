# Generic baseline checklist

> Always-on. Applies to every audit regardless of profile. Covers secrets, supply chain, repo hygiene, and basic OPSEC that any software project should pass.

Read this file on every `/cso-audit` invocation (it's always active).

## Threat outcomes we defend against

1. **Credential leakage** — secrets committed, secrets in history, secrets in CI logs
2. **Supply-chain compromise** — vulnerable transitive deps, unsigned releases, lockfile drift
3. **Repo hijacking** — missing branch protection, unsigned commits, dependency confusion
4. **Future you, weeping** — undocumented critical infra, no LICENSE, no SECURITY.md

## Checklist (G-1 to G-8)

### G-1: Secrets in source / history

> If `.git/` is absent, the history-scanning items (G-1.1) and branch-protection items (G-5) cannot run. Emit one `info` finding (source `cso-audit:no-git`) listing the skipped items, then continue with the current-tree checks (G-1.2 through G-1.6).

- **G-1.1** Run `gitleaks detect` on the full git history. Any hit is at least `high`; verified live credentials are `critical`.
- **G-1.2** Grep current tree for high-confidence patterns:
  - AWS: `AKIA[0-9A-Z]{16}`, `aws_secret_access_key`
  - GCP: service-account JSON keys (`-----BEGIN PRIVATE KEY-----` near `"type": "service_account"`)
  - Stripe: `sk_live_`, `rk_live_`, `whsec_`
  - Slack: `xoxb-`, `xoxp-`, `xapp-`
  - GitHub: `ghp_`, `gho_`, `ghs_`, `github_pat_`
  - JWT-looking blobs that decode to live values
  - Generic high-entropy strings (last-line check, high false-positive rate)
- **G-1.3** `.env`, `.env.local`, `.env.production`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa`, `*.kdbx`, `*.keystore` not committed.
  - In current tree → `high`/`critical`.
  - In history but `.gitignore`d now → still `high` if credential is live; secrets in history live forever.
- **G-1.4** `.gitignore` lists the common offenders.
- **G-1.5** `.env.example` / `.env.sample` contains *only* placeholders, never real values.
- **G-1.6** Backup files (`*.bak`, `*.orig`, `*.swp`) not committed — they often contain pre-redacted versions.

### G-2: Dependency hygiene
- **G-2.1** Lockfile exists for every package manager in the repo (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `Gemfile.lock`, `Cargo.lock`, `composer.lock`, `poetry.lock`, `go.sum`, `Podfile.lock`, `Package.resolved`).
- **G-2.2** Vulnerability scanner ran (the language-appropriate one — see `tools.md`). Findings rolled in.
- **G-2.3** No unpinned `latest` / `*` versions on security-critical deps (auth, crypto, sanitizers, validators).
- **G-2.4** Lockfile checked in (not in `.gitignore`).
- **G-2.5** `package.json` (or equivalent) does not include `postinstall` scripts that download/execute remote code at install time. If present, flag and read what it does.

### G-3: Supply-chain risk surface
- **G-3.1** Count of direct dependencies — flag if absurdly large for the project type. (Heuristic: small CLI > 50 direct deps = `medium` worth questioning.)
- **G-3.2** Recently-published dependencies (< 90 days, < 1k downloads/week, single maintainer) on critical paths — flag for review (typosquatting risk).
- **G-3.3** Dependency confusion risk: internal package names that could collide with public registries (e.g., `@company/internal-auth`).
- **G-3.4** Vendored binaries (`bin/*`, `*.so`, `*.dll`, `*.dylib`) reviewed for provenance.
- **G-3.5** Submodules / git URL deps point to specific commits (not branches).

### G-4: Repository hygiene
- **G-4.1** `LICENSE` file present.
- **G-4.2** `SECURITY.md` present declaring vulnerability reporting process (preferred contact, response time).
- **G-4.3** `README.md` doesn't reveal sensitive infra (internal hostnames, IP ranges, admin URLs) unless intentionally public.
- **G-4.4** `CONTRIBUTING.md` — bonus, not a finding if missing.
- **G-4.5** No huge committed binaries pushing the repo above reasonable size (LFS or skip).
- **G-4.6** No `TODO: SECURITY` / `FIXME: VULNERABLE` / `XXX: insecure` markers left in code without tracking ticket.

### G-5: Branch protection & CI provenance (if hosted on GitHub/GitLab/etc.)
- **G-5.1** `main` / `master` / `develop` branch protected: required reviews ≥1, dismiss stale approvals, status checks required.
- **G-5.2** Force-push disabled on protected branches.
- **G-5.3** Signed commits (GPG / SSH / sigstore) — bonus for high-value projects, not always a finding.
- **G-5.4** Required status checks include the security scanners (`gitleaks`, `osv-scanner`, etc.) so they actually gate merges.
- **G-5.5** Webhooks reviewed — none pointing to abandoned domains.

### G-6: CI/CD secrets
- **G-6.1** Workflow files (`.github/workflows/*.yml`, `.gitlab-ci.yml`) reviewed:
  - No `echo $SECRET` (echoing secrets to logs).
  - Secrets passed via `env:` block scoped to the step.
  - No `pull_request_target` checking out PR code (classic RCE in CI).
- **G-6.2** Third-party actions pinned to commit SHA, not `@v1` (a tag can be moved).
- **G-6.3** OIDC used for cloud-credential exchange where available.

### G-7: License compliance
- **G-7.1** Dependency licenses reviewed if redistribution is in play. GPL/AGPL in a proprietary product = legal risk, flag as `medium` (not strictly a security finding but a release blocker).
- **G-7.2** Project's own LICENSE compatible with its dependencies' licenses.

### G-8: Documentation of sensitive flows
- **G-8.1** `SECURITY.md` (or similar) names: maintainer contact, supported versions, disclosure process, encryption preference (PGP key / Signal).
- **G-8.2** If the project handles payments, PII, or regulated data — a basic data-flow note exists somewhere (README, ARCHITECTURE.md).
- **G-8.3** Threat-model artifact exists or is consciously deferred — note its absence as `info` (not a finding worth blocking on, but worth flagging).

## Tools mapping

| Item | Tool that catches it |
|------|---------------------|
| G-1.x | gitleaks, trufflehog, grep |
| G-2.x | npm/pnpm/yarn audit, pip-audit, govulncheck, cargo audit, composer audit, osv-scanner |
| G-3.x | Manual review of dep tree; osv-scanner finds known CVEs |
| G-4.x | `ls` + `git log --stat` review |
| G-5.x | Manual review of repo settings (or `gh api repos/:owner/:repo/branches/main/protection`) |
| G-6.x | actionlint, manual |
| G-7.x | `license-checker` (npm), `pip-licenses`, manual |
| G-8.x | Manual |

## Severity calibration cheat sheet

- Critical: live AWS / GCP / Stripe / GitHub PAT in source or history, post-install script fetching remote code, accept-all in CI workflow.
- High: any committed secret (even rotated — assume still live for the audit), missing lockfile on prod project, `pull_request_target` with PR checkout.
- Medium: floating major version on auth lib, missing branch protection on main, vulnerable transitive dep without exploit.
- Low: missing `.env.example`, missing SECURITY.md, GPL transitive in proprietary product, third-party action pinned to tag not SHA.
- Info: opportunity for SLSA provenance, opportunity for commit signing, opportunity to publish threat model.

## Remediation prompt template

```
Issue: `<short title>` at `<file or git ref>`.

Steps:
1. <Concrete first step — usually rotate the credential / revoke the key / remove from history>
2. <Update .gitignore / source / lockfile>
3. <Verify by re-running the scanner: `gitleaks detect`, `npm audit`, etc.>
4. <Document the rotation in SECURITY.md or incident log if a credential was leaked>

If the leak was a credential committed to history:
- Treat as compromised even if "private repo." Rotate now. Removing from history (BFG, `git filter-repo`) is cleanup, not remediation.
```

## References

- OWASP SAMM — https://owaspsamm.org/
- NIST SSDF — https://csrc.nist.gov/projects/ssdf
- SLSA — https://slsa.dev/
- GitHub security best practices — https://docs.github.com/en/code-security
- OWASP Dependency Check / OSV — https://osv.dev/
