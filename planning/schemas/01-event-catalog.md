# 01 — Event Catalog (v2 Topics)

> **Every event Inflora publishes, with producer, consumers, payload schema, and trigger.**
> Format follows `00-frozen-contracts.md` envelope. Version `v1` unless noted otherwise.

---

## Index (v2)

| Topic | Producer | Consumers | Trigger |
|---|---|---|---|
| `donation.intent.created.v1` | ingest-api | saruman | Donor submits donation form |
| `donation.charged.v1` | saruman | realtime-gateway, analytics | Provider capture webhook + ledger |
| `donation.settled.v1` | saruman | realtime-gateway (delayed alert), analytics | Provider settlement webhook (T+N) |
| `donation.failed.v1` | saruman | analytics | Provider failure OR intent expiry |
| `donation.refunded.v1` | saruman | analytics | Refund completed |
| `donation.receipt_sent.v1` | saruman | analytics | Donor receipt email sent |
| `payout.requested.v1` | tolkien | saruman, palantir-gateway | Streamer requests payout |
| `payout.batched.v1` | tolkien (admin) | saruman, palantir-gateway | FinOps assigns payouts to a batch |
| `payout.settled.v1` | palantir-gateway | saruman, analytics | Bank transfer confirmed |
| `payout.failed.v1` | palantir-gateway | saruman | Bank rejects |
| `payout.batch.executed.v1` | tolkien (admin) | saruman, palantir-gateway | FinOps executes bulk batch |
| `payout.batch.completed.v1` | palantir-gateway | saruman, analytics | All payouts in batch settled |
| `payout.batch.failed.v1` | palantir-gateway | saruman, analytics | Bulk batch failed |
| `streamer.registered.v1` | tolkien | saruman, palantir-gateway | Signup |
| `streamer.settings.updated.v1` | tolkien | saruman, realtime-gateway | Streamer updates settings |
| `overlay.token.rotated.v1` | tolkien | saruman, audit | OBS token rotated |
| `fund_hold.created.v1` | tolkien (admin/finops) | saruman | Hold placed on staff |
| `fund_hold.released.v1` | tolkien (admin/finops) | saruman | Hold released |
| `fraud.flagged.v1` | saruman | ops dashboard | Inline velocity rule trips |

---

## 1. donation.intent.created.v1

**Producer:** `ingest-api`
**Consumers:** `saruman` (validates, transitions to CHARGED on payment)
**Trigger:** Donor submits donation form.

**Subject:** `donation.intent.created.v1.<streamer_id>`

**Payload:**
```json
{
  "intent_id":           "uuid",
  "donation_id":         "uuid",
  "streamer_id":         "uuid",
  "amount_idr":          10000,
  "payment_method":      "QRIS",
  "donor_display_name":  "Andi",
  "donor_email":         "andi@example.com",
  "message":             "Semangat streamingnya bang!",
  "is_anonymous":        false,
  "voice_url":           "https://cdn.inflora.app/voice/abc.mp3",
  "voice_duration_sec":  8,
  "youtube_url":         "https://youtu.be/xyz",
  "youtube_start_sec":   30,
  "youtube_end_sec":     45,
  "client_ip":           "203.0.113.42",
  "user_agent":          "Mozilla/5.0 ...",
  "captcha_token":       "string",
  "expires_at":          "2026-10-02T14:45:00Z",
  "created_at":          "2026-10-02T14:30:00Z"
}
```

**Validation rules:**
- `amount_idr`: 1000 ≤ amount ≤ 10_000_000 (per-streamer limits in `streamer_settings`)
- `donor_email`: optional, RFC 5322; if provided, receipt sent
- `donor_display_name`: ≤ 80 chars (required unless `is_anonymous=true`)
- `message`: ≤ 500 chars
- `voice_url`: ≤ 500 chars, must be https://
- `voice_duration_sec`: ≤ 60 sec (system cap)
- `youtube_url`: optional; if provided, `youtube_start_sec` + `youtube_end_sec` required, `end > start`, max duration 60 sec
- `payment_method`: must be one the streamer accepts

---

## 2. donation.charged.v1

**Producer:** `saruman`
**Consumers:** `realtime-gateway` (immediate fanout), `analytics`
**Trigger:** Provider capture webhook AND ledger write commits.

**Subject:** `donation.charged.v1.<streamer_id>`

**Payload:**
```json
{
  "donation_id":            "uuid",
  "intent_id":              "uuid",
  "streamer_id":            "uuid",
  "amount_idr":             10000,
  "mdr_idr":                70,
  "mdr_rate_bps":           70,
  "gross_charged_idr":      10070,
  "platform_fee_idr":       1,
  "net_idr":                9999,
  "currency":               "IDR",
  "settlement_status":      "PENDING",
  "donor_display_name":     "Andi",
  "is_anonymous":           false,
  "message":                "Semangat streamingnya bang!",
  "voice_url":              "https://cdn.inflora.app/voice/abc.mp3",
  "voice_duration_sec":     8,
  "youtube_url":            "https://youtu.be/xyz",
  "youtube_start_sec":      30,
  "youtube_end_sec":        45,
  "display_duration_sec":   10,
  "provider_charge_id":     "TRX-12345",
  "provider_name":          "midtrans",
  "payment_method":         "QRIS",
  "ledger_entry_ids":       ["uuid-1", "uuid-2"],
  "ledger_correlation_id":  "corr-uuid",
  "captured_at":            "2026-10-02T14:30:01.500Z",
  "expected_settled_at":    "2026-10-02T15:30:00Z"
}
```

