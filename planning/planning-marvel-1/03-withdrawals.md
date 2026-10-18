# 03 — Withdrawals (financial ownership, state machines, idempotency, recovery)

> Planning only. This document is the **authority for withdrawal correctness**. It reconciles the spec (`schemas/03-http-api.md`, `01-event-catalog.md`, `09-internal-provider-events.md`, `10-posting-templates.md`, `11-operation-keys.md`, `CONTRACT_DRIFT.md` D-004/D-005/D-006) with the current code (`inflora-tolkien/internal/app/batches.go|holds.go` mutate financial tables directly — must stop).

---

## 1. Ownership model (who writes what)

Per D-004/D-006 and WIRE_GUIDE §6, enforced from Phase 1 of this work:

| Responsibility | Service | Table |
|---|---|---|
| Authenticate streamer/admin, validate request shape, HTTP facade | tolkien | — (reads `payouts` for views only) |
| **Payout aggregate + balance reservation + all payouts/payout_batches state transitions + payout ledger postings** | **saruman** | `payouts`, `payout_batches`, `ledger_*` |
| Holds (non-financial rows; eligibility input) | tolkien per WIRE_GUIDE §6 (`fund_holds`: tolkien) — but position as **hold command = saruman-validated eligibility**; write stays tolkien for now, flagged as drift-discussion item | `fund_holds` |
| Provider execution + `pg.gateway.withdrawal.*` events | palantir | `gateway_withdrawals`, `webhook_events` |

> **Explicit refactor item R-1:** move `CreateBatch`/`ListBatches`/`ExecuteBatch` (tolkien `app/batches.go`) behind Saruman commands: tolkien keeps the HTTP handlers and actor identity; SQL writes to `payouts`/`payout_batches` and the `payout.batched.v1`/`payout.batch.executed.v1` outbox rows move to Saruman. Same for direct ledger writes anywhere outside Saruman — prohibited (WIRE_GUIDE rule 6 + D-004).

## 2. Canonical withdrawal state machine (target)

### 2.1 `payouts.status` — current enum `{REQUESTED, BATCHED, PROCESSING, SETTLED, FAILED}` is **insufficient**; add states. Migration (new enum values, ALTER TYPE):

| State | Meaning | Entered by | Exit conditions |
|---|---|---|---|
| `REQUESTED` | funds reserved (posting §3 done) | saruman (`create_payout` command) | batch member → `BATCHED`; fast-path submit → `PROCESSING`; terminal reject → `FAILED`(with release) |
| `BATCHED` | member of a DRAFT/EXECUTING batch | saruman (batch create/add) | batch execute → `PROCESSING`; batch cancel → back to `REQUESTED`; admin cancel → `FAILED` + release |
| `PROCESSING` | provider attempt in flight (lease active) | saruman (submit/execute) | completed event → `SETTLED`; failed event → `FAILED`; lease expiry×2 → `NEEDS_REVIEW` |
| `NEEDS_REVIEW` | **NEW** — provider state unknown (timeout/no event) | sweep cron + `RefreshProviderState` returning indeterminate | operator resolution → `SETTLED` / `FAILED` / retry path → `PROCESSING` |
| `SETTLED` | terminal — provider paid bank (posting §4 appended) | saruman on `pg.gateway.withdrawal.completed.v1` | terminal (no exit) |
| `FAILED` | terminal — provider rejected/operator aborted; funds released (posting §5 appended) | saruman on `pg.gateway.withdrawal.failed.v1` or operator ForceFail | terminal (no exit) |

Transition guard (implement in one place, `saruman internal/service/payout.go` `transition()`): only listed transitions allowed; any attempt to leave `SETTLED`/`FAILED` is rejected with `INVALID_TRANSITION` (mirrors the compiled state checks in `10-posting-templates.md` §7).

### 2.2 `payout_batches.status` — keep `{DRAFT, EXECUTING, COMPLETED, PARTIAL_FAILED, FAILED}` (+ `SCHEDULED` optional for provider-outage pause, flagged D-027):

