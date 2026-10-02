# Code Review Rubric

Detail for `/em-review` Mode A. 4-section review with severity levels and decision matrix.

---

## Where to Use

- `/em-review` Mode A workflow — all 4 sections must be evaluated
- Anti-skip rule — even if "no issues found", evaluate and state explicitly

---

## Section 1: Architecture Conformance

### Goal
Match PR to `edd.md` + `eng-works.md`. Deviations must be justified.

### Items to check

- [ ] **PR scope match plan** — implements ticket from eng-works, doesn't drift
- [ ] **No new module unjustified** — new module not in the plan = deviation
- [ ] **Boundaries preserved** — trust boundaries from the plan are preserved
- [ ] **Conway's Law** — module ownership is clear, not crossing team ownership without coord
- [ ] **Existing patterns reused** — not parallel-build something that already exists

### Severity levels

- **Block** — Architecture deviation that affects an invariant or failure mode from the plan
- **Major** — New module not in the plan, plan must be updated first
- **Minor** — Pattern deviation that's debatable, suggest discuss

### Forcing question template

1. "Issue [#X] — severity: a) Block b) Major c) Minor d) Info"
2. "PR introduces module Y not in the plan. a) Justified deviation (rationale: ...) b) Out of scope (split into separate PR) c) Plan must be updated via /em-plan"

---

## Section 2: Code Quality

### Goal
Code maintainable, follows team convention, no over/under-engineering.

### Items to check

- [ ] **DRY** — aggressive repetition flagged
- [ ] **Error handling** — explicit, with recovery or loud failure
- [ ] **Edge cases** — missing edge cases flagged (empty, null, max, concurrent)
- [ ] **Naming** — descriptive, consistent with codebase
- [ ] **Tech debt hotspots** — touched code with known debt — leave or refactor?
- [ ] **Right-sized diff** — > 500 line diff: justified or split? Necessary rewrite but compressed: red flag.
- [ ] **Make change easy + make easy change** — refactor + behavior bundled? Block.
- [ ] **Stale ASCII diagram** — touched code with inline diagram comment? Update or flag.
- [ ] **Observability** — log, metric, trace sufficient for future debugging?

### Severity levels

- **Block** — DRY violation in T0/T1 path, missing error handling in critical path, refactor + feature bundled
- **Major** — Edge case missed, technical debt added unjustified
- **Minor** — Naming improvement, suggestion non-blocking

### Forcing question template

1. "Pattern duplication in [file A] and [file B] — extract or leave? a) Extract (DRY) b) Leave (premature abstraction risk) c) TODO follow-up"
2. "Diff size: N lines. a) Justified (single logical change) b) Split into 2-3 PRs c) Backfill commit history with smaller commits"

---

## Section 3: Test Coverage

### Goal
Test strategy from plan implemented. Failure modes from plan covered.

### Items to check

- [ ] **Test-first for T0/T1** — tests written before implementation (commit history check)
- [ ] **Failure modes covered** — every row in the failure modes table from the plan has a test
- [ ] **Edge cases** — empty, max, null, concurrent, partial failure
- [ ] **Boundary tests** — at min, at max, at zero
- [ ] **Integration coverage** — required interactions tested
- [ ] **No skipped/disabled tests** — if there's `skip` or `xit`, justify
- [ ] **Test naming** — descriptive, matches what's tested

### Severity levels

- **Block (T0/T1)** — Failure mode from plan has no test, OR critical edge case missing
- **Block (T2)** — Test missing for core invariant
- **Major** — Test exists but assertion is weak
- **Minor** — Test naming suggestion, additional case nice-to-have

### Forcing question template

1. "Failure mode #X from the edd — test coverage? a) Yes (test name: ...) b) No (block) c) Deferred (justify)"
2. "Edge case [empty / null / max / concurrent] — covered? a) Yes b) Subset c) No (block T0/T1, allow T2/T3 with note)"
3. "Test commit timing — pre or post implementation? a) Pre (test-first) b) Same commit c) Post (red flag T0/T1)"

---

## Section 4: Performance

### Goal
No obvious performance footgun. N+1 queries flagged. Memory hotspots aware.

### Items to check

- [ ] **N+1 queries** — loop over records with DB query inside? Flag.
- [ ] **Memory allocation hotspot** — large slice/map allocation in tight loop, leak risk
- [ ] **Caching opportunity** — read-heavy + immutable data without cache?
- [ ] **High-complexity path** — O(n²) or worse where O(n log n) is possible
- [ ] **Database indexes** — new query path uses existing index, or needs new index?
- [ ] **External API calls** — rate limit aware, retry policy, timeout configured

### Severity levels

- **Block** — N+1 in T0/T1 endpoint, memory leak risk, missing index for table-scanning query
- **Major** — Clear caching opportunity, complexity hotspot in hot path
- **Minor** — Suggestion, nice-to-have optimization

### Forcing question template

1. "Loop in [file] iterates over [N items] with DB query inside — N+1 risk. a) Refactor batch query (block) b) Acceptable (N small, justify) c) TODO with index/cache plan"
2. "External API call in [file] — timeout configured? Rate limit aware?"

---

## Severity Levels Summary

| Severity | Action |
|----------|--------|
| **Block** | Must fix before merge. Request changes. |
| **Major** | Discuss; can defer to follow-up PR with ticket. |
| **Minor** | Comment; engineer decides. |
| **Info** | FYI, no action needed. |

---

## Decision Matrix

| Block count | Major count | Minor count | Decision |
|-------------|-------------|-------------|----------|
| 0 | 0 | any | **Approve** |
| 0 | ≤ 2 (with TODO ticket) | any | **Approve** with follow-up tickets |
| 0 | ≥ 3 | any | **Comment** (engineer decides if PR splits or merges) |
| ≥ 1 | any | any | **Request changes** |

Engineer judgment override allowed with rationale in output.

---

## Anti-pattern Reviewer (don't do this)

- ❌ **"LGTM" without annotation on T0/T1 PR.** Review unmoored.
- ❌ **Approve without reading the edd.** Grounding weak.
- ❌ **Skip a section.** Anti-skip rule — even "no issues" must be stated explicitly.
- ❌ **Batch multiple issues into one AskUserQuestion.** One issue = one question.
- ❌ **"Add tests later" as negotiable on T0/T1.** A block must block.
- ❌ **Severity inflation** — flag everything as block. Trust erodes.
- ❌ **Severity deflation** — flag block as minor. Bug ships.
- ❌ **Re-architect via review.** If an architectural concern emerges, suggest /em-plan loop, don't dictate redesign in the review thread.

---

## Self-check: Is this review high quality?

- [ ] Every finding linked to file:line specific
- [ ] Every finding referenced to edd section / failure mode
- [ ] Severity assigned per finding
- [ ] One issue = one AskUserQuestion (anti-batch)
- [ ] Decision consistent with severity counts (matrix)
- [ ] Tone: actionable, not judgmental
