---
name: pm-decide
description: Multi-mode strategic skill — prioritize backlog, red-team review a PRD, draft a stakeholder update, or run a post-launch retro. Use with --prio when ranking initiatives or running RICE/ICE/Kano against a backlog, with --review when auditing a PRD before handoff to engineering, with --stakeholder when writing weekly status or translating progress for exec/eng/sales/customer audiences, or with --retro when reflecting on a shipped feature against success criteria. Forces critical questions for each mode — not template fill-in.
argument-hint: "--prio | --review <prd-path> | --stakeholder <audience> | --retro <feature-name>"
---

# /pm-decide

Multi-mode skill for the **deliberate reflection layer** — prio, review, stakeholder, retro. Each mode uses the forcing-question pattern, not an empty template.

> **Reference resolution.** `../../references/*.md` paths resolve inside the `pm-thinking` bundle. If a referenced file does not exist (standalone/flattened install), **say so explicitly** and continue with the rules inlined in this SKILL.md — never improvise the missing file's content; recommend reinstalling the full `pm-thinking` bundle.

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

**Specific application for pm-decide:**
- Mode picker (when the user doesn't pass a flag): label each mode option 1/2/3/4
- Forcing questions in each mode: number each question + letter each option
- Confirmation prompts (push to Notion, send update, etc.): a/b/c options

## Mode picker — when to use which

| Mode | Triggers |
|------|----------|
| `--prio` | "Rank Q3 backlog", "RICE this list", "what should we build first?", "decide next sprint focus" |
| `--review` | "Audit this PRD", "red-team my spec", "anything missing in the PRD?", "is this ready for eng?" |
| `--stakeholder` | "Write a weekly update", "translate progress for exec", "explain status to sales", "monthly leadership report" |
| `--retro` | "Post-mortem feature X", "retro the feature that just launched", "did we hit metric?", "lessons learned" |

If the user doesn't pass a flag, **ask first** which mode they mean. Don't default to one.

---

## Mode 1: `--prio` (Prioritize)

**Role:** Product Lead. **Goal:** rank the backlog with rationale that isn't feel-based.

### Workflow

#### Step 1: Capture the backlog

Sources:
- `.md` / `.csv` file with the list of initiatives
- Notion database link (via Notion MCP)
- BigQuery query for reach metric (if MCP is connected)
- Verbal list from the user

Minimum: every item must have **a name + a 1-line description**. If the user provides a list with only titles and no context, **stop** and ask for a minimum brief per item.

#### Step 2: Pick a framework

Ask the user (AskUserQuestion):

a) **RICE** (Reach × Impact × Confidence ÷ Effort) — most common, needs numbers
b) **ICE** (Impact × Confidence × Ease) — simpler RICE variant, for early-stage
c) **Kano** (Must-Have / Performance / Delighter) — for feature variation, not for strategic prio
d) **Custom** — user defines their own dimensions

#### Step 3: Drive scoring (forcing questions per item)

For **each item** in the backlog, push the PM to answer sharply:

**For RICE:**
1. **Reach:** "How many users will be affected within the relevant time window? Where does the number come from? (Not a guess — query, segment count, etc.)"
2. **Impact:** "If this works, how much will user behavior change? Scale 0.25 / 0.5 / 1 / 2 / 3. Why?"
3. **Confidence:** "How confident are you that Reach × Impact will happen? %. What's the evidence?"
4. **Effort:** "Eng ballpark — person-week. Confirmed by eng or PM guess?"

**If Confidence < 50%:** flag — needs more discovery or experiment first.

**If Effort = "PM guess":** flag — request a sanity check from the engineer-manager skill / eng lead before locking the prio.

#### Step 4: Cross-cutting check

After scoring, ask:

- **"These top 3 items — can they all be worked on together from a capacity / dependency standpoint? Or is something blocking?"**
- **"Are there any items with a LOW score but strategic / commitment to a stakeholder?"** (force explicit override rationale)
- **"Bottom-tier items — which ones most deserve to be killed, not parked?"** (force courage)

