---
name: em-plan
description: Receive engineering intake (PRD, design doc, bug repro, ad-hoc request) and produce an architectural plan with risk tier, scope challenge, invariants, failure modes, and test strategy. Use when starting a new engineering investigation, when a PRD lands and needs eng grounding, when a recurring bug needs proper plan before patching, when team debates two architectural approaches, or when a refactor request needs structured framing. Pushes back on speculative architecture — extracts boundaries and invariants, not implementation choices.
---

# /em-plan

Take raw input (PRD, design doc, bug repro, ad-hoc request) → produce `edd.md` that locks architecture, risk tier, invariants, failure modes, and test strategy.

Not execution detail (task breakdown, env, deploy) — that's `/em-works`. Not code review — that's `/em-review`. **em-plan = think before you work.**

> **Reference resolution.** All `../../references/*.md` and `../../ETHOS.md` paths resolve inside the `em-thinking` bundle. If a referenced file does not exist (standalone/flattened install), **say so explicitly** and continue using only the rules inlined in this SKILL.md — never improvise the missing file's content. If `../../references/html-template.md` is missing, deliver `edd.md` only, state that `edd.html` was skipped because the template is unavailable, and recommend reinstalling the full `em-thinking` bundle.

## ⚠ Question Format Rule (required for all em-thinking skills)

**Every question to the user must be tagged with a unique label** (1/2/3 or a/b/c) so the user can respond by pointing — anti-ambiguity, saves user effort.

Use `AskUserQuestion` MCP if available. Fall back to numbered text:

```
1. [Q]?
   a) ...
   b) ...
2. [Q]?
   a) ...
   b) ...
```

User: "1a, 2b" — done. Detail in [../../ETHOS.md](../../ETHOS.md) principle #8.

## When to trigger this skill

- "PRD from `/pm-works` is ready, I want an eng plan"
- "Recurring bug in production, I need a proper plan before patching"
- "Founder asked for feature X — I'm not sure of the eng scope yet"
- "Team is debating 2 approaches (microservice vs module) — need structured framing"
- "Refactor module Y — want a proper plan before starting"
- "Plan from a junior eng — I want to audit the framing"

## Workflow — 4 phases

### Phase 1 — Capture & Risk-Classify

#### Step 1: Capture input

Ask the user for one of:

a) **PRD / discovery.md** — output from pm-thinking (path / Notion link)
b) **Design doc** — markdown / Notion / Pencil canvas
c) **Bug repro** — stack trace + repro steps + observed behaviour
d) **Ad-hoc verbal** — user pastes plain English request
e) **Existing code** — refactor request, "module X needs rework"

If none available → **stop**. This skill doesn't speculate. Tell the user to come back with at least 1 concrete artifact.

#### Step 2: Classify risk tier

Must state explicitly upfront — risk tier determines the discipline that applies (test-first, security review, etc.).

| Tier | Surface | Examples | Required discipline |
|------|---------|----------|---------------------|
| **T0 — Critical** | Irreversible operations, security boundaries (auth/authz, secrets), state machines with concurrency, external system contracts (idempotency, exactly-once), sensitive data (PII, regulated, financial, health) | Critical write path, login/session handling, distributed lock, webhook receiver, data export with sensitive fields | Test-first required. `security-reviewer` role parallel. Postmortem-grade documentation. |
| **T1 — High** | Schema migration, breaking API, multi-service coordination, observability gap in sensitive area | Add NOT NULL column, change response field type, cross-service transaction | Test strategy explicit. Migration plan reviewed. Backward compat addressed. |
| **T2 — Standard** | Single-module feature, additive backward-compat, isolated surface | New endpoint with feature flag, internal helper module | Standard test coverage. Invariants stated. |
| **T3 — Trivial** | Config / docs / dev tooling / style | README update, CI workflow tweak, lint rule | Sanity check only. Skip heavy review. |

Classification detail in [../../references/risk-tiering.md](../../references/risk-tiering.md).

T0/T1 → test-first required in Phase 4. T2/T3 → fast lane, still requires minimum 1 invariant statement.

### Phase 2 — Step-0 Scope Challenge

> Do this **before** designing architecture. Scope locked first → architecture second.

Forcing questions (one issue = one AskUserQuestion):

1. **What already exists** — code/flow that already partially solves this problem?
   - The skill must *search* (Grep/Glob), not ask the user. Look for similar functions, similar modules, similar patterns.
   - Output: list with reuse decision per item ("reuse / extend / parallel-build with rationale").

2. **Minimum change set** — if the goal is just X, what can be deferred?
   - Push back if scope contains "while we're at it..." — that's scope creep.
   - Output: in-scope vs deferred (NOT-in-scope) list.

3. **Complexity smell check** — does the proposal touch >8 files or introduce >2 new classes/services?
   - Trigger scope-reduce conversation if yes.
   - AskUserQuestion: "This plan touches N files (>8). Reduce scope, or proceed as-is with justification?"

