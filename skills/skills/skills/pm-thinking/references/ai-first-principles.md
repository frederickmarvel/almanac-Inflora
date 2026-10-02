# AI-First PM Principles

Reference doc for every skill in `pm-thinking`. Read this once so you know the thinking behind the forcing questions.

---

## 1. PM = Orchestrator, AI = Team

Traditional PM: writes a PRD from a blank doc, manually synthesizes interviews, reads thousands of tickets.
AI-First PM: directs the AI, AI does the assembly, the PM makes the final call.

**Implication:**
- Every skill in pm-thinking doesn't hand you an empty template to fill in
- The skill directs, pushes, challenges — you respond, AI assembles
- You evaluate, AI iterates

---

## 2. Forcing Questions > Template Fill-In

A skill that gives an empty template = you're still doing the AI's work.
A skill that pushes a forcing question = you think sharper, AI assembles.

**Contrast example:**

❌ Template-style:
> "Fill in: Problem Statement, Goals, Non-Goals, Acceptance Criteria..."

✅ Forcing-question style:
> "You said the user wants CSV export. But: when did you last interview them? Is CSV the solution or the request? What's the real pain?"

A forcing question forces you back to the root cause before AI writes anything.

---

## 3. Markdown Output That's Self-Aware About Its Reader

Every skill output **must know** who reads it next:

- `discovery.md` → read by `/pm-works` when writing the PRD
- `prd.md` → read by `/pm-decide --review` (audit) and the `engineer-manager` skill (technical design)
- `priority.md` → read by the team for sprint planning
- `update.md` → delivered to a specific audience
- `retro.md` → fed into the next discovery loop

If output can be fed directly into the next skill without manual editing, **the output is good**. If not, redesign.

---

## 4. Tech-Aware, Not Tech-Decide

A tech-literate Product PM **must think** about the technical impact of their spec, **doesn't make** engineering decisions.

| PM **must** know | PM **does NOT** decide |
|-------------------|------------------------|
| "Does this need a new schema?" | "Postgres or Mongo?" |
| "API contract change? Backward compat?" | "REST or gRPC?" |
| "Data privacy / compliance impact?" | "Where's the service boundary?" |
| "Existing component to reuse?" | "Microservices or monolith?" |
| "Effort ballpark — week or month?" | "What's the tech stack?" |

Detail in [tech-literacy-checklist.md](./tech-literacy-checklist.md).

---

## 5. Push Back, Not Yes-Man

Skills in pm-thinking **must push back** on the PM when:

- Framing is too solution-prescriptive ("user wants a dropdown" → "why? what are they trying to achieve?")
- Assumptions aren't validated ("retention will rise 30%" → "based on what?")
- Scope is too broad ("can this be broken into v1, v2, v3?")
- Success metric is vague ("improve UX" → "how do you measure it, what's the target, what's the time window?")
- Confidence is low but still pushed for prio ("RICE confidence 30%, more discovery needed first")

The AI-First PM learns to be challenged by AI as hard as by a senior PM. That's the value of this workflow.

---

## 6. Conditional Tool Usage

MCP integration is **opportunistic**:
- Connected → used automatically (no asking)
- Not connected → fall back to manual mode (no nagging to connect)

Reason: friction kills workflow. The skill runs on a fresh laptop with no setup, becomes more powerful as soon as tools come online.

---

## 7. Note: English Style (Casual Narrative + Formal Tables)

Skills in this bundle use English throughout. Style guide:

- **Narrative/explanation**: casual professional. "You should...", "if X, do Y." Direct, opinionated, short sentences.
- **Tables / structured lists**: formal English. Consistent voice.
- **Code blocks, frontmatter, anchors**: unchanged technical anchors.
- **Forcing questions**: numbered (per principle on numbered questions), with concrete options (a/b/c).

The previous "Bahasa Mixed" convention (English structure + Indonesian narrative) was deprecated in v1.5.0 for international accessibility.

---

## 8. Numbered Questions — Anti-Ambiguity

**Rule:** Every question to the user **MUST** be tagged with a unique label (1/2/3 or a/b/c) so the user can respond by pointing to a specific label.

**Why:**
- The PM user is busy — skim, not read in full
- Number = persistent reference, easy to prioritize answers
- Reduces ambiguity in the AI parser ("1c, 2b" vs "yes for the first, at risk for second")
- Cleaner audit trail

**Apply on:**
- Forcing questions in all modes
- Gather context phase
- Mode picker (when the user doesn't pass a flag)
- Confirmation prompt before pushing to an external tool

**Tool preference:** Use the `AskUserQuestion` MCP if available — auto-renders multi-choice. Fall back to numbered text format if unavailable.

**Format reference:**
```
1. [First question]?
   a) Option A
   b) Option B
   c) Option C

2. [Second question]?
   a) ...
```

User: "1b, 2c" → done.

---

## 9. Boundary to the Engineer-Manager Skill

pm-thinking does **NOT** make technical decisions in:
- Choice of database / framework / architecture
- Performance vs cost trade-offs
- Service boundary / API design at the implementation level
- Infra / deployment strategy

For all of those, hand off to the `engineer-manager` skill (separate, to be built independently later).

`pm-thinking` only needs to be **aware** of the impact (new schema? backward compat? data privacy?) — so the engineer isn't surprised at kickoff.

Detail of the handoff contract in [handoff-to-eng-manager.md](./handoff-to-eng-manager.md).
