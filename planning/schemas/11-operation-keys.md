# 11 — Stable Idempotency / Operation Keys

> **Status:** FROZEN — Phase 0 contract freeze. Implementation Phases 1, 2, 5, 6, 7.
> **Purpose:** give every name-spaced operation a deterministic, unique key so duplicate retries cannot produce duplicate financial effects.

Inflora has two idempotency layers (D-011):

1. **HTTP-layer idempotency** (existing) — `(endpoint, Idempotency-Key)` in the `idempotency` table.
2. **Business-layer operation key** — stable `operation_key` per logical financial transition, stored in the new `ledger_transactions.operation_key` UNIQUE column (Phase 1 migration).

This document freezes the second layer.

---

## 1. Namespace conventions

Operation keys have the form `<namespace>:<part-1>[:<part-2>...]`.

Namespaces are:

| Namespace | Where it appears | Layer |
|---|---|---|
| `http_idem:<endpoint>` | `idempotency.key` (existing) | HTTP edge |
| `donation_capture` | `ledger_transactions.operation_key` (Phase 1) | business |
| `donation_settle` | same | business |
| `create_payout` | same | business |
| `complete_payout` | same | business |
| `fail_payout` | same | business |
| `donation_refund` | same | business |
| `donation_intent` | `idempotency.key` (or stable column on `donations.intent_id`) | HTTP |
| `palantir_topup` | `gateway_topups.palantir_ref` | provider |
| `palantir_withdrawal` | `gateway_withdrawals.palantir_ref` | provider |
| `palantir_refund` | `gateway_refunds.palantir_ref` | provider |
| `webhook` | `webhook_events(provider_name, provider_event_id)` UNIQUE | provider |

---

## 2. Business-layer derivation rules

Operation keys are derived via UUIDv5 with the namespace UUID `inflora-ops-v1 = 7f9a3b6c-2c8e-4f01-9c0e-1a4e7d8c9e02` (registered in `inflora-shared/keys/operation.go`, Phase 2).

```
operation_key = UUIDv5(namespace=inflora-ops-v1, name="<namespace>:<part-1>[:<part-2>...]")
```

The resulting UUIDv5 is the literal stored in `ledger_transactions.operation_key`. UUIDv5 is deterministic: re-deriving the same input always yields the same key.

| Logical operation | Operation key seed string | Stored in column |
|---|---|---|
| Donation capture | `donation_capture:<donation_id>` | `ledger_transactions.operation_key` |
| Donation settlement | `donation_settle:<donation_id>` | same |
| Payout reservation | `create_payout:<payout_id>` | same |
| Payout completion | `complete_payout:<payout_id>` | same |
| Payout failure release | `fail_payout:<payout_id>` | same |
| Refund compensation | `donation_refund:<donation_id>:<refund_id>` | same |

Operation keys are **also** carried in the corresponding `pg.gateway.*` event payload (`operation_key` field) so Saruman's durable consumer_inbox can reference the same key without re-deriving.

---

## 3. Provider-layer derivation rules

These live on the provider state tables, not on the ledger:

| Logical operation | Provider key | UNIQUE column |
|---|---|---|
| Palantir top-up | `palantir_topup:<saruman_donation_id>` | `gateway_topups.palantir_ref` (UNIQUE) |
| Palantir withdrawal | `palantir_withdrawal:<saruman_payout_id>` | `gateway_withdrawals.palantir_ref` (UNIQUE) |
| Palantir refund | `palantir_refund:<saruman_refund_id>` | `gateway_refunds.palantir_ref` (UNIQUE) |
| Provider webhook | `<provider_name>:<provider_event_id>` (existing) | `webhook_events(provider_name, provider_event_id)` UNIQUE |

Palantir must look up by `(provider_name, idempotency_key)` or `(palantir_ref, ...)` on `CreateWithdrawal`/`CreateRefund` to return the same result for an exact retry.

---

## 4. HTTP-layer derivation rules

Existing `00-frozen-contracts §5` continues to apply for HTTP-level idempotency. The `Idempotency-Key` header value is a UUIDv4 from the client. `idempotency.key` is stored as `<endpoint>:<Idempotency-Key>` (existing).

For Ingest's public donation intent (`POST /v1/donations`), the HTTP idempotency record covers only the donation row insert. The **operation key for the gateway top-up** is derived from the donation's `intent_id` (Palantir uses `palantir_topup:<donation_id>` as `idempotency_key` on `CreateTopUp`).

---

## 5. Consumer-layer dedup boundary

Saruman's durable consumer_inbox primary key `(consumer_name, event_id)` is the correctness boundary for `pg.gateway.*` event consumption. The in-memory `sync.Map` in `inflora-shared/events` may remain as a performance optimization but MUST NOT be relied upon.

`consumer_name` is `saruman.topup-completed`, `saruman.topup-failed`, `saruman.withdrawal-completed`, etc. — one per topic. List is frozen in `inflora-shared/events/configs.CONSUMER_NAMES`.

---

## 6. Failure-injection guarantees

The combination of operation-key UNIQUE constraint (Phase 1) + consumer_inbox UNIQUE (Phase 1) + transactional outbox (Phase 1+2) provides the following invariants:

- Duplicate `pg.gateway.*` redelivery: second delivery hits the inbox UNIQUE, treated as no-op, does not create a duplicate ledger transaction.
- Duplicate `CreateTopUp` from Ingest with same `idempotency_key`: Palantir returns the prior gateway_topup, does not call provider twice.
- Process restart before outbox publish: row remains unpublished, dispatcher re-publishes with the same `event_id`.
- Process restart after publish, before ACK: redelivery hits the inbox UNIQUE, treated as no-op.

These are exercised in Phase 7 failure-injection tests and Phase 9 E2E.

---

## 7. Implementation owners

| Component | Owner | Phase |
|---|---|---|
| UUIDv5 namespace registration | `inflora-shared` | Phase 2 |
| `ledger_transactions.operation_key` UNIQUE column | Saruman migration runner | Phase 1 |
| Consumer inbox `(consumer_name, event_id)` UNIQUE | Saruman migration runner | Phase 1 |
| `gateway_topups.palantir_ref` UNIQUE | Palantir (already inline in `02-database-schema.sql`) | already |
| `webhook_events(provider_name, provider_event_id)` UNIQUE | Palantir (already inline) | already |
| Operation-key derivation helpers | `inflora-shared/keys` | Phase 2 |

*End of operation keys.*