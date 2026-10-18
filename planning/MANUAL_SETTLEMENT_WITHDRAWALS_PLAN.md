# Manual Gateway Settlement Tracking and Creator Withdrawals

> **Status:** Authoritative focused execution plan; planning only.
>
> **Scope:** Manual gateway settlement tracking for captured donations and
> creator-initiated withdrawals, including financial state, auditability,
> evidence, reconciliation, and operational controls.
>
> **Explicitly excluded:** refunds and admin frontend development.
>
> **Implementation gate:** Do not implement production manual actions until the
> unresolved decisions in §4 are approved and reflected in the frozen contracts.

## 1. Goal

Deliver an auditable backend workflow in which:

1. Provider-captured donations can be tracked until funds are manually confirmed
   as settled into Inflora's gateway/merchant balance.
2. A creator can request withdrawal of available funds without overdrawing,
   including under concurrent requests.
3. Operations can record the real-world withdrawal outcome using authenticated,
   idempotent, evidence-backed actions.
4. Every financial transition uses append-only ledger postings and can be
   reconciled to provider evidence.

This plan narrows and, for this scope, overrides the automated-provider
assumptions in Phase 10 of
[`AI_BACKEND_COMPLETION_PLAN.md`](AI_BACKEND_COMPLETION_PLAN.md). Frozen schemas,
posting templates, operation keys, ownership decisions, and the wire guide still
take precedence.

## 2. Scope boundaries

### Included

- Track captured-but-unsettled and settled donation value.
- Record gateway settlement batches or individual settlement evidence.
- Expose settlement status needed to calculate withdrawable creator balance.
- Accept creator withdrawal requests through the existing authenticated Tolkien
  HTTP boundary.
- Atomically reserve funds in Saruman.
- Track a manual transfer/disbursement lifecycle in Palantir.
- Record withdrawal success or failure and settle or release the reservation.
- Persist actor, reason, timestamps, idempotency keys, and evidence references.
- Reconciliation queries, operational runbook steps, and automated invariant
  tests.

### Excluded

- Refund requests, refund provider execution, and refund ledger postings.
- Admin web pages, dashboards, forms, or other admin frontend work.
- Inventing an undocumented provider payout or settlement API.
- Automated bank-statement ingestion unless separately approved.
- Multi-currency behavior.
- Tax, KYC, sanctions, or regulatory policy design beyond enforcing an approved
  eligibility decision supplied by the owning boundary.

Backend/internal endpoints or CLI tooling needed to execute approved manual
actions are in scope; a graphical admin interface is not.

## 3. Required invariants

1. **Settled funds only:** captured funds are not withdrawable until the approved
   settlement rule marks them available.
2. **Single financial owner:** Saruman owns creator balance, reservations, payout
   aggregate state, and ledger postings.
3. **Provider/manual execution owner:** Palantir owns gateway settlement evidence
   and the external/manual withdrawal execution record.
4. **Authenticated facade:** Tolkien authenticates creator requests and exposes
   read models; it does not write ledger entries.
5. **No double spend:** balance validation, reservation, payout creation, and the
   payout-requested outbox event occur in one serializable/retryable transaction.
6. **Append-only correction:** success, failure, release, or correction creates a
   new transaction; prior ledger entries are never edited or deleted.
7. **Idempotent manual actions:** retries with the same operation key return the
   same result; conflicting payloads are rejected.
8. **Evidence is referenced, not exposed:** evidence has integrity metadata and
   controlled access; secrets and full bank-account details never enter logs.
9. **One terminal outcome:** settlement success/failure races and withdrawal
   success/failure races resolve to one legal terminal state.
10. **Auditability:** every manual state transition records who acted, why, when,
    the request/operation key, and the evidence reference.

## 4. Blocking decisions

These decisions must be approved before production implementation. Phase 0 may
prepare decision records and contract diffs, but must not silently choose values.

| ID | Decision | Minimum question to resolve | Blocks |
|---|---|---|---|
| MSW-001 | Identity and RBAC | Which authenticated human/service roles may record settlement evidence, initiate transfer, and mark withdrawal success/failure? | Manual command authorization and audit actor model |
| MSW-002 | Maker-checker | Which actions/amounts require a second distinct approver, and can one actor both prepare and approve? | State machine and approval records |
| MSW-003 | Gateway evidence | Required evidence type, storage system, retention, checksum/hash, external reference, amount/date matching tolerance, and redaction policy | Settlement/withdrawal completion contracts |
| MSW-004 | Business-day calendar | Calendar owner, timezone, weekends, Indonesian public/bank holidays, cutoff time, and SLA behavior | Availability dates, overdue alerts, reconciliation |
| MSW-005 | Settlement granularity | Individual donation, provider batch, bank-credit line, or a supported combination; allocation rule for partial settlement | Schema and ledger operation keys |
| MSW-006 | Manual withdrawal execution | Exact prepare/submit/confirm/fail lifecycle and which step means funds left Inflora control | Withdrawal state machine and posting point |
| MSW-007 | Limits and eligibility | Minimum/maximum amount, fees, KYC/bank verification gates, holds, velocity limits, and cooldowns | Creator request validation |
| MSW-008 | Failure correction | Who may correct erroneous manual evidence or terminal status, and which compensating postings are permitted? | Recovery runbook and correction contracts |

