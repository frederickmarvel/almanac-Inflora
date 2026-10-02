# board-thinking — ETHOS

> Productive disagreement between board members is the artifact. A polite roundtable is a failed session.

## 1. Multiple voices, never one

Single-voice diagnosis optimizes for one quality dimension. The Skeptical Customer cares about adoption. The Cynical Investor cares about unit economics. The Operator cares about who's paged at 3am. These lenses pull in different directions — that tension is the value.

**Minimum 5 seats. Maximum 7.** Fewer than 5 means you don't have a board, you have an advisor. More than 7 means the idea is too broad — surface that as a finding.

✅ Good: 5 always-on + 2 domain-triggered when the idea touches regulated industries or claims scale.
❌ Bad: a 3-member board because "I trust these three the most." That's an echo chamber, not a board.

## 2. Cross-examination is the differentiator

Round 1 is discovery. Round 2 is where the board becomes a board. Each member sees what every other member said, then asks a follow-up that surfaces contradiction.

Without Round 2, this skill collapses into a worse version of single-voice diagnosis. The cross-examination round is non-negotiable. The only legitimate reason to skip a member's Round 2 is that their Round 1 answer genuinely doesn't intersect with any other member's lens — and that must be logged in the memo as `Skipped — no productive contradiction surfaced`.

✅ Good: "The Skeptical Customer said users will switch because of X. The Operator said delivering X requires Y ops burden. Reconcile this in unit economics."
❌ Bad: "Based on your answer to Round 1, can you elaborate on Y?" (cites the user, not other members — defeats the purpose)

## 3. Verdicts reflect answer quality, not founder vibe

The founder is in the room and is enthusiastic. That's expected and irrelevant. Votes reflect the evidence in Round 1 + Round 2 answers.

| What I must do | What I must NOT do |
|----------------|-------------------|
| Vote REJECT when answers are thin even if founder is excited | Vote APPROVE because founder seems committed |
| Vote APPROVE_WITH_CONDITION when a gap is specific and closable | Vote APPROVE because "they probably know" |
| Cite the exact gap that triggered a REJECT | Hand-wave with "feels risky" |

The tally rule is mechanical: `≥4 REJECT → REJECT`, `≥4 APPROVE no rejects → PROCEED`, anything else → `PROCEED_WITH_CONDITIONS`. Founder enthusiasm does not override votes.

## 4. Questions cite specifics, not boilerplate

Every Round 1 question must reference at least one specific from the idea brief. Generic survey questions are worthless — the user already has the generic version in their head.

✅ Good: "Citing your idea: 'whitelabel framework for fund asset management in Indonesia.' Describe the closest competitor or workaround a mid-tier fund operator is already using."
❌ Bad: "What's your closest competitor?" (could apply to any idea, signals zero attention)

The reviewer subagent in Phase 6 explicitly rejects generic questions. If the board memo would read like a survey, the skill failed.

## 5. Output is one self-contained artifact, in the working directory

`board-memo-{YYYYMMDD-HHMMSS}.md` lives in the user's project, not in a global cache. This is verzth convention.

The memo is self-contained: a reader who didn't sit through the session can pick it up and know what was asked, what was answered, who voted what, why the verdict landed where it did, and what the next concrete action is.

If a prior board memo exists in the same directory, the new one adds `Supersedes: {prior filename}` — creating a revision chain so the founder can see how the board's view evolved.

## 6. Spec review is adversarial, not affirming

After writing the memo, dispatch a reviewer subagent in a fresh context with only the file path. The reviewer's job is to find issues:

- Are Round 1 questions cited from the idea brief, or generic?
- Do Round 2 questions cite other members, or the user?
- Do verdicts match the evidence?
- Are conditions specific and verifiable, or vague?

Max 3 iterations. If the same issue surfaces twice, stop and persist it as `## Reviewer Concerns` in the memo. Honesty about unresolved concerns beats fake polish.

## 7. REJECT means REJECT — do not route to implementation

A REJECT verdict means the board found a fatal flaw the founder did not address. The handoff for REJECT is never `/em-plan` or `/pm-works`. It is:

- Loop back to raw ideation
- Park the project
- Address the single fatal gap and re-convene the board

Routing REJECT to architecture is the worst thing this skill can do. It would teach founders that the board doesn't matter.

## 8. Numbered questions — anti-ambiguity rule

Every question is numbered, every option is lettered. User responds with combos like `1a, 2c, 3b`. Same rule as `pm-thinking` and `em-thinking`.

✅ Good:
```
1. Stage of the idea?
   a) Pre-product
   b) Has users
   c) Has paying customers
2. Domain hints (multi-select)?
   a) Fintech
   b) Health
   c) Infra
```

❌ Bad:
```
What stage is the idea at, and what's the domain?
```

Use the `AskUserQuestion` MCP tool when available. Fall back to plain numbered text otherwise.

## 9. Speak the user's language at runtime, brand stays English

Package documentation (this file, README, SKILL.md, plugin manifest) is English-only — that's verzth convention and keeps the marketplace consistent.

But when the skill runs, it speaks the user's language. Question bodies, option descriptions, memo prose, AI commentary — all match what the user wrote in.

The exceptions stay English regardless: persona names (`The Skeptical Customer`, `The Cynical Investor`, ...), verdict tokens (`PROCEED`, `REJECT`, ...), and memo section anchors (`## Round 1 — Discovery`, `## Verdicts`, ...). These are brand and parseability concerns — translating them would break cross-session continuity and the "board" identity.

For mixed-language users (e.g., Indonesian engineers mixing Bahasa with English technical terms), don't over-translate. `unit economics`, `CAC`, `LTV`, `payback period`, `oncall`, `regulator` — these stay as-is even in Bahasa prose. The skill matches how the user actually talks, not a textbook version of their language.

✅ Good (Bahasa user):
> **The Cynical Investor** bertanya:
> Tunjukkan unit economics untuk ide ini: angka kasar CAC, LTV, payback period. Back-of-napkin pun boleh. Kalau belum ada, sebut saja — itu jadi kondisi.

❌ Bad:
> **Investor Sinis** bertanya:
> Tunjukkan ekonomi unit untuk ide ini... (persona name diterjemahkan = brand rusak; "ekonomi unit" terdengar asing dibanding "unit economics")

## 10. Discipline at the edges

- One question per member per round. No batching, no multi-part questions.
- ONE AT A TIME. Round 1 and Round 2 each present one member's question, wait for the answer, then move on.
- One swap maximum during board composition. Two or more means the user is gaming the board — warn explicitly.
- The Contrarian is non-negotiable. If the founder asks to remove the Contrarian, that itself is a Round 1 finding.

---

*Board Thinking is not a rubber-stamp roundtable. If your board votes unanimously APPROVE on a thin idea, your board members aren't doing their job — re-convene with a sharper Contrarian.*
