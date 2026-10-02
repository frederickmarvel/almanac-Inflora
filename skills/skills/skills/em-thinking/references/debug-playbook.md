# Debug Playbook

Detail for `/em-review` Mode B. 5-step investigation, hypothesis-driven, **no blind fixes**.

---

## Iron Rule

> **No fixes without root cause confirmed.**

A patch shipped before the hypothesis is confirmed = a future bug that will recur. Symptom ≠ root cause.

---

## Step 1: Reproduce

### Goal
Can't repro = can't debug. **Stop if there's only 1 anecdotal report without a repro path.**

### Reliability levels

| Level | Description | Action |
|-------|-------------|--------|
| **Consistent** | Repro 100% with clear steps | Proceed to Step 2 |
| **Intermittent** | Repro sometimes, need observability | Instrument, gather data, retry |
| **Anecdotal** | Single report, can't repro | **Stop**. Instrument observability first. |

### Forcing questions

1. "This bug: a) Repro consistent (clear steps) b) Repro intermittent (need more obs) c) Anecdotal (can't repro)"
2. "If (c) — stop and instrument. Tell the user: a bug that can't be repro'd = a bug that will recur."

### Anti-pattern

❌ **"Cannot reproduce, closing."** Without instrumenting observability first = a bug that will return.

❌ **"Customer report, I assume legit."** A repro path must be established before engineer time is spent.

---

## Step 2: Isolate

### Goal
Narrow the surface to **minimum repro case** (smallest input + state that reproduces the bug).

### Techniques

- **Disable feature flag** unrelated → still repro?
- **Test with input subset** → which one triggers it?
- **Run in different env** (staging vs local) → consistent?
- **Strip dependencies** — if the bug is in service A→B→C, isolate whether B or C is misbehaving
- **Time-based isolation** — if the bug appeared after deploy X, bisect git history
- **Data-based isolation** — do affected users/records share a common property?

### Output

Minimum repro case as code/script + state setup.

### Forcing questions

1. "Minimum repro case established? a) Yes b) Still narrowing c) Cannot narrow further (proceed with caveat)"
2. "Pattern across affected — same user segment? same time window? same data shape?"

---

## Step 3: Hypothesize

### Goal
List 3 hypotheses, rank by likelihood. Hypotheses that are testable.

### Format per hypothesis

```
Hypothesis [N] (likelihood: high/medium/low):
- **Statement:** [what's wrong, in declarative form]
- **Evidence supporting:** [log line, metric, code reading, similar past bug]
- **Evidence against:** [if any, be honest]
- **Test plan:** [how to verify or refute — concrete action]
```

### Likelihood rationale

- **High** — strong supporting evidence, no contradicting evidence, similar past bug
- **Medium** — some supporting evidence, gap in knowledge
- **Low** — speculative, weak evidence, but plausible enough to test

### Hypothesis sources (where to look)

- Recent code changes (git log on affected file)
- Recent infra changes (deploy, config, scale)
- Recent dependency updates
- Recent user behavior change (load, pattern)
- Known existing tech debt that was touched
- Time correlation (cron job? business hour pattern?)

### Forcing questions

1. "Top hypothesis confidence: a) High (strong evidence, clear test plan) b) Medium (need more data) c) Low (still guessing — keep observing)"
2. "Hypothesis count — minimum 2 alternatives considered? Single-hypothesis investigation = confirmation bias risk."

---

## Step 4: Test

### Goal
Verify each hypothesis with **evidence**, not opinion. Don't blind-fix.

### Per hypothesis

| Action | Evidence collected | Verdict |
|--------|---------------------|---------|
| Run targeted unit test | Test output (pass/fail/exception) | Confirmed / Refuted / Inconclusive |
| Add temporary log line, repro | Log line content | Confirmed / Refuted / Inconclusive |
| Read code path | Code reading note | Confirmed / Refuted / Inconclusive |
| Run instrumented repro | Trace / metric data | Confirmed / Refuted / Inconclusive |

### Verdict definitions

