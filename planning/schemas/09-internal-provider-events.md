# 09 — Internal Provider-Result Events (Palantir → Saruman)

> **Status:** FROZEN — Phase 0 contract freeze. Implementation Phase 6.
> **Producer:** `palantir`. **Subscribers:** `saruman`. No other consumer at MVP.
> **Format:** the frozen `00-frozen-contracts.md §1` envelope. Subjects follow `<topic>.<streamer_id>` (or no streamer_id for global events).
> **Reliability:** every event is published from `palantir` via the transactional outbox (`outbox_events` in the same DB transaction as `gateway_topups` / `gateway_withdrawals` / `gateway_refunds` + `webhook_events` writes). Consumer dedup is via `consumer_inbox` on the Saruman side (Phase 2).

These events replace the old direct "Ingest → Saruman SettleDonation" path. Ingest never writes to `webhook_events`, donations, or ledger. Palantir verifies the provider signature and emits these normalized events. Saruman performs the donation transition and ledger write based on the frozen payload.

---

## 1. Index

| Topic | Producer | Subscribers | Trigger |
|---|---|---|---|
| `pg.gateway.topup.completed.v1` | palantir | saruman | Provider captured the payment (Midtrans `capture`/`settlement`, Pivot `topup.completed`) |
| `pg.gateway.topup.failed.v1` | palantir | saruman | Provider failed/denied the top-up |
| `pg.gateway.topup.expired.v1` | palantir | saruman | Top-up window expired without capture |
| `pg.gateway.withdrawal.completed.v1` | palantir | saruman | Withdrawal settled at the bank |
| `pg.gateway.withdrawal.failed.v1` | palantir | saruman | Bank rejected / returned the withdrawal |
| `pg.gateway.topup.settled.v1` (dev-only marker) | palantir | saruman | Pivot dev autosettle closed both capture and settlement in one TX (D-052) |
| `pg.gateway.refund.completed.v1` | palantir | saruman | Refund settled at the provider |
| `pg.gateway.refund.failed.v1` | palantir | saruman | Refund rejected / not settled |

Withdrawal payloads are additive (CONTRACT_DRIFT D-047 family): `bank_account_ref` rides the completed/failed payloads; consumers compiled before the field ignore it.

---

## 2. `pg.gateway.topup.completed.v1`

**Trigger:** provider captured the donation. Saruman must transition the donation `INTENT_CREATED → CHARGED`, post the capture-side ledger entries, and emit `donation.charged.v1`.

**Subject:** `pg.gateway.topup.completed.v1.<streamer_id>`

**Payload:**
```json
{
  "donation_id":              "uuid",
  "intent_id":                "uuid",
  "streamer_id":              "uuid",
  "saruman_donation_id":      "uuid",
  "amount_idr":               10000,
  "mdr_idr":                  70,
  "mdr_rate_bps":             70,
  "gross_charged_idr":        10070,
  "platform_fee_idr":         1,
  "net_idr":                  9999,
  "currency":                 "IDR",
  "provider":                 "midtrans",
  "payment_method":           "QRIS",
  "provider_charge_id":       "TRX-12345",
  "provider_event_id":        "evt-abc-123",
  "raw_provider_status":      "capture",
  "raw_provider_fraud_status":"accept",
  "captured_at":              "2026-10-02T14:30:01.500Z",
  "gateway_topup_palantir_ref":"gt-<uuid>",
  "webhook_event_id":         "uuid"
}
```

**Invariants:**
- Saruman's transition is `INTENT_CREATED → CHARGED`; cannot regress.
- Exactly 2 ledger entries: `donor_cash +gross_charged`, `streamer_pending +net_idr` (or `+amount-fee`).
- `settlement_status` stays `PENDING`.
- Emitted `donation.charged.v1` carries the same fields with `settlement_status=PENDING`.

---

## 3. `pg.gateway.topup.failed.v1`

**Trigger:** provider denied, cancelled, or returned the gateway_topup. Saruman transitions `INTENT_CREATED → FAILED`.

**Subject:** `pg.gateway.topup.failed.v1.<streamer_id>`

