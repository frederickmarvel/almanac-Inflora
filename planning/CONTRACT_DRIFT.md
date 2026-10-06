# Contract Drift Resolution Table — Phase 0

> **Purpose:** every known conflict between prior almanac docs / code / archive, plus the authoritative decision that resolves it. Living document for Phase 0; once complete, this file is read-only and feeds into the implementation phases.
>
> **Status:** Phase 0 contract freeze (pre-implementation). All decisions below are binding on subsequent phases.
>
> **Effective from:** 2026-10-04 (start of Phase 0).
>
> **Reviewers:** Marvel (and friend for anything that touches `inflora-ws-gateway`).
>
> **How to use:** Phase reviewers must read this file before changing code. If a new conflict is discovered, **stop and add a new row here**, do not invent silently in code.

---

## 1. Webhook ownership and routing

| ID | Topic | Conflict | Decision | Resolution source |
|---|---|---|---|---|
| D-001 | Webhook ingress | Old WIRE_GUIDE §2 ASCII shows `ingest` → `saruman` `gRPC SettleDonation`. Saruman §8.4 also lists `gRPC SettleDonation`. Plan mandates `ingest → palantir SettleTopUp → pg.gateway.* event → saruman`. | **Single source of truth:** provider webhook → `ingest` HTTP → `palantir` `SettleTopUp` gRPC → `palantir` writes `gateway_topups` + emits `pg.gateway.topup.completed.v1` (or failure variant) via outbox → `saruman` consumes via durable inbox → `saruman` performs donation state transition + ledger write + emits `donation.charged.v1` (or failure) via outbox. **Saruman does not expose `SettleDonation` and never has.** | WIRE_GUIDE §2/§3/§4 (this phase); §8.4 saruman; 06-webhook-schemas §7. |
| D-002 | Webhook writer of `webhook_events` | WIRE_GUIDE §6 lists `webhook_events` as owned by `ingest, palantir` (joint). 02-database-schema.sql header says "palantir owns `gateway_*` tables". Plan mandates sole writer is Palantir. | **Palantir is the sole writer of `webhook_events`.** Ingest performs only the public HTTP edge and forwards the raw body to Palantir's `SettleTopUp` gRPC. Ingest must never insert into `webhook_events`. | WIRE_GUIDE §6; 02-database-schema.sql header comments; new §9 internal provider events. |
| D-003 | Webhook signature verification | 06-webhook-schemas §7 says "Ingest calls saruman SettleTopUp". Plan puts signature verification on Palantir. | **Palantir verifies the provider signature.** Ingest only enforces body size, content-type, method, and forwards the raw bytes. Palantir uses constant-time comparison and never logs raw payload or signature. | WIRE_GUIDE §5 (added in this phase); 06-webhook-schemas §2.1; 06-webhook-schemas §7. |

## 2. Payout and refund ownership

| ID | Topic | Conflict | Decision | Resolution source |
|---|---|---|---|---|
| D-004 | Payout state machine owner | WIRE_GUIDE §6 lists `payouts` INSERT owner as `tolkien` and UPDATEs shared between `saruman` and `palantir`. Plan mandates one atomic owner. | **Saruman owns the payout aggregate and balance reservation.** Tolkien creates the initial payout row in `REQUESTED` state via HTTP→Saruman command, only. Saruman runs the serializable transaction that locks the balance, reserves funds, posts ledger entries, and emits `payout.requested.v1` via outbox. Palantir consumes that event and calls the provider. Saruman owns all subsequent state transitions. | WIRE_GUIDE §3/§6/§8.4; new §9 events; new §10 posting templates. |
| D-005 | Refund state machine owner | Same joint-write conflict as D-004. | **Saruman owns the refund aggregate.** Tolkien is the authenticated HTTP facade (admin/finops + streamer). Saruman performs eligibility + ledger reservation. Palantir executes the provider refund and emits the result event. | WIRE_GUIDE §3/§6/§8.4. |
| D-006 | Payout/refund HTTP facade | Some docs imply Tolkien may write ledger. Plan clarifies Tolkien is HTTP only. | **Tolkien is the authenticated payout/refund HTTP facade and authorization boundary. It never writes ledger entries, never mutates donation financial state, and never directly calls providers.** It calls the frozen Saruman command surface. | WIRE_GUIDE §8.1; 03-http-api §5/§6. |

## 3. Internal provider events