Decision output must update, as applicable:

- [`CONTRACT_DRIFT.md`](CONTRACT_DRIFT.md);
- [`WIRE_GUIDE.md`](WIRE_GUIDE.md);
- `schemas/02-database-schema.sql`;
- `schemas/03-http-api.md`;
- `schemas/04-grpc-proto.md`;
- `schemas/08-flow-diagrams.md`;
- `schemas/09-internal-provider-events.md`;
- `schemas/10-posting-templates.md`;
- `schemas/11-operation-keys.md`;
- ops runbooks and audit/redaction rules.

## 5. Target lifecycle

Names below are conceptual until Phase 0 freezes exact enum, event, table, RPC,
and endpoint names.

### 5.1 Gateway settlement tracking

1. A donation reaches the existing captured/charged state.
2. Its creator value remains unavailable or pending settlement according to the
   approved posting template.
3. An authorized operator records provider settlement evidence for a settlement
   batch or individual item.
4. Palantir validates command idempotency, evidence metadata, amount/currency,
   provider reference uniqueness, and permitted state transition.
5. Palantir persists the settlement record and emits the frozen internal result
   through its transactional outbox.
6. Saruman consumes the result through a durable inbox, verifies allocation and
   expected value, posts the settlement transaction, and updates the donation or
   settlement projection atomically.
7. Reconciliation reports unmatched captures, unmatched bank/provider evidence,
   partially allocated batches, amount differences, and overdue settlements.

No manual action may mutate an existing capture or ledger row to make totals
match.

### 5.2 Creator withdrawal

1. Tolkien authenticates the creator, validates request shape and bank-account
   ownership, and enforces HTTP idempotency.
2. Tolkien sends one authenticated command to Saruman.
3. Saruman locks the relevant balance/account state and, in one transaction:
   validates settled available funds and approved eligibility rules; creates the
   payout; posts reservation entries; and writes the payout-requested outbox
   event.
4. Palantir creates one manual withdrawal execution record for the stable payout
   operation key.
5. Authorized operations perform the external transfer and attach the required
   evidence through the approved maker-checker workflow.
6. Palantir records exactly one success or failure result and publishes it via
   outbox.
7. Saruman consumes the result idempotently. Success completes the payout using
   the frozen posting template; failure creates a release/compensation transaction
   restoring availability.
8. Tolkien exposes creator-visible status and history from Saruman read models.

## 6. Phased execution

### Phase 0 — Decisions and contract freeze

**Goal:** Resolve §4 and remove contradictions before code changes.

**Deliverables:**

- Approved decision record for MSW-001 through MSW-008.
- Exact lifecycle diagrams and legal transition tables.
- Contract diffs for database, HTTP/gRPC, events, posting templates, operation
  keys, error codes, audit fields, and evidence metadata.
- Explicit compatibility/migration strategy for existing donation, payout, and
  gateway records.
- Threat model covering privilege abuse, evidence tampering, replay, conflicting
  approvals, PII leakage, and terminal-state correction.

**Exit gate:** No unresolved owner, actor, transition, posting, idempotency, or
evidence semantic remains.

### Phase 1 — Persistence and read models

**Goal:** Add reversible schema support without service behavior.

**Deliverables:**

- Settlement record/batch/allocation persistence according to MSW-005.
- Manual withdrawal execution and approval persistence according to MSW-002 and
  MSW-006.
- Evidence-reference metadata with uniqueness and integrity constraints.
- Audit actor/reason fields and immutable action history.
- Indexes and constraints for provider references, operation keys, legal status,
  and one-terminal-result behavior.
- Read models for pending settlement, settled availability, pending withdrawal,
  and reconciliation exceptions.

**Tests:** migration up/down/re-up, uniqueness under concurrency, invalid
transition rejection, actor separation where required, and redaction-safe
fixtures.

**Exit gate:** The database makes duplicate business operations and structurally
illegal records impossible or explicitly detectable.

### Phase 2 — Manual gateway settlement backend

**Goal:** Record and apply settlement evidence end to end.

**Deliverables:**

- Authenticated internal command/CLI boundary; no admin frontend.
- Palantir validation, durable persistence, and outbox publication.
- Saruman durable consumption, allocation validation, posting, and projection.
- Idempotent retries and conflict responses.
- Queries for unmatched, partial, mismatched, and overdue settlement items.
- Audit events and metrics without evidence content or sensitive identifiers in
  logs.

