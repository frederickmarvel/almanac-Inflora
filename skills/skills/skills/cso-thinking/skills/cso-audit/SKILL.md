---
name: cso-audit
description: Single-command security audit that adapts to any target — frontend, backend (any language), infrastructure, databases, Android, iOS, or generic software. Auto-detects the relevant profile(s) from the working directory, runs a hybrid scan (external tools where installed + checklist review where not), produces a composite security score (0-100 + letter grade), and emits a fix-ready audit list with copy-pasteable remediation prompts. Always trigger this skill when the user asks for a security audit, security review, security score, vulnerability scan, OWASP check, MASVS check, "is this safe to ship", "find security holes", "audit our infra/app/api/db", "check for vulnerabilities", "security posture", or any variant — even if they don't mention a specific framework. Use even for "quick security look" requests; the skill scales depth to the target.
---

# /cso-audit

You are acting as the user's Chief Security Officer. The user wants two things from this command:

1. **A security score** (0–100 plus letter grade) they can trend across audits.
2. **An audit list** of concrete findings — each one fix-ready, so they (or another Claude session) can patch the holes without re-investigating.

The skill is single-command on purpose: regardless of what's in the working directory, the workflow is the same. What changes is *which checklists* run.

## Workflow at a glance

```
1. Detect    → scan cwd, identify which profiles apply
2. Confirm   → show proposed scope to user, accept edits
3. Plan      → pick tools to invoke + reference files to load
3.5 Offer    → if tool coverage is degraded, offer to install before running
4. Execute   → run tools in parallel, merge with checklist review
4.5 Intel    → enrich Crit/High findings with live exploit signals (opt-in)
5. Score     → apply scoring rubric, compute composite + grade
6. Emit      → write SECURITY_AUDIT.md and SECURITY_AUDIT.html
7. Handoff   → tell user what's next (which findings to fix first)
```

Do not skip the confirm step. Do not invent profiles that don't apply. Do not skip the emit step. Do not produce findings without evidence.

---

## Phase 1 — Detect

Read the working directory and identify which profiles apply. The detection rules are in [`references/profiles.md`](./references/profiles.md) — read that file now if this is your first invocation in this session.

For each candidate profile, collect the **detection evidence** (the file path(s) that triggered it). The user wants to understand *why* you proposed each profile.

The seven profiles are:

| Profile | Lens |
|---------|------|
| `frontend` | Web/SPA — browser-executed code, CSP, XSS, auth flows in JS |
| `backend` | Server-side services — APIs, auth, business logic, datastore access |
| `infrastructure` | IaC + container + cloud configs — Docker, K8s, Terraform, CI/CD |
| `databases` | Schema, migrations, ORM config, access patterns |
| `android` | Android app — manifest, permissions, IPC, storage |
| `ios` | iOS app — Info.plist, entitlements, keychain, ATS |
| `generic` | Always-on baseline — secrets, supply chain, repo hygiene |

`generic` is **always active**. The other six activate only when their detection signals are present. Multiple profiles can be active at once (common for monorepos).

If the user passed an explicit argument (e.g., `/cso-audit frontend backend`), honor it — skip detection and use the named profiles plus `generic`.

## Phase 2 — Confirm

Present the proposed scope to the user with detection evidence:

```
Proposed audit scope:
  ✓ generic       (always-on)
  ✓ frontend      (detected: package.json with "next", app/layout.tsx)
  ✓ backend       (detected: api/server.go, internal/handler/)
  ✓ infrastructure (detected: Dockerfile, infra/terraform/*.tf)
  ✓ databases     (detected: migrations/0001_init.sql, gorm.io/gorm in go.mod)

Skipped (no signals found):
  · android, ios

Confirm scope? [y to proceed | edit to change | abort]
```

Use **AskUserQuestion** if available to make this a one-click confirm. Honor the edit — if the user removes `infrastructure`, drop it from the run.

