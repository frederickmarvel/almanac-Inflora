# 08 — Flow Diagrams (End-to-End)

> **Visual companion** to all schema files. Each flow shows happy path + key failure paths + latency budget + state machine.
> **Use this** when onboarding, debugging, or designing new flows.

---

## Flow 1 — Happy Path Donation (donor pays → popup in OBS)

```
┌────────────────────────────────────────────────────────────────────┐
│  T+0.000s   Donor fills form on /d/<streamer_id>                   │
│             amount=Rp50.000, name="Andi", msg="Semangat bang!"     │
└────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌──────────────────────┐
                    │  ingest-api          │
                    │  POST /v1/donations  │
                    │  • validate          │
                    │  • CAPTCHA verify    │
                    │  • rate limit check  │
                    └──────────┬───────────┘
                               │
                               │  T+50ms
                               ▼
                    ┌──────────────────────┐
                    │  ingest-api          │
                    │  • INSERT donations  │
                    │    (INTENT_CREATED,  │
                    │     expires_at=+15m) │
                    │  • INSERT idempotency│
                    │  • call palantir gRPC│
                    │    CreateTopUp       │
                    └──────────┬───────────┘
                               │
                               │  T+200ms
                               ▼
                    ┌──────────────────────┐
                    │  palantir-gateway    │
                    │  • provider.CreateTopUp
                    │  • Midtrans Snap → payment_url
                    │  • INSERT gateway_topups (PENDING)
                    └──────────┬───────────┘
                               │
                               │  T+400ms
                               ▼
                    ┌──────────────────────┐
                    │  ingest-api          │
                    │  HTTP 201:           │
                    │   { payment_url,     │
                    │     intent_id, ... } │
                    └──────────┬───────────┘
                               │
                               │  T+600ms
                               ▼
                    ┌──────────────────────┐
                    │  Donor browser       │
                    │  redirect → Midtrans │
                    │  Snap payment page   │
                    └──────────┬───────────┘
                               │
                               │  donor confirms payment (async, T+N seconds)
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│  T+15.000s  Midtrans POSTs webhook to /v1/webhooks/payment         │
└────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌──────────────────────┐
                    │  ingest-api          │
                    │  1. Verify signature │
                    │  2. Detect provider  │
                    │  3. INSERT idempotency
                    │     (key=midtrans:<event_id>) │
                    │     ON CONFLICT → 200 (no-op)
                    │  4. call palantir gRPC SettleTopUp
                    └──────────┬───────────┘
                               │
                               │  T+15.100s
                               ▼
                    ┌──────────────────────┐
                    │  palantir-gateway    │
                    │  • INSERT webhook_events (audit)
                    │  • UPDATE gateway_topups (SETTLED)
                    │  • publish pg.gateway.topup.completed.v1
                    └──────────┬───────────┘
                               │
                               │  NATS push
                               ▼
                    ┌──────────────────────┐
                    │  saruman NATS        │
                    │  consumer            │
                    └────────┬─────────────┘
                             │
                             │  T+15.200s
                             ▼
                    ┌──────────────────────┐
                    │  saruman             │
                    │  • Validate donation │
                    │    is INTENT_CREATED │
                    │  • BEGIN TX (serializable) │
                    │    a. UPDATE donations SET status=CHARGED,
                    │       amount_idr, platform_fee_idr, net_idr,
                    │       provider_charge_id, charged_at │
                    │    b. INSERT ledger_entries x 2: │
                    │       - DONATION_DEPOSIT (donor_cash +X) │
                    │       - STREAMER_PENDING_CREDIT (+X-fee) │
                    │    d. UPDATE ledger_accounts.balance + version++ │
                    │  • COMMIT
                    │  • INSERT fraud_events (if rules tripped)
                    │  • publish donation.charged.v1.<streamer_id>
                    └──────────┬───────────┘
                               │
                               │  T+15.400s (commit done)
                               ▼
                    ┌──────────────────────┐
                    │  NATS JetStream      │
                    │  donation.charged.v1 │
                  ┌─┤  .<streamer_id>      ├─┐
                  │ └─────────────────────┘ │
                  │                          │
                  │  T+15.500s (NATS push)   │
                  ▼                          ▼
       ┌─────────────────────┐    ┌────────────────────────┐
       │  saruman analytics  │    │  realtime-gateway      │
       │  (Phase 2 consumer) │    │  NATS consumer         │
       └─────────────────────┘    └───────────┬────────────┘
                                              │
                                              │  T+15.550s
                                              ▼
                                ┌─────────────────────────────┐
                                │  realtime-gateway           │
                                │  • Look up streamer hub     │
                                │    (map[streamerID]*Hub)     │
                                │  • Atomic increment seq     │
                                │  • Marshal WS frame:        │
                                │    {type:donation, seq:N,   │
                                │     data:{...}}             │
                                │  • Fanout to all clients    │
                                │    for that streamer        │
                                └──────────────┬──────────────┘
                                               │
                                               │  T+15.650s (WS frame sent)
                                               ▼
┌────────────────────────────────────────────────────────────────────┐
│  T+15.700s  OBS Browser Source receives donation frame            │
│             Renderer plays animation in OBS broadcast             │
│             (popup shows for 8 seconds, then auto-dismisses)       │
└────────────────────────────────────────────────────────────────────┘

Side-effects in parallel (not blocking OBS path):
  • dashboard cache invalidated → balance shows new amount on next refresh
  • analytics collector logs event (Phase 2)
  • audit_log entry (CHARGED)
  • webhook_events row stored (already done in step 1)

Total latency budget: < 700ms p99 (webhook → OBS frame)
```