| State | Rule |
|---|---|
| `DRAFT` | assembling; payouts `BATCHED`; may add/remove members; may cancel → members back to `REQUESTED` |
| `EXECUTING` | approved by checker; payouts `PROCESSING`; batch stays here until **all** member outcomes are terminal |
| `COMPLETED` | all members `SETTLED` (publishes `payout.batch.completed.v1`, producer **palantir** per catalog — flag D-028: batch-resolution counting is done by Saruman from per-payout events; resolve this ownership row explicitly) |
| `PARTIAL_FAILED` | mixed outcomes; operator `Close` → documented; unresolved members remain tracked |
| `FAILED` | all members failed |

### 2.3 Batch membership invariant

- `payouts.batch_id` gains a real FK→`payout_batches.id` (migration). `SET NULL` on batch delete is forbidden instead (no batch deletion after DRAFT→EXECUTING; DRAFT cancel unsets each row individually in a transaction).
- A payout appears in at most one batch (partial unique index `WHERE batch_id IS NOT NULL` enforced by `UPDATE … WHERE batch_id IS NULL` claim pattern under `FOR UPDATE`).

## 3. Commands (Saruman command surface — new)

Tolkien calls these via the **internal HTTP command endpoint** `POST /v1/internal/saruman/payout-commands` style surface (preferred, matches existing internal HTTP matrix) OR gRPC `:7002` — **the implementer picks ONE and adds the row to WIRE_GUIDE §5. Do not invent both.** For each command: request `{command, payload, idempotency_key, actor, request_id}`; response is synchronous for validation/reservation, asynchronous provider parts go through events.

Commands (all Saruman-owned, idempotent via `operation_key` per `11-operation-keys.md`):

| Command | Posting/opKey | Publishes |
|---|---|---|
| `CreatePayout` (from `POST /v1/me/payouts`) | `create_payout:<payout_id>` postings §3: STREAMER_AVAILABLE DEBIT / STREAMER_PAID CREDIT | `payout.requested.v1` |
| `CreateBatch`, `AddToBatch`, `CancelBatch` | (batch op keys TBD — extend `11-operation-keys.md`): `create_batch:<id>`, `batch_assign:<batch_id>:<payout_id>`, `cancel_batch:<id>` | `payout.batched.v1` (per payout), `payout.batch.executed.v1` (on final submission row) |
| `SubmitPayout` (fast path) / `SubmitBatch` | `submit_payout:<payout_id>` / `submit_batch:<batch_id>` | (provider call flows via palantir CreateWithdrawal) |
| `RefreshProviderState` | n/a (read-only RPC to palantir) | result → sweep transitions |
| `RetryPayout`, `ForceFailPayout`, `ResolvePayout` | reuses `create_payout` reservation; `fail_payout:<payout_id>` for release | `payout.failed.v1` etc. |

Precondition checks in Saruman (must be in the same serializable TX as the reservation — `10-posting-templates.md` §3): available balance ≥ amount (from ledger account row lock), no ACTIVE `fund_holds` for streamer, amount ≥ 10000 (CHECK), bank account belongs to streamer and `is_verified`.

## 4. Ledger wiring (exact templates — from `10-posting-templates.md`, already frozen)

| Lifecycle point | Template | OpKey | Net effect |
|---|---|---|---|
| Request | §3 PAYOUT_RESERVATION | `create_payout:<payout_id>` | STREAMER_AVAILABLE −amt → STREAMER_PAID +amt |
| Settle | §4 PAYOUT_COMPLETION | `complete_payout:<payout_id>` | closes STREAMER_PAID (terminal entries; balance unchanged) |
| Fail | §5 PAYOUT_FAILURE_RELEASE | `fail_payout:<payout_id>` | STREAMER_PAID −amt → STREAMER_AVAILABLE +amt (linked compensation, `reversal_of` set) |

Invariants: append-only; UNIQUE `operation_key`; balanced TX; never UPDATE/DELETE ledger rows. Tests assert post-failure `STREAMER_AVAILABLE` equals pre-request balance exactly (the §3→§5 pair must net to zero).

## 5. Event flow (frozen + new topics)

Existing frozen producers consumers apply (catalog + wire guide). New/changed rows required:

