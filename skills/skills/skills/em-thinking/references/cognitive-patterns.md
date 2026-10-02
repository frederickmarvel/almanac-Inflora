# Cognitive Patterns for Engineering Managers

Reference list of 15 instincts that experienced engineering managers develop from canonical literature. Not a dead checklist — use as a **lens** when reviewing plans, designs, or code.

Citations explicit for follow-up. Apply with judgment, not ritual.

---

## How to Use This Reference

- **At `/em-plan` Phase 3** — apply min 2 patterns that actually shape decisions in the architecture. Cite patterns explicitly in the "Cognitive patterns applied" section.
- **At `/em-review` Mode A Section 1** — check whether PR is consistent with the patterns from the plan. Flag deviations.
- **At `/em-review` Mode B Step 5** — check whether the debug fix is consistent with the pattern (e.g. "Failure is information" → fix must produce learning, not a blind patch).

Cite patterns explicitly in output. Empty citation without connecting to a concrete decision = anti-pattern (see ETHOS #7).

---

## The 15 Patterns

### 1. State Diagnosis
**Source:** Will Larson, *An Elegant Puzzle*

An engineering team lives in one of 4 states, and each state demands a different intervention:
- **Falling behind** — backlog piling up, on-call exhausted, slow to ship. Intervention: **reduce WIP**, simplify, freeze new scope.
- **Treading water** — shipping works but no strategic progress. Intervention: **reclaim slack**, automate toil.
- **Repaying debt** — actively cleaning. Intervention: **protect from new scope**, hold the line.
- **Innovating** — strong foundation, team explores. Intervention: **bounded experiments** with time-box.

**EM connection:** Diagnose first before you prescribe. An ambitious plan for a "falling behind" team = adding pain, not solving.

### 2. Blast Radius Instinct
**Source:** SRE folklore, formalized in the Google SRE Book

Every decision evaluated through: "What's the worst case, and how many systems/people get hit?"

**EM connection:** Before approving a plan, mentally simulate failure. A database migration that blocks writes for 10 minutes → blast radius = all users. A local config flag flip → blast radius = 1 service. Same decision shape, different blast radius → different discipline applies.

### 3. Boring by Default
**Source:** Dan McKinley, *Choose Boring Technology* (2015)

> "Every company gets about three innovation tokens."

Default to proven tech. Every deviation to a shiny new pattern = **spending an innovation token**. Tokens are spent deliberately, not by accident.

**EM connection:** A plan that proposes a new pattern must answer: "Is this token justified enough? What can't be done with boring tech?" Bias toward boring = bias toward a team that can still ship fast 2 years from now.

### 4. Incremental over Revolutionary
**Source:** Martin Fowler, *Strangler Fig Application* (2004)

Refactor, don't rewrite. Strangler fig pattern: legacy system gets wrapped, functionality migrates piece by piece, until the legacy can be decommissioned.

**EM connection:** "Big bang rewrite" is almost always a bad idea. A plan that proposes a rewrite must minimally address: 1) can we roll it back, 2) is there an intermediate milestone that's valuable, 3) feature freeze during the rewrite — accepted or not.

### 5. Systems over Heroes
**Source:** SRE folklore

Design for tired humans at 3am, not for the best engineer on their best day.

**EM connection:** Runbook, alerts that are clear, dashboards that are first-glance-readable. A system that relies on "Andi knows how to fix it" is fragile. The em-works pre-handoff checklist mandates a runbook draft for this reason.

### 6. Reversibility Preference
**Source:** Jeff Bezos, "Type 1 vs Type 2 decisions"

Reversible decisions (Type 2) can be made fast. Irreversible ones (Type 1) need care.

In eng: feature flag > big bang. Canary > 100% rollout. A/B > permanent change. Make the cost of being wrong **low**.

**EM connection:** em-works deploy strategy defaults to flag/canary for T0/T1. Big bang reserved for T3 trivial only.

### 7. Failure is Information
**Source:** John Allspaw, *Blameless PostMortems and a Just Culture* (2012); Google SRE

An incident is not a blame event — an incident is a learning opportunity. An error budget is not a punishment, but a resource to be allocated.

**EM connection:** em-review Mode B (debug) is explicitly anti-blameless violation: "a postmortem that names a person as cause" = anti-pattern. A bug that recurs because there's no test → the actual root cause = test gap, not "engineer was sloppy".

### 8. Org Structure IS Architecture
**Source:** Conway's Law (1967); formalized in Skelton & Pais, *Team Topologies* (2019)

> "Organizations design systems that mirror their communication structure."

The boundary in code maps to the boundary in the team. Microservices that are split but 1 team owns all = micro-distributed-monolith. A module that's logical but 5 teams co-edit = constant merge hell.

**EM connection:** em-plan Phase 3 must consider ownership. "This new service — who owns it?" If there's no clear owner, the service will become an orphan in 6 months.

