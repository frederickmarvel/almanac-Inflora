---
name: onboard
description: Board Thinking idea diagnostic. Convene a virtual board of 5-7 stakeholder advisors (Customer, Investor, Operator, Contrarian, Time Traveler + domain seats), each interrogating the idea from a distinct lens. Two rounds of questions plus cross-examination plus board verdict. Use when you have an idea past raw inception but not yet a plan, and need multi-perspective stress test before committing to architecture or scope. Sits between raw ideation and /pm-works (PRD) or /em-plan (architecture). Trigger on "stress test this idea", "what would a board say", "diagnose this from multiple angles", "should I build this", "convene a board", "review this idea from multiple perspectives".
---

# /onboard

Board Thinking — convene a virtual board of 5-7 advisors. Each board member interrogates the idea from a distinct stakeholder lens. Two rounds of questions, cross-examination, then a board verdict (PROCEED / PROCEED_WITH_CONDITIONS / REJECT) plus a board memo.

> "Onboard your virtual board of advisors into your idea. Each board member asks one hard question from their seat. They vote. You leave with a memo and conditions to satisfy."

---

## ⚠ Question Format Rule

**Every question MUST be labeled** — numbered for the question, lettered for the options. Anti-ambiguity rule, applied across all phases.

Use `AskUserQuestion` MCP tool when available. Fall back to plain numbered text otherwise. User responds with combos like `1a, 2c, 3b`.

```
1. [Question]?
   a) Option A
   b) Option B
   c) Other (free text)
```

For Round 1 and Round 2 (qualitative, narrative answers expected), provide 2-3 anchor options like `a) I have specific data on this`, `b) I have an informed guess`, `c) I haven't thought about this` and always include `d) Other` for free text.

---

## Language Rule

**Match the user's language at runtime.** Detect from the user's first message — or from explicit instructions in the prompt (e.g., "the user mixes Bahasa Indonesia and English", "respond in Spanish"). Default to English only when the language signal is truly absent.

This is not a passive observation — it is an active execution instruction. If the prompt signals Indonesian, the question bodies, memo prose, executive summary, conditions, "most important finding", and "what the board noticed" sections MUST be written in Indonesian-English mix. Not a translation of an English draft — natively bilingual prose.

### What stays English regardless of user language
- **Persona names** — `The Skeptical Customer`, `The Cynical Investor`, `The Operator`, `The Contrarian`, `The Time Traveler`, `The Compliance Officer`, `The Technical Architect`. These are brand terms. Use them EXACTLY as written — do not translate, do not invent alternative names (no "Rahmat", no "Maya Chen", no "Investor Sinis"), do not personify with first names. The brand discipline is part of the skill.
- **Verdict tokens** — `PROCEED`, `PROCEED_WITH_CONDITIONS`, `REJECT`, `APPROVE`, `APPROVE_WITH_CONDITION`. Used for parsing and routing.
- **Section anchors in the memo** (`## Round 1 — Discovery`, `## Verdicts`, `## Recommended next action`, etc.) — keep verbatim so the file stays parseable.
- **Option labels** stay alphabetic (`a)`, `b)`, `c)`, `d)`).
- **Technical domain terms** — `unit economics`, `CAC`, `LTV`, `payback period`, `oncall`, `regulator`, `gross margin`, `SaaS`, `MVP`, `PRD`. Keep these as-is even in non-English prose; over-translating sounds foreign.

### What matches the user's language
- **Question bodies** — both Round 1 templates and Round 2 cross-examination prompts.
- **Option text** (the description after `a) ... b) ...`).
- **Memo prose** — executive summary, idea brief restated, vote reasons in the verdicts table, conditions, "most important finding", recommended next action, "what the board noticed about how you think".
- **AI commentary to the user during phases.**

### Worked example — Indonesian-English mix

If the user signals Indonesian, a Round 1 question from The Cynical Investor should look like this, NOT like the English template:

> **The Cynical Investor** bertanya:
>
> Tunjukkan unit economics untuk ide ini — angka kasar CAC, LTV, payback period. Back-of-napkin pun cukup. Kalau belum ada angkanya, sebut saja: itu otomatis jadi salah satu kondisi di verdict.

