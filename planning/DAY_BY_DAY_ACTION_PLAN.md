# Day-by-Day Action Plan

> **Goal:** Get the MVP donation loop working end-to-end in 13 working days. Layer v2 features in Week 3. Phase 3 ops in Week 4. Production-ready by Day 30.
>
> **Audience:** Marvel + friend (the WS gateway owner).
> **Update cadence:** revise every Sunday after retrospective.
> **Format:** Each day has Marvel tasks, friend tasks, end-of-day check (acceptance criteria), and risks/notes.

---

## TL;DR — The Critical Path

```
Day 1 EOD: contracts PR merged        ← single highest-ROI action
Day 5 EOD: auth endpoint live         ← friend can swap mock → real
Day 13 EOD: 🎉 FIRST END-TO-END DONATION → popup in OBS within 2s
Day 21 EOD: Phase 2 (v2 features) done
Day 26 EOD: Phase 3 (ops layer) done
Day 30 EOD: production-ready + first streamer onboarded
```

If anything slips, **Day 13 is the only true gate** (MVP loop). Everything else can move ±3 days without breaking the launch.

---

## Pre-Day Preparation (Day -1 to 0)

### Marvel
- [ ] Create/fork repos: `ingest-api`, `saruman`, `tolkien`, `palantir-gateway`. Bootstrap with `make` rules (`make test`, `make build`, `make lint`).
- [ ] Set up shared MySQL 8 + NATS 2.10 locally (`brew install mysql nats-server`).
- [ ] Create databases `inflora_dev`, run baseline migrations.
- [ ] Sign up for Midtrans SNAP sandbox account, save `MIDTRANS_SERVER_KEY` to `.env`.
- [ ] Create Gmail account for SMTP fallback.
- [ ] Set up Discord channel `#inflora-dev` for async standups.

### friend
- [ ] Create repo: `ws-gateway` (or whatever you call it).
- [ ] Bootstrap Go project (chi + gorilla/websocket + nats.go + zap + OpenTelemetry).
- [ ] Set up local NATS connection.

### Both
- [ ] 60-min joint reading session: walk through `planning/schemas/INDEX.md` and `08-flow-diagrams.md` Flow 1 + Flow 2.
- [ ] Agree on contracts PR scope: just event envelope + topics + WS protocol + token format (no payload details yet).

---

## Week 1 — Foundation (Day 1-5)

### Day 1 — Contracts freeze + scaffolding

**Theme:** Unblock the friend. Get schemas locked.

**Marvel (4h):**
- [ ] Open PR in almanac repo: "feat: freeze v2 contracts (envelope, topics, WS frames)"
- [ ] Files touched: `00-frozen-contracts.md` (no edits, just confirm), `01-event-catalog.md` (Mark each event with FROZEN status), `05-websocket-protocol.md` (Mark each frame FROZEN).
- [ ] Add CHANGELOG entry.
- [ ] Ping friend for review.

**friend (4h):**
- [ ] Read `00-frozen-contracts.md` + `05-websocket-protocol.md` fully.
- [ ] Read `08-flow-diagrams.md` Flow 2 (WS connect & catch-up) carefully.
- [ ] Review contracts PR. Comment on anything wrong/missing.

**EOD check:** contracts PR open + has at least one 👍 from friend.

**Risk:** If friend raises blocking concerns, address same day. Don't let PR sit overnight.

---

### Day 2 — DB tables + WS gateway scaffold

**Marvel (6h):**
- [ ] Migration runner setup in saruman (Go binary `cmd/migrate`).
- [ ] Create initial migrations: `00001_initial.up.sql` (enums + streamers, sessions, idempotency, ledger_accounts, ledger_entries, donations, refunds, payouts tables). Apply v2 schema.
- [ ] Wire saruman HTTP server (chi + zap + config).
- [ ] Health check endpoint: `GET /healthz`, `GET /readyz`.
- [ ] Smoke test: `make migrate && make run` → `curl /healthz` returns 200.

