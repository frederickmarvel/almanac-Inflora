# 02 — Inflora Backoffice (naming, admin management, withdrawal operations)

> Planning only. This document owns: the rename of the visible admin area, backoffice information architecture, RBAC wiring inside it, fast-path withdrawal operations, batch processing, and the exception-handling/productivity controls. The financial engine details live in `03-withdrawals.md`; refer there for state machines and ledger postings.

---

## 1. Naming decisions (explicit)

| # | Decision | Detail |
|---|---|---|
| N-1 | Visible product name: **"Inflora Backoffice"**, brand wherever a human staff member logs in. | Frontend surface only (`frontend/src/routes/admin/+layout.svelte` currently renders "Inflora Admin" — change text, title, nav). |
| N-2 | Internal API paths: keep `/v1/me/*` for users. Keep **`/v1/admin/*`** for the existing monitoring API to avoid breaking the current `admin.ts` client now; new operational endpoints go under **`/v1/backoffice/*`**. Long-term (phase N) the `/v1/admin/*` prefix may be renamed wholesale behind a version bump — do NOT rename silently; it is a contract-level change. | Minimizes first-phase churn; the prefix is invisible to end users. |
| N-3 | Code identifiers named `admin…` are **not** renamed in Phase 1 (backoffice endpoints are new code → `backoffice.go` files). Renaming Go types/tables is a cosmetic refactor deferred until RBAC is landed. | Avoids a massive diff with no functional gain; prevents drift with existing migrations (table `admin_users` stays `admin_users`). |
| N-4 | Backoffice SPA route: keep `/admin` for now (bookmarks); add branded title + logo swap. New pages are added under `/admin/*`. | Again presentation-only; route rename can ship with the `/v1/admin → /v1/backoffice` API rename later. |
| N-5 | Error message copy and email templates must never say "Admin console"; use "Backoffice". | Polish, but the user asked for the rename explicitly. |

## 2. Information architecture of the Backoffice

Existing pages survive; new ones are added. Target nav (all gated by RBAC permissions, not by nav presence):

| Section | Pages | RBAC |
|---|---|---|
| Overview | summary tiles (existing `/admin` + payment/withdrawal KPIs) | `Donation:ReadAll`, `PayoutBatch:Create` |
| Donations | list, detail, override (existing) — add refund + receipt-resend buttons | `Donation:ReadAll`, `Donation:Override`, `Receipt:Resend` |
| **Payouts** (new) | payout queue (`REQUESTED`), per-payout detail, batch builder | `PayoutBatch:Create` |
| **Batches** (new) | batch list (DRAFT/EXECUTING/PARTIAL_FAILED/FAILED/COMPLETED), batch detail with per-payout rows, execute/approve, retry controls | `PayoutBatch:Execute`, `Payout:Review` |
| **Exceptions** (new) | `NEEDS_REVIEW` queue, stuck-work queue (`PROCESSING` older than the lease), dead letters surfaced, reconcile-drift list | `Payout:Review` |
| Holds | existing hold create/list/release | `FundHold:*` |
| Streamers | (new, SUPERADMIN) list, activate/deactivate, per-streamer balance snapshot | `User:Manage` |
| Team (new) | backoffice operator management, role assignment, sessions/revoke | `Admin:Manage` (SUPERADMIN) |
| Audit | read-only audit stream with filters | `Audit:Read` (SUPERADMIN) |
| System tools | event replay, provider-toolbox (health probe / retry webhook) | `Replay:Trigger` (SUPERADMIN) |

Every page's fetch goes through `frontend/src/lib/api/backoffice.ts` (new client). The old `admin.ts` is folded in or kept as an internal shim.

## 3. Admin management (operators)

