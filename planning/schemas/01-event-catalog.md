# 01 — Event Catalog (v1 Topics)

> **Every event Inflora publishes, with producer, consumers, payload schema, and trigger.**
> Format follows `00-frozen-contracts.md` envelope.

---

## Index

| Topic | Producer | Consumers | Trigger |
|---|---|---|---|
| `donation.intent.created.v1` | ingest-api | saruman | Donor submits donation form |
| `donation.charged.v1` | saruman | realtime-gateway, analytics | Ledger write + provider confirmation |
| `donation.failed.v1` | saruman | analytics, optional UI toast | Provider failure OR intent expiry |
| `donation.refunded.v1` | saruman | analytics | Refund completed |
| `payout.requested.v1` | tolkien | saruman, palantir-gateway | Streamer clicks Request Payout |
| `payout.settled.v1` | palantir-gateway | saruman, analytics | Bank transfer confirmed |
| `payout.failed.v1` | palantir-gateway | saruman | Bank rejects |
| `streamer.registered.v1` | tolkien | saruman, palantir-gateway | Signup |
| `overlay.token.rotated.v1` | tolkien | saruman, audit log | Streamer rotates OBS token |
| `fraud.flagged.v1` | saruman | ops dashboard | Inline velocity rule trips |

---

## 1. donation.intent.created.v1

**Producer:** `ingest-api`
**Consumers:** `saruman` (validates, transitions to CHARGED on payment)
**Trigger:** Donor submits donation form on `/d/:streamer_id`. Before payment provider redirect.

**Subject:** `donation.intent.created.v1.<streamer_id>`

**Payload:**
```json
{
  "intent_id":           "550e8400-e29b-41d4-a716-446655440000",
  "donation_id":         "abc-123-def-456",                  // pre-generated, saruman uses to find row
  "streamer_id":         "xyz-789-ghi-012",
  "amount_idr":          50000,
  "currency":            "IDR",
  "donor_display_name":  "Andi",
  "message":             "Semangat streamingnya bang!",
  "is_anonymous":        false,
  "client_ip":           "203.0.113.42",
  "user_agent":          "Mozilla/5.0 ...",
  "captcha_token":       "string",                          // verified at edge, not stored
  "expires_at":           "2026-10-02T14:45:00Z",
  "created_at":          "2026-10-02T14:30:00Z"
}
```

**Validation rules:**
- `amount_idr`: 1000 ≤ amount ≤ 10_000_000 (config-driven)
- `message`: ≤ 500 chars
- `donor_display_name`: ≤ 80 chars
- `is_anonymous=true` overrides `donor_display_name` (stored as null in DB)

---

## 2. donation.charged.v1

**Producer:** `saruman`
**Consumers:** `realtime-gateway` (fanout to OBS), `analytics` (Phase 2)
**Trigger:** Payment provider webhook fires `settlement`/`PAID` AND saruman ledger write commits.

**Subject:** `donation.charged.v1.<streamer_id>`

**Payload:**
```json
{
  "donation_id":         "abc-123-def-456",
  "intent_id":           "550e8400-e29b-41d4-a716-446655440000",
  "streamer_id":         "xyz-789-ghi-012",
  "amount_idr":           50000,
  "platform_fee_idr":    5,                                  // 1 bp of 50000 = 5 IDR
  "net_idr":             49995,                              // amount - fee
  "currency":            "IDR",
  "donor_display_name":  "Andi",
  "is_anonymous":        false,
  "message":             "Semangat streamingnya bang!",
  "provider_charge_id":  "TRX-12345",
  "provider_name":       "midtrans",
  "ledger_entry_ids": [
    "entry-donor-cash-uuid",
    "entry-streamer-pending-uuid"
  ],
  "ledger_correlation_id":"corr-uuid",
  "settled_at":          "2026-10-02T14:30:01.500Z"
}
```

**Invariants:**
- Exactly 2 ledger entries created (donor_cash +X, streamer_pending +X-fee).
- `donation.status` transitioned to `CHARGED` in same DB transaction as ledger entries.
- Idempotency: if webhook retried, this event re-fires only if NOT previously emitted (consumer dedupe on `event_id`).

---

## 3. donation.failed.v1

**Producer:** `saruman`
**Consumers:** `analytics`, optional OBS toast (off by default)
**Trigger:** Provider webhook fires failure OR intent expires (15 min default).

**Subject:** `donation.failed.v1.<streamer_id>`

**Payload:**
```json
{
  "intent_id":      "550e8400-e29b-41d4-a716-446655440000",
  "donation_id":    "abc-123-def-456",
  "streamer_id":    "xyz-789-ghi-012",
  "amount_idr":     50000,
  "failure_reason": "INSUFFICIENT_FUNDS",                   // enum
  "provider_error_code": "201",                             // optional
  "provider_name":  "midtrans",
  "failed_at":      "2026-10-02T14:32:00Z"
}
```

**`failure_reason` enum:**
- `INSUFFICIENT_FUNDS`
- `USER_CANCELLED`
- `PROVIDER_ERROR`
- `TIMEOUT` (intent expired)
- `FRAUD_BLOCKED` (inline rule)
- `UNKNOWN`

---

## 4. donation.refunded.v1

**Producer:** `saruman`
**Consumers:** `analytics`
**Trigger:** Admin triggers refund OR chargeback settled.

