---
name: pm-discover
description: Synthesize raw user input (interviews, support tickets, NPS, feedback) into themes and reframe pain into hypothesis. Use when starting a new product investigation, when sitting on a pile of unprocessed user research, when deciding whether to even build something, when validating a feature request before writing a PRD, or when the team keeps debating "what's the real problem here." Pushes back on solution-prescriptive framing — extracts JTBD and opportunity, not feature requests.
---

# /pm-discover

Synthesize raw user research → theme map. Then reframe: reported pain vs actual pain.

> **Reference resolution.** `../../references/*.md` paths resolve inside the `pm-thinking` bundle. If a referenced file does not exist (standalone/flattened install), **say so explicitly** and continue with the rules inlined in this SKILL.md — never improvise the missing file's content; recommend reinstalling the full `pm-thinking` bundle.

Output: `discovery.md` ready to feed into `/pm-works` for writing the PRD.

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

- "I have 25 interview transcripts that need synthesis"
- "Customer is asking for feature X, I want to validate before writing a PRD"
- "Team keeps debating what the actual problem is — I want a structured approach"
- "NPS comments + support tickets piling up, want to find themes"
- "Before prioritizing the backlog, I want to be sure which user pain is on top"

## Workflow — 2 phases

### Phase 1 — Synthesize (raw input → theme)

#### Step 1: Capture raw input

Ask the user one of (or a combination of):

a) **File / URL** — interview transcript, NPS export, support ticket dump, feedback form result
b) **Notion page** — if the user gives a Notion link, read via the `mcp__plugin_operations_notion__*` MCP (if connected)
c) **BigQuery query** — for support volume / NPS distribution / feature request frequency, if the `mcp__plugin_data_bigquery__*` MCP is connected
d) **Verbal dump** — user pastes raw notes / quotes directly in chat

If none of these is available, **stop**. This skill isn't for speculation — it needs real user signal. Tell the user to come back with at least 5 actual user data points (interview snippet, ticket, NPS verbatim, etc.).

#### Step 2: Extract — JTBD (Jobs To Be Done) not features

For each data point, don't write down "user wants X". Capture:

- **Job:** What is the user trying to achieve? (not the tools, the outcome)
- **Trigger:** When does this job arise? (event / situation)
- **Current solution / workaround:** How do they get by today?
- **Pain point:** What makes the current solution insufficient?
- **Verbatim quote:** The user's actual words — keep it raw, don't clean it up

Output table:

| Source | Job | Trigger | Workaround | Pain | Quote |
|--------|-----|---------|------------|------|-------|

#### Step 3: Cluster themes

Group by **shared job + pain**, not by shared feature request. Example:

❌ **Bad cluster:** "Users requesting CSV export"
✅ **Good cluster:** "Users stuck in reporting workflow because they have to copy-paste data into an external spreadsheet"

For each theme, calculate:
- **Frequency:** How many data points mention it?
- **Severity:** Is the workaround cost high or light?
- **Recency:** Recent (last 3 months) or old?

### Phase 2 — Reframe (push back on framing)

Once themes are clustered, **AI swaps hat to Strategist** and asks the PM forcing questions.

#### Forcing questions — must be RAISED, either live or logged in output

In a live session: ask one by one via AskUserQuestion. In batch / async mode: **log explicitly in the output** as a "Forcing Questions Raised" section — so the PM knows what the skill challenged and can reflect on it.

