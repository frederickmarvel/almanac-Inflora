---
name: pm-works
description: Write a Product Requirements Document (PRD) from a discovery output or a problem hypothesis, with built-in Technical Implications section and structured handoff to engineering. Use when turning a validated hypothesis into a spec, when writing a PRD that engineers will actually act on, when scoping a feature with goals and non-goals, when defining acceptance criteria and success metrics, or when a feature request needs structured documentation before sprint planning. Forces tech-awareness (schema, API, backward compat) without making engineering decisions.
argument-hint: "<feature topic or path to discovery.md>"
---

# /pm-works

Write a complete PRD from a discovery output or hypothesis. Output is ready to hand off to the `engineer-manager` skill (or directly to the eng team).

> **Reference resolution.** `../../references/*.md` paths resolve inside the `pm-thinking` bundle. If a referenced file does not exist (standalone/flattened install), **say so explicitly** and continue with the rules inlined in this SKILL.md — never improvise the missing file's content; recommend reinstalling the full `pm-thinking` bundle.

This skill is **draft-only**. For audit / red-team, run `/pm-decide --review` after the PRD is done.

## ⚠ Question Format Rule (mandatory for every skill in pm-thinking)

**Every question to the user must be tagged with a unique label** (1/2/3 or a/b/c) so the user can respond by pointing — anti-ambiguous, saves user effort.

Use the `AskUserQuestion` MCP when available. Fall back to numbered text:

```
1. [Q]?
   a) ...
   b) ...
2. [Q]?
   a) ...
   b) ...
```

User: "1a, 2b" — done. Detail in [references/ai-first-principles.md](../../references/ai-first-principles.md) principle #8.

## When to trigger this skill

- "Hypothesis is validated, now I want to write the PRD"
- "Write a spec for feature X, read from `discovery.md`"
- "Build a PRD for enterprise SSO, deadline 2 weeks"
- "Convert this idea into a spec eng can execute on"
- "I have a rough Notion page, need to clean it up into PRD format"

## Workflow

### Step 1: Capture input

Ask the user:

a) **Path to `discovery.md`** from `/pm-discover` (preferred — best context)
b) **Notion page link** with hypothesis / rough draft (if Notion MCP is connected, read via `mcp__plugin_operations_notion__*`)
c) **Hypothesis statement directly** — paste in chat
d) **Direct argument** — `$ARGUMENTS` from skill invocation

If none is available, **stop**. PRD without hypothesis = solution looking for a problem. Tell the user to run `/pm-discover` first, or at minimum provide a hypothesis statement.

### Step 2: Gather context (ask one at a time, don't dump)

Ask these things conversationally. Use **AskUserQuestion** if available for fast answers:

#### Mandatory (don't skip)

1. **Target user segment** — who specifically? ("enterprise admin" not "user")
2. **Success metric (north star)** — how will you know this worked? Specific number, time window
3. **Hard deadline / dependency** — is there a commitment date? Locked stakeholder?
4. **Scope boundary** — is this v1 or full vision?

#### When there's signal

5. **Existing component** — is there an existing feature / API / component to reuse or that will be affected?
6. **Compliance / legal** — touches personal data, regulated industry, region-specific?
7. **Mockup link** — a Pencil / Figma link? (if Pencil MCP is connected, fetch via `mcp__pencil__*`)

### Step 3: Drive Tech Implications (CORE differentiator of this skill)

**This is what differentiates pm-works from a generic PRD skill.** Before writing, push the PM to answer:

> See [references/tech-literacy-checklist.md](../../references/tech-literacy-checklist.md) for the full checklist.

**Force the PM to think (not the PM to make the decision):**

| Question | Why the PM needs to answer |
|----------|---------------------|
| New schema? Migration on an existing table? | Eng needs to know the scope of database work |
| API contract change? Breaking change? | Backward compat strategy needs planning |
| Touches sensitive data? PII / payment / health? | Compliance review timeline must be allocated |
| Existing component that will be affected? | Risk of regression in another area |
| Realistic effort — week, month, or quarter? | Sanity check before committing to a deadline |

The PM **doesn't make decisions** — the PM only flags awareness. The output PRD will have a "Technical Implications" section that contains **observations**, not **prescriptions**.

### Step 4: Write the PRD

Output to a `prd.md` file (or Notion page if MCP is connected). Use this template **exactly**:

```markdown
# PRD: [Feature Name]

**Author:** [PM]
**Status:** Draft → Review → Approved → Building → Shipped
**Date:** YYYY-MM-DD
**Discovery source:** [link to discovery.md or Notion]
**Engineering lead:** TBD (will be assigned via /pm-decide --prio)

---

## TL;DR

[2-3 sentences. What's being built, for whom, why now.]

---

## Problem Statement

[From the discovery.md hypothesis. Pain → segment → cost-of-not-solving.]

**Evidence:**
- [Quote / data point #1] — [source]
- [Quote / data point #2] — [source]

---

## Goals (3-5)

Measurable outcomes. Not output (feature shipped), but behavior change.

1. [Goal] — measurable by [metric, target, time window]
2. ...

---

## Non-Goals (3-5)

What is explicitly OUT of scope, plus rationale.

1. [Thing] — out of scope because [reason]
2. ...

---

## User Stories

Group by persona. Format: As a [user type], I want [capability] so that [benefit].

### Persona 1: [name]
- As a [type], I want [capability] so that [benefit]
- ...

### Persona 2: ...

---

## Requirements

### Must-Have (P0)
- [ ] [Requirement] — acceptance: [Given/When/Then or checklist]
- [ ] ...

### Nice-to-Have (P1)
- [ ] ...

### Future Considerations (P2)
- [ ] ...

---

## Technical Implications (CORE — must be filled in)

> PM observation, not prescription. Engineering decides implementation.

### Data layer
- Schema impact: [None / New table X / Add column Y to table Z]
- Migration: [Required / None]
- Data sensitivity: [PII / payment / none]

### API / Integration
- API contract change: [None / New endpoint / Breaking change to existing]
- Backward compat: [N/A / Required — strategy TBD by eng]
- External dependency: [None / X service / Y vendor]

### Existing components affected
- [Component A] — [how affected]
- [Component B] — [how affected]

### Compliance / Privacy
- Touches: [list — none, PII, payment, health, regulated region]
- Required review: [None / Legal / Security / Privacy]

### Effort ballpark (PM guess, not commitment)
- [Days / Weeks / Months] — full eng commitment to be confirmed by engineer-manager skill

### Open technical questions for eng
- [Q1 — what the PM can't answer, needs eng input]
- [Q2 — ...]

---

## Success Metrics

### Leading indicators (days–weeks)
- [Metric] — current baseline → target → measurement source [BigQuery query / Amplitude / Notion log]

### Lagging indicators (weeks–months)
- [Metric] — baseline → target → measurement window

---

## Rollout Plan

- **Phase 1 (internal):** [scope, timeline]
- **Phase 2 (beta cohort):** [criteria, timeline]
- **Phase 3 (GA):** [criteria, timeline]

### Kill switch / rollback
- [Mechanism — feature flag, env var, etc.]

---

## Open Questions

| # | Question | Owner | Blocking? |
|---|----------|-------|-----------|
| 1 | [Q] | [Eng / Design / Legal / Data] | [Yes / No] |

---

## Handoff to Engineer Manager

This section is for the `engineer-manager` skill (or eng tech lead directly) to consume. PM stops here, eng takes over.

**Hypothesis to validate:**
[From discovery.md]

**Constraints (locked by PM):**
- [User-facing constraint, e.g., "must support SSO via SAML 2.0"]
- [Business constraint, e.g., "ship before Q3 review"]

**Decisions delegated to eng:**
- [Decision area — e.g., "tech stack for SSO library"]
- [Decision area — e.g., "session storage strategy"]

**Don't decide engineering:**
- Specific library / framework choice
- Service boundary
- Performance trade-off
- Deployment strategy

---

## Appendix

- Mockup: [Pencil link if any]
- Discovery source: [link]
- Related PRDs: [link]
```

### Step 5: Push to Notion (if connected)

If `mcp__plugin_operations_notion__*` is connected, **offer to** push the PRD to a Notion page. Default location: the PRD database / folder the user points to. Ask for confirmation once, then push.

### Step 6: Suggest next step

Once the PRD is done, suggest to the user:

> "PRD draft is complete. Next: run `/pm-decide --review` for a red-team audit before handing off to eng. Want me to trigger it now?"

## Tools integration

| Condition | Behavior |
|---------|----------|
| Notion MCP connected | Push the PRD to Notion, pull discovery from a Notion link |
| Pencil MCP connected | Embed the mockup link in the Appendix |
| BigQuery MCP connected | Auto-fill baseline metrics if the PM provides a SQL hint |
| No MCP available | Output to local `prd.md`, copy manually |

## Anti-pattern

- ❌ Writing a PRD without upstream discovery / hypothesis — that's wishful thinking
- ❌ "Technical Implications" empty / vague ("might affect database") — minimum: list specific component, schema impact
- ❌ Output-based goal ("ship onboarding wizard") instead of outcome-based ("reduce time-to-first-value 50%")
- ❌ P0 with 15 items — ruthless prio, P0 max 5-7
- ❌ "Skip Tech Implications, eng will figure it out" — that's what makes eng surprised at kickoff
- ❌ Deciding the tech stack in the PRD — that's the engineer-manager domain

## Downstream handoff

- `prd.md` → `/pm-decide --review` for red-team audit
- After review approves → `engineer-manager` skill takes the "Handoff to Engineer Manager" section for technical design
- "Success Metrics" section → fed into `/pm-decide --retro` post-launch

## Reference

- [tech-literacy-checklist.md](../../references/tech-literacy-checklist.md) — full Tech Implications checklist
- [handoff-to-eng-manager.md](../../references/handoff-to-eng-manager.md) — contract between pm-thinking and engineer-manager
