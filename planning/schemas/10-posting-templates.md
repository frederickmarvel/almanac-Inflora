# 10 — Frozen Ledger Posting Templates

> **Status:** FROZEN — Phase 0 contract freeze. Implementation Phase 7.
> **Owner:** Saruman (the only service that writes `ledger_entries` and `ledger_transactions`).
> **Money:** IDR only. Integer `BIGINT`. No decimals. Append-only ledger. Corrections via linked compensation transactions only.
> **Operation keys:** stable, derived per logical operation (frozen in `11-operation-keys.md`).

Each posting template below specifies:

- A logical operation name and unique `operation_key` derivation.
- The exact ledger entries (accounts, directions, amounts, types).
- The `transaction_type` and `correlation_id` semantics.
- The donation/payout/refund state transitions it pairs with.

Posting templates are encoded as Go functions in `inflora-saruman/internal/ledger/postings.go` (Phase 7). Tests assert balance and immutability.

---

## Conventions used in this document

| Symbol | Meaning |
|---|---|
| `donor_cash(streamer)` | `DONOR_CASH` account for this streamer |
| `streamer_pending(streamer)` | `STREAMER_PENDING` account for this streamer |
| `streamer_available(streamer)` | `STREAMER_AVAILABLE` account for this streamer |
| `streamer_paid(streamer)` | `STREAMER_PAID` account for this streamer |
| `platform_revenue()` | singleton `PLATFORM_REVENUE` account (one global row keyed by `streamer_id = platform`) |
| `mdr_revenue()` | singleton `MDR_REVENUE` account (informational only; provider takes this directly) |
| `hold_escrow(streamer)` | escrow account for streamer-level fund holds |

Direction `DEBIT` decreases, `CREDIT` increases the account balance. Each logical operation must balance: `sum(CREDIT) == sum(DEBIT)`. Implementations assert balance inside the same DB transaction.

`amount_idr` is always strictly positive (`> 0`). Zero or negative amounts are rejected.

---

## 1. Donation capture (CHARGED)

Trigger: Saruman consumes `pg.gateway.topup.completed.v1` and transitions donation to `CHARGED`.

| `operation_key` | derivation |
|---|---|
| `donation_capture:<donation_id>` | UUIDv5 from `("donation_capture", donation_id)` |

| `transaction_type` | `correlation_id` |
|---|---|
| `DONATION_CAPTURE` | the inbox event's `event_id` |

**Entries:**

| # | Account | Direction | amount_idr | entry_type | external_ref |
|---|---|---|---|---|---|
| 1 | `donor_cash(streamer)` | CREDIT | `gross_charged_idr` | `DONATION_DEPOSIT` | `donation_id` |
| 2 | `streamer_pending(streamer)` | CREDIT | `net_idr` | `STREAMER_PENDING_CREDIT` | `donation_id` |
| 3 | `platform_revenue()` | CREDIT | `platform_fee_idr` | `PLATFORM_FEE` | `donation_id` |
| 4 | `mdr_revenue()` | CREDIT | `mdr_idr` | `MDR_FEE` | `donation_id` |

**Balance invariant:** `gross_charged_idr == net_idr + platform_fee_idr + mdr_idr`. The Saruman posting engine verifies this equality and rejects the transaction otherwise.

Donation state after commit: `status=CHARGED, settlement_status=PENDING, charged_at=<now>`. Public outbox event: `donation.charged.v1` with `settlement_status=PENDING`.

---

## 2. Donation settlement (SETTLED)

Trigger: Saruman consumes a settlement webhook, normally via a future `pg.gateway.topup.settled.v1` from Palantir (or, in MVP, the same `pg.gateway.topup.completed.v1` followed by a later webhook if the provider distinguishes capture vs settle). For MVP, settlement may happen in the same transaction as capture for QRIS — see `09-internal-provider-events §9`.

| `operation_key` | derivation |
|---|---|
| `donation_settle:<donation_id>` | UUIDv5 from `("donation_settle", donation_id)` |

