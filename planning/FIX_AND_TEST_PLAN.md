# Fix + Guided Test Plan (admin login → donation → OBS overlay)

> Status: **proposed, not implemented.** Date: 2026-10-15.
> Companion to ADMIN_SYSTEM_PLAN.md (that plan's implementation is done; this
> plan covers the follow-up fixes and the hands-on MVP test run).

## 0. Current state (verified against the live Docker stack)

| Check | Result |
| --- | --- |
| Services up | postgres, nats, redis, ingest:8081, saruman:8082, palantir, tolkien:8080, ws-gateway:8083 — all running |
| Frontend dev | `127.0.0.1:5173` listening |
| Overlay dev | `127.0.0.1:5174` listening (esbuild) |
| Donations | 2 INTENT_CREATED, 5 CHARGED, 1 SETTLED, 1 FAILED |
| gateway_topups | 6 CAPTURED, 1 FAILED |
| Dead letters | 4 rows, all `OUTBOX_PUBLISH` / `context deadline exceeded` from 2026-10-13 (pre-fix era) |
| Overlay tokens | only `obs-test@inflora.local` and `obs2@inflora.local` hold active `ok_` tokens; Dev Streamer 1–5 have none |
| Admin seed | `admin@inflora.local` / `inflora-admin` present (migration 00008, dev-gated) |

---

## 1. Problems found (what needs fixing)

### F1 — Override SUCCESS is impossible on legacy donations (real bug, blocks the demo)

Two donations (`0935b28d…`, `0e0e38a0…`) sit in `INTENT_CREATED` with
`net_idr = gross_charged_idr = platform_fee_idr = mdr_idr = 0` while
`gateway_topups.gross_charged_idr = 50000`. They were created by an ingest build
before the amount fix, so the row is internally inconsistent.

Palantir's override builds its payload from the **donation** snapshot
(`net_idr=0`) and the **gateway** row (`gross_charged_idr=50000`). Saruman's
`completeTopup` then rejects it on both invariants:

```
gross_charged_idr != net_idr + platform_fee_idr + mdr_idr   → 50000 != 0
amount_idr          != net_idr + platform_fee_idr           → 50000 != 0
```

The event lands in `consumer_inbox` failures and eventually dead-letters. Net
effect: the admin clicks "Tandai Sukses", gets a green success response, and
**nothing happens downstream** — no ledger, no overlay. That is the single worst
failure mode for the feature, because it is silent.

Two sub-decisions:
- **(a) Data**: the two rows are dev artifacts. Cheapest correct fix is to mark
  them `FAILED` with `failure_reason='LEGACY_DATA'` (append-only; no fake
  ledger). They cannot be repaired into a valid capture anyway.
- **(b) Code**: the override must not report success for an event the consumer
  will reject. Add a pre-flight validation in `palantir/internal/grpc/override.go`
  mirroring Saruman's invariants, returning `codes.FailedPrecondition` with the
  mismatched numbers so the admin UI shows a real reason. This converts a silent
  lie into an actionable error. **Recommended — small, contained, one file.**

### F2 — No intent-expiry sweeper (design gap)

`donations.expires_at` is set to `created_at + 15m` and
`gateway_topups.expires_at` too, but nothing in any service ever reads them.
`pg.gateway.topup.expired.v1` exists end-to-end (Palantir `normalizeTopUpStatus`
maps `EXPIRE/EXPIRED/TIMEOUT`, Saruman has `expireTopup` → `markFailed`), but
nothing emits it except a provider webhook that says so. So:

- every abandoned donation is `INTENT_CREATED` **forever**, not 15 minutes;
- the admin console's "pending" bucket is permanently polluted;
- F1's class of broken rows can never self-heal.

For the MVP demo this is tolerable (you manually override), but it means the
"monitored clearly" goal has no cleanup story. **Recommendation: document as
known gap, do not build the sweeper now** — it is a new component (a periodic
job in Palantir that finds expired PENDING top-ups and enqueues
`topup.expired.v1`), not a fix. Flagging it so it is a conscious deferral.

### F3 — No helper to simulate the payment gateway (the actual blocker for your test)