### 9. DX is Product Quality
**Source:** *DevOps Research and Assessment* (DORA); Nicole Forsgren, *Accelerate* (2018)

Slow CI, bad local dev, painful deploy → worse software, higher attrition. Developer experience = leading indicator.

**EM connection:** "CI green takes 25 minutes" is a metric to track. The em-works pre-handoff checklist explicitly includes "CI green on baseline" because weak DX eats team velocity silently.

### 10. Essential vs Accidental Complexity
**Source:** Fred Brooks, *No Silver Bullet* (1986)

Essential complexity = inherent to the problem (the problem domain really is complex). Accidental complexity = self-inflicted (tool/approach choices that add complexity without justification).

**EM connection:** Before adding anything: "Is this solving a real problem or a problem we created ourselves?" em-plan Step-0 Scope Challenge explicitly triggers this.

### 11. Two-Week Smell Test
**Source:** Charity Majors, various

If a competent new engineer can't ship a small feature in 2 weeks, **you have an onboarding problem disguised as an architecture problem**.

**EM connection:** em-plan Phase 2 Step 5 triggers this. If the plan isn't feasible in 2 weeks, root cause analysis first — often the answer is not "this feature is complex" but "our stack is hard to learn for newcomers".

### 12. Glue Work Awareness
**Source:** Tanya Reilly, *The Staff Engineer's Path* (2022); Will Larson, "Glue Work"

Glue work = invisible coordination (docs, migration, test fixtures, runbook, mediation between teams). Critical for delivery, but not visible in promo packets.

**EM connection:** em-works Phase 1 Step 4 explicitly flags glue tickets, distributes fairly. Anti-pattern: 1 IC stuck doing only glue → eventual burnout + career stall.

### 13. Make the Change Easy, Then Make the Easy Change
**Source:** Kent Beck, "Tidy First?" / *Tidy First?* (2023)

Refactor first (no behavior change). Then implement the feature. **Never** combine structural + behavioral changes in 1 commit/PR.

**EM connection:** em-works Phase 1 Step 3 explicit anti-pattern: "Bundle refactor + feature in 1 ticket". em-review Mode A flags if the diff is bundled.

### 14. Own Your Code in Production
**Source:** Charity Majors, "The DevOps movement is ending"

> "There are only engineers who write code and own it in production."

There is no wall between dev and ops. The engineer who ships must be able to observe, debug, and roll back production.

**EM connection:** em-works pre-handoff checklist includes a monitoring dashboard plan + on-call window-1 owner. em-review Mode A Section 2 checks that the PR includes sufficient observability (log, metric, trace).

### 15. Error Budgets over Uptime Targets
**Source:** Google SRE Book, *Implementing Service Level Objectives*

99.9% SLO is not an uptime target — it's a **0.1% downtime budget** that can be spent on shipping. Reliability = a resource allocation problem.

**EM connection:** em-works deploy plan section "Error budget tracking" — when the budget is gone, **freeze new feature deploys** until the budget is restored. Reliability isn't a velocity blocker, it's velocity that's sustainable.

---

## Pattern Selection Guide

Which patterns are active when?

| Phase / Skill | Most active patterns |
|---------------|------------------------|
| `/em-plan` Phase 1 (Capture & Risk) | #1 (State diagnosis), #2 (Blast radius) |
| `/em-plan` Phase 2 (Scope Challenge) | #10 (Essential vs accidental), #11 (Two-week smell), #4 (Incremental) |
| `/em-plan` Phase 3 (Architecture) | #3 (Boring), #6 (Reversibility), #5 (Systems over heroes), #8 (Conway), #14 (Own in prod) |
| `/em-plan` Phase 4 (Test Strategy) | #7 (Failure is info), #15 (Error budgets) |
| `/em-works` Phase 1 (Tasks) | #13 (Make change easy), #12 (Glue work) |
| `/em-works` Phase 4 (Deploy) | #6 (Reversibility), #15 (Error budgets), #9 (DX) |
| `/em-review` Mode A (Review) | #13 (Make change easy), #14 (Own in prod), #5 (Systems > heroes) |
| `/em-review` Mode B (Debug) | #7 (Failure is info), #2 (Blast radius) |

Not exhaustive — patterns can apply across phases. This guide is just a starting point.

---

## Anti-pattern Citation

✅ **Good:**
> "Boring by default — picked Postgres over <new shiny db> because the team has operated Postgres for 3 years. Innovation token saved for the ML pipeline (#X in roadmap)."

✅ **Good:**
> "Reversibility — feature flag default off, canary 5% → 25% → 100%. Rollback < 5 minutes via flag toggle. Cost of being wrong = low."

❌ **Bad (empty citation):**
> "Applied Conway's Law and Boring by Default."
(Doesn't connect to a specific decision. Where's the decision, where's the pattern that shaped it?)

❌ **Bad (ritual):**
> "Per ETHOS principle #3, we are choosing boring tech."
(Doesn't explain what's boring, why boring, and what token is saved.)