| `transaction_type` | `correlation_id` |
|---|---|
| `DONATION_SETTLE` | the inbox event's `event_id` |

**Entries:**

| # | Account | Direction | amount_idr | entry_type | external_ref |
|---|---|---|---|---|---|
| 1 | `streamer_pending(streamer)` | DEBIT | `net_idr` | `STREAMER_PENDING_CREDIT` (reversal marker) | `donation_id` |
| 2 | `streamer_available(streamer)` | CREDIT | `net_idr` | `STREAMER_AVAILABLE_CREDIT` | `donation_id` |

**Balance invariant:** `net_idr == net_idr`.

Donation state after commit: `status=SETTLED, settlement_status=SETTLED, settled_at=<now>`. Public outbox event: `donation.settled.v1`.

> Capture template §1 already posts the gross into `donor_cash`. The settle template does **not** move money out of `donor_cash`. `donor_cash` is informational for refund reconciliation; refunds debit the appropriate available/pending accounts per §6.

---

## 3. Payout reservation (REQUESTED)

Trigger: Saruman's payout-request command (called from Tolkien HTTP facade) succeeds the eligibility + balance check and reserves funds.

| `operation_key` | derivation |
|---|---|
| `create_payout:<payout_id>` | UUIDv5 from `("create_payout", payout_id)` |

| `transaction_type` | `correlation_id` |
|---|---|
| `PAYOUT_RESERVATION` | the request's `Idempotency-Key` (or `request_id` if no key) |

**Entries:**

| # | Account | Direction | amount_idr | entry_type | external_ref |
|---|---|---|---|---|---|
| 1 | `streamer_available(streamer)` | DEBIT | `amount_idr` | `STREAMER_PAID_DEBIT` | `payout_id` |
| 2 | `streamer_paid(streamer)` | CREDIT | `amount_idr` | `STREAMER_PAID_DEBIT` (marker) | `payout_id` |

**Balance invariant:** `amount_idr == amount_idr`.

Payout state after commit: `status=REQUESTED, batch_id=NULL`. Saruman emits `payout.requested.v1` via outbox in the same transaction.

The balance check and the ledger inserts MUST be in the same serializable transaction (Phase 2 retry helper). Two concurrent reservation requests against the same available balance cannot both succeed.

---

## 4. Payout completion (SETTLED)

Trigger: Saruman consumes `pg.gateway.withdrawal.completed.v1`.

| `operation_key` | derivation |
|---|---|
| `complete_payout:<payout_id>` | UUIDv5 from `("complete_payout", payout_id)` |

| `transaction_type` | `correlation_id` |
|---|---|
| `PAYOUT_COMPLETION` | the inbox event's `event_id` |

**Entries:**

| # | Account | Direction | amount_idr | entry_type | external_ref |
|---|---|---|---|---|---|
| 1 | `streamer_paid(streamer)` | DEBIT | `amount_idr` | `STREAMER_PAID_DEBIT` (terminal) | `payout_id` |
| 2 | `streamer_available(streamer)` | CREDIT | `amount_idr` | (noop terminal: balance already moved in §3, this closes the `streamer_paid` account) | `payout_id` |

**Balance invariant:** terminal entries must zero `streamer_paid` for this payout. Saruman verifies `streamer_paid` is unchanged after commit.

Payout state after commit: `status=SETTLED, settled_at=<now>`. Saruman emits `payout.settled.v1` via outbox.

The historical §3 entries are byte-for-byte unchanged. The §4 entries are new append-only rows.

---

## 5. Payout failure release (FAILED)

Trigger: Saruman consumes `pg.gateway.withdrawal.failed.v1`. Funds reserved in §3 must be returned to `streamer_available` through a new compensation. **No UPDATE/DELETE on the §3 entries.**

| `operation_key` | derivation |
|---|---|
| `fail_payout:<payout_id>` | UUIDv5 from `("fail_payout", payout_id)` |

| `transaction_type` | `correlation_id` |
|---|---|
| `PAYOUT_FAILURE_RELEASE` | the inbox event's `event_id` |

