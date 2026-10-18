# 00 — Current State (verified baseline)

> Status: planning only. Every "current" statement below was verified by reading source or contracts on 2026-10-16 under `/home/ubuntu/inflora-dev/Streamer donation`.
> Anything marked **PROPOSED** is future work and must never be confused with what exists today.
> Source-of-truth order: read `schemas/00-frozen-contracts.md`, `CONTRACT_DRIFT.md`, `WIRE_GUIDE.md`, the relevant `schemas/*`, then this file.

---

## 1. Repository and service layout

Polyrepo Go backend under `backend/`. Six repos exist on disk:

| Repo dir | Service | HTTP | gRPC | WS | Deployed | Notes |
|---|---|---|---|---|---|---|
| `inflora-tolkien` | tolkien | `:8080` | — | — | yes | streamer + admin HTTP facade |
| `inflora-ingest` | ingest | `:8081` | — | — | yes | donor edge + webhook edge |
| `inflora-palantir` | palantir | — | `:7001` | — | yes | provider broker |
| `inflora-saruman` | saruman | `:8082` | `:7002` | — | partial | engine + ledger + migrations |
| `inflora-ws-gateway` | ws-gateway | `:8083` | — | `:8083/ws` | yes | OBS overlay gateway |
| `inflora-shared` | — (library) | — | — | — | lib | proto, events, auth, outbox, inbox, keys, retry, ledger |
| `inflora-erebor` | — | — | — | — | **empty** | do not plan anything against it |

- Single PostgreSQL 15+ database `inflora`. **Saruman is the sole migration runner** (`inflora-saruman/cmd/migrate`, `internal/migrate/runner.go`). WIRE_GUIDE §6 is the per-table writer matrix.
- NATS JetStream carries events. Subject shape `<topic>.<streamer_id>` (00-frozen-contracts §2). Producer ownership is canon in WIRE_GUIDE §3.
- All money is BIGINT IDR minor units. Envelope `{error:{code,message,request_id,details?}}` frozen (00-frozen-contracts §6). Internal HTTP uses header `X-Internal-Api-Key` (D-010), NOT `Authorization: Bearer`.

## 2. Current authentication (verified, pre-Firebase)

### 2.1 Streamers (dashboard)

- `inflora-tolkien/internal/app/app.go` implements `Signup` / `Login` / `ValidateSession` / `ValidateOverlay` / `RotateOverlay`.
- Passwords: `auth.HashPassword` → Argon2id (`inflora-shared/auth`), stored `streamers.password_hash`.
- Sessions: opaque token `sk_<base64url(32B)>`, bcrypt-hashed in `sessions.token_hash`, `purpose='SESSION'`, TTL 30 days **sliding** (`last_used_at` bump per validate). Issued on `POST /v1/auth/signup` and `/v1/auth/login`.
- Overlay: `ok_` token, `purpose='OVERLAY'`, TTL 90 days, cached 60s in `TokenCache`. Rotated via `POST /v1/me/overlay-token/rotate`. **`?token=ok_…` over WS; must not change**.
- Browser storage: `sessionStorage.inflora_sk`, `inflora_sk_expires_at`, `inflora_principal` — see `frontend/docs/AUTH.md`. No refresh-token flow.

### 2.2 Backoffice operators (current "Admin")

- `inflora-tolkien/internal/app/admin.go` implements `AdminLogin` / `AdminValidate`. Tables `admin_users`, `admin_sessions` (saruman migrations `00007_admin`, `00008_seed_admin`).
- `admin_role` enum = `{ADMIN, FINOPS, OPS}` (migration `00007_admin.up.sql:5`). **This is NOT the requested `SUPERADMIN/ADMIN/USER`.**
- Token `ak_`, bcrypt hash in `admin_sessions.token_hash`, TTL 12h (`App.AdminTTL`).
- `App.AdminPrincipal` carries `{AdminUserID, SessionID, Email, DisplayName, Role, ExpiresAt}`. **The role is loaded but never enforced** — no handler checks it.
- Seeded dev account (migration `00008_seed_admin`): `admin@inflora.local` / `inflora-admin`.