**friend (6h):**
- [ ] WS gateway scaffold:
  - `cmd/gateway/main.go` (HTTP server + WS upgrade handler).
  - `internal/ws/hub.go` (skeleton: `map[streamerID]*Hub`).
  - `internal/auth/validate.go` (calls tolkien endpoint — fake for now).
  - [ ] WebSocket upgrade works, accepts token from query string, returns 401 on missing.
- [ ] Hello frame fires on connect.

**EOD check:** Both can run their respective services locally + `/healthz` returns 200 + WS gateway accepts connection.

---

### Day 3 — Auth tables + WS gateway heartbeat

**Marvel (6h):**
- [ ] Migration `00002_auth.up.sql` (sessions table — already in initial, ensure indexes).
- [ ] tolkien: signup endpoint `POST /v1/auth/signup` (argon2id password, INSERT streamers + sessions, return session_token).
- [ ] tolkien: login endpoint `POST /v1/auth/login`.
- [ ] tolkien: GET /v1/me endpoint.
- [ ] Token validation endpoint `POST /v1/internal/validate-overlay-token` (returns 200 if token valid + not expired).

**friend (6h):**
- [ ] WS gateway: heartbeat every 10s.
- [ ] WS gateway: client pong response.
- [ ] WS gateway: 30s silent → close 4408.
- [ ] WS gateway: connect hello frame includes high_water_mark (placeholder = 0 for now).

**EOD check:** Signup works (create streamer, get session_token). WS heartbeat works in wscat test.

---

### Day 4 — Overlay token + WS auth integration

**Marvel (6h):**
- [ ] tolkien: overlay token issuance endpoint `POST /v1/me/overlay-token/rotate`.
- [ ] Returns full token (shown once) + last4 + URL `wss://...?token=ok_xxx`.
- [ ] Token validation cache (60s Redis or in-memory).
- [ ] Test: rotate → token works in WS gateway (friend tests).

**friend (4h):**
- [ ] WS gateway: validate token via tolkien endpoint on connect.
- [ ] Cache 60s.
- [ ] Reject invalid token with close 4401.

**Both (2h):**
- [ ] **Sync 2 (Day 5 prep):** end-to-end test. Marvel issues token → friend connects with that token → hello frame received.

**EOD check:** Streamer can issue overlay token; WS gateway validates against tolkien.

---

### Day 5 — Sync 2: WS gateway uses real auth

**Marvel (3h):**
- [ ] Audit log on token rotation (audit_log INSERT).
- [ ] Publish `overlay.token.rotated.v1` event (consumed by saruman to invalidate cache).
- [ ] Bug fixes from Sync 2.

**friend (3h):**
- [ ] Swap mock auth → real auth.
- [ ] Subscribe to `overlay.token.rotated.v1` for cache eviction.
- [ ] Load test: 100 concurrent WS connections, validate heartbeat.

**Both (4h):**
- [ ] **Sync 2 meeting (1h):** confirm integration works.
- [ ] Both write integration test: token issuance → WS connect → hello frame.
- [ ] Update runbook with auth integration details.

**EOD check:** Integration test passes. Cache eviction on token rotation works.

---

## Week 2 — Donation Loop (Day 6-13)

### Day 6 — Webhook ingest scaffold + Midtrans client

**Marvel (8h):**
- [ ] ingest-api: webhook endpoint `POST /v1/webhooks/payment` (signature verify, idempotency INSERT, return 200).
- [ ] palantir-gateway: CreateTopUp gRPC method + Midtrans SNAP client.
- [ ] Test: send fake Midtrans webhook → ingest-api accepts, idempotency row inserted, palantir called.
- [ ] Test: replay same webhook → idempotency hit → returns cached 200.

**EOD check:** Webhook ingest + Midtrans sandbox integration works.

---