**Entries:**

| # | Account | Direction | amount_idr | entry_type | external_ref | reversal_of |
|---|---|---|---|---|---|---|
| 1 | `streamer_paid(streamer)` | DEBIT | `amount_idr` | `STREAMER_PAID_DEBIT` (reversal) | `payout_id` | link to §3 entries |
| 2 | `streamer_available(streamer)` | CREDIT | `amount_idr` | `STREAMER_AVAILABLE_CREDIT` | `payout_id` | — |

`reversal_of` is set to the corresponding §3 entry IDs in the linked-compensation pattern.

Payout state after commit: `status=FAILED, failure_reason=<from event>`. Saruman emits `payout.failed.v1` via outbox.

Historical §3 entries are byte-for-byte unchanged. The §5 entries are new append-only rows linked through `reversal_of`.

---

## 6. Refund compensation (REFUNDED)

Trigger: Saruman consumes `pg.gateway.refund.completed.v1`. The donation moves to `REFUNDED`. Money flows back to the donor side and out of `streamer_available` / `streamer_pending` proportionally.

| `operation_key` | derivation |
|---|---|
| `donation_refund:<donation_id>:<refund_id>` | UUIDv5 from `("donation_refund", donation_id, refund_id)` |

| `transaction_type` | `correlation_id` |
|---|---|
| `DONATION_REFUND` | the inbox event's `event_id` |

**Entries (full refund of a CHARGED donation):**

| # | Account | Direction | amount_idr | entry_type | external_ref | reversal_of |
|---|---|---|---|---|---|---|
| 1 | `streamer_pending(streamer)` | DEBIT | `net_idr` | `STREAMER_PENDING_CREDIT` (reversal) | `donation_id` | link to §1 entry #2 |
| 2 | `streamer_available(streamer)` | DEBIT | 0 | (no-op; if settled, also reverse §2 entries) | — | — |
| 3 | `platform_revenue()` | DEBIT | `platform_fee_idr` | `PLATFORM_FEE` (reversal) | `donation_id` | link to §1 entry #3 |
| 4 | `donor_cash(streamer)` | DEBIT | `amount_idr` (donor intended) | `REFUND_DEBIT` | `donation_id` | — |
| 5 | `donor_cash(streamer)` | CREDIT | `amount_idr` (returned) | `REFUND_CREDIT` | `refund_id` | — |

For a SETTLED donation refund, replace entries #1/#2 above with the §2 entries' reversal pattern (DEBIT `streamer_available`, CREDIT `streamer_available` as a reversal marker so net balance is restored).

Donation state after commit: `status=REFUNDED, refunded_at=<now>`. Refund row is marked `completed_at=<now>`. Saruman emits `donation.refunded.v1` via outbox.

Historical §1/§2 entries are byte-for-byte unchanged. The §6 entries are new append-only rows linked through `reversal_of`.

---

## 7. Balance and immutability invariants (compile-time)

The Saruman posting engine MUST reject, inside the same DB transaction:

- Any template whose `sum(CREDIT) != sum(DEBIT)`.
- Any template with `amount_idr <= 0` for any entry.
- Any insert whose `operation_key` already exists (UNIQUE constraint at the database, see Phase 1).
- Any `UPDATE` or `DELETE` on `ledger_entries` (existing PostgreSQL RULEs in `02-database-schema.sql`).
- Any state-machine transition that regresses a terminal state (`SETTLED`, `REFUNDED`, `FAILED`).

These checks live in `inflora-saruman/internal/ledger/postings.go` and are tested with property-based and concurrency-based tests (Phase 7 + Phase 9).

---

## 8. Cross-references

- Operation keys derivation: `11-operation-keys.md`.
- Donation/payout/refund state transitions: `09-internal-provider-events.md §9`, plus `02-database-schema.sql` enums.
- Append-only enforcement: `02-database-schema.sql` rules and the Phase 1 schema additions.

*End of posting templates.*