A verdicts table row should look like this:

> | The Cynical Investor | REJECT | Founder mengaku "no hard numbers" sebelum cross-exam; setelah cross-exam baru muncul gross margin 25-30% dan burn 4-5 tahun — itu bukan thesis SaaS dan tidak di-model sebelum sesi. |

A "most important finding" should look like this:

> Insight terpenting dari sesi ini muncul saat The Skeptical Customer cross-examine: founder mengakui *"I can't reconcile cleanly. If gross margin is 25-30%, we're not really SaaS — we're a services business with software."* Itulah temuan yang founder belum sampai sebelum sesi ini.

Notice: technical terms (`unit economics`, `CAC`, `LTV`, `payback period`, `gross margin`, `SaaS`, `cross-exam`) stay English. Brand persona names (`The Cynical Investor`, `The Skeptical Customer`) stay English verbatim. Verdict token (`REJECT`) stays English. Everything else flows in Indonesian.

❌ **Don't do this** (defaults to English when prompt clearly signaled Indonesian):
> | The Cynical Investor | REJECT | Founder admits "no hard numbers" pre-cross-exam; post-cross-exam reveals 25-30% gross margin and 4-5 year burn. |

❌ **Don't do this either** (translates the brand persona name):
> **Investor Sinis** bertanya: Tunjukkan ekonomi unit...

✅ **Do this** (mixed prose, English brand + technical terms):
> **The Cynical Investor** bertanya: Tunjukkan unit economics untuk ide ini...

---

## When to trigger this skill

- User has an idea past raw inception but not yet a plan (no PRD, no architecture).
- User asks "should I build this", "stress test this", "what would a board say", "convene a board", "review from multiple perspectives".
- A feature request feels too founder-only and needs cross-stakeholder scrutiny before scoping.
- User just finished `/pm-discover` and wants to validate the hypothesis before writing a PRD.
- User wants disconfirming evidence and not just affirmation.

**Do NOT trigger when:**
- User already has a PRD and wants to scope it → use `/pm-works`.
- User already has a plan and wants to lock architecture → use `/em-plan`.
- User wants to synthesize raw user research → use `/pm-discover`.
- User wants single-voice founder-mentor diagnosis → use external office-hours skill.

---

## Workflow — 7 phases

### Phase 0 — Preamble (skinny)

Run once at skill invocation:

1. Detect current working directory (`pwd`).
2. Detect git branch if repo (`git rev-parse --abbrev-ref HEAD 2>/dev/null`).
3. Read `CLAUDE.md` in cwd if present (for project voice/context).
4. Search for prior board memos in cwd: `ls -t board-memo-*.md 2>/dev/null | head -3`. If any exist, capture the most recent filename to add `Supersedes:` lineage in the new memo.
5. Skip any heavy onboarding burst — assume the user is past first-time setup. If user is invoking `/onboard` cold with no project context, that's fine; collect what's needed in Phase 1.

No telemetry prompting. No file writes yet.

---

### Phase 1 — Idea intake

**One AskUserQuestion block** collecting three things:

```
1. Describe the idea in 1-3 sentences. What does it do, who is it for, what's the wedge?
   a) (user types via Other / free text)

2. Stage of the idea?
   a) Pre-product — only an idea, no users
   b) Has users — built something, gathering signal
   c) Has paying customers — revenue exists, scaling question
   d) Other

3. Domain hints (multi-select)?
   a) Fintech / regulated finance
   b) Health / medical / clinical
   c) Infra / dev tools / platform
   d) Consumer SaaS
   e) B2B enterprise
   f) Crypto / web3
   g) Education / legal / insurance
   h) Unregulated other
```

Store the responses as a structured `idea_brief` in conversation state:

```
idea_brief = {
  description: "...",
  stage: "pre-product" | "has-users" | "has-paying-customers",
  domain_hints: ["fintech", "b2b-enterprise", ...]
}
```

**Do not summarize back to the user yet.** Move directly to Phase 2.

---