#### Step 5: Output

```markdown
# Priority: [list name / sprint / quarter]

**Date:** YYYY-MM-DD
**Framework:** RICE / ICE / Kano
**Decided by:** [PM] with input from [stakeholders]

## Ranked

| # | Item | Reach | Impact | Conf | Effort | Score | Notes |
|---|------|-------|--------|------|--------|-------|-------|
| 1 | ... | ... | ... | ... | ... | ... | ... |

## Top-3 commitment

1. **[Item]** — why first, what's at stake
2. ...

## Low-score, strategic override

- [Item] — why promoted despite low score

## Killed (not parked)

- [Item] — why killing, not parking

## Open dependency / blocker

- [Issue] — owner, deadline

## Next actions

- [ ] Sprint planning kickoff with eng
- [ ] Communicate deprio to [stakeholder]
- [ ] Run /pm-works --spec for top item
```

---

## Mode 2: `--review` (Red-team PRD audit)

**Role:** Senior PM Reviewer. **Goal:** find what's missing / weak in a PRD before handoff.

### Workflow

#### Step 1: Read the PRD

Argument: path to `prd.md` or Notion link. If missing, ask the user.

Read the full content. If the PRD doesn't use the `pm-works` template, it can still be audited — but flag that the structure is non-standard.

#### Step 2: Run the audit checklist

Look at each section, **not summarizing** — but searching for **gaps / weaknesses**.

##### Problem Statement audit
- [ ] Specific user segment (not generic "users")?
- [ ] Evidence cited (quote, data, source)? Not assumption?
- [ ] Cost-of-not-solving proven, not hand-waved?

##### Goals audit
- [ ] Outcome-based, not output-based?
- [ ] Measurable with target + time window?
- [ ] 3-5 goals, not 10+ (dilution risk)?

##### Non-Goals audit
- [ ] Specific enough to prevent scope creep?
- [ ] Rationale per non-goal clear?

##### Requirements audit
- [ ] P0 lean (max 5-7)? If >10, force re-prioritize
- [ ] Acceptance criteria writable as test case?
- [ ] Edge cases / error states covered?

##### Technical Implications audit
- [ ] Schema impact specified?
- [ ] API breaking change flagged?
- [ ] Compliance / privacy reviewed?
- [ ] Existing components affected listed?
- [ ] Effort ballpark realistic / acknowledged as a guess?

##### Success Metrics audit
- [ ] Leading + lagging indicators?
- [ ] Baseline current value documented?
- [ ] Measurement source / query identified?

##### Rollout Plan audit
- [ ] Phasing makes sense (internal → beta → GA)?
- [ ] Kill switch / rollback mechanism?

##### Open Questions audit
- [ ] Owner assigned per question?
- [ ] Blocking vs non-blocking flagged?

##### Handoff section audit
- [ ] PM-locked constraints vs delegated decisions clearly separated?
- [ ] Eng won't get surprised at kickoff?

#### Step 3: Forcing questions to PM

For gaps you find, **don't hand over a checklist of results**, but **trigger AskUserQuestion** or direct questions:

- "You said Reach = 10K users — where does that number come from? Have you ever verified the query?"
- "Your P0 has 12 items. Sure all 12 are really cannot-ship-without? Try killing the 5 that are most cuttable."
- "Tech Implications is empty in the 'Existing components' section — does it really not touch anything, or have you not checked?"

PM answers → update PRD per feedback.

#### Step 4: Output

```markdown
# PRD Review: [PRD name]

**Reviewed:** YYYY-MM-DD
**Reviewer:** /pm-decide --review (AI red team)
**Original PRD:** [path / link]
**Status:** Needs revision / Ready for handoff

## Severity scorecard

- 🔴 **Blocker** — must fix before eng handoff: N issues
- 🟡 **Should fix** — strong recommend: N issues
- 🟢 **Nit** — optional: N issues

## Blocker findings

### B1. [Title]
**Section:** [section name]
**Issue:** [what's wrong / missing]
**Why blocker:** [risk if shipped as-is]
**Fix:** [specific recommendation]

## Should-fix findings
...

## Nit findings
...

## What's strong (so user knows what to keep)

- [Section] — [why solid]

## Recommendation

- [ ] Fix all blockers, then re-run /pm-decide --review
- [ ] OR: proceed to handoff acknowledging [trade-off]
```

