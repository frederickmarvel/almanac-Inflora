# 05 — Phases and Gates (execution sequence, verification, rollout, open decisions)

> Planning only. This file sequences `00`–`04` into implementable phases with **exit gates**. The implementer is another AI + engineers: it must never guess — every phase lists exact files/contracts to read first and exact acceptance tests.
> Convention: phases run in order; a phase is not "done" until its gate list is green AND the reviewer merges. **"Phase N"** anywhere in this package means "any future phase beyond G that the owner schedules later" — it is deliberately outside this plan. **Red-line rule: no phase may silently change a frozen contract; any mismatch becomes a `CONTRACT_DRIFT.md` row first.**

---

## 0. Pre-flight (must exist before any code)

- [ ] Reviewer acks decisions A-1…A-10 (`01 §1`), N-1…N-5 (`02 §1`), and the drift rows D-024…D-030 (`01 §12`, `03 §11`) in `CONTRACT_DRIFT.md`.
- [ ] Fix migration-test drift first (so later gates are meaningful): `inflora-saruman/internal/migrate/runner_test.go` expectations must be reconciled with the actual `00001…00008` + seeded enums before adding `00009+` (00 §6.7).
- [ ] Go toolchain on the implementer machine (unavailable in this planning environment — 00 §9).
- [ ] `frontend/docs/AUTH.md` WIP branch updated alongside code, not after.
- [ ] Template for every test below: name = `TestPhaseX_<behavior>`, file = `<service>/internal/...`, tag = `@phaseX`.

## 1. Phase A — Database foundation (RBAC + withdrawal robustness schema)

Files: `inflora-saruman/migrations/00009_firebase_identities.up/.down.sql` … `00012_withdrawal_robustness.up/.down.sql` per `01 §4` and `03 §10`; `inflora-saruman/migrations/embed.go` regenerate; `runner_test.go` recount.

Gate A:
- [ ] `make test` (saruman) green including migration up/down/up cycle for every new file (the existing runner integration test pattern, extended).
- [ ] Citizen schema check: pg catalog query asserting FKs added (`payouts.batch_id`, `admin_roles.*`, `role_permissions.*`), UNIQUE `(provider_name, saruman_payout_id)`, and `app_role` enum values exactly `{SUPERADMIN, ADMIN, USER}`.
- [ ] Legacy `admin_role` still present (rollback window) — its drop is Phase G, not now.
- [ ] No `identities` polymorphic CHECK constraint if the reviewer chose the column-on-both-tables variant (`01 §4` note) — implementation must match the acked decision.

## 2. Phase B — Saruman payout engine (pure core, offline-safe)

Read first: `10-posting-templates.md`, `11-operation-keys.md`, `09-internal-provider-events.md`, `03-withdrawals.md` §2–§5.
Files: `inflora-saruman/internal/service/payout.go` (commands + transition guard), `internal/ledger/postings.go` (add §3/§4/§5 compiled templates + balance checks per `10 §7`), `internal/repo/payouts.go`, `internal/subscriber/withdrawal.go` (consume `pg.gateway.withdrawal.*`), `internal/cron/sweep.go` (leases), `internal/handler/` command HTTP surface, WIRE_GUIDE §5 row for the chosen command transport.

Gate B:
- [ ] Property test: request→settle and request→fail posting pairs net to zero and respect append-only (RULEs) — mirrors existing `postCapture` balance assertion.
- [ ] Concurrency: 2 simultaneous `CreatePayout` with exactly-enough balance → one wins, one `INSUFFICIENT_BALANCE`.
- [ ] State machine table test: every illegal transition rejected; `SETTLED`/`FAILED` immutable.
- [ ] Consumer dedup: duplicate `completed.v1` → single §4 posting (operation key).
- [ ] No tolkien code changed in this phase; saruman compiles standalone.

## 3. Phase C — Tolkien facade rewire + payout user API

Files: `inflora-tolkien/internal/httpapi/payout.go` NEW (`POST /v1/me/payouts`, `GET /v1/me/payouts` — user scope only), `internal/httpapi/donations.go` NEW (`GET /v1/me/donations` cursor-paginated), `internal/app/app.go` (call Saruman commands, never SQL-financial writes), `internal/app/batches.go|holds.go` → **refactor R-1** (`03 §1`): tolkien handlers become facade; all `payouts`/`payout_batches`/ledger writes move to Saruman commands.
**Interim auth for the existing holds/batches endpoints** (until Phase D lands `requirePerm`): switch them from `admin()` (internal key + `X-Actor-Id`) to the existing `adminSession` (`ak_`) with a role check on `AdminPrincipal.Role` (loaded today, never enforced — enforce as bridge). This closes the actor-spoofing gap one phase earlier; `requirePerm`+Firebase then replace it wholesale in Phase D. `X-Actor-Id` acceptance from the browser is removed in this phase.

