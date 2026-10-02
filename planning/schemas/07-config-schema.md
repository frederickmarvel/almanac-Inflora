# 07 — Config Schema (Per-Service Env Vars)

> **MVP simplification:** use environment variables. Defer the One Ring centralized config service.
> This file documents the convention so it can be promoted later.

---

## 1. Required env vars (every service)

| Variable | Type | Default | Notes |
|---|---|---|---|
| `ENV` | enum | `dev` | `dev`, `staging`, `prod` |
| `SERVICE_NAME` | string | required | `ingest-api`, `saruman`, `palantir-gateway`, `tolkien`, `ithildin` |
| `LOG_LEVEL` | enum | `info` | `debug`, `info`, `warn`, `error` |
| `LOG_FORMAT` | enum | `json` | `json` (prod), `text` (dev) |
| `HTTP_ADDR` | string | per-service | `:8080`, `:8081`, etc. |
| `VERSION` | string | git sha | For `X-Service-Version` header |

---

## 2. Database (saruman, tolkien, ithildin)

| Variable | Type | Notes |
|---|---|---|
| `DB_DRIVER` | enum | `postgres`, `mysql` (postgres in MVP) |
| `DB_DSN` | string | Full DSN, e.g., `postgres://user:pass@host:5432/inflora?sslmode=require` |
| `DB_MAX_OPEN_CONNS` | int | Default 50 |
| `DB_MAX_IDLE_CONNS` | int | Default 10 |
| `DB_CONN_MAX_LIFETIME_SEC` | int | Default 300 |
| `DB_SLOW_QUERY_THRESHOLD_MS` | int | Default 200; logs queries above this |

---

## 3. NATS (saruman, palantir-gateway, ithildin for replay)

| Variable | Type | Notes |
|---|---|---|
| `NATS_URL` | string | `nats://localhost:4222` |
| `NATS_STREAM_NAME` | string | `inflora-events` |
| `NATS_CONSUMER_GROUP` | string | Per-service, e.g., `saruman-donation-aggregator` |
| `NATS_ACK_WAIT_SEC` | int | Default 30 |
| `NATS_MAX_DELIVER` | int | Default 5 |
| `NATS_MAX_ACK_PENDING` | int | Default 1000; backpressure threshold |

---

## 4. Auth (tolkien)

| Variable | Type | Notes |
|---|---|---|
| `SESSION_TTL_HOURS` | int | Default 720 (30 days) |
| `OVERLAY_TOKEN_TTL_HOURS` | int | Default 2160 (90 days) |
| `BCRYPT_COST` | int | Default 12; min 10 |
| `ARGON2_MEMORY_KB` | int | Default 65536 (64 MB) |
| `ARGON2_TIME` | int | Default 3 |
| `ARGON2_THREADS` | int | Default 1 |
| `LOGIN_RATE_LIMIT_PER_MIN` | int | Default 5 |
| `LOGIN_LOCKOUT_THRESHOLD` | int | Default 3 failures → 1/hr lockout |

---

## 5. Payment provider (saruman, palantir-gateway)

| Variable | Type | Notes |
|---|---|---|
| `PAYMENT_PROVIDER` | enum | `midtrans`, `xendit`, `pivot` |
| `PLATFORM_FEE_BPS` | int | Default 1 (0.01%); basis points |
| `MIN_DONATION_IDR` | int | Default 1000 |
| `MAX_DONATION_IDR` | int | Default 10_000_000 |
| `INTENT_TTL_MINUTES` | int | Default 15 |

### Midtrans-specific

| Variable | Type |
|---|---|
| `MIDTRANS_SERVER_KEY` | string (secret) |
| `MIDTRANS_CLIENT_KEY` | string |
| `MIDTRANS_ENV` | enum: `sandbox`, `production` |
| `MIDTRANS_WEBHOOK_URL` | URL (where Midtrans posts) |

### Xendit-specific

| Variable | Type |
|---|---|
| `XENDIT_SECRET_KEY` | string (secret) |
| `XENDIT_PUBLIC_KEY` | string |
| `XENDIT_WEBHOOK_TOKEN` | string (shared secret) |

---

## 6. Saruman → Palantir gRPC

| Variable | Type | Notes |
|---|---|---|
| `SM_GATEWAY_ADDR` | string | `localhost:7001` (dev) / `palantir-gateway:7001` (k8s) |
| `SM_GATEWAY_ENGINE_API_KEY` | string | Shared secret |
| `SM_GRPC_TIMEOUT_SEC` | int | Default 5 |

---

## 7. Encryption

| Variable | Type | Notes |
|---|---|---|
| `AEAD_KEY_HEX` | 64 hex chars | 32-byte key for AES-256-GCM. Used for bank account refs. |
| `RATE_LIMITER_KEY` | string | For distributed rate limiting (Redis key prefix) |

---

## 8. Rate limiting (per-endpoint)