**Tests:** duplicate command, conflicting reuse of idempotency key, duplicate
evidence reference, partial allocation, amount mismatch, out-of-order delivery,
crash after commit/before ACK, and repeated result delivery.

**Exit gate:** A captured donation becomes withdrawable exactly once only after
valid settlement evidence is recorded and applied.

### Phase 3 — Creator withdrawal request and reservation

**Goal:** Allow safe creator requests without external/manual completion yet.

**Deliverables:**

- Tolkien creator request and history endpoints from the frozen contract.
- Bank-account ownership and eligibility validation.
- Saruman serializable/retryable reservation transaction.
- Stable payout operation key and payout-requested outbox event.
- Creator-visible states that do not reveal internal evidence or operator data.

**Tests:** concurrent requests against one balance, duplicate HTTP request,
insufficient funds, unsettled funds exclusion, wrong-owner bank account, limits,
holds, and transaction rollback.

**Exit gate:** Concurrent requests cannot reserve more than the settled available
balance.

### Phase 4 — Manual withdrawal execution and terminal posting

**Goal:** Execute, approve, and record the real-world transfer safely.

**Deliverables:**

- Palantir manual execution lifecycle and evidence capture.
- RBAC and maker-checker enforcement at every manual command boundary.
- Idempotent success/failure result publication.
- Saruman completion and release/compensation postings.
- Correction workflow limited to approved append-only operations.
- Creator-visible status/history updates.

**Tests:** duplicate prepare/approve/settle/fail, same actor prohibited where
required, unauthorized role, missing/invalid evidence, settle/fail race, crash
windows, stale approval, and terminal correction rules.

**Exit gate:** Every reservation reaches exactly one legal terminal financial
outcome, with complete evidence and audit lineage.

### Phase 5 — Reconciliation, alerts, and operations

**Goal:** Make manual processing supportable and recoverable.

**Deliverables:**

- Reconciliation report for gateway captures, settlement evidence, settled ledger
  value, withdrawal reservations, transfer evidence, and terminal postings.
- Alerts for overdue settlement, stale withdrawal, unmatched evidence, amount
  mismatch, duplicate reference, and outbox/dead-letter backlog.
- Runbook for normal processing, maker-checker handoff, rejected evidence,
  provider outage, correction, replay, and escalation.
- Business-day calculations only after MSW-004 is approved.
- Audited inspection/replay tooling using existing idempotent state machines.

**Tests:** clock/calendar boundaries, replay, operator retry, dead-letter recovery,
report invariants, and redaction/access controls.

**Exit gate:** On-call and finance operations can identify every incomplete or
mismatched item and recover it without direct database mutation.

### Phase 6 — End-to-end qualification and handoff

**Goal:** Prove the workflow under concurrency and failure before rollout.

**Deliverables:**

- Full captured donation → manual settlement → available balance → creator
  withdrawal → manual transfer → terminal ledger E2E.
- Failure-injection matrix at every transaction, outbox, inbox, approval, and ACK
  boundary.
- Security/RBAC and evidence-access test report.
- Migration, rollback, deployment, and operational handoff report.
- Documentation drift review and links from the planning index and runbooks.

**Exit gate:** All invariants in §3 have linked evidence, blockers are closed, and
known limitations are explicitly approved.

## 7. Validation matrix

At minimum, qualification must prove:

- Settlement evidence cannot be reused across incompatible records.
- Total settlement allocation cannot exceed the evidence amount.
- Unsettled creator value cannot be reserved for withdrawal.
- Concurrent creator withdrawals cannot overdraw.
- A duplicate manual command produces no duplicate external or ledger effect.
- A success/failure race yields one terminal outcome.
- Failed withdrawal restores availability exactly once.
- Maker and checker are distinct when policy requires it.
- Unauthorized actors cannot read evidence or execute manual actions.
- Logs contain no raw tokens, full bank accounts, provider secrets, or evidence
  payloads.
- Crash/restart and redelivery converge through outbox/inbox idempotency.
- Ledger debits equal credits for settlement, reservation, completion, release,
  and approved correction templates.

## 8. Completion evidence

The phase is not complete without links to:

- approved MSW-001 through MSW-008 decisions;
- contract diffs and generated-code validation;
- migration and concurrency test output;
- authorization and maker-checker test output;
- settlement and withdrawal E2E output;
- failure-injection results;
- ledger invariant and reconciliation reports;
- evidence integrity/access/redaction checks;
- updated runbook and rollback procedure; and
- an explicit statement that refunds and admin frontend work were not included.

## 9. Immediate next action

Execute **Phase 0 only**. Resolve the eight blocking decisions and update the
frozen contracts. Do not begin backend implementation from conceptual names in
this document, and do not add refunds or admin frontend work to this scope.
