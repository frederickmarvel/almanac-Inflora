---
name: em-works
description: Translate edd.md into execution-ready handoff package — atomic ticket breakdown, worktree parallelization lanes, environment & secrets specification, and deployment strategy artifact. Use after /em-plan produces a plan and before engineers start coding, when a plan needs ticket-level decomposition for sprint planning, when prepping multi-engineer parallel work, or when documenting deploy strategy for future devops execution. Prepares artifact only — does not execute deployment (handoff to release/deploy role, skill matched per env).
---

# /em-works

Translate `edd.md` → execution-ready handoff package. Output `eng-works.md` ready to distribute to the `engineer` role for implementation, plus a deployment plan artifact ready to be picked up by the `release-engineer` / `devops` role.

> **Reference resolution.** All `../../references/*.md` and `../../ETHOS.md` paths resolve inside the `em-thinking` bundle. If a referenced file does not exist (standalone/flattened install), **say so explicitly** and continue using only the rules inlined in this SKILL.md — never improvise the missing file's content. If `../../references/html-template.md` is missing, deliver `eng-works.md` only, state that `eng-works.html` was skipped because the template is unavailable, and recommend reinstalling the full `em-thinking` bundle.

Important scope: **em-works prepares artifact, doesn't execute deployment.** Provisioning secrets, creating feature flags, applying migrations, running rollout — that's devops territory.

## ⚠ Question Format Rule

See [../../ETHOS.md](../../ETHOS.md) principle #8. Numbered questions, AskUserQuestion if available.

## When to trigger this skill

- Automatically after `/em-plan` finishes (seamless handoff)
- "The plan is locked, want to break it down to ticket level"
- "Have a plan, want to prep for sprint planning"
- "Want to distribute work across 3 engineers in parallel — need a lane plan"
- "Implementation is running, need a deploy artifact to hand off to devops"

## Workflow — 4 phases

### Phase 1 — Task Breakdown

#### Step 1: Read edd.md

Read from working dir or the path the user provides. If missing → **stop**. em-works doesn't start from blank — always from a plan that's already been framed.

#### Step 2: Atomic ticket decomposition

Break the edd scope into atomic tickets. Per ticket:

- **What:** 1 deliverable, measurable, ≤ Large compute class (smaller is better)
- **Why:** Connect to a specific edd invariant or failure mode #
- **Acceptance criteria:** Test cases + behavioral expectations + observability check
- **Dependencies:** Other tickets that must be done first (be explicit, not implicit)
- **Owner suggestion:** Based on module ownership if the team has context, or "any AI agent"
- **Touched modules:** Directories (controllers/, models/) — not specific files
- **Compute class:** Nano / Small / Medium / Large / XL (if XL → split)
- **Est. tokens:** ~Xk in / ~Xk out
- **AI clock:** ~X min (single agent, sequential calls)

#### Compute class reference

| Class | AI clock | Total tokens | When to use | Rule |
|-------|----------|--------------|-------------|------|
| **Nano** | < 1 min | < 2k | Config, doc, 1-liner, rename | — |
| **Small** | 1–5 min | 2k–8k | Isolated function, small fix, single file | — |
| **Medium** | 5–20 min | 8k–25k | Module-level feature, multi-file change | — |
| **Large** | 20–60 min | 25k–80k | Cross-module feature, migration, multi-lane | Consider splitting |
| **XL** | > 60 min | > 80k | — | **Must split** |

Token budget = sum of all ticket `Est. tokens`. Report in TL;DR as sprint token budget. Helps prompter scope the AI compute cost upfront.

Prompt count estimate: assume 1 prompt per agent call. Medium ticket ≈ 2–4 prompts (plan + impl + review). Large ≈ 5–10 prompts.

#### Step 3: Apply the Beck principle

> "Make the change easy, then make the easy change." — Kent Beck

Refactor ticket always **before** feature ticket. Don't bundle them in 1 ticket.

✅ Good:
- T1: Refactor PaymentService to extract idempotency key handling (no behavior change)
- T2: Add new payment provider X (using extracted idempotency)

❌ Bad:
- T1: Refactor PaymentService and add provider X (mixed structural + behavioral)

#### Step 4: Glue work flag

Identify tickets that are invisible coordination:
- Migration scripts
- Test fixtures
- Documentation updates
- CI/CD config
- Monitoring dashboard creation
- Runbook writing

