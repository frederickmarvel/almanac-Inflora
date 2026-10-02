# Inflora Almanac

> **Live source-of-truth documents for Inflora — schemas, runbooks, planning, and references.**
> The `archive/` directory in the parent `Inflora` repo holds the frozen MVP build state from 2026-09-16 → 2026-10-02. Anything new lives in this almanac.

---

## What's in here

```
almanac/
├── README.md                   ← you are here
├── planning/                   ← operational + planning docs
│   ├── RUNBOOK.md                 per-service runbook template + filled example
│   ├── ONCALL_CHECKLIST.md        shift handover + incident response checklist
│   ├── PARALLEL_WORK_PLAN.md      Marvel + friend parallelization plan
│   └── schemas/                   full backend schema freeze (MVP)
│       ├── INDEX.md               start here
│       ├── 00-frozen-contracts.md  Track 0 contracts (event envelope, tokens, etc.)
│       ├── 01-event-catalog.md    every v1 event with payload schema
│       ├── 02-database-schema.sql  full PostgreSQL DDL (466 lines)
│       ├── 03-http-api.md         all REST endpoints
│       ├── 04-grpc-proto.md       saruman ↔ palantir-gateway RPCs
│       ├── 05-websocket-protocol.md OBS overlay WS protocol
│       ├── 06-webhook-schemas.md  Midtrans / Xendit / Pivot
│       ├── 07-config-schema.md    per-service config env vars
│       └── 08-flow-diagrams.md    end-to-end flows (10 flows, 707 lines)
├── docs/                       ← external tech docs (mirrors)
│   └── Pivot_techdocs.md          Pivot Payment Gateway docs mirror
└── skills/                     ← agent toolchain (Claude plugin)
    └── skills/                    Claude Skills plugin (board-thinking, cso-thinking, etc.)
```

---

## Reading order for new contributors

**If you're shipping the OBS overlay WebSocket gateway:**
1. `planning/schemas/00-frozen-contracts.md` — the contracts
2. `planning/schemas/05-websocket-protocol.md` — WS frames you'll send
3. `planning/schemas/01-event-catalog.md` → focus on `donation.charged.v1`, `donation.failed.v1`
4. `planning/schemas/08-flow-diagrams.md` → Flow 1 (donation) + Flow 2 (WS connect & catch-up)
5. `planning/PARALLEL_WORK_PLAN.md` — your scope vs the parallel track

**If you're shipping the engine / dashboard / ledger / auth / payments:**
1. `planning/schemas/00-frozen-contracts.md`
2. `planning/schemas/02-database-schema.sql` — full DDL
3. `planning/schemas/03-http-api.md` — your service's endpoints
4. `planning/schemas/01-event-catalog.md` — events you'll publish/consume
5. `planning/schemas/08-flow-diagrams.md` — all flows for shared understanding
6. `planning/PARALLEL_WORK_PLAN.md`

**If you're on-call:**
1. `planning/RUNBOOK.md` — per-service operations
3. `planning/ONCALL_CHECKLIST.md` — shift handover + incident response

---

## Status as of 2026-10-02

| Area | Status | Next action |
|---|---|---|
| Schemas (frozen contracts) | ✅ Written | Open contracts PR Day 1 of next sprint |
| Runbook template | ✅ Written | Fill per-service versions as services come online |
| On-call checklist | ✅ Written | Adopt on Day 1 of production |
| Parallel work plan | ✅ Written | Friend starts Day 2 after contracts PR merge |
| Pivot docs mirror | ✅ Snapshot | Refresh when Pivot docs change |

---

## Versioning

- All schemas currently at `v1`.
- Schema changes go through PR review (both Marvel + friend must ack).
- Breaking changes require a new major version (`donation.charged.v2`, etc.).

See `planning/schemas/INDEX.md` §Versioning policy for details.

---

## Conventions

- **Money:** IDR minor units only (`BIGINT`, no decimals). Always append `_idr` suffix on amount fields.
- **Time:** RFC 3339 UTC, ms precision.
- **UUIDs:** v4 lowercase with dashes.
- **Tokens:** opaque with `sk_` (session) or `ok_` (overlay) prefix. Bcrypt-hashed in DB.
- **Append-only:** ledger entries never mutate; corrections are reversal entries.
- **Idempotency:** every webhook + every external write is idempotent on `provider_event_id` / `idempotency_key`.

See `planning/schemas/00-frozen-contracts.md` for the full convention set.

---

*For the legacy/frozen MVP build state, see the parent repo's `archive/` directory.*