### Day 7 — Donation intent flow + WS subscribe

**Marvel (8h):**
- [ ] ingest-api: `POST /v1/donations` (validate, INSERT donations, call palantir CreateTopUp, return payment_url).
- [ ] saruman: NATS subscriber for `pg.gateway.topup.completed`.
- [ ] saruman: SettleDonation gRPC method (called by ingest-api after webhook).
- [ ] saruman: SettleDonation publishes `donation.charged.v1`.
- [ ] Test: real Midtrans sandbox donation → saruman consumes → publishes.

**friend (parallel, optional):**
- [ ] Read donation.charged.v1 payload structure.

**EOD check:** Real Midtrans sandbox donation triggers `donation.charged.v1` publish.

---

### Day 8 — Donation service + ledger

**Marvel (8h):**
- [ ] saruman: SettleDonation implements BEGIN TX → INSERT donations + INSERT ledger_entries x 2 + UPDATE ledger_accounts → COMMIT.
- [ ] Idempotency at SARuman (donot-save twice for same donation_id).
- [ ] Test: donation.charged fires once per donation, ledger balances correct.
- [ ] Manual ledger invariant check: `SUM(DEBIT) == SUM(CREDIT)` per account.

**EOD check:** Double-entry ledger commit works. Balances correct after multiple test donations.

---

### Day 9 — WS gateway subscribe + initial fanout

**friend (8h):**
- [ ] WS gateway: NATS consumer subscribes to `donation.charged.v1.>`.
- [ ] Per-streamer hub: route event by `streamer_id` → marshal WS frame → send to all that streamer's clients.
- [ ] Sequence number increment (atomic counter per streamer).
- [ ] Test: real donation → WS frame arrives at OBS client within 2s.

**Marvel (parallel):**
- [ ] Add metrics: donations_per_min, ledger_balance_idr_total.

**EOD check:** WS frame arrives at OBS test client (headless Chromium) within 2s of real donation.

---

### Day 10 — Donor page + OBS overlay renderer

**Marvel (6h):**
- [ ] Donor landing page `/d/<streamer_id>` (HTML + minimal JS). Form: amount, name, message.
- [ ] Submit → POST /v1/donations → redirect to Midtrans Snap.

**friend (6h):**
- [ ] OBS overlay renderer (Vite + TS + Canvas):
  - DOM container with `display_duration_sec` (placeholder = 10s at MVP).
  - Show donor name, amount, message.
  - Auto-dismiss after 10s.
  - Fade-in / fade-out animations.

**EOD check:** Donor can submit form on `/d/<streamer>` → redirected to Midtrans.

---

### Day 11 — Streamer signup + balance UI

**Marvel (6h):**
- [ ] Streamer signup HTML form (separate page or part of dashboard).
- [ ] Streamer dashboard minimal: balance read, recent donations list.
- [ ] "Add to OBS" button: generates URL with overlay token, copies to clipboard.

**friend (3h):**
- [ ] OBS overlay: connect — show "🟢 Connected" pill when hello frame arrives.
- [ ] OBS overlay: disconnect — show "🔴 Disconnected" pill.

**EOD check:** Streamer can sign up, get overlay URL, paste into OBS.

---

### Day 12 — E2E smoke prep

**Both (8h):**
- [ ] Write integration test script (`make smoke`):
  - Sign up test streamer.
  - Generate overlay token.
  - Connect WS client.
  - Send test donation through Midtrans sandbox.
  - Assert WS frame received within 2s.
  - Assert ledger entries created.
  - Assert balance updated.
- [ ] Run smoke test in CI on every commit.

**EOD check:** Smoke test passes locally + in CI.

---

### Day 13 — 🎉 FIRST END-TO-END DONATION

**Both (4h):**
- [ ] **Sync 3 meeting (1h):** run smoke test together, observe popup.
- [ ] **Real OBS Studio test:** paste URL into OBS Studio, trigger real Midtrans sandbox donation, observe popup.
- [ ] Record a 30-sec video for the team.

