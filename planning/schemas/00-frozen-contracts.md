# 00 — Frozen Contracts (Track 0)

> **Status:** FROZEN. Breaking changes require a new major version (`v2`).
> **Effective from:** Day 1 of MVP sprint.
> **Reviewers:** Marvel + friend (both must ack).

These are the cross-cutting contracts every service must honor. Treat as source of truth.

---

## 1. Event envelope

Every event published to NATS MUST be JSON-encoded with this envelope:

```json
{
  "event_id":      "550e8400-e29b-41d4-a716-446655440000",
  "event_type":    "donation.charged.v1",
  "event_version": "1",
  "occurred_at":   "2026-10-02T14:30:00.123Z",
  "producer":      "saruman",
  "streamer_id":   "abc-123-def-456",
  "causation_id":  "...",
  "correlation_id":"...",
  "schema_url":    "https://inflora.app/schemas/donation.charged.v1.json",
  "payload":       { /* event-specific */ }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `event_id` | uuid-v4 | yes | Unique per producer. Idempotency key at the consumer. |
| `event_type` | string | yes | Format: `<domain>.<entity>.<verb>.<version>`. |
| `event_version` | int | yes | Stringified in JSON. Matches the version in topic. |
| `occurred_at` | RFC 3339 | yes | Producer-set. UTC, ms precision. |
| `producer` | string | yes | Service name: `ingest-api`, `saruman`, `palantir-gateway`, `tolkien`, `ithildin`. |
| `streamer_id` | uuid | yes (nullable for global events) | The streamer this event relates to. |
| `causation_id` | uuid | no | Parent event_id if this is a reaction. |
| `correlation_id` | uuid | no | Groups events from one logical transaction. |
| `schema_url` | URL | no | For runtime validation (deferred). |
| `payload` | object | yes | Event-specific. Never null, never array. |

**Producer ack rule:** `event_id` must be unique per producer. Use `gen_random_uuid()` or equivalent.

**Consumer ack rule:** de-dupe on `event_id`. At-least-once delivery × idempotent consumer = effective exactly-once.

---

## 2. Topic naming convention

`<domain>.<entity>.<verb>.<version>`

**Examples:**
- `donation.charged.v1`
- `donation.refunded.v1`
- `payout.requested.v1`
- `fraud.flagged.v1`

**NATS subject format:** `<topic>.<streamer_id>` — partitions by streamer.

```
donation.charged.v1.abc-123-def-456
donation.charged.v1.xyz-789-ghi-012
```

**Consumer subscriptions:**
- All events of type X: `donation.charged.v1.>`
- One streamer's events: `donation.charged.v1.<streamer_id>`

**Versioning rule:** bump version only on breaking changes. Adding optional fields = no bump.

---

## 3. Sequence numbering (overlay events)

Every frame sent to an OBS overlay WebSocket MUST carry a per-streamer monotonic `seq`:

```json
{
  "type": "donation",
  "seq": 43,
  "data": { ... }
}
```

| Field | Type | Notes |
|---|---|---|
| `seq` | int | Per-streamer. Starts at 1 on gateway boot. Increments by 1. |
| wrap | at `2^53 - 1` | Client should treat wrap-around as reconnect trigger. |

**Why:** client uses `seq` to detect missed events and request catch-up after reconnect. See `05-websocket-protocol.md` §7.

**Gateway invariant:** `seq` is monotonic per streamer across all clients (not per-connection). All OBS clients for streamer X see the same `seq` series.

---

## 4. Token formats

Two opaque token types. Never reverse-engineerable from the DB (we store hash only).

### 4.1 Session token (dashboard auth)

```
sk_<base64url(32 random bytes)>
```

- 256 bits of entropy
- Prefix `sk_` for sanity (grep, log scanning)
- Stored in `sessions.token_hash` as `bcrypt(token)`
- TTL: 30 days (sliding on use)

### 4.2 Overlay token (OBS browser source)

```
ok_<base64url(32 random bytes)>
```

- 256 bits of entropy
- Prefix `ok_` for sanity
- Stored in `sessions.token_hash` as `bcrypt(token)`
- TTL: 90 days (no sliding)
- Shown in dashboard as `<last4>` only (last 4 of base64url)
- Embedded in OBS browser source URL: `https://overlay.inflora.app/?token=ok_xxx`