### Phase 2 — Board composition

Auto-select roster (5-7 members) using the selection logic below, then present for user approval.

**Auto-selection logic:**

```
roster = [SkepticalCustomer, CynicalInvestor, Operator, Contrarian, TimeTraveler]

text = lowercase(idea_brief.description + idea_brief.domain_hints joined)

if text matches /fintech|fund|invest|reksa|crypto|web3|health|medical|legal|edu|insurance|regulated/:
  roster += ComplianceOfficer

if text matches /enterprise|scale|million|real.?time|distributed|microservice|ai infra|ml platform|multi.?tenant/:
  roster += TechnicalArchitect

assert 5 <= len(roster) <= 7
```

**Present to user:**

> Your board for this session:
> 1. **The Skeptical Customer** — end-user lens
> 2. **The Cynical Investor** — capital allocation, unit economics, moat
> 3. **The Operator** — day-2 ops, who runs this at 3am
> 4. **The Contrarian** — disconfirming evidence, steelman against
> 5. **The Time Traveler** — 3-year future state, both endings
> 6. **The Compliance Officer** *(added: idea touches {regulated domain})*
> 7. **The Technical Architect** *(added: idea claims {scale/realtime/etc})*

```
1. How do you want to handle this board?
   a) Accept the board as composed — proceed to Round 1 (recommended)
   b) Swap exactly one member — specify which to remove and what to add (via Other)
   c) Restart composition — re-collect domain hints
```

**Swap rule:** user may swap exactly ONE member. Two or more swaps means the user is gaming the board — warn explicitly and ask whether to proceed with the gamed roster or restart.

---

### Phase 3 — Round 1: Discovery questions

**One AskUserQuestion per board member. ONE AT A TIME.** Do not batch board members into a single question block.

Each question:
- Cites at least one specific from the idea brief (never generic boilerplate).
- Comes from that member's lens only.
- Provides 2-3 anchor options plus `Other` free text.

**Question templates per persona** — always interpolate specifics from `idea_brief`:

**Skeptical Customer:**
> Citing your idea: "{idea snippet}". Describe the closest competitor or workaround the target user is already using today. Why would they switch?

**Cynical Investor:**
> Show me unit economics for {idea}: rough numbers for cost-to-acquire, lifetime value, payback period. Even back-of-napkin counts. If you don't have them, say so — that becomes a condition.

**Operator:**
> Day 30 post-launch of {idea}. The most boring failure happens — DB full, third-party API down, support ticket flood. Walk me through what happens. Who's paged, who handles it, what breaks first?

**Contrarian:**
> Steelman "{idea} should NOT be built." Give me the strongest argument against you — not a strawman. What would a smart skeptic say that you genuinely can't dismiss?

**Time Traveler:**
> It's three years from now. {idea} is either dead or has compounded into something big. Tell me both endings with specifics — who killed it in the dead version, and what did it become in the big version?

**Compliance Officer (if seated):**
> Name the regulator that owns {idea}. Name the specific regulation. What's the worst penalty for getting this wrong? What's your concrete path to compliant launch?

**Technical Architect (if seated):**
> What's the existing open-source or commercial system that already does 60% of {idea}? What's the 40% you're actually building, and why isn't that an extension of the existing thing?

After each answer, store **verbatim** in session state. Do not summarize.

**Per-member format on screen:**

```
**[Member Name]** asks:

{question, interpolated with specifics}

1. How do you want to answer?
   a) I have specific data on this
   b) I have an informed guess
   c) I haven't thought about this yet
   d) Other (free text — your actual answer)
```

If user picks (c) "I haven't thought about this", that becomes an automatic condition in the verdict for this member — track it.

---

### Phase 4 — Round 2: Cross-examination

**The unique value vs single-voice diagnosis.** Each member sees OTHER members' Round 1 answers and asks a follow-up that surfaces contradiction.

For each board member, synthesize ONE reaction question that:
- Cites at least TWO other members' Round 1 answers by name.
- Highlights a tension, contradiction, or unresolved gap.
- Forces the user to reconcile.

**Example cross-examination prompt:**