### State machine: donation

```
INTENT_CREATED ──(webhook settlement)──▶ CHARGED
       │
       ├──(webhook failure)──▶ FAILED
       │
       └──(15 min timeout)──▶ FAILED  (cron job)
                          │
                          CHARGED ──(admin refund)──▶ REFUNDED
                          CHARGED ──(chargeback)─────▶ REFUNDED
```

---

## Flow 2 — OBS WebSocket Connect & Catch-up

```
OBS Browser Source                         ithildin + saruman
         │                                          │
         │  GET overlay.inflora.app/ws?token=ok_xxx
         │  Sec-WebSocket-Protocol: inflora-overlay.v1
         │ ────────────────────────────────────────▶│
         │                                          │
         │                          Validate token  │
         │                          via tolkien:    │
         │                          POST /v1/internal/validate-overlay-token
         │                          (cache 60s)    │
         │                                          │
         │                          Look up streamer│
         │                          hub (create if │
         │                          first connect) │
         │                                          │
         │  HTTP 101 Switching Protocols            │
         │ ◀────────────────────────────────────────│
         │  {type:hello, high_water_mark:42,        │
         │   replay_window:600, version:1.0.0}      │
         │ ◀────────────────────────────────────────│
         │                                          │
         │  ... live frames continue ...            │
         │  {type:donation, seq:43, ...}            │
         │ ◀────────────────────────────────────────│
         │                                          │
         │  ╳ (network drop)                       │
         │                                          │
         │  (client waits: backoff with jitter)     │
         │  delay = min(30000, 200 * 2^n + jitter) │
         │                                          │
         │  GET overlay.inflora.app/ws?token=ok_xxx│
         │ ────────────────────────────────────────▶│
         │                                          │
         │  {type:hello, high_water_mark: 87, ...} │
         │ ◀────────────────────────────────────────│
         │                                          │
         │  {type:catch_up, last_seq: 42}          │
         │ ────────────────────────────────────────▶│
         │                                          │
         │                          read NATS log:  │
         │                          events 43..87   │
         │                          (or replay_window │
         │                           if NATS trimmed)│
         │                                          │
         │  {type:donation, seq:43, data:...}      │
         │ ◀────────────────────────────────────────│
         │  {type:donation, seq:44, data:...}      │
         │ ◀────────────────────────────────────────│
         │  ... (events 43-87 replayed) ...         │
         │  {type:catch_up_end, last_seq:87}       │
         │ ◀────────────────────────────────────────│
         │                                          │
         │  ... live events continue from seq 88+  │
```

### Reconnect storm protection

If 1000 OBS clients reconnect at once (e.g., server restart):

```
Server: no OBS issue
         │  Per-streamer hub already exists, no re-creation cost.
         │  Concurrent connections: 1000 goroutines (cheap in Go).
         │  NATS consumer auto-load-balances; no additional drain.
```

---

## Flow 3 — Idempotency at Webhook Edge (the critical path)

```
Midtrans webhook              ingest-api                     DB
                 │
        ┌────────┴────────┐
        │ T+0: arrives    │
        └────────┬────────┘
                 ▼
        ┌────────────────────┐
        │ Compute request    │
        │ hash = sha256(body)│
        │ key = "midtrans:   │
        │        <event_id>" │
        └────────┬───────────┘
                 ▼
        ┌────────────────────────────────────┐
        │ INSERT INTO idempotency            │
        │   (key, endpoint, request_hash)    │
        │ VALUES (...)                       │
        │ ON CONFLICT (key) DO NOTHING       │
        │ RETURNING id                       │
        └────┬─────────────────────────┬────┘
             │                         │
        (row returned)            (no row)
        first writer              duplicate
             │                         │
             ▼                         ▼
        ┌─────────────────┐    ┌──────────────────┐
        │ process normally│    │ SELECT response_ │
        │ (settle donation│    │ body FROM        │
        │  via saruman)   │    │ idempotency      │
        └────────┬────────┘    │ WHERE key=...    │
                 │             │                  │
                 │             │ return 200 OK    │
                 ▼             │ with cached      │
        ┌─────────────────┐    │ response_body    │
        │ UPDATE          │    └──────────────────┘
        │ idempotency     │
        │ SET response_   │
        │ status, body,   │
        │ processed_at    │
        └─────────────────┘
```

### Why this matters

**Midtrans retries up to 30 times** if it gets a non-2xx response. Without idempotency:
- Each retry creates a new `ledger_entries` row
- Balance double-counts
- Money is wrong
- We can't tell which entry is the "real" one

