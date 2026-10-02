# Tool catalog

> External security tools the skill tries to run, organized by profile. Used in Phase 3 of `/cso-audit`. For each tool: what it does, install-check command, invocation, output parsing hint.

## How to use this file

For each active profile, look up the tools in its section. For each tool:

1. **Check installation** with the listed command. Use a short timeout (5s).
2. If installed → add to `tools_available[]`, run it, parse output into findings.
3. If missing → add to `tools_missing[]`, fall back to checklist review for the items that tool would have covered.

Run tool invocations **in parallel** when they operate on different file sets and don't interfere. Cap any single tool at a reasonable timeout (60s for scans, 300s for full repo deep-scans).

For non-zero exit codes:
- Many security tools return non-zero when findings exist — this is normal, not a failure.
- A real error (missing input, permission denied, panic) needs to be logged as a tool-execution finding (`info` severity, source `cso-audit:tool-error`) so the user knows that scanner didn't fully run.

---

## Always-on (used by `generic` and most profiles)

### `gitleaks` — secret scanner (git history + tree)
- **Install check:** `command -v gitleaks`
- **Run:** `gitleaks detect --no-banner --report-format json --report-path /tmp/gitleaks.json --source .`
- **Parse:** JSON array; each entry has `Description`, `File`, `StartLine`, `Match`, `RuleID`, `Commit`.
- **Severity mapping:** any hit → at least `high`; live credentials (AWS, GCP, Stripe, Slack) → `critical`.

### `trufflehog` — secret scanner (alternative to gitleaks, broader rules)
- **Install check:** `command -v trufflehog`
- **Run:** `trufflehog git file://. --json --no-update`
- **Parse:** JSON lines; key fields `DetectorName`, `Raw`, `SourceMetadata.Data.Git.file`, `SourceMetadata.Data.Git.line`, `Verified` (true = active credential).
- **Severity mapping:** `Verified=true` → `critical`; otherwise `high`.

Run only one of gitleaks or trufflehog (gitleaks preferred — faster). Don't double-count.

### `semgrep` — SAST (multi-language, rule-based)
- **Install check:** `command -v semgrep`
- **Run:** `semgrep --config auto --json --quiet --error --timeout 60 .`
  - Or, with profile-specific configs: `--config p/owasp-top-ten`, `--config p/jwt`, `--config p/secrets`, `--config p/dockerfile`, `--config p/kubernetes`, `--config p/terraform`.
- **Parse:** JSON; results in `.results[]`, each has `check_id`, `path`, `start.line`, `extra.severity` (INFO/WARNING/ERROR), `extra.message`, `extra.metadata.cwe`, `extra.metadata.owasp`.
- **Severity mapping:** ERROR → `high` (escalate to `critical` if CWE indicates RCE / auth-bypass / sql-injection); WARNING → `medium`; INFO → `low`.

### `osv-scanner` — dependency vulnerability scanner (OSV.dev)
- **Install check:** `command -v osv-scanner`
- **Run:** `osv-scanner --format json --recursive .`
- **Parse:** JSON; results in `.results[].packages[].vulnerabilities[]`, with `id` (CVE/GHSA), `summary`, `severity` (CVSS).
- **Severity mapping:** CVSS ≥9.0 → `critical`; 7.0–8.9 → `high`; 4.0–6.9 → `medium`; <4.0 → `low`.

---

## `frontend`

### `npm audit` / `pnpm audit` / `yarn audit`
- **Install check:** detect from `package-lock.json` / `pnpm-lock.yaml` / `yarn.lock`.
- **Run:** `npm audit --json` (or pnpm/yarn equivalent).
- **Parse:** JSON; `vulnerabilities` object, each with `severity` (info/low/moderate/high/critical), `via`, `range`.
- **Severity mapping:** use as reported; collapse moderate → `medium`.

### `retire.js`
- **Install check:** `command -v retire`
- **Run:** `retire --outputformat json --outputpath /tmp/retire.json`
- **Parse:** JSON; per-file results with vulnerable JS libs.

### `eslint-plugin-security` (if eslint config already exists)
- **Install check:** `cat eslint.config.* package.json | grep -q eslint-plugin-security`
- **Run:** `npx eslint --ext .js,.jsx,.ts,.tsx --no-eslintrc --config <(echo '{"plugins":["security"],"extends":["plugin:security/recommended"]}') --format json .`
- **Parse:** JSON; messages array.