**Payload:**
```json
{
  "donation_id":              "uuid",
  "intent_id":                "uuid",
  "streamer_id":              "uuid",
  "amount_idr":               10000,
  "provider":                 "midtrans",
  "provider_charge_id":       "TRX-12345",
  "provider_event_id":        "evt-abc-456",
  "raw_provider_status":      "deny",
  "failure_reason":           "PROVIDER_ERROR",
  "failed_at":                "2026-10-02T14:30:05Z",
  "gateway_topup_palantir_ref":"gt-<uuid>",
  "webhook_event_id":         "uuid"
}
```

`failure_reason` ∈ {`PROVIDER_ERROR`, `INSUFFICIENT_FUNDS`, `FRAUD_BLOCKED`, `USER_CANCELLED`}. Frozen map in `06-webhook-schemas §2.3`.

---

## 4. `pg.gateway.topup.expired.v1`

**Trigger:** gateway top-up's `expires_at` elapsed without provider confirmation. Saruman transitions `INTENT_CREATED → FAILED` with `failure_reason=TIMEOUT`.

**Subject:** `pg.gateway.topup.expired.v1.<streamer_id>`

**Payload:**
```json
{
  "donation_id":              "uuid",
  "intent_id":                "uuid",
  "streamer_id":              "uuid",
  "amount_idr":               10000,
  "provider":                 "midtrans",
  "provider_charge_id":       "TRX-12345",
  "expired_at":               "2026-10-02T14:45:00Z",
  "gateway_topup_palantir_ref":"gt-<uuid>"
}
```

---

## 5. `pg.gateway.withdrawal.completed.v1`

**Trigger:** provider settled the withdrawal at the bank. Saruman moves `STREAMER_PAID` value (already reserved) to terminal state and posts the completion ledger entries (see `10-posting-templates §4`).

**Subject:** `pg.gateway.withdrawal.completed.v1.<streamer_id>`

**Payload:**
```json
{
  "payout_id":                "uuid",
  "streamer_id":              "uuid",
  "amount_idr":               150000,
  "provider":                 "midtrans",
  "provider_payout_id":       "WD-98765",
  "provider_event_id":        "evt-987",
  "bank_reference":           "BCA-12345",
  "bank_account_ref":         "uuid (additive, D-055 mirror)",
  "settled_at":               "2026-10-05T10:30:00Z",
  "gateway_withdrawal_palantir_ref":"gw-<uuid>",
  "webhook_event_id":         "uuid"
}
```

---

## 6. `pg.gateway.withdrawal.failed.v1`

**Trigger:** bank rejected / returned. Saruman reverses the payout reservation and posts a release compensation (see `10-posting-templates §5`).

**Subject:** `pg.gateway.withdrawal.failed.v1.<streamer_id>`

**Payload:**
```json
{
  "payout_id":                "uuid",
  "streamer_id":              "uuid",
  "amount_idr":               150000,
  "provider":                 "midtrans",
  "provider_payout_id":       "WD-98765",
  "provider_event_id":        "evt-654",
  "bank_account_ref":         "uuid (additive, D-055 mirror)",
  "failure_reason":           "BANK_REJECTED",
  "failed_at":                "2026-10-05T10:31:00Z",
  "gateway_withdrawal_palantir_ref":"gw-<uuid>",
  "webhook_event_id":         "uuid"
}
```

---

## 7. `pg.gateway.refund.completed.v1`

**Trigger:** provider settled the refund. Saruman posts a refund compensation (see `10-posting-templates §6`) and emits `donation.refunded.v1`.

**Subject:** `pg.gateway.refund.completed.v1.<streamer_id>`

**Payload:**
```json
{
  "refund_id":                "uuid",
  "donation_id":              "uuid",
  "streamer_id":              "uuid",
  "amount_idr":               10000,
  "provider":                 "midtrans",
  "provider_refund_id":       "RF-11111",
  "provider_event_id":        "evt-321",
  "completed_at":             "2026-10-06T09:00:00Z",
  "gateway_refund_palantir_ref":"gr-<uuid>",
  "webhook_event_id":         "uuid"
}
```

---

## 8. `pg.gateway.refund.failed.v1`

**Trigger:** provider rejected the refund. Saruman reverses any refund-side reservation.

**Subject:** `pg.gateway.refund.failed.v1.<streamer_id>`