With idempotency:
- First webhook processed, response cached
- All 29 retries return same cached 200
- One ledger entry, balance correct

---

## Flow 4 — Streamer Registration → Ledger Provisioning

```
tolkien dashboard        saruman              palantir-gateway
       │                    │                        │
       │  POST /v1/auth/signup
       │ ──────────────────▶│
       │                    │                        │
       │  validate          │                        │
       │  argon2 hash pw    │                        │
       │  INSERT streamers  │                        │
       │  INSERT sessions (purpose=SESSION)
       │  publish streamer.registered.v1
       │                    │                        │
       │                    │   NATS subscribe       │
       │                    │ ◀──────────────────────│
       │                    │                        │
       │                    │  BEGIN TX              │
       │                    │   INSERT ledger_accounts x 4: │
       │                    │    - DONOR_CASH (balance=0)
       │                    │    - STREAMER_PENDING (balance=0)
       │                    │    - STREAMER_PAID (balance=0)
       │                    │    - PLATFORM_REVENUE (balance=0)
       │                    │  COMMIT                │
       │                    │                        │
       │                    │  call palantir gRPC   │
       │                    │   ProvisionStreamer    │
       │                    │ ──────────────────────▶│
       │                    │                        │
       │  201 Created        │  create sub-account   │
       │  {streamer, token} │  with provider        │
       │ ◀──────────────────│ ──────────────────────▶│
       │                    │  cache provider_ref    │
```

### Why per-streamer ledger accounts?

- Each streamer's balance is independent.
- Reconciliation job is per-(streamer, account_type).
- Refund of streamer X's streamer's donation only touches X's ledger entries.

---

## Flow 5 — Payout Request (Streamer Initiated)

```
Streamer dashboard       saruman              palantir-gateway      Bank
       │                    │                        │                │
       │  POST /v1/me/payouts (amount_idr: 145000)
       │ ──────────────────▶│
       │                    │                        │
       │                    │  validate balance      │
       │                    │  >= amount             │
       │                    │  BEGIN TX              │
       │                    │   INSERT payouts (REQUESTED)
       │                    │   INSERT ledger_entries x 2: │
       │                    │    - STREAMER_PENDING_CREDIT (-145000) │
       │                    │    - STREAMER_PAID (+145000)
       │                    │   UPDATE ledger_accounts.balance + version++
       │                    │  COMMIT                │
       │                    │                        │
       │                    │  publish payout.requested.v1
       │                    │ ──────────────────────▶│
       │                    │                        │
       │                    │                        │  provider.CreateWithdrawal
       │                    │                        │ ──────────────────────▶│
       │                    │                        │                  (provider calls bank)
       │                    │                        │ ◀──────────────────────│
       │                    │                        │  (status: PROCESSING)
       │                    │                        │
       │  201 Created        │                        │
       │  {payout, status:REQUESTED}                 │
       │ ◀──────────────────────────────────────────│
       │                    │                        │
       │  ... 1-3 days later ...                      │
       │                    │                        │
       │                    │                        │  bank settles
       │                    │                        │  provider sends webhook
       │                    │                        │ ──────────────────────▶│
       │                    │                        │
       │                    │  call saruman SettleWithdrawal
       │                    │ ◀──────────────────────│
       │                    │                        │
       │                    │  UPDATE payouts SET status=SETTLED,
       │                    │    provider_payout_id, settled_at
       │                    │                        │
       │                    │  INSERT audit_log (PAYOUT_SETTLED)
       │                    │                        │
       │                    │  publish payout.settled.v1
       │                    │ ──────────────────────▶│
       │                    │                        │
       │  (streamer sees status update via dashboard refresh)
```

### State machine: payout

```
REQUESTED ──(palantir CreateWithdrawal)──▶ PROCESSING ──(webhook)──▶ SETTLED
       │                                            │
       │                                            └──(webhook)──▶ FAILED
       │
       └──(15 min timeout, cron)──▶ FAILED  (rare; ops alerts)
```

---

## Flow 6 — Refund (Admin Initiated)

```
Admin dashboard        saruman              palantir-gateway        Provider
       │                    │                        │                   │
       │  POST /v1/admin/donations/:id/refund
       │  { reason: ADMIN_REFUND }
       │ ──────────────────▶│
       │                    │                        │
       │                    │  validate donation     │
       │                    │  status=CHARGED        │
       │                    │  BEGIN TX              │
       │                    │   INSERT refunds (PROCESSING)
       │                    │   INSERT ledger_entries x 2 (reversal): │
       │                    │    - REFUND_DEBIT (donor_cash -X) │
       │                    │    - REFUND_CREDIT (streamer_pending -X) │
       │                    │    - reversal_of = original entry IDs │
       │                    │   UPDATE ledger_accounts.balance + version++
       │                    │   UPDATE donations SET status=REFUNDED, refunded_at
       │                    │  COMMIT                │
       │                    │                        │
       │                    │  INSERT audit_log (REFUND)
       │                    │                        │
       │                    │  publish donation.refunded.v1
       │                    │ ──────────────────────▶│
       │                    │                        │
       │                    │                        │  provider.CreateRefund
       │                    │                        │ ──────────────────────▶│
       │                    │                        │                  (refund to donor)
       │                    │                        │ ◀──────────────────────│
       │                    │                        │  (status: PROCESSING)
       │                    │                        │
       │  200 OK             │                        │
       │  {refund, status:PROCESSING}                │
       │ ◀──────────────────────────────────────────│
       │                    │                        │
       │                    │                        │  provider webhook (later)
       │                    │                        │ ──────────────────────▶│
       │                    │                        │
       │                    │  UPDATE refunds SET status=COMPLETED,
       │                    │    provider_refund_id, completed_at
       │                    │                        │
       │                    │  publish (no event; already fired) │
```