### Manual checks (no good tool — checklist only)
- CSP headers (parse the `next.config.*` / framework config or HTML `<meta http-equiv="Content-Security-Policy">`)
- HSTS, X-Frame-Options, Referrer-Policy, Permissions-Policy
- Cookies: `Secure`, `HttpOnly`, `SameSite`
- DOM XSS sinks: `dangerouslySetInnerHTML`, `v-html`, direct `innerHTML =` assignments — grep for them.

---

## `backend`

### Language-specific dependency scanners

| Language | Tool | Run |
|----------|------|-----|
| Node.js | `npm audit` / `pnpm audit` / `yarn audit` | as above |
| Python | `pip-audit` | `pip-audit --format json` |
| Python | `safety` | `safety scan --output json` |
| Ruby | `bundler-audit` | `bundle audit check --format json` |
| Go | `govulncheck` | `govulncheck -json ./...` |
| Java | `mvn dependency-check:check` (OWASP DC) or `gradle dependencyCheckAnalyze` | per-tool docs |
| Rust | `cargo audit` | `cargo audit --json` |
| PHP | `composer audit` | `composer audit --format=json` |
| .NET | `dotnet list package --vulnerable` | parse text |

### `semgrep` with backend-specific configs
- Add `--config p/owasp-top-ten --config p/jwt --config p/sql-injection --config p/command-injection --config p/insecure-transport`.

### Language-specific SAST

| Language | Tool |
|----------|------|
| Go | `gosec` — `gosec -fmt json ./...` |
| Python | `bandit` — `bandit -r . -f json` |
| Ruby | `brakeman` (Rails) — `brakeman -f json -o /tmp/brakeman.json` |
| Java | `spotbugs` + `find-sec-bugs` plugin |
| PHP | `phpstan` (with `phpstan-security` rules) or `psalm` (with `psalm-plugin-laravel`) |
| Rust | `cargo-geiger` (unsafe usage analysis) |

### Manual checks
- Auth model: who can call what? Look for missing middleware, wide-open routes.
- Authorization: IDOR — does the handler check `resource.owner_id == current_user.id`?
- Rate limiting + brute-force protection on auth endpoints.
- Error responses: do they leak stack traces, SQL fragments, internal hostnames?
- Secrets management: env vars vs file vs secret manager.
- CORS: wildcard `*` with credentials = critical.

---

## `infrastructure`

### `trivy` — container + IaC + filesystem scanner (Swiss army knife)
- **Install check:** `command -v trivy`
- **Run multiple modes:**
  - `trivy config --format json .` (IaC misconfigs in Dockerfile/Terraform/K8s/Helm)
  - `trivy fs --format json --scanners vuln,secret,misconfig .` (filesystem)
  - `trivy image --format json <image:tag>` if a built image exists
- **Parse:** JSON; `Results[].Misconfigurations[]` and `Results[].Vulnerabilities[]`.
- **Severity:** trivy reports `CRITICAL/HIGH/MEDIUM/LOW/UNKNOWN` — map directly.

### `checkov` — IaC policy scanner
- **Install check:** `command -v checkov`
- **Run:** `checkov -d . -o json --quiet`
- **Parse:** JSON; `results.failed_checks[]` with `check_id`, `file_path`, `file_line_range`, `severity`.

### `tfsec` — Terraform-specific
- **Install check:** `command -v tfsec` (note: deprecated in favor of trivy, but still common)
- **Run:** `tfsec --format json .`

### `kube-score` / `kubescape` — Kubernetes manifest scanners
- **kube-score:** `kube-score score --output-format json k8s/*.yaml`
- **kubescape:** `kubescape scan framework nsa --format json --output /tmp/ks.json .`

### `hadolint` — Dockerfile linter
- **Install check:** `command -v hadolint`
- **Run:** `hadolint --format json Dockerfile`

### `actionlint` — GitHub Actions linter
- **Install check:** `command -v actionlint`
- **Run:** `actionlint -format '{{json .}}'`

### Manual checks
- Secret env vars: are they sourced from a secret manager or hardcoded?
- Image pinning: `FROM node:latest` vs `FROM node:20.11.1-alpine@sha256:...`
- Privileged containers, `runAsRoot`, missing `securityContext`.
- Open ingress (`0.0.0.0/0` on port 22, RDS publicly accessible).
- IAM policies with `Action: "*"` or `Resource: "*"`.

---

## `databases`

### `sqlfluff` — SQL linter (catches some safety issues)
- **Install check:** `command -v sqlfluff`
- **Run:** `sqlfluff lint --format json migrations/`