**Payload:**
```json
{
  "refund_id":                "uuid",
  "donation_id":              "uuid",
  "streamer_id":              "uuid",
  "amount_idr":               10000,
  "provider":                 "midtrans",
  "provider_refund_id":       "RF-11111",
  "failure_reason":           "PROVIDER_REJECTED",
  "failed_at":                "2026-10-06T09:00:05Z",
  "gateway_refund_palantir_ref":"gr-<uuid>",
  "webhook_event_id":         "uuid"
}
```

---

## 9. `pg.gateway.topup.settled.v1` (dev-only settlement closure, D-052)

**Trigger:** Pivot autosettle-dev path only (default ON in dev). Palantir emits it **alongside** `pg.gateway.topup.completed.v1` in the same outbox TX. There is no prod trigger: prod settlement cadence (T+N, refunds FFF) is out of Phase C (CONTRACT_DRIFT D-052).

**Subject:** `pg.gateway.topup.settled.v1.<streamer_id>`

**Payload:**
```json
{
  "donation_id":              "uuid",
  "streamer_id":              "uuid",
  "amount_idr":               10000,
  "provider":                 "pivot",
  "provider_event_id":        "evt-settle-1",
  "settled_at":               "2026-10-02T14:30:01.500Z",
  "gateway_topup_palantir_ref":"gt-<uuid>"
}
```

**Saruman handler:** closes donation `PENDING → SETTLED` + s2 posting (`DonationSettleKey`) + `donation.settled.v1`, reusing the frozen §2-posting amount semantics. Late arrival after manual settlement is a no-op (never regress a settled donation).

---

## 10. payout.* producer register (D-028, registered via CONTRACT_DRIFT D-049)

The payout/batch domain events are produced by **saruman** (payout machine), not by tolkien/palantir as older WIRE_GUIDE editions listed:

| Topic | Producer | Subscribers | Payload |
|---|---|---|---|
| `payout.requested.v1` | saruman | palantir (provider attempt at REQUESTED, D-055), tolkien (read-side) | `events.PayoutRequestedEvent` |
| `payout.batched.v1` | saruman (+tolkien legacy DRAFT-batch path, D-054) | analytics | `events.PayoutBatchedEvent` |
| `payout.batch.executed.v1` | saruman | analytics | `events.PayoutBatchExecutedEvent` |
| `payout.settled.v1` | saruman | analytics | `events.PayoutSettledEvent` |
| `payout.failed.v1` | saruman | analytics | `events.PayoutFailedEvent` |
| `payout.batch.completed.v1` | saruman | analytics | `events.PayoutBatchCompletedEvent` |
| `payout.batch.failed.v1` | saruman | analytics | `events.PayoutBatchFailedEvent` |

Payload shapes live in `inflora-shared/events/catalog.go`; saruman emits all of them from its transactional outbox in the same TX as the state transition.

---

## 11. CHARGED vs SETTLED semantics (D-008)

| Term | Trigger | Donation status | Settlement status | PENDING ledger | AVAILABLE ledger | Public event |
|---|---|---|---|---|---|---|
| CHARGED | Provider captured (`capture`/`settlement` from Midtrans, or Pivot `topup.completed`) | `CHARGED` | `PENDING` | `+net_idr` | — | `donation.charged.v1` |
| SETTLED | Provider settled funds (later in T+N) | `SETTLED` | `SETTLED` | `-net_idr` | `+net_idr` | `donation.settled.v1` |
| FAILED | Provider denied/expired/timeout | `FAILED` | `FAILED` | rolled back | — | `donation.failed.v1` |
| REFUNDED | Authorized refund completed at provider | `REFUNDED` | `SETTLED` | reversed | reversed | `donation.refunded.v1` |

`CHARGED` does not mean the streamer can withdraw. Only `SETTLED` donations contribute to `STREAMER_AVAILABLE` (and therefore to payout eligibility).

---

## 12. Reliability contract

- Every event above is published from `palantir` via `outbox_events` in the same DB transaction as the `gateway_*` row update and the `webhook_events` row insert.
- `event_id` is generated as UUIDv4 once, stable across outbox retries.
- `Nats-Msg-Id = event_id`. Saruman's `consumer_inbox` primary key is `(consumer_name, event_id)`.
- Saruman treats the inbox as the dedup boundary. The optional in-memory map in `inflora-shared/events` is **not** the correctness boundary.
- `event_type` and `event_version` must match the schema above. Saruman MUST dead-letter unknown types/versions.

*End of internal provider events.*