# em-thinking

> **AI-First Engineering Management — opinionated workflow for tech-lead Engineering Managers.**

A bundle that turns Claude into a virtual EM team. **One install** → you immediately get 3 skills: `/em-plan` (architect), `/em-works` (delivery prep), `/em-review` (reviewer + debugger).

Companion to [pm-thinking](https://github.com/verzth/skills/tree/main/pm-thinking) — if pm-thinking turns Claude into a PM team, **em-thinking turns Claude into the EM team that picks up the handoff from PM**.

Inspired by [gstack](https://github.com/garrytan/gstack) (Garry Tan, YC) for cognitive patterns + scope challenge discipline, and [soekarno](https://github.com/verzth/soekarno) for multi-agent process + structured handoff philosophy.

## Philosophy

An AI-First EM is **not an EM who reviews code faster with AI**. An AI-First EM is a **reviewer & synthesizer**: AI drafts the architecture plan, AI synthesizes review issues, AI pushes back with forcing questions — the EM makes the final call.

8 core principles:

1. **AI-First EM = Reviewer & Synthesizer, not Code Writer.**
2. **Reduce Future Pain > Maximize Current Speed.** Compound velocity, not sprint velocity.
3. **Boring by Default, Innovation Tokens Are Scarce** (Tan/McKinley — 3 tokens per company).
4. **Boil the Lake** (Tan) — completeness when AI marginal cost ≈ 0.
5. **EM Owns Architecture & Scope, Not Implementation Detail.** Boundary clear with the `engineer` role.
6. **Forcing Questions > Template.** Push sharp, EM thinks, AI drafts.
7. **Output Handoff-Aware (Role-Based).** Every output references a role (`engineer`, `security-reviewer`, `qa-reviewer`, `release-engineer`/`devops`), not a specific skill name.
8. **Numbered Questions — Anti-Ambiguity.** Tag every question 1/2/3 or a/b/c.

Full detail in [ETHOS.md](./ETHOS.md).

## The 3 skills

| Skill | Specialist role | EM lifecycle stage |
|-------|----------------|---------------------|
| [`/em-plan`](./skills/em-plan/SKILL.md) | **Architect + Risk Classifier** — receive PRD/design/bug → produce **`edd.md` + `edd.html`** (dual: source + review-ready HTML) with risk tier T0-T3, scope challenge, invariants, failure modes, test strategy | Plan |
| [`/em-works`](./skills/em-works/SKILL.md) | **Delivery Lead** — translate plan → execution-ready package (atomic tickets, worktree lanes, env/secrets spec, deploy plan artifact) | Prep |
| [`/em-review`](./skills/em-review/SKILL.md) | **Code Reviewer + Debugger** — Mode A PR review (4-section, against plan, **dual `.md` + `.html` output**), Mode B hypothesis-driven debug (5-step, root-cause-first) | Review / Debug |

## EM lifecycle flow

```
[PM /pm-works] ── prd.md ──┐
                            ▼
                       [/em-plan]
                            │ edd.md
                            ▼
       ┌── (T0 + sensitive) ─┴──── security-reviewer role (parallel)
       │                     │
       │                [/em-works]
       │                     │ eng-works.md + tickets + deploy artifact
       │                     ▼
       │                engineer role ── PRs ──┐
       │                                        ▼
       │                                  [/em-review]
       │                                        │
       │                                ┌───────┴────────┐
       │                          Mode A│                │ Mode B (architectural)
       │                          approve│                │
       │                                ▼                ▼
       │                       release-engineer    [em-plan loop]
       │                       role
       │                                ▼ (post-deploy incident)
       │                          [/em-review Mode B]
       │                                │
       └─── action items ◄──────────────┘
                  │
                  ▼
            [/em-works next sprint]
```

## Risk tier (T0-T3)

| Tier | Surface | Example | Discipline |
|------|---------|---------|------------|
| **T0 — Critical** | Irreversible ops, security boundaries, state machines w/ concurrency, external contracts (idempotency), sensitive data | Critical write path, login/session, distributed lock, webhook receiver | Test-first required. Security review parallel. Postmortem-grade docs. Feature flag/canary deploy. |
| **T1 — High** | Schema migration, breaking API, multi-service coordination | Add NOT NULL column, change response field type | Test strategy explicit. Migration plan. Backward compat. |
| **T2 — Standard** | Single-module additive, isolated surface | New endpoint with flag, internal helper | Standard test coverage. Invariants stated. |
| **T3 — Trivial** | Config / docs / dev tooling | README typo, lint rule | Sanity check only. Fast lane. |

Detail in [references/risk-tiering.md](./references/risk-tiering.md).

## Install — once, get all 3 skills

### Via npm CLI (recommended)

```bash
npx @verzth/skills install em-thinking
```

Pick scope (Global = `~/.claude/skills/em-thinking/`, Project = `./.claude/skills/em-thinking/`).

### Via Claude Code plugin marketplace

```text
/plugin marketplace add https://github.com/verzth/skills.git
/plugin install em-thinking@verzth-skills
```

### Manual (clone + symlink)

```bash
git clone https://github.com/verzth/skills.git ~/.verzth-skills
ln -s ~/.verzth-skills/skills/em-thinking ~/.claude/skills/em-thinking
```

After install, restart Claude Code. The 3 skills will appear:
- `/em-plan`
- `/em-works`
- `/em-review`

### Update

```bash
# npm CLI
npx @verzth/skills install em-thinking  # re-install latest

# Manual
cd ~/.verzth-skills && git pull
```

## Tools integration

em-thinking opportunistically calls connected MCP tools — **if available, used; if not, fall back to manual**:

| Tool | Used by | For what |
|------|-------------|-----------|
| **Notion** | em-plan, em-works, em-review | Push edd/eng-works/pr-review/debug-trace to Notion engineering page |
| **GitHub** | em-review (Mode A) | Auto-fetch PR diff, post review comments inline |
| **Linear / GitHub Issues** | em-works, em-review | Auto-create issue per ticket / regression / process gap |
| **BigQuery** | em-plan, em-review (Mode B) | Validate scale assumption / pull production telemetry for debug evidence |
| **Pencil Dev** | em-plan | Generate visual diagram from ASCII (when user prefers visual) |
| **WebSearch** | em-plan (Phase 2 built-in check) | Search "{framework} {pattern} built-in" before custom solution |

Skills won't ask you to connect tools that aren't there — they go straight to manual mode.

## Boundary: em-thinking vs pm-thinking

pm-thinking ends at **PRD ready (handoff to eng)**. em-thinking starts at **PRD received → edd**.

| pm-thinking owns | em-thinking owns |
|-------------------|-------------------|
| User research synthesis | Architecture & scope |
| JTBD reframing | Risk tier classification |
| PRD writing | Failure modes enumeration |
| Tech Implications (PM-level) | Test strategy |
| Stakeholder updates | Code review (against plan) |
| Prio decisions | Debug investigation |
| Retro | Deploy plan artifact (no execution) |

Cross-handoff:
- pm-thinking PRD → em-plan input
- em-plan scope-reduce → loop back to pm-thinking pm-decide --prio
- em-review Mode B architectural fix → em-plan re-frame

## Boundary: em-thinking vs engineer role

em-thinking does **NOT** dictate implementation detail:

| em-thinking owns | engineer role owns |
|-------------------|---------------------|
| Architecture (boundaries, invariants) | Code style, naming, refactoring choices |
| Test strategy (what to test, coverage targets) | Test implementation (mocks, fixtures) |
| Failure modes (what can go wrong) | Error path implementation |
| Risk tier (T0-T3 classification) | Library micro-choices |
| Scope (in / out) | Function-level decomposition |

EM trusts the engineer to decide *how*, while EM owns *what* and *why*.

## Boundary: em-thinking vs deployment

em-thinking **prepares deploy artifact, doesn't execute**. Deploy execution = `release-engineer` / `devops` role (skill matched per env).

| em-thinking produces | release/devops role executes |
|------------------------|-------------------------------|
| Env vars + secrets spec (with status keywords) | Provisioning in Secrets Manager |
| Migration ID + rollback SQL | Running migration |
| Feature flag definition (name, default, owner) | Creating flag on flag platform |
| Deploy strategy (canary 5%/25%/100%) | Triggering canary |
| Rollback procedure step-by-step | Executing rollback |
| Monitoring dashboard plan | Creating dashboard |

Detail in [references/deploy-prep-checklist.md](./references/deploy-prep-checklist.md).

## References

- [`cognitive-patterns.md`](./references/cognitive-patterns.md) — 15 patterns from Tan / Larson / SRE / Beck / Conway / Brooks (with citation)
- [`risk-tiering.md`](./references/risk-tiering.md) — T0-T3 detail (shared with pm-thinking)
- [`architecture-checklist.md`](./references/architecture-checklist.md) — boundaries / invariants / failure modes / SPOFs
- [`deploy-prep-checklist.md`](./references/deploy-prep-checklist.md) — env / secrets / rollback (artifact spec only)
- [`code-review-rubric.md`](./references/code-review-rubric.md) — 4-section review + severity + decision matrix
- [`debug-playbook.md`](./references/debug-playbook.md) — 5-step investigation + anti-patterns

## License

MIT.