| Event | Producer | Consumer | Notes |
|---|---|---|---|
| `payout.requested.v1` | **saruman** | palantir, analytics | today's doc says tolkien produces — **already drifted in code-gen plan; keep saruman (D-004)**; update WIRE_GUIDE §3 row |
| `payout.batched.v1`, `payout.batch.executed.v1` | **saruman** | palantir, analytics | same drift correction as above |
| `pg.gateway.withdrawal.completed.v1` / `.failed.v1` | palantir | saruman | frozen payload in `09-internal-provider-events.md`; **palantir adds batch-level fields if batch API used** (D-029) |
| `pg.gateway.withdrawal.batch.*.v1` | palantir | saruman | **NEW** — only if provider batch API adopted (defer; see §6) |
| `payout.settled.v1` / `payout.failed.v1` | saruman | analytics (+ backoffice push if later) | produced on terminal transitions |
| `payout.batch.completed.v1` / `payout.batch.failed.v1` | **saruman** (batch resolution owner) | analytics | resolves catalog ambiguity (catalog says palantir) — contract drift row D-028 |

## 6. Palantir integration

- Use existing `WithdrawalService.CreateWithdrawal` / `SettleWithdrawal` proto (`proto/palantir/v1/withdrawal.proto`). `CreateWithdrawalRequest` fields: `saruman_payout_id, streamer_id, amount_idr, bank_account_ref, idempotency_key, requested_at_unix`. `idempotency_key = payout id` (stable, replayed attempts reuse it).
- **Batch API**: MVP does NOT assume a provider bulk-disbursement API. Each batch executes as N `CreateWithdrawal` calls (rate-limited, sequential with backoff). If the provider later receives a bulk API, add `ExecuteBatch` RPC + `pg.gateway.withdrawal.batch.*` events behind D-029 — do not build a speculative interface now.
- `SettleWithdrawal` handles result webhooks per D-003 pattern (palantir verifies signature, writes `gateway_withdrawals`, emits `pg.gateway.withdrawal.*`).
- Palantir-side idempotency: `(provider_name, saruman_payout_id)` UNIQUE in `gateway_withdrawals` (add constraint/index), so duplicate webhooks/retries collapse to one provider attempt.

## 7. Failure matrix (every class needs a designed behavior + test)

| # | Failure | Detection | Automatic behavior | Manual tool | Test |
|---|---|---|---|---|---|
| F-1 | Provider CreateWithdrawal timeout, no state | no event after `provider_timeout_sec` (config, default 60s) | mark PROCESSING (lease), sweep | RefreshProviderState | simulate palantir hang |
| F-2 | Webhook lost (provider paid but event never arrived) | sweep: PROCESSING age > lease | cannot self-heal → NEEDS_REVIEW | RefreshProviderState → ForceSettle path (posting §4 appended by command, idempotent) | drop NATS message, assert review |
| F-3 | Duplicate/late `completed.v1` after FAILED resolution | inbox dedup + operation key idempotency | auto-safe (terminal transition refusal) | none | emit duplicate, assert single §4 |
| F-4 | `failed.v1` for unknown payout | inbox; saruman lookup miss | dead-letter after retries | ReplayEvent / DropEvent | corrupt event id test |
| F-5 | Bank rejects (insufficient/frozen account) | `failed.v1` with reason | payout FAILED + §5 release + notify streamer (`payout.failed.v1`) | Retry after streamer updates bank | E2E with Pivot fake reject |
| F-6 | Partial batch failure | per-payout outcomes | batch PARTIAL_FAILED; unaffected payouts continue | per-payout Retry/Dismiss + batch Close | mixed-outcome dataset |
| F-7 | Provider outage | CreateWithdrawal connection errors | retain PROCESSING; pause new submits (circuit) | PauseExecution/Resume | toggle circuit in test |
| F-8 | Hold created between batch build and execute | Saruman execute re-checks holds; conflicting payout skipped to NEEDS_REVIEW with `HOLD_CONFLICT` | batch PARTIAL_FAILED on skip | operator resolves after hold release | race test |
| F-9 | Crash mid-batch-commit | single TX per batch membership claim; outbox in same TX (D-018) | exactly-once state | ReplayEvent | kill-injection test |
| F-10 | Ledger operation-key collision (double processing) | UNIQUE constraint | second attempt no-ops (idempotent) | none | concurrency test (k workers same event) |

## 8. Leases, retries, sweeps (concrete parameters)