### Refund invariants

- `refunds.original` and `reversed ledger_entries` link together
- `donation.status` transitions CHARGED → REFUNDED
- Original ledger entries NEVER modified (append-only)
- Reversal entries created with `reversal_of` pointer

---

## Flow 7 — Token Rotation

```
Streamer dashboard       tolkien               saruman         realtime-gateway
       │                    │                      │                    │
       │  POST /v1/me/overlay-token/rotate
       │ ──────────────────▶│
       │                    │                      │                    │
       │                    │  generate new token  │
       │                    │  bcrypt(token)        │
       │                    │                      │                    │
       │                    │  BEGIN TX            │                    │
       │                    │   UPDATE sessions    │                    │
       │                    │    SET revoked_at=NOW()│                  │
       │                    │    WHERE purpose=OVERLAY│                │
       │                    │    AND streamer_id=?│                    │
       │                    │   INSERT new session (OVERLAY)
       │                    │  COMMIT              │                    │
       │                    │                      │                    │
       │                    │  INSERT audit_log (TOKEN_ROTATE)          │
       │                    │                      │                    │
       │                    │  publish overlay.token.rotated.v1
       │                    │ ────────────────────▶│
       │                    │                      │                    │
       │                    │                      │  invalidate token │
       │                    │                      │  cache for this    │
       │                    │                      │  streamer          │
       │                    │                      │                    │
       │  200 OK             │                      │                    │
       │  {token, last4, url, obs_browser_source_url}                  │
       │ ◀──────────────────────────────────────────────────────────────│
       │                    │                      │                    │
       │  Streamer copies URL → pastes in OBS      │                    │
       │  OBS reconnects with new token            │                    │
       │ ─────────────────────────────────────────────────────────────────▶
       │                                              new WS connect   │
       │                                              token validated  │
       │                                              against tolkien  │
```

---

## Flow 8 — Reconciliation (Daily Cron)

```
Cron job (00:00 UTC daily)         saruman
       │                                │
       │  reconciliation.run()          │
       │ ──────────────────────────────▶│
       │                                │
       │  FOR EACH streamer:           │
       │    SELECT SUM(direction=DEBIT) │
       │    FROM ledger_entries         │
       │    WHERE account_id IN (...)   │
       │                                │
       │    SELECT SUM(direction=CREDIT)│
       │    FROM ledger_entries         │
       │    WHERE account_id IN (...)   │
       │                                │
       │    expected = credits - debits │
       │    actual   = balance_idr      │
       │    diff = expected - actual    │
       │                                │
       │    IF abs(diff) > threshold:   │
       │      INSERT reconciliation_drift
       │      PAGE on-call (SEV-2)      │
       │      BLOCK new donations      │
       │      for that streamer         │
       │                                │
       │  emit metric: sql_recon_drift_total{streamer_id}
```

### Invariants checked

For each `(streamer_id, account_type, currency)`:
- `SUM(DEBIT) - SUM(CREDIT)` of all entries = `ledger_accounts.balance_idr`
- Sum of credits - sum of debits on the asset side = sum on the liability side
- Total donations received = total pending + total paid (for streamer account)
- Refund entries equal donation entries they're reversing

### Drift response

| Diff size | Action |
|---|---|
| 0 | Log "OK" metric |
| ≤ 100 IDR (rounding) | Log, no alert |
| > 100 and ≤ 1000 | Log + ops dashboard flag |
| > 1000 | SEV-2 page + block new donations for streamer |
| Negative (negative = math is broken) | SEV-1 page immediately |

---

## Flow 9 — Failure Modes & Recovery

### Failure 1a: Database UNIQUE violation on idempotency (race: two webhooks arrive simultaneously)

```
Webhook A                ingest-api                  DB
   │                        │                        │
   │  INSERT idempotency   │                        │
   │ ──────────────────────▶│                        │
   │                        │  INSERT (CONFLICT)     │
   │                        │ ─────────────────────▶│
   │                        │ ◀─ ON CONFLICT DO NOTHING │
   │                        │                        │
   │                        │  (no row returned)    │
   │                        │                        │
   │                        │  SELECT response_body │
   │                        │  WHERE key = ...      │
   │                        │ ─────────────────────▶│
   │                        │ ◀───────────────────── │
   │                        │                        │
   │  200 OK + cached body  │                        │
   │ ◀──────────────────────│                        │
```

