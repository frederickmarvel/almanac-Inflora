# Wire Guide — Inflora Microservices

> **Guidance**
> - **Use this when:** designing service-to-service interactions, debugging cross-service issues, onboarding new engineers, or asking an AI to add a new connection.
> - **Audience:**all engineers, AI assistants.
> - **Read first, before:** any code PR that touches inter-service communication.
> - **Related:** `README.md` (planning index), `AI_BACKEND_COMPLETION_PLAN.md`
>   (broad execution sequence), `MANUAL_SETTLEMENT_WITHDRAWALS_PLAN.md` (focused
>   manual settlement/withdrawal scope), `schemas/` (contracts), and
>   `../ops/RUNBOOK.md` (ops).

This is the **single source of truth for service-to-service wiring** in Inflora's new polyrepo architecture. **Never invent connections** not in this guide. If a new connection is needed, edit this file first, then update code.

---

## 1. Service Registry (single source of truth)

| Service | Repo | HTTP port | gRPC port | WS port | Process model | Owner |
|---|---|---|---|---|---|---|
| **tolkien** | `frederickmarvel/inflora-tolkien` | `8080` | — | — | stateless, 1+ replicas | Marvel |
| **ingest** | `frederickmarvel/inflora-ingest` | `8081` | — | — | stateless, 1+ replicas | Marvel |
| **palantir** | `frederickmarvel/inflora-palantir` | — | `7001` | — | stateless, 1+ replicas | Marvel |
| **saruman** | `frederickmarvel/inflora-saruman` | `8082` | `7002` | — | stateless, 1+ replicas | Marvel |
| **ws-gateway** | `frederickmarvel/inflora-ws-gateway` | `8083` | — | `8083/ws` | stateful (per-streamer hubs), 1+ replicas | friend |
| **shared** | `frederickmarvel/inflora-shared` | — | — | — | Go library (not deployed) | both |

**Critical: ports above are the canonical assignments.** Do not use other ports.
If a port must change, update this table, the affected config contract, and the
applicable current execution plan from [`README.md`](README.md).

---

## 2. Wire Map (ASCII)

```
                    ┌──────────────────────────────────────────────────────────────┐
                    │                  External                                    │
                    │                                                              │
                    │      ┌─────────────────┐         ┌─────────────────┐         │
                    │      │  Browser Donor  │         │  Browser Dashbd │         │
                    │      │  /d/<streamer>  │         │  app.inflora    │         │
                    │      └────────┬────────┘         └────────┬────────┘         │
                    │               │                           │                  │
                    └───────────────┼───────────────────────────┼──────────────────┘
                                    │ HTTPS                     │ HTTPS
                                    ▼                           ▼
┌────────────────────────────────────────────────────────────────────────────────────┐
│                         inflora microservices                                       │
│                                                                                    │
│   ┌─────────────────┐                                                              │
│   │ ingest          │   POST /v1/webhooks/payment  ◀──── Midtrans webhooks        │
│   │ :8081 HTTP      │       │ (HTTP edge only — NO DB writes; D-002/D-003)         │
│   └────────┬────────┘       │ gRPC SettleTopUp → palantir                           │
│            │                ▼                                                       │
│            │         ┌──────────────────┐                                            │
│            └────────▶│ saruman           │      ┌─────────────────┐                │
│            gRPC       │ gRPC :7002        │      │ palantir         │                │
│   CreateTopUp         │ HTTP :8082 admin  │◀────▶│ gRPC :7001       │                │
│            │         │ NATS pub + sub    │ gRPC │ TopUp/Withdrawal/│───────────────▶│
│            ▼         └──┬───────────────┘       │ Refund services  │ HTTPS         │
│   ┌─────────────────┐   │                       └─────────────────┘             ▼
│   │ palantir        │   │                                                 ┌──────────────┐
│   │ gRPC :7001      │   │ NATS publish                                    │ Midtrans SNAP │
│   └────────┬────────┘   │ donation.charged.v1.<streamer_id>              │ Pivot (stub)  │
│            │ HTTPS      ▼                                                 └──────────────┘
│            ▼      ┌──────────────────────────────────────┐
│   ┌─────────────────┐  │ NATS JetStream :4222            │                  ▲
│   │ Midtrans        │  └──────────────────────────────────────┘                  │
│   └─────────────────┘           │           │       │                              │ HTTPS
│                                  │           │       │ HTTPS webhook               │
│                                  ▼           ▼       └──────────────────────────────┘
│                          ┌────────────────────┐
│                          │ ws-gateway         │      ┌──────────────────────┐
│                          │ :8083 HTTP + WS    │◀─────│ OBS Browser Source   │
│                          │ NATS subscribe     │      │ overlay.inflora.app  │
│                          └─────────┬──────────┘      │ wss://?token=ok_xxx  │
│                                    │                  └──────────────────────┘
│                                    │ HTTPS (token validation, cached 60s)
│                                    ▼
│                          ┌────────────────────┐
│                          │ tolkien            │
│                          │ :8080 HTTP         │◀────── Browser Dashboard
│                          │ streamer/admin API │
│                          └────────────────────┘
│                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       │ All services share single DB
                                       ▼
                          ┌────────────────────────────────┐
│                          │ PostgreSQL 15+ DB `inflora`   │
                          │ owner: saruman (migrations)  │
                          └────────────────────────────────┘
```

