# 03 — HTTP API Schema (REST) — v2

> All REST endpoints exposed by Inflora services. v2 adds: MDR computation, settlement, email receipts, holds, batches, finops actions.

---

## 4. Public endpoints (ingest-api)

### POST /v1/donations

**Auth:** none (CAPTCHA + rate limit per IP)
**Rate limit:** 10/min/IP, 100/hour/IP

**Request:**
```json
{
  "streamer_id":         "uuid",
  "amount_idr":          10000,
  "payment_method":      "QRIS",
  "donor_display_name":  "Andi",
  "donor_email":         "andi@example.com",
  "message":             "Semangat bang!",
  "is_anonymous":        false,
  "voice_url":           "https://cdn.inflora.app/voice/abc.mp3",
  "voice_duration_sec":  8,
  "youtube_url":         "https://youtu.be/xyz",
  "youtube_start_sec":   30,
  "youtube_end_sec":     45,
  "captcha_token":       "string"
}
```

**Validation:**
- `amount_idr`: per-streamer min/max from `streamer_settings`
- `donor_email`: RFC 5322 if provided
- `donor_display_name`: ≤ 80 chars (required unless `is_anonymous=true`)
- `message`: ≤ 500 chars
- `payment_method`: must be allowed by streamer; determines MDR
- `voice_url`: optional; `voice_duration_sec ≤ 60`
- `youtube_url`: optional; if provided, `youtube_start_sec` + `youtube_end_sec` required, `end > start`, clip ≤ 60 sec

**Response 201:**
```json
{
  "intent_id":           "uuid",
  "donation_id":         "uuid",
  "amount_idr":          10000,
  "mdr_idr":             70,
  "mdr_rate_bps":        70,
  "gross_charged_idr":   10070,
  "platform_fee_idr":    1,
  "net_idr":             9999,
  "currency":            "IDR",
  "display_duration_sec": 10,
  "payment_url":         "https://app.midtrans.com/snap/v2/vtweb/<token>",
  "expires_at":          "2026-10-02T14:45:00Z"
}
```

**Errors:**
- `400 VALIDATION_FAILED`
- `400 CAPTURE_FAILED`
- `404 STREAMER_NOT_FOUND`
- `403 STREAMER_INACTIVE`
- `422 INSUFFICIENT_AMOUNT` (below floor)
- `429 RATE_LIMITED`

**Side effects:**
- INSERT donations (INTENT_CREATED, includes voice/youtube, donor_email, computed display_duration_sec)
- INSERT idempotency
- Publish `donation.intent.created.v1.<streamer_id>`
- Call palantir-gateway gRPC `CreateTopUp` with payment_method → provider returns payment_url

---

## 5. Me endpoints (tolkien)

### GET /v1/me/settings

**Auth:** session

