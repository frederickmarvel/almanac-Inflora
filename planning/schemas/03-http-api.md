# 03 — HTTP API Schema (REST)

> All REST endpoints exposed by Inflora services.
> Standard error format per `00-frozen-contracts.md` §6.
> Auth via `Authorization: Bearer <token>` (session or overlay).

**Base URLs:**
- Dashboard / streamer-facing: `https://app.inflora.app` (tolkien)
- Public / donor-facing: `https://ingest.inflora.app` (ingest-api)
- Internal (service-to-service): `https://saruman.inflora.internal` etc.

---

## 1. Auth (tolkien)

### POST /v1/auth/signup

**Auth:** none
**Rate limit:** 5/min/IP

**Request:**
```json
{
  "email":         "streamer@example.com",
  "password":      "SecurePass123!",
  "display_name":  "Pakde Streamer"
}
```

**Response 201:**
```json
{
  "streamer": {
    "id":            "uuid",
    "email":         "streamer@example.com",
    "display_name":  "Pakde Streamer",
    "created_at":    "2026-10-02T13:00:00Z"
  },
  "session_token": "sk_xxx",
  "expires_at":    "2026-11-01T13:00:00Z"
}
```

**Errors:**
- `400 VALIDATION_FAILED` — bad email/password/display_name
- `409 STREAMER_NOT_FOUND` — wait, `409 EMAIL_EXISTS` (add to error codes)
- `429 RATE_LIMITED`

**Side effects:**
- INSERT streamers
- INSERT sessions (purpose=SESSION)
- Publish `streamer.registered.v1`
- Saruman + palantir provision ledger accounts + provider account (consumers of event)

---

### POST /v1/auth/login

**Auth:** none
**Rate limit:** 5/min/IP (after 3 failures: 1/min hour)

**Request:**
```json
{
  "email":    "streamer@example.com",
  "password": "SecurePass123!"
}
```

**Response 200:**
```json
{
  "session_token": "sk_xxx",
  "expires_at":    "...",
  "streamer":      { ... }
}
```