### 2.3 Key architectural facts for the Firebase cutover

- Streamer and backoffice identities are **separate tables** today (`streamers` vs `admin_users`) with separate session tables. There is no shared human-identity table.
- Streamer signup lowercases email before insert (`app.go:140`) and login looks up by `lower(email)` (`app.go:199`). The **admin** path has the inverse defect: `admin_users.email` is a case-sensitive `VARCHAR(320) UNIQUE` (migration `00007_admin.up.sql`) while `AdminLogin` looks up by `lower(email)` — a case-differing email can be inserted that the login query finds only with an exact-literal match via the unique index; normalize on insert (covered in `01 §4`, CITEXT).

## 3. Current HTTP surface (verified)

### 3.1 Tolkien routes (`inflora-tolkien/internal/httpapi/server.go:61-101`)

Streamer: `POST /v1/auth/signup|login|logout`, `GET /v1/me`, `GET /v1/me/balance`, `GET|PUT /v1/me/settings`, `GET|POST /v1/me/bank-accounts`, `POST /v1/me/overlay-token/rotate`.
Internal: `POST /v1/internal/validate-overlay-token`, `POST /v1/internal/send-receipt`.
Admin (legacy, **internal-key + `X-Actor-Id`, no role check**): `POST /v1/admin/holds`, `GET /v1/admin/holds`, `DELETE /v1/admin/holds/{id}`, `POST /v1/admin/payout-batches`, `GET /v1/admin/payout-batches`, `POST /v1/admin/payout-batches/{id}/execute`, `POST /v1/admin/email-records/{donation_id}/resend`.
Admin (new, `ak_` session, `adminSession` middleware): `POST /v1/admin/login`, `POST /v1/admin/logout`, `GET /v1/admin/me`, `GET /v1/admin/donations`, `GET /v1/admin/donations/summary`, `GET /v1/admin/donations/{id}`, `POST /v1/admin/donations/{id}/override`.

- The authority boundary is split: holds/batches use `admin()` (`httpapi/admin_holds.go:11-21` → `X-Internal-Api-Key` + `X-Actor-Id`); the monitoring surface uses `adminSession` (`httpapi/admin.go`). **These two mechanisms must be unified under RBAC.**
- `POST /v1/me/payouts` and `GET /v1/me/donations` are specified in `schemas/03-http-api.md` but **not implemented** in `server.go` today.

### 3.2 Client-side placeholders

- `frontend/src/lib/api/tolkien.ts` throws `NOT_IMPLEMENTED` for `/v1/me/donations` and `/v1/me/payouts`. Matches `frontend/docs/API.md` "Endpoints we don't call (yet)".

## 4. Donation engine (current, verified)

- `inflora-saruman/internal/subscriber/processor.go` consumes via durable inbox (`inflora-shared/inbox`): `donation.intent.created.v1` (`validateIntent`), `pg.gateway.topup.completed.v1` (`completeTopup`), `pg.gateway.topup.failed.v1` (`failTopup`), `pg.gateway.topup.expired.v1` (`expireTopup`).
- Transitions: `INTENT_CREATED → CHARGED (settlement PENDING)` on topup.completed; `→ FAILED` on failed/expired. `settlement_status ∈ {PENDING, SETTLED, FAILED}`.
- Capture postings (`postCapture`) already enforce the posting-template §1 shape (DONOR_CASH DEBIT, STREAMER_PENDING CREDIT, PLATFORM_REVENUE CREDIT, MDR_REVENUE CREDIT) and `operation_key = DonationCaptureKey(donation_id)` UNIQUE. Balance invariant asserted.
- **Settlement (`donation.settled.v1`) is specified but not yet in `processor.go`** — there is no handler that moves `STREAMER_PENDING → STREAMER_AVAILABLE` (posting template §2) yet. This is a prerequisite for any payout-eligibility logic.
- Saruman HTTP is health-only today (`internal/handler/health.go`). gRPC `:7002` is designed (WIRE_GUIDE) but the summary of `internal/grpc/` shows the dir exists; no live payout command surface is wired.