---

## Mode 3: `--stakeholder` (Audience-specific update)

**Role:** Comms Lead. **Goal:** translate the same fact into different framings per audience.

### Workflow

#### Step 1: Capture context + audience

Ask:

a) **Audience:**
- `exec` — board / leadership (impact + decision needed)
- `eng` — engineering team (technical detail + dependency)
- `sales` — sales / GTM (customer-facing benefit + timeline)
- `customer` — external user (value + transparency)
- `team` — broad team-wide update (everyone)

b) **What's the update about?**
- File / Notion / verbal: progress, milestone, blocker, launch, escalation
- Period: weekly / monthly / one-off

c) **Cadence:** weekly digest, monthly review, one-time escalation, launch announcement

#### Step 2: Frame per audience

**Audience-aware filter:**

| Audience | Lead with | De-emphasize | Tone |
|----------|-----------|--------------|------|
| Exec | Outcome / impact / decision needed | Implementation detail | Concise, direct, action-oriented |
| Eng | Tech detail, dependency, blocker | Business framing | Specific, technical, no fluff |
| Sales | Customer benefit, timeline, talking points | Internal trade-off | Confident, customer-language |
| Customer | Value, transparency, what's next | Internal politics | Friendly, honest, no jargon |
| Team | Progress, learnings, what's next | Anything siloed | Inclusive, energizing, honest |

#### Step 3: Push back if you spot an off signal

- Update is all-positive even though milestone slipped → "Are you covering up, or do you genuinely not see the risk?"
- Update too detailed for exec → "Cut 60%. Exec needs impact, not log."
- Update too vague for eng → "Specific please — issue ID, file, deadline."

#### Step 4: Output

Different template per audience:

##### Exec / Leadership

```markdown
# [Project] Status — [Date]

**TL;DR:** [1 sentence — on track / at risk / off track + biggest signal]

**Decision needed:** [Yes / No — if yes, fill in below]

## Wins this period
- [Outcome with metric]

## At risk / Off track
- [Issue] — [impact] — [decision needed by [date]]

## What we need from you
- [Specific ask, decision, or unblock]
```

##### Eng

```markdown
# [Project] — Eng Update [Date]

## Shipped
- [Issue ID] — [what shipped]

## In flight
- [Issue ID] — [status, ETA, blocker?]

## Coming up
- [Issue ID] — [scope, dep]

## Blocked / Help wanted
- [Issue] — [what's blocking, who can help]

## Tech context (if relevant)
- [Migration, deprecation, new tooling]
```

##### Sales / GTM

```markdown
# [Feature] — GTM Update [Date]

**ETA:** [date or window]
**Status:** [On track / At risk]

## What's shipping
[1-2 paragraphs in customer-language]

## How to talk about it
- **Lead with:** [key benefit]
- **Avoid:** [what's not in scope yet]
- **Talking point:** [specific scenario]

## Customer-facing date
[When is this announceable]
```

##### Customer

```markdown
# [Feature] is [coming / live]

**For:** [user segment]

[Plain-language explanation: what it does, what problem it solves, what changes]

## What's new
- [Feature] — [benefit]

## What's NOT changing
[Address common worry]

## Need help?
[Support link / contact]
```

##### Team

```markdown
# [Project] Weekly — [Date]

## Wins
- [Outcome]

## Learnings
- [What we learned, what we changed]

## Coming up
- [Next milestone]

## Shoutouts
- [Person] for [thing]
```

---

## Mode 4: `--retro` (Post-launch reflection)

**Role:** Reflective PM. **Goal:** structured reflection — what surprised us, what's the gap.

