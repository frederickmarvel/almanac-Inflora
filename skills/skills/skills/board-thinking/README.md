# board-thinking

> Multi-perspective idea diagnostic. Convene a virtual board of 5-7 stakeholder advisors and stress-test an idea from distinct lenses before committing to a PRD or architecture.

## Philosophy

Board Thinking sits between raw ideation and structured product work. It exists because single-voice diagnosis optimizes for one quality dimension — a board surfaces tradeoffs that single voices hide.

1. **Multiple voices, not one.** Minimum 5 board members. Each represents a distinct stakeholder lens.
2. **Productive disagreement is the artifact.** When the Skeptical Customer says "users will switch" and the Operator says "ops burden is brutal," that conflict is the most valuable output.
3. **Verdict reflects answer quality, not founder vibe.** Enthusiastic founder + thin answers = REJECT or APPROVE_WITH_CONDITION.
4. **Cross-examination is the unique value.** Round 2 forces members to react to each other — that's what makes this different from single-voice "office hours" diagnosis.

See [ETHOS.md](./ETHOS.md) for the full philosophy.

## The skill

| Skill | Specialist role | Sprint stage |
|-------|----------------|--------------|
| [`/onboard`](./skills/onboard/SKILL.md) | Board of 5-7 advisors | After raw ideation, before PRD or architecture |

Future versions may add `/board-decide` (between-options trade-off) or `/board-retro` (post-mortem board review).

## Sprint flow

```
raw idea                      ←  user has an unstructured thought
   ↓
/onboard                      ←  board stress-tests from 5-7 lenses
   ↓
verdict: PROCEED / PROCEED_WITH_CONDITIONS / REJECT
   ↓
   ├─→ PROCEED              →  /pm-works (PRD) or /em-plan (architecture)
   ├─→ WITH_CONDITIONS      →  off-tool user interviews, then /pm-discover or re-convene
   └─→ REJECT               →  back to ideation or park
```

## The board roster

Always-on (5 core seats):

| # | Member | Lens |
|---|--------|------|
| 1 | The Skeptical Customer | end-user experience, switching cost |
| 2 | The Cynical Investor | unit economics, CAC, LTV, moat |
| 3 | The Operator | day-2 ops, who runs this at 3am |
| 4 | The Contrarian | disconfirming evidence, steelman against |
| 5 | The Time Traveler | 3-year future state, both endings |

Auto-added when the idea brief signals the domain:

| # | Member | Auto-trigger |
|---|--------|--------------|
| 6 | The Compliance Officer | fintech, health, legal, edu, crypto, insurance |
| 7 | The Technical Architect | enterprise scale, real-time, multi-tenant, ML/AI infra |

The user may swap exactly one member after auto-composition.

**Brand discipline:** persona names are canonical and used verbatim across sessions. The skill does not invent first names (no "Maya," no "Rahmat") or translate persona names — the brand vocabulary is part of what makes the board recognizable across sessions and projects.

## Bilingual output

The runtime memo follows the user's language. Conversation in Indonesian → memo prose in Indonesian-English mix. Conversation in English → English throughout. The skill keeps a small set of items in English regardless of user language to preserve brand and parseability:

- **Persona names** (`The Skeptical Customer`, `The Cynical Investor`, …)
- **Verdict tokens** (`PROCEED`, `PROCEED_WITH_CONDITIONS`, `REJECT`)
- **Memo section anchors** (`## Round 1 — Discovery`, `## Verdicts`, …)
- **Technical domain terms** (`unit economics`, `CAC`, `LTV`, `payback period`, `oncall`, `gross margin`)

Example — Indonesian founder voice, mixed prose:

> **The Cynical Investor** bertanya:
>
> Tunjukkan unit economics untuk ide ini — angka kasar CAC, LTV, payback period. Back-of-napkin pun cukup. Kalau belum ada, sebut saja: itu otomatis jadi salah satu kondisi di verdict.

This is documented exhaustively (with do/don't examples) in [`skills/onboard/SKILL.md`](./skills/onboard/SKILL.md) under the **Language Rule** section.

## Install

### Claude Code (plugin marketplace)

```bash
# Add the verzth-skills marketplace once
/plugin marketplace add verzth/skills

# Install board-thinking
/plugin install board-thinking@verzth-skills
```

### Per-project (manual)

```bash
mkdir -p .claude/skills
cp -r skills/board-thinking .claude/skills/
```

### Update

```bash
/plugin update board-thinking@verzth-skills
```

## Tools integration

| Tool | Used by | For what |
|------|---------|----------|
| `AskUserQuestion` MCP | `/onboard` | Numbered + lettered question format |
| `Bash` | `/onboard` | Detect cwd, branch, find prior memos |
| `Read` | `/onboard` | Read project `CLAUDE.md` for voice/context |
| `Write` / `Edit` | `/onboard` | Write `board-memo-*.md`, apply reviewer fixes |
| `Agent` | `/onboard` | Adversarial reviewer subagent for the spec-review loop |

If `AskUserQuestion` MCP is not available the skill falls back to plain numbered text — same `1. … a) … b) …` format.

## Output

`/onboard` writes one self-contained `board-memo-{YYYYMMDD-HHMMSS}.md` to the working directory. The memo contains:

- Executive summary + verdict
- Idea brief (verbatim from intake)
- Board roster with selection rationale per seat
- Round 1 questions + answers (verbatim)
- Round 2 cross-examination questions + answers (verbatim)
- Verdicts table with vote and one-line reason per member
- Conditions to satisfy (if verdict is `PROCEED_WITH_CONDITIONS`)
- "The most important finding" — the single insight the board surfaced
- "Recommended next action" — one concrete real-world step
- "What the board noticed about how you think" — quoted, mentor-style

If a prior memo exists in the same directory, the new one adds `Supersedes: {prior filename}` to create a revision chain.

## Boundary: board-thinking vs adjacent skills

`board-thinking` does NOT:
- Write a PRD — that's `/pm-works`.
- Lock architecture or risk-tier the work — that's `/em-plan`.
- Synthesize raw user research into themes — that's `/pm-discover`.
- Prioritize a backlog or do stakeholder updates — that's `/pm-decide`.
- Review or debug existing code — that's `/em-review`.

`board-thinking` answers a single question: **"Does this idea survive multi-perspective scrutiny before I commit to building anything?"**

## Versioning

**v0.1.1** ships `/onboard` with:
- 5 always-on members + 2 domain-triggered seats
- One cross-examination round
- Verdict tally + memo with adversarial spec-review loop
- Bilingual runtime output (matches user's language; brand and section anchors stay English)
- Next-skill routing per verdict

Possible future directions:
- **v0.2** — persistent board memory across sessions, optional 8th custom-persona seat
- **v0.3** — multi-round cross-examination, domain-specific persona packs (e.g., "Healthtech Board" with FDA Specialist, Clinical Lead, Reimbursement Strategist)

## License

MIT — see repository root.