### Failure 1b: Database UNIQUE violation on ledger (race: two simultaneous settle-webhooks)

This MUST NOT happen — only one webhook per donation (saruman's idempotency ensures this).

If it does happen → bug. SEV-1. Stop the world, fix.

### Failure 2: NATS publish fails

```
saruman: ledger committed, NATS publish failed
   │
   │  Log: "ledger committed, event publish failed"
   │  emit metric: events_publish_failed_total{topic}
   │
   │  Two recovery options:
   │  (A) Outbox pattern: write event to outbox table; replay later
   │  (B) Reverse the ledger entry (REFUND_*) and re-publish later
   │
   │  MVP: option (B) — simple to implement
```

For MVP, use a simple outbox table:

```sql
CREATE TABLE event_outbox (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic        VARCHAR(120) NOT NULL,
  payload      JSONB NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at TIMESTAMPTZ
);

-- after ledger commit, write to outbox in same TX
-- background worker reads unpublished rows, publishes to NATS, marks published
```

### Failure 3: OBS WebSocket gateway crash mid-event

```
Gateway crashes                              OBS client
       │                                          │
       │ ╳ process exit                          │
       │                                          │
       │                                          │  WS close 1006 (abnormal)
       │                                          │  client: backoff + reconnect
       │                                          │
       │ (new gateway process starts)             │
       │                                          │
       │  GET /ws?token=ok_xxx                   │
       │ ◀───────────────────────────────────────│
       │                                          │
       │  hello { high_water_mark: 87 }          │
       │ ────────────────────────────────────────▶│
       │                                          │
       │  catch_up { last_seq: 42 }              │
       │ ◀───────────────────────────────────────│
       │                                          │
       │  replay events 43..87                   │
       │ ────────────────────────────────────────▶│
       │                                          │
       │  catch_up_end                            │
       │ ────────────────────────────────────────▶│
       │                                          │
       │  ... live events from seq 88 ...         │
```

Client-side: no UX change. The OBS overlay shows brief "Reconnecting..." pill (1-2 sec) then resumes.

---

## Flow 10 — Donation Intent Expiry

```
Cron job (every 1 min)            saruman
       │                              │
       │  expire_intents()            │
       │ ────────────────────────────▶│
       │                              │
       │  UPDATE donations             │
       │    SET status=FAILED,         │
       │        failed_at=NOW(),       │
       │        failure_reason=TIMEOUT│
       │  WHERE status=INTENT_CREATED │
       │    AND expires_at < NOW()    │
       │                              │
       │  For each updated row:       │
       │    publish donation.failed.v1│
       │    with failure_reason=TIMEOUT│
       │                              │
       │  (no ledger entries — no money moved) │
```

---

## Latency budget matrix

| Step | Target p99 | Notes |
|---|---|---|
| Donor form submit → payment_url returned | < 500ms | CAPTCHA + DB + gRPC |
| Donor confirms payment → webhook arrives | 5-30s | Midtrans-side latency |
| Webhook arrives → ledger committed | < 500ms | DB insert in TX |
| Ledger committed → event published | < 50ms | NATS publish |
| Event published → gateway consumes | < 100ms | NATS consumer |
| Gateway → WS frame dispatched | < 50ms | Per-streamer hub |
| **Total: webhook → OBS popup** | **< 700ms** | Above sum |
| Webhook → dashboard balance visible | < 1.5s | Includes cache invalidation |

---

## Connection recovery matrix

| Failure | Client behavior | Server behavior |
|---|---|---|
| Donor browser refresh | New donation attempt (idempotency key prevents dup) | n/a |
| OBS WS close 1000 (normal) | No reconnect | Clean shutdown |
| OBS WS close 1001 (server restart) | Reconnect immediately | Drain old connections |
| OBS WS close 4401 (token bad) | Show "rotate token" UI | Mark token revoked |
| OBS WS close 4408 (timeout) | Reconnect with backoff | n/a |
| OBS WS close 4429 (rate limited) | Wait 60s, then retry | Drop new connections |
| Donor page fails to load | Browser retry | n/a |
| Dashboard fails to load | Browser retry | n/a |
| Midtrans webhook fails | n/a | Provider retries 30x over 24h |

---

## Flow 11 — Settlement (T+N webhook → funds become withdrawable)

```
T+N (typically minutes for QRIS, T+1 for VA, T+2-3 for CC)
                                                       Midtrans webhook
                                                              │
                                                              ▼
                    ┌──────────────────────────────────────┐
                    │  ingest-api                           │
                    │  POST /v1/webhooks/payment            │
                    │  (status_code="200", transaction_status="settlement") │
                    └──────────┬────────────────────────────┘
                               │
                               │  T+N+100ms
                               ▼
                    ┌──────────────────────┐
                    │  saruman             │
                    │  SettleDonation      │
                    │  • idempotency check │
                    │  • BEGIN TX          │
                    │    a. UPDATE donations SET │
                    │       settlement_status=SETTLED, settled_at=NOW() │
                    │    b. INSERT ledger_entries x 2: │
                    │       - STREAMER_PENDING_CREDIT (-net) │
                    │       - STREAMER_AVAILABLE_CREDIT (+net) │
                    │    c. version++ on ledger_accounts │
                    │  COMMIT               │
                    │  • publish donation.settled.v1.<streamer_id>
                    │  • optionally: trigger email_receipts.send │
                    └──────────┬───────────┘
                               │
                               ▼
                    NATS pushes to consumers
                               │
                ┌──────────────┴──────────────┐
                ▼                             ▼
        analytics                    realtime-gateway
                                       publishes donation_settled
                                       WS frame to OBS (optional toast)
                                       (only if streamer.settings.notify_on_donation=true)

Side effect (parallel):
  • trigger email_receipt if not yet sent (Flow 12)
  • dashboard balance updates (pending_idr down, available_idr up)
```

### State machine: donation (v2 — capture then settle)

```
                                                                  cred: STREAMER_PENDING +net
                                                                  deb: donor_cash +gross
INTENT_CREATED ──(capture webhook)──▶ CHARGED (settlement_status=PENDING) ──(settle webhook)──▶ SETTLED
       │                                                          │
       ├──(webhook failure)──▶ FAILED  (settlement_status=N/A)  │
       │                                                          │
       └──(15 min timeout)──▶ FAILED                              │
                                                                  │
                                          CHARGED/SETTLED ──(admin refund)──▶ REFUNDED
                                          CHARGED/SETTLED ──(chargeback)──▶ REFUNDED
```

### Invariants

- A donation in `SETTLED` state contributes to `STREAMER_AVAILABLE` balance (withdrawable).
- A donation in `CHARGED` state contributes to `STREAMER_PENDING` balance (NOT withdrawable).
- Settlement moves the funds atomically between ledger accounts.
- Email receipt may fire on either CHARGED (fast) or SETTLED (more accurate); MVP defaults to CHARGED for speed.

---

## Flow 12 — Email Receipt (post-donation)

```
T+0.500s                saruman                email_provider        donor inbox
       │                    │                        │                    │
       │  donation.charged.v1 published             │                    │
       │                    │                        │                    │
       │                    │  lookup donation.donor_email                │
       │                    │  if null → skip                          │
       │                    │                        │                    │
       │                    │  INSERT email_receipts (PENDING)            │
       │                    │                        │                    │
       │                    │  email_service.Send(  │                    │
       │                    │   to=donor_email,       │                    │
       │                    │   subject="...",        │                    │
       │                    │   body=receipt.html     │                    │
       │                    │  )                       │                    │
       │                    │ ─────────────────────▶ │                    │
       │                    │                        │                    │
       │                    │  (SES / SendGrid etc.) │                    │
       │                    │                        │  SMTP/TLS          │
       │                    │                        │ ─────────────────▶ │
       │                    │                        │                    │
       │                    │ ◀───────────────────── │                    │
       │                    │  {provider_msg_id: "..."}                   │
       │                    │                        │                    │
       │                    │  UPDATE email_receipts SET status=SENT,     │
       │                    │    provider_msg_id=?, sent_at=NOW            │
       │                    │  publish donation.receipt_sent.v1.         │
       │                    │ ──────────►              │
```

### Failure modes

| Provider response | Action |
|---|---|
| 200 OK | Mark SENT, publish event |
| 4xx (e.g., invalid email) | Mark FAILED, log, do not retry |
| 5xx (transient) | Retry with exponential backoff (3 attempts); mark FAILED after |
| Bounce (later) | Update status=BOUNCED via provider webhook |

### Email template (Indonesian default)

```
Subject: Terima kasih atas donasi Rp [amount] untuk [streamer_name]

Hai [donor_name],

Donasi kamu sudah kami terima:
  Jumlah donasi : Rp [amount_idr]
  Biaya [payment_method] : Rp [mdr_idr]  (ditanggung kamu)
  Total dibayar  : Rp [gross_charged_idr]
  Untuk streamer : [streamer_name]
  Pesan kamu     : "[message]"

[Inflora Invoice #INV-xxxxx]

⏳ Settlement: dana sedang diproses oleh payment provider,
   tersedia untuk streamer dalam 1-3 hari kerja.

Lihat transaksi kamu: https://app.inflora.app/donations/[donation_id]

Terima kasih sudah mendukung kreator Indonesia! 🇮🇩
— Tim Inflora
```

---

## Flow 13 — Fund Hold (admin/finops investigation)

```
Admin dashboard                saruman                     realtime-gateway
       │                            │                            │
       │  POST /v1/admin/holds       │                            │
       │  {                         │                            │
       │    target_type: STREAMER,  │                            │
       │    streamer_id: uuid,      │                            │
       │    amount_idr: 1500000,    │                            │
       │    reason: "fraud #423",   │                            │
       │    expires_at: +30 days    │                            │
       │  }                         │                            │
       │ ──────────────────────────▶│
       │                            │
       │                            │  validate: amount <= available
       │                            │  INSERT fund_holds (ACTIVE)
       │                            │  INSERT audit_log (HOLD_CREATED)
       │                            │
       │                            │  (optional) ledger:                                     │
       │                            │   STREAMER_AVAILABLE -X                                  │
       │                            │   HOLD_ESCROW +X                                        │
       │                            │
       │                            │  publish fund_hold.created.v1.<streamer_id>             │
       │                            │ ────────────────────────▶
       │  201 Created                │
       │  { hold_id, status:ACTIVE } │
       │ ◀──────────────────────────│
       │                            │
       │                            │
       │  -- streamer tries payout: --                            │
       │                            │
       │  POST /v1/me/payouts       │
       │ ──────────────────────────▶│
       │                            │  lookup active holds for streamer
       │                            │  if amount_idr > (available - held) → reject
       │  403 STREAMER_HOLD_ACTIVE │
       │ ◀──────────────────────────│
       │                            │
       │                            │
       │  -- admin releases hold: --                              │
       │                            │
       │  DELETE /v1/admin/holds/:id│
       │  { resolution_note: "..." }│
       │ ──────────────────────────▶│
       │                            │  UPDATE fund_holds (RELEASED)
       │                            │  publish fund_hold.released.v1.<streamer_id>
       │  200 OK                    │
       │  { hold_id, status:RELEASED }                            │
```

### Hold types

| target_type | Effect |
|---|---|
| STREAMER | Whole-account freeze. All payouts blocked. Payouts returned with 403 STREAMER_HOLD_ACTIVE. |
| DONATION | Specific donation excluded from withdrawable balance. Other donations OK. |

### Auto-expiry

Cron job (every 1 hour):
```sql
UPDATE fund_holds
SET status='EXPIRED', released_at=NOW()
WHERE status='ACTIVE' AND expires_at < NOW()
RETURNING streamer_id;
```

For each returned: publish `fund_hold.released.v1.<streamer_id>` with `resolution_note='auto-expired'`.

---

## Flow 14 — Batch Payout (finops FIFO bulk transfer)

```
FinOps dashboard              tolkien           saruman          palantir-gateway       Bank API
       │                          │                  │                    │                  │
       │  -- Step 1: Create batch --                                                  │
       │                          │                  │                    │                  │
       │  POST /v1/admin/payout-batches             │                    │                  │
       │  { auto_select: true }    │                  │                    │                  │
       │ ─────────────────────────▶│                  │                    │                  │
       │                          │                  │                    │                  │
       │                          │  SELECT payouts WHERE status='REQUESTED'  │           │
       │                          │  ORDER BY requested_at ASC (FIFO)          │           │
       │                          │  LIMIT 1000                                 │           │
       │                          │                  │                    │                  │
       │                          │  UPDATE payouts SET status='BATCHED', batch_id=?
       │                          │  INSERT payout_batches (DRAFT)              │           │
       │                          │  publish payout.batched.v1.<streamer_id>  │           │
       │                          │ ────────────────────▶                       │           │
       │                          │                  │                    │                  │
       │  201 Created              │                  │                    │                  │
       │  { batch_id, status:DRAFT, payout_count:25 }                         │           │
       │ ◀───────────────────────────────────────────│                  │                  │
       │                          │                  │                    │                  │
       │                          │                  │                    │                  │
       │  -- Step 2: Review + execute --                                              │
       │                          │                  │                    │                  │
       │  GET /v1/admin/payout-batches/:id           │                    │                  │
       │  POST /v1/admin/payout-batches/:id/execute   │                  │                  │
       │ ─────────────────────────▶│                  │                    │                  │
       │                          │                  │                    │                  │
       │                          │  UPDATE payout_batches SET status='EXECUTING'        │
       │                          │  UPDATE payouts SET status='PROCESSING'              │
       │                          │                  │                    │                  │
       │                          │  palantir.ExecuteBatch(batch_id, payout_ids, total) │          │
       │                          │ ────────────────────▶                     │                  │
       │                          │                  │                    │                  │
       │                          │                  │  provider.BulkDisbursement(...) │                  │
       │                          │                  │ ──────────────────────────────────▶│                  │
       │                          │                  │                    │  API call        │
       │                          │                  │ ◀─────────────────────────────│                  │
       │                          │                  │  {provider_batch_id}│                  │
       │                          │                  │                    │                  │
       │                          │                  │  publish payout.batch.executed.v1.<streamer>    │
       │                          │ ────────────────────▶                     │                  │
       │                          │                  │                    │                  │
       │                          │  UPDATE payout_batches SET provider_batch_id=?, │                  │
       │                          │    executing_at=NOW()                       │                  │
       │                          │                  │                    │                  │
       │  200 OK                                                           │                  │
       │  { batch_id, status:EXECUTING, provider_batch_id }                │                  │
       │ ◀───────────────────────────────────────────────────│                  │
       │                          │                  │                    │                  │
       │                          │                  │                    │                  │
       │  -- Step 3: Provider webhook settles (T+1 to T+3) --                                  │
       │                          │                  │                    │                  │
       │                          │                  │  bank settles,     │                  │
       │                          │                  │  provider webhook  │                  │
       │                          │                  │ ──────────────────▶│                  │
       │                          │                  │                    │                  │
       │                          │  For each payout in batch:               │                  │
       │                          │    UPDATE payouts SET status='SETTLED',  │                  │
       │                          │      provider_payout_id=?, settled_at=NOW  │                  │
       │                          │    publish payout.settled.v1.<streamer>  │                  │
       │                          │ ────────────────────▶                     │                  │
       │                          │                  │                    │                  │
       │                          │  if all settled:                          │                  │
       │                          │    UPDATE payout_batches SET status='COMPLETED'         │
       │                          │    publish payout.batch.completed.v1                    │
       │                          │ ────────────────────▶                     │                  │
```

### FIFO selection

```sql
-- Default FIFO batch selection
SELECT id, streamer_id, amount_idr, bank_account_id
FROM payouts
WHERE status = 'REQUESTED'
  AND NOT EXISTS (
    SELECT 1 FROM fund_holds fh
    WHERE fh.streamer_id = payouts.streamer_id
      AND fh.status = 'ACTIVE'
  )
ORDER BY requested_at ASC
LIMIT 1000;
```

### Customization (admin configurable)

`payout_batches` creation can be parameterized via admin settings:
- `batch_size_max`: 25 default (provider's bulk limit)
- `batch_threshold_idr`: trigger when accumulated REQUESTED > X IDR
- `batch_cron`: trigger batch on schedule (e.g., every Friday 10am)
- `fifo_only`: true/false (else select by largest amount first)

These settings live in `admin_settings` table (Phase 2).

---

## Flow 15 — OBS Rendering with Voice + YouTube + Display Duration

```
OBS Browser Source (Vite + TS + Canvas)
                                          │
       donation frame received (seq=N)    │
                                          ▼
       ┌────────────────────────────────────────────────────┐
       │ Renderer:                                          │
       │  1. Read data.display_duration_sec                 │
       │  2. If voice_url AND auto_play_voice=true:         │
       │     a. new Audio(voice_url).play()                  │
       │     b. duration = min(voice_duration_sec,          │
       │                     display_duration_sec)          │
       │  3. If youtube_url AND auto_play_youtube=true:     │
       │     a. Embed YouTube IFrame:                       │
       │        ?start=<youtube_start_sec>                  │
       │        &end=<youtube_end_sec>                      │
       │     b. Stop after display_duration_sec              │
       │  4. Show text popup (donor name + amount + msg)    │
       │     for display_duration_sec                       │
       │  5. If settlement_status=PENDING,                  │
       │     show "⏳ Settling" pill (subtle)               │
       └────────────────────────────────────────────────────┘
                                          │
       After display_duration_sec:         │
       ┌────────────────────────────────────────────────────┐
       │ Renderer:                                          │
       │  1. fadeOut popup                                  │
       │  2. pause audio                                    │
       │  3. remove YouTube iframe                          │
       │  4. reset for next donation                        │
       └────────────────────────────────────────────────────┘
                                          │
       If donation_settled frame received later:            │
       ┌────────────────────────────────────────────────────┐
       │ Renderer:                                          │
       │  1. Show "✅ Settled" toast for 2 seconds          │
       │  2. No animation; just text                        │
       └────────────────────────────────────────────────────┘
```

### Client-side playback coordination

- Voice plays first (audio context), then YouTube, then text only if time remains.
- If `display_duration_seconds < voice_duration`, audio is clipped to display_duration.
- If `display_duration_seconds < youtube_clip_duration`, iframe auto-stops.
- Multiple donations queued: each gets its own display_duration in sequence (no overlap); if too many, queue depth cap.

---

## Updated latency budget matrix (v2)

| Step | Target p99 | Notes |
|---|---|---|
| Donor form submit → payment_url returned | < 500ms | CAPTCHA + DB + gRPC + MDR lookup |
| Donor confirms payment → capture webhook arrives | 5-30s | Midtrans-side |
| Capture webhook → ledger committed | < 500ms | DB insert in TX |
| Ledger committed → event published | < 50ms | NATS publish |
| Event published → gateway consumes | < 100ms | NATS consumer |
| Gateway → WS frame dispatched | < 50ms | Per-streamer hub |
| **Total: capture webhook → OBS popup** | **< 700ms** | Above sum |
| Capture webhook → email sent | < 5s | SES typical |
| Provider settlement → SETTLED WS frame | varies (minutes to days) | Midtrans side |
| FinOps batch create → batch execute | < 30s | Manual UI action |
| Batch execute → all settled | T+1 to T+3 days | Bank processing |
| Hold created → payout rejected | < 100ms | Synchronous check |

---

*Pin this file. v2 adds: Settlement (Flow 11), Email Receipt (Flow 12), Fund Hold (Flow 13), Batch Payout (Flow 14), OBS Rendering (Flow 15).*