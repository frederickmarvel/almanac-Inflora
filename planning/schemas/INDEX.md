# Schema Index — Start Here

> **All backend schemas for Inflora MVP, in one place.**
> Read this index first, then jump to the file you need.

---

## File map

| # | File | Purpose | Audience |
|---|---|---|---|
| **00** | `00-frozen-contracts.md` | Cross-cutting: event envelope, error format, pagination, headers, idempotency keys, token format | All engineers |
| **01** | `01-event-catalog.md` | Every event topic with full payload schema, producer, consumers, trigger | All engineers |
| **02** | `02-database-schema.sql` | Full SQL DDL (PostgreSQL 15+) with comments for every table | Backend |
| **03** | `03-http-api.md` | All REST endpoints (dashboard, public, admin, webhook, health) | Frontend, integrations |
| **04** | `04-grpc-proto.md` | gRPC service definitions (saruman ↔ palantir-gateway internal RPCs) | Backend |
| **05** | `05-websocket-protocol.md` | WS frame protocol for OBS browser source, sequence numbers, reconnect, close codes | Friend (WS gateway) |
| **06** | `06-webhook-schemas.md` | Payment provider webhook formats (Midtrans, Xendit, Pivot stub), signature verification, idempotency | Backend |
| **07** | `07-config-schema.md` | Per-service config env vars + future One Ring keys | Ops, Backend |
| **08** | `08-flow-diagrams.md` | End-to-end flows: donation, refund, payout, token rotation, WS reconnect, idempotency, reconciliation | All engineers |

---

## Reading order

**If you're the friend (building WS gateway):**
1. `00-frozen-contracts.md` — learn the envelope
2. `05-websocket-protocol.md` — learn the WS frames you'll send
3. `01-event-catalog.md` → focus on `donation.charged.v1`, `donation.failed.v1`
4. `08-flow-diagrams.md` → "Flow 1: Happy Path" + "Flow 2: WS Connect & Catch-up"

**If you're Marvel (parallel tracks):**
1. `00-frozen-contracts.md`
2. `02-database-schema.sql` (Day 2-3)
3. `03-http-api.md` (Dashboard + Public + Admin)
4. `01-event-catalog.md` (for events you'll fire)
5. `08-flow-diagrams.md` (visualize)

**If you're ops / on-call:**
1. `07-config-schema.md`
2. `00-frozen-contracts.md` (error codes, status codes)
3. `08-flow-diagrams.md` (Flow 7 reconciliation)

---

## Service-to-schema map

| Service | Owns | Schemas it implements |
|---|---|---|
| **ingest-api** (Go) | public donation page, webhook edge | 00, 03 (§Public), 06, 01 (intent events) |
| **saruman** (Go) | donation engine, double-entry ledger, idempotency | 00, 01 (donation events), 02 (most), 04 (palantir client) |
| **palantir-gateway** (Go) | payment provider broker | 02 (gateway_* tables), 04 (service impl), 06 |
| **tolkien** (Go) | dashboard + auth + token issuance | 00, 01 (streamer events), 02 (sessions), 03 (§Streamer) |
| **ithildin / WS-gateway** (Go) | OBS overlay WS proxy + token validation | 00, 02 (streamers read), 03 (§Internal), 05 (WS), 01 (subscribes) |

---

## Versioning policy

- All schemas are at `v1` as of 2026-10-02.
- **Adding optional fields** = backward-compatible. Bump doc, no version change.
- **Changing field shape or removing fields** = breaking. New topic version (`donation.charged.v2`).
- Old consumers keep reading old topics. Old producers keep producing old topics.
- New consumers subscribe to new topics. Both can coexist.

---

## Change process

1. Open PR with schema change.
2. Reviewer = Marvel + friend (both must ack).
3. Update topic version if breaking.
4. Update dependent docs in this folder (`INDEX.md`, flow diagrams).
6. Add a CHANGELOG entry under `## Changelog` below.

---

## Changelog

| Date | Change | Author |
|---|---|---|
| 2026-10-02 | Initial schema freeze for MVP | Marvel + friend |