**Errors:**
- `401 INVALID_TOKEN` (don't differentiate INVALID vs NOT_FOUND for security)
- `403 STREAMER_INACTIVE` (account disabled)

---

### POST /v1/auth/logout

**Auth:** required (session token)

**Response 204**

---

## 3. Me endpoints (tolkien)

### GET /v1/me

**Auth:** session

**Response 200:**
```json
{
  "id":            "uuid",
  "email":         "streamer@example.com",
  "display_name":  "Pakde Streamer",
  "is_verified":   false,
  "is_active":     true,
  "created_at":    "...",
  "last_login_at": "..."
}
```

---

### GET /v1/me/balance

**Auth:** session

**Response 200:**
```json
{
  "currency":                    "IDR",
  "pending_idr":                  145000,    -- streamer_pending balance
  "paid_idr":                     2500000,   -- streamer_paid (already paid out, sum is informational)
  "available_idr":                 145000,    -- == pending_idr; semantic alias
  "lifetime_donations_count":     87,
  "lifetime_donations_idr":      4350000
}
```

**Errors:**
- `401 INVALID_TOKEN`

---

### POST /v1/me/overlay-token/rotate

**Auth:** session

**Response 200:**
```json
{
  "token":                   "ok_<full-token>",   -- SHOWN ONCE. Never recoverable.
  "last4":                   "aB3X",
  "url":                     "wss://overlay.inflora.app/ws?token=ok_<full-token>",
  "obs_browser_source_url":  "https://overlay.inflora.app/?token=ok_<full-token>",
  "created_at":              "2026-10-02T13:30:00Z",
  "expires_at":              "2027-01-01T00:00:00Z"
}
```

**Side effects:**
- UPDATE old session SET revoked_at = NOW()
- INSERT new session (purpose=OVERLAY)
- INSERT audit_log (TOKEN_ROTATE)
- Publish `overlay.token.rotated.v1`
- Saruman invalidates token cache for this streamer

---

### GET /v1/me/bank-accounts

**Auth:** session

**Response 200:**
```json
{
  "data": [
    {
      "id":            "uuid",
      "bank_code":     "BCA",
      "last4":         "1234",
      "account_name":  "Pakde Streamer",
      "is_primary":    true,
      "is_verified":   true
    }
  ]
}
```

### POST /v1/me/bank-accounts

**Auth:** session

**Request:**
```json
{
  "bank_code":     "BCA",
  "account_number":"1234567890",
  "is_primary":    true
}
```

**Response 201:** `{"id": "uuid", "last4": "7890", ...}`

---

### POST /v1/me/payouts

**Auth:** session

**Request:**
```json
{
  "amount_idr":       145000,
  "bank_account_id":  "uuid"
}
```

**Response 201:**
```json
{
  "payout_id":      "uuid",
  "amount_idr":     145000,
  "status":         "REQUESTED",
  "requested_at":   "2026-10-02T16:00:00Z"
}
```

**Errors:**
- `422 INSUFFICIENT_BALANCE` (payout > pending)
- `404 BANK_ACCOUNT_NOT_FOUND` (add to error codes)
- `400 VALIDATION_FAILED`

**Side effects:**
- INSERT payouts (REQUESTED)
- BEGIN: ledger_entries x4 (donor→reserve, streamer_pending -X, streamer_paid +X, donor_cash -X) — actually 2 entries: streamer_pending -X, streamer_paid +X
- Publish `payout.requested.v1`
- Palantir consumes event, calls provider CreatePayout

---

### GET /v1/me/payouts?limit=20&cursor=...

**Auth:** session

**Response 200:**
```json
{
  "data": [
    {
      "id":               "uuid",
      "amount_idr":       145000,
      "status":           "SETTLED",
      "bank_account_last4":"1234",
      "requested_at":     "...",
      "settled_at":       "..."
    }
  ],
  "pagination": { "next_cursor": null, "has_more": false }
}
```

---

### GET /v1/me/donations?limit=20&cursor=...

**Auth:** session

**Response 200:**
```json
{
  "data": [
    {
      "id":                  "uuid",
      "amount_idr":          50000,
      "net_idr":             49995,
      "status":              "CHARGED",
      "donor_display_name":  "Andi",
      "is_anonymous":        false,
      "message":             "...",
      "created_at":          "...",
      "charged_at":          "..."
    }
  ],
  "pagination": { "next_cursor": "...", "has_more": true }
}
```

---

## 4. Public endpoints (ingest-api)

### GET /d/:streamer_id

**Auth:** none

**Response 200:** HTML page (donor landing). Shows:
- Streamer avatar + display name
- Recent donations ticker (last 5)
- Donation form (amount picker + name + message)

---

### POST /v1/donations

**Auth:** none (CAPTCHA + rate limit per IP)
**Rate limit:** 10/min/IP, 100/hour/IP

**Request:**
```json
{
  "streamer_id":        "uuid",
  "amount_idr":         50000,
  "donor_display_name": "Andi",
  "message":            "Semangat bang!",
  "is_anonymous":       false,
  "captcha_token":      "string"
}
```

**Validation:**
- `amount_idr`: 1000 ≤ amount ≤ 10_000_000
- `donor_display_name`: ≤ 80 chars (required unless `is_anonymous=true`)
- `message`: ≤ 500 chars
- `streamer_id`: must exist and `is_active`

**Response 201:**
```json
{
  "intent_id":     "uuid",
  "donation_id":   "uuid",
  "amount_idr":    50000,
  "platform_fee_idr": 5,
  "net_idr":       49995,
  "currency":      "IDR",
  "payment_url":   "https://app.midtrans.com/snap/v2/vtweb/<token>",
  "expires_at":    "2026-10-02T14:45:00Z"
}
```

**Errors:**
- `400 VALIDATION_FAILED`
- `404 STREAMER_NOT_FOUND`
- `403 STREAMER_INACTIVE`
- `422 INSUFFICIENT_AMOUNT` (below floor)
- `429 RATE_LIMITED`
- `400 CAPTCHA_FAILED`

**Side effects:**
- INSERT donations (INTENT_CREATED, expires_at = NOW() + 15min)
- INSERT idempotency
- Publish `donation.intent.created.v1.<streamer_id>`
- Call palantir-gateway gRPC `CreateTopUp` to get payment_url
- Return payment_url to donor

---

### POST /v1/webhooks/payment

**Auth:** HMAC signature (provider-specific, see `06-webhook-schemas.md`)
**Idempotency:** `Idempotency-Key: <key>` header (required)

**Request:** provider-specific body

**Response 200:**
```json
{
  "received": true,
  "event_id": "uuid"
}
```

**Errors:**
- `400 INVALID_SIGNATURE`
- `400 VALIDATION_FAILED`
- `200 IDEMPOTENCY_CONFLICT` (idempotent retry — return cached response)

**Side effects (provider-specific):**
- For settlement: call saruman gRPC `SettleTopUp` → ledger entries + publish `donation.charged.v1`
- For failure: update donation.status=FAILED, publish `donation.failed.v1`
- For refund: update refund + publish `donation.refunded.v1`

---

## 5. Internal endpoints (service-to-service)

### POST /v1/internal/validate-overlay-token  (tolkien)

**Auth:** internal API key (header `X-Internal-Api-Key`)
**Called by:** friend (WS gateway)

**Request:**
```json
{
  "token": "ok_xxx"
}
```

**Response 200:**
```json
{
  "streamer_id": "uuid",
  "expires_at":  "2027-01-01T00:00:00Z",
  "is_active":   true
}
```

**Errors:**
- `401 INVALID_TOKEN`
- `403 TOKEN_EXPIRED`
- `403 STREAMER_INACTIVE`

**Caching:** friend (WS gateway) caches result for 60s.

---

### POST /v1/internal/rotate-overlay-token-invalidate  (tolkien → saruman)

**Auth:** internal API key

**Request:**
```json
{
  "streamer_id": "uuid"
}
```

**Response 204**

**Side effects:**
- Saruman invalidates its 60s token cache for this streamer.
- Next WS connect will re-validate against tolkien.

---

### POST /v1/internal/replay-events  (saruman)

**Auth:** internal API key

**Request:**
```json
{
  "streamer_id":  "uuid",
  "from_seq":     42,
  "to_seq":       47
}
```

**Response 200:**
```json
{
  "events": [
    { "type": "donation", "seq": 42, "data": { ... } },
    { "type": "donation", "seq": 43, "data": { ... } }
  ]
}
```

**Used by:** friend (WS gateway) for catch-up after reconnect.

---

## 6. Admin endpoints

### POST /v1/admin/donations/:id/refund

**Auth:** admin token
**Audit:** writes `audit_log` row

**Request:**
```json
{
  "reason": "ADMIN_REFUND",
  "note":   "Donor requested via email"
}
```

**Response 200:**
```json
{
  "refund_id":   "uuid",
  "donation_id": "uuid",
  "amount_idr":  50000,
  "status":      "PROCESSING"
}
```

**Side effects:**
- INSERT refunds
- INSERT ledger_entries x 2 (reversal: donor_cash -X, streamer_pending -X)
- Publish `donation.refunded.v1`
- Call palantir-gateway gRPC `CreateRefund`

---

### POST /v1/admin/streamers/:id/drain

**Auth:** admin token

**Response 200:**
```json
{
  "drained_clients": 3
}
```

**Side effects:**
- Send WS close frame to all OBS clients for this streamer (code 1011 + reason "drained")
- Logged to audit_log

---

### POST /v1/admin/streamers/:id/rotate-token

**Auth:** admin token

**Response 200:**
```json
{
  "new_token_last4": "aB3X"
}
```

**Use case:** only when token is exposed. Generates new token, revokes old, logs to audit.

---

### POST /v1/admin/events/replay

**Auth:** admin token

**Request:**
```json
{
  "streamer_id": "uuid",
  "topic":       "donation.charged.v1",
  "from":        "2026-10-02T14:00:00Z",
  "to":          "2026-10-02T14:30:00Z"
}
```

**Response 200:**
```json
{
  "events": [ ... ]
}
```

---

## 7. Health endpoints (all services)

### GET /healthz

**Auth:** none
**Response 200:**
```json
{
  "status":   "ok",
  "version":  "1.2.3",
  "uptime_seconds": 3600
}
```

---

### GET /readyz

**Auth:** none
**Response 200:**
```json
{
  "status": "ok",
  "checks": {
    "db":   "ok",
    "nats": "ok"
  }
}
```

**Response 503:**
```json
{
  "status": "fail",
  "checks": {
    "db":   "ok",
    "nats": "fail"
  }
}
```

---

### GET /metrics

**Auth:** internal (Prometheus scrape)
**Response 200:** Prometheus exposition format

```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{endpoint="/v1/donations",method="POST",status="201"} 1234
...
```

**Required metrics:**
- `http_requests_total{endpoint,method,status}`
- `http_request_duration_seconds{endpoint,method}` (histogram)
- `db_connections_active{database="main"}`
- `db_queries_total{query_type}`
- `events_published_total{topic}`
- `events_consumed_total{topic, consumer_group}`
- `ledger_balance_idr{account_type, streamer_id}`
- `ws_connections_active{streamer_id}` (gateway only)

---

## 8. Error code registry

Add new codes here. Never invent at call site.

| Code | HTTP | Meaning |
|---|---|---|
| `VALIDATION_FAILED` | 400 | Generic validation |
| `INVALID_SIGNATURE` | 400 | Webhook HMAC bad |
| `CAPTCHA_FAILED` | 400 | |
| `INVALID_TOKEN` | 401 | |
| `TOKEN_EXPIRED` | 401 | |
| `STREAMER_INACTIVE` | 403 | |
| `STREAMER_NOT_FOUND` | 404 | |
| `BANK_ACCOUNT_NOT_FOUND` | 404 | |
| `EMAIL_EXISTS` | 409 | |
| `IDEMPOTENCY_CONFLICT` | 409 | |
| `INSUFFICIENT_BALANCE` | 422 | |
| `INSUFFICIENT_AMOUNT` | 422 | |
| `STREAMER_INACTIVE` | 403 | |
| `RATE_LIMITED` | 429 | |
| `PROVIDER_ERROR` | 502 | |
| `INTERNAL` | 500 | |
| `SERVICE_UNAVAILABLE` | 503 | |

---

*See `01-event-catalog.md` for events fired by these endpoints, and `08-flow-diagrams.md` for how they wire together.*