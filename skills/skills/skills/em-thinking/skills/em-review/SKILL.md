---
name: em-review
description: Review what comes back from engineers — Mode A code review (PR review against edd, bug-first, regression-first), Mode B debug (root cause investigation when production bug emerges, hypothesis-driven, no blind fixes). Use when a PR is ready for engineering manager review, when a bug appears in staging or production and needs structured root-cause analysis, when CI fails repeatedly with unclear root cause, or when investigating recurring issues. Pushes back on LGTM-without-grounding and on patches-without-root-cause.
---

# /em-review

> **Reference resolution.** All `../../references/*.md` and `../../ETHOS.md` paths resolve inside the `em-thinking` bundle. If a referenced file does not exist (standalone/flattened install), **say so explicitly** and continue using only the rules inlined in this SKILL.md — never improvise the missing file's content. If `../../references/html-template.md` is missing, deliver the `.md` output only, state that the `.html` artifact was skipped because the template is unavailable, and recommend reinstalling the full `em-thinking` bundle.

Review what comes back. This skill is multi-mode:

- **Mode A — Review:** PR code review, bug-first, grounded in `edd.md` + `eng-works.md`
- **Mode B — Debug:** Root cause investigation when bug emerges, hypothesis-driven

**Pick mode in this priority order:**

1. **Explicit flag** (`--review` / `--debug`) — highest priority, always honored
2. **Auto-detect from input** — fallback when no flag:
   - Input contains PR ref (diff, link, SHA, "PR #N", patch file) → **Mode A (review)**
   - Input contains stack trace, error log, "bug", "error", "crashed", "failing", "production issue" → **Mode B (debug)**
3. **Ask user** — only if input is ambiguous (both signals or neither). Use AskUserQuestion: "Pick mode: a) Review (PR diff) b) Debug (bug investigation)"

## ⚠ Question Format Rule

See [../../ETHOS.md](../../ETHOS.md) principle #8. Numbered questions, AskUserQuestion if available.

## When to trigger this skill

**Mode A (review):**
- "PR from engineer Y is ready, want to review"
- "Batch review end-of-lane (3 related PRs)"
- "Want to audit whether the PR matches the edd invariants"

**Mode B (debug):**
- "Production error spike in endpoint X, I'm investigating"
- "Recurring bug in tests, want root cause"
- "CI flaky, not sure of underlying cause"
- "Customer reported a bug we can't repro internally"

## Mode A — Code Review

### Input
- PR diff (link or patch file)
- `edd.md` + `eng-works.md` (for grounding the review)
- CI run output

If plan/works files are missing → **flag explicitly**. Review can still run but grounding is weak. Ask the user: "Does this PR have a plan reference? a) Yes (path) b) No, ungrounded review c) Generate a retroactive plan via /em-plan"

### Workflow — 4-section review

**Anti-skip rule:** All 4 sections must be evaluated, even if "no issues found". Skipping = anti-pattern.

#### Section 1: Architecture conformance

Active cognitive patterns:
- **Match plan:** Does PR architecture match the edd? Are deviations justified?
- **Boundary integrity:** Are the trust boundaries from the plan preserved?
- **Conway's Law:** Is module ownership clear?

Forcing questions per issue (one issue = one AskUserQuestion):
1. "PR introduces new module X that wasn't in the edd. a) Justified deviation (rationale) b) Out of scope, must be a separate PR c) Plan must be updated first via /em-plan"
2. "Trust boundary at [file Y line Z] — validation is missing. a) Add validation (block merge) b) Defer to follow-up ticket (justify) c) Out of scope, parking lot"

#### Section 2: Code quality

Active cognitive patterns:
- **DRY aggressive** — flag repetition
- **Edge cases over speed** — flag missing edge cases explicitly
- **Right-sized diff** — diff too large (>500 lines without rationale)? Too compressed (necessary rewrite squeezed)?
- **Make change easy + make easy change** — refactor + behavior bundled? Block.
- **Stale diagram check** — touched code with inline ASCII diagram? Update or flag.

Forcing questions:
1. "Pattern duplication in [file A] and [file B] — extract or leave? a) Extract (recommend, DRY) b) Leave (justify — premature abstraction) c) TODO follow-up"
2. "Diff size: N lines. Smell large. a) Justified (single logical change) b) Split into 2-3 PRs c) Backfill commit history with smaller commits"

#### Section 3: Test coverage

Active cognitive patterns:
- **Failure modes from plan** — covered in tests?
- **Tests > too few** — better over-test
- **Boundary tests** — empty, max, concurrent, partial-failure

Forcing questions:
1. "Failure mode #X from the edd — test coverage? a) Yes (test name) b) No (block) c) Deferred (justify)"
2. "Edge case [empty input / null / max value / concurrent] — covered? a) Yes b) Subset c) No (block T0/T1, allow T2/T3 with note)"

Detail rubric in [../../references/code-review-rubric.md](../../references/code-review-rubric.md).

#### Section 4: Performance

Active cognitive patterns:
- **N+1 query check** — DB access pattern
- **Memory concerns** — large allocation, leak risk
- **Caching opportunity** — flagged opportunity, not mandatory
- **High-complexity hotspot** — algorithm complexity