**Invariants:**
- Exactly 2 ledger entries: `donor_cash +gross_charged`, `streamer_pending +net_idr` (or +amount-fee).
- `donation.status = CHARGED`, `settlement_status = PENDING`.
- `display_duration_sec = clamp(amount_idr / display_rate_idr_per_sec, min, max)` — snapshot at capture.
- Idempotent: if webhook retries, this event re-fires only if NOT previously emitted.

---

## 3. donation.settled.v1

**Producer:** `saruman`
**Consumers:** `realtime-gateway` (optional "settled" notification, configurable), `analytics`
**Trigger:** Provider settlement webhook fires T+N (typically minutes for QRIS, T+1 for VA, T+2-3 for CC).

**Subject:** `donation.settled.v1.<streamer_id>`

**Payload:**
```json
{
  "donation_id":            "uuid",
  "intent_id":              "uuid",
  "streamer_id":            "uuid",
  "amount_idr":             10000,
  "mdr_idr":                70,
  "net_idr":                9999,
  "provider_name":          "midtrans",
  "provider_settlement_id": "STL-98765",
  "settlement_held_seconds": 1800,
  "ledger_entry_ids":       ["uuid-3", "uuid-4"],     -- new entries: pending->available move
  "ledger_correlation_id":  "corr-uuid",
  "settled_at":             "2026-10-02T15:00:00Z"
}
```

**Invariants:**
- `donation.settlement_status = SETTLED`, `donation.settled_at` set.
- 2 NEW ledger entries: `streamer_pending -net`, `streamer_available +net`.
- After this event: streamer can include this donation in a payout request.

---

## 4. donation.failed.v1

*(unchanged from v1 — see below for backward compat note)*

**Subject:** `donation.failed.v1.<streamer_id>`

```json
{
  "intent_id":      "uuid",
  "donation_id":    "uuid",
  "streamer_id":    "uuid",
  "amount_idr":     50000,
  "failure_reason": "INSUFFICIENT_FUNDS",
  "provider_error_code": "201",
  "provider_name":  "midtrans",
  "failed_at":      "2026-10-02T14:32:00Z"
}
```

---

## 5. donation.refunded.v1

*(unchanged from v1)*

---

## 6. donation.receipt_sent.v1  (NEW)

**Producer:** `saruman` (after `email_service.Send()` succeeds)
**Consumers:** `analytics`
**Trigger:** Email receipt successfully delivered to donor's email.

**Subject:** `donation.receipt_sent.v1.<streamer_id>`

**Payload:**
```json
{
  "donation_id":      "uuid",
  "intent_id":        "uuid",
  "streamer_id":      "uuid",
  "donor_email":      "andi@example.com",
  "receipt_id":       "uuid",                            -- email_receipts.id
  "provider_msg_id":  "<ses-message-id>",
  "amount_idr":       10000,
  "gross_charged_idr":10070,
  "sent_at":          "2026-10-02T14:30:05Z"
}
```

**Side effects:**
- INSERT `email_receipts` (status=SENT)
- Provider's message id stored for tracking

---

## 7. payout.requested.v1

*(unchanged from v1, but now blocked by holds + min 10000)*

```json
{
  "payout_id":           "uuid",
  "streamer_id":         "uuid",
  "amount_idr":          150000,
  "bank_account_id":     "uuid",
  "bank_account_last4":  "1234",
  "bank_code":           "BCA",
  "requested_at":        "2026-10-02T16:00:00Z"
}
```

**Validation now:**
- `amount_idr >= 10000` (min withdrawal)
- No active `fund_holds` for this streamer

---

## 8. payout.batched.v1  (NEW)

**Producer:** `tolkien` (admin/finops action: `POST /v1/admin/payout-batches`)
**Consumers:** `saruman`, `palantir-gateway`, `analytics`
**Trigger:** FinOps creates a batch.

**Subject:** `payout.batched.v1.<streamer_id>` (one per payout in batch)

**Payload:**
```json
{
  "batch_id":          "uuid",
  "payout_id":         "uuid",
  "streamer_id":       "uuid",
  "amount_idr":        150000,
  "bank_account_last4": "1234",
  "batch_total_idr":   5000000,
  "batch_payout_count": 25,
  "fifo_position":     161,                              -- position in batch by requested_at
  "batched_at":        "2026-10-05T09:00:00Z"
}
```

---

## 9. payout.settled.v1

*(unchanged from v1)*

---

## 10. payout.failed.v1

*(unchanged from v1)*

---

## 11. payout.batch.executed.v1  (NEW)

**Producer:** `tolkien` (admin/finops: `POST /v1/admin/payout-batches/:id/execute`)
**Consumers:** `saruman`, `palantir-gateway`, `analytics`
**Trigger:** FinOps executes a batch.