---

## 3. Event Topic Ownership

Every event published to NATS has exactly **one producer**. Consumers may be multiple. See `planning/schemas/01-event-catalog.md` for payload schemas.

| Topic | Producer | Subscribers | Purpose |
|---|---|---|---|
| `donation.intent.created.v1` | **ingest** | saruman | Donor submits form; saruman provisions ledger accounts |
| `donation.charged.v1` | **saruman** | ws-gateway, analytics | Provider captured (CHARGED); STREAMER_PENDING increases; OBS alert fired. Emitted in same TX as the capture-side ledger entries. `settlement_status=PENDING`. |
| `donation.settled.v1` | **saruman** | ws-gateway (optional toast), analytics | Provider settled (Settled); PENDING→AVAILABLE move; emitted in same TX as the new ledger entries. `settlement_status=SETTLED`. |
| `donation.failed.v1` | **saruman** | ws-gateway (skip), analytics | Capture failed; donation goes FAILED; outbox emits in same TX as the donation row update. |
| `pg.gateway.topup.completed.v1` | **palantir** | saruman | Palantir wrote `gateway_topups` and the corresponding `webhook_events` row, then committed. Frozen payload in `schemas/09-internal-provider-events.md`. |
| `pg.gateway.topup.failed.v1` | **palantir** | saruman | Palantir transitioned the gateway top-up to a failed/expired/cancelled state and recorded `webhook_events`. |
| `pg.gateway.topup.expired.v1` | **palantir** | saruman | Gateway top-up expired without capture (e.g. donor abandoned QRIS). |
| `pg.gateway.withdrawal.completed.v1` | **palantir** | saruman | Withdrawal settled at bank. |
| `pg.gateway.withdrawal.failed.v1` | **palantir** | saruman | Bank rejected / returned. |
| `pg.gateway.refund.completed.v1` | **palantir** | saruman | Refund settled. |
| `pg.gateway.refund.failed.v1` | **palantir** | saruman | Refund rejected / not settled. |
| `donation.refunded.v1` | **saruman** | analytics | Refund completed |
| `donation.receipt_sent.v1` | **saruman** | analytics | Donor receipt email sent |
| `payout.requested.v1` | **tolkien** | palantir, saruman | Streamer requests payout |
| `payout.batched.v1` | **tolkien** | saruman, palantir, analytics | FinOps creates batch |
| `payout.settled.v1` | **palantir** | saruman, analytics | Bank settled |
| `payout.failed.v1` | **palantir** | saruman | Bank rejected |
| `payout.batch.executed.v1` | **tolkien** | saruman, palantir, analytics | FinOps runs bulk transfer |
| `payout.batch.completed.v1` | **palantir** | saruman, analytics | All payouts in batch settled |
| `payout.batch.failed.v1` | **palantir** | saruman, analytics | Bulk batch failed |
| `streamer.registered.v1` | **tolkien** | saruman, palantir | New streamer |
| `streamer.settings.updated.v1` | **tolkien** | saruman (cache), ws-gateway | Settings changed |
| `overlay.token.rotated.v1` | **tolkien** | saruman (cache invalidation), audit | Token rotated |
| `fund_hold.created.v1` | **tolkien** | saruman (cache + reject payouts) | Investigation started |
| `fund_hold.released.v1` | **tolkien** | saruman | Investigation cleared |
| `fraud.flagged.v1` | **saruman** | ops dashboard | Inline velocity rule tripped |