### 4.3 Last4

Shown in UI for sanity (`"aB3X"`). Last 4 chars of the base64url portion, no prefix.

### 4.4 Token storage

```sql
-- sessions table (see 02-database-schema.sql)
token_hash VARCHAR(255) NOT NULL  -- bcrypt cost 12
```

`last4` stored separately for UI display without bcrypt roundtrip:

```sql
last4 CHAR(4) NOT NULL
```

### 4.5 Token validation endpoint

Internal only. Friend's WS gateway calls this on connect.

```
POST /v1/internal/validate-overlay-token
Authorization: Bearer <internal-api-key>
Body: { "token": "ok_xxx" }

200 OK: { "streamer_id": "abc-...", "expires_at": "..." }
401 Unauthorized: { "error": { "code": "INVALID_TOKEN" } }
```

Cache result for 60s in `tolkien` to avoid bcrypt per WS connect.

---

## 5. Idempotency key

Used at the webhook edge to dedupe retries.

### 5.1 Header form (for our internal POSTs)

```
Idempotency-Key: <uuid-v4>
```

### 5.2 Provider-derived form (for webhooks)

```
key = "<provider_name>:<provider_event_id>"
```

Examples:
- `midtrans:abc-123-def-456`
- `xendit:inv-98765`
- `pivot:stub-event-uuid`

### 5.3 Storage

```sql
CREATE TABLE idempotency (
  key VARCHAR(128) PRIMARY KEY,
  endpoint VARCHAR(80) NOT NULL,
  request_hash CHAR(64) NOT NULL,  -- sha256 hex of body
  response_status INT,
  response_body JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at TIMESTAMPTZ
);
```

### 5.4 Insert pattern

```sql
INSERT INTO idempotency (key, endpoint, request_hash)
VALUES ($1, $2, $3)
ON CONFLICT (key) DO NOTHING
RETURNING id;
```

- If `RETURNING` returns a row → first writer, proceed.
- If empty → duplicate, no-op. Return 200 OK with cached `response_body`.

---

## 6. Error response format (HTTP)

Every non-2xx HTTP response MUST return:

```json
{
  "error": {
    "code":       "STREAMER_NOT_FOUND",
    "message":    "Streamer abc-123 does not exist",
    "request_id": "550e8400-...",
    "details":    { "streamer_id": "abc-123" }
  }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `code` | enum | yes | One of §6.1 codes |
| `message` | string | yes | Human-readable, English |
| `request_id` | uuid | yes | Same as `X-Request-Id` header |
| `details` | object | no | Structured context |

### 6.1 Error codes (canonical)

| Code | HTTP | Notes |
|---|---|---|
| `VALIDATION_FAILED` | 400 | Generic validation failure |
| `STREAMER_NOT_FOUND` | 404 | |
| `INVALID_TOKEN` | 401 | Session/overlay token bad |
| `TOKEN_EXPIRED` | 401 | Token past expiry |
| `INSUFFICIENT_BALANCE` | 422 | Payout > pending |
| `INSUFFICIENT_AMOUNT` | 422 | Donation < min |
| `PROVIDER_ERROR` | 502 | Payment provider 5xx |
| `RATE_LIMITED` | 429 | |
| `IDEMPOTENCY_CONFLICT` | 409 | Same key, different body hash |
| `STREAMER_INACTIVE` | 403 | Account disabled |
| `INTERNAL` | 500 | Generic 500 |
| `SERVICE_UNAVAILABLE` | 503 | Overloaded |

Add new codes here, in the schema. Never invent at the call site.

### 6.2 HTTP status mapping

| Status | Meaning |
|---|---|
| 200 | OK |
| 201 | Created |
| 204 | No Content |
| 400 | Bad request (validation) |
| 401 | Unauthorized (no/bad token) |
| 403 | Forbidden (token valid, not allowed) |
| 404 | Not found |
| 409 | Conflict (idempotency, state machine) |
| 422 | Unprocessable entity (semantic) |
| 429 | Too many requests |
| 500 | Internal error |
| 502 | Bad gateway (provider failed) |
| 503 | Service unavailable |

---

## 7. Pagination

Cursor-based. Required for any list endpoint returning > 20 items.

```
GET /v1/me/donations?limit=20&cursor=<opaque>
```

Response:

```json
{
  "data": [ { ... }, { ... } ],
  "pagination": {
    "next_cursor": "eyJpZCI6IjEz...",
    "has_more": true
  }
}
```

| Field | Type | Notes |
|---|---|---|
| `limit` | int | Default 20, max 100, min 1 |
| `cursor` | string | Opaque (base64url of `{id, sort_key}`) |
| `next_cursor` | string | null if no more |
| `has_more` | bool | Computed; redundant with `next_cursor != null` |

**Sort:** `created_at DESC, id DESC` for stable cursor (tie-break on id).

---

## 8. Standard HTTP headers

### 8.1 Request headers

| Header | Required | Notes |
|---|---|---|
| `Authorization: Bearer <token>` | where applicable | Session or overlay token |
| `Idempotency-Key: <uuid>` | webhook ingest | Always |
| `X-Request-Id: <uuid>` | recommended | Propagated for tracing |
| `Content-Type: application/json; charset=utf-8>` | when body | |
| `User-Agent` | optional | Logged in audit_log |
| `Accept-Language` | optional | Future i18n |

### 8.2 Response headers

| Header | Always | Notes |
|---|---|---|
| `X-Request-Id: <uuid>` | yes | Same as request, generated if missing |
| `Content-Type: application/json; charset=utf-8` | yes | |
| `Cache-Control: no-store` | auth endpoints | Prevent caching of sensitive data |
| `X-RateLimit-Remaining: <int>` | rate-limited endpoints | |

---

## 10. Logging format (all services)

```json
{
  "ts":        "2026-10-02T14:30:00.123Z",
  "level":     "info",
  "service":   "saruman",
  "request_id":"550e8400-...",
  "streamer_id":"abc-123",   // if available
  "msg":       "donation settled",
  "fields":    { "donation_id":"...", "amount_idr": 50000 }
}
```

**Required fields:**
- `ts` (RFC 3339, UTC, ms)
- `level` (debug/info/warn/error)
- `service` (the producing service)
- `msg` (event description, lowercase, present tense)

**Sensitive data:** never log raw tokens, passwords, bank account numbers, full card numbers. Use `last4` or `***`.

---

## 11. Money representation

**Unit:** IDR minor units (rupiah, no decimals). Use `BIGINT`.

```sql
amount_idr BIGINT NOT NULL  -- e.g., 50000 = Rp 50.000
```

**Why:** floating-point is forbidden for money. Integer minor units = exact.

**Conversions to user-facing:**
- `display = amount_idr / 1000` then format with thousands separator: `"50.000"` (Indonesian locale).
- For MVP: just show the integer with a `.` every 3 digits from the right.

**Platform fee:** `platform_fee_bps = 1` = 1 basis point = 0.01% (per MVP decision; Inflora charge is on top of provider fee).

**No decimals ever.** Rp 50,5 doesn't exist.

---

## 12. Time representation

**Format:** RFC 3339 UTC, ms precision.

```
"2026-10-02T14:30:00.123Z"
```

**Storage:** `TIMESTAMPTZ` in PostgreSQL. Always UTC.

**API:** strings in JSON. Never unix timestamps in user-facing APIs (allow for `X-*` internal headers if useful).

**Latency budget measured:** client → server → response. See `08-flow-diagrams.md` §Flow 1.

---

## 13. UUIDs

- Version: v4 (random)
- Encoding: lowercase hex with dashes
- Always 36 chars
- Examples: `550e8400-e29b-41d4-a716-446655440000`

Generation:
- PostgreSQL: `gen_random_uuid()` (requires extension `pgcrypto`)
- Go: `crypto/rand` + manual formatting, or `github.com/google/uuid`
- Never use `auto_increment` for IDs exposed externally (info leak).

---

*End of frozen contracts. Pin this file in repo, link from README. Breaking changes require `v2`.*