**Subject:** `payout.batch.executed.v1.<streamer_id>` (one per payout in batch)

**Payload:**
```json
{
  "batch_id":          "uuid",
  "payout_id":         "uuid",
  "streamer_id":       "uuid",
  "amount_idr":        150000,
  "provider_batch_id": "BATCH-MIDTRANS-98765",
  "provider_name":     "midtrans",
  "executed_at":       "2026-10-05T10:00:00Z"
}
```

---

## 12. payout.batch.completed.v1  (NEW)

**Producer:** `palantir-gateway`
**Consumers:** `saruman`, `analytics`
**Trigger:** All payouts in batch settled.

**Subject:** `payout.batch.completed.v1` (no streamer_id)

**Payload:**
```json
{
  "batch_id":               "uuid",
  "total_amount_idr":       5000000,
  "settled_count":          25,
  "failed_count":           0,
  "provider_batch_id":      "BATCH-MIDTRANS-98765",
  "completed_at":           "2026-10-05T10:30:00Z"
}
```

---

## 13. payout.batch.failed.v1  (NEW)

**Producer:** `palantir-gateway`
**Consumers:** `saruman`, `analytics`
**Trigger:** Bulk batch failed (provider-side).

**Payload:**
```json
{
  "batch_id":          "uuid",
  "failure_reason":    "PROVIDER_REJECTED",
  "provider_error":    "Invalid bulk transfer configuration",
  "failed_at":         "2026-10-05T10:01:00Z"
}
```

---

## 14. streamer.registered.v1

*(unchanged from v1)*

---

## 15. streamer.settings.updated.v1  (NEW)

**Producer:** `tolkien`
**Consumers:** `saruman` (display_rate used for new donations), `realtime-gateway` (cache)
**Trigger:** Streamer updates their settings (display rate, allowed content types, etc).

**Subject:** `streamer.settings.updated.v1.<streamer_id>`

**Payload:**
```json
{
  "streamer_id":               "uuid",
  "display_rate_idr_per_sec":   10000,
  "display_min_sec":           5,
  "display_max_sec":           60,
  "show_donor_name":           true,
  "allow_voice":               true,
  "allow_youtube":             true,
  "auto_play_voice":           true,
  "auto_play_youtube":         true,
  "notify_on_donation":        true,
  "min_donation_idr":          1000,
  "max_donation_idr":          10000000,
  "updated_at":                "2026-10-02T14:00:00Z"
}
```

---

## 16. overlay.token.rotated.v1

*(unchanged from v1)*

---

## 17. fund_hold.created.v1  (NEW)

**Producer:** `tolkien` (admin/finops action: `POST /v1/admin/holds`)
**Consumers:** `saruman` (rejects payout creation), `audit_log`
**Trigger:** Hold placed on streamer/donation/payout.

**Subject:** `fund_hold.created.v1.<streamer_id>` (when target=STREAMER/DONATION/PAYOUT)

**Payload:**
```json
{
  "hold_id":          "uuid",
  "target_type":      "STREAMER" | "DONATION" | "PAYOUT",
  "streamer_id":      "uuid",
  "donation_id":      "uuid-or-null",
  "payout_id":        "uuid-or-null",
  "amount_idr":       1500000,                              -- null if whole-streamer hold
  "reason":           "Investigating fraud report #423",
  "expires_at":       "2026-11-01T00:00:00Z",
  "created_by":       "uuid",
  "created_at":       "2026-10-02T14:00:00Z"
}
```

**Side effects (when target=STREAMER, amount_idr given):**
- INSERT ledger_entries x 2: `STREAMER_AVAILABLE -HOLD` (HOLD_DEBIT), `HOLD_escrow +HOLD` (HOLD_CREDIT)
- Or simpler: just mark `fund_holds.status = ACTIVE`; balance check excludes held amount

---

## 18. fund_hold.released.v1  (NEW)

**Producer:** `tolkien` (admin/finops action: `DELETE /v1/admin/holds/:id`)
**Consumers:** `saruman`
**Trigger:** Hold released (manual or expired).

**Subject:** `fund_hold.released.v1.<streamer_id>`

**Payload:**
```json
{
  "hold_id":         "uuid",
  "target_type":     "STREAMER",
  "streamer_id":     "uuid",
  "released_by":     "uuid",
  "released_at":     "2026-10-15T10:00:00Z",
  "resolution_note": "Investigation cleared, no fraud found"
}
```

---

## 19. fraud.flagged.v1

*(unchanged from v1)*

---

## Reserved topics (do NOT publish at MVP)

These are reserved for Phase 2+. Do not use these topic names:
- `donation.subscribed.v1` (subscriptions / recurring)
- `goal.reached.v1` (goal meters)
- `moderation.flagged.v1` (moderation queue)
- `analytics.*.v1` (analytics stream)

---

*See `08-flow-diagrams.md` for the visual flow of each event. v2 adds: Settlement flow (Flow 11), Email Receipt flow (Flow 12), Hold flow (Flow 13), Batch Payout flow (Flow 14).*