**Naming rule:** `<domain>.<entity>.<verb>.<version>`. Subjectformat on NATS: `<topic>.<streamer_id>`. See `00-frozen-contracts.md §2`.

**Critical:** if you need to publish from a service that is NOT the listed producer, **this is a bug**. Find a way to make the canonical producer publish.

---

## 4. gRPC Matrix (every RPC must be in this table)

| Caller | Callee | RPC | Schema reference |
|---|---|---|---|
| **ingest** | palantir | `CreateTopUp` | `schemas/04-grpc-proto.md §topup.proto` |
| **ingest** | palantir | `SettleTopUp` | `schemas/04-grpc-proto.md §topup.proto` |
| **saruman** | palantir | `CreateWithdrawal` | `schemas/04-grpc-proto.md §withdrawal.proto` |
| **saruman** | palantir | `SettleWithdrawal` | `schemas/04-grpc-proto.md §withdrawal.proto` |
| **saruman** | palantir | `CreateRefund` | `schemas/04-grpc-proto.md §refund.proto` |
| palantir | saruman | (none — async via NATS) | n/a |
| ingest | saruman | (none — async via NATS; ingest publishes intent event, saruman provisions) | n/a |

**Critical:** gRPC is for synchronous command/response only ("do this now, return result"). For async fire-and-forget, use **NATS**. Do not invent new gRPC methods; Service-to-service is async.

**Auth:** every gRPC call carries header `authorization: Bearer <engine-api-key>`. Validate against `SM_GATEWAY_ENGINE_API_KEY` env var (both caller and callee read same key).

---

## 5. HTTP Matrix (every internal HTTP call must be in this table)

Internal HTTP is for service-to-service calls that are NOT in the gRPC matrix and NOT async.External HTTP (public donor, dashboard) goes to ingest/tolkien public endpoints, listed in `schemas/03-http-api.md`.

| Caller | Callee | Method + Path | Purpose | Cache |
|---|---|---|---|---|
| **ws-gateway** | tolkien | `POST /v1/internal/validate-overlay-token` | Token validation on WS connect | 60s in-memory |
| **saruman** | tolkien | `POST /v1/internal/send-receipt` | Email receipt trigger | none |
| **saruman** | tolkien | `POST /v1/internal/rotate-overlay-token-invalidate` | Cache invalidation on token rotation | none |

**Auth:** every internal HTTP call carries header `X-Internal-Api-Key`. Validate against `INTERNAL_API_KEY` env var on callee.

**Timeout:** every internal HTTP call has 5s timeout default, configurable via `INTERNAL_HTTP_TIMEOUT_MS`.

---

## 6. Database Ownership (per-table writer matrix)

**All services share one PostgreSQL 15+ database `inflora`.** But **only one service WRITES each table** to avoid race conditions.