**Response 200:**
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
  "updated_at":                "2026-10-02T13:00:00Z"
}
```

---

### PUT /v1/me/settings

**Auth:** session

**Request:** (any subset of fields)
```json
{
  "display_rate_idr_per_sec":   5000,
  "display_min_sec":           5,
  "display_max_sec":           90,
  "show_donor_name":           true,
  "allow_voice":               true,
  "allow_youtube":             true,
  "auto_play_voice":           true,
  "auto_play_youtube":         true,
  "min_donation_idr":          1000,
  "max_donation_idr":          10000000
}
```

**Response 200:** updated settings

**Validation:**
- `display_rate_idr_per_sec > 0`
- `display_min_sec ≤ display_max_sec`
- `min_donation_idr ≤ max_donation_idr`
- `min_donation_idr >= 1000` (system floor)

**Side effects:**
- UPDATE streamer_settings
- Publish `streamer.settings.updated.v1.<streamer_id>`
- Realtime-gateway caches new display_rate for new donations

---

### GET /v1/me/balance

**Response 200:**
```json
{
  "currency":                    "IDR",
  "pending_idr":                  45000,     -- captured, waiting settlement
  "available_idr":                145000,    -- settled, withdrawable
  "held_idr":                     50000,     -- active holds
  "net_withdrawable_idr":         95000,     -- available - held
  "lifetime_donations_count":     87,
  "lifetime_donations_idr":      4350000
}
```

---

### POST /v1/me/payouts

**Auth:** session

**Request:**
```json
{
  "amount_idr":       150000,
  "bank_account_id":  "uuid"
}
```

**Response 201:**
```json
{
  "payout_id":      "uuid",
  "amount_idr":     150000,
  "status":         "REQUESTED",
  "requested_at":   "2026-10-02T16:00:00Z"
}
```

**Validation:**
- `amount_idr >= 10000` (min withdrawal)
- `amount_idr <= streamer_available_idr` (cannot exceed available)
- No active `fund_holds` for streamer (`fund_hold.created.v1` check)
- Bank account must belong to streamer and be verified

**Errors:**
- `422 INSUFFICIENT_BALANCE`
- `422 BELOW_MIN_WITHDRAWAL`
- `403 STREAMER_HOLD_ACTIVE`
- `404 BANK_ACCOUNT_NOT_FOUND`
- `400 VALIDATION_FAILED`

**Side effects:**
- INSERT payouts (REQUESTED)
- BEGIN TX: ledger_entries x 2: `STREAMER_AVAILABLE -X`, `STREAMER_PAID +X`
- COMMIT
- INSERT audit_log
- Publish `payout.requested.v1.<streamer_id>`
- Palantir consumes event, calls provider CreatePayout (per single payout OR waits for batch)

---

## 6. Admin endpoints (tolkien — admin/finops only)

### POST /v1/admin/holds

**Auth:** admin or finops token

**Request:**
```json
{
  "target_type":   "STREAMER" | "DONATION" | "PAYOUT",
  "streamer_id":   "uuid",
  "donation_id":   "uuid-or-null",
  "payout_id":     "uuid-or-null",
  "amount_idr":    1500000,
  "reason":        "Investigating fraud report #423",
  "expires_at":    "2026-11-01T00:00:00Z"
}
```

**Response 201:**
```json
{
  "hold_id":    "uuid",
  "status":     "ACTIVE",
  "created_at": "..."
}
```

**Validation:**
- Exactly one of `donation_id` / `payout_id` set based on `target_type`
- `amount_idr` optional for STREAMER holds (whole-account hold if null)
- `amount_idr <= available_idr` (cannot hold more than available)

**Side effects:**
- INSERT fund_holds (ACTIVE)
- INSERT audit_log (HOLD_CREATED)
- Publish `fund_hold.created.v1.<streamer_id>`
- If amount > 0: ledger_entries x 2 (STREAMER_AVAILABLE -X, hold escrow +X) — optional pattern

---

### GET /v1/admin/holds?status=ACTIVE&target_type=STREAMER

**Auth:** admin/finops

**Response 200:**
```json
{
  "data": [
    {
      "hold_id":        "uuid",
      "target_type":    "STREAMER",
      "streamer_id":    "uuid",
      "amount_idr":      1500000,
      "reason":         "Investigating fraud report",
      "status":         "ACTIVE",
      "created_at":     "...",
      "expires_at":      "2026-11-01T00:00:00Z",
      "released_at":    null
    }
  ],
  "pagination": { "next_cursor": null, "has_more": false }
}
```

---

### DELETE /v1/admin/holds/:id

**Auth:** admin/finops

**Request body:**
```json
{ "resolution_note": "Investigation cleared" }
```

**Response 200:**
```json
{
  "hold_id":     "uuid",
  "status":      "RELEASED",
  "released_at": "..."
}
```

**Side effects:**
- UPDATE fund_holds (RELEASED, released_by, resolution_note)
- Publish `fund_hold.released.v1.<streamer_id>`
- Reverse any ledger hold entries

---

### POST /v1/admin/payout-batches

**Auth:** finops

**Request:**
```json
{
  "payout_ids":   ["uuid-1", "uuid-2", "uuid-3"],
  "auto_select":  false
}
```

If `auto_select: true`, server picks all REQUESTED payouts FIFO.

**Response 201:**
```json
{
  "batch_id":           "uuid",
  "status":             "DRAFT",
  "total_amount_idr":   5000000,
  "payout_count":       25,
  "fifo_first_requested_at": "2026-09-25T14:00:00Z",
  "fifo_last_requested_at":  "2026-10-05T09:30:00Z",
  "created_at":         "..."
}
```

**Side effects:**
- INSERT payout_batches (DRAFT)
- For each payout: UPDATE payouts SET batch_id=?, status=BATCHED
- Publish `payout.batched.v1.<streamer_id>` for each payout
- INSERT audit_log (BATCH_CREATED)

**Validation:**
- All `payout_ids` must be status=REQUESTED, not already batched
- No active holds on any streamer in batch (server pre-checks)

---

### GET /v1/admin/payout-batches?status=DRAFT

**Auth:** finops

**Response 200:**
```json
{
  "data": [
    {
      "id":                "uuid",
      "status":            "DRAFT",
      "total_amount_idr":  5000000,
      "payout_count":      25,
      "created_by":        "uuid",
      "created_at":        "..."
    }
  ],
  "pagination": { "next_cursor": null, "has_more": false }
}
```

---

### POST /v1/admin/payout-batches/:id/execute

**Auth:** finops

**Response 200:**
```json
{
  "batch_id":           "uuid",
  "status":             "EXECUTING",
  "provider_batch_id":  "BATCH-MIDTRANS-98765",
  "executed_at":        "..."
}
```

**Side effects:**
- UPDATE payout_batches SET status=EXECUTING, executing_at=NOW, provider_batch_id=?
- Call palantir-gateway gRPC `ExecuteBatch(batch_id, payout_ids, total)`
- For each payout: UPDATE payouts SET status=PROCESSING, processed_at=NOW
- Publish `payout.batch.executed.v1.<streamer_id>` for each payout

---

### POST /v1/admin/email-records/:donation_id/resend

**Auth:** admin

**Response 200:**
```json
{
  "receipt_id":    "uuid",
  "status":        "PENDING"
}
```

**Side effects:**
- INSERT email_receipts (PENDING) for same donation (idempotent via UNIQUE on donation_id)
- Trigger send

---

### Admin endpoints (existing, unchanged)

- `POST /v1/admin/donations/:id/refund` (Flow 6)
- `POST /v1/admin/streamers/:id/drain`
- `POST /v1/admin/streamers/:id/rotate-token`
- `POST /v1/admin/events/replay`

---

## 7. Internal endpoints (service-to-service)

### POST /v1/internal/validate-overlay-token  (tolkien)

*(unchanged from v1)*

---

### POST /v1/internal/send-receipt  (tolkien)

**Auth:** internal API key

**Request:**
```json
{
  "donation_id":      "uuid",
  "recipient_email":  "andi@example.com",
  "language":         "id"
}
```

**Response 200:**
```json
{
  "receipt_id":    "uuid",
  "status":        "SENT",
  "provider_msg_id":"<ses-id>"
}
```

**Side effects:**
- INSERT email_receipts
- Send via email provider (SES, SendGrid, etc.)
- Publish `donation.receipt_sent.v1.<streamer_id>` on success

---

## 8. Email receipts (saruman internal)

The email provider integration is internal — not exposed as REST. Saruman calls:
- `email_service.Send(to, subject, body)` — synchronous; returns `provider_msg_id`
- Used after settlement confirmation to send receipt

**Email template (Indonesian default):**
```
Subject: Terima kasih atas donasi Rp 50.000 untuk [streamer_name]

