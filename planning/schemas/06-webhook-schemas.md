# 06 — Webhook Schemas (Payment Providers)

> Inflora accepts webhooks from multiple payment providers.
> All webhooks MUST be signature-verified at the edge before any DB or business action.
> All webhooks MUST be idempotent — see `00-frozen-contracts.md` §5.

---

## 1. Common fields (all providers)

| Field | Type | Notes |
|---|---|---|
| `provider_name` | enum | `midtrans`, `xendit`, `pivot` |
| `provider_event_id` | string | Unique per provider. Idempotency key. |
| `event_type` | enum | `topup.completed`, `topup.failed`, `refund.completed` |
| `amount_idr` | BIGINT | Minor units. |
| `currency` | string | Always `IDR` at MVP. |
| `charge_id` | string | Provider's charge ID; matches palantir `gateway_topups.provider_charge_id`. |
| `raw_payload` | bytes | Stored in `webhook_events.payload` for audit. |

---

## 2. Midtrans Snap

**URL:** `POST https://ingest.inflora.app/v1/webhooks/payment`
**Trigger:** Transaction status change (settlement, capture, cancel, deny, expire, refund).
**Signature header:** `X-Signature: <hex-encoded SHA-256 hex of `<body>` + `<server_key>` + `<order_id>` + `<status_code>` + `<gross_amount>`>`

### 2.1 Signature verification

```
expected = sha512(order_id + status_code + gross_amount + server_key)
received = request.headers["X-Signature"]
match = hmac.compare_digest(expected, received)
```

Or simpler variant (Midtrans uses both):
```
expected = sha256(body + server_key)
received = request.headers["X-Signature"]
```

Verify both. Match either.

### 2.2 Payload — settlement

```json
{
  "transaction_time":   "2026-10-02 14:30:00",
  "transaction_status": "settlement",
  "transaction_id":     "abc-123-def-456",
  "status_message":     "midtrans payment notification",
  "status_code":        "200",
  "signature_key":      "<computed>",
  "payment_type":       "qris",
  "order_id":           "donation-<intent_id>",
  "gross_amount":       "50000.00",
  "currency":           "IDR",
  "fraud_status":       "accept",
  "merchant_id":        "M-INFLORA-001"
}
```

### 2.3 Status mapping

| `transaction_status` | `fraud_status` | Inflora action |
|---|---|---|
| `capture` | `accept` | mark `CHARGED`, fire `donation.charged.v1` |
| `capture` | `challenge` | mark `INTENT_CREATED` (manual review later) |
| `capture` | `deny` | mark `FAILED` (`failure_reason=FRAUD_BLOCKED`) |
| `settlement` | (any) | mark `CHARGED`, fire `donation.charged.v1` |
| `cancel` | — | mark `FAILED` (`USER_CANCELLED`) |
| `deny` | — | mark `FAILED` (`PROVIDER_ERROR`) |
| `expire` | — | mark `FAILED` (`TIMEOUT`) |
| `refund` | — | mark `REFUNDED`, fire `donation.refunded.v1` |
| `partial_refund` | — | mark partial refund |

### 2.4 Order ID convention

```
order_id = "donation-<intent_id>"
```

`intent_id` is Inflora's uuid. Midtrans echoes it back, which is how we correlate.

### 2.5 Required headers

| Header | Required | Notes |
|---|---|---|
| `Content-Type: application/json` | yes | |
| `X-Signature: <sha256>` | yes | Per §2.1 |
| `X-Request-Id: <uuid>` | no | Propagated for tracing |

### 2.6 Example verification (Go)

```go
func verifyMidtrans(body []byte, header string, serverKey string) bool {
    h := sha256.New()
    h.Write(body)
    h.Write([]byte(serverKey))
    expected := hex.EncodeToString(h.Sum(nil))
    return subtle.ConstantTimeCompare([]byte(header), []byte(expected)) == 1
}
```

---

## 3. Xendit Invoice

**URL:** `POST https://ingest.inflora.app/v1/webhooks/payment`
**Trigger:** Invoice status change (paid, expired, refunded).
**Signature header:** `X-Callback-Token: <shared webhook token>` (simple equality).

### 3.1 Signature verification

```go
if req.Header.Get("X-Callback-Token") != os.Getenv("XENDIT_WEBHOOK_TOKEN") {
    return 400, INVALID_SIGNATURE
}
```

Xendit uses shared-secret-in-header (less robust than HMAC, but per their docs).

### 3.2 Payload — paid

```json
{
  "id":              "xendit-invoice-id-98765",
  "external_id":     "donation-<intent_id>",
  "user_id":         "xendit-user-id",
  "status":          "PAID",
  "merchant_name":    "Inflora",
  "amount":          50000,
  "paid_amount":     50000,
  "currency":        "IDR",
  "payment_method":  "QRIS",
  "payment_channel": "qris",
  "payment_destination": "...",
  "paid_at":         "2026-10-02T14:30:01Z",
  "created":         "2026-10-02T14:25:00Z",
  "updated":         "2026-10-02T14:30:01Z",
  "description":     "Donation to <streamer_name>"
}
```

### 3.3 Status mapping