- Creation flow: SUPERADMIN invites operator by email → creates `admin_users` row (`is_active=false`) → operator completes Firebase account creation (email/password) with link to their profile (frontend onboarding page) → system binds `firebase_uid` (lookup by verified **email** at first successful login for that pending row; operator confirms display name). Password is Firebase-managed from day one (no local password for new operators).
- Disable flow: `PATCH /v1/backoffice/users/{id}` `is_active=false` + Firebase `updateUser(disabled=true)` via Admin SDK; all `ak_` sessions for that admin are revoked in the same transaction. Audit both.
- Role changes: `POST /v1/backoffice/users/{id}/roles` — replacing role assignments requires SUPERADMIN and cannot target self-demotion without a second SUPERADMIN present (safety check: count of active SUPERADMINs > 1 before removing the last one's SUPERADMIN).
- **Every state mutation audit-logged** with actor + target + delta + reason (required string).

## 4. Fast-path (single payout) vs. batch processing

Per `schemas/03-http-api.md` §5-§6 and `01-event-catalog.md`, the pipeline is:

```
Streamer: POST /v1/me/payouts (Tolkien facade, USER)
   └─► Saruman command: reserve funds (posting template §3: STREAMER_AVAILABLE→STREAMER_PAID, opKey create_payout:<id>)
        └─► payouts.status=REQUESTED, outbox payout.requested.v1
Backoffice: payout queue shows REQUESTED rows (FIFO by requested_at)
   ├─ fast path (single): POST /v1/backoffice/payouts/{id}/submit
   │     └─► Saruman: payouts.status=PROCESSING (marker claim) →
   │          palantir WithdrawalService.CreateWithdrawal (gRPC, idempotency_key=payout id) →
   │          provider → pg.gateway.withdrawal.completed|failed.v1 → Saruman completes/fails (templates §4/§5)
   └─ batch path: POST /v1/backoffice/payout-batches (select or auto_select FIFO)
         └─► DRAFT → submit (maker) → approve (checker — different actor) → EXECUTING
              └─► palantir per-payout CreateWithdrawal, or provider batch API if available (see 03 §6)
```

**Batch membership rules:** every payout in a batch must be `REQUESTED`, no active holds for its streamer (`fund_holds` ACTIVE check at batch build AND at execute — TOCTOU guard), ≥ `MIN_WITHDRAWAL_IDR` (already a CHECK), amount already reserved (posting §3 is done at request time, so batches merely group **already-reserved** payouts — the batch is a routing/ops construct, not a money-movement construct). This is the crucial design property that makes partial failure safe: **a failed payout inside a batch only needs its dead-letter + reversal template §5; it cannot damage other payouts' reservations.**

## 5. Batch algorithm (implementer spec)

Input: `payout_ids` (explicit list) or `auto_select=true`. Output: `payout_batches` row `DRAFT` + per-payout `payout.batched.v1`.

1. Enumerate candidates: `status='REQUESTED' AND batch_id IS NULL`, streamer has no ACTIVE hold, `requested_at` FIFO.
2. For explicit lists: validate each id is a candidate; if any is not → `PAYOUT_NOT_BATCHABLE` 409 listing exact ids (do not partially create).
3. `auto_select` default **picks max 50 payouts / max total 100_000_000 IDR** per batch (configurable `PAYOUT_BATCH_MAX_COUNT`, `PAYOUT_BATCH_MAX_TOTAL_IDR`) — hard-coded caps are a backstop against a typo-moving-the-company problem, and subject to `05-phases-and-gates.md` config gate.
4. Grouping strategy: default is one batch per execution round across all streamers (provider bulk API is out of MVP scope). Per-bank-account grouping becomes relevant only if the provider batch API is adopted.
5. Creation is a single SQL transaction (in Saruman): `INSERT payout_batches (DRAFT)` + `UPDATE payouts SET batch_id, status='BATCHED' WHERE id = ANY(...)` with a `FOR UPDATE` row lock per payout; emits one `payout.batched.v1` per payout (producer = **saruman**, per D-004 — do not repeat the current tolkien-producer mistake).
6. Adding a payout to an existing DRAFT batch: `POST /v1/backoffice/payout-batches/{id}/payouts` with the same candidate rules.

Execution (see `03-withdrawals.md` for the state machine and failure policy — it is the authority; this section is the operator flow): maker `submit`, checker `approve`; on execute, `payout_batches.status=EXECUTING`, per-payout `PROCESSING`; results arrive asynchronously via `pg.gateway.withdrawal.*` events consumed by Saruman; batch resolves to `COMPLETED` / `PARTIAL_FAILED` / `FAILED` from the per-payout outcome counts (spec: `payout.batch.completed.v1` requires `settled_count == payout_count`).

## 6. Exception handling (what the Backoffice must render + allow)

The Backoffice is the operator's tool to resolve these problems; recovery is **never** a raw SQL UPDATE (README safety rule). Each queue below enforces the "no direct DB mutation" rule by exposing only audited commands:

| Problem class | Detection | Allowed operator actions |
|---|---|---|
| Payout `PROCESSING` longer than the lease (stuck) | sweep query (Saruman cron: `PROCESSING` where `processed_at` < now - lease) | 1) `Reconcile` (compare with provider status — see 03 §9); 2) `Retry` (see rules below); 3) `ForceFail` (terminal FAILED + posting §5 release, reason mandatory). |
| `pg.gateway.withdrawal.failed.v1` (bank rejected / provider failure) | event handled automatically → payout FAILED + §5 release; surfaces in Exceptions queue with `failure_reason` | `Retry` (creates a **new** payout request or re-submits — see retry rule); `Dismiss` (acknowledge). |
| `pg.gateway.withdrawal.completed.v1` where payout is already FAILED/unknown (late/duplicate result) | idempotency via consumer inbox + operation key | auto-safe (inbox dedup); if gate exceeds threshold → discrepancy row for investigation; operator `ForceSettle` (SUPERADMIN, reason + compensating posting if needed). |
| Provider unknown state (timeout on CreateWithdrawal → no event ever) | 03 §7 policy: mark NEEDS_REVIEW after lease expiry × 2 | `RefreshProviderState` (command → Pivot/Midtrans status lookup RPC), then resolution per result. |
| Batch `PARTIAL_FAILED` | auto on per-payout results | per-payout Retry/Dismiss; batch `Close` (finalize; exposes which payouts still unresolved). |
| Hold expired while a payout is in flight | Saruman hold-expiry cron | no operator action normally; if expiry invalidated a payout request, the payout request fails at creation-check time only (holds block creation, not in-flight settle). |
| Dead-lettered withdrawal event | `event_dead_letters` rows surfaced in System tools | `ReplayEvent` (SUPERADMIN) re-publishes the original envelope with original `event_id` (inbox dedups); `DropEvent` with mandatory IR note. |
| Reconciliation drift | Saruman nightly recon (`reconciliation_drift`) | backoffice read-only view + "create resolution task" linking to a documented posting (compensation, template-linked op key). |
| Provider outage (Midtrans down) | provider-side timeouts; CREATE attempts failing | `Circuits` board: show provider health; operator `PauseExecution` (stop batching new submits), `Resume`; queue `SCHEDULED` status holds. |