Forcing questions:
1. "Loop in [file] iterates over [N items] with DB query inside — N+1 risk. a) Refactor to batch query (block) b) Acceptable (N small, justify) c) TODO with index/cache plan"

### Decision routing (Mode A)

After all 4 sections:

1. **Approve** — all blockers resolved, ready to merge → handoff to `release-engineer` role or direct merge
2. **Request changes** — blockers listed, fix loop → engineer fix → loop back to `/em-review`
3. **Comment** — minor suggestions, not blocking → engineer can merge without loop

Forcing question:
- "Decision for this PR: a) Approve (no blockers) b) Request changes (list in output) c) Comment (suggestions, mergeable)"

### Output: `pr-review-<sha>.md` + `pr-review-<sha>.html` (dual output)

**Must write 2 files**:

1. **`pr-review-<sha>.md`** — source markdown (structure below)
2. **`pr-review-<sha>.html`** — human-readable review version, self-contained (severity badges colored Block/Major/Minor/Info, TOC + breadcrumb, code refs styled, decision summary card)

HTML render uses the template + full CSS spec from [`../../references/html-template.md`](../../references/html-template.md). `<sha>` is the short SHA (7 chars) of the PR head commit. Content must be 1:1 consistent between `.md` and `.html`.

#### MD Structure

```markdown
# PR Review: [PR title or ID]

**PR:** [link / sha]
**Plan reference:** edd.md (path) / eng-works.md (path)
**Reviewed by:** em-review (Mode A)
**Date:** YYYY-MM-DD

---

## TL;DR

**Decision:** Approve / Request changes / Comment
**Blockers:** N
**Suggestions:** N
**Section breakdown:** Architecture (X issues) | Code quality (Y) | Tests (Z) | Performance (W)

---

## Section 1: Architecture Conformance

[Per issue: file:line, severity, recommendation, decision]

## Section 2: Code Quality

[Per issue: ...]

## Section 3: Test Coverage

[Per issue: ...]

## Section 4: Performance

[Per issue: ...]

---

## Forcing Questions Raised

| # | Section | Question | Response | Resolution |
|---|---------|----------|----------|------------|

---

## Decision

- **Outcome:** [Approve / Request changes / Comment]
- **Blockers (must fix):** [list with file:line]
- **Suggestions (nice to have):** [list]
- **Routing:**
  - Approve → `release-engineer` role or direct merge
  - Request changes → `engineer` role (fix) → `/em-review` again
  - Comment → `engineer` role (merge with FYI, no loop)

---

**Generated by:** em-review (Mode A)
**Status:** [decision]
```

## Mode B — Debug

### Input
- Bug repro / stack trace / log
- Optional: `edd.md` (if the bug touches an area already planned)
- Optional: production telemetry

### Workflow — 5 steps (mirror investigate skill, EM-flavored)

Detail playbook in [../../references/debug-playbook.md](../../references/debug-playbook.md).

#### Step 1: Reproduce

Can't repro = can't debug. Stop if there's only 1 anecdotal report without a repro path.

Forcing questions:
1. "This bug: a) Repro consistent (clear steps) b) Repro intermittent (need additional observability) c) Anecdotal only (single report, can't repro) → if (c), stop and instrument first"

#### Step 2: Isolate

Narrow the surface to the minimum repro case.

- Disable an unrelated feature flag → still repro?
- Test with input subset → which one triggers it?
- Run in different env (staging vs local) → consistent?

Output: minimum repro case (smallest input + state that reproduces the bug).

#### Step 3: Hypothesize

List 3 hypotheses, rank by likelihood.

Format:
- **Hypothesis 1 (likely):** [statement]. Evidence supporting: [log/metric/code]. Evidence against: [—]. Test plan: [how to verify].
- **Hypothesis 2 (less likely):** ...
- **Hypothesis 3 (long shot):** ...

Forcing question:
1. "Top hypothesis confidence: a) High (strong evidence, clear test plan) b) Medium (need more data) c) Low (still guessing — keep observing)"

#### Step 4: Test

Verify each hypothesis. Don't blind-fix.

Per hypothesis:
- Run targeted test / instrumented repro / code read
- Capture evidence (log line, test output, code path)
- Confirmed / refuted / inconclusive?

#### Step 5: Diagnose & propose fix

Root cause stated explicitly. Symptom ≠ root cause.

Fix scope decision:
- **Local fix** (1-3 files, contained) → proposal handoff to `engineer` role
- **Architectural fix** (cross-module, design issue) → loop back to `/em-plan` with flag "rooted in production bug X"
- **Process fix** (CI gap, test gap, observability gap) → ticket via `/em-works` next sprint (route to `engineer` / `qa-reviewer` / `devops` role per gap type)

Forcing questions:
1. "Before patching, is the root cause confirmed? a) Yes (evidence: ...) b) Strong hypothesis c) Guessing (continue investigation)"
2. "Fix scope: a) Local (handoff engineer) b) Architectural (loop to /em-plan) c) Process (CI/test/observability gap → ticket)"
3. "Test for regression — does it exist? a) Yes (test name) b) Will be added in fix PR c) Not yet decided"