| ID | Topic | Conflict | Decision | Resolution source |
|---|---|---|---|---|
| D-007 | Internal events between Palantir and Saruman | WIRE_GUIDE §3 lists `payout.settled.v1` / `payout.failed.v1` produced by `palantir-gateway`, but no event for top-up completion that drives `donation.charged.v1`. Plan requires Palantir to emit explicit top-up completion events. | **Palantir emits `pg.gateway.topup.completed.v1`, `pg.gateway.topup.failed.v1`, `pg.gateway.topup.expired.v1`, `pg.gateway.withdrawal.completed.v1`, `pg.gateway.withdrawal.failed.v1`, `pg.gateway.refund.completed.v1`, `pg.gateway.refund.failed.v1`.** Producer = Palantir. Subscribers = Saruman (always). Payloads are frozen in new `09-internal-provider-events.md`. | WIRE_GUIDE §3; new 09-internal-provider-events. |
| D-008 | Donation transition events | WIRE_GUIDE §3 has `donation.charged.v1` / `donation.settled.v1` from `saruman`. CHARGED vs SETTLED semantics need to be explicit. | **CHARGED = provider captured; settlement balance for STIVAL pending (PENDING).** Saruman emits `donation.charged.v1` with `settlement_status=PENDING` and the public outbox event in the same transaction as the capture-side ledger entries. **SETTLED = provider settled; balance moves from PENDING → AVAILABLE.** Saruman emits `donation.settled.v1` with `settlement_status=SETTLED` and the new pending→available ledger entries in the same transaction. ws-gateway may optionally subscribe to `donation.settled.v1` if `streamer_settings.notify_on_donation=true`. | 00-frozen-contracts §11; 01-event-catalog §2/§3; new 09-internal-provider-events. |
| D-009 | `SettleTopUp` gRPC | WIRE_GUIDE §4 gRPC matrix has no `SettleTopUp`. Proto file `topup.proto` already declares it. Plan requires it. | **`SettleTopUp` is on the gRPC matrix.** Caller `ingest` → callee `palantir` service `TopUpService`. Auth: `authorization: Bearer <engine-api-key>`. Wire-guide §4 + 04-grpc-proto are now aligned. | WIRE_GUIDE §4; 04-grpc-proto `topup.proto`. |

## 4. Authentication header

| ID | Topic | Conflict | Decision | Resolution source |
|---|---|---|---|---|
| D-010 | Overlay token validation header | `00-frozen-contracts.md §4.5` says `Authorization: Bearer <internal-api-key>`. WIRE_GUIDE §5 and the rest of the almanac consistently mandate `X-Internal-Api-Key` for internal HTTP. Plan mandates the latter. | **Internal HTTP uses `X-Internal-Api-Key`.** `Authorization: Bearer` is reserved for end-user session/overlay tokens. The frozen contracts §4.5 example is corrected in this phase. | 00-frozen-contracts §4.5; WIRE_GUIDE §5. |

## 5. Idempotency / operation keys

| ID | Topic | Conflict | Decision | Resolution source |
|---|---|---|---|---|
| D-011 | Donation intent idempotency | Prior doc only describes `idempotency` table (HTTP layer). Plan requires a durable business-operation key for the ledger. | **Two layers, each with its own key:** (1) HTTP layer — `(endpoint, Idempotency-Key)` in `idempotency` table (existing). (2) Business layer — stable `operation_key` per logical financial transition, stored in new `ledger_transactions.operation_key` UNIQUE. Keys are namespaced and frozen in new `11-operation-keys.md`. | WIRE_GUIDE §6; new 11-operation-keys; new 02-database-schema migration in Phase 1. |
| D-012 | Provider idempotency at Palantir | `topup.proto` already has `idempotency_key` on `CreateTopUp`. Plan mandates the same on `SettleTopUp` and other provider-result commands. | **`CreateTopUp` uses the donation-intent stable key (from `intent_id`).** Palantir dedupes by `(provider_name, idempotency_key)` and by gateway_topup `palantir_ref`. `SettleTopUp` uses `(provider_name, provider_event_id)` for dedup. No new fields on the proto; existing fields are sufficient. | 04-grpc-proto `topup.proto`. |
| D-013 | Consumer dedup boundary | `inflora-shared/events` has `sync.Map`-based dedup. Plan requires durable consumer inbox. | **Durable consumer inbox is the correctness boundary.** The in-memory map may remain as a performance optimization only. New `consumer_inbox` table (Phase 1). | new 09-internal-provider-events; Phase 2 deliverables. |

## 6. Ledger posting templates

| ID | Topic | Conflict | Decision | Resolution source |
|---|---|---|---|---|
| D-014 | Posting templates were implicit | Existing almanac describes ledger entries in prose but has no canonical posting-template document. Plan requires explicit freezing. | **Posting templates are frozen in new `10-posting-templates.md`** for: (1) donation capture, (2) donation settlement, (3) payout reservation, (4) payout completion, (5) payout failure release, (6) refund. Each template specifies accounts, directions, amounts, and a derived `operation_key`. | new 10-posting-templates. |