> **The Cynical Investor** reacts:
>
> "The Skeptical Customer said target users will switch because of {X}. The Operator pointed out that delivering {X} requires {Y ops burden}. Reconcile this in unit economics: what does the gross margin look like if every customer needs {Y} support, and does that still pencil at the CAC you stated?"

**Skip rule:** if you genuinely cannot find a productive contradiction for a member (their Round 1 answer didn't intersect with any other member's lens), SKIP that member's Round 2. But log this in the memo as "Skipped — no productive contradiction surfaced for this member."

**ONE AT A TIME, like Round 1.** Same question format:

```
**[Member Name]** reacts:

{cross-examination question citing 2+ other members by name}

1. How do you want to answer?
   a) I can reconcile this cleanly
   b) Partial answer — gap remains
   c) I can't reconcile — this is a real conflict
   d) Other (free text)
```

Anti-pattern: cross-examination questions that cite the user's own answers instead of other members' answers. Defeats the purpose.

---

### Phase 5 — Board verdict synthesis

**No user input.** AI synthesizes each member's vote based on Round 1 + Round 2 answers.

**Vote rubric per member:**
- **APPROVE** — answer quality is high, no fatal concern, member's lens is satisfied.
- **APPROVE_WITH_CONDITION** — answers are reasonable but one specific gap must close before proceeding.
- **REJECT** — fatal flaw from this lens; founder did not address the core concern.

Show all verdicts in a table:

| Member | Vote | Reason (1 line) |
|--------|------|-----------------|
| Skeptical Customer | APPROVE_WITH_CONDITION | "Switching cost story unclear for top 3 user types — prove with interviews." |
| Cynical Investor | REJECT | "CAC > LTV per stated numbers. Need 3x LTV or 50% CAC cut." |
| ... | ... | ... |

**Tally rule (board verdict):**
- `≥ 4 REJECT votes` → **REJECT** verdict
- `≥ 4 APPROVE votes` (no rejects) → **PROCEED** verdict
- Anything else (mixed, conditionals, 1-3 rejects) → **PROCEED_WITH_CONDITIONS**

**Anti-pattern:** verdicts that follow founder vibe. If founder was enthusiastic but answers were thin, votes reflect answer quality — not enthusiasm.

---

### Phase 6 — Board memo synthesis

Write `board-memo-{YYYYMMDD-HHMMSS}.md` to the working directory using the template in **Output** below.

If a prior memo exists in cwd (captured in Phase 0), add `**Supersedes:** {prior filename}` to the frontmatter section to create a revision chain.

**Spec review loop (adversarial, max 3 iterations):**

1. After writing the memo, dispatch a reviewer subagent (via `Agent` tool, fresh context, no conversation history) with only the file path. Reviewer checks:
   - Each Round 1 question cites real specifics from the idea brief (not generic).
   - Each Round 2 question cites OTHER members' answers (not the user's own).
   - Verdicts match the evidence in Round 1 + Round 2 answers, not founder vibe.
   - Conditions are specific and verifiable (not vague aspirations like "improve marketing").
   - Tally rule applied correctly.
2. If reviewer raises issues, fix with `Edit` and re-dispatch. **Maximum 3 iterations.** Convergence guard: if the same issue surfaces twice, stop, persist remaining concerns as a `## Reviewer Concerns` section in the memo.
3. If subagent dispatch is unavailable, skip with a one-line note: "Spec review unavailable — presenting unreviewed memo." Review is a bonus, not a gate.
4. After convergence, tell user: `"Memo survived N rounds of adversarial review. M issues caught and fixed. Quality score: X/10."`

---

### Phase 7 — Handoff

Present the memo path to the user and offer next steps.

```
1. The board memo is at `./board-memo-{YYYYMMDD-HHMMSS}.md`. What next?
   a) Accept the memo and route to the recommended next skill (recommended)
   b) Revise specific sections — tell me which
   c) Re-convene the board with a different roster — back to Phase 2
   d) Other
```