### Output: `debug-<bug-id>.md` + `debug-<bug-id>.html` (dual output)

**Must write 2 files**:

1. **`debug-<bug-id>.md`** — source markdown (structure below)
2. **`debug-<bug-id>.html`** — human-readable review version, self-contained (severity badge colored, hypothesis table, root cause card highlighted, TOC + breadcrumb)

HTML render uses the template + full CSS spec from [`../../references/html-template.md`](../../references/html-template.md). Content must be 1:1 consistent. `<bug-id>` is a short slug (issue number or brief description, e.g. `debug-auth-timeout.html`).

```markdown
# Debug Trace: [bug ID or short description]

**Reported:** YYYY-MM-DD by [source]
**Severity:** Critical / High / Medium / Low
**Investigated by:** em-review (Mode B)
**Date:** YYYY-MM-DD

---

## TL;DR

**Root cause:** [1 line]
**Fix scope:** [Local / Architectural / Process]
**Routing:** [engineer / /em-plan / /em-works ticket]
**Regression test:** [planned / existing / TBD]

---

## Step 1: Reproduce

- Repro reliability: [Consistent / Intermittent / Anecdotal]
- Repro steps:
  1. ...
  2. ...
- Min input: [...]
- Environment: [...]

## Step 2: Isolate

- Narrowing observations:
  - [observation 1]
- Minimum repro case: [...]

## Step 3: Hypothesize

### Hypothesis 1 (likely)
- **Statement:** ...
- **Evidence supporting:** ...
- **Evidence against:** ...
- **Test plan:** ...

### Hypothesis 2 (less likely)
...

### Hypothesis 3 (long shot)
...

## Step 4: Test

| Hypothesis | Test action | Evidence | Verdict |
|------------|-------------|----------|---------|
| 1 | ... | ... | Confirmed / Refuted / Inconclusive |

## Step 5: Diagnose & Fix

- **Root cause (confirmed):** ...
- **Why bug emerged:** [trigger condition]
- **Why not caught earlier:** [test gap / observability gap / review gap]

### Fix proposal
- **Scope:** Local / Architectural / Process
- **Approach:** [1 paragraph]
- **Files affected:** [list]
- **Regression test:** [test plan]

---

## Forcing Questions Raised

| # | Step | Question | Response | Resolution |
|---|------|----------|----------|------------|

---

## Routing

- **Local fix:** Handoff to `engineer` role (skill matched per env)
- **Architectural fix:** Loop back to `/em-plan` with flag "production-driven re-plan"
- **Process fix:** Ticket via `/em-works` next sprint (route to `engineer` / `qa-reviewer` / `devops` role per gap type)

---

**Generated by:** em-review (Mode B)
**Status:** [Root cause identified / Investigation ongoing]
```

## Integration with tools

| Condition | Behavior |
|---------|----------|
| GitHub MCP connected (Mode A) | Auto-fetch PR diff, post review comments inline |
| Linear / GitHub Issues MCP (Mode B) | Auto-create issue for regression / process gap |
| BigQuery MCP (Mode B) | Pull production telemetry for evidence |
| Notion MCP | Push debug-trace.md / pr-review.md to Notion |
| No MCP | File saved local, user pastes manually |

## Anti-pattern (don't do this)

### Mode A
- ❌ **Skip `pr-review-<sha>.html` output.** Dual output mandatory — user reviews via HTML.
- ❌ **"LGTM" without annotation on T0/T1 PR.** Review unmoored.
- ❌ **Approve PR without reading the edd reference.** Grounding weak.
- ❌ **Skip a section.** Anti-skip rule applies.
- ❌ **Batch multiple issues into one AskUserQuestion.** One issue = one question.
- ❌ **"Add tests later" as a negotiable blocker on T0/T1.** A block must block.

### Mode B
- ❌ **Skip `debug-<bug-id>.html` output.** Dual output mandatory — prompter reviews via HTML.
- ❌ **Patch before the hypothesis is confirmed.** Blind fix masking root cause.
- ❌ **Stop at the symptom.** "Restart fixes it" is not a diagnosis.
- ❌ **Skip regression test.** A bug whose fix has no test will recur.
- ❌ **Architectural fix tossed to engineer ticket without looping to /em-plan.** EM bypasses own job.
- ❌ **"Cannot reproduce, closing"** without instrumenting observability first. An anecdotal that gets dismissed = a bug that will return.

## Handoff

### Mode A
- **Approve** → `release-engineer` role (skill matched per env) or direct merge
- **Request changes** → `engineer` role fix loop → `/em-review --review` again
- **Comment** → `engineer` role merge with FYI, no loop

### Mode B
- **Local fix** → `engineer` role (per fix PR) → `/em-review --review` per fix PR
- **Architectural fix** → `/em-plan` with re-frame ("production bug X drove re-plan")
- **Process fix** → `/em-works` next sprint with ticket "process improvement: [CI gap / test gap / observability]" (route to `engineer` / `qa-reviewer` / `devops` role per gap type)
