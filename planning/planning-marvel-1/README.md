# planning-marvel-1

Detailed implementation plan for the Inflora Backoffice, Firebase Authentication, database RBAC, streamer dashboard parity, and withdrawal processing.

Status: planning only. No production implementation is authorized by these documents.
Prepared: 2026-10-16.

## Documents

- `00-current-state.md` — observed architecture, service boundaries, startup/config, auth assumptions, and exact change points.
- `01-firebase-rbac.md` — phased Firebase identity bridge and SUPERADMIN/ADMIN/USER authorization model.
- `02-backoffice.md` — Backoffice naming, admin management, withdrawal operations, batching, approvals, and exception handling.
- `03-withdrawals.md` — financial ownership, state machine, persistence, events, idempotency, and recovery requirements.
- `04-frontend.md` — existing dashboard/admin surface and the work required to make every represented function real.
- `05-phases-and-gates.md` — execution sequence, tests, rollout, observability, and explicit stop conditions.

## Required source-of-truth order

Read `almanac/planning/schemas/00-frozen-contracts.md`, `CONTRACT_DRIFT.md`, `WIRE_GUIDE.md`, the relevant schemas, then the applicable focused plan before editing code. The plan must not be used to invent endpoint names, event producers, table ownership, or ledger postings. Any mismatch must become a contract-drift decision first.

## Current high-level conclusions

1. Tolkien is the current streamer/admin HTTP facade on port 8080; its monitoring admin slice already has `ak_` sessions, but legacy holds/batches still trust `X-Actor-Id` plus the internal key.
2. Firebase is not present in the inspected Go modules, service code, frontend package, or environment examples. Authentication migration therefore requires an explicit compatibility and cutover design.
3. The database currently stores Argon2id streamer/admin passwords and bcrypt opaque `sk_`, `ok_`, and `ak_` session hashes. `admin_role` currently contains `ADMIN`, `FINOPS`, and `OPS`, not the requested `SUPERADMIN`, `ADMIN`, `USER`.
4. Saruman owns migrations, donation financial transitions, and the ledger, but the current running service has no payout command surface or withdrawal-result processor. Tolkien batch/hold code directly writes shared financial tables and must be reconciled with the authoritative ownership rules before withdrawal work.
5. The checked-in frontend has implemented settings, overlay token rotation, bank-account add/list, balance, donation intake, and donation monitoring pages; streamer donations and payouts remain explicit placeholders.
6. User-facing text currently says `Inflora Admin`; the target label is `Inflora Backoffice`. This is a presentation change, not an authorization change.

## Non-negotiable safety rules

- Firebase ID tokens are verified at a trust boundary; the browser never supplies a role that the server trusts.
- Roles are persisted in the Inflora database and resolved server-side. Firebase custom claims may mirror roles for convenience, but they are not the sole authorization source.
- Every privileged action records actor identity, role, reason, request ID, idempotency key where applicable, and resource.
- Financial state is owned by Saruman and corrected with append-only ledger transactions.
- No direct database mutation is a recovery procedure. Use idempotent commands, outbox/inbox, dead letters, and audited operational tools.
- Do not remove legacy auth or `X-Actor-Id` until migration telemetry proves that all callers are migrated and a rollback path is tested.