**Next-skill routing by verdict:**
- **PROCEED** → recommend `/em-plan` (lock architecture) or `/pm-works` (write the PRD).
- **PROCEED_WITH_CONDITIONS** → top condition usually needs user research first. If conditions are demand-side, suggest off-tool user interviews then `/pm-discover` when signal collected. If conditions are technical, route to `/em-plan` for scoped exploration.
- **REJECT** → do NOT recommend implementation. Suggest the user either rethink the idea (back to raw ideation), park the project, or — if a single dimension was fatal — address that gap and re-convene the board.

---

## Output: `board-memo-{YYYYMMDD-HHMMSS}.md`

Written to the current working directory. Self-contained, no external deps.

```markdown
# Board Memo: {idea title}

**Date:** {YYYY-MM-DD}
**Branch:** {branch or "no-repo"}
**Supersedes:** {prior board memo filename, or "none"}

**VERDICT:** {PROCEED | PROCEED_WITH_CONDITIONS | REJECT}

---

## Executive summary

{2-3 sentences. Lead with verdict and the single issue that mattered most. A busy reader should know the bottom line in 15 seconds.}

---

## Idea brief

{from Phase 1, verbatim}

**Stage:** {pre-product | has users | has paying customers}
**Domain hints:** {comma-separated}

---

## Board roster

| # | Member | Why selected |
|---|--------|-------------|
| 1 | The Skeptical Customer | always-on |
| 2 | The Cynical Investor | always-on |
| 3 | The Operator | always-on |
| 4 | The Contrarian | always-on |
| 5 | The Time Traveler | always-on |
| 6 | The Compliance Officer | added: idea touches {regulated domain} |
| 7 | The Technical Architect | added: idea claims {scale/realtime/etc} |

---

## Round 1 — Discovery

### {Member name}
**Q:** {question asked, verbatim}
**A:** {user's answer, verbatim}

[repeat for each member]

---

## Round 2 — Cross-examination

### {Member name}
**Q:** {cross-examination question — must cite OTHER members' findings}
**A:** {user's answer, verbatim}

{or: "Skipped — no productive contradiction surfaced for this member."}

[repeat for each member]

---

## Verdicts

| Member | Vote | Reason |
|--------|------|--------|
| ... | ... | ... |

**Tally:** {N approve / N conditional / N reject} → **{verdict}**

---

## Conditions to satisfy (if PROCEED_WITH_CONDITIONS)

1. **{condition title}** — raised by {member}. Satisfied when: {specific verifiable criterion}.
2. **{condition title}** — raised by {member}. Satisfied when: {...}.

---

## The most important finding

{The single insight the board surfaced that the founder did not have before this session. Quote from cross-examination if possible. This is the "aha" — what the founder takes home even if they ignore the rest.}

---

## Recommended next action

{ONE concrete real-world action. Not "go build it." Examples: "Interview 5 fund operators and ask 'what's your most embarrassing operational workaround?'" — or — "Build a 1-page landing with calendly link and run $200 of ads; if no demo bookings in 7 days, kill."}

---

## What the board noticed about how you think

{2-4 mentor-style bullets quoting the user's own words from the session. Observational, not judgmental. Quote the user back to themselves — don't characterize their behavior.}

---

## Reviewer Concerns

{Optional section. Only present if spec review loop hit the convergence guard with unresolved issues. List them with the reviewer's exact concern and why they remain.}

---

**Generated by:** /onboard (Board Thinking v0.1)
**Ready for:** {/em-plan | /pm-works | back to raw ideation | re-convene board}
```

---

## The Board Roster — full reference

### Always-on (5 core seats)

**1. The Skeptical Customer**
- **Lens:** End-user experience.
- **Probes:** switching cost, current workaround, what would force adoption.
- **Failure mode if missing:** founder believes users will switch without proof.

**2. The Cynical Investor**
- **Lens:** Capital allocation, unit economics, moat.
- **Probes:** CAC, LTV, payback period, defensibility.
- **Failure mode if missing:** beautiful product, broken business.

**3. The Operator**
- **Lens:** Day-2 operations. Who runs this thing at 3am.
- **Probes:** monitoring, oncall, support burden, failure modes.
- **Failure mode if missing:** ships, then drowns in ops cost.