4. **Built-in check** — does the framework/runtime have a built-in for this pattern?
   - Search "{framework} {pattern} built-in" before custom solution.
   - Search "{pattern} pitfalls" for known footguns.
   - If WebSearch unavailable, note: "Search unavailable — proceeding with in-distribution knowledge only."

5. **Two-week smell test** — could a competent new engineer ship this feature in 2 weeks?
   - If not, the problem is in onboarding/architecture/docs, not the feature itself.
   - Flag as "onboarding problem masked as architecture" if triggered.

After Phase 2: **commit to scope.** Don't re-argue scope in Phase 3-4. If scope changes → loop back to Phase 1.

### Phase 3 — Architecture Design

Apply the 15 cognitive patterns as **lenses**, not a dead checklist. Detail in [../../references/cognitive-patterns.md](../../references/cognitive-patterns.md).

Sub-steps:

#### 3.1 — State Diagnosis (Larson)
What state is this team in?
- a) **Falling behind** — backlog piling up, on-call exhausted, slow to ship → intervention: reduce WIP, simplify
- b) **Treading water** — shipping works but no strategic progress → intervention: reclaim slack
- c) **Repaying debt** — actively cleaning up → intervention: protect from new scope
- d) **Innovating** — strong foundation, team explores → intervention: bounded experiments

The plan must be contextual to the state. An ambitious plan for a "falling behind" team = adding pain.

#### 3.2 — Component & Data Flow

Must produce:
- **Component boundaries** — what's in scope, what's out (ASCII box diagram)
- **Data flow** — where requests come in, what they pass through, where they go out (ASCII arrow diagram)
- **State machine** — if state count >2, ASCII state diagram
- **Trust boundaries** — where data is validated, where it's trusted as-is
- **Single points of failure** — identify, then decide accept or mitigate

Diagram is **required** for non-trivial flow (>2 hops). Skipping the diagram = anti-pattern.

#### 3.3 — Invariants (min 1)

"What must always be true." Statements more specific than prose, but not necessarily formal logic.

✅ Good:
- "Account balance can never be negative."
- "Once a webhook event is acknowledged, it is processed exactly once."
- "Session tokens are never logged or persisted in plaintext."

❌ Bad:
- "TBD" — if you can't state it, the plan isn't ready
- "Code is clean" — not an invariant, that's an aspiration
- "No bugs" — not an invariant, that's impossible

#### 3.4 — Cognitive Pattern Citation (min 2)

Cite cognitive patterns that actually shaped a decision in this plan. Not empty signaling.

✅ Good:
- "Boring by default — picked Postgres over <new shiny db> because the team has operated Postgres for 3 years. Innovation token saved for feature X."
- "Reversibility — feature flag default off, canary 5% → 25% → 100%. Rollback < 5 minutes via flag toggle."

❌ Bad:
- "We applied Conway's Law." — doesn't connect to a specific decision
- (No citation at all) — generic review

### Phase 4 — Test Strategy

T0/T1 → mandatory test-first. T2/T3 → standard coverage.

#### Failure modes table

Must enumerate. Per row:

| # | Scenario | Test? | Handling? | Visible to user? | Severity |
|---|----------|-------|-----------|-------------------|----------|
| 1 | Network timeout to upstream | ✓ | ✓ retry | Loud retry message | Med |
| 2 | Race condition in concurrent write | ✗ | ✗ | Silent corruption | **Critical gap** |

Critical gap = no test + no handling + silent. Critical gaps > 0 → block before em-works.

#### Coverage targets

- Core invariant — 100% (mandatory T0/T1)
- Error paths — explicit list
- Edge cases — explicit list (empty input, max input, concurrent access, partial failure)
- Integration — required interactions covered

Forcing questions:
1. "Failure mode #X — accept gap or block? a) Accept (rationale) b) Block c) Defer to follow-up ticket"
2. "Test-first for T0 surface — apply 100% or partial with justification? a) Full b) Partial X% c) No (justify)"

## Output: `edd.md` + `edd.html` (dual output)

**Must write 2 files** in working dir:

1. **`edd.md`** — source markdown (structure below, must match exactly for downstream skill consumption)
2. **`edd.html`** — human-readable review version, self-contained with inline CSS (badge T0-T3 colored, ASCII diagram styled, failure modes table critical-gap highlighted, TOC + breadcrumb)

HTML render uses the template + full CSS spec from [`../../references/html-template.md`](../../references/html-template.md). Content must be 1:1 consistent with markdown — same data, different rendering. Skipping HTML = anti-pattern (user explicitly reviews via HTML).

Optional push: if Notion MCP is connected, offer to push `edd.md` to Notion (markdown renders natively in Notion). Keep HTML local for browser review.

### MD Structure (must match)

