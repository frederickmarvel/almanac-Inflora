# Parallel Work Plan — Marvel + Friend

> **Goal.** Maximize throughput while the friend builds the OBS overlay WebSocket gateway (WS hub, per-streamer isolation, token auth, reconnect, heartbeat).
> **Marvel's job.** Build everything that does NOT touch the gateway's responsibility surface, in priority order.
> **Sync points.** Agreed before each integration milestone — see §Sync.

---

## Friend's scope (do NOT touch — Marvel's exclusion zone)

- Per-streamer WebSocket hub (`map[streamerID]*Hub` with `sync.RWMutex` per hub)
- OBS overlay WebSocket endpoint + protocol
- Reconnect with exponential backoff client behavior
- Heartbeat (10s tick, 30s silent = disconnected)
- WebSocket auth handshake (`?token=<...>` in URL)
- Per-streamer fanout logic (event → all that streamer's clients)
- Sequence numbering on overlay events (catch-up replay)

---

## Marvel's scope (independent tracks, ordered)

### Track 0 — UNBLOCK the friend (Day 1) — CRITICAL

> Without these, the friend can't start coding the WS gateway. Land them Day 1, agreed by both, then merge into the friend's repo as a contract PR.

- [ ] **Event envelope schema** — frozen JSON, versioned, in `packages/proto/`
- [ ] **Topic naming convention** — `<domain>.<entity>.<verb>.<version>` with examples
- [ ] **WebSocket protocol spec** — frame format, hello/donation/error/heartbeat types
- [ ] **Token format spec** — opaque, base64url, 256-bit, prefix `ok_` for sanity
- [ ] **Sequence numbering convention** — per-streamer monotonic `seq` on every overlay frame
- [ ] **PR opened** with the contract — friend ack's and starts coding Day 2

**Why this is first:** the WS gateway consumes `donation.charged.v1` events. If the schema changes mid-build, the friend rebuilds. Pin it day 1.

---

### Track 1 — Database + migrations (Day 2-3)

- [ ] `streamers` table — `id`, `display_name`, `email`, `created_at`, `is_active`
- [ ] `sessions` table — `id`, `streamer_id`, `token_hash`, `expires_at`, `last_seen_at`
- [ ] `idempotency` table — UNIQUE on `(provider, transact_id)`, `payload_hash`, `created_at`
- [ ] `ledger_entries` table — `id`, `streamer_id`, `direction`, `amount`, `currency`, `entry_type`, `external_ref`, `created_at`
- [ ] `ledger_accounts` table — per-streamer per-currency balance, with `version` column for optimistic locking
- [ ] Migrations runner — Go binary, up/down, single source of truth
- [ ] Documented schema ownership (who owns which table)

**Why this is parallel:** schemas don't depend on the WS gateway. Friend will need `streamers` and `sessions` for token validation, but read-only.

---

### Track 2 — Auth + token service (Day 4-5)

- [ ] Token issuance — `POST /v1/auth/login`, returns session
- [ ] Token rotation — `POST /v1/me/overlay-token/rotate`, returns new `ok_<token>` + last4
- [ ] Token validation endpoint — `POST /v1/internal/validate-overlay-token`, returns `streamer_id` or 401
- [ ] Token storage — `argon2id(password)` for streamer passwords; `bcrypt(token)` for session tokens
- [ ] Rate limit on login (5/min/IP) — guard against credential stuffing
- [ ] Audit log on every token rotation

**Sync point with friend:** Day 5 — friend can now wire token validation into the WS gateway handshake.

---

### Track 3 — Streamer dashboard (Day 6-9)

> Plain Next.js / SvelteKit. Reads only. No WS, no business logic.

- [ ] Sign-up / log-in pages
- [ ] Dashboard home — shows balance, recent donations, "Add to OBS" CTA
- [ ] "Add to OBS" button — generates one-click URL with embedded token, copies to clipboard
- [ ] Settings — alert theme picker (defer multiple themes), notification toggles
- [ ] "Rotate overlay token" button — calls Track 2 endpoint
- [ ] Responsive, mobile-friendly (streamers check it on phone often)

**Why this is parallel:** frontend-only, no shared mutable state with the WS gateway.

---

### Track 4 — Donor landing page (Day 10-11)

> Public page per streamer. Donor lands here, picks amount, message, pays.

- [ ] `/d/<streamer_id>` page — streamer avatar, name, recent donations ticker
- [ ] Amount picker — preset buttons (Rp 10k, 25k, 50k, 100k, custom
- [ ] Donor name + message input
- [ ] "Send" → redirect to payment provider (Midtrans Snap / Xendit invoice)
- [ ] "Thank you" confirmation page
- [ ] Spam protection — CAPTCHA at the form, rate limit per IP

**Why this is parallel:** donor flow is independent of OBS overlay path.

---

### Track 5 — Webhook ingest (Day 12-13)

> Receives callbacks from the payment provider. Idempotent at the edge.

- [ ] `POST /v1/webhooks/payment` — receives provider webhook
- [ ] Signature verification — HMAC-SHA256 with shared secret
- [ ] Idempotency check — INSERT ON CONFLICT DO NOTHING on idempotency table; 200 OK on retry
- [ ] Validate payload — amount, currency, donor fields
- [ ] Publish `donation.intent.created.v1` to NATS (or call donation service directly)
- [ ] Reject malformed payloads with 400 + log
- [ ] Rate limit per provider (sane defaults)

**Why this is parallel:** webhook ingestion doesn't depend on WS gateway. Friend's gateway consumes downstream of this.

---

### Track 6 — Ledger + donation service (Day 14-17)

> The money path. Most careful code in the system.

- [ ] Donation service — `CreateDonation(streamer_id, amount, donor, message)` → idempotent
- [ ] Ledger write — within a serializable transaction:
  - INSERT `ledger_entries` (donor_cash +X, streamer_pending +X)
  - UPDATE `ledger_accounts` SET balance = balance + X, version = version + 1 WHERE version = ?
- [ ] Publish `donation.charged.v1` to NATS — atomic with ledger commit (transactional outbox pattern)
- [ ] Reconciliation job — daily, flags imbalance > Rp 1.000
- [ ] Refund path — `CreateRefund(donation_id)` → reversal entries, publish `donation.refunded.v1`
- [ ] **Acceptance test:** charge → ledger → publish → WS → popup (E2E with friend's gateway)

---

### Track 7 — Load test + smoke test (Day 18-19)

- [ ] k6 script — simulate 2,500 donations/sec sustained for 5 min
- [ ] Go WS load test — 10k concurrent OBS clients, validate reconnect storm
- [ ] End-to-end smoke script — `make smoke` runs all paths
- [ ] Document expected headroom (current peak vs. ceiling)

---

## Sync points (when Marvel meets Brown)

| Sync | Friend state | Marvel state | What we agree |
|---|---|---|---|
| **Sync 1 — Day 1 EOD** | Friend has read contracts PR | Marvel has PR open with frozen schemas | Friend acks contracts PR |
| **Sync 2 — Day 5 EOD** | Friend has WS gateway w/ mock auth | Marvel has token validation endpoint live | Friend swaps mock → real endpoint |
| **Sync 3 — Day 17 EOD** | Friend has WS gateway wired to NATS | Marvel has ledger publishing `donation.charged.v1` | First real donation end-to-end |
| **Sync 4 — Day 19 EOD** | Friend has WS gateway load tested | Marvel has E2E smoke green | MVP definition-of-done met |

---

## Dependency graph (who blocks whom)

Friend blocks nothing for Marvel.
Marvel blocks the friend on:
- Track 0 contracts → before Day 2 (friend can start coding)
- Track 2 token validation endpoint → before Day 5 (friend can integrate real auth)

Friend unblocks Marvel on:
- WS callback WebSocket events flowing → Day 17 (Marvel can run end-to-end test)
- WS callback load test results → Day 19 (Marvel can prove capacity)

---

## What Marvel should NOT do

- ❌ Touch anything in the friend's WS gateway repo
- ❌ Change event schemas after Track 0 freeze (use `v2` topic, don't mutate `v1`)
- ❌ Add NATS consumers that compete with the friend
- ❌ Deploy on a Friday without telling the friend
- ❌ Skip the smoke test → reachability smoke after Sync 2

---

## What the friend should NOT do

- ❌ Define events/topics/tokens on their own — must come from Marvel's Track 0
- ❌ Hardcode streamer IDs in test fixtures that Marvel also uses
- ❌ Skip the Day 5 integration sync (otherwise Marvel can't validate your auth wiring)
- ❌ Block on Marvel's slower tracks — work on mock data until Sync 3

---

## Communication cadence

- **Daily async standup** — both post in `#inflora-dev`: yesterday / today / blockers. <5 min each.
- **Weekly sync** — 30 min, video. Walk through what's merged, what's next.
- **PR reviews** — within 4 working hours of opening. Small PRs (>300 LOC = split).
- **Incident bridge** — any SEV-1, both jump on the call.

---

## Risk register (top 3)

| Risk | Mitigation |
|---|---|
| Friend waits on Marvel's Track 0 contracts | Marvel drops contracts Day 1 morning, not EOD |
| Event schema drift mid-build | Use `v2` topic instead of mutating `v1`; both review schema changes in PR |
| WebSocket reconnect storm after NATS restart | Friend adds jitter to backoff (already standard); Marvel sets NATS to drain cleanly |

---

## Definition of done — combined tracks

When all of these are green, MVP is shippable:

1. Streamer signs up via dashboard
2. Streamer clicks "Add to OBS", pastes URL into OBS, sees "connected"
3. Donor opens `/d/<streamer_id>`, pays Rp 10.000 via Midtrans Snap
4. Donation popup appears in OBS within 2 seconds
5. Streamer dashboard balance reflects (net of platform fee)
6. Two matching ledger entries exist (donor_cash +X, streamer_pending +X)
7. Load test sustains 5x peak for 5 min with p99 < 2s
8. Runbook + on-call checklist live; one dry-run incident resolved without escalation

---

*End of plan. Update this file whenever the dependency graph changes.*