### ORM-aware SAST via semgrep
- Use semgrep's `p/sql-injection` ruleset.
- Plus language-specific: `p/django`, `p/rails`, `p/sequelize`, `p/typeorm`.

### Manual checks (most of databases is manual)
- Migration safety: `DROP COLUMN` without backup? `ALTER TABLE` on a hot path?
- Encryption-at-rest columns: PII, tokens, secrets — are they encrypted?
- Connection strings: hardcoded? committed?
- DB user privileges: app user has `SUPERUSER` / `ALL PRIVILEGES`?
- Row-level security in multi-tenant schemas.
- Backup & retention: is anyone testing restores?
- N+1 query patterns that enable DoS.
- Indexes on auth-related columns (sessions, tokens) to prevent timing attacks.

---

## `android`

### `mobsf` — Mobile Security Framework (static + dynamic)
- **Install check:** `command -v mobsf` or `docker images | grep -i mobsf`
- **Static analysis CLI:** the CLI is `mobsfscan` for source code
- **`mobsfscan`:** `pip install mobsfscan && mobsfscan --json .`
- **Parse:** JSON; results per file with severity.

### `apkleaks` — APK secret / endpoint scanner (if APK build available)
- **Install check:** `command -v apkleaks`
- **Run:** `apkleaks -f app.apk -o /tmp/apkleaks.json --json`

### `qark` — Android source quick-audit
- **Install check:** `command -v qark`
- **Run:** `qark --source 1 --report-type json --report-path /tmp/qark.json`

### Manual checks (MASVS-driven, see `android.md`)
- AndroidManifest: `android:exported`, intent filters, deep links, permissions.
- Backup/restore: `android:allowBackup="true"` leaks data.
- Network security config: cleartext traffic, certificate pinning, custom trust anchors.
- Storage: `MODE_WORLD_*`, external storage for sensitive data.
- Logs: `Log.d(TAG, sensitiveValue)`.
- Crypto: `DES`, `MD5`, ECB mode, hardcoded keys.

---

## `ios`

### `mobsfscan` (also handles iOS source)
- **Run:** `mobsfscan --json .` from project root.

### Manual checks (MASVS iOS-driven, see `ios.md`)
- Info.plist: `NSAppTransportSecurity` exceptions, URL schemes, background modes.
- Entitlements: keychain access groups, app groups, ATS bypass.
- Keychain: missing `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- WebView: `WKWebView` with `javaScriptEnabled`, `allowsArbitraryLoads`.
- Logs: `print()` / `NSLog()` of sensitive data.
- Crypto: `CommonCrypto` with weak ciphers, hardcoded IV/key.
- Jailbreak detection (defense-in-depth).
- Pasteboard: do not write secrets to `UIPasteboard.general`.

---

## Tool gap fallbacks

If many tools are missing for the active profiles, the SKILL's **Phase 3.5** offers the user a chance to install before the audit runs (see SKILL.md). Don't silently degrade — surface the gap and let them choose.

If they opt out (or the run is non-interactive), proceed checklist-only and emit a top-level `info` finding: "Tool coverage degraded — only `<tool list>` ran. Install missing tools (`<list>`) and re-run for full coverage."

### Reasonable minimal install set (macOS)

Covers ~70% of cases. Useful as the recommendation Phase 3.5 prints to the user:

```bash
brew install gitleaks semgrep trivy hadolint actionlint osv-scanner
pip install pip-audit bandit mobsfscan
go install golang.org/x/vuln/cmd/govulncheck@latest
go install github.com/securego/gosec/v2/cmd/gosec@latest
```

### Per-installer groupings (for the Phase 3.5 prompt)

Group missing tools by their installer so one command installs many. Only suggest tools that map to **active profiles** — don't ask the user to install `mobsfscan` for a Terraform-only repo.

| Installer | Tools |
|-----------|-------|
| `brew` (macOS) / `apt` (Debian) / `yum` (RHEL) | gitleaks, semgrep, trivy, hadolint, actionlint, osv-scanner, checkov, tfsec |
| `pip install` | pip-audit, bandit, safety, mobsfscan, checkov |
| `go install` | govulncheck (`golang.org/x/vuln/cmd/govulncheck@latest`), gosec (`github.com/securego/gosec/v2/cmd/gosec@latest`), osv-scanner (`github.com/google/osv-scanner/cmd/osv-scanner@v1`) |
| `npm install -g` | retire (`retire`), eslint + plugin-security |
| `gem install` | bundler-audit, brakeman |
| `cargo install` | cargo-audit |
| Docker | mobsf (`opensecurity/mobile-security-framework-mobsf`) |