### Workflow

#### Step 1: Capture launch context

Ask:
- **Feature / project name** + launch date
- **Time since launch** — minimum 1 sprint post-launch (if sooner, retro is premature)
- **Original PRD path / link** — to compare expectation vs reality
- **Metric source** — BigQuery, Amplitude, Notion log

#### Step 2: Pull data (if MCP is connected)

If BigQuery MCP is connected, offer to pull metrics:
- Adoption rate (vs target)
- Activation / completion rate
- Error rate
- Retention impact

User confirms the query. Skill runs it, displays the result.

#### Step 3: Structured reflection (forcing questions)

Push the PM to answer — don't hand over an empty template:

##### Outcome vs hypothesis
1. **"Your hypothesis: [from PRD]. Reality: [data]. What's the gap? Hypothesis confirmed, partially confirmed, or wrong?"**
2. **"If wrong, where do you feel the miss is — discovery, framing, or execution?"**

##### Behavior change
3. **"Behavior you expected: [from PRD]. Behavior observed: [data]. What's the surprise?"**
4. **"Any signal you didn't expect — positive or negative?"**

##### Process
5. **"Execution smooth or chaotic? What was slow / unexpected? Did eng get surprised during build?"** (if yes → flag improvement for Tech Implications next time)
6. **"Stakeholder alignment — execs, sales, customer — as expected or any friction?"**

##### Forward
7. **"If you redid this, what would you change in discovery / PRD / rollout?"**
8. **"What needs fixing now (fast follow), what gets parked, what gets killed?"**

#### Step 4: Output

```markdown
# Retro: [Feature / Project]

**Launched:** YYYY-MM-DD
**Retro date:** YYYY-MM-DD
**Time since launch:** N weeks

## Hypothesis vs Reality

| Hypothesis (from PRD) | Reality (data) | Verdict |
|------------------------|----------------|---------|
| [statement] | [metric / observation] | Confirmed / Partial / Incorrect |

## Metrics scorecard

| Metric | Target | Actual | Gap | Source |
|--------|--------|--------|-----|--------|
| ... | ... | ... | ... | ... |

## What surprised us

- [Positive surprise]
- [Negative surprise]

## What we got right

- [Process / decision that worked]

## What we missed

- [Discovery gap / framing miss / execution issue]
- [Why we missed it — root cause, not blame]

## Process notes (next-time improvement)

- [Tech Implications was [thorough / vague] — improve by [specific change]]
- [Stakeholder alignment was [smooth / friction] — improve by [specific change]]

## Forward decisions

### Fast follow (next sprint)
- [ ] [Item] — owner [name], deadline [date]

### Parked (revisit Q[X])
- [Item]

### Killed
- [Item] — why

## Confidence update

For future similar features: confidence level on [type of bet] is [up / down / unchanged] because [evidence].
```

---

## Anti-pattern (all modes)

- ❌ Template fill-in without forcing questions — you're wasting AI capability
- ❌ Override mode without reason — if you force-skip --review even though there's a blocker, write down the trade-off
- ❌ Same stakeholder update copy-pasted to every audience — that's not comms, that's lazy
- ❌ Retro without data — that's opinion, not retrospective
- ❌ Prio without effort sanity-check from eng — that's wishful thinking

## Tools integration

| Mode | Tool used (if connected) |
|------|--------------------------------------|
| `--prio` | Notion (read backlog), BigQuery (reach numerator) |
| `--review` | Notion (read PRD), if PRD is in Notion |
| `--stakeholder` | Notion (push update to a status page), Slack/Gmail (if MCP exists) — but no auto-send, draft only |
| `--retro` | BigQuery (pull metrics), Notion (push retro page) |

## Downstream handoff

- `priority.md` → input to sprint planning (eng), can be fed into `engineer-manager` skill for capacity check
- `review.md` → if there's a Blocker, back to `/pm-works` for revision
- `update.md` → ready to send / paste, audience-specific
- `retro.md` → input for the next discovery loop (`/pm-discover`)