| `status` | Inflora action |
|---|---|
| `PAID` | mark `CHARGED`, fire `donation.charged.v1` |
| `EXPIRED` | mark `FAILED` (`TIMEOUT`) |
| `FAILED` | mark `FAILED` (`PROVIDER_ERROR`) |
| `REFUNDED` | mark `REFUNDED`, fire `donation.refunded.v1` (partial or full) |

### 3.4 Required headers

| Header | Required |
|---|---|
| `Content-Type: application/json` | yes |
| `X-Callback-Token: <token>` | yes |

### 3.5 Example verification (Go)

```go
func verifyXendit(req *http.Request) bool {
    return req.Header.Get("X-Callback-Token") == os.Getenv("XENDIT_WEBHOOK_TOKEN")
}
```

---

## 4. Pivot (development stub)

> `palantir.js/provider.Stub` — for local dev only. Auto-confirms payment.

**Payload:**
```json
{
  "event_id":          "stub-event-uuid",
  "event_type":        "topup.completed",
  "donation_intent_id":"uuid",
  "amount_idr":        50000,
  "currency":          "IDR",
  "donor_display_name": "Stub User",
  "settled_at":        "2026-10-02T14:30:00Z"
}
```

No signature — palantir-palantir in-process delivery.

---

## 5. Provider detection

```go
func detectProvider(req *http.Request) string {
    if req.Header.Get("X-Signature") != "" {
        return "midtrans"
    }
    if req.Header.Get("X-Callback-Token") != "" {
        return "xendit"
    }
    // Body sniff as fallback
    body, _ := io.ReadAll(req.Body)
    if bytes.Contains(body, []byte(`"transaction_id"`)) {
        return "midtrans"
    }
    if bytes.Contains(body, []byte(`"external_id"`)) {
        return "xendit"
    }
    return "unknown"
}
```

---

## 6. Idempotency at edge (mandatory)

Before processing, dedupe via `idempotency` table:

```sql
-- Pseudo-SQL inside ingest-api
INSERT INTO idempotency (key, endpoint, request_hash, processed_at)
VALUES ($1, $2, $3, NOW())
ON CONFLICT (key) DO NOTHING
RETURNING id;
```

- If row returned → first writer; proceed with processing.
- If no row → duplicate; return 200 OK with cached `response_body`.

**Why this is critical:** Midtrans retries up to 30 times if it gets non-2xx. Without idempotency, every retry = duplicate ledger entries = money lost.

---

## 7. Processing flow (after signature + idempotency pass)

```
ingest-api:webhook                                 saruman
        │                                              │
        │  parse body → detect event_type              │
        │                                              │
        │  event_type = topup.completed                │
        │ ────────────────────────────────────────────▶ │
        │   palantir.CreateTopUp                      │
        │                                              │
        │  event_type = topup.failed                  │
        │ ────────────────────────────────────────────▶ │
        │   (just update donation, no ledger entry)    │
        │                                              │
        │  event_type = refund.completed              │
        │ ────────────────────────────────────────────▶ │
        │   (update refund.status)                     │
```

Ingest-api calls saruman gRPC `SettleTopUp` (or similar). Saruman writes ledger + publishes `donation.charged.v1`.

---

## 8. Failure handling

| Provider status | Our response | Provider retry? |
|---|---|---|
| Valid webhook, processed | 200 OK | No |
| Invalid signature | 400 Bad Request | No (it's an attacker or misconfig) |
| Valid signature, internal error | 500 Internal Error | Yes (provider retries 30 times) |
| Duplicate (idempotency hit) | 200 OK | No (already processed) |
| Validation failed (malformed body) | 400 Bad Request | No |
| Provider down (unreachable to us) | n/a | Yes |

We MUST return 5xx for transient errors so providers back off and retry. We MUST return 4xx for permanent errors so they don't retry.

---

## 9. Schema versioning

When a provider changes their payload format:
1. Detect via `X-Provider-Version` header (if they send one) or version field in payload.
2. Map old shape → new shape inside `ingest-api`.
3. NEVER pass raw provider payload to saruman. Always normalize first.

---

## 10. Webhook URL conventions

```
https://ingest.inflora.app/v1/webhooks/payment
```

Single endpoint for all providers. Detection in `§5`.

We do NOT use per-provider URLs (e.g., `/v1/webhooks/midtrans`) because:
- Adding a new provider = code change in 1 place, not URL routing.
- Detection is robust via header sniffing.

---

## 11. Local dev: webhook tunneling

For testing real provider webhooks against localhost:

- `ngrok http 8080` (free, sufficient for dev)
- `cloudflared tunnel --url http://localhost:8080` (Cloudflare)
- Update provider dashboard with the tunnel URL.

For automated tests, use the Pivot stub — no real provider calls needed.

---

## 12. Audit trail

Every webhook received:
- INSERT into `webhook_events` (provider_name, provider_event_id, payload_hash, payload)
- This is independent of the idempotency check; both happen at edge.

```sql
INSERT INTO webhook_events (provider_name, provider_event_id, payload_hash, payload)
VALUES ($1, $2, $3, $4)
ON CONFLICT (provider_name, provider_event_id) DO NOTHING;
```

This gives us a full audit log of every webhook received, even if processing failed.

---

*Pin this file. Add new providers by appending a section. NEVER break the existing format.*