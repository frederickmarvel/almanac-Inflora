# cso-thinking

> Single-command security audit that adapts to whatever you point it at — frontend, backend, infrastructure, databases, Android, iOS, or generic software. Produces a security score plus a fix-ready audit list.

## Philosophy

A Chief Security Officer doesn't run seven different audits for seven different stacks — they ask one question ("where are we exposed?") and route it to whichever lens fits the target. This plugin embodies that mindset: one entry point, profile-aware execution, evidence-grounded findings, and a fix-ready audit list a human or another Claude session can act on immediately.

1. **One command, every target.** Auto-detect the profile from the working directory; confirm; run.
2. **Evidence over opinion.** Every finding cites a file, line, and standard. Run external tools where available; fall back to checklist review where not.
3. **Score is a signal, not a verdict.** 0–100 + letter grade for trend tracking. The audit list is what matters.
4. **Fix-ready output.** Each finding ships with a copy-pasteable remediation prompt.

See [ETHOS.md](./ETHOS.md) for the full philosophy.

## The skill

| Skill | Specialist role | When |
|-------|-----------------|------|
| [`/cso-audit`](./skills/cso-audit/SKILL.md) | Chief Security Officer | Pre-release, periodic review, post-incident, before audit committee |

## What it covers

| Profile | Standards drawn from | Auto-detect signals |
|---------|----------------------|---------------------|
| `frontend` | OWASP Top 10 (Web), CSP L3, Webhint, MDN security headers | `package.json` + `index.html` / Next.js / Vite / React / Vue / Svelte |
| `backend` | OWASP API Top 10, ASVS L1/L2, language-specific guides | Go / Node / Python / Java / Ruby / PHP / Rust / .NET service code |
| `infrastructure` | CIS Docker / Kubernetes / Cloud benchmarks, NIST 800-190 | `Dockerfile`, `*.tf`, `k8s/`, `helm/`, `docker-compose.yml`, `ansible/` |
| `databases` | OWASP Database Security Cheat Sheet, CIS DB benchmarks | Migration files, `schema.sql`, ORM config, DB connection strings |
| `android` | OWASP MASVS L1/L2, MASTG | `AndroidManifest.xml`, `build.gradle`, Kotlin/Java sources |
| `ios` | OWASP MASVS L1/L2 (iOS profile), Apple Platform Security | `Info.plist`, `*.xcodeproj`, Swift/Obj-C sources |
| `generic` | OWASP SAMM, NIST SSDF, supply-chain (SLSA), secrets hygiene | Catch-all + always applied alongside others |

Multiple profiles can be active in one run (e.g., a monorepo with frontend + backend + infra gets all three).

## Output

Every run writes two files to the working directory:

- **`SECURITY_AUDIT.md`** — agent handoff (stable structure, parseable)
- **`SECURITY_AUDIT.html`** — human review (score banner, severity grouping, copyable remediation blocks)

Each finding has: severity, location (`file:line` or config key), source (tool name+version or checklist item ID), why-it-matters, and a copy-pasteable **remediation prompt**.

## Composite score

Score = 100 − Σ(severity_weight × finding_count), floored at 0. See [scoring.md](./skills/cso-audit/references/scoring.md) for weights, letter-grade bands, and how scope size scales the penalty.

## Sprint flow

```
target codebase                  ← any of: web / api / infra / db / mobile / generic
   ↓
/cso-audit                       ← profile detect → confirm → run → score → emit
   ↓
SECURITY_AUDIT.md + .html
   ↓
   ├─→ Critical/High findings  →  fix immediately, re-run /cso-audit
   ├─→ Medium findings         →  ticket, batch
   └─→ Low/Info                →  parking lot, address in next audit cycle
```

## Related plugins

- [`em-thinking`](../em-thinking/) — engineering plan/review (security findings often become tickets here)
- [`board-thinking`](../board-thinking/) — when "should we even ship this?" is the real question
- [`public-awareness`](../public-awareness/) — keeps audit findings out of public artifacts

## Versioning

- **v0.2.0** — added **Phase 4.5: threat-intelligence enrichment** using only free public APIs (OSV.dev, EPSS, CISA KEV from the cisagov GitHub mirror, NVD, GitHub Advisory via existing `gh` auth, Hacker News Algolia). Each Critical/High finding with a CVE/GHSA identifier gets a `Recent activity` block showing EPSS percentile, KEV listing + federal patch deadline, ransomware-campaign use, NVD CVSS verification, curated OSV references, and recent HN discussions. Severity can be auto-promoted (never demoted) when intel justifies it — e.g., KEV listing → at least High; KEV + ransomware → Critical; EPSS ≥0.95 → at least High. Bundles `scripts/fetch_intel.sh` so the LLM doesn't re-derive the curl chains. Per-CVE cache (6h), KEV catalog cache (24h). Opt-in via `--threat-intel`, auto-on when internet is reachable, fully graceful when any/all APIs are down. Zero paid dependencies, ever. Skill instructions remain under 500 lines.
- **v0.1.1** — added **Phase 3.5** (offer to install missing scanners interactively before the audit runs). Coverage gaps now get a one-click `brew install ...` / `pip install ...` / `go install ...` recommendation instead of silently degrading to checklist-only. Picking "install now" runs the commands straight through — no double-prompt — and Claude Code's harness handles the actual approval (auto-approve mode just runs; default mode shows the standard Bash permission prompt). Constraints on the commands themselves (no surprise `sudo`, no shell-rc edits, prefer project-local environments) are enforced regardless of mode. Non-interactive mode (subagent / CI / `--no-prompt`) skips Phase 3.5 entirely and proceeds checklist-only with the degraded-coverage info finding intact.
- v0.1.0 — initial release: `/cso-audit` with 7 profiles, hybrid tool+checklist execution, dual md+html output, fix-ready findings.