The provider stub returns `payment_url = "stub://pivot/pay/pivot_topup_…"`.
Nothing consumes that; there is no "pay" page and no way to move a top-up from
`PENDING` to `CAPTURED` except crafting a signed webhook by hand. Concretely, to
simulate a real PG confirmation you must:

1. `POST :8081/v1/donations` with `Idempotency-Key` → get `donation_id`;
2. read `gateway_topups.provider_charge_id` for that donation (it is **not** in
   the ingest response — the response has `payment_url`, which embeds it);
3. build a JSON body containing `event_id`, `transaction_id`, `status`;
4. compute `HMAC-SHA256(body, "pivot-dev-secret")` hex;
5. `POST :8081/v1/webhooks/payment` with `X-Signature`.

Steps 3–5 need code. **Recommendation: add one dev-only helper script**
(`backend/scripts/dev_confirm_payment.py`, run with `python3 -I`), which takes a
donation id, signs the payload, and posts it. That is the difference between a
5-minute test and a 30-minute one. This is additive (new file), no production
code touched.

### F4 — Dev Streamers 1–5 have no overlay token

Not a bug. It only matters if you want to test with a seeded streamer instead of
`obs-test@inflora.local`. Since the latter already has an active `ok_` token,
**no fix needed** — but it does mean the two OBS streamers are the only viable
overlay subjects.

### F5 — Frontend admin CORS is fine; streamer CORS was verified

`CORS_ALLOWED_ORIGINS` already includes `http://localhost:5173`, and
`WS_DEV_OPEN_ORIGIN: "true"` is set on ws-gateway so the overlay at
`http://localhost:5174` can open the WS. **No change.** Note for the record that
`WS_DEV_OPEN_ORIGIN` must be unset in production (it is dev-only) — that stays
as documented.

---

## 2. Fix list to implement after review

| # | Change | File(s) | Risk |
| --- | --- | --- | --- |
| 1 | Pre-flight invariant check in override; `FailedPrecondition` with the actual numbers | `backend/inflora-palantir/internal/grpc/override.go` | low — additive guard |
| 2 | Mark the two legacy broken donations `FAILED` / `LEGACY_DATA` | one-off SQL (dev DB only, not a migration) | none — dev data |
| 3 | Dev helper script to send a signed Pivot webhook | new `backend/scripts/dev_confirm_payment.py` | none — new file |
| 4 | Update `LOCAL_DEV_NOTES.md` with the expiry-sweeper gap + how to run the helper | docs | none |

Deliberately **not** in scope (respecting "don't edit everything"): the expiry
sweeper, admin role checks on the override endpoint (all admins can override
today — fine for a single-role MVP), and the 4 historical dead letters.

---

## 3. Guided test: admin login → donation → overlay

Everything below is a runbook for you to execute; nothing here needs me to
change code (fixes 1–3 just make it smoother).

### Step 0 — services up (already true)

```
sudo -n docker compose -f backend/docker-compose.dev.yml ps
```
Expect 8 services `running`. Frontend must be on :5173 and overlay on :5174
(`npm run dev` in each of `frontend/` and `overlay/`).

### Step 1 — admin login

- Open <http://localhost:5173/admin/login>
- Email `admin@inflora.local`, password `inflora-admin`
- (dev-only seed; gated by `ENV=dev` + `--seed` on the migrate service)

You land on the dashboard: summary cards (total / intent_created / charged /
settled / failed / refunded) plus the 10 most recent donations.

### Step 2 — open the overlay (do this BEFORE donating)

The overlay must be connected to receive the event, so set it up first.

- Log in as the streamer at <http://localhost:5173/login> —
  `obs-test@inflora.local`. **I could not verify this password** (the seed hash
  is bcrypt and I did not want to brute-force it); if the login fails, use
  <http://localhost:5173/signup> and register a fresh streamer, then run step 2b.
- Go to `/dashboard/overlay` and click rotate → copy the `ok_…` URL.
- Open it in a browser tab: `http://localhost:5174/?host=localhost:8083&token=ok_…`
  The banner should read *connected*.
- For OBS: Browser Source, URL as above, **1920×1080**, tick "Shutdown source
  when not visible" **off**, refresh period ~2 s.

### Step 3 — create the donation (the "PG transaction")