## 7. WebSocket projection

| ID | Topic | Conflict | Decision | Resolution source |
|---|---|---|---|---|
| D-015 | WS sequence/replay durability | Prior doc says sequence starts at 1 on gateway boot and wraps at 2^53-1. Plan flags this as not durable across multi-replica deploys. | **Sequence and replay are owned by a durable PostgreSQL projection in the WS gateway service.** New tables `ws_projection_sequences`, `ws_projection_frames`, `ws_projection_inbox`. Replay supports `?since=<seq>` and emits `system.resync_required` when the gap exceeds the retention window. Two replicas see the same history because `(streamer_id, seq)` is UNIQUE and the per-streamer sequence is allocated under a row lock. | WIRE_GUIDE §6 (added in this phase); 05-websocket-protocol (already lists `?since=`); Phase 1 migration. |

## 8. Provider MVP scope

| ID | Topic | Conflict | Decision | Resolution source |
|---|---|---|---|---|
| D-016 | Midtrans vs Xendit vs Pivot | Old docs include Xendit and Pivot at the same priority level. User note 2026-09-17 deferred Xendit. Plan mandates MVP primary is Midtrans SNAP, with Pivot as local-only stub. | **MVP provider scope: Midtrans SNAP production, Pivot deterministic stub local-only. Xendit is deferred to a future phase and MUST NOT be added to any current implementation.** No Xendit env vars, no Xendit gRPC handlers, no Xendit test fixtures. | PROJECT_SUMMARY §13; WIRE_GUIDE §9; 06-webhook-schemas §3 retained for reference but not implemented. |
| D-017 | Pivot name | Old docs call the stub "Pivot". Plan keeps Pivot as the local-only stub. | **The local stub provider is named `pivot` everywhere (env, code, tests).** Retained as the integration harness provider for all local E2E and Phase 9. | 06-webhook-schemas §4; PROJECT_SUMMARY §7. |

## 9. Outbox / dead-letter

| ID | Topic | Conflict | Decision | Resolution source |
|---|---|---|---|---|
| D-018 | Outbox dispatcher reliability | No transactional outbox exists. Plan mandates one. | **Each producer transaction writes to `outbox_events` in the same DB transaction as the business state.** A separate dispatcher claims rows with `FOR UPDATE SKIP LOCKED`, publishes via NATS JetStream with `Nats-Msg-Id = event_id`, waits for publish ack, and only then marks the row published. Phase 1 ships the schema; Phase 2 ships the dispatcher. | new 09-internal-provider-events; Phase 1 migration; Phase 2 deliverables. |
| D-019 | Dead-letter workflow | No durable dead-letter exists. | **Exhausted/permanent failures are persisted in `event_dead_letters`.** A consumer may ACK only after the dead-letter row commits. Replay uses the original `event_id` and the consumer inbox for idempotency. | Phase 1 schema; Phase 2 library; Phase 12 ops CLI. |

---

## 10. Service naming

| ID | Topic | Conflict | Decision | Resolution source |
|---|---|---|---|---|
| D-020 | Producer / service identity | Schema docs (00 §1 envelope, 01-event-catalog, 07 `SERVICE_NAME`) used legacy names `ingest-api`, `palantir-gateway`, `ithildin`, `realtime-gateway`; the codebase canonical names are the short forms. | **Canonical service names are `ingest`, `palantir`, `saruman`, `tolkien`, `ws-gateway`.** `inflora-shared/config.Load` accepts the legacy aliases (`ingest-api`→`ingest`, `ithildin`→`ws-gateway`) but every producer string, `SERVICE_NAME` value, and doc label uses the short form. `palantir-gateway` has no alias; it is `palantir`. `realtime-gateway` was the WS overlay service alias; it is `ws-gateway`. | `inflora-shared/config/config.go` (`defaultHTTPAddr`/`Load`); backend `cmd/*/main.go` defaults (`ingest`, `palantir`, `tolkien`, `ws-gateway`, `saruman`). |

## How a future agent should use this file

1. Before writing any code, search this table for the topic.
2. If the topic is here, follow the decision column and link the resolution source in your PR/commit message.
3. If you find a new conflict, **add a new row here first**. Do not resolve silently in code.
4. After Phase 0 closes (all RPC validations green, all migrations down/up tested, all gRPC and HTTP boundary contracts validated), this file becomes read-only.

*End of contract drift table.*