Gate C:
- [ ] Grep gate: `inflora-tolkien` contains zero `INSERT|UPDATE|DELETE` statements against `payouts|payout_batches|ledger_entries|ledger_accounts|ledger_transactions` (static check script added to CI).
- [ ] BDD tests for `POST /v1/me/payouts` error matrix: `422 BELOW_MIN_WITHDRAWAL`, `422 INSUFFICIENT_BALANCE`, `403 STREAMER_HOLD_ACTIVE`, `404 BANK_ACCOUNT_NOT_FOUND`, idempotent replay with `Idempotency-Key`.
- [ ] Hold TOCTOU test: ACTIVE hold appears between request-eligibility check and reserve → rejection (serializable TX).
- [ ] Existing `integration_test.go` (tolkien) still green with admin hold/batch handlers calling Saruman commands (test doubles acceptable where Saruman is out of scope; no raw-money SQL in doubles).
- [ ] Holds/batches endpoints reject calls without a valid `ak_` session (401) and calls whose `AdminPrincipal.Role` lacks the mapping (`403`), including a missing/forged `X-Actor-Id` request.

## 4. Phase D — Firebase Auth + RBAC enforcement

Files: `01 §11` list. Order inside the phase: (1) Firebase middleware + verification tests; (2) `POST /v1/auth/firebase/exchange` + bridge; (3) role/permission resolution (`role_permissions`) + `requirePerm` + backoffice user management endpoints; (4) wire `requirePerm` onto every admin/backoffice endpoint (replacing the Phase-C interim `adminSession` role check where Firebase ID tokens are the credential); (5) bootstrap CLI. Frontend Firebase SDK work moves to Phase F so the two halves land together.

Gate D:
- [ ] Token table tests: expired, wrong-aud, wrong-iss, RS256 enforcement, garbage, revoked (`tokensValidAfterTime`/auth_time when enabled).
- [ ] Escalation suite: USER token → all `/v1/backoffice/*` and `/v1/admin/*` 403; ADMIN token → `User:Manage`/`Admin:Manage`/`Audit:Read` 403; legacy FINOPS-mapped operator → donation-monitoring allowed, streamer management denied; deactivated operator → 401/403 within expected window.
- [ ] `FIREBASE_VERIFY_MODE=degraded` tested: bridge works, new logins denied, WARN audit rows written.
- [ ] Break-glass account login recorded + alert threshold wired.
- [ ] Bootstrap CLI: `tolkien admin bootstrap --firebase-uid` produces first SUPERADMIN; second bootstrap refused while a SUPERADMIN exists (test).
- [ ] Phase-C interim auth still works (bridge `ak_` accepts both paths; telemetry counts each).

## 5. Phase E — Backoffice operations + batching

Files: `inflora-tolkien/internal/httpapi/backoffice*.go` (endpoints in `02 §7`), `internal/app/backoffice.go`, palantir `internal/grpc/withdrawal.go` (wire `CreateWithdrawal`/`SettleWithdrawal` + `GetWithdrawalStatus` D-030), `inflora-shared/proto/palantir/v1/withdrawal.proto` (add `GetWithdrawalStatus`), events catalog alignment for batch-resolution ownership (D-028).

Gate E:
- [ ] Batch end-to-end (Pivot provider): N REQUESTED → DRAFT (auto_select caps honored) → submit → approve by different actor → execute → per-payout PROCESSING → Pivot result events → batch COMPLETED; ledger zero-sum proof.
- [ ] `MAKER_CHECKER_CONFLICT` on same-actor approve; `PAYOUT_NOT_BATCHABLE` on illegal members; `BATCH_HAS_HOLDS` race; maker==checker still enforced under RBAC (`PayoutBatch:Execute`).
- [ ] F-1–F-10 failure matrix `03 §7` — each has a passing test (F-7 circuit, F-9 crash-injection between outbox enqueue and commit).
- [ ] Sweep cron moves aged PROCESSING → NEEDS_REVIEW; escalation alert fires at threshold.
- [ ] Reconciliation with seeded drift resolves through `RefreshProviderState`/`ForceSettle` commands (audit rows for each).

## 6. Phase F — Frontend parity + Firebase SDK + cutover

Files: `04 §3/§4` + §7 remote-repo protocol. Deliverable `frontend-parity-matrix.md` (committed into this directory).

Gate F:
- [ ] Bridge phase: dashboard works on `sk_`; backoffice works on `ak_`; both can exchange Firebase tokens (both paths telemetry-counted).
- [ ] Target phase: direct Firebase ID token on all API calls; `POST /v1/auth/firebase/exchange` restricted or removed only after 2 weeks of 100%-Firebase telemetry; **legacy login endpoints remain available behind `AUTH_LEGACY_ENABLED` until the rollback drill passes.**
- [ ] Rollback drill: flipping `AUTH_LEGACY_ENABLED` restores legacy login within one deploy; tested in staging.
- [ ] Remote-repo parity matrix: every row has disposition; contradicting remote contracts produced CONTRACT_DRIFT rows; no "served by nothing" rows remain except explicit-no rows with alternatives.
- [ ] `frontend/docs/AUTH.md` / `API.md` / `ARCHITECTURE.md` updated to the shipped model.
- [ ] Strings sweep: zero "Inflora Admin" user-visible strings (`grep -ri "inflora admin" frontend/ backend/` excludes archived docs).