| Endpoint | Default limit |
|---|---|
| `POST /v1/auth/signup` | 5/min/IP |
| `POST /v1/auth/login` | 5/min/IP (lockout after 3 fails) |
| `POST /v1/donations` | 10/min/IP, 100/hour/IP |
| `POST /v1/webhooks/payment` | 1000/min/IP (effectively unlimited) |
| WS connect | 10/min/IP, 100 concurrent/streamer |

All limits are configurable via env:

```
RATE_LIMIT_DONATION_PER_MIN=10
RATE_LIMIT_DONATION_PER_HOUR=100
RATE_LIMIT_SIGNUP_PER_MIN=5
```

---

## 9. Reconciliation

| Variable | Type | Default |
|---|---|---|
| `RECONCILIATION_ENABLED` | bool | true |
| `RECONCILIATION_CRON` | string | `0 0 * * *` (daily 00:00 UTC) |
| `RECONCILIATION_DRIFT_THRESHOLD_IDR` | int | bigint | 1000 |
| `RECONCILIATION_ALERT_WEBHOOK` | URL | optional (Slack/Discord webhook) |

---

## 10. Observability

| Variable | Type | Notes |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | URL | OpenTelemetry collector |
| `OTEL_SERVICE_NAME` | string | Same as `SERVICE_NAME` |
| `OTEL_TRACES_SAMPLER` | enum | `parentbased_traceidratio`, `always_on`, `always_off` |
| `OTEL_TRACES_SAMPLER_ARG` | float | 0.1 = 10% sampling |

---

## 11. WebSocket gateway (friend's service)

| Variable | Type | Default |
|---|---|---|
| `WS_ADDR` | string | `:8081` |
| `WS_PATH` | string | `/ws` |
| `WS_HEARTBEAT_INTERVAL_SEC` | 10 |
| `WS_HEARTBEAT_TIMEOUT_SEC` | 30 |
| `WS_MAX_CONNECTIONS_PER_STREAMER` | 100 |
| `WS_REPLAY_WINDOW_SEC` | 600 |
| `WS_AUTH_CACHE_TTL_SEC` | 60 |
| `TOLKIEN_VALIDATE_TOKEN_URL` | URL | `http://tolkien:8080/v1/internal/validate-overlay-token` |
| `INTERNAL_API_KEY` | string | Shared with tolkien |

---

## 12. Example `.env.example` for saruman

```bash
# Identity
ENV=dev
SERVICE_NAME=saruman
VERSION=0.1.0-dev
LOG_LEVEL=debug
LOG_FORMAT=text

# Bind
HTTP_ADDR=:8082

# DB
DB_DRIVER=postgres
DB_DSN=postgres://inflora:dev@localhost:5432/inflora?sslmode=disable
DB_MAX_OPEN_CONNS=50

# NATS
NATS_URL=nats://localhost:4222
NATS_STREAM_NAME=inflora-events
NATS_CONSUMER_GROUP=saruman
NATS_MAX_ACK_PENDING=1000

# Provider
PAYMENT_PROVIDER=midtrans
PLATFORM_FEE_BPS=1
MIN_DONATION_IDR=1000
MAX_DONATION_IDR=10000000
INTENT_TTL_MINUTES=15

# Saruman → Palantir
SM_GATEWAY_ADDR=localhost:7001
SM_GATEWAY_ENGINE_API_KEY=dev-engine-api-key
SM_GRPC_TIMEOUT_SEC=5

# Encryption
AEAD_KEY_HEX=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f

# Reconciliation
RECONCILIATION_ENABLED=true
RECONCILIATION_CRON=0 0 * * *
RECONCILIATION_DRIFT_THRESHOLD_IDR=1000

# Rate limits
RATE_LIMIT_DONATION_PER_MIN=10
RATE_LIMIT_DONATION_PER_HOUR=100

# Observability
OTEL_EXPORTER_OTLP_ENDPOINT=localhost:4317
OTEL_SERVICE_NAME=saruman
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=1.0
```

---

## 13. Future: One Ring centralized config

When we have > 3 flags or per-stage overrides, switch to One Ring service:

```typescript
// One Ring config service API
GET /v1/config/:service_name
Authorization: Bearer <service-token>

Response:
{
  "service": "saruman",
  "config": {
    "palantir.provider": "midtrans",
    "palantir.api_key": "decrypted-secret",
    "mvp.show_ads": false,
    "mvp.max_donation_per_card_per_day": 500000
  },
  "version": "42",
  "fetched_at": "..."
}
```

Clients poll every 30s for hot-reload. Secrets are decrypted only by the service that owns them.

Migration path:
1. Stage 1 (MVP): env vars only. ← WE ARE HERE
2. Stage 2: One Ring service, env vars as fallback.
3. Stage 3: One Ring is the only source of truth.

---

## 14. Change process

1. Add variable to this file.
2. Update service code to read it.
3. Update `.env.example` in the service repo.
5. If breaking (rename/remove), bump service version.

---

*Pin this file. Service-specific config sections live in each service's `.env.example`.*