**4. The Contrarian**
- **Lens:** Disconfirming evidence. Always argues opposite the founder.
- **Probes:** the steelman against building this.
- **Failure mode if missing:** founder echo chamber.

**5. The Time Traveler**
- **Lens:** 3-year future state — both endings (success and post-mortem).
- **Probes:** market trajectory, second-order effects, exit conditions.
- **Failure mode if missing:** local-maximum thinking, no long horizon.

### Domain-triggered (auto-add when relevant)

**6. The Compliance Officer**
- **Auto-add when:** idea touches fintech, health, legal, education, crypto, insurance, regulated industries.
- **Lens:** Regulatory risk, license requirements, worst-case penalty.

**7. The Technical Architect**
- **Auto-add when:** idea claims enterprise scale, real-time, multi-tenant, ML/AI infra, distributed systems.
- **Lens:** What exists already, build-vs-buy, scaling bottleneck.

---

## Tools integration

| Tool | Used by | For what |
|------|---------|----------|
| `AskUserQuestion` MCP | Phases 1, 2, 3, 4, 7 | Numbered+lettered question format |
| `Bash` | Phase 0, Phase 6 | Detect cwd, branch, prior memos, write file |
| `Read` | Phase 0 | Read `CLAUDE.md` for project context |
| `Write` | Phase 6 | Write `board-memo-*.md` |
| `Edit` | Phase 6 (spec review) | Apply reviewer fixes |
| `Agent` | Phase 6 (spec review) | Dispatch adversarial reviewer subagent |

If `AskUserQuestion` MCP is not available, fall back to plain numbered text — same `1. ... a) ... b) ...` format, user responds with combos.

---

## Anti-pattern (don't do this)

- ❌ **Generic Round 1 questions.** Each must cite specifics from the idea brief. "What's your CAC?" is not the question — "Show me CAC for your stated wedge of {X}" is.
- ❌ **Skipping Round 2.** Cross-examination is the unique value vs single-voice diagnosis. Skipping it collapses the skill into a worse version of office-hours.
- ❌ **Round 2 questions that cite the user's own answers instead of other members'.** Defeats the purpose. Always reference at least two other board members by name.
- ❌ **Verdicts that follow founder vibe.** Enthusiastic founder + thin answers = REJECT or APPROVE_WITH_CONDITION, never APPROVE.
- ❌ **Recommending implementation after REJECT.** Never route a REJECT verdict to `/em-plan` or `/pm-works`. Loop back to ideation or park.
- ❌ **Auto-selecting more than 7 members.** Discipline matters. If you feel 8 lenses are needed, the idea is too broad — surface that as a Round 1 finding via the Contrarian.
- ❌ **Letting one member dominate.** Round-robin strictly. One question per member per round.
- ❌ **Batching board members into a single AskUserQuestion block.** ONE AT A TIME — both rounds.
- ❌ **Skipping the spec review loop on the memo.** Memo is the takeaway artifact; quality matters. Skip only if subagent dispatch is unavailable.
- ❌ **Persisting the memo outside the working directory.** Verzth convention: write to cwd, not `~/.gstack/` or any global path.

---

## Handoff

After Phase 7 acceptance, route by verdict:

| Verdict | Next skill | Why |
|---------|-----------|-----|
| **PROCEED** | `/em-plan` or `/pm-works` | Idea survived board scrutiny; lock architecture or write PRD |
| **PROCEED_WITH_CONDITIONS** | Off-tool work (user interviews, unit economics math), then return to `/pm-discover` or re-convene `/onboard` | Conditions must close before architecture |
| **REJECT** | Back to raw ideation OR park the project | Do NOT recommend implementation |

**Handoff footer in memo (verbatim):**

```
**Generated by:** /onboard (Board Thinking v0.1)
**Ready for:** {next skill per routing table}
```

---

*Board Thinking is not a rubber-stamp roundtable. Productive disagreement between board members is the unique value. If your board votes unanimously APPROVE on a thin idea, your board members aren't doing their job — re-convene with a sharper Contrarian.*