- **Confirmed** — evidence directly supports hypothesis (e.g. expected log line matched)
- **Refuted** — evidence contradicts hypothesis
- **Inconclusive** — evidence gathered but not decisive — refine hypothesis or collect more

### Forcing questions

1. "Test [X] — verdict: a) Confirmed b) Refuted c) Inconclusive — keep gathering"
2. "Multiple hypotheses confirmed simultaneously — check if hypotheses have a subset/superset relationship"

---

## Step 5: Diagnose & Propose Fix

### Goal
**Root cause stated explicitly.** Symptom ≠ root cause.

### Symptom vs root cause

❌ **Symptom-stated:**
> "Service X returns 500 on endpoint /orders"

✅ **Root-cause-stated:**
> "OrderRepository.find() throws IllegalStateException when transaction isolation conflicts with read-after-write — race between insert and read in concurrent request handling"

### Why-chain (ask 5 whys)

```
Bug: API returns 500
↓ Why?
Endpoint throws unhandled exception
↓ Why?
Database query returns inconsistent state
↓ Why?
Race condition between insert and read
↓ Why?
Transaction isolation level READ_COMMITTED + concurrent insert
↓ Why?
Service uses default isolation, never set to SERIALIZABLE for this critical path
                ↑
               Root cause
```

Stop deeper if you hit an organizational / external boundary (e.g. "the team doesn't have a budget to upgrade DB" = a real root cause that can't be solved technically).

### Fix scope decision

| Scope | Description | Routing |
|-------|-------------|---------|
| **Local** | 1-3 files, contained, tactical | Engineer role (skill matched per env) — handoff per fix PR |
| **Architectural** | Cross-module, design issue | Loop to `/em-plan` with flag "rooted in production bug X" |
| **Process** | CI gap, test gap, observability gap | Ticket via `/em-works` next sprint (route to engineer/qa-reviewer/devops role per gap type) |

### Why not caught earlier?

Must answer this in output. Memorialize for preventative learning:

- Test gap? — add regression test
- Observability gap? — add metric/log/trace
- Review gap? — add to code-review-rubric.md
- Architecture gap? — flag to em-plan for future similar work

### Forcing questions

1. "Root cause confirmed: a) Yes (evidence: ...) b) Strong hypothesis (more verification needed) c) Guessing (continue investigation)"
2. "Fix scope: a) Local b) Architectural c) Process"
3. "Test for regression: a) Yes (test name) b) Will be added in fix PR c) Not yet decided"
4. "Why not caught earlier — gap type: a) Test gap b) Observability gap c) Review gap d) Architecture gap"

---

## Common Anti-patterns in Debugging

### ❌ Blind fix
"Restart fixes it" — no diagnosis. A restart hides root cause. The bug will recur.

### ❌ Symptom patch
"Add try/catch around the failing line" — masking, not fixing. A future bug will emerge with less visibility.

### ❌ Single hypothesis
"It's definitely the cache" — confirmation bias. Always ≥ 2 hypotheses considered.

### ❌ "Cannot reproduce, closing"
Without instrumenting observability. An anecdotal that gets dismissed = a bug that will return.

### ❌ Skip regression test
A bug whose fix has no test will recur. Always test.

### ❌ Architectural fix tossed to engineer ticket
Without looping to `/em-plan`. EM bypasses own job. Engineer fixes locally, the pattern propagates to other services.

### ❌ Stop at proximate cause
"Engineer X created the bug" — that's not root cause, that's blame. Why does the system allow this bug? Test? Review? Process?

---

## Output Linkage

Debug output (`debug-<bug-id>.md`) feeds:
- **Local fix** → engineer role (skill matched per env)
- **Architectural fix** → `/em-plan` (re-planning context: production bug drove re-frame)
- **Process fix** → `/em-works` next sprint ticket
- **Lessons** → update `references/code-review-rubric.md` or `references/architecture-checklist.md` if pattern is generalizable

Self-improving loop: debug findings → reference doc updates → fewer similar bugs in the future.