**Marvel (2h):**
- [ ] Update README with "🎉 MVP loop working" badge.

**friend (2h):**
- [ ] Update OBS overlay README with setup instructions.

**EOD check:** Real money, real OBS, popup within 2s. **MVP DEFINITION OF DONE met.**

**🎉 CELEBRATE.**

---

## Week 3 — v2 Features (Day 14-21)

### Day 14 — Settlement webhook handling

**Marvel (8h):**
- [ ] saruman: NATS consumer for `pg.gateway.topup.settled` (different from completed).
- [ ] On settle: BEGIN TX → UPDATE donations settlement_status=SETTLED → INSERT ledger_entries x 2 (move STREAMER_PENDING → STREAMER_AVAILABLE) → COMMIT.
- [ ] Publish `donation.settled.v1.<streamer_id>`.
- [ ] Test: Midtrans sandbox delayed settlement → STREAMER_AVAILABLE updates correctly.

**EOD check:** STREAMER_AVAILABLE increases when settlement webhook fires.

---

### Day 15 — Settlement WS notification

**friend (6h):**
- [ ] WS gateway: new frame type `donation_settled` (text only, no animation).
- [ ] OBS overlay: render 2-sec "✅ Settled" toast.

**Marvel (2h):**
- [ ] Streamer settings: `notify_on_donation` toggle (default true).

**EOD check:** Settle notification visible in OBS.

---

### Day 16 — Email service integration

**Marvel (8h):**
- [ ] Choose email provider: SES (production), MailHog (dev).
- [ ] saruman: `email_service.Send()` with idempotency on donation_id.
- [ ] email_receipts table populated.
- [ ] Receipt template (Indonesian, HTML + text).
- [ ] Trigger after donation.charged.v1.

**EOD check:** Donation → receipt email received in test inbox within 5s.

---

### Day 17 — Email retry + bounce handling

**Marvel (8h):**
- [ ] Email retry: 3 attempts with exponential backoff on 5xx.
- [ ] Bounce webhook handler (provider-specific).
- [ ] email_receipts status updates.
- [ ] Test: invalid email → 4xx → status=FAILED, no retry.

**EOD check:** Bounce handling works.

---

### Day 18 — OBS voice rendering

**friend (8h):**
- [ ] OBS overlay: read `voice_url` from donation frame.
- [ ] HTML5 Audio: `new Audio(voice_url).play()` on receipt.
- [ ] Auto-stop on display_duration boundary.
- [ ] Test with stub voice file (hosted in CDN or `/static/voice/test.mp3`).

**EOD check:** Voice plays on donation.

---

### Day 19 — OBS YouTube rendering

**friend (8h):**
- [ ] OBS overlay: read `youtube_url` + `youtube_start_sec` + `youtube_end_sec`.
- [ ] Embed YouTube IFrame with `?start=X&end=Y` params.
- [ ] Auto-remove after display_duration_sec.
- [ ] Test with real YouTube link.

**EOD check:** YouTube clip plays on donation.

---

### Day 20 — Streamer settings UI

**Marvel (8h):**
- [ ] Dashboard: settings page (display rate, allowed content toggles, min/max donation).
- [ ] PUT /v1/me/settings.
- [ ] Publish `streamer.settings.updated.v1` (realtime-gateway invalidates cache).
- [ ] Test: change display rate → new donations use new rate immediately.

**EOD check:** Settings changes apply to new donations in real-time.

---

### Day 21 — Phase 2 done

**Both (4h):**
- [ ] **Phase 2 retrospective:** what's working, what's not, what's next.
- [ ] Update smoke test to cover Phase 2 (settlement, email, voice/youtube, settings).

**EOD check:** All Phase 2 features in smoke test. **Definition of done for v2 met.**

---

