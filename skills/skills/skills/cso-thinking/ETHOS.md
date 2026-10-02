# cso-thinking — ETHOS

> A security audit is worth what its **fixes** are worth. A pretty report nobody acts on is theatre.

## 1. One command, every target

A real CSO doesn't say "use a different process for the iOS app." They say "show me the risks, ranked." This plugin exposes a single command — `/cso-audit` — that adapts to whatever the working directory contains: web frontend, backend in any language, infrastructure-as-code, databases, Android, iOS, or a generic software project.

The skill's first job is **profile detection**: read the directory and propose which checklists apply. The user confirms, then the audit runs. One entry point, many internal paths.

✅ Good: detect `package.json` + `Dockerfile` + `terraform/`, propose `frontend + backend + infrastructure`, ask user to confirm or trim.
❌ Bad: force the user to pick `/cso-audit-frontend` vs `/cso-audit-mobile` from the start — that's not a CSO mindset, that's a tool catalog.

## 2. Evidence over opinion

Every finding cites a file path with a line number (or the configuration key, or the package version) plus the standard it violates. "Looks insecure" is not a finding. "`server.js:42` accepts `eval(req.body.expr)` — OWASP A03:2021 Injection" is a finding.

Where external tools exist and are installed (semgrep, trivy, gitleaks, npm audit, bundler-audit, govulncheck, mobsf, etc.), the skill runs them and merges their output. Where tools are missing, the skill falls back to checklist-driven LLM review against the relevant reference file. Both paths produce evidence; neither produces vibes.

The audit report tags each finding with its **source** — tool name + version, or checklist name + item ID — so the reader knows whether to trust it like a static-analysis hit or weigh it like a human review note.

## 3. Score is a signal, not a verdict

The composite score (0–100) and letter grade (A/B/C/D/F) exist so the reader can answer "is this getting worse or better?" across audits. They are **not** a pass/fail gate. A B+ with one Critical finding is worse than a C with no Criticals.

The score formula is published in [`scoring.md`](./skills/cso-audit/references/scoring.md) so reviewers can see exactly why a finding moved the number. Never hand-wave the grade.

✅ Good: "Score 72/B−. One Critical (hardcoded AWS key in `.env.example`) drags this from a high-B; fix that and the next audit should clear 85."
❌ Bad: "Looks pretty good, probably a B."

## 4. Every finding is fix-ready

The user explicitly asked for this: each finding ships with a **remediation prompt** — a copy-pasteable instruction another Claude session (or the same one) can execute to fix the issue. That prompt names the file, the change, the standard, and the verification step.

This makes the audit → fix loop trivial: open the report, scan severities, copy the remediation block, paste it into a new session (or use a `/fix` skill), verify. The skill is judged on whether that loop actually works, not on how many findings it produced.

✅ Good: remediation prompt = "Replace `crypto.createCipher('aes-256-cbc', key)` at `src/crypto.ts:18` with `crypto.createCipheriv(...)` and a per-message random IV; add `iv` to the ciphertext envelope. Verify by running `npm test -- crypto.test.ts`."
❌ Bad: remediation = "Use a more secure encryption method." (no file, no API, no verification — useless to hand to anyone)

## 5. Dual output — agent handoff and human review

Every run produces two artifacts:

- **`SECURITY_AUDIT.md`** — agent handoff. Stable structure, deterministic ordering, parseable headings. Other Claude sessions consume this to act on findings.
- **`SECURITY_AUDIT.html`** — human review. Same data, presented with score banner, severity grouping, expandable remediation blocks, copy-to-clipboard buttons, and printable styling for sharing.

Same source data, two audiences. Don't try to make the markdown pretty for humans — that's the HTML's job. Don't try to make the HTML parseable — that's the markdown's job.

## 6. Lean SKILL.md, fat references

The `SKILL.md` is the orchestrator: detect, confirm, run, score, emit. It should not contain the OWASP Top 10, the CIS benchmarks, or the MASVS checklist — those live in `references/<profile>.md` and are only read when the profile is active.

A `SKILL.md` that grows past ~400 lines is a smell — push detail into a reference file and link.

## 7. Adversarial mindset, not compliance mindset

The skill is graded on whether it would catch a real attacker, not whether it ticks every box in a framework. A perfectly compliant SOC 2 environment can still have an exposed S3 bucket. Always ask "what's the most damaging thing reachable from this code?" — then check whether the controls actually stop it.

This is why the checklists are organized by **threat outcome** (RCE, data exfil, auth bypass, supply-chain compromise) before being mapped to standard IDs. Standards are how we communicate; threats are what we defend against.

## 8. Honest about what we didn't check

The audit ends with a `## Scope & limitations` section that lists what the skill **could not** assess — runtime behavior on production traffic, business-logic flaws that need domain context, social-engineering risk, physical security. A report that pretends to be exhaustive is dangerous; a report that names its blind spots is useful.