| Table | OWNER (INSERTs) | WRITERS (UPDATEs) | READERS | Migration runner |
|---|---|---|---|---|
| `streamers` | tolkien | tolkien (login_at, etc.) | ingest (validation), palantir (account lookup), ws-gateway (token validate, cached) | saruman |
| `sessions` | tolkien | tolkien (rotate, revoke) | ws-gateway (via tolkien HTTP), tolkien itself | saruman |
| `streamer_settings` | tolkien | tolkien | saruman (read for new donations), ws-gateway (cache) | saruman |
| `streamer_bank_accounts` | tolkien | tolkien | saruman (read for payout creation) | saruman |
| `idempotency` | ingest | ingest | ingest (read for retry), saruman (read for debugging) | saruman |
| `webhook_events` | **palantir only** | **palantir only** | (audit only) | palantir |
| `donations` | ingest (INSERT INTENT_CREATED) | saruman (state transitions only) | tolkien (read for /v1/me/donations), palantir (read for settle), ws-gateway (no read) | saruman |
| `ledger_entries` | **saruman ONLY** | (append-only — NEVER UPDATE/DELETE) | saruman (recon), tolkien (audit) | saruman |
| `ledger_accounts` | saruman (auto-create on streamer.registered) | saruman (balance update + version increment) | saruman, tolkien (read for balance view) | service-to-service |
| `refunds` | saruman (HTTP facade: tolkien calls Saruman command — D-005) | **saruman only** (status transitions, ledger compensation) | tolkien (audit) | saruman |
| `payouts` | tolkien (INSERT REQUESTED, via authenticated Saruman command — see D-004) | **saruman only** (status transitions, balance reservation, ledger) | tolkien (read for /v1/me/payouts), saruman | saruman |
| `payout_batches` | tolkien | tolkien, saruman, palantir | saruman | saruman |
| `fund_holds` | tolkien | tolkien | saruman (read for payout validation) | saruman |
| `email_receipts` | saruman | saruman | saruman | saruman |
| `mdr_rates` | (read-only at MVP) | (admin edits Phase 2) | ingest (read), saruman (audit) | saruman |
| `fraud_events` | saruman | saruman | (audit) | saruman |
| `audit_log` | every service (every privileged action) | (append-only) | (audit) | saruman |
| `reconciliation_drift` | saruman | saruman | (audit) | saruman |
| `gateway_topups` | palantir | palantir | saruman (correlate) | palantir |
| `gateway_withdrawals` | palantir | palantir | saruman (correlate) | palantir |
| `gateway_refunds` | palantir | palantir | saruman (correlate) | palantir |

**Critical:** if a service needs to write a table not in its OWNER/WRITERS row, **this is a bug**. Refactor: either move the write to the canonical writer, or add a new service-to-service call (HTTP, gRPC, or NATS).

**All services use a SINGLE database migration runner** (saruman's `cmd/migrate`
runs migrations against the shared schema). See
[`AI_BACKEND_COMPLETION_PLAN.md`](AI_BACKEND_COMPLETION_PLAN.md) and
[`schemas/02-database-schema.sql`](schemas/02-database-schema.sql) for current
implementation and ownership details.

---

## 7. Per-Repo File Layout (template)

Every service repo follows this layout. The repository skeletons already exist;
use the applicable incomplete phase in
[`AI_BACKEND_COMPLETION_PLAN.md`](AI_BACKEND_COMPLETION_PLAN.md) for new work.

```
inflora-<service>/
├── README.md                       # service overview, run instructions
├── ARCHITECTURE.md                 # service-internal design
├── CHANGELOG.md                    # version history
├── Makefile                        # make build, make test, make run, make lint
├── Dockerfile                      # multi-stage build
├── go.mod                          # module github.com/frederickmarvel/inflora-<service>
├── go.sum
├── .golangci.yml                   # linter config (matches workspace)
├── .gitignore
├── .dockerignore
├── .github/
│   └── workflows/
│       └── ci.yml                  # lint + test + build on PR
├── cmd/
│   ├── server/
│   │   └── main.go                 # HTTP/gRPC server boot
│   └── migrate/                    # (only saruman)
│       └── main.go
├── internal/
│   ├── config/
│   │   └── config.go               # env var loader (uses pkg/config)
│   ├── handler/                    # HTTP/gRPC handlers (one file per resource)
│   │   ├── auth.go                 # (tolkien only)
│   │   ├── me.go
│   │   ├── settings.go
│   │   ├── bank_accounts.go
│   │   ├── admin_holds.go
│   │   ├── admin_batches.go
│   │   ├── donations.go            # (ingest only)
│   │   ├── webhook.go
│   │   ├── donor_page.go           # (ingest only)
│   │   ├── health.go
│   │   └── ...
│   ├── middleware/
│   │   ├── auth.go
│   │   ├── request_id.go
│   │   ├── logging.go
│   │   ├── recovery.go
│   │   └── rate_limit.go
│   ├── repo/                       # SQL queries (one file per table)
│   │   ├── streamers.go
│   │   ├── sessions.go
│   │   ├── donations.go
│   │   └── ...
│   ├── service/                    # business logic (orchestrates repos + events)
│   │   ├── donation.go
│   │   ├── payout.go
│   │   ├── hold_check.go
│   │   └── ...
│   ├── ledger/                     # (saruman only) double-entry helpers
│   ├── provider/
│   │   ├── midtrans/               # (palantir only)
│   │   └── pivot/                  # (palantir only, stub for dev)
│   ├── auth/                       # token validation helpers (uses pkg/auth)
│   ├── events/                     # NATS publisher/subscriber wrappers
│   ├── cache/                      # in-memory caches (token validation, etc.)
│   ├── audit/                      # audit_log helper
│   ├── cron/                       # scheduled jobs (saruman: recon, expire holds, etc.)
│   ├── ws/                         # (ws-gateway only) hub + connection
│   ├── subscriber/                 # NATS consumer (saruman, ws-gateway)
│   └── testutil/                   # test helpers (ephemeral DB, mock NATS, etc.)
└── migrations/                     # (saruman only)
    ├── embed.go
    ├── 00001_init.up.sql
    ├── 00001_init.down.sql
    ├── 00002_seed_dev.up.sql
    └── 00002_seed_dev.down.sql
```