```
curl -s -X POST http://localhost:8081/v1/donations \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: demo-1' \
  -d '{"streamer_id":"58fdf7d3-20eb-4540-a729-dab33855c54c",
       "amount_idr":75000,"payment_method":"QRIS",
       "donor_display_name":"Andi","message":"Semangat!"}'
```

(75,000 IDR / 10,000 per sec = 7.5 s of display time. Min 1,000, max 10,000,000.)

The response carries `donation_id`. In the admin console the new row appears as
`INTENT_CREATED` / gateway `PENDING` — this is your "order recorded and
monitorable" proof.

### Step 4 — confirm payment — pick ONE of the two routes

**Route A — admin override (what you built; fastest)**

In the admin console open the donation → type a reason → **Tandai Sukses**.
This drives Palantir → `pg.gateway.topup.completed.v1` → Saruman ledger +
`donation.charged.v1` → ws-gateway → overlay. The overlay alert should fire.
"**Tandi Gagal**" instead drives `donation.failed.v1` and the overlay stays
silent — that is the correct contrast to demo.

**Route B — simulated real webhook (proves the unmodified PG path)**

Same end state, but goes through `POST /v1/webhooks/payment` exactly as a real
Pivot callback would, so Palantir's signature verification and
`webhook_events` idempotency are exercised too. After fix #3 lands:

```
python3 -I backend/scripts/dev_confirm_payment.py <donation_id> --status SETTLEMENT
```

Manual equivalent, if you prefer to see the mechanics:
```
BODY='{"event_id":"evt-demo-1","transaction_id":"pivot_topup_...","external_id":"<donation_id>","status":"SETTLEMENT"}'
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac 'pivot-dev-secret' -hex | sed 's/^.* //')
curl -s -X POST http://localhost:8081/v1/webhooks/payment \
  -H 'Content-Type: application/json' -H "X-Signature: $SIG" -d "$BODY"
```
The body **must** contain `event_id` (that is how ingest detects Pivot) and
`transaction_id` must equal the `provider_charge_id` on the gateway row —
readable in the admin detail view.

Status mapping (from `normalizeTopUpStatus`): `SETTLEMENT`/`PAID`/`COMPLETED`/
`SUCCESS`/`TOPUP.COMPLETED` → CAPTURED; `CAPTURE` → CAPTURED unless
`fraud_status=DENY`; `EXPIRE`/`EXPIRED`/`TIMEOUT` → EXPIRED; `DENY`/`FAILED` →
FAILED; `CANCEL*` → FAILED.

### Step 5 — verify the whole chain

1. **Overlay**: the alert shows "Andi · Rp75.000 · Semangat!" then clears.
2. **Admin list**: status flips to `CHARGED`, gateway `CAPTURED`.
3. **Admin detail**: two ledger entries appear — `DONOR_CASH` DEBIT 75,000 and
   `STREAMER_PENDING` CREDIT 75,000.
4. **Audit**: `SELECT * FROM audit_log WHERE action='DONATION_OVERRIDE'` (route
   A only) has your actor and reason.
5. **Event log**:
   ```
   sudo -n docker exec backend-postgres-1 psql -U inflora -d inflora -c \
     "SELECT event_type, published_at IS NOT NULL AS published FROM outbox_events ORDER BY created_at DESC LIMIT 6;"
   ```
   expect `pg.gateway.topup.completed.v1` → `donation.charged.v1`, both published.

### Step 6 — negative cases worth trying

- Override **Tandai Gagal** on a fresh donation → `FAILED`,
  `failure_reason=ADMIN_OVERRIDE`, no overlay.
- Override the same donation twice → second returns
  `already_terminal: true`, no new events (idempotency).
- Override one of the two legacy donations → with fix #1 you get a clear
  `DONATION_TERMINAL`-style error naming the mismatch instead of silence; after
  fix #2 it will already be `FAILED`.

---

## 4. Open question for you

Do you want me to also fix the streamer login for the OBS test streamers
(reset `obs-test@inflora.local`'s password to a known dev value so step 2 is
one click instead of possibly requiring signup)? It is a one-row dev-DB update
or a seed migration. Say the word and I will include it.