## 5. Payout / withdrawal current state (the biggest gap)

- `schemas/03-http-api.md` §5 defines `POST /v1/me/payouts`, §6 defines `POST /v1/admin/payout-batches`, `…/execute`, holds. `schemas/01-event-catalog.md` defines `payout.requested.v1`, `payout.batched.v1`, `payout.batch.executed.v1`, `payout.settled.v1`, `payout.failed.v1`, `payout.batch.completed.v1`, `payout.batch.failed.v1`, `fund_hold.created/released.v1`.
- `proto/palantir/v1/withdrawal.proto` **already declares** `WithdrawalService.CreateWithdrawal` / `SettleWithdrawal`. `refund.proto` declares `CreateRefund`. There is currently **no proto RPC for batch execution** nor an explicit batch struct in palantir.
- `inflora-tolkien/internal/app/batches.go` and `holds.go` **mutate `payouts`, `payout_batches`, `fund_holds` directly** and enqueue outbox events as producer `"tolkien"`. This violates D-004/D-006 (Saruman owns the payout aggregate and financial mutation; Tolkien is facade-only). **This is the single most important refactor before any withdrawal feature work.**
- `inflora-saruman` has **no payout command surface** (no `CreatePayout`/`ReservePayout` endpoint or gRPC), **no withdrawal-result consumer** (no handler for `pg.gateway.withdrawal.completed.v1` / `.failed.v1`), and **no settle/complete/fail posting implementations** (templates §3/§4/§5 exist as spec only).
- `payouts.batch_id` has no FK to `payout_batches` (schema `02-database-schema.sql:375-392`); `payout_batches.created_by` is a UUID with no FK to `admin_users`.
- `payout_status` enum = `{REQUESTED, BATCHED, PROCESSING, SETTLED, FAILED}`; **no `NEEDS_REVIEW` / `MANUAL_REVIEW` / `UNKNOWN` state for provider ambiguity.** `payout_batch_status` = `{DRAFT, EXECUTING, COMPLETED, PARTIAL_FAILED, FAILED}`.
- `gateway_withdrawals` (`02-database-schema.sql:587`) has a `palantir_ref` UNIQUE and `saruman_batch_id`, but **no idempotency/dedup key for provider withdrawal events** and no `settlement_status`-style ambiguity column. Must be extended per D-012/D-013 equivalents for withdrawals.

## 6. Database schema vs migrations drift (verified defects)

1. `schemas/02-database-schema.sql` (the frozen Phase-0 doc) **does not contain** `admin_users` / `admin_sessions` / `admin_role` at all — those live only in saruman migrations `00007/00008`. The frozen schema doc is stale relative to the DB for the admin surface.
2. `v_streamer_balances` has no hold-exclusion consistency guarantee (summary item) — payout eligibility must not rely solely on the view.
3. `streamer_bank_accounts` `UNIQUE(streamer_id, is_primary)` is a latent bug (only one primary `true`/`false` row possible) — must be fixed before bank-account add/list is made fully robust.
4. `gateway_withdrawals` lacks a dedup key for provider events.
5. `audit_log` has no immutability guard (append-only RULEs exist only on `ledger_entries`, schema lines 281-282).
6. Admin email case-sensitivity: `admin_users.email` uniqueness is case-sensitive; lookups use `lower(email)`. Normalize on insert.
7. Migrations `00007_admin`, `00008_seed_admin` exist but are **untracked in the migration-count expectations** (the summary notes `runner_test.go` expects 6 migrations and 14 enums — a test-consistency debt the implementer must reconcile before adding new migrations).

## 7. Frontend current surface (verified)

Routes (`frontend/src/routes/`):

