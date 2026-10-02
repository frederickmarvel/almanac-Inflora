# pm-thinking

> **AI-First Product Management — opinionated workflow for tech-literate Product PMs.**

A bundle that turns Claude into a virtual PM team. **One install** → you get 3 skills: `/pm-discover` (researcher), `/pm-works` (senior PM), `/pm-decide` (strategist).

Inspired by [gstack](https://github.com/garrytan/gstack) (Garry Tan, YC). Where gstack turns Claude into an engineering team for builders, **pm-thinking turns Claude into a PM team for product thinkers.**

## Philosophy

An AI-First PM **isn't a PM who writes faster with AI**. An AI-First PM is an **orchestrator**: AI synthesizes raw input, AI drafts, AI pushes back — the PM makes the final call.

Four core principles:

1. **Forcing questions, not templates.** Every skill pushes you to answer sharp questions — it doesn't hand you an empty form to fill out.
2. **Markdown output that feeds the next skill.** `discovery.md` becomes input to `/pm-works`. `prd.md` becomes input to `/pm-decide --review`. Nothing falls through the cracks.
3. **Tech-aware, not tech-decide.** The PM must understand the technical impact (schema, API, backward compat) but doesn't make engineering decisions. Clear boundary to the `engineer-manager` skill.
4. **Numbered questions, anti-ambiguity.** Every question to the user is labeled (1/2/3 or a/b/c). User responds "1a, 2c" — done. Saves effort, keeps audit trail clean.

Full detail in [ETHOS.md](./ETHOS.md).

## The 3 skills

| Skill | Specialist role | Sprint stage |
|-------|----------------|--------------|
| [`/pm-discover`](./pm-discover/SKILL.md) | **User Researcher + Strategist** — synthesizes raw user input, reframes pain → hypothesis | Discover |
| [`/pm-works`](./pm-works/SKILL.md) | **Senior Product PM (tech-literate)** — writes a complete PRD with a Tech Implications section, ready for handoff to engineer-manager | Define |
| [`/pm-decide`](./pm-decide/SKILL.md) | **Product Lead + Reviewer + Comms + Reflective PM** — `--prio` / `--review` / `--stakeholder` / `--retro` modes | Decide / Communicate / Reflect |

## Sprint flow

```
                                                           ┌──────────────────────────┐
                                                           │ /pm-decide --prio        │
                                                           │   (across items, anytime) │
                                                           └──────────────────────────┘
                                                                       ↑
/pm-discover ──→ /pm-works ──→ /pm-decide --review ──→ [HANDOFF ENG-MANAGER]
                                                                       ↓
                                                           ┌──────────────────────────┐
                                                           │ /pm-decide --stakeholder │
                                                           │   (during build)          │
                                                           └──────────────────────────┘
                                                                       ↓
                                                                    [SHIP]
                                                                       ↓
                                                           ┌──────────────────────────┐
                                                           │ /pm-decide --retro       │
                                                           │   (post-launch)           │
                                                           └──────────────────────────┘
```

## Install — once, get 3 skills

### Claude Code (per-user)

```bash
# Clone the verzth/skills repo, place pm-thinking in Claude Code's skills directory
git clone https://github.com/verzth/skills.git ~/.verzth-skills
ln -s ~/.verzth-skills/pm-thinking ~/.claude/skills/pm-thinking
```

After that, restart Claude Code. All three skills will appear:
- `/pm-discover`
- `/pm-works`
- `/pm-decide`

### Cowork (Claude desktop app)

Drop the `pm-thinking/` folder into `~/.claude/skills/`. Since Claude treats every subfolder containing a `SKILL.md` as a skill, installing pm-thinking automatically gives you the 3 skills inside.

### Per-project (team sharing)

From the root of your project repo:

```bash
mkdir -p .claude/skills && ln -s ~/.verzth-skills/pm-thinking .claude/skills/pm-thinking
git add .claude && git commit -m "add pm-thinking skill bundle"
```

Teammates who clone the repo will automatically get all 3 skills once they set up `.verzth-skills` locally.

### Update

```bash
cd ~/.verzth-skills && git pull
```

One pull, all 3 skills update.

## Tools integration

pm-thinking opportunistically calls connected MCP tools — **if available, used; if not, fall back to manual**:

| Tool | Used by | For what |
|------|-------------|-----------|
| **Notion** | discover, works, decide | Read user research notes, write PRD/update/retro pages |
| **BigQuery** | discover, decide (--prio, --retro) | Query support tickets, NPS, post-launch metrics |
| **Pencil Dev** | works | Read mockup links, embed in PRD |

The skill won't ask you to connect tools that aren't there — straight to manual mode.

## Boundary: pm-thinking vs engineer-manager

pm-thinking does **NOT** make technical decisions in the following:
- Choice of database / framework / architecture
- Performance vs cost trade-offs
- Service boundary / API design (at the implementation level)
- Infra / deployment strategy

For all of those, hand off to the `engineer-manager` skill (separate, built independently).

`pm-thinking` only needs to be **aware** of the impact (new schema? backward compat? data privacy?) — so the engineer isn't surprised at kickoff. Detail in [references/handoff-to-eng-manager.md](./references/handoff-to-eng-manager.md).

## License

MIT.