**Retry rules (money-guard):** A retry must never double-pay.
- If payout is terminal (SETTLED): retry is refused.
- If FAILED (no provider payout created, i.e., `gateway_withdrawals` row absent/definitively-failed): retry creates a **new provider attempt row** reusing the same payout id as idempotency key — the reservation (posting §3) persists; no new ledger movement.
- If status ambiguous (`PROCESSING` + no event): retry is replaced by `RefreshProviderState` first (unknown = do not blind-resend money).
- Every retry bumps `attempts` and is audit-logged with the operator + reason.

## 7. Endpoint inventory (new; all Backoffice-auth + permission-checked)

Grouped by ownership — remember Tolkien is the facade, **Saruman executes all financial mutations**:

- `GET /v1/backoffice/payouts?status=&cursor=` (queue)
- `GET /v1/backoffice/payouts/{id}` (detail incl. ledger postings for it)
- `POST /v1/backoffice/payouts/{id}/refresh-provider-state` → Saruman command → Palantir RPC
- `POST /v1/backoffice/payouts/{id}/retry` ; `POST /v1/backoffice/payouts/{id}/force-fail` (SUPERADMIN) ; `POST /v1/backoffice/payouts/{id}/dismiss`
- `POST /v1/backoffice/payout-batches` (create DRAFT; `payout_ids` OR `auto_select`)
- `GET /v1/backoffice/payout-batches?status=&cursor=`
- `GET /v1/backoffice/payout-batches/{id}`
- `POST /v1/backoffice/payout-batches/{id}/payouts` (add to DRAFT)
- `POST /v1/backoffice/payout-batches/{id}/submit` (maker) ; `POST /v1/backoffice/payout-batches/{id}/approve` (checker) ; `POST /v1/backoffice/payout-batches/{id}/execute` (system step after approval)
- `POST /v1/backoffice/payout-batches/{id}/close` (finalize PARTIAL_FAILED)
- `GET /v1/backoffice/exceptions?kind=stuck|needs_review|dead_letters|drift`
- `POST /v1/backoffice/events/{event_id}/replay` (SUPERADMIN)
- `GET|POST /v1/backoffice/streamers…` ; `GET|POST|PATCH /v1/backoffice/users…` ; `GET /v1/backoffice/audit`
- Legacy renamed-but-still-working aliases for the current frontend: `GET /v1/admin/donations*` etc. (kept as-is in phase 1; see N-2).

Modifications to existing endpoints: `POST /v1/admin/holds`, `GET /v1/admin/holds`, `DELETE /v1/admin/holds/{id}`, `POST /v1/admin/payout-batches`, `GET /v1/admin/payout-batches`, `POST /v1/admin/payout-batches/{id}/execute`, `POST /v1/admin/email-records/{donation_id}/resend` move from `admin()` (internal key + X-Actor-Id) to Backoffice session + permission checks, and their body mutations are re-pointed at Saruman commands (D-004).

## 8. RBAC wiring inside the Backoffice

Single chain: `firebase middleware → identity resolution → requirePerm(...)`. Roles come back as a list so the UI can hide controls, but **hiding is not authorization** — every server endpoint re-checks. The maker-checker constraint (different actor for submit/approve) is enforced at the API layer, with a clear `MAKER_CHECKER_CONFLICT` 409 error code (add to `03-http-api.md` error table as part of phase N docs update).

## 9. Observability requirements for the Backoffice

- Event annotations on all queue views: age (requested_at → now), attempts, lease state, provider ref, last event id.
- Backoffice-specific dashboards: queue depth by status; `PROCESSING` age histogram; batch resolution times; retry counts; drift count; circuit state.
- Every `4xx/5xx` backoffice call logs actor, endpoint, perm requirement, decision (allow/deny). Denials at rate>threshold → alert (possible breach probe).

## 10. Acceptance criteria (Backoffice slice)

1. `Inflora Backoffice` branding visible; no "Inflora Admin" user-visible string remains.
2. Legacy `X-Actor-Id` human-auth path removed for holds/batches; actor is the verified operator; no route acts on client-supplied actor identity.
3. A FINOPS-mapped legacy operator cannot open streamer management or audit pages.
4. Maker/checker blocks same-actor approve.
5. Every exception class in §6 has a working operator action verified by integration tests (they are listed in `05-phases-and-gates.md`).