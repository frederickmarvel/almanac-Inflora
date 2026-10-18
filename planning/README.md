# Inflora Planning Index

Start here for planning work. This page identifies the authoritative documents,
their precedence, and the documents retained only for history.

## What to read

| Need | Read | Authority |
|---|---|---|
| Choose the next backend phase | [`AI_BACKEND_COMPLETION_PLAN.md`](AI_BACKEND_COMPLETION_PLAN.md) | Current backend execution plan |
| Implement manual gateway settlement tracking or creator withdrawals | [`MANUAL_SETTLEMENT_WITHDRAWALS_PLAN.md`](MANUAL_SETTLEMENT_WITHDRAWALS_PLAN.md) | Current focused execution plan for that scope |
| Change service boundaries, connections, ports, or table ownership | [`WIRE_GUIDE.md`](WIRE_GUIDE.md) | Canonical wiring and ownership |
| Resolve a known documentation or ownership conflict | [`CONTRACT_DRIFT.md`](CONTRACT_DRIFT.md) | Binding Phase 0 decisions |
| Change an API, event, database object, posting rule, or operation key | [`schemas/INDEX.md`](schemas/INDEX.md) | Entry point to frozen contracts |
| Operate or troubleshoot production | [`../ops/RUNBOOK.md`](../ops/RUNBOOK.md) and [`../ops/ONCALL_CHECKLIST.md`](../ops/ONCALL_CHECKLIST.md) | Operational guidance |
| Check provider behavior | [`../docs/Pivot_techdocs.md`](../docs/Pivot_techdocs.md) | Provider reference; verify against official/sandbox behavior before freezing a contract |

## Precedence

When documents disagree, use this order and record the drift instead of making a
silent choice:

1. Frozen contract documents in [`schemas/`](schemas/), including posting
   templates and operation keys.
2. [`CONTRACT_DRIFT.md`](CONTRACT_DRIFT.md) for explicit conflict resolutions.
3. [`WIRE_GUIDE.md`](WIRE_GUIDE.md) for service wiring and ownership.
4. The applicable focused execution plan.
5. [`AI_BACKEND_COMPLETION_PLAN.md`](AI_BACKEND_COMPLETION_PLAN.md) for the
   overall phase sequence.
6. Archived material, which is historical context only and never authoritative.

If levels 1–3 conflict with each other, stop and update the contracts before
implementation.

## Current planning state

- The broad backend sequence is tracked in
  [`AI_BACKEND_COMPLETION_PLAN.md`](AI_BACKEND_COMPLETION_PLAN.md).
- Manual gateway settlement tracking and creator withdrawals are specified in
  [`MANUAL_SETTLEMENT_WITHDRAWALS_PLAN.md`](MANUAL_SETTLEMENT_WITHDRAWALS_PLAN.md).
- That focused plan excludes refunds and admin frontend development.
- Security/identity/RBAC, maker-checker policy, gateway evidence requirements,
  and holiday-calendar behavior remain blocking decisions for production use.

## Archive policy

Move a Markdown planning document to [`../archive/`](../archive/) when it is:

- superseded by a named current document;
- a completed one-time bootstrap prompt or checklist; or
- no longer consistent with the active architecture and retained only for
  historical context.

Do **not** archive frozen contracts, provider references, runbooks, or decision
records merely because they are not linked from an execution phase. Every
archived document must state its archive date, reason, and replacement.

## Archived documents

| Document | Why archived | Replacement |
|---|---|---|
| [`../archive/planning/BACKEND_BUILD_PLAN.md`](../archive/planning/BACKEND_BUILD_PLAN.md) | Original bootstrap/build plan; contains older phase assumptions and dead references | [`AI_BACKEND_COMPLETION_PLAN.md`](AI_BACKEND_COMPLETION_PLAN.md) |
| [`../archive/prompts/PROMPT_CLAUDE_CODE.md`](../archive/prompts/PROMPT_CLAUDE_CODE.md) | One-time Phase 0 repository-bootstrap prompt; bootstrap is complete | This index and the applicable current execution plan |