**Make them visible.** Distribute fairly across the team — don't let 1 person get stuck doing only glue (anti-pattern, Reilly's *The Staff Engineer's Path*).

### Phase 2 — Worktree / Parallelization Lanes

Forcing questions:

1. **Lane analysis** — do tickets share modules?
   - a) Yes → same lane (sequential within lane)
   - b) No + no dep → separate lane (parallel)
   - c) Yes but read-only overlap → parallel ok with flag

2. **Conflict flag** — do 2 lanes touch the same module?
   - a) Sequential (safer)
   - b) Coordinate explicitly (require sync points)
   - c) Refactor module first into 2 sub-modules (separate ticket)

#### Output lanes table

| Lane | Tickets | Modules | Depends on | Worktree branch suggestion |
|------|---------|---------|------------|----------------------------|
| A | T1 → T2 | controllers/, models/ | — | feature/payments-providers |
| B | T3 | utils/ | — | refactor/idempotency-helper |
| C | T4 | infra/ | A done | infra/payments-rollout |

#### Execution order

Format: "Launch A + B parallel via worktree. Merge both. Then C."

If Claude Code Agent with `isolation: "worktree"` is available, suggest using it for lanes A & B.

### Phase 3 — Environment & Secrets Specification

> Important: em-works **specifies what's needed**, doesn't provision. Provisioning = devops skill.

Per env (local / staging / prod), spec the following:

#### Env vars table

| Var | Local | Staging | Prod | Sensitive? | Owner |
|-----|-------|---------|------|------------|-------|
| `DB_URL` | `.env.local` | `secrets/staging/db-url` | `secrets/prod/db-url` | Yes | infra-team |
| `EXTERNAL_API_KEY` | `.env.local` | `secrets/staging/api-key` | `secrets/prod/api-key` | Yes | api-team |
| `FEATURE_FLAG_X_DEFAULT` | `false` | `false` | `false` | No | feature-owner |

#### Secrets spec

| Secret | Storage location | Rotation policy | Access list | Pre-handoff status |
|--------|------------------|-----------------|-------------|---------------------|
| `db-url-prod` | AWS Secrets Manager | 90 days | infra-team, app-pods | TODO: provision |

Status keywords:
- `TODO: provision` — devops needs to create
- `TODO: rotate` — exists but needs rotation
- `READY` — confirmed exists & accessible
- `DEPRECATED` — old secret to be removed post-deploy

#### Infra prereqs checklist

- [ ] Database schema migration prepared (file: `migrations/202X-XX-XX-name.sql`)
- [ ] Queue/topic creation spec (broker URL placeholder, dead-letter topic name)
- [ ] Feature flag definition (name: `payment.provider_x.enabled`, default: `false`, owner: `payments-team`)
- [ ] Monitoring dashboard plan (metrics: latency P50/P99, error rate, throughput)
- [ ] Alert rule plan (threshold: error rate > 1% / 5min, escalation: PagerDuty payments-oncall)
- [ ] Runbook draft (link or path)

Status for each item: `READY` / `TODO` / `BLOCKED (waiting on X)`.

Forcing questions:

1. **Secrets status:** Prod secret X — exists already or needs provisioning?
   - a) Ready (link to Secrets Manager entry)
   - b) Need provisioning (assign to devops)
   - c) Need rotation (current secret valid until ...)

2. **Feature flag default:** what is it?
   - a) Off (recommended — safest rollout)
   - b) On (justify — usually only for refactor with no behavior change)
   - c) Per-env (off in prod, on in staging — for testing)

3. **Migration approach:**
   - a) Backwards-compatible (add column nullable, then later make NOT NULL)
   - b) Single-step (acceptable risk, T2 only)
   - c) Multi-deploy coordinated (T0/T1 with high data volume)

### Phase 4 — Deployment Plan Artifact

> em-works **writes the plan**, doesn't execute. Execution = `release-engineer` / `devops` role.

Active cognitive patterns:
- **Reversibility preference** — feature flag, canary, blue-green, incremental rollout
- **Error budgets over uptime** — what's the budget to spend on this rollout?
- **Own your code in production** — who's the first on-call window owner?

#### Deploy strategy

Pick one + justify:

- **Feature flag toggle** — code deploys disabled, flag flips per cohort. Lowest risk. Default for T0/T1 with user-facing behavior change.
- **Canary** — deploy to small % of traffic, observe, expand. Use when no flag-friendly UX boundary.
- **Blue-green** — full new env, switchover. Use when DB schema change or breaking API.
- **Big bang** — deploy + activate. Acceptable for T2/T3 only with low blast radius.

#### Rollback procedure

- **Trigger conditions:** explicit threshold (error rate, latency P99, manual decision)
- **Procedure:** step-by-step, target < 5 minute execution
- **Data implications:** if migration is involved, rollback procedure for data too (forward-compat data, backfill plan, etc.)
- **Communication:** who to notify, channel

#### Monitoring window

- **First 24h:** dedicated on-call attention, error rate watch
- **First 7 days:** check metric drift weekly review
- **Sign-off criteria:** error rate baseline, latency baseline, no incident → safe to remove canary / fully ramp flag

#### Comms plan

- **Pre-deploy:** announce window, scope, rollback strategy (Slack channel, email, status page)
- **During:** live status update per phase
- **Post-deploy:** retrospective summary, metric snapshot

### Phase 5 — Pre-Handoff Checklist

Before handoff to engineer, validate:

- [ ] All tickets have clear acceptance criteria
- [ ] Lane plan unambiguous (no orphan tickets, no overlapping module conflict unresolved)
- [ ] Env vars + secrets table complete with status
- [ ] Infra prereqs status: minimum READY or with explicit owner+ETA for TODO items
- [ ] CI green on baseline branch (link to last green build)
- [ ] Test fixture data prepared (link or path)
- [ ] Monitoring dashboard plan documented (will be implemented during impl phase)
- [ ] Rollback procedure documented
- [ ] On-call window-1 owner identified

If any item isn't READY → flag explicitly. Engineers can start tickets that don't depend on the missing item.

## Output: `eng-works.md` + `eng-works.html` (dual output)

**Must write 2 files** in working dir:

1. **`eng-works.md`** — source markdown (structure below, handoff to engineer role + version control)
2. **`eng-works.html`** — human-readable review version, self-contained with inline CSS (compute class badges colored, lane table highlighted, token budget summary card, TOC + breadcrumb)

HTML render uses the template + full CSS spec from [`../../references/html-template.md`](../../references/html-template.md). Content must be 1:1 consistent with markdown. Skipping HTML = anti-pattern (prompter explicitly reviews via HTML).

Optional push: if Notion MCP is connected, offer to push `eng-works.md` to Notion engineering page. HTML stays local for browser review.