## Week 4 — Operations Layer (Day 22-26)

### Day 22 — Holds (table + endpoints)

**Marvel (8h):**
- [ ] fund_holds table migration.
- [ ] `POST /v1/admin/holds` + `GET /v1/admin/holds` + `DELETE /v1/admin/holds/:id`.
- [ ] Saruman payout creation rejects if active holds for streamer (403 STREAMER_HOLD_ACTIVE).
- [ ] Audit log on hold create/release.

**EOD check:** Held place admin can put streamer on hold; payouts rejected.

---

### Day 23 — Holds (ledger + auto-expiry)

**Marvel (8h):**
- [ ] Optional: ledger entries on hold creation (HOLD_DEBIT + HOLD_escrow CREDIT).
- [ ] Cron job: every hour, expire holds past `expires_at`.
- [ ] Test: hold expires automatically after expiry.

**EOD check:** Auto-expiry works.

---

### Day 24 — Batches table + admin endpoint

**Marvel (8h):**
- [ ] payout_batches table migration.
- [ ] `POST /v1/admin/payout-batches` (auto_select or manual payout_ids).
- [ ] FIFO selection query (ORDER BY requested_at).
- [ ] Test: 5 REQUESTED payouts → batch created with FIFO order.

**EOD check:** Batch creation works FIFO.

---

### Day 25 — Batches execute + provider integration

**Marvel (8h):**
- [ ] `POST /v1/admin/payout-batches/:id/execute`.
- [ ] palantir-gateway: bulk payout API (provider-specific, e.g., Midtrans Disbursement).
- [ ] UPDATE payouts SET status=PROCESSING.
- [ ] Publish `payout.batch.executed.v1` per payout.

**EOD check:** Bulk transfer executes. Single provider call → multiple bank transfers.

---

### Day 26 — Load test + runbook + on-call

**Both (8h):**
- [ ] Run k6 load test at 5x peak (2,500 donations/sec, 10k WS).
- [ ] Identify bottleneck. Fix or document.
- [ ] Fill runbook per service (RUNBOOK.saruman.md, etc.).
- [ ] Run on-call drill (simulate SEV-2 incident, both respond).

**EOD check:** Load test passes (p99 < 2s). Runbook complete. Drill complete.

---

## Week 5 — Polish (Day 27-30)

### Day 27 — Bug bash

**Both (8h):**
- [ ] Triage all known issues from smoke tests + retrospectives.
- [ ] Fix highest-priority bugs.
- [ ] Run smoke test again.

**EOD check:** No SEV-1 or SEV-2 bugs open.

---

### Day 28 — Onboard first streamer (test)

**Marvel (4h):**
- [ ] Onboard 1 friendly streamer as alpha tester.
- [ ] Walk through signup, OBS setup, first donation.

**friend (4h):**
- [ ] Observe: are OBS instructions clear? Anything confusing?

**EOD check:** Alpha streamer has working OBS overlay.

---

### Day 29 — Production prep

**Both (8h):**
- [ ] Set up staging environment.
- [ ] Set up monitoring + alerts (Prometheus + OpenTelemetry + Grafana).
- [ ] Set up CI/CD (GitHub Actions → auto-deploy to staging).
- [ ] Runbook tested in staging.

**EOD check:** Staging ready for production cutover.

---

### Day 30 — Production cutover

**Both (4h):**
- [ ] Cutover: switch Midtrans to production keys.
- [ ] First real-money test (Rp 10.000 donation).
- [ ] Monitor for 24h.

**Definition of done for production:**
- [ ] Real money works end-to-end
- [ ] No SEV-1 SEV-2 incidents in 24h
- [ ] At least 1 streamer onboarded + using overlay
- [ ] On-call rotation live
- [ ] Runbook complete
- [ ] Smoke test green in CI
- [ ] Load test passes at 5x peak

**🎉 MVP LAUNCHED.**

---