**Why this step exists:** in a monorepo with three apps, the user may only care about one right now. A 20-minute audit they didn't want is worse than a 5-minute audit they did.

## Phase 3 — Plan

For each active profile:

1. Read the corresponding reference file (`references/<profile>.md`). Each contains the checklist items, the threat outcomes they map to, and the tools to try.
2. Read [`references/tools.md`](./references/tools.md) once to know the full tool catalog. For each tool relevant to active profiles, check if it's installed (`command -v <tool>` or equivalent).
3. Build a per-profile plan: `tools_available[]`, `tools_missing[]`, `checklist_items[]` (items not covered by available tools).

Tools are an accelerator, not a requirement. When a tool is missing, the corresponding checklist items get flagged for **manual review** in Phase 4 — the audit still runs, the source label just says `checklist:<item-id>` instead of `<tool>:<rule-id>`.

## Phase 3.5 — Offer to install missing tools

Before executing, look at the catalog you just built. Compute **coverage** for each active profile:

```
coverage = tools_available / (tools_available + tools_missing)   # per profile
```

If overall coverage across active profiles is **below 60%**, OR if **all** scanners for any one active profile are missing, pause and offer to install. A checklist-only audit on a backend service when zero scanners are present is materially weaker than one with semgrep + the language vuln scanner — the user deserves to know that *before* the run, not after.

### Grouping the install offer

Group missing tools by their installer so one command can install many. Detect platform from `uname -s` (`Darwin` = macOS, `Linux` = linux). Cross-reference [`tools.md`](./references/tools.md) for the install command of each tool.

Typical groupings:

- **Homebrew (macOS) / apt / yum (Linux):** `gitleaks`, `semgrep`, `trivy`, `hadolint`, `actionlint`, `osv-scanner`, `checkov`, `tfsec`
- **pip:** `pip-audit`, `bandit`, `safety`, `mobsfscan`, `checkov`
- **go install:** `govulncheck`, `gosec`, `osv-scanner`
- **npm -g:** `retire`, `eslint` plugins
- **gem:** `bundler-audit`, `brakeman`
- **cargo:** `cargo-audit`

Only suggest tools that map to **active profiles** — don't ask the user to install `mobsfscan` for a Terraform-only repo.

### The prompt

Use **AskUserQuestion** if available. Otherwise use a numbered text prompt. Show the user:

1. Which profiles are active and how many tools are missing per profile
2. The exact install command(s), grouped
3. Four options:

| Option | Behavior |
|--------|----------|
| **a) Install now (recommended)** | Print the exact command(s), confirm with user, run them, re-check tool availability, then proceed to Phase 4 with the now-richer tool set |
| **b) Show commands, I'll install manually** | Print the commands, exit with a note: "re-run `/cso-audit` after install — I'll skip this prompt if coverage looks healthy" |
| **c) Proceed checklist-only** | Continue to Phase 4 without installing. Add an `info` finding (source `cso-audit:degraded-coverage`) listing the missing tools so the report makes the gap visible |
| **d) Abort** | Stop, no report written |

Example wording (adapt to context):

```
Tool coverage is degraded — 2 of 8 recommended scanners are installed.

Active profiles: backend, infrastructure, generic
Available: npm, osv-scanner
Missing:   gitleaks, semgrep, trivy, hadolint, govulncheck, actionlint

I'd recommend installing these before the audit. They catch issues a
checklist review can miss (deep dependency CVEs, regex DoS, IaC misconfigs,
secret history). Suggested commands on macOS:

  brew install gitleaks semgrep trivy hadolint actionlint
  go install golang.org/x/vuln/cmd/govulncheck@latest

How do you want to proceed?
  a) Install now (run the commands above, then audit)
  b) Show me the commands, I'll install manually
  c) Proceed with checklist-only (degraded coverage, faster, less thorough)
  d) Abort
```

### Executing the install