```markdown
# Eng Works: [topic]

**Date:** YYYY-MM-DD
**Plan source:** edd.md (path)
**Risk tier:** Tx (inherited from plan)
**Prepared by:** em-works

---

## TL;DR

- **Total tickets:** N
- **Lanes:** A (sequential) | B (parallel A) | C (after A done)
- **Deploy strategy:** [feature-flag / canary / blue-green / big-bang]
- **Sprint token budget:** ~Xk total (sum across all tickets) — ~Xk in / ~Xk out
- **AI clock:** ~X min sequential / ~X min optimal parallel
- **Pre-handoff blockers:** N (must clear before engineer starts)
- **Handoff status:** READY / BLOCKED (reason)

---

## Tickets

### T1 — [name]

- **What:** [1-line deliverable]
- **Why:** Implements invariant #X / closes failure mode #Y from edd
- **Acceptance:**
  - [ ] [test case 1]
  - [ ] [test case 2]
  - [ ] [observability check — log/metric emitted]
- **Dependencies:** —
- **Modules:** controllers/, models/
- **Owner suggestion:** [name / "any AI agent"]
- **Compute class:** Small
- **Est. tokens:** ~4k in / ~2k out
- **AI clock:** ~3 min (single agent)
- **Glue work:** [yes — what type / no]

### T2 — [name]
...

---

## Parallelization Plan

### Lanes

| Lane | Tickets | Modules | Depends on | Worktree branch |
|------|---------|---------|------------|-----------------|

### Execution order

[Narrative: "Launch A + B parallel via worktree. Merge both. Then C."]

### Conflict flags

[List any cross-lane risks + mitigation]

---

## Environment & Secrets

### Env vars

| Var | Local | Staging | Prod | Sensitive? | Owner |
|-----|-------|---------|------|------------|-------|

### Secrets

| Secret | Storage | Rotation | Access | Status |
|--------|---------|----------|--------|--------|

### Infra prereqs

- [ ] [item 1] — Status: READY / TODO (owner) / BLOCKED (reason)

---

## Deployment Plan Artifact

### Strategy
**Pick:** [feature-flag / canary / blue-green / big-bang]
**Rationale:** ...

### Rollback procedure
- **Trigger:** [explicit threshold]
- **Steps:**
  1. ...
  2. ...
- **Target time:** < 5 min
- **Data rollback:** [if migration involved]
- **Comms:** [who to notify, channel]

### Monitoring window
- **First 24h:** [on-call assignment]
- **First 7 days:** [review cadence]
- **Sign-off criteria:** [explicit metrics + thresholds]

### Comms plan
- **Pre-deploy:** [channels + scope statement]
- **During:** [status update cadence]
- **Post-deploy:** [retrospective trigger]

---

## Pre-Handoff Checklist

- [ ] All tickets have clear acceptance criteria
- [ ] Lane plan unambiguous
- [ ] Env vars table complete
- [ ] Secrets table complete with status
- [ ] Infra prereqs minimum READY or explicit TODO owner+ETA
- [ ] CI green on baseline (link)
- [ ] Test fixtures ready (link)
- [ ] Monitoring dashboard plan documented
- [ ] Rollback procedure documented
- [ ] On-call window-1 owner identified

---

## Forcing Questions Raised

| # | Phase | Question | Response | Resolution |
|---|-------|----------|----------|------------|

---

## Handoff

### Per ticket → `engineer` role
- Tickets ready: T1, T2, T3
- Tickets blocked: T4 (reason: waiting on infra prereq X)
- Skill matched per env (env-team picks the engineer skill that handles this role)

### After implementation → /em-review
- Per PR or batch end-of-lane
- Mode: review (standard) or debug (if a bug emerges)

### Deployment → `release-engineer` / `devops` role
- Deploy artifact ready: deployment plan section above
- Pre-deploy validation: monitoring window owner confirmed, rollback procedure tested in staging
- Skill matched per env (env-team picks the deploy/release skill that handles this role)

---

**Generated by:** em-works
**Ready for:** Engineer skill (per ticket) + future devops skill (per deploy plan)
```

## Integration with tools

| Condition | Behavior |
|---------|----------|
| Notion MCP connected | Offer to push `eng-works.md` to Notion engineering page; tickets can be mirrored as Notion database rows |
| Linear MCP connected | Offer to create a Linear issue per ticket with dependency link |
| ClickUp / Monday MCP connected | Same — bulk task creation |
| GitHub MCP connected | Offer to create an issue per ticket in the target repo |
| Pencil MCP connected | Offer to generate a visual lane diagram from ASCII |
| No MCP | File saved as local `eng-works.md`, user copies manually to task tracker |

## Anti-pattern (don't do this)

- ❌ **Skip `eng-works.html` output.** Dual output (`.md` + `.html`) mandatory — prompter reviews via HTML.
- ❌ **"Implementation: TBD"** — no ticket-level breakdown. Output isn't handoff-able.
- ❌ **Skip env/secrets spec.** Engineer gets stuck in local setup, loses cycle time.
- ❌ **Bundle refactor + feature in 1 ticket.** Anti-Beck principle.
- ❌ **Big bang deploy for T0/T1.** Sin. Always feature-flag or canary.
- ❌ **Rollback = "git revert" without data consideration.** Migration rollback needs a data plan.
- ❌ **Ticket XL compute class that isn't split.** Atomicity broken — AI agent will drift or lose context.
- ❌ **Glue work invisible.** Causes 1 agent to get stuck doing only glue, anti-pattern Reilly.
- ❌ **Lane plan with 2 lanes sharing a module without conflict flag.** There will be merge hell.
- ❌ **Execute deployment in em-works.** Out of scope. Hand off to devops skill.
- ❌ **Skip sprint token budget in TL;DR.** Prompter needs cost visibility before committing to the plan.

## Handoff

- **Per ticket** → `engineer` role (skill matched per env).
- **PR comes back** → `/em-review` (per ticket or batch end-of-lane).
- **Deploy artifact ready** → `release-engineer` / `devops` role (skill matched per env).

If the pre-handoff checklist is incomplete (many BLOCKED items), the output flags "BLOCKED" in the TL;DR — engineers don't start until blockers are cleared. Loop back to `devops` / `infra-owner` before handoff.
