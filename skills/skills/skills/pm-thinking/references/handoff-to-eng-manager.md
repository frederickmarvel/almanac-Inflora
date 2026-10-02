# Handoff Contract: pm-thinking → engineer-manager

This doc defines the contract between the `pm-thinking` skill bundle and the `engineer-manager` skill (separate, built after pm-thinking).

**Purpose:** PM stops trespassing into engineering territory, eng isn't surprised at kickoff.

---

## What pm-thinking writes (PRD section "Handoff to Engineer Manager")

Every PRD produced by `/pm-works` has a **mandatory** section:

```markdown
## Handoff to Engineer Manager

**Hypothesis to validate:**
[From discovery.md hypothesis statement]

**Constraints (locked by PM):**
- [User-facing constraint, e.g., "must support SSO via SAML 2.0"]
- [Business constraint, e.g., "ship before Q3 review"]
- [Compliance constraint, e.g., "data residency US-only"]

**Decisions delegated to eng:**
- [Decision area — e.g., "tech stack for SSO library"]
- [Decision area — e.g., "session storage strategy"]
- [Decision area — e.g., "rollout architecture"]

**Don't decide engineering:**
- Specific library / framework choice
- Service boundary
- Performance trade-off
- Deployment strategy
```

---

## What the engineer-manager skill picks up

The `engineer-manager` skill will read this section and automatically:

1. **Honor constraints** — won't override what the PM locked
2. **Take delegated decisions** — pick tech stack, library, etc., with rationale
3. **Surface hidden trade-offs** — if there's tension between constraints, flag back to the PM
4. **Generate technical design doc** — derived from the PRD, not from scratch

---

## Boundary rules

### PM **may** specify (in the PRD):
- User outcome / behavior change
- Success metric (target + time window)
- Compliance / legal constraint
- Hard deadline / dependency
- User-facing API contract (input/output from user perspective)
- Audience / segment

### PM **may not** specify (delegate to eng):
- Tech stack choice (DB, framework, language)
- Internal API design
- Service boundary
- Caching strategy
- Performance optimization choice
- Deployment / infra strategy
- Test framework

### PM **may observe** (Tech Implications section):
- "New schema in table X" (observation, not how)
- "API contract changes, breaking" (flag, not strategy)
- "Touches PII" (compliance flag)
- "Effort ballpark: 2-3 weeks (PM guess)"

---

## Conflict resolution

If eng (via the engineer-manager skill) detects that a PM constraint **can't be honored** (e.g., deadline isn't realistic, the tech approach the PM locked in isn't feasible), eng must:

1. Flag back to the PM via the `engineer-manager` skill output
2. Propose 2-3 alternatives (relax constraint, extend deadline, reduce scope)
3. PM runs `/pm-decide --review` again or `/pm-works` revision
4. Loop until alignment

The PM may not override an eng technical assessment without written rationale.

---

## Iteration loop

```
/pm-discover → /pm-works → /pm-decide --review → engineer-manager (technical design)
                                                          ↓
                                              [eng flags constraint conflict]
                                                          ↓
                                              PM revisits /pm-works → /pm-decide --review
                                                          ↓
                                              engineer-manager (re-design)
                                                          ↓
                                                       [SHIP]
                                                          ↓
                                              /pm-decide --retro
```

---

## Current status

- ✅ pm-thinking: built, hosted at `verzth/skills/pm-thinking`
- ⏳ engineer-manager: planned, will be built separately at `verzth/skills/engineer-manager`

Until the engineer-manager skill exists, **the "Handoff to Engineer Manager" section in the PRD can be read manually by your tech lead**. The format is designed to be human-readable too.