## Daily Standup Format (Discord `#inflora-dev`)

```markdown
**YYYY-MM-DD — Day N standup**

@marvel
- Yesterday: [bullet]
- Today: [bullet]
- Blockers: [bullet or "none"]

@friend
- Yesterday: [bullet]
- Today: [bullet]
- Blockers: [bullet or "none"]
```

Post by 09:00 WIB each day.

---

## Weekly Retrospective (Friday afternoon, 30 min)

- [ ] What went well?
- [ ] What went poorly?
- [ ] What to change next week?
- [ ] Update this action plan if needed.

---

## Definition of Done (per phase)

### Phase 1 (Day 13) — MVP
- [ ] Streamer signs up via dashboard
- [ ] Streamer pastes URL into OBS Studio, sees "Connected" pill
- [ ] Donor visits `/d/<streamer>`, pays via Midtrans Snap
- [ ] **Popup appears in OBS within 2 seconds**
- [ ] Two ledger entries created
- [ ] Streamer sees balance in dashboard
- [ ] Smoke test green in CI

### Phase 2 (Day 21) — v2 features
- [ ] Settlement webhook updates STREAMER_AVAILABLE
- [ ] Email receipt sent within 5s
- [ ] Voice plays in OBS
- [ ] YouTube clip plays in OBS
- [ ] Settings change applies in real-time
- [ ] Smoke test covers all of Phase 2

### Phase 3 (Day 26) — Operations layer
- [ ] Admin can put streamer on hold
- [ ] Payouts rejected during hold
- [ ] Admin can create payout batch (FIFO)
- [ ] Bulk execute single provider call
- [ ] Load test passes at 5x peak
- [ ] Runbook filled per service
- [ ] On-call drill complete

### Phase 4 (Day 30) — Production
- [ ] All Phase 1-3 done
- [ ] Real money works
- [ ] Staging + prod environments live
- [ ] CI/CD green
- [ ] First streamer onboarded

---

## Risks & Contingencies

| Risk | Likelihood | Mitigation |
|---|---|---|
| Friend slips Day 7-9 (WS gateway) | Medium | Marvel mocks WS subscriber for E2E smoke. Friend can catch up Day 10-12. |
| Midtrans sandbox flaky | Low | Pivot stub as fallback (provider.Stub). |
| DB schema changes mid-sprint | Low | Migrations are forward-only. Schema is frozen in almanac. |
| Settlement webhook doesn't fire | Medium | Mock settlement via admin endpoint (POST /v1/admin/donations/:id/settle-now). |
| WS reconnect storm after deploy | Medium | Friend: implement jitter. Marvel: deploy one shard at a time. |
| Provider account approval | High | Apply Midtrans production Day 21. Approval takes 1-2 weeks. |
| YouTube IFrame blocked | Low | Use IFrame API. Test in actual OBS Browser Source (not Chrome). |

---

## What NOT to build (even though schema supports)

| Feature | Why not now |
|---|---|
| Multi-payment-provider | Schema supports but single provider (Midtrans) at MVP |
| Multi-region | Schema supports but single region (Singapore) at MVP |
| KYC automation | Schema supports but manual review at MVP |
| Full fraud scoring | Inline velocity rules only at MVP |
| Analytics dashboard | SQL queries at MVP |
| Goal meters / subscriptions / moderation | out of scope entirely |
| Custom CSS per streamer | hardcoded visual at MVP |
| Multiple themes | one theme at MVP |

---

## Reading this document

- **Both:** read Pre-Day prep + Day 1 + Day 13 + Day 30 (the milestones).
- **Marvel:** read all days you're working (Day 1-26 in parallel).
- **friend:** read all days you're working (Day 2-9, 18-19, 26).
- **Updates:** revise this doc every Sunday retrospective.
- **Source of truth:** when in doubt, this doc wins.

---

*Pin this file. This is the operational contract for the next 30 days. Update at retrospectives.*