**Subject:** `donation.refunded.v1.<streamer_id>`

**Payload:**
```json
{
  "refund_id":           "uuid",
  "original_donation_id":"uuid",
  "streamer_id":         "uuid",
  "amount_idr":          50000,
  "reason":              "ADMIN_REFUND",                      // enum
  "is_partial":           false,
  "ledger_entry_ids":     ["uuid-1", "uuid-2"],                // reversal entries
  "refunded_at":          "2026-10-02T15:01:00Z"
}
```

**`reason` enum:**
- `ADMIN_REFUND`
- `USER_REQUEST`
- `CHARGEBACK`
- `PROVIDER_INITIATED`

---

## 5. payout.requested.v1

**Producer:** `tolkien`
**Consumers:** `saruman` (validates balance), `palantir-gateway` (executes)
**Trigger:** Streamer clicks Request Payout in dashboard.

**Subject:** `payout.requested.v1.<streamer_id>`

**Payload:**
```json
{
  "payout_id":           "uuid",
  "streamer_id":         "uuid",
  "amount_idr":          1500000,
  "bank_account_id":     "uuid",
  "bank_account_last4":  "1234",
  "bank_code":           "BCA",
  "requested_at":        "2026-10-02T16:00:00Z"
}
```

---

## 6. payout.settled.v1

**Producer:** `palantir-gateway`
**Consumers:** `saruman`, `analytics`
**Trigger:** Bank transfer confirmed by provider.

**Subject:** `payout.settled.v1.<streamer_id>`

**Payload:**
```json
{
  "payout_id":           "uuid",
  "streamer_id":         "uuid",
  "amount_idr":          1500000,
  "provider_payout_id":  "WD-98765",
  "bank_reference":      "TRF-20261002-XYZ",
  "settled_at":          "2026-10-02T16:05:00Z"
}
```

---

## 7. payout.failed.v1

**Producer:** `palantir-gateway`
**Consumers:** `saruman`
**Trigger:** Bank rejects transfer.

**Subject:** `payout.failed.v1.<streamer_id>`

**Payload:**
```json
{
  "payout_id":      "uuid",
  "streamer_id":    "uuid",
  "amount_idr":     1500000,
  "failure_reason": "INVALID_ACCOUNT",                       // enum
  "provider_error": "Bank account not found",                // optional human msg
  "failed_at":      "2026-10-02T16:01:00Z"
}
```

**`failure_reason` enum:**
- `INVALID_ACCOUNT`
- `BANK_REJECTED`
- `PROVIDER_ERROR`
- `TIMEOUT`

---

## 8. streamer.registered.v1

**Producer:** `tolkien`
**Consumers:** `saruman` (provision ledger accounts), `palantir-gateway` (provision provider account)
**Trigger:** Streamer signs up.

**Subject:** `streamer.registered.v1.<streamer_id>`

**Payload:**
```json
{
  "streamer_id":   "uuid",
  "email":         "streamer@example.com",
  "display_name":  "Pakde Streamer",
  "registered_at": "2026-10-02T13:00:00Z"
}
```

---

## 9. overlay.token.rotated.v1

**Producer:** `tolkien`
**Consumers:** `saruman` (cache invalidation), `audit_log`, optional `realtime-gateway`
**Trigger:** Streamer rotates OBS overlay token via dashboard.

**Subject:** `overlay.token.rotated.v1.<streamer_id>`

**Payload:**
```json
{
  "streamer_id":        "uuid",
  "old_token_last4":    "xY7Z",
  "new_token_last4":    "aB3X",
  "rotated_at":         "2026-10-02T13:30:00Z",
  "client_ip":          "203.0.113.42"
}
```

**Side effects:**
- Saruman invalidates token validation cache for this streamer.
- Old token rejected on next WS connect.
- Existing OBS clients will reconnect with new URL (from dashboard).

---

## 10. fraud.flagged.v1

**Producer:** `saruman`
**Consumers:** ops dashboard, optional auto-blocker
**Trigger:** Inline velocity rule trips in webhook ingest path.

**Subject:** `fraud.flagged.v1.<streamer_id>` (or `.global` if no streamer)

**Payload:**
```json
{
  "rule":            "VEL_CARD_DONATIONS_PER_MIN",           // enum
  "streamer_id":     "uuid-or-null",
  "donor_fingerprint":"card-1234-or-ip-203.0.113.42",
  "count":           7,
  "window_seconds":  60,
  "action_taken":    "BLOCKED",                              // or ALLOWED_BUT_FLAGGED
  "flagged_at":      "2026-10-02T14:35:00Z"
}
```

**`rule` enum (MVP):**
- `VEL_CARD_DONATIONS_PER_MIN` (> 5/min same card)
- `VEL_CARD_DONATIONS_PER_DAY` (> 500000 IDR/day same card)
- `BLOCKED_CARD` (`4242 4242 4242 4242`)
- `BLOCKED_IP` (manual blocklist)

---

## Reserved topics (do NOT publish at MVP)

These are reserved for Phase 2+. Do not use these topic names:

- `donation.subscribed.v1` (subscriptions / recurring)
- `goal.reached.v1` (goal meters)
- `moderation.flagged.v1` (moderation queue)
- `analytics.*.v1` (analytics stream)

If you need a new topic, add to this file. Don't invent names in code.

---

*See `08-flow-diagrams.md` for the visual flow of each event.*