| Route | Purpose | Backend ready |
|---|---|---|
| `d/[streamer_id]/+page.svelte` | public donor page (calls ingest) | yes |
| `d/[streamer_id]/thanks/+page.svelte` | post-donation thanks | yes |
| `dashboard/+page.svelte` | streamer home | partial |
| `dashboard/donations/+page.svelte` | **placeholder** (`GET /v1/me/donations` missing) | no |
| `dashboard/payouts/+page.svelte` | **placeholder** (`POST /v1/me/payouts` missing) | no |
| `dashboard/banks/+page.svelte` | bank accounts add/list | yes |
| `dashboard/overlay/+page.svelte` | overlay capabilities | yes (token rotate) |
| `dashboard/settings/+page.svelte` | streamer settings | yes |
| `admin/+layout.svelte` | **brand says "Inflora Admin"** | n/a |
| `admin/+page.svelte`, `admin/donations/…` | donation monitoring | yes (ak_) |
| `admin/login/+page.svelte` | admin login | yes (ak_) |
| `login|logout|signup/+page.svelte` | streamer auth | yes (sk_) |

- `frontend/src/lib/api/tolkien.ts`: signup/login/logout/me/balance/settings/updateSettings/listBankAccounts/addBankAccount/rotateOverlayToken implemented; donations/payouts throw `NOT_IMPLEMENTED`.
- `frontend/src/lib/api/admin.ts`: adminLogin/adminLogout/adminMe/adminDonations/adminDonationSummary/adminDonationDetail/adminDonationOverride only.
- `frontend/src/lib/stores/session.ts` / `adminSession.ts`: sessionStorage keys `inflora_sk` / `inflora_ak`.
- `frontend/docs/` (AUTH.md, API.md, ARCHITECTURE.md, README.md, ROADMAP.md) further pin the client contract.
- A sibling `overlay/` app exists (OBS browser source) — outside dashboard scope but shares the `ok_` token.

## 8. Remote frontend repository status (verified 2026-10-16, UPDATED same day)

- `https://github.com/leolaiherman/inflora-front.git` is **private** (clone without credentials fails; REST/page return 404) but was cloned successfully with owner-supplied credentials on 2026-10-16 → `/home/ubuntu/inflora-dev/inflora-front`.
- It is **not a clone of this dashboard**: React 19 + React Router 7 + TanStack Query + Zustand, "campaign infrastructure for creators", 100% mock-backed (localStorage `inflora.mockdb`, BroadcastChannel live simulator), **zero network calls, zero auth/Firebase artifacts**. Full inventory and per-function backend dispositions: `planning-marvel-1/frontend-parity-matrix.md`; planning consequences in `04-frontend.md` header + §7.

## 9. Environment constraints on verification

- This environment has **no Go toolchain** (`go: command not found`). All backend verification in this plan is **static/read-only**; the implementer (who has Go) must run `go build ./...` / `go test ./...` per per-repo and `make lint`.
- The six repos appear to be git repositories individually (e.g. `inflora-shared/.git` exists); the workspace root is not one git repo.

## 10. What the plan must therefore do (summary of gaps → documents)

1. Rename visible admin area to **"Inflora Backoffice"** — presentation + route/API naming decision (`02-backoffice.md`).
2. Unify the two admin auth mechanisms and enforce roles — `01-firebase-rbac.md` + `02-backoffice.md`.
3. Add Firebase Auth and DB-backed RBAC `SUPERADMIN/ADMIN/USER` — `01-firebase-rbac.md`.
4. Implement `POST /v1/me/payouts`, Saruman payout command + withdrawal-result consumers, batch algorithm, failure/recovery — `03-withdrawals.md`.
5. Fix D-004 ownership violation (move batch/hold financial mutation into Saruman) — `03-withdrawals.md`.
6. Complete dashboard donations/payouts pages + connect the remote dashboard repo's full function set — `04-frontend.md`.
7. Sequence everything with migration/rollback/telemetry gates — `05-phases-and-gates.md`.