Hai [donor_name],

Donasi kamu sudah kami terima:
- Jumlah: Rp 50.000
- Biaya QRIS: Rp 350 (ditanggung kamu)
- Total dibayar: Rp 50.350
- Untuk streamer: [streamer_name]
- Pesan: [message]

[Inflora Invoice #INV-xxxxx]

Settlement: dana sedang diproses, tersedia dalam 1-3 hari kerja.

Lihat di dashboard: https://app.inflora.app/donations/[donation_id]
```

---

## 9. Error code additions (v2)

| Code | HTTP | Notes |
|---|---|---|
| `BELOW_MIN_WITHDRAWAL` | 422 | amount_idr < 10000 |
| `STREAMER_HOLD_ACTIVE` | 403 | fund hold blocks withdrawal |
| `DONATION_HOLD_ACTIVE` | 403 | |
| `PAYOUT_NOT_BATCHABLE` | 409 | status not REQUESTED |
| `BATCH_HAS_HOLDS` | 409 | some payouts blocked by holds |
| `SETTLEMENT_PENDING` | 422 | donation not yet settled (informational) |

(Other codes from v1 unchanged.)

---

*See `08-flow-diagrams.md` for end-to-end flows. v2 adds: Settlement, Email Receipt, Batch Payout, Fund Hold.*