**Convention:** every repo imports `github.com/frederickmarvel/inflora-shared` for proto defs, event types, auth helpers, observability, db pool, ledger helpers, provider interface, config loader.**No service-to-service imports.**

---

## 8. Service Responsibilities (one paragraph each)

### 8.1 tolkien — `inflora-tolkien`
Streamer-facing and admin HTTP API. Owns: streamers, sessions, streamer_settings, streamer_bank_accounts, payout_batches, fund_holds. Exposes signup/login/logout, /v1/me/*, /v1/admin/*, /v1/internal/validate-overlay-token, /v1/internal/send-receipt. Publishes: streamer.registered.v1, streamer.settings.updated.v1, overlay.token.rotated.v1, fund_hold.created.v1, fund_hold.released.v1, payout.batched.v1, payout.batch.executed.v1. Reads donations table for /v1/me/donations; reads ledger via view v_streamer_balances. Single source of truth for streamer identity and admin/finops actions. **Payout and refund HTTP are facades only (D-006); all financial state mutations happen in Saruman.**

### 8.2 ingest — `inflora-ingest`
Public-facing HTTP API + webhook edge. Owns: idempotency, donations (INSERT INTENT_CREATED only). Exposes /d/:streamer_id (donor landing page), POST /v1/donations, POST /v1/webhooks/payment. **Does NOT verify provider signatures or write `webhook_events`** (D-002, D-003). On webhook receipt, forwards the raw body to Palantir's `SettleTopUp` gRPC and returns the provider-compatible response. Computes MDR locally (configurable per payment_method), dedupes its own HTTP idempotency, calls Palantir `CreateTopUp` gRPC for payment URL, publishes `donation.intent.created.v1` in the same DB transaction as the donation row insert. NO ledger writes. NO streamer management. NO `webhook_events` writes. NO financial state mutations beyond INTENT_CREATED.

### 8.3 palantir — `frederickmarvel/inflora-palantir`
Payment provider broker (gRPC). Owns: gateway_topups, gateway_withdrawals, gateway_refunds, **webhook_events (sole writer, D-002)**. Exposes gRPC TopUpService, WithdrawalService, RefundService, HealthService. Implements provider interface: **midtrans/snap (production MVP), pivot/stub (local dev only)**. Xendit is deferred (D-016) and MUST NOT be added at MVP. Publishes: `pg.gateway.topup.completed.v1`, `pg.gateway.topup.failed.v1`, `pg.gateway.topup.expired.v1`, `pg.gateway.withdrawal.completed.v1`, `pg.gateway.withdrawal.failed.v1`, `pg.gateway.refund.completed.v1`, `pg.gateway.refund.failed.v1` via the transactional outbox (Phase 1 schema, Phase 2 dispatcher). NO ledger writes. NO streamer management. NO donation state transitions.

### 8.4 saruman — `inflora-saruman`
Donation engine + ledger. Owns: donations (state transitions), ledger_entries (APPEND-ONLY, NEVER UPDATE/DELETE), ledger_accounts, refunds (state transitions), payouts (state transitions, atomic balance reservation — D-004), email_receipts, mdr_rates, fraud_events, audit_log (co-owned with all), reconciliation_drift. Runs the single migration runner. **Does NOT expose gRPC `SettleDonation`** (D-001); settlement happens by Palantir `SettleTopUp` → `pg.gateway.*` event → Saruman durable consumer_inbox. Exposes HTTP `/v1/admin/donations/:id/refund`, `/v1/admin/streamers/:id/drain`, `/v1/admin/streamers/:id/rotate-token` (auth facade only) and the Saruman command surface for payout/refund that tolkien calls. Subscribes to all `pg.gateway.*` events via durable consumer_inbox (Phase 2). Publishes: donation.charged.v1, donation.settled.v1, donation.failed.v1, donation.refunded.v1, donation.receipt_sent.v1, fraud.flagged.v1, payout.settled.v1, payout.failed.v1, payout.batch.completed.v1, payout.batch.failed.v1. Owns reconciliation cron + hold expiry + intent expiry.

### 8.5 ws-gateway — `frederickmarvel/inflora-ws-gateway` (friend's main work)
OBS overlay WebSocket gateway. Owns: **ws_projection_sequences, ws_projection_frames, ws_projection_inbox** (Phase 1 schema; D-015). Exposes HTTP `/ws` (WebSocket upgrade) + `/healthz` + `/metrics`. Validates overlay token via tolkien HTTP (cached 60s; `X-Internal-Api-Key`, NOT `Authorization: Bearer` — D-010). Subscribes to `donation.charged.v1` (always) and `donation.settled.v1` (when `streamer_settings.notify_on_donation=true`). Per-streamer hub: `map[streamerID]*Hub` with `sync.RWMutex` per hub. **Sequence allocation and replay are durable in PostgreSQL** (D-015), so two replicas see the same `(streamer_id, seq)` history and a replica restart does not reset `seq`. Reconnect: exponential backoff with jitter (200ms → 30s). Replay: client sends `?since=<seq>`, replays from `last_seq+1`, sends `system.resync_required` when the requested `seq` is too old or the gap exceeds the retention window. Heartbeat every 10s; silent >30s → close 4408.

### 8.6 shared — `inflora-shared` (Go library, not deployed)
Shared types and helpers.Contains: proto definitions (generated Go code), event Go structs (matching almanac 01-event-catalog), auth helpers (token gen/validate, password hash), observability (logger, tracer, metrics), db pool, ledger double-entry helpers, provider interface, config loader, middleware. Imported by all 5 services as`github.com/frederickmarvel/inflora-shared`. Versioned: v0.1.0, v0.2.0, etc.

---

## 9. Configuration Matrix (env vars per service)

Every service reads from env. Service-specific values differ; common values same. Use `pkg/config` (from shared). See `schemas/07-config-schema.md` for detailed list. Below is the per-service subset.

### 9.1 Common to all services

```
SERVICE_NAME          # one of: tolkien, ingest, palantir, saruman, ws-gateway
LOG_LEVEL             # debug|info|warn|error
LOG_FORMAT            # json|text
OTEL_EXPORTER_OTLP_ENDPOINT   # OpenTelemetry collector
ENV                   # dev|staging|prod
```

### 9.2 DB + NATS (all services that touch DB or NATS)

```
DB_DRIVER=postgres
DB_DSN=postgres://<user>:<pass>@<host>:5432/inflora?sslmode=disable
DB_MAX_OPEN_CONNS=50
NATS_URL=nats://localhost:4222
NATS_STREAM_NAME=inflora-events
NATS_CONSUMER_GROUP=<service-name>
NATS_ACK_WAIT_SEC=30
NATS_MAX_ACK_PENDING=1000
```

### 9.3 Per-service

```
# tolkien
HTTP_ADDR=:8080
SESSION_TTL_HOURS=720
OVERLAY_TOKEN_TTL_HOURS=2160
BCRYPT_COST=12
ARGON2_MEMORY_KB=65536
ARGON2_TIME=3
ARGON2_THREADS=1
LOGIN_RATE_LIMIT_PER_MIN=5
INTERNAL_API_KEY=<shared-secret>

# ingest
HTTP_ADDR=:8081
PAYMENT_PROVIDER=midtrans
PLATFORM_FEE_BPS=1
MIN_DONATION_IDR=1000
MAX_DONATION_IDR=10000000
INTENT_TTL_MINUTES=15
RATE_LIMIT_DONATION_PER_MIN=10
RATE_LIMIT_DONATION_PER_HOUR=100
MIDTRANS_SERVER_KEY=<secret>
MIDTRANS_CLIENT_KEY=<secret>
MIDTRANS_ENV=sandbox|production
MIDTRANS_WEBHOOK_URL=https://ingest.inflora.app/v1/webhooks/payment
SARUMAN_GRPC_ADDR=saruman:7002
PALANTIR_GRPC_ADDR=palantir:7001
ENGINE_API_KEY=<shared-secret>
SM_GATEWAY_ADDR=palantir:7001
SM_GATEWAY_ENGINE_API_KEY=<shared-secret>

# palantir
GRPC_ADDR=:7001
PAYMENT_PROVIDER=midtrans
MIDTRANS_SERVER_KEY=<secret>
MIDTRANS_ENV=sandbox|production
PROVIDER_DEFAULT=pivot

# saruman
GRPC_ADDR=:7002
HTTP_ADDR=:8082
PAYMENT_PROVIDER=midtrans
PLATFORM_FEE_BPS=1
SM_GATEWAY_ADDR=palantir:7001
SM_GATEWAY_ENGINE_API_KEY=<shared-secret>
RECONCILIATION_ENABLED=true
RECONCILIATION_CRON=0 0 * * *
RECONCILIATION_DRIFT_THRESHOLD_IDR=1000
RECONCILIATION_ALERT_WEBHOOK=<optional Slack/Discord>
AEAD_KEY_HEX=<32-byte hex>
SMTP_HOST=<host>
SMTP_PORT=587
SMTP_USER=<user>
SMTP_PASS=<secret>
SMTP_FROM=receipts@inflora.app
TOLKIEN_INTERNAL_URL=http://tolkien:8080
INTERNAL_API_KEY=<shared-secret>

# ws-gateway
HTTP_ADDR=:8083
WS_PATH=/ws
WS_HEARTBEAT_INTERVAL_SEC=10
WS_HEARTBEAT_TIMEOUT_SEC=30
WS_MAX_CONNECTIONS_PER_STREAMER=100
WS_REPLAY_WINDOW_SEC=600
WS_AUTH_CACHE_TTL_SEC=60
TOLKIEN_VALIDATE_TOKEN_URL=http://tolkien:8080/v1/internal/validate-overlay-token
INTERNAL_API_KEY=<shared-secret>
```

**Critical:** every secret uses the same `INTERNAL_API_KEY` across all services. This is loaded by every service via `pkg/config`. Rotate quarterly.

---

## 10. Wire Guide Cross-References

For each connection in this guide, here'swhere the contract is defined:

| Connection | Contract source |
|---|---|
| `donation.intent.created.v1` event | `schemas/01-event-catalog.md §1` |
| `donation.charged.v1` event | `schemas/01-event-catalog.md §2` |
| All events | `schemas/01-event-catalog.md` + `00-frozen-contracts.md §1` |
| `CreateTopUp` gRPC | `schemas/04-grpc-proto.md §topup.proto` |
| All gRPCs | `schemas/04-grpc-proto.md` |
| HTTP public APIs | `schemas/03-http-api.md` |
| WS frames | `schemas/05-websocket-protocol.md` |
| Provider webhooks | `schemas/06-webhook-schemas.md` |
| DB schema | `schemas/02-database-schema.sql` |
| Error format | `00-frozen-contracts.md §6` |
| Token format | `00-frozen-contracts.md §4` |
| Money conventions | `00-frozen-contracts.md §11` |
| Time conventions | `00-frozen-contracts.md §12` |
| UUID conventions | `00-frozen-contracts.md §13` |

---

## 11. Anti-hallucination rules (for this guide)

1. **Never invent a new connection.** If a new service-to-service interaction is needed, add it to §3-5 here first, then code.
2. **Never change a port.** §1 is the canon. Update only via this guide.
3. **Never change DB ownership.** §6 is the canon. If a service needs to write a table not in its row, refactor — don't add a writer.
4. **Always import `inflora-shared` for cross-service types.** Don't redefine event payloads or gRPC structs in service repos.
5. **Always validate tokens via tolkien HTTP.** ws-gateway must NOT read sessions table directly (use HTTP + 60s cache).
6. **Always publish events from the canonical producer.** §3 is the canon.
7. **Always run migrations via saruman's cmd/migrate.** No service owns its own migration runner.

---

*End of wire guide. Edit this file when adding/removing services, ports, or connections.*