- `PAYOUT_PROCESSING_LEASE_SEC` (default 600): a PROCESSING payout is "stuck" after 2× lease. Sweep cron (saruman `internal/cron`, currently holds recon) every `PAYOUT_SWEEP_INTERVAL_SEC` (default 120):
  1. Find PROCESSING older than 2× lease → set NEEDS_REVIEW, audit `SWEEP_STUCK`.
  2. Find NEEDS_REVIEW older than `PAYOUT_REVIEW_ESCALATION_SEC` (default 86400) → alert escalation (Slack webhook + `fraud_events`-adjacent marker).
  3. Expire stale holds (existing responsibility) — emit `fund_hold.released.v1`.
- Retry backoff uses shared `inflora-shared/retry` with the existing NATS `NATS_ACK_WAIT_SEC` semantics; a command that fails before reservation creates no rows; a command that reserves then fails publish retries from outbox (D-018 guarantees).
- No payout submission without an **acknowledged** `outbox_events` row for its `payout.requested.v1` (assert at execute time: gateway attempt row exists or is created in the same TX).

## 9. Reconciliation (daily proof)

Nightly `RECONCILIATION_CRON` (existing saruman) extends to withdrawals; for each non-terminal payout with a `gateway_withdrawals` row, compare provider status via palantir `GetWithdrawalStatus` (add this RPC to proto — D-030) where provider supports it (Midtrans IRIS status; Pivot deterministic):

- Provider SETTLED + payout not SETTLED → drift row `PROVIDER_AHEAD` → operator ForceSettle (posting §4, idempotent opKey).
- Provider FAILED + payout not FAILED → drift row `PROVIDER_BEHIND` → auto-post `fail_payout` release or force review.
- Provider unknown + payout old → NEEDS_REVIEW.
- Counts mismatches → insert `reconciliation_drift` and alert (existing drift table reused; new `kind='WITHDRAWAL'` rows).

## 10. Persistence changes (migration `00012_withdrawal_robustness`)

1. `ALTER TYPE payout_status ADD VALUE 'NEEDS_REVIEW'` (and `IF NOT EXISTS` guards in migrations; enum values append-only).
2. `payouts`: `attempts INT NOT NULL DEFAULT 0`, `lease_expires_at TIMESTAMPTZ`, `last_event_id UUID NULL`, `failure_reason` widened to `VARCHAR(200)`.
3. `payout_batches`: `submitted_by UUID NULL`, `approved_by UUID NULL`, `executed_at` exists; add `paused BOOLEAN NOT NULL DEFAULT FALSE`, `resolution_note TEXT`.
4. FK: `payouts.batch_id → payout_batches(id)`.
5. `gateway_withdrawals`: UNIQUE `(provider_name, saruman_payout_id)`; add `status_checked_at`, `last_known_provider_status VARCHAR(20)`.
6. `admin_roles`/`permissions` from `01-firebase-rbac.md` arrive in `00009-00011` before this file's content is unblocked (withdrawal commands need RBAC to be meaningful).
7. Down-migrations for every file, run + revert tested in CI (see `05-phases-and-gates.md`).

## 11. Contract drift rows to add (D-027…D-030)

- **D-027** — batch `SCHEDULED`/paused execution state (add enum value only if circuit-pause is implemented; otherwise reject the row).
- **D-028** — batch-resolution event ownership: `payout.batch.completed.v1`/`payout.batch.failed.v1` produced by Saruman (catalog currently says palantir).
- **D-029** — provider bulk batch API deferred; no batch-level palantir proto until a provider supports it.
- **D-030** — add `WithdrawalService.GetWithdrawalStatus` RPC for reconciliation; Midtrans IRIS + Pivot implementations only.

## 12. Acceptance criteria

1. Full E2E: signup → donation → settle → payout request → batch build → submit/approve → (Pivot) provider events → payouts SETTLED → ledger invariant checks green (streamer_available decreases by sum, streamer_paid zeroed).
2. Failure drill F-1–F-10 each passes with its listed test.
3. Zero direct SQL mutations of `payouts`/`payout_batches`/`ledger_*` from tolkien (static check: only `saruman` package appears in writer grep).
4. Kill-injection (crash between outbox publish and commit) leaves no double-reservation and no stuck DRAFT without members.
5. Recon finds seeded drift rows (injected test fixtures) and resolves via the tool matrix.