## 7. Phase G — Cleanup + hardening

- [ ] Drop legacy `admin_role` enum + column (after telemetry silence), drop `admin_sessions.password_hash` requirement (break-glass account keeps a local password row documented), remove `admin()` internal-key auth remainder (ideally zero callers), remove `X-Actor-Id` human path remnants.
- [ ] Remove the bridge: `POST /v1/auth/firebase/exchange` restricted to break-glass only or deleted; legacy `/v1/auth/signup|login` (Argon2id path) removed behind `AUTH_LEGACY_ENABLED=false` default after the Phase F rollback drill and 100%-Firebase telemetry; frontend `inflora_sk` stores deleted (`04 §2`).
- [ ] `streamer_bank_accounts` unique-primary fix (00 §6.3) — with a data migration; its down path is a re-add of the old constraint only if data permits (tested).
- [ ] `audit_log` append-only hardening (RULEs + test) — requires a drift row if the schema doc disagreeing.
- [ ] Quarterly secret rotation checklist update; runbook updates in `almanac/ops/RUNBOOK.md` (withdrawal sweeps, recon drill, break-glass, Firebase outage).
- [ ] Performance: batch list queries + payout queue EXPLAIN-capped (<50ms p50 at 1M payout rows synthetic load).

## 8. Rollout (environments)

1. **Dev (this machine)**: full E2E with Pivot provider; Firebase emulator optional (local verify mode with test JWKS) — `FIREBASE_VERIFY_MODE=closed` + Firebase Admin SDK emulator for integration tests.
2. **Staging**: Midtrans sandbox; real Firebase staging project; telemetry dashboards; 1 week of shadow batching (read-only replay of prod-like event logs) before prod.
3. **Production**: feature flags in order — (a) Firebase auth behind `AUTH_LEGACY_ENABLED=true`, (b) payout engine with `PAYOUT_EXECUTION_PAUSED=true` (batches buildable, not executable) until recon + runbooks signed off, (c) enable execution with caps, (d) post-cutover cleanup in a later deploy.
4. Backfill: existing streamers adopt Firebase per-user lazily (login flow offers "set password via Firebase" claim flow); existing admins mapped per `01 §6`. Both counted to 100% before legacy drop.

## 9. Observability & alerts (new)

- Metrics: `inflora_payout_queue_depth{status}`, `inflora_payout_processing_age_seconds`, `inflora_withdrawal_batch_resolution_seconds`, `inflora_firebase_token_verify_latency/errors`, `inflora_rbac_deny_total{endpoint,role}`.
- Alerts: payout queue depth > threshold; `NEEDS_REVIEW` age > 24h; sweep skipped (cron heartbeat); `MAKER_CHECKER` failure bursts; Firebase verification error rate > 1%; degraded-auth accepts > 0 (immediate page); recon drift unresolved > 1 day.
- Every alert has a runbook link (writes to `../ops/RUNBOOK.md`).

## 10. Explicit stop/abort conditions

- Any migration test failure, or any `go vet`/`golangci` error on changed packages → stop the phase.
- Any test that required relaxing a frozen invariant (e.g. deleting a ledger RULE, widening postings) → stop, escalate to contract reviewers, add CONTRACT_DRIFT row.
- Firebase token verification implemented outside tolkien or accepting client-supplied roles → immediate reject.
- Any code path mutating financial tables outside Saruman (CI grep gate) → reject PR.
- `go test ./...` must pass in every touched repo per phase (ingest + ws-gateway untouched by Phase A–D and must still pass).

## 11. Unresolved decisions (open until owner acks — do not guess)

1. A-3 variant: `identities` polymorphic table vs `firebase_uid` columns on `streamers`/`admin_users` (recommended: columns).
2. A-5 pass-through vs bridge-first default for the frontend during rollout.
3. N-2/N-4: whether to rename `/v1/admin/*` → `/v1/backoffice/*` and route `/admin` → `/backoffice` now or at the final phase.
4. D-028: batch-resolution event producer final word (recommended: Saruman).
5. Whether `payout_batch_status` gains `SCHEDULED` (circuit pause) — recommended defer.
6. Provide batch support via provider bulk API (requires provider confirmation) — recommended defer (D-029).
7. **RESOLVED 2026-10-16** — remote repo access obtained (owner credentials); `04 §7` executed; `frontend-parity-matrix.md` filed in this directory. See its §11/§12 for dispositions + pending drift rows D-031…D-036.
8. Whether USER role should also cover a future "non-streamer viewer" account type — out of current scope; decision recorded to avoid accidental scope growth.

## 12. Cross-document consistency checks (run by the implementer before starting each phase)

- Rerun: every path referenced in `00`–`04` exists (`test -f`); every endpoint name matches the frozen contracts or an acked drift row; every event topic/producer matches WIRE_GUIDE §3 (or an explicit D-row); every posting template referenced by opKey matches `10/11`.
- A `scripts/verify-plan-links.sh` (new) must resolve every relative link in this directory to a real file — add it in Phase 0.