**Question categories (rephrase per scenario, don't copy-paste literally):**

1. **Data quality challenge:** "You said [claim, e.g., '8 interviews']. But the concrete data you pasted is only [N]. Is the gap significant? Bias / gap in the sample?"

2. **Reframe symptom vs cause:** "Theme `[X]` has quote `[Y]`. Is that really about `[X]`, or a symptom of another problem (`[Z]`)?"

3. **Opportunity sizing:** "Is the frequency × severity of this theme enough to justify building? Or vocal minority?"

4. **Success criteria force:** "If you solve this theme, what behavior change happens? Specific metric that will move?"

5. **Red team:** "What might be WRONG with this? If you build it and it doesn't move the needle, what did you miss?"

6. **Cluster validity:** "Is this theme distinct, or does it overlap with another theme?"

**EVERY question the skill raises MUST appear in the "Forcing Questions Raised" section in discovery.md** — not buried in chat history. The PM needs the audit trail to self-reflect and share with the team.

Why important: an invisible forcing question = the PM doesn't know what the skill helped push back on. Visibility = trust + auditability.

#### Output reframing

Each theme gets rewritten as a **Hypothesis Statement**:

```
We believe that [user segment] is struggling with [job] because [pain].
If we [intervention], we expect [behavior change] which we'll measure by [metric].
We're confident in this because [evidence: quote refs + frequency].
```

## Output: `discovery.md`

Write `discovery.md` in the working dir, or push to Notion via MCP if connected. The structure below is **strictly required** — section ordering matters for downstream skill consumption.

```markdown
# Discovery: [topic]

**Date:** YYYY-MM-DD
**Sources:** [list of files / Notion links / BigQuery queries]
**Total data points:** N
**Reframed by:** [PM name]

---

## TL;DR — Pursue Hypothesis

> **Lead with the one to pursue.** A busy PM needs to know in 30 seconds which one to PRD.

**Recommended pursue:** Hypothesis #[X] — [1-line statement]
**Why this one:** [Main evidence: deal value / frequency / severity that wins]
**Next skill:** `/pm-works --spec "[hypothesis #X]"` — spec stub in the final section

---

## Methodology

- Source mix: X interviews + Y tickets + Z NPS verbatims
- Time range: [from – to]
- Notable bias / gap: [e.g., "skewed enterprise, no SMB voice"]
- Data quality flags: [e.g., "PM claims 8 interviews but concrete quotes are only 4 — sample size smaller than reported"]

---

## Forcing Questions Raised

> Visible audit trail — what the skill pushed back on / challenged the PM on.

| # | Category | Question | PM response | Resolution |
|---|----------|----------|-------------|------------|
| 1 | Data quality | "[Q raised]" | "[user response, or 'assumed [X]' if async]" | "[how it shaped the output]" |
| 2 | Reframe | "[Q]" | "[response]" | "[resolution]" |
| ... | | | | |

---

## Themes (ranked by impact × frequency)

### Theme 1: [Job-based label, NOT feature label]
- **Frequency:** N/total mentions
- **Severity:** [High / Med / Low] — based on workaround cost
- **Recency:** [Recent / Mixed / Old]
- **Representative quotes:**
  - "..." — [source ref]
  - "..." — [source ref]

#### JTBD Analysis
- **Job:** [Outcome the user wants to achieve, NOT tool/feature]
- **Trigger:** [Event / situation]
- **Workaround:** [How they get by today]
- **Pain:** [What makes the workaround insufficient]

#### Hypothesis #1
**We believe that** [segment] is struggling with [job] **because** [pain].
**If we** [intervention], **we expect** [behavior change],
**which we'll measure by** [metric, target, time window].
**Confidence:** [High / Med / Low].
**Evidence:**
- [Quote ref + frequency / severity evidence]
- [Industry / market signal if any]

#### Open questions (to validate / strengthen)
- [Q you're not sure about, needs more research]
- *Suggest follow-up:* [specific action — interview who, query what]

### Theme 2: ...

---

## Tech Implications (For Eng Kickoff)

> Must use the **7-section format** from [`../../references/tech-literacy-checklist.md`](../../references/tech-literacy-checklist.md). Not freeform observation. This is for the engineer-manager skill to consume directly.

### 1. Data layer
- Schema impact: [None / New table X / Add column Y to table Z]
- Migration: [Required / None]
- Volume: [Small / Med / Large]
- Sensitive data: [None / PII / payment / health]
- Retention: [If applicable]

### 2. API / Integration
- API contract change: [None / New endpoint / Breaking change]
- Backward compat: [N/A / Required]
- External dependency: [None / [name]]
- Auth model change: [None / [description]]

### 3. Existing components affected
- [Component] — [how affected, owner team]

### 4. Compliance / Privacy / Security
- Touches: [list — none, PII, payment, health, regulated region]
- Required review: [None / Legal / Security / Privacy]

### 5. Performance / Scale
- Concurrent user expectation: [number]
- Latency tolerance: [target]
- Heavy compute: [None / Yes — what]

### 6. Effort ballpark (PM guess)
- [Days / 1-2 weeks / 1 month / 1 quarter / >1 quarter]
- *To be confirmed by engineer-manager skill*

### 7. Open technical questions for eng
- [Q1 — what the PM can't answer]
- [Q2 — ...]

---

## Out-of-scope themes (acknowledged but parked)

### [Theme name]
- **Why parked:** [reason]
- **Solved as side-effect of pursuing Theme #[X]?:** [Yes / No]
- **Revisit when:** [trigger / time window]

---

## Spec stub for `/pm-works --spec`

Copy-paste ready for the next skill:

\`\`\`
Problem: [problem statement from chosen hypothesis]
Success metric: [metric + target + time window]
Constraints:
- [User-facing constraint]
- [Business constraint]
- [Compliance constraint]
\`\`\`

---

**Generated by:** pm-discover
**Ready for:** /pm-works --spec
```

## Tools integration

| Condition | Behavior |
|---------|----------|
| Notion MCP connected | Offer to push `discovery.md` to a Notion page (default: the PM Discovery folder the user points to) |
| BigQuery MCP connected | Offer to pull support ticket / NPS aggregates to validate theme frequency |
| Pencil MCP connected | Skip — discover doesn't need design |
| No MCP available | File saved as local `discovery.md`, user copies manually |

## Anti-pattern (don't do this)

- ❌ Summarizing interviews without clustering themes — that's a summary, not discovery
- ❌ Using a user feature request as-is as a theme — always reframe to job/pain
- ❌ Skipping forcing questions when a theme looks obvious — the obvious themes are often the weakest
- ❌ Recommending "build all themes" — discovery has to be brave enough to prioritize the top 1-2 themes
- ❌ Assuming the user uses "AI tools" / "Notion AI" — we synthesize the raw data ourselves, not delegate it

## Handoff

The `discovery.md` output is a **mandatory input** for `/pm-works --spec`. The hypothesis statement you produce becomes the Problem Statement in the PRD.

If discovery shows a **theme not worth building**, the output is still valid — it means `/pm-decide --prio` gets a valuable "park this theme" input.