```markdown
# EDD: [topic]

**Date:** YYYY-MM-DD
**Risk tier:** T0 / T1 / T2 / T3
**Source:** [PRD path / Notion link / verbal description]
**Planned by:** em-plan
**State diagnosis:** [Falling behind / Treading water / Repaying debt / Innovating]

---

## TL;DR — Recommended Path

**Problem (1 line):** ...
**Architecture summary (1 paragraph):** ...
**Critical invariants:** [bullet list]
**Critical gaps:** N (must resolve before em-works)
**Recommended path:** [proceed to em-works / scope-reduce first / send back to PM]
**Next skill:** `/em-works` (if ready) or `/em-plan --rescope`

---

## Step-0 Scope Findings

- **What already exists:** [refs + reuse decision per item]
- **Minimum change set:** [in-scope items]
- **NOT in scope:** [items deferred + 1-line rationale each]
- **Complexity smell:** [yes — N files / no]
- **Built-in available:** [yes — what / no — search performed]
- **Two-week feasibility:** [yes / no — root cause if no]

---

## Architecture

### Component boundaries

\`\`\`
[ASCII box diagram]
\`\`\`

### Data flow

\`\`\`
[ASCII arrow diagram]
\`\`\`

### State machine (if applicable)

\`\`\`
[ASCII state diagram]
\`\`\`

### Trust boundaries

- [boundary 1 — what data crosses, what's validated, what's trusted]
- [boundary 2 — ...]

### Single points of failure

- [SPOF 1 — accept rationale OR mitigation plan]

### Cognitive patterns applied

- **[Pattern X]** → applied to [decision Y] because [reason]
- **[Pattern Z]** → applied to [decision W] because [reason]

(Min 2-3 — cited explicitly, connected to concrete decision)

---

## Invariants

- [Invariant 1 — what must always be true]
- [Invariant 2 — ...]

---

## Failure Modes

| # | Scenario | Test? | Handling? | UX | Severity |
|---|----------|-------|-----------|-----|----------|

**Critical gaps:** [items with no test + no handling + silent]

---

## Test Strategy

- **Test-first required:** [yes (T0/T1) / no]
- **Coverage targets:**
  - Core invariant: [target %]
  - Error paths: [list]
  - Edge cases: [list]
  - Integration: [list]
- **Test types:** [unit / integration / contract / e2e — applicable mix]

---

## Forcing Questions Raised

| # | Phase | Question | Response | Resolution |
|---|-------|----------|----------|------------|
| 1 | Scope | "[Q]" | "[user response]" | "[how it shaped output]" |

---

## Open Questions for em-works

- [Q answerable in execution prep, e.g. infra prereq, secret management]
- [Q that must be resolved before task breakdown]

---

## Handoff

- **Next skill:** `/em-works`
- **Required input:** this file + [referenced docs]
- **Required follow-up review (route by role, not skill name):**
  - `security-reviewer` role — if T0 + sensitive surface
  - `qa-reviewer` role — if T0/T1 + complex test surface
  - none — if T2/T3
- **Block conditions:** critical gaps > 0 → must resolve before em-works

---

**Generated by:** em-plan
**Ready for:** /em-works
```

## Integration with tools

| Condition | Behavior |
|---------|----------|
| Notion MCP connected | Offer to push `edd.md` to Notion engineering page (HTML stays local) |
| BigQuery MCP connected | Offer to pull metric data to validate scale assumptions (concurrent users, query volume) |
| Pencil MCP connected | Offer to generate diagram from ASCII (when user prefers visual) |
| WebSearch tool available | Auto-search built-in check at Phase 2 step 4 |
| No MCP | Files saved as local `edd.md` + `edd.html`, user opens `edd.html` in browser |

## Anti-pattern (don't do this)

- ❌ **Skip `edd.html` output.** Dual output (`.md` + `.html`) mandatory — user reviews via HTML.
- ❌ **Skip risk tier.** Leaves downstream without a proper gate.
- ❌ **Jumping to implementation.** "Use Postgres + Kafka" in Phase 3 without state diagnosis = anti-pattern.
- ❌ **Skip "what already exists" search.** Causes the team to rebuild parallel infrastructure.
- ❌ **"Critical invariant: TBD"** — if you can't state it, the plan isn't ready.
- ❌ **Cite cognitive pattern without connecting to a concrete decision.** Empty signaling.
- ❌ **Skip ASCII diagram for flow > 2 hops.** Diagram is not optional.
- ❌ **Recommend overkill for T2/T3.** Over-engineering = sin.
- ❌ **Bundle refactor + feature in the same plan.** Beck's principle: make the change easy, then make the easy change. Two plans.
- ❌ **A plan for a "falling behind" team that adds scope.** Adds pain, not reducing.

## Handoff

The `edd.md` output becomes **required input** for `/em-works`. Critical gaps in failure modes → blocker, must resolve first.

If em-plan reveals **scope is too large or the approach is fundamentally wrong**, the output is also valid — it means `/pm-works` needs to be looped back with reframed problem, or the scope must be reduced before continuing.

If T0 with security/compliance surface → trigger `security-reviewer` role parallel to `/em-works`. Both run in parallel; security findings feed back into the em-works pre-handoff checklist.
