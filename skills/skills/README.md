<p align="center">
  <h1 align="center">@verzth/skills</h1>
  <p align="center">
    Curated collection of custom skills for Claude Code, Cowork, OpenClaw &amp; Hermes Agent
    <br />
    <a href="https://www.npmjs.com/package/@verzth/skills"><strong>npm</strong></a> · <a href="https://github.com/verzth/skills/issues"><strong>Issues</strong></a>
  </p>
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/@verzth/skills"><img src="https://img.shields.io/npm/v/@verzth/skills?style=flat-square&color=blue" alt="npm version" /></a>
  <a href="https://github.com/verzth/skills/blob/main/LICENSE"><img src="https://img.shields.io/github/license/verzth/skills?style=flat-square" alt="license" /></a>
  <a href="https://www.npmjs.com/package/@verzth/skills"><img src="https://img.shields.io/npm/dm/@verzth/skills?style=flat-square" alt="downloads" /></a>
</p>

---

## What is this?

A plug-and-play skill registry for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Cowork](https://claude.ai), [OpenClaw](https://openclaw.ai), and [Hermes Agent](https://hermes-agent.org/). Each skill extends the AI's behavior with domain-specific frameworks, workflows, and personality — installed with a single command.

**Four install paths supported:**
- **npm CLI** — `npx @verzth/skills install <name>`
- **Claude Code plugin marketplace** — `/plugin install <name>@verzth-skills`
- **OpenClaw** — `npx @verzth/skills install <name> --openclaw`
- **Hermes Agent** — `npx @verzth/skills install <name> --hermes`, `hermes skills install github:verzth/skills/skills/<name>` *(native)*, or `bash install.sh --hermes <name>`

## Available skills

| Skill | Type | Description |
|-------|------|-------------|
| `humanoid-thinking` | single | Human cognitive framework — intuition-first, validated by logic |
| `golang-developer` | single | Go microservices development (Clean Architecture, gRPC, Wire DI) |
| `pm-thinking` | bundle | AI-First Product Management — pm-discover, pm-works, pm-decide |
| `em-thinking` | bundle | AI-First Engineering Management — em-plan, em-works, em-review |
| `public-awareness` | single | Artifact integrity guardrail — keeps internal working context out of public-facing artifacts |
| `board-thinking` | bundle | Board Thinking idea diagnostic — convene a virtual board of 5-7 advisors (`/onboard`) to stress-test an idea before PRD or architecture |
| `cso-thinking` | bundle | CSO mindset security audit — single command (`/cso-audit`) covers frontend / backend / infra / db / Android / iOS / generic; emits SECURITY_AUDIT.md + .html with score, audit list, and fix-ready remediation prompts |
| `mockerize` | single | Mockup-to-production UI — visual fidelity at the reference viewport, responsive constraints elsewhere, and real frontend-backend integration |

> Want something else? [Request a skill →](https://github.com/verzth/skills/issues/new)

## Quick Start (npm)

```bash
npx @verzth/skills install humanoid-thinking
```

You'll be prompted to choose where to install:

```
Where do you want to install?
  1) Global  → ~/.claude/skills/ (available in all projects)
  2) Project → ./.claude/skills/ (current project only)

Choose [1/2]:
```

Or skip the prompt with flags:

```bash
npx @verzth/skills install humanoid-thinking --global    # all projects
npx @verzth/skills install humanoid-thinking --project   # current project only
```

## Usage

```bash
# Install a specific skill
npx @verzth/skills install <skill-name>

# Install multiple skills
npx @verzth/skills install humanoid-thinking <other-skill>

# Install all available skills
npx @verzth/skills install --all

# Update one or all installed skills
npx @verzth/skills update <skill-name>
npx @verzth/skills update

# List available skills
npx @verzth/skills list
```

### Flags

| Flag | Short | Description |
|------|-------|-------------|
| `--global` | `-g` | Install to `~/.claude/skills/` — available across all projects |
| `--project` | `-p` | Install to `./.claude/skills/` — scoped to current project only |
| `--openclaw` | `-o` | Install for OpenClaw with adapted content |
| `--hermes` | `-H` | Install for Hermes Agent (path switch to `.hermes/skills/`; no content adaptation needed) |

Flags can be combined: `--openclaw --global` installs adapted skill to `~/.openclaw/skills/`. `--openclaw` and `--hermes` are mutually exclusive (run twice if you want both).

When no scope flag is provided and the session is interactive, the CLI prompts you to choose. In non-interactive environments (CI/CD, piped input), it auto-detects based on whether `.claude/`, `.openclaw/`, or `.hermes/` exists in the current directory.

## Install via Claude Code plugin marketplace

If you prefer the native plugin marketplace mechanism in Claude Code:

```
# Add this repo as a marketplace (one-time)
/plugin marketplace add https://github.com/verzth/skills.git

# Install any skill
/plugin install humanoid-thinking@verzth-skills
/plugin install golang-developer@verzth-skills
/plugin install pm-thinking@verzth-skills
/plugin install em-thinking@verzth-skills
/plugin install public-awareness@verzth-skills
/plugin install board-thinking@verzth-skills
/plugin install cso-thinking@verzth-skills
/plugin install mockerize@verzth-skills
```

Update later:
```
/plugin marketplace update verzth-skills
/plugin update <skill-name>@verzth-skills
```

Marketplace catalog: [`.claude-plugin/marketplace.json`](./.claude-plugin/marketplace.json)

### Install for OpenClaw

```bash
# Global (recommended)
npx @verzth/skills install public-awareness --openclaw --global

# Project-scoped
npx @verzth/skills install public-awareness --openclaw --project
```

The `--openclaw` flag adapts skill content at install time:
- Installs to `~/.openclaw/skills/` or `.openclaw/skills/`
- Rewrites tool names: `Bash` → `exec`, `Write` → `write`, `Agent` → `sessions_spawn`, `TodoWrite` → `task tracker`
- Rewrites paths: `.claude/` → `.openclaw/`, `CLAUDE.md` → `AGENTS.md`
- Normalizes frontmatter: only `name`, `description`, and `version` are kept

### Install for Hermes Agent

Hermes Agent reads the same `SKILL.md` + YAML frontmatter + `references/` format Claude Code uses — no content adaptation needed. Three install paths:

**1. Native Hermes CLI** (recommended — uses Hermes' own dependency/update tracking):

```bash
hermes skills install github:verzth/skills/skills/golang-developer
hermes skills install github:verzth/skills/skills/cso-thinking
hermes skills list
```

**2. Our curl one-liner** (drops files into `~/.hermes/skills/` directly):

```bash
# Install one
curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash -s -- --hermes humanoid-thinking

# Install all
curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash -s -- --hermes
```

**3. npm CLI**:

```bash
npx @verzth/skills install humanoid-thinking --hermes --global
```

Hermes looks for skills in `~/.hermes/skills/` by default (configurable via `skills.external_dirs` in Hermes' `config.yaml`).

### Already using Claude Code? Add Hermes too

If you've already installed these skills into `~/.claude/skills/` and want to use them in Hermes without re-downloading, you have three options:

**Option A — Symlink** (recommended; one source of truth, updates flow automatically):

```bash
# Per-skill
mkdir -p ~/.hermes/skills
for skill in humanoid-thinking golang-developer pm-thinking em-thinking public-awareness board-thinking cso-thinking mockerize; do
  [ -d ~/.claude/skills/$skill ] && ln -sfn ~/.claude/skills/$skill ~/.hermes/skills/$skill
done
```

When you later run `npx @verzth/skills update` or re-curl, the change to `~/.claude/skills/<skill>` is instantly visible to Hermes — no second install step.

**Option B — Add `external_dirs` to Hermes config** (cleanest; zero file duplication):

```yaml
# ~/.hermes/config.yaml
skills:
  external_dirs:
    - ~/.claude/skills
```

Hermes will load skills from both `~/.hermes/skills/` AND `~/.claude/skills/`. Same single-source-of-truth benefit as symlinks, with no FS clutter.

**Option C — Re-install via Hermes flag** (independent copies; useful if you want per-runtime overrides):

```bash
curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash -s -- --hermes
```

This drops fresh copies into `~/.hermes/skills/`. You then maintain them separately from your `.claude/skills/` set. Pick this only if you intend to diverge the two installs (e.g., test a new version in Hermes before promoting it to Claude).

### Alternative Install Methods

<details>
<summary><strong>curl (Claude Code)</strong></summary>

```bash
# Install all
curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash

# Install specific skill
curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash -s -- humanoid-thinking
```
</details>

<details>
<summary><strong>curl (OpenClaw)</strong></summary>

```bash
# Install specific skill for OpenClaw
curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash -s -- --openclaw public-awareness
```

> Note: curl installs change the install path but skip content adaptation (tool name rewrites). For fully adapted content, use `npx @verzth/skills install <name> --openclaw`.
</details>

<details>
<summary><strong>curl (Hermes Agent)</strong></summary>

```bash
# Install specific skill for Hermes
curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash -s -- --hermes humanoid-thinking

# Install all skills for Hermes
curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash -s -- --hermes
```

> Hermes reads `SKILL.md` natively, so both curl and the npm CLI install skill content without an adaptation step. Or use the Hermes-native CLI: `hermes skills install github:verzth/skills/skills/<name>`.
</details>

<details>
<summary><strong>git clone</strong></summary>

```bash
git clone https://github.com/verzth/skills.git /tmp/verzth-skills
cp -r /tmp/verzth-skills/skills/humanoid-thinking .claude/skills/humanoid-thinking
```
</details>

## How Skills Work

Each skill contains YAML frontmatter with the required `name` and `description` fields; runtimes or installers may add an optional `version`. A skill may also include `references/`, `scripts/`, `assets/`, `templates/`, or evaluation files. The runtime loads `SKILL.md` when its description matches the user's request.

| Runtime | Skill directory | Loader |
|---|---|---|
| Claude Code & Cowork | `~/.claude/skills/` (global) or `./.claude/skills/` (project) | Built-in skill loader |
| OpenClaw | `~/.openclaw/skills/` or `./.openclaw/skills/` | Built-in (with `--openclaw` content adaptation) |
| Hermes Agent | `~/.hermes/skills/` (and any `skills.external_dirs` configured in `~/.hermes/config.yaml`) | Native; reads SKILL.md unchanged |

**Global** skills are active in every project on your machine. **Project** skills only activate when the agent is working in that specific project directory.

### Upgrade-safe

The installer automatically backs up and restores your `personality.md` configuration when upgrading skills, so your personalized settings are never lost.

## Skill: humanoid-thinking

The flagship skill. Makes Claude think with human-like common sense instead of exhaustively exploring every possibility.

**What it does:**
- **Framework HATI** (Human-Aware Thinking & Intuition) — a 4-step cognitive process: Tangkap → Intuisi → Validasi → Sampaikan
- **Smart confirmation** — asks follow-up questions only when genuinely ambiguous, not for things that are obvious from context
- **Personality system** — on first use, runs an onboarding flow where you name your agent, set communication style, language, and detail level. All preferences persist across sessions.

**Example:**
> *User:* "Mau cuci mobil, enaknya jalan kaki atau naik mobil?"
>
> *Without skill:* Analyzes both options, considers walking distance, pickup services, exercise benefits...
>
> *With skill:* "Naik mobil — mobilnya harus dibawa ke sana."

[Read full documentation →](./skills/humanoid-thinking/SKILL.md)

## Skill: golang-developer

An opinionated Go microservices development skill that enforces production-proven patterns across your entire Go codebase.

**What it does:**
- **Clean Architecture** — strict layering: entity → repository → service → handler, with Google Wire for compile-time DI
- **gRPC + grpc-gateway** — three-tier API design (Admin/Insider/Public) with buf for proto management and OpenAPI generation
- **Production stack** — GORM + MySQL, NATS JetStream for event streaming, Redis for caching and distributed locking
- **Comprehensive references** — covers entity patterns, repository patterns, service patterns, scheduler patterns, testing, infrastructure, and provider integration

**Covers:** scaffolding, code review, debugging, testing, and architecture guidance for Go microservices.

[Read full documentation →](./skills/golang-developer/SKILL.md)

## Skill: pm-thinking

A bundle that turns Claude into a virtual PM team. **One install → 3 sub-skills**: `/pm-discover` (researcher), `/pm-works` (senior PM), `/pm-decide` (strategist).

**What it does:**
- **Forcing questions, not templates** — each skill pushes you to answer sharp questions instead of filling out blank forms
- **Markdown handoffs between skills** — `discovery.md` feeds `/pm-works`, `prd.md` feeds `/pm-decide --review`, nothing falls through the cracks
- **Tech-aware, not tech-decide** — PMs understand technical impact (schema, API, backward compat) without making engineering decisions; clear boundary to a separate `engineer-manager` skill
- **Multi-mode `/pm-decide`** — `--prio` (prioritization), `--review` (PRD review), `--stakeholder` (updates), `--retro` (post-launch reflection)
- **Numbered questions, anti-ambiguity** — every question to the user is labeled (1/2/3 or a/b/c) so responses like "1a, 2c" stay precise and audit-friendly

**Sprint flow:** `/pm-discover` → `/pm-works` → `/pm-decide --review` → handoff to engineering → `/pm-decide --stakeholder` during build → `/pm-decide --retro` after ship.

[Read full documentation →](./skills/pm-thinking/README.md)

## Skill: em-thinking

A bundle that turns Claude into a virtual EM team. **One install → 3 sub-skills**: `/em-plan` (architect), `/em-works` (delivery prep), `/em-review` (reviewer + debugger). Companion to pm-thinking — picks up where PRD ends.

**What it does:**
- **EDD as PRD's parallel (dual `.md` + `.html` output)** — `/em-plan` produces `edd.md` + `edd.html` (Engineering Design Document) with risk tier (T0-T3), scope challenge, invariants, failure modes table, test strategy, and ASCII diagrams for component boundaries / data flow / state machine. HTML is self-contained (inline CSS, color-coded T0-T3 risk badges, ASCII diagram styling, TOC + breadcrumb, print-friendly) for human review
- **15 cognitive patterns from canonical sources** — State Diagnosis (Larson), Boring by Default (McKinley), Failure is Information (Allspaw/SRE), Make Change Easy (Beck), Conway's Law (Skelton/Pais), and more — applied as lens, not checklist
- **Execution-ready handoff** — `/em-works` translates EDD into atomic tickets + worktree parallelization lanes + env/secrets spec + deploy plan artifact (artifact-only, doesn't execute — devops/release skill handles execution)
- **Auto-detect mode in /em-review** — input contains PR ref → Mode A (code review, **dual `.md` + `.html` output** with severity-coded findings); stack trace / "bug" / "error" → Mode B (debug, hypothesis-driven, no blind fixes); ambiguous → asks
- **Role-based handoff (not skill-specific)** — outputs reference role names (`engineer`, `security-reviewer`, `qa-reviewer`, `release-engineer`/`devops`, `pm`) so they work across env conventions (verzth, soekarno, gstack, generic)
- **Numbered questions, anti-ambiguity** — same pattern as pm-thinking

**EM lifecycle flow:** `/em-plan` → `/em-works` → engineer role → `/em-review` (Mode A approve → release; Mode B debug if production incident → loop back to `/em-plan` if architectural).

**Inspired by** [gstack](https://github.com/garrytan/gstack) (Garry Tan, YC) for cognitive patterns + scope challenge discipline, and [soekarno](https://github.com/verzth/soekarno) for multi-agent process + structured handoff philosophy.

[Read full documentation →](./skills/em-thinking/README.md)

## Skill: public-awareness

A guardrail that keeps working context out of artifacts. Install it globally so every artifact-writing session automatically separates what's being built from how it's being built.

**What it does:**
- **Channel rule** — internal context (progress notes, uncertainty, process TODOs, session reasoning) belongs in conversation / TodoWrite / memory, never inside the artifact being built
- **Covers all artifact types** — websites, API specs, technical docs, database records, design specs, shared documents (Notion, Confluence, Google Docs), deployed code
- **Language rule** — the artifact's language follows the project audience, not the conversation language (e.g. prompter writes in Indonesian, product is an English website → content in English)
- **Audience check** — before writing, asks: "Is this content *part of the artifact* or *about how we're building it*?" When the target's visibility is unclear, asks before writing

**Example:**
> *Without skill:* Writes `<!-- TODO: verify pricing with legal -->` inside published HTML, or `"_note": "still validating"` inside a production JSON payload
>
> *With skill:* Keeps those notes in conversation; writes only intentional, finished content into the artifact

[Read full documentation →](./skills/public-awareness/SKILL.md)

## Skill: board-thinking

A multi-perspective idea diagnostic that sits between raw ideation and structured product work. **One install → one skill**: `/onboard` (Board Thinking).

**What it does:**
- **Convenes a virtual board of 5-7 stakeholder advisors** — 5 always-on lenses (The Skeptical Customer, The Cynical Investor, The Operator, The Contrarian, The Time Traveler) plus auto-added domain seats (Compliance Officer for regulated industries; Technical Architect for enterprise-scale or real-time claims)
- **Two rounds of questions** — Round 1 is discovery (each member asks one probing question citing specifics from the idea); Round 2 is cross-examination (each member reacts to other members' findings to surface tension). Cross-examination is the unique value vs single-voice "office hours" diagnosis
- **Mechanical verdict tally** — `≥4 REJECT → REJECT`, `≥4 APPROVE no rejects → PROCEED`, anything else → `PROCEED_WITH_CONDITIONS`. Founder enthusiasm does not override votes — verdicts reflect answer quality
- **Self-contained memo output** — writes `board-memo-{YYYYMMDD-HHMMSS}.md` to the working directory with executive summary, idea brief, roster, both rounds verbatim, verdicts table, conditions to satisfy, "the most important finding," "recommended next action," and "what the board noticed about how you think"
- **Bilingual runtime output** — memo prose matches user's language (Indonesian/English mix supported); persona names, verdict tokens, and section anchors stay English to preserve brand and parseability across sessions
- **Anti-routing discipline on REJECT** — a REJECT verdict never routes to `/em-plan` or `/pm-works`; it loops back to ideation or parks the project

**Sprint flow position:** raw idea → `/onboard` → verdict → `/pm-works` (PRD) or `/em-plan` (architecture) on PROCEED; off-tool user interviews then `/pm-discover` on PROCEED_WITH_CONDITIONS; back to ideation on REJECT.

**When to use:** "stress test this idea", "what would a board say", "should I build this", "review this idea from multiple perspectives", "convene a board" — when you have an idea past raw brainstorm but before any PRD or architecture commitment, and want disconfirming evidence rather than affirmation.

[Read full documentation →](./skills/board-thinking/README.md)

## Skill: cso-thinking

A Chief Security Officer in a single command. **One install → one skill**: `/cso-audit`.

**What it does:**
- **Auto-detects target profile(s)** from the working directory — frontend, backend (any language: Go / Node / Python / Java / Ruby / PHP / Rust / .NET / Elixir), infrastructure (Docker / Terraform / Kubernetes / Helm / Ansible / CI), databases, Android, iOS. `generic` baseline (secrets, supply chain, repo hygiene) is always active.
- **Confirms scope before running** — proposes profiles with detection evidence, accepts edits (no surprise 20-minute audit on the wrong target).
- **Hybrid execution** — runs external tools where installed (`gitleaks`, `semgrep`, `trivy`, `osv-scanner`, `govulncheck`, `bandit`, `mobsfscan`, `npm audit`, `hadolint`, `checkov`, `actionlint`, …) and falls back to checklist review against curated reference files (OWASP Top 10 / API Top 10 / ASVS / MASVS / Cheat Sheets, CIS benchmarks, NIST SP 800-190, SLSA) where they are not.
- **Composite score 0–100 + letter grade** with a hard cap at C+ when any Critical finding exists — score is a trend signal, not a pass/fail. Severity-weighted formula (Critical −15, High −7, Medium −3, Low −1, Info 0) with scope-size adjustment so a 50-line script and a 500k-LOC platform don't share the same scale.
- **Fix-ready audit list** — every finding has severity, location (`file:line` or config key), source (tool+version or checklist item ID), why-it-matters, copy-pasteable remediation prompt (paste into a fresh Claude session and the fix executes itself), and verification steps.
- **Dual output** — `SECURITY_AUDIT.md` (agent handoff, stable structure, parseable) AND `SECURITY_AUDIT.html` (human review with score banner, severity filters, expandable findings, copy buttons, dark/light auto, printable).
- **Re-audit deltas** — second run computes resolved/regressed/new findings and shows score trend over time, preserving the prior report.
- **Honest about blind spots** — every report ends with a Scope & limitations section listing what the audit could not assess (runtime behavior, business-logic flaws, social engineering, physical security).

**When to use:** "audit security", "security score", "vulnerability scan", "OWASP check", "MASVS check", "find security holes", "audit our api/infra/app/db", "is this safe to ship", "security posture", "security review" — pre-release, periodic posture review, post-incident, before audit committee.

[Read full documentation →](./skills/cso-thinking/README.md)

## Skill: mockerize

A mockup-to-production implementation workflow for turning visual references into responsive, fully integrated product UI.

**What it does:**
- **High visual fidelity without brittle positioning** — matches the reference viewport closely, then preserves layout constraints, hierarchy, and usability across other device sizes
- **Explicit implementation mapping** — traces every visible element and action through UI components, frontend state, API contracts, backend services, and persistence
- **Correct-layer adjustments** — separates visual, layout, data, interaction, and domain mismatches so each problem is fixed at its owning layer instead of hidden with frontend workarounds
- **Minimal backend evolution** — adds only the contracts, validation, authorization, service, schema, or migration changes the real UI needs while protecting existing consumers and flows
- **Visual adjustment loop** — renders, compares, prioritizes high-impact differences, adjusts, and rechecks responsive sizes instead of declaring success from code inspection
- **End-to-end definition of done** — includes loading, empty, error, permission, validation, submission, long-data, build, contract, and regression verification
- **Benchmark coverage** — 10 execution-quality scenarios plus 20 balanced trigger cases covering visual fidelity, responsive inference, mapping, backend evolution, protected flows, authorization, and rendered verification

**Core rule:** pixel-faithful at the reference viewport, constraint-faithful everywhere else.

**When to use:** "implement this mockup", "make this screen match Figma", "follow this Pencil design", "turn this screenshot into responsive UI", "map this design to the API/backend", or "adjust the backend to support this mockup."

[Read full documentation →](./skills/mockerize/SKILL.md)

## Requirements

- **Node.js** 14.14+ (for `npx`)
- **Claude Code** or **Cowork** by Anthropic, **OpenClaw**, or **Hermes Agent**

## FAQ

**Can I use multiple skills at once?**
Yes. Install as many as you want — they work independently and don't conflict.

**What happens when I upgrade a skill?**
Your personalized settings (like `personality.md`) are automatically backed up and restored. You won't lose your configuration.

**Global or project — which should I pick?**
Use **global** if you want the skill everywhere. Use **project** if you only want it in a specific repo, or if different projects need different configurations.

**Can I uninstall a skill?**
Just delete the skill folder from `.claude/skills/` (project) or `~/.claude/skills/` (global). For OpenClaw, same pattern under `.openclaw/skills/`; for Hermes, under `.hermes/skills/` (or run `hermes skills remove <name>` for installs done via the Hermes CLI).

**I already have skills in `.claude/skills/` — can Hermes use them without re-downloading?**
Yes. Either symlink each skill from `~/.claude/skills/` into `~/.hermes/skills/`, or add `~/.claude/skills` to Hermes' `skills.external_dirs` in `~/.hermes/config.yaml`. Both options keep one source of truth so updates flow to both runtimes automatically. See the *"Already using Claude Code? Add Hermes too"* section above for commands.

## License

[MIT](./LICENSE)
