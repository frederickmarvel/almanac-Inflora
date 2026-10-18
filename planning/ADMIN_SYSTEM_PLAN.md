# Admin System Plan — Donation Monitoring & Override

> Status: implementation. Date: 2026-10-14.
> Supersedes the "admin frontend excluded" note in MANUAL_SETTLEMENT_WITHDRAWALS_PLAN.md
> for the **donation monitoring + override** slice only (holds/batches/refunds unchanged).

## Problem

- Donations are fully recorded (`donations`, `gateway_topups`, `ledger_entries`,
  `outbox_events`, `audit_log`) but there is no admin surface to monitor them.
- When a provider confirms a payment but the webhook is delayed/lost, the donation
  stays `INTENT_CREATED` and the overlay never fires. We need an admin override.

## Principle

An override is **not** a parallel write path. It injects a synthetic provider
result through Palantir, reusing the frozen pipeline:

```
override SUCCESS  -> Palantir enqueues pg.gateway.topup.completed.v1
                  -> saruman ledger postings + donation.charged.v1
                  -> ws-gateway -> OBS overlay            (same as a real payment)
override FAILURE  -> Palantir enqueues pg.gateway.topup.failed.v1
                  -> saruman donation.failed.v1           (no overlay)
```

The event producer (`palantir`), subject, causation/correlation, and payload are
identical to a real webhook, so the ledger and overlay stay consistent.

## Scope of changes

### 1. Palantir (broker — owns `gateway_topups` + provider-result events)

- `proto/palantir/v1/topup.proto`: add `AdminOverrideTopUp` RPC +
  `AdminOverrideTopUpRequest`/`Response`.
- Extract the settlement-commit logic from `SettleTopUp` into a shared helper so
  the override reuses the exact payload/enqueue code.
- `internal/grpc/override.go`: new handler. Only valid from a non-terminal
  gateway state (`PENDING`/`CREATED`/`PROCESSING`). `SUCCESS -> CAPTURED`,
  `FAILURE -> FAILED` (`failure_reason = ADMIN_OVERRIDE`). Idempotent on
  already-terminal state.
- Auth: covered by the existing `GRPCBearerAuth(SM_GATEWAY_ENGINE_API_KEY)`.

### 2. Migrations (saruman owns schema)

- `00007_admin.up/down.sql`: `admin_role` enum, `admin_users`, `admin_sessions`.
- `00008_seed_admin.up/down.sql`: one dev admin (gated like `seed_dev`).
- Migrate runner: gate any migration named `seed_*` (currently only `seed_dev`).
- `docker-compose.dev.yml`: pass `--seed` to the migrate service; add
  `PALANTIR_GRPC_ADDR` + `SM_GATEWAY_ENGINE_API_KEY` to tolkien.

### 3. Shared auth

- `auth/tokens.go`: `ak_` prefix, `GenerateAdminToken`, `ValidAdminToken`;
  extend `HashToken`/`VerifyToken`/`TokenLast4` to accept admin tokens.

### 4. Tolkien (admin facade)

- `internal/palantir/client.go`: gRPC client for `AdminOverrideTopUp`.
- `internal/app/admin.go`: `AdminLogin`, `AdminValidate`, `AdminListDonations`,
  `AdminDonationSummary`, `AdminGetDonation`, `AdminOverrideDonation`.
- `internal/httpapi/admin.go`: `POST /v1/admin/login`, `POST /v1/admin/logout`,
  `GET /v1/admin/me`, `GET /v1/admin/donations`, `GET /v1/admin/donations/summary`,
  `GET /v1/admin/donations/{id}`, `POST /v1/admin/donations/{id}/override`.
  Auth = `ak_` bearer token (real admin session + role), replacing `X-Actor-Id`
  for the new endpoints. Writes `audit_log` (actor_type `ADMIN`).
- Existing holds/batches/resend endpoints are left unchanged this slice.

### 5. Frontend (SvelteKit)

- `src/lib/api/admin.ts`, `src/lib/stores/adminSession.ts`.
- `src/routes/admin/+layout.svelte` (guard + nav), `login/+page.svelte`,
  `+page.svelte` (summary + donation list), `donations/[id]/+page.svelte`
  (detail + override).

## Out of scope (unchanged)

- Holds, payout batches, refunds, settlement/withdrawal (existing MSW plan).
- Migrating existing `X-Actor-Id` endpoints to role auth (follow-up).
- Settlement (`donation.settled.v1`) wiring — unchanged this slice.

## Verification

1. Create a donation via ingest (INTENT_CREATED).
2. Admin list shows it; detail shows gateway `PENDING`.
3. Override `SUCCESS` -> overlay fires (ws-gateway broadcast), ledger posted.
4. Override `FAILURE` -> donation `FAILED`, no overlay.
5. Override on an already-terminal donation -> clear, non-mutating error.

## Completion status (2026-10-15)

Implemented and verified end-to-end. Deviations from the scope above, kept
deliberately narrow:

- The RPC lives in a new `proto/palantir/v1/admin.proto` (`AdminService.
  OverrideDonation`) instead of extending `topup.proto`; generating a single new
  file kept the generated-code diff minimal. `decision` is an enum
  (`OVERRIDE_SUCCESS` / `OVERRIDE_FAILURE`), with `actor` and `reason` required.
- The idempotent no-op gate is keyed on the **donation** status, not the gateway
  status. Saruman's `completeTopup` / `markFailed` only ever transition a
  donation in `INTENT_CREATED`, so a gateway already `CAPTURED` whose result
  event was lost must still be re-drivable. Overriding an already terminal
  donation returns `already_terminal: true` with the current donation status.
- A missing `provider_charge_id` (stuck `PENDING`) is synthesised as
  `admin-override:<donation_id>` so the emitted event still satisfies Saruman's
  "non-empty provider_charge_id" invariant.
- Passwords/tokens: `admin_users` Argon2id + `ak_` bcrypt sessions (12h TTL),
  rate-limited login. Verified: SUCCESS override posts the two capture ledger
  entries and publishes `pg.gateway.topup.completed.v1` ->
  `donation.charged.v1`; FAILURE publishes `donation.failed.v1` (no overlay);
  both write a `DONATION_OVERRIDE` row to `audit_log` with actor + reason.