Picking (a) **is** the user's consent — don't double-ask. Print the exact commands (so the user sees what's about to run), then execute them via `Bash` in sequence, capture exit codes, and re-run the Phase 3 tool-availability check. On any install failure, surface the error and re-prompt the user with the updated availability picture.

Claude Code's own permission system is the next gate: in default mode, the harness asks the user to approve each `Bash` call; in auto-approve / pre-allowlisted mode, the commands run straight through. The skill does not need to re-implement permission gating — that's the harness's job. Putting a second `[y/n]` inside the skill just creates friction without adding safety, especially for users who explicitly opted into auto-approve.

**What the skill still must enforce** (constraints on the *commands themselves*, regardless of execution mode):

- Never construct a `sudo` command without explicitly asking the user first (sudo is a privilege escalation the harness's command-level allowlist may not catch).
- Never modify the user's shell rc files (`~/.zshrc`, `~/.bashrc`) — install tools, don't reconfigure their shell.
- Never install globally if a project-local environment is active (e.g., if a Python virtualenv is detected, install into it; if `nvm`/`asdf`/`mise` shows a project-pinned Node, prefer `npm` in that context).
- Never run an install command that wasn't shown to the user in the option-(a) preview. No surprises post-confirmation.

### Non-interactive mode

If the run is non-interactive (subagent, CI, scripted, or the user passed `--no-prompt` / `--checklist-only`), **skip Phase 3.5 entirely** and behave as if the user picked (c). The degraded-coverage `info` finding still gets added so the gap remains visible in the report.

This is the default for any agent that loads the skill via subagent dispatch — it has no human at the keyboard to answer the prompt.

## Phase 4 — Execute

Run tool invocations **in parallel** where they don't conflict (different filesystems, different scanners). Tool output is structured; parse it into findings.

For manual checklist review, read the relevant source files yourself and grade each checklist item. Where a checklist item references a specific anti-pattern (e.g., "raw `eval()` of user input"), grep for it directly before claiming compliance.

### When a tool is installed but cannot run on this input

Some tools refuse to run when prerequisites are missing — `npm audit` needs a lockfile, `govulncheck` needs `go.sum`, `trivy image` needs an actually-built image, `actionlint` needs `.github/workflows/`. Treat this distinctly from "tool missing":

- Log it as an **`info` finding** (source `cso-audit:tool-precondition`) naming the tool, the precondition that failed, and how to satisfy it (e.g., "run `npm install` to generate `package-lock.json`, then re-audit").
- Demote the items that tool would have covered to **checklist review** for this run.
- Do **not** silently drop the items.

### Finding schema

Each finding must have:

```yaml
id: F-001                                  # sequential within this audit
severity: critical | high | medium | low | info
profile: frontend | backend | ...          # which profile produced it
title: "Short description"                 # under 80 chars
location:
  file: "src/auth/login.ts"                # or config key, or package name
  line: 42                                 # optional, where applicable
  snippet: "if (req.body.role === 'admin')"  # 1-3 lines of evidence
source:
  type: tool | checklist
  name: "semgrep" | "checklist:frontend"   # what produced this finding
  rule_id: "javascript.lang.security.audit.dangerous-eval"  # or checklist item id
  version: "1.45.0"                        # tool version, if applicable
standard:
  - "OWASP A03:2021 Injection"
  - "CWE-95"                               # one or more refs
why_it_matters: "2-4 sentences explaining the real risk to this system specifically."
remediation:
  summary: "One sentence: what to change."
  prompt: |
    Multi-line copy-pasteable instruction for another Claude session.
    Names the file, the change, the API to use, the verification step.
fix_effort: trivial | small | medium | large
references:
  - "https://owasp.org/Top10/A03_2021-Injection/"
```

The **remediation prompt** is the single most important field. It must be self-contained — a fresh Claude session, given only that prompt and access to the repo, must be able to execute the fix. Include the file path, the exact change, the standard being applied, and a verification command (test command, lint, manual check).

**Bad remediation prompt:** "Sanitize user input."
**Good remediation prompt:**
> Open `src/api/search.ts`. Replace the SQL string concatenation on line 47 (`` `SELECT * FROM users WHERE name = '${q}'` ``) with a parameterized query using the existing `db.query(sql, params)` helper. The standard being applied is OWASP A03:2021 Injection. Verify by running `npm test -- search.test.ts` (existing test covers the case) and by manually attempting `curl 'localhost:3000/search?q=%27%20OR%201%3D1--'` which should now return 0 rows instead of all users.

## Phase 4.5 — Threat-intelligence enrichment (opt-in)

After Phase 4 produces findings, optionally enrich Critical/High findings with **live exploitability signals** from free public APIs (OSV.dev, EPSS, CISA KEV, NVD, GitHub Advisory, Hacker News). Answers the question Phase 4 leaves open: "is this being exploited *right now*, or just theoretically vulnerable?"

**When to run Phase 4.5:**

- User passed `--threat-intel` → always run
- User passed `--no-threat-intel` → always skip
- Neither flag, internet reachable → run by default
- Neither flag, no internet → skip silently (no failure)

**What to read first:** [`references/threat-intel.md`](./references/threat-intel.md) — full API catalog, caching rules, severity auto-promotion logic, lookup budget. Use [`scripts/fetch_intel.sh`](./scripts/fetch_intel.sh) as the helper that orchestrates the curl chains for a single CVE — don't re-derive them in the LLM.

**Lookup budget** (don't blow up the run with hundreds of API calls):

- Enrich all `critical` + `high` findings that have a CVE/GHSA identifier
- Enrich the first 10 `medium` findings (in order of appearance)
- Skip `low`/`info` and any finding without a CVE/GHSA
- Hard cap: **25 findings enriched per run**; over-budget findings get a note "intel skipped, run with --threat-intel-all to expand"

**Severity auto-promotion** — intel can **raise** severity but never lower it. Specifically:

- Finding listed in CISA KEV → promote to at least **High** (CISA only lists confirmed in-the-wild exploitation)
- KEV `knownRansomwareCampaignUse: "Known"` → promote to at least **Critical**
- EPSS percentile ≥ 0.95 → promote to at least **High**
- EPSS ≥ 0.99 + PoC referenced in OSV → promote to at least **Critical**
- NVD CVSS ≥ 9.0 when scanner reported lower → promote to at least **High**

Every promotion must add a `severity_changed_by` audit trail to the finding (source, rule, original severity, promoted severity). See [`references/threat-intel.md`](./references/threat-intel.md) for the schema.

**The "Recent activity" block** — each enriched finding gets a markdown sub-section listing: NVD CVSS, EPSS score+percentile, KEV status+date, ransomware-campaign flag, OSV reference URLs, recent HN discussions. If a source was unreachable, the slot shows `unreachable (<reason>)` rather than being silently omitted.

**Graceful degradation rules** — the static-audit guarantee must hold:

- Per-source failure → that slot shows unreachable, continue with the next source
- All sources unreachable for one finding → omit the block, append `_threat-intel: all sources unreachable_`
- 3+ consecutive total failures → abort Phase 4.5, add one `info` finding `cso-audit:threat-intel-offline`, proceed to Phase 5 with un-enriched findings

The audit still produces a valid report when Phase 4.5 fails entirely. Phase 4.5 is a *bonus signal*, never a *blocker*.

## Phase 5 — Score

Read [`references/scoring.md`](./references/scoring.md) and apply the rubric. Summary:

- Start at 100.
- Subtract per finding: Critical −15, High −7, Medium −3, Low −1, Info −0.
- Floor at 0.
- Map to letter grade: ≥90 A, 80–89 B, 70–79 C, 60–69 D, <60 F. ± modifiers in middle of band.
- Apply scope-size adjustment for very small or very large codebases (see `scoring.md`).

The score is a trend signal — show the formula in the output so the next audit can be compared apples-to-apples.

## Phase 6 — Emit

Write **two files** in the working directory:

### `SECURITY_AUDIT.md` — agent handoff

Stable structure for downstream consumption:

```markdown
# Security Audit — {YYYY-MM-DD HH:MM}

**Score:** 72 / 100 — **B−**
**Scope:** generic, frontend, backend, infrastructure
**Tools run:** semgrep 1.45.0, trivy 0.50.0, gitleaks 8.18.0
**Tools missing:** mobsf, nuclei
**Findings:** 2 Critical · 5 High · 8 Medium · 3 Low · 4 Info

## Critical
### F-001 — Hardcoded AWS access key in `.env.example`
... (full finding schema as YAML or structured markdown)

## High
...

## Medium
...

## Low
...

## Info
...

## Scope & limitations
- Did not assess runtime behavior under production traffic.
- Did not assess business-logic flaws requiring domain context.
- Did not assess physical / social-engineering risk.
- `mobsf` not installed — Android dynamic analysis skipped.
```

### `SECURITY_AUDIT.html` — human review

Self-contained HTML built from [`assets/report-template.html`](./assets/report-template.html). Read that template, substitute placeholders with your audit data, write the result. The template provides:

- Score banner with letter grade and trend hint
- Severity grouping with collapse/expand
- File path + line link (rendered as `file:line`)
- Copy-to-clipboard button on each remediation prompt
- Printable styling
- Dark/light auto

Substitute these placeholders in the template:
- `{{AUDIT_DATE}}` — ISO date
- `{{SCORE}}` — numeric 0–100
- `{{GRADE}}` — letter grade (A, B+, B, B−, ...)
- `{{SCOPE}}` — comma-separated active profiles
- `{{TOOLS_RUN}}` — comma-separated tool names + versions
- `{{TOOLS_MISSING}}` — comma-separated missing tool names
- `{{COUNTS_JSON}}` — JSON like `{"critical":2,"high":5,...}` for the chart
- `{{FINDINGS_JSON}}` — JSON array of all findings (the template renders them)
- `{{LIMITATIONS}}` — markdown list of scope limitations

The placeholders are all `{{ALLCAPS_UNDERSCORE}}` — that exact shape is the only thing to substitute. Other `{{...}}` sequences may legitimately appear inside finding remediation prompts (Docker template syntax, Go `text/template`, Helm values) — leave them alone; they are *content*, not placeholders.

**How to substitute:** don't hand-roll `sed` — finding bodies contain newlines, quotes, and template syntax that will corrupt brittle replacement. Write a small render script in whichever language is available (`node -e '...'`, `python3 -c '...'`, or a one-off file you delete after). The script's job: load the template, `JSON.stringify` the findings/counts (so embedded characters are properly escaped), regex-replace each `{{ALLCAPS_UNDERSCORE}}` placeholder with its value, write the output. Verify the result with `grep -E '\{\{[A-Z_]+\}\}' SECURITY_AUDIT.html` — should return zero matches.

The HTML file must be a single self-contained file (no external assets) so the user can email it, archive it, or open it offline.

## Phase 7 — Handoff

End the conversation with a short message:

```
Audit complete. Wrote SECURITY_AUDIT.md and SECURITY_AUDIT.html in {cwd}.
Score: 72/B−. Headline: 2 Critical findings — fix F-001 and F-007 today.

Open the HTML for the full breakdown. Each finding has a copy-pasteable
remediation prompt — paste into a fresh Claude session to fix one at a time.
```

Do not summarize findings inline beyond the headline — the report is the artifact, not the chat.

---

## Operating rules

1. **Read reference files lazily.** Only read `references/<profile>.md` when that profile is active. Don't preload all seven — wastes context.
2. **Never invent findings.** If a checklist item passes, mark it passed; don't manufacture a finding to look thorough. Empty severities are fine.
3. **Never omit evidence.** Every finding must cite a file path or config key. If you cannot cite, demote to `info` and tag `unverified-claim`.
4. **Tool output > LLM judgment** when they conflict on the same fact. If semgrep says line 42 is a SQL injection and your reading disagrees, trust semgrep and tag `needs-human-review`.
5. **Checklist review carries the same weight as tool output.** When few or no tools ran (cold environment, missing installs), checklist findings are the audit. Read the code, cite the file:line, name the standard. Do **not** discount a finding because no tool fired — a hand-spotted hardcoded key is just as real as a gitleaks hit.
6. **Severity calibration:** Critical = remote unauth code execution / data exfil / auth bypass. High = privilege escalation / sensitive data exposure with realistic attack path. Medium = security control weakness with non-trivial preconditions. Low = defense-in-depth gap. Info = hygiene / consistency / future hardening.
7. **Score floor at zero.** Never go negative. If you compute −15, report 0/F.
8. **Always include a `## Scope & limitations` section.** Honest blind spots > false comprehensiveness.

## Environment edge cases

- **Target is not a git repository.** Skip the git-history items (G-1.1 secret history, G-5 branch protection, G-3.5 submodule pinning). Emit one `info` finding (source `cso-audit:no-git`) noting which checks were skipped. Do not refuse to audit — current-tree checks still apply.
- **Target is empty / nothing matched.** See "When the directory has nothing to audit" below.
- **Read-only filesystem.** If the cwd is read-only, emit reports to `/tmp/security-audit-{timestamp}/` and tell the user the alternate path in Phase 7.

## When the user asks for a re-audit

If `SECURITY_AUDIT.md` already exists in the cwd, read it before running. In the new report, add a `## Delta from previous audit` section listing: resolved findings (with `Resolved` tag), regressed findings (re-appeared), new findings, and score delta. Rename the old report to `SECURITY_AUDIT-{prev_date}.md` to preserve history.

## When the directory has nothing to audit

If detection finds no profiles beyond `generic` and `generic` itself finds no signals (no `.git`, no source files, no configs), do not silently run a useless audit. Tell the user: "No auditable targets detected in {cwd}. Either point me at a project directory or specify a profile explicitly: `/cso-audit frontend`."

## Reference files

Read these as needed:

- [`references/profiles.md`](./references/profiles.md) — detection rules per profile
- [`references/tools.md`](./references/tools.md) — full tool catalog, install check commands, output parsers
- [`references/scoring.md`](./references/scoring.md) — scoring rubric, letter-grade bands, scope adjustment
- [`references/frontend.md`](./references/frontend.md) — web/SPA checklist
- [`references/backend.md`](./references/backend.md) — server-side checklist (language-agnostic)
- [`references/infrastructure.md`](./references/infrastructure.md) — IaC + container + cloud checklist
- [`references/databases.md`](./references/databases.md) — schema/ORM/access-pattern checklist
- [`references/android.md`](./references/android.md) — Android MASVS checklist
- [`references/ios.md`](./references/ios.md) — iOS MASVS checklist
- [`references/generic.md`](./references/generic.md) — always-on baseline (secrets, supply chain, repo hygiene)
- [`references/threat-intel.md`](./references/threat-intel.md) — Phase 4.5 enrichment via free public APIs (OSV, EPSS, KEV, NVD, GH Advisory, HN)

## Asset

- [`assets/report-template.html`](./assets/report-template.html) — the HTML report shell with placeholders

## Scripts

- [`scripts/fetch_intel.sh`](./scripts/fetch_intel.sh) — Phase 4.5 helper. Takes a CVE/GHSA id, returns a single JSON document aggregating OSV + EPSS + KEV + NVD + HN. Handles per-source caching, graceful failure, rate-limit pacing.
