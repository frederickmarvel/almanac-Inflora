# Inflora Backend Completion Plan for AI Agents

> **Status:** Proposed authoritative execution plan. Contract corrections in Phase 0 must be approved and applied before service implementation begins.
>
> **Purpose:** Finish the scalable MVP backend through small, dependency-ordered phases that can be assigned to AI coding agents without requiring them to invent architecture, names, ownership, or reliability behavior.
>
> **Workspace:** `/Users/frederickmarvel/Inflora`
>
> **Scope:** `inflora-shared`, `inflora-tolkien`, `inflora-ingest`, `inflora-palantir`, `inflora-saruman`, and `inflora-ws-gateway`, including migrations, cross-service contracts, automated tests, local integration, and production-readiness gates.

---

## 1. Objective and definition of done

The MVP backend is complete only when the following user journey works reliably:

1. A streamer registers and receives an overlay token.
2. The streamer configures an Indonesian bank account and OBS overlay.
3. A donor creates a donation intent in IDR.
4. Palantir creates a Midtrans SNAP transaction.
5. A valid provider callback is accepted exactly once as a business operation.
6. Saruman records the donation and balanced ledger transactions atomically.
7. The committed domain event is eventually published even after a process crash.
8. The OBS gateway displays the donation to the correct streamer and can recover missed frames.
9. The streamer sees balances and donation history in Tolkien.
10. The streamer requests a payout without the possibility of overdrawing through concurrent requests.
11. A payout either settles exactly once or restores reserved funds exactly once.
12. An authorized refund creates an append-only compensating ledger transaction.

The backend is **not done** merely because it compiles, unit tests pass, or every binary starts. Completion requires the phase gates, failure-injection tests, and end-to-end acceptance tests in this document.

---

## 2. Current baseline

### 2.1 Completed or substantially implemented

- The six-repository polyrepo workspace exists under `/Users/frederickmarvel/Inflora/backend`.
- `inflora-shared` contains initial configuration, auth, database, event, ledger, middleware, observability, provider, and generated protobuf packages.
- Saruman migrations and development seed infrastructure exist.
- Tolkien contains partial application and HTTP code for batches and holds.
- Workspace-wide tests and builds are currently green.

### 2.2 Incomplete production entrypoints

The following binaries are placeholders and must be replaced:

- `/Users/frederickmarvel/Inflora/backend/inflora-ingest/cmd/server/main.go`
- `/Users/frederickmarvel/Inflora/backend/inflora-palantir/cmd/server/main.go`
- `/Users/frederickmarvel/Inflora/backend/inflora-saruman/cmd/server/main.go`
- `/Users/frederickmarvel/Inflora/backend/inflora-ws-gateway/cmd/gateway/main.go`

### 2.3 Reliability gaps that must be closed

- No transactional outbox connects database commits to event publication.
- Consumer deduplication is process-local rather than durable.
- No durable dead-letter and replay workflow exists.
- Settlement/webhook ownership conflicts across documentation.
- Payout creation and balance reservation are not assigned to one atomic owner.
- WebSocket sequence and replay promises conflict with process restarts and multiple replicas.
- Ledger operation idempotency is not represented by a dedicated unique business-operation record.

---

## 3. Mandatory architectural decisions

These decisions are prerequisites for this plan. Phase 0 must encode them into the almanac before code relies on them.

### 3.1 Reliability model

Use all three mechanisms below because they solve different problems:

1. **Transactional outbox:** domain state and its event are written in the same PostgreSQL transaction.
2. **Durable consumer inbox:** each consumer claims `(consumer_name, event_id)` in the same transaction as its business effects.
3. **Append-only compensation:** committed financial mistakes or provider failures are corrected with new reversal/compensation ledger transactions, never by mutating old entries.

Delivery is at-least-once. Effective exactly-once business behavior comes from stable operation keys, database uniqueness, and idempotent state machines.

### 3.2 Canonical service ownership

| Concern | Canonical owner |
|---|---|
| Public donor HTTP and public provider webhook edge | Ingest |
| Provider signature verification and provider-specific normalization | Palantir |
| `gateway_topups`, `gateway_withdrawals`, `gateway_refunds`, `webhook_events` | Palantir |
| Donation financial transitions and ledger | Saruman |
| Payout domain state and atomic balance reservation | Saruman |
| Refund domain state and compensating ledger transaction | Saruman |
| Streamer/session/settings/bank-account identity data | Tolkien |
| Dashboard/admin authentication and HTTP facade | Tolkien |
| OBS connections, frame projection, sequence, and replay | WS Gateway |
| All PostgreSQL migrations | Saruman migration runner |

### 3.3 Canonical settlement path

```text
Provider
  -> Ingest public webhook HTTP
  -> Palantir SettleTopUp gRPC
  -> Palantir DB transaction + internal gateway outbox event
  -> NATS JetStream
  -> Saruman durable inbox + donation/ledger transaction + public outbox event
  -> NATS JetStream
  -> WS Gateway durable projection/inbox
  -> OBS WebSocket
```

`SettleTopUp` is implemented by Palantir. Palantir does not write donation financial state or ledger entries.

### 3.4 MVP provider scope

- Production MVP provider: **Midtrans SNAP**.
- Local/test provider: **Pivot deterministic stub**.
- Xendit remains deferred. Do not add Xendit implementation work to an MVP phase unless the almanac is explicitly changed.

### 3.5 Money and ledger rules

- All money is integer IDR in Go `int64` and PostgreSQL `BIGINT`.
- No floating-point or decimal money values.
- Ledger entries are append-only.
- Every logical ledger operation has a stable unique operation key.
- Every ledger transaction must balance.
- Corrections use linked compensation transactions.

---

## 4. Source-of-truth order

Before changing code, an AI agent must read the relevant documents in this order:

1. `/Users/frederickmarvel/Inflora/PROJECT_SUMMARY.md`
2. This plan.
3. `/Users/frederickmarvel/Inflora/almanac/planning/WIRE_GUIDE.md`
4. `/Users/frederickmarvel/Inflora/almanac/planning/schemas/INDEX.md`
5. Relevant files under `/Users/frederickmarvel/Inflora/almanac/planning/schemas/`
6. The target repository's `README.md` and `ARCHITECTURE.md`
7. Existing code and tests in the target repository.

After Phase 0, conflicts are resolved in this priority order:

1. Frozen schema/contract documents.
2. `WIRE_GUIDE.md`.
3. This execution plan.
4. Service `ARCHITECTURE.md`.
5. Existing code.
6. Archive code.

The `/Users/frederickmarvel/Inflora/archive` directory is historical reference only. Never copy it wholesale or treat its APIs as current contracts.

---

## 5. Rules for every AI implementation session

### 5.1 Scope control

- Work on exactly one phase or explicitly named subphase per request.
- Do not silently implement later phases.
- Do not rename contracts, topics, columns, endpoints, or environment variables without first updating the almanac.
- Do not import one service repository from another. Services may import only `inflora-shared` and approved third-party modules.
- Do not add a new library when the repository already has a suitable library or standard-library solution.
- Do not edit generated protobuf files manually.
- Do not add Xendit MVP behavior.

### 5.2 Required session workflow

Each AI agent must:

1. Inspect repository status and existing patterns.
2. Read the exact contracts needed for the phase.
3. State the planned files and tests before editing.
4. Add or update tests alongside implementation.
5. Run focused tests during development.
6. Run the target repository's `make test`, `make build`, and `make lint` when available.
7. Run workspace `make test-all` and `make build-all` for cross-repository contract changes.
8. Re-read all edited files.
9. Report changed files, commands run, results, assumptions, and remaining work.

### 5.3 Prohibited completion claims

An agent must not say a phase is complete when:

- Tests were not run and no explicit environmental limitation is reported.
- A production entrypoint still prints a TODO and exits.
- Integration behavior is represented only by mocks when PostgreSQL or NATS semantics are part of the requirement.
- Failure paths only log and discard data.
- Idempotency is held only in memory.
- State is committed before an event without an outbox record in the same transaction.
- A ledger correction updates or deletes an old ledger entry.

### 5.4 Standard phase report

Every phase handoff should contain:

```markdown
## Phase report
- Phase/subphase:
- Repositories changed:
- Contracts used:
- Files changed:
- Migrations added:
- Tests added:
- Commands run and results:
- Failure cases verified:
- Contract deviations: none / list
- Remaining risks:
- Next allowed phase:
```

---

## 6. Global engineering standards

### 6.1 Service structure

Use the existing repository conventions. A normal service should have:

```text
cmd/<binary>/main.go          composition root only
internal/config/              service-specific configuration
internal/repo/                PostgreSQL access
internal/service/             business use cases
internal/httpapi or handler/  HTTP transport
internal/grpc/                gRPC transport/client
internal/events/              outbox/event adapters
internal/subscriber/          NATS handlers
internal/testutil/            test fixtures and integration helpers
```

Business rules must not live in `main.go` or transport handlers.

### 6.2 Startup and shutdown

Every production binary must:

- Load and validate configuration before opening listeners.
- Initialize structured logging.
- Connect to required dependencies with bounded startup timeouts.
- Expose liveness and readiness separately where applicable.
- Start HTTP/gRPC servers and workers under a shared cancellation context.
- Handle `SIGINT` and `SIGTERM`.
- Stop accepting new requests before draining workers/connections.
- Shut down within a configured deadline.
- Return a non-zero exit code on fatal startup or runtime failure.

### 6.3 HTTP and gRPC behavior

- HTTP errors use the frozen JSON error envelope.
- gRPC errors use canonical status codes and do not leak secrets.
- Propagate request, correlation, and causation identifiers.
- Internal HTTP uses `X-Internal-Api-Key`.
- Internal gRPC uses `authorization: Bearer <service-api-key>`.
- Production transport security must be configurable; local development may use plaintext internal connections.

### 6.4 Event processing

- Event IDs are UUIDs and remain stable across outbox retries.
- `Nats-Msg-Id` equals the event ID.
- Event subjects follow the frozen catalog.
- Handlers validate event type and version before mutation.
- A consumer ACKs only after its database transaction commits.
- Transient failures NAK for redelivery.
- Permanent malformed/unsupported events go through durable dead-letter handling.

### 6.5 Testing requirements

Use four levels where applicable:

1. **Unit:** pure validation, state machines, hashes, mapping, posting templates.
2. **Repository integration:** real PostgreSQL constraints and transactions.
3. **Messaging integration:** real NATS JetStream delivery and redelivery.
4. **End-to-end:** real service processes with the Pivot stub; Midtrans sandbox is a separate external-integration gate.

Mocks do not replace PostgreSQL concurrency tests or JetStream delivery tests.

---

## 7. Phase dependency map

```text
Phase 0  Contract freeze
   |
Phase 1  Reliability schema
   |
Phase 2  Shared reliability/auth/runtime libraries
   |
Phase 3  Tolkien completion + account bootstrap event
   |-----------------------------|
Phase 4  Palantir top-up       Phase 5 Ingest intent
   |                             |
   +-------------+---------------+
                 |
Phase 6  Webhook normalization
                 |
Phase 7  Saruman donation + ledger
                 |
Phase 8  WS Gateway + replay
                 |
Phase 9  Donation E2E vertical slice
                 |
Phase 10 Payout
                 |
Phase 11 Refund
                 |
Phase 12 Scheduled jobs/reconciliation
                 |
Phase 13 Security/observability/operations
                 |
Phase 14 Failure, load, and release qualification
                 |
Phase 15 Documentation and handover
```

Phases 4 and 5 may proceed in parallel only after Phases 0-3 are complete and the RPC/event contracts are frozen.

---

## 8. Phase 0 — Freeze and reconcile contracts

### Goal

Remove all known ambiguity before adding business logic.

### Repositories

- `/Users/frederickmarvel/Inflora/almanac`
- Regenerate `/Users/frederickmarvel/Inflora/backend/inflora-shared` protobuf code only if proto contracts change.

### Required decisions and edits

1. Update `WIRE_GUIDE.md` so the webhook path is Ingest -> Palantir `SettleTopUp` -> internal event -> Saruman.
2. Add `SettleTopUp` to the gRPC caller/callee matrix.
3. Make Palantir the sole writer of `webhook_events`.
4. Make Saruman the sole owner of payout domain state transitions and balance reservations.
5. Clarify that Tolkien is the authenticated payout/refund HTTP facade, not the ledger owner.
6. Freeze internal provider-result event names and payloads, including at minimum:
   - top-up captured/completed
   - top-up settled, if distinct
   - top-up failed/expired
   - withdrawal settled/failed
   - refund settled/failed
7. Define CHARGED versus SETTLED provider semantics.
8. Correct the overlay token internal-auth header conflict.
9. Freeze stable idempotency/operation keys.
10. Freeze ledger posting templates for charge, settlement, payout reservation, payout completion, payout failure release, and refund.
11. Decide and document persistent WS sequence/replay for the scalable MVP. Recommended: PostgreSQL projection owned by WS Gateway.
12. Update flow diagrams to match the decisions.
13. Add a contract-drift table recording the old conflict and final decision.

### Contract review checklist

- [ ] Every RPC has one caller and one server.
- [ ] Every event has one producer and explicit consumers.
- [ ] Every table has one logical writer.
- [ ] Every financial transition has an operation key.
- [ ] Every async transition declares its outbox producer transaction.
- [ ] Every consumer declares its inbox name.
- [ ] Every webhook status maps to an allowed state transition.
- [ ] Every HTTP/gRPC call declares authentication and timeout.
- [ ] Every WebSocket replay promise has a durable implementation design.

### Validation

- Run Markdown/link checks if configured.
- Run `buf lint` and generation checks if proto files change.
- Run `/Users/frederickmarvel/Inflora/backend` `make test-all` and `make build-all` after shared contract regeneration.

### Exit gate

No known ownership or caller conflict remains. Implementation names can be copied directly from the almanac without invention.

### Suggested AI prompt

```text
Implement Phase 0 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md. Reconcile only documentation and shared contracts. Do not implement service business logic. Show a before/after contract-drift matrix, regenerate protobuf code if required, and run all relevant validation.
```

---

## 9. Phase 1 — Reliability and financial schema foundation

### Goal

Add the durable database primitives required before service event handling.

### Repository

- `/Users/frederickmarvel/Inflora/backend/inflora-saruman`

### Migration deliverables

Add a new migration; do not rewrite an applied migration unless the project explicitly confirms no shared environment has used it.

#### `outbox_events`

Minimum fields:

- `event_id UUID PRIMARY KEY`
- `producer VARCHAR(...) NOT NULL`
- `event_type VARCHAR(...) NOT NULL`
- `event_version VARCHAR(...) NOT NULL`
- `aggregate_type`, `aggregate_id`
- `streamer_id UUID NULL`
- `subject VARCHAR(...) NOT NULL`
- `envelope JSONB NOT NULL`
- `occurred_at TIMESTAMPTZ NOT NULL`
- `available_at TIMESTAMPTZ NOT NULL`
- `attempts INT NOT NULL DEFAULT 0`
- `claimed_at`, `claimed_by`
- `published_at`
- `last_error`

Indexes must support due unpublished event claiming and operational backlog queries.

#### `consumer_inbox`

Minimum fields:

- `consumer_name VARCHAR(...) NOT NULL`
- `event_id UUID NOT NULL`
- `event_type VARCHAR(...) NOT NULL`
- `received_at TIMESTAMPTZ NOT NULL`
- `processed_at TIMESTAMPTZ NULL`
- Primary key `(consumer_name, event_id)`

#### `event_dead_letters`

Minimum fields:

- `consumer_name`
- `event_id`
- `subject`
- `envelope JSONB`
- `attempt_count`
- `error_class`
- `last_error`
- `first_failed_at`
- `last_failed_at`
- `replayed_at`
- Unique `(consumer_name, event_id)`

#### `ledger_transactions`

Minimum fields:

- `id UUID PRIMARY KEY`
- `operation_key VARCHAR(...) UNIQUE NOT NULL`
- `correlation_id UUID`
- `causation_id UUID NULL`
- `transaction_type`
- `streamer_id UUID NULL`
- `reversal_of UUID NULL REFERENCES ledger_transactions(id)`
- `created_at TIMESTAMPTZ NOT NULL`
- `metadata JSONB`

Add `ledger_transaction_id` to `ledger_entries`. Preserve append-only enforcement.

#### WS projection tables

If Phase 0 approves database-backed sequence/replay, add:

- A per-streamer sequence counter table.
- A unique projection row keyed by source event ID.
- Stored frame JSON and expiry/retention metadata.
- Unique `(streamer_id, seq)`.

### Tests

- Migration up from current schema.
- Migration down and re-up in an isolated database.
- Unique outbox event ID.
- Inbox uniqueness under concurrent inserts.
- Ledger operation-key uniqueness under concurrent inserts.
- Dead-letter upsert uniqueness.
- `SKIP LOCKED` behavior for concurrent outbox workers.
- WS sequence allocation uniqueness if included.

### Exit gate

All durability invariants are enforced by PostgreSQL constraints, not only application checks.

### Suggested AI prompt

```text
Implement Phase 1 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md in inflora-saruman. Add a new reversible migration and real PostgreSQL integration tests. Do not add service handlers or workers yet. Prove concurrency-related uniqueness with tests.
```

---

## 10. Phase 2 — Shared reliability, runtime, and transport primitives

### Goal

Provide reusable, tested primitives so each service does not implement outbox, inbox, auth, and shutdown differently.

### Repository

- `/Users/frederickmarvel/Inflora/backend/inflora-shared`

### Deliverables

#### Transaction-aware outbox writer

- Accept an existing `*sql.Tx`.
- Construct and validate the frozen envelope.
- Insert the exact subject and envelope in the same transaction as business state.
- Never publish directly from business transaction code.
- Return stable event IDs to callers/tests.

#### Outbox dispatcher

- Claim bounded batches with `FOR UPDATE SKIP LOCKED` or an equivalent safe claim pattern.
- Publish with `Nats-Msg-Id = event_id`.
- Wait for JetStream publish acknowledgement.
- Mark published only after acknowledgement.
- Retry with bounded exponential backoff and jitter.
- Release stale claims after a configurable timeout.
- Support cancellation and graceful drain.

#### Durable inbox processor

- Begin or join a SQL transaction.
- Attempt to insert `(consumer_name, event_id)`.
- Treat a completed duplicate as successful no-op.
- Run the caller's mutation callback only for the winning claim.
- Mark `processed_at` in the same transaction.
- Roll back both inbox and mutation on error.

Do not use the existing in-memory `sync.Map` as the correctness boundary. It may remain only as an optional performance optimization.

#### Retry and dead-letter handling

- Classify transient versus permanent errors.
- Persist exhausted/permanent failures in `event_dead_letters`.
- Store the original envelope and error metadata.
- Terminate/ACK only after dead-letter persistence commits.
- Provide a library operation suitable for a later replay CLI.

#### Serializable retry helper

- Retry PostgreSQL serialization/deadlock failures a small bounded number of times.
- Add jitter.
- Respect context cancellation.
- Do not retry validation, authorization, or invariant failures.

#### Internal authentication

- HTTP internal API-key middleware using `X-Internal-Api-Key`.
- gRPC unary interceptor validating `authorization: Bearer ...`.
- Client helpers to attach auth and correlation metadata.
- Constant-time secret comparisons where applicable.
- No raw secret logging.

#### Runtime helpers

- Shared signal cancellation helper if consistent with existing style.
- Readiness dependency checks.
- Graceful shutdown coordination.
- Config fields for batch size, polling, retry, claim timeout, shutdown timeout, and consumer names.

### Required tests

- Unit tests for envelope validation and retry classification.
- PostgreSQL integration tests for outbox claims and inbox atomicity.
- JetStream integration tests for publish acknowledgement and duplicate publication.
- Crash-window simulation: publish succeeds, marking fails, retry publishes duplicate with same event ID.
- Two consumer instances receive/redeliver one event but execute one business mutation.
- Auth interceptor/middleware success and failure tests.
- Race-enabled tests.

### Compatibility requirement

Do not break existing public shared APIs without either:

- A compatibility wrapper, or
- Coordinated edits to every current caller in the same phase.

### Exit gate

A minimal test producer and test consumer can demonstrate committed-event recovery and durable business deduplication across process/object recreation.

### Suggested AI prompt

```text
Implement Phase 2 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md in inflora-shared. Use the Phase 1 schema exactly. Add real PostgreSQL and JetStream integration tests. Preserve compatibility for current callers, and do not implement service-specific domain behavior.
```

---

## 11. Phase 3 — Complete Tolkien identity and dashboard foundation

### Goal

Finish the streamer/admin service sufficiently to support registration, sessions, overlay validation, settings, bank accounts, and downstream account bootstrap.

### Repository

- `/Users/frederickmarvel/Inflora/backend/inflora-tolkien`

### First action

Audit existing Tolkien endpoints against the Phase 0 HTTP contract. Preserve working code, but do not assume the project-summary claim that Tolkien is complete is still accurate.

### Deliverables

#### Streamer authentication

- Signup with normalized unique email.
- Password hashing through `inflora-shared/auth`.
- Login and session creation.
- Logout/revocation.
- Session expiry and last-used handling.
- No timing-sensitive disclosure of whether a login email exists.

#### Overlay token lifecycle

- Generate opaque `ok_` tokens.
- Store only the password/token hash plus last four characters.
- Rotate/revoke safely.
- Internal overlay-token validation endpoint.
- 60-second bounded cache with invalidation on rotation.
- Internal HTTP authentication via `X-Internal-Api-Key`.

#### Streamer profile/settings

- Read/update only fields in the frozen HTTP contract.
- Validate donation and display bounds.
- Publish settings events through the outbox in the same transaction.

#### Bank-account references

- CRUD required by the MVP contract.
- Encrypt or tokenize sensitive values according to the frozen schema.
- Never expose/log full account details outside allowed responses.
- Ownership checks on every request.

#### Streamer registration event

- Registration transaction inserts `streamer.registered.v1` into the outbox.
- Event ID and correlation ID are visible in structured logs.

#### Saruman bootstrap consumer preparation

The actual ledger account creation handler belongs to Saruman, but its event payload must be fully usable by the end of this phase.

#### Existing admin batches and holds

- Reconcile existing partial code with the corrected ownership model.
- Keep identity/admin authorization in Tolkien.
- Do not perform direct ledger mutations.
- Any financial command required later should call the frozen Saruman command surface.

#### Entrypoint quality

The existing Tolkien main must be updated as necessary to include:

- Full route registration.
- Dependency initialization.
- Outbox dispatcher if Tolkien produces events.
- Health/readiness/metrics.
- Graceful shutdown.

### Tests

- Signup/login/logout integration tests with PostgreSQL.
- Duplicate email race.
- Session expiry/revocation.
- Token rotation invalidates old token.
- Overlay validation never logs the raw token.
- Authorization prevents cross-streamer bank/settings access.
- Registration commits streamer and outbox event atomically.
- Forced rollback creates neither.
- Existing batch/hold tests remain green.

### Exit gate

A new streamer can authenticate, configure the MVP profile, obtain a valid overlay token, and produce one durable registration event.

### Suggested AI prompt

```text
Implement Phase 3 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md in inflora-tolkien. Begin with a contract-to-code gap audit, preserve correct existing batch/hold code, finish identity/settings/bank/overlay functionality, and use the transactional outbox for every produced event.
```

---

## 12. Phase 4 — Palantir top-up command and provider foundation

### Goal

Replace the Palantir placeholder with a real authenticated gRPC provider broker capable of idempotent top-up creation.

### Repository

- `/Users/frederickmarvel/Inflora/backend/inflora-palantir`

### Deliverables

#### Composition root

Replace `cmd/server/main.go` with real startup for:

- Config and logger.
- PostgreSQL.
- gRPC server on canonical port `7001`.
- Auth, recovery, logging, tracing, and metrics interceptors.
- Provider registry.
- Outbox dispatcher.
- Health service.
- Signal handling and graceful shutdown.

#### Gateway top-up repository

- Insert/read/update gateway top-ups using Phase 0 schema ownership.
- Stable unique business key based on donation ID or persisted operation ID.
- Store provider reference, payment URL, expiry, status, and safe metadata.
- Lock rows for state transitions.

#### `CreateTopUp`

- Validate positive IDR and required IDs.
- Reject unsupported currency/provider.
- Use a stable provider idempotency key.
- Return the existing result for an exact retry.
- Reject the same operation key with materially different input.
- Bound provider timeouts.
- Map provider errors to canonical gRPC status codes.

#### Pivot provider

- Deterministic local implementation.
- No network dependency.
- Configurable success/failure/timeout behavior for tests.
- Stable response for the same operation key.

#### Midtrans SNAP provider

- Use the existing shared provider package where suitable.
- Create a SNAP transaction with a stable order ID.
- Validate and normalize expiry/payment URL response.
- Redact credentials and sensitive provider data.
- Contract tests with an `httptest` provider server.

### Tests

- gRPC auth required.
- Exact duplicate `CreateTopUp` returns the same gateway record/URL.
- Same key with different amount is rejected.
- Concurrent duplicates call the provider at most once logically.
- Provider timeout maps correctly and leaves a retryable state.
- Restart followed by retry does not create a second gateway top-up.
- Health/readiness behavior when PostgreSQL is down.
- Graceful shutdown stops accepting new RPCs.

### Exit gate

An authenticated client can create one idempotent Pivot top-up and one mocked Midtrans SNAP top-up through real gRPC and PostgreSQL.

### Suggested AI prompt

```text
Implement Phase 4 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md in inflora-palantir. Replace the placeholder server, implement only top-up creation plus provider foundations, and prove provider/database idempotency with concurrency and restart-style tests. Do not implement webhook settlement yet.
```

---

## 13. Phase 5 — Ingest donation intent API

### Goal

Replace the Ingest placeholder with the public donation-intent API and an idempotent Palantir client flow.

### Repository

- `/Users/frederickmarvel/Inflora/backend/inflora-ingest`

### Deliverables

#### Composition root

Replace `cmd/server/main.go` with:

- Config/logger/PostgreSQL/NATS.
- Palantir gRPC client with auth and timeout interceptors.
- HTTP server on canonical port `8081`.
- Middleware, health/readiness/metrics.
- Outbox dispatcher.
- Graceful shutdown.

#### Public donation endpoint

- Implement exactly the frozen route and request/response fields.
- Require `Idempotency-Key` for writes.
- Validate UUID, amount, message/media fields, and IDR-only constraints.
- Check active streamer and current donation settings.
- Apply CAPTCHA abstraction and configured rate limiting.
- Normalize donor display fields safely.

#### Idempotency behavior

- Claim `(key, endpoint, request_hash)` transactionally.
- Exact completed retry returns the cached status/body.
- Same key with a different hash returns `409 IDEMPOTENCY_CONFLICT`.
- In-progress retry must not return an empty false-success response.
- Define lease/recovery behavior for requests interrupted before response caching.

#### Donation intent transaction

In one PostgreSQL transaction:

- Claim/validate the idempotency record.
- Insert `donations(status=INTENT_CREATED)`.
- Insert `donation.intent.created.v1` into the outbox.
- Commit.

Then call Palantir `CreateTopUp` with a stable operation key derived from the donation intent. Store/cache the successful response idempotently.

#### Donor landing/read behavior

Implement only the public read endpoints defined in the HTTP contract. Never expose private streamer or donor information.

### Important crash cases

The implementation must correctly recover when:

1. The donation commits but Ingest crashes before Palantir is called.
2. Palantir succeeds but Ingest crashes before caching the HTTP response.
3. The client retries while the original request is still in progress.

Palantir idempotency is the second line of defense for cases 1 and 2.

### Tests

- Validation/error-envelope unit tests.
- Real PostgreSQL idempotency integration tests.
- Concurrent duplicate HTTP requests create one donation.
- Same key/different body returns 409.
- Transaction rollback creates neither donation nor outbox event.
- Palantir timeout leaves a resumable intent.
- Retry after simulated post-provider crash returns the original payment URL.
- Rate limit and CAPTCHA behavior.
- No raw donor email/token/secret logging.

### Exit gate

With Pivot Palantir running, a public HTTP request reliably returns one reusable payment URL and one durable donation-intent event.

### Suggested AI prompt

```text
Implement Phase 5 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md in inflora-ingest. Replace the placeholder server and implement the donation intent vertical slice through the real Palantir gRPC contract. Include crash-window and concurrent idempotency tests. Do not implement provider webhooks yet.
```

---

## 14. Phase 6 — Provider webhook edge and Palantir normalization

### Goal

Accept hostile/repeated provider callbacks safely and turn them into one durable internal provider-result event.

### Repositories

- `/Users/frederickmarvel/Inflora/backend/inflora-ingest`
- `/Users/frederickmarvel/Inflora/backend/inflora-palantir`

### Ingest deliverables

- Add the exact Midtrans webhook route from the frozen contract.
- Enforce body-size limits and strict content-type/method handling.
- Preserve the raw body bytes required for signature verification.
- Call Palantir `SettleTopUp` with bounded deadlines and internal auth.
- Return the frozen provider-compatible response semantics.
- Do not write `webhook_events`, gateway rows, donations, or ledger rows in Ingest.
- Never log raw signature secrets or full unredacted payloads.

### Palantir deliverables

#### Signature and payload validation

- Verify the Midtrans signature using constant-time comparison where possible.
- Validate order/reference identifiers, amount, currency, and known status.
- Match the callback to the stored gateway top-up.
- Reject amount/reference mismatches without mutating business state.

#### Webhook deduplication

- Compute the frozen provider event/deduplication key.
- Insert one `webhook_events` record in the same transaction as the gateway state update.
- Return prior success for an exact duplicate.
- Record invalid callbacks according to the frozen security/audit policy without allowing them to consume a valid event key incorrectly.

#### State transition and outbox

In one PostgreSQL transaction:

- Lock the gateway top-up.
- Apply only a legal, monotonic provider transition.
- Store safe raw/normalized metadata.
- Insert the internal provider-result event into `outbox_events`.
- Commit before responding with business success.

Late or duplicate callbacks must not move a terminal state backward.

### Tests

- Valid Midtrans signature accepted.
- Invalid signature rejected with no gateway/outbox mutation.
- Exact duplicate callback is business-idempotent.
- Concurrent duplicates produce one state transition and one logical event.
- Amount/reference mismatch is rejected.
- Unknown status follows the frozen handling policy.
- Success followed by late pending/failure cannot regress state.
- Database failure prevents success response and produces no partial state.
- Process restart followed by duplicate callback remains idempotent.
- Provider raw payload is redacted in logs.

### Exit gate

One valid callback produces one committed gateway transition and one recoverable internal event; repeated, concurrent, malformed, and late callbacks cannot duplicate or regress it.

### Suggested AI prompt

```text
Implement Phase 6 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md across inflora-ingest and inflora-palantir. Ingest is only the public HTTP edge; Palantir owns verification, webhook persistence, gateway state, and outbox production. Add duplicate, concurrency, invalid-signature, amount-mismatch, and late-event tests.
```

---

## 15. Phase 7 — Saruman account bootstrap, donation settlement, and ledger

### Goal

Replace the Saruman placeholder and make financial transitions atomic, balanced, replay-safe, and append-only.

### Repository

- `/Users/frederickmarvel/Inflora/backend/inflora-saruman`

### Deliverables

#### Composition root

Replace `cmd/server/main.go` with:

- Config/logger/PostgreSQL/NATS.
- Authenticated gRPC server if required by frozen command contracts.
- Durable JetStream consumers.
- Outbox dispatcher.
- Health/readiness/metrics.
- Graceful consumer drain and server shutdown.

#### Streamer account bootstrap consumer

Consume `streamer.registered.v1` using the durable inbox and create required ledger accounts with deterministic identities or unique account keys. Redelivery must be a no-op after successful processing.

#### Provider-result consumer

For a successful top-up result, run one database transaction that:

1. Claims the event in `consumer_inbox`.
2. Locks the donation and relevant financial records.
3. Validates the allowed donation transition.
4. Creates one `ledger_transactions` row using the frozen operation key.
5. Inserts all posting-template ledger entries.
6. Verifies debit equals credit before commit.
7. Updates the donation status.
8. Inserts the public donation-completed/settled event into the outbox.
9. Marks the inbox row processed.

Failure/expiry provider events must transition the donation only through legal state-machine paths and publish any required public state event through the same pattern.

#### Ledger posting engine

- Encode posting templates as tested domain functions, not handler-local ad hoc SQL.
- Reject zero/negative values where invalid.
- Reject unbalanced postings.
- Resolve account IDs without cross-streamer leakage.
- Use operation-key uniqueness as the final duplicate guard.
- Never update/delete committed ledger entries.

#### Query surfaces

Implement only frozen internal/dashboard query RPCs required by Tolkien for:

- Balance summary.
- Donation history/details.
- Ledger/audit views required by admins.

Use deterministic pagination ordering and authorized streamer scoping.

### Required tests

- Streamer registration redelivery creates one account set.
- Donation settlement duplicate/redelivery creates one ledger transaction.
- Two Saruman replicas racing one event commit one mutation.
- Balanced posting property tests over representative amounts.
- Forced failure after ledger inserts rolls back donation, ledger, inbox, and outbox together.
- Forced failure after commit but before ACK redelivers to a successful no-op.
- Unknown/unsupported event versions dead-letter durably.
- Terminal donation states cannot regress.
- Query authorization and pagination tests.
- PostgreSQL constraints reject duplicate operation keys and ledger mutation.

### Failure-injection scenarios

- Kill consumer before transaction begin.
- Kill/return error after inbox claim but before commit.
- Commit, then lose the NATS ACK.
- Publish the same source event repeatedly.
- Temporarily stop NATS while Saruman commits its public event.
- Temporarily stop PostgreSQL while messages remain pending.

### Exit gate

Saruman can be restarted or redelivered at every failure boundary without duplicating accounts, donation transitions, balances, or ledger entries, and its public event eventually publishes after NATS recovery.

### Suggested AI prompt

```text
Implement Phase 7 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md in inflora-saruman. Replace the placeholder server; add durable consumers, account bootstrap, donation settlement, ledger posting templates, queries, and outbox publication. Use real PostgreSQL/JetStream tests and inject failures around transaction and ACK boundaries.
```

---

## 16. Phase 8 — Durable WebSocket projection and overlay delivery

### Goal

Replace the WS gateway placeholder with a horizontally safe overlay service that can deduplicate, sequence, replay, and resume.

### Repository

- `/Users/frederickmarvel/Inflora/backend/inflora-ws-gateway`

### Deliverables

#### Composition root

Replace `cmd/gateway/main.go` with:

- Config/logger/PostgreSQL/NATS.
- Tolkien internal overlay-token client.
- HTTP/WebSocket server on canonical port `8083`.
- Durable JetStream consumer.
- Health/readiness/metrics.
- Connection registry.
- Graceful shutdown with close frames and consumer drain.

#### Connection authentication

- Validate overlay tokens using Tolkien's internal endpoint.
- Cache only for the bounded contract duration.
- Associate each connection with exactly one streamer.
- Reject revoked/invalid tokens.
- Redact tokens from URL/access/application logs.
- Enforce origin policy, handshake timeout, read limit, ping/pong deadlines, and bounded write timeouts.

#### Durable event projection

For each public overlay event:

1. Validate envelope type/version.
2. Claim the source event through durable inbox/projection uniqueness.
3. Atomically allocate the next per-streamer sequence.
4. Persist the exact frozen WebSocket frame JSON.
5. Commit before ACK.
6. Fan out the committed frame to local connections.

If the process crashes after commit and before fanout, clients recover the frame through replay/resume.

#### Resume and replay

- Implement the frozen `?since=<seq>` behavior.
- Replay frames with `seq > since` in ascending order.
- Enforce the documented replay limit and retention policy.
- Send `system.resync_required` when the requested sequence is too old or the gap is too large.
- Ensure two gateway replicas observe the same sequence history.
- Ensure source-event redelivery cannot allocate a second sequence.

#### Backpressure

- Use bounded per-connection queues.
- Never block the NATS consumer or all clients on one slow socket.
- Apply the frozen slow-consumer policy: disconnect/resync rather than silently losing ordered frames.
- Record connection, replay, drop/disconnect, and projection-lag metrics.

### Tests

- Token success/failure/rotation behavior.
- Raw token absent from captured logs.
- Same source event delivered repeatedly yields one persisted frame.
- Concurrent events for one streamer receive unique increasing sequences.
- Events for different streamers do not leak across connections.
- Restart preserves sequence and replay.
- Two gateway instances share sequence/replay correctly.
- Simulated crash after projection commit but before fanout is recoverable.
- Slow consumer does not block a fast consumer.
- Replay-limit overflow returns `system.resync_required`.
- Ping/pong and graceful close behavior.

### Exit gate

An OBS client can disconnect, reconnect to another gateway replica with `since`, and receive every retained frame exactly once in sequence at the application level.

### Suggested AI prompt

```text
Implement Phase 8 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md in inflora-ws-gateway. Replace the placeholder gateway and implement durable PostgreSQL-backed source-event deduplication, per-streamer sequence allocation, replay, token validation, and bounded connection backpressure. Include restart and multi-instance tests.
```

---

## 17. Phase 9 — Donation vertical-slice integration gate

### Goal

Prove the entire donation path before beginning payouts or refunds.

### Repositories

- All backend repositories.
- `/Users/frederickmarvel/Inflora/backend/Makefile`
- `/Users/frederickmarvel/Inflora/backend/README.md`
- Docker/local orchestration files if present.

### Deliverables

- Add a repeatable integration harness using PostgreSQL, NATS JetStream, all required services, and Pivot.
- Run real service processes or production composition roots; do not bypass them with direct function calls.
- Seed only infrastructure/global accounts that cannot be created through public flows.
- Provide deterministic fixture cleanup or isolated database/schema creation.
- Add one documented command to run the complete scenario.

### Required scenario

1. Register a streamer through Tolkien.
2. Wait for Saruman account bootstrap.
3. Connect an overlay client through WS Gateway.
4. Create a donation through Ingest.
5. Verify one Palantir gateway top-up.
6. Send a signed Pivot/provider success callback through Ingest.
7. Verify Palantir gateway/webhook state.
8. Wait for Saruman donation and ledger commit.
9. Verify the balanced posting and expected available/pending balances.
10. Verify one overlay donation frame for the correct streamer.
11. Verify Tolkien dashboard query returns the donation/balance.

### Mandatory disruption variants

- Stop NATS before provider settlement; restart it and verify eventual completion.
- Stop Saruman during delivery; restart it and verify one ledger transaction.
- Duplicate the provider webhook concurrently.
- Force a consumer redelivery by losing an ACK.
- Disconnect overlay before settlement, reconnect with `since`, and replay.
- Run two WS gateway instances.

### Evidence

The test should assert database invariants directly in addition to API responses:

- One webhook business event.
- One ledger operation key.
- Balanced ledger entries.
- One source-event projection row.
- Monotonic frame sequence.
- No pending outbox rows after dependencies recover.
- No unexpected dead-letter rows.

### Exit gate

The complete donation slice passes repeatedly, including disruption cases. No payout/refund phase may start before this gate passes.

### Suggested AI prompt

```text
Implement Phase 9 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md. Add a repeatable full-process donation integration suite using Pivot, PostgreSQL, and JetStream. Include the specified disruptions and assert database invariants, not only HTTP responses.
```

---

## 18. Phase 10 — Payout lifecycle

### Goal

Implement a payout flow whose reservation is concurrency-safe and whose provider completion/failure is idempotent and compensating.

### Repositories

- `/Users/frederickmarvel/Inflora/backend/inflora-tolkien`
- `/Users/frederickmarvel/Inflora/backend/inflora-saruman`
- `/Users/frederickmarvel/Inflora/backend/inflora-palantir`
- `/Users/frederickmarvel/Inflora/backend/inflora-ingest` only if a public payout-provider webhook edge is required.

### Ownership

- Tolkien: authenticated streamer/admin HTTP facade and authorization.
- Saruman: payout aggregate, balance check, atomic reservation, ledger, status transitions.
- Palantir: provider withdrawal command, provider withdrawal record, webhook normalization.

### Deliverables

#### Payout request

- Tolkien validates session, bank-account ownership, request shape, and HTTP idempotency.
- Tolkien sends one authenticated Saruman command.
- Saruman runs a serializable/retryable transaction that locks the relevant balance/account state, proves sufficient funds, creates the payout, posts reservation entries, and writes a payout-requested outbox event.
- The balance check and reservation must be in the same transaction.
- Concurrent requests cannot reserve the same funds twice.

#### Provider withdrawal

- Palantir consumes the payout-requested event or receives the frozen command, using durable inbox semantics.
- Create one `gateway_withdrawals` row and one provider transfer for the stable payout operation key.
- Pivot must support deterministic settle/fail behavior.
- Midtrans payout support must be implemented only if Phase 0 confirms the chosen Midtrans product and credentials; otherwise document/manual-adapter the MVP boundary instead of inventing an API.

#### Settlement

- Provider callbacks enter through the frozen webhook edge.
- Palantir verifies/deduplicates and emits one internal withdrawal result.
- Saruman completion moves reserved value to the frozen terminal posting accounts.
- Saruman failure posts a new compensation/release transaction restoring availability.
- Neither path mutates prior entries.

#### Read/admin behavior

- Tolkien returns payout history/status through Saruman queries.
- Admin approval/hold requirements follow the Phase 0 contract.
- Audit actor and reason are captured for manual actions.

### Tests

- Two payouts racing the same available balance: at most the affordable set succeeds.
- Duplicate HTTP request returns the same payout.
- Duplicate provider command creates one withdrawal.
- Duplicate settle callback posts one completion transaction.
- Duplicate fail callback posts one release transaction.
- Settle and fail race produces one legal terminal result.
- Provider timeout/restart resumes by operation key.
- Reservation rollback on any transaction failure.
- Streamer cannot use another streamer's bank account.
- Full Pivot payout E2E.

### Exit gate

Payout funds can never be spent twice; every reserved amount reaches one legal terminal state, and failures restore availability through an append-only compensation.

### Suggested AI prompt

```text
Implement Phase 10 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md. Keep HTTP auth in Tolkien, the payout aggregate/reservation/ledger in Saruman, and provider withdrawal state in Palantir. Prove concurrent no-overdraft behavior and idempotent settle/fail compensation with real database tests.
```

---

## 19. Phase 11 — Refund lifecycle

### Goal

Implement authorized full refunds with provider idempotency and append-only financial compensation.

### Repositories

- `/Users/frederickmarvel/Inflora/backend/inflora-tolkien`
- `/Users/frederickmarvel/Inflora/backend/inflora-saruman`
- `/Users/frederickmarvel/Inflora/backend/inflora-palantir`
- `/Users/frederickmarvel/Inflora/backend/inflora-ingest` only for provider callback routing.

### Deliverables

#### Refund authorization/request

- Implement only the frozen actor policy (streamer and/or admin).
- Validate the donation is captured/settled and not already fully refunded.
- Require audit reason where specified.
- Use HTTP and domain operation idempotency keys.

#### Financial reservation/eligibility

- Saruman owns the refund aggregate/financial eligibility decision.
- If funds must be reserved pending provider completion, use a dedicated append-only posting template.
- Create one refund-requested outbox event atomically with financial state.

#### Provider refund

- Palantir owns `gateway_refunds` and provider calls.
- Use the frozen stable refund operation key.
- Duplicate commands return the same provider result/reference.
- Provider callbacks/results become durable normalized internal events.

#### Completion and failure

- Successful refund creates one linked compensation/reversal ledger transaction.
- Failed refund releases any reservation through a separate linked compensation.
- Update refund/donation display status without changing historical ledger entries.
- Publish public/dashboard events through the outbox.

### Tests

- Ineligible donation rejected.
- Duplicate requests create one refund aggregate/provider refund.
- Concurrent refund requests cannot exceed the refundable amount.
- Duplicate completion creates one compensating ledger transaction.
- Fail/complete race ends in one legal terminal state.
- Ledger remains balanced before and after refund.
- Historical original entries are byte-for-byte unchanged.
- Full Pivot refund E2E.

### Exit gate

Every accepted refund has one stable operation identity and exactly one append-only financial outcome; historical financial records remain immutable.

### Suggested AI prompt

```text
Implement Phase 11 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md using the frozen refund authorization and posting templates. Saruman owns refund financial state, Palantir owns provider refund state, and Tolkien owns authenticated HTTP. Prove concurrency, duplicate, and compensation invariants.
```

---

## 20. Phase 12 — Scheduled jobs, expiry, reconciliation, and replay tools

### Goal

Ensure asynchronous state progresses and can be repaired without direct database edits.

### Repositories

- Primarily Palantir, Saruman, and shared.
- Service-specific `cmd/worker` or `cmd/cli` binaries as appropriate.

### Deliverables

#### Expiry workers

- Expire donation intents/gateway top-ups after the frozen deadline.
- Use row locking/claiming so multiple replicas can run safely.
- Produce required state events through the outbox.
- Do not expire a transaction that concurrently reached success.

#### Provider reconciliation

- Query provider status for non-terminal operations past a threshold.
- Normalize reconciled results through the same state machines as webhooks.
- Use bounded rate, timeouts, and retries.
- Record last reconciliation attempts/errors.

#### Financial reconciliation

- Verify ledger transactions balance.
- Compare derived balances to stored/cache balances if such caches exist.
- Report provider terminal operations lacking a financial terminal state.
- Report financial terminal states lacking provider evidence where required.
- Never auto-edit historical ledger entries.

#### Dead-letter operations

- Add a CLI/admin operation to list/filter dead letters.
- Replay one or a bounded batch with an explicit actor/reason.
- Preserve the original event ID for idempotent replay.
- Mark replay metadata without deleting audit history.
- Prevent infinite automatic replay loops.

#### Outbox operations

- Metrics and inspection for pending/claimed/stale/failed rows.
- Safe stale-claim recovery.
- Optional bounded manual retry command.

### Tests

- Two expiry workers do not duplicate a transition.
- Success/expiry race has one legal winner.
- Reconciliation duplicate result remains idempotent.
- Dead-letter replay executes one business mutation at most once.
- Replay of an already-processed event is a successful no-op.
- Financial reconciliation detects an intentionally unbalanced fixture.

### Exit gate

Operators can identify and safely replay failed asynchronous work, and stale non-terminal provider operations converge without manual SQL mutation.

### Suggested AI prompt

```text
Implement Phase 12 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md. Add replica-safe expiry/reconciliation workers and audited dead-letter/outbox inspection and replay tools. Route all recovered results through existing idempotent state machines; never repair ledger history with UPDATE or DELETE.
```

---

## 21. Phase 13 — Security, observability, and operational hardening

### Goal

Make production behavior diagnosable and secure without changing domain ownership.

### Repositories

- All backend repositories.

### Security checklist

- [ ] All internal HTTP and gRPC calls authenticate.
- [ ] Provider signatures are verified before mutation.
- [ ] Secrets are loaded from configuration/secrets, never committed.
- [ ] Passwords and overlay tokens are hashed using approved primitives.
- [ ] Bank-account-sensitive fields are encrypted/tokenized as designed.
- [ ] Request bodies, auth headers, full overlay tokens, passwords, provider secrets, and full bank accounts are absent from logs.
- [ ] Public endpoints have body limits, deadlines, rate limits, and validation.
- [ ] CORS/origin policies are explicit.
- [ ] Database users follow least privilege where deployment supports it.
- [ ] Dependency and static security scans have no unresolved critical findings.

### Observability deliverables

#### Logs

- JSON structured logs.
- Service, environment, version, request ID, correlation ID, event ID, operation key, and safe entity IDs.
- Consistent error classification.
- No high-cardinality secret labels.

#### Metrics

At minimum:

- HTTP/gRPC request count, latency, and error class.
- Outbox pending age/count, publish attempts, publish failures.
- Inbox duplicates and handler failures.
- JetStream consumer lag/redelivery.
- Dead-letter count and oldest age.
- Provider request latency/error/status.
- Donation/payout/refund transition counts.
- Ledger invariant failures.
- WS active connections, handshake failures, queue pressure, replay count, resync count.
- PostgreSQL pool saturation.

#### Tracing

- Propagate correlation/trace context across HTTP, gRPC, outbox envelopes, NATS, and WebSocket projection logs.
- Trace provider calls with redacted metadata.
- Sampling is configurable.

#### Health

- Liveness reports process health only.
- Readiness reflects dependencies required for the service's role.
- A dependency outage should remove readiness without causing a restart loop unless the process itself is unhealthy.

### Operational artifacts

- Environment-variable reference for every service.
- Startup dependency matrix.
- Alert recommendations for outbox age, consumer lag, dead letters, provider failures, ledger invariant errors, and payout aging.
- Runbooks for NATS outage, PostgreSQL outage, provider outage, stuck payout, duplicate callback, dead-letter replay, and token compromise.

### Tests

- Automated log-capture tests for secret redaction.
- Health/readiness transition tests.
- Metrics endpoint smoke tests.
- Trace/correlation propagation integration test.
- Graceful shutdown under active request/message/socket load.

### Exit gate

An operator can detect, correlate, and safely respond to every known failure mode without requiring sensitive data in logs or direct production database edits.

### Suggested AI prompt

```text
Implement Phase 13 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md across all backend services. Standardize auth, redaction, health, metrics, tracing, deadlines, and graceful shutdown without changing domain ownership. Add automated redaction and propagation tests plus operational runbooks.
```

---

## 22. Phase 14 — Failure, concurrency, load, and release qualification

### Goal

Demonstrate that the implementation satisfies reliability promises under realistic disruption and concurrency.

### Deliverables

#### Automated failure matrix

| Failure | Expected result |
|---|---|
| NATS unavailable during DB commit | Business state and outbox commit; eventual publication after recovery |
| Process killed after publish before outbox mark | Duplicate delivery possible; one business effect |
| Consumer killed before commit | Redelivery performs the effect once |
| Consumer commit succeeds but ACK is lost | Redelivery is durable-inbox no-op |
| Duplicate provider callbacks | One provider transition/event |
| PostgreSQL serialization conflict | Bounded retry or clean client retry response |
| Provider timeout after provider accepted request | Stable operation key recovers original operation |
| WS gateway restart | Sequence/replay survives |
| Two WS replicas | No duplicate sequence/source projection |
| Concurrent payouts/refunds | No overspend/over-refund |
| Slow WebSocket client | Isolated disconnect/resync; no global blocking |

#### Load profiles

Define measured MVP targets in a checked-in test document before declaring success. At minimum test:

- Donation-intent HTTP throughput.
- Provider callback burst.
- Saruman settlement throughput.
- Outbox backlog drain rate.
- Concurrent OBS connections.
- Fanout to multiple connections for one streamer.
- Many streamers receiving independent events.
- Payout concurrency on one streamer balance.

Do not invent an unapproved SLA. Record hardware, configuration, test data, percentiles, error rates, and bottlenecks.

#### Race and quality gates

- Run `go test -race ./...` in every Go repository where practical.
- Run all repository linters.
- Run workspace tests/builds.
- Run migration validation from an empty database and current baseline.
- Run protobuf breaking/lint checks.
- Run dependency vulnerability scanning using the repository-approved toolchain.

#### Recovery rehearsal

- Restore from a PostgreSQL backup in a non-production environment.
- Verify migrations and services start against the restore.
- Verify outbox/inbox/dead-letter data remains usable.
- Document NATS stream recreation/retention assumptions and the consequence of message loss; PostgreSQL outbox must remain the recovery source for unpublished producer events.

### Exit gate

All correctness scenarios pass; load results meet the explicitly approved MVP targets; no critical security/invariant defects remain; residual limitations are documented and accepted.

### Suggested AI prompt

```text
Implement and execute Phase 14 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md. Create repeatable failure/concurrency/load tests, record the exact environment and results, run race/lint/build/migration/contract checks, and produce a release qualification report. Do not claim an SLA that was not approved.
```

---

## 23. Phase 15 — Documentation, deployment handover, and completion audit

### Goal

Make the finished backend reproducible by a new engineer or AI agent and close all plan items with evidence.

### Deliverables

- Update `/Users/frederickmarvel/Inflora/PROJECT_SUMMARY.md` to reflect actual status.
- Update `/Users/frederickmarvel/Inflora/backend/README.md` with exact setup, migration, generation, test, and run commands.
- Update `/Users/frederickmarvel/Inflora/backend/REPO-STRUCTURE.md` for actual service structures.
- Update every service README/architecture document.
- Document all environment variables, defaults, and which are secrets.
- Document canonical local ports and health endpoints.
- Document NATS streams, subjects, durable consumer names, retention, and replay policy.
- Document database migration/deployment order and rollback limitations.
- Document Midtrans sandbox/production setup and webhook configuration.
- Document Pivot use for local development.
- Document backup/restore and disaster-recovery steps.
- Add architecture diagrams matching implemented flows.
- Mark every checklist item in this document complete or link an explicitly accepted deferral.
- Remove obsolete TODO startup messages and contradictory documentation.
- Ensure no production binary remains a placeholder.

### Final audit commands

Run the commands supported by the current workspace, including at minimum:

```bash
cd /Users/frederickmarvel/Inflora/backend
make test-all
make build-all
```

Also run each repository's supported lint/race/integration targets and the complete E2E suite. Record exact commands rather than assuming Make targets exist.

### Final completion checklist

- [ ] Contracts have no known ownership/caller/event conflicts.
- [ ] All migrations apply cleanly from empty and current baseline databases.
- [ ] All production entrypoints run real services.
- [ ] Every database-to-event transition uses an outbox.
- [ ] Every business-mutating consumer uses a durable inbox.
- [ ] Dead letters are durable, inspectable, and replayable.
- [ ] Donation E2E passes with failure injection.
- [ ] Payout E2E passes with concurrency and compensation tests.
- [ ] Refund E2E passes with concurrency and compensation tests.
- [ ] Ledger entries are immutable and all tested transactions balance.
- [ ] WebSocket sequence/replay survives restart and multiple replicas.
- [ ] Internal transport authentication is enabled.
- [ ] Secret-redaction tests pass.
- [ ] Health, metrics, tracing, alerts, and runbooks exist.
- [ ] Race, lint, build, integration, security, and migration gates pass.
- [ ] Performance results and accepted limits are documented.
- [ ] Documentation describes the implementation as it exists.

### Exit gate

A new operator can create a clean environment, migrate it, start the complete backend, run the documented E2E flows, diagnose failures, and recover failed async work using only checked-in documentation and tools.

### Suggested AI prompt

```text
Execute Phase 15 from almanac/planning/AI_BACKEND_COMPLETION_PLAN.md. Audit documentation against the running implementation, remove contradictions/placeholders, run every final validation gate, and produce a completion report linking evidence for every checklist item. Do not mark an unverified item complete.
```

---

## 24. Cross-phase progress tracker

Update this table only after the phase exit gate passes. A phase with code merged but a failed gate remains `IN PROGRESS` or `BLOCKED`.

| Phase | Status | Commit/PR | Validation evidence | Blocker/notes |
|---|---|---|---|---|
| 0. Contract freeze | COMPLETE | this session | CONTRACT_DRIFT.md (D-001..D-019) created; WIRE_GUIDE §2/§3/§4/§6/§8/§9 updated; 00-frozen-contracts §4.5 auth header corrected (D-010); 09-internal-provider-events.md (pg.gateway.* frozen); 10-posting-templates.md (capture/settle/reserve/complete/release/refund); 11-operation-keys.md; 08-flow-diagrams.md settlement flow corrected; schemas/INDEX.md updated | next: Phase 1 schema foundation |
| 1. Reliability schema | COMPLETE | this session | 00003_reliability.{up,down}.sql adds ledger_transactions (operation_key UNIQUE), outbox_events, consumer_inbox, event_dead_letters, ws_projection_inbox/sequences/frames; ledger_entries now FK'd to ledger_transactions with chk_amount_positive; 7 integration tests in reliability_integration_test.go pass against real PostgreSQL 14 (up/down/re-up, outbox event_id unique, inbox concurrent inserts, ledger op_keys unique, dead-letter upsert unique, SKIP LOCKED, WS seq concurrent unique) | next: Phase 2 shared primitives |
| 2. Shared reliability/runtime | COMPLETE (implementation) | working tree | PostgreSQL-leased outbox dispatcher uses producer-scoped `FOR UPDATE SKIP LOCKED` claims, acknowledged JetStream publishing with event-ID deduplication, fenced completion, stale-claim recovery, exponential retry/backoff, and durable dead-lettering. Shared runtime now surfaces worker failure immediately and cancels siblings. `go test ./...`, `go test -race ./...`, and `go build ./...` pass. | Live PostgreSQL dispatcher and JetStream delivery tests still require local infrastructure. |
| 3. Tolkien foundation | COMPLETE (implementation) | working tree | Tolkien startup runs HTTP and its outbox dispatcher under shared runtime. Signup, settings, overlay rotation, holds, and payout-batch workflows enqueue events in the same SQL transaction as business mutations; all direct post-commit NATS publication was removed. Unit/race suites and build pass. | PostgreSQL-backed lifecycle tests are present but were skipped because `TEST_DATABASE_URL` is unset. |
| 4. Palantir top-up | COMPLETE (implementation) | working tree | A stable PostgreSQL advisory transaction lock serializes missing-row creation before provider invocation. Full provider response data, request hash/request ID, expiration, and actual provider name are persisted and replayed; inserts no longer silently discard conflicts. The concurrency test uses synchronized goroutines and asserts one provider call. Unit/race suites and build pass. | PostgreSQL-backed concurrency execution was skipped because `TEST_DATABASE_URL` is unset. |
| 5. Ingest donation intent | COMPLETE (implementation) | working tree | Palantir calls carry shared bearer metadata and per-RPC deadlines, with authenticated in-process gRPC coverage. Idempotency uses explicit `IN_PROGRESS`/`COMPLETED` states, stale recovery, deterministic intent/donation IDs, and never replays incomplete status-zero responses. Ingest runs the shared outbox dispatcher. Unit/race suites and build pass. | PostgreSQL crash-window execution and end-to-end JetStream delivery remain unrun because local infrastructure is unavailable. |
| 6. Webhook normalization | NOT STARTED | | | |
| 7. Saruman donation/ledger | NOT STARTED | | | |
| 8. WS delivery/replay | NOT STARTED | | | |
| 9. Donation E2E | NOT STARTED | | | |
| 10. Payout | NOT STARTED | | | |
| 11. Refund | NOT STARTED | | | |
| 12. Jobs/reconciliation/replay | NOT STARTED | | | |
| 13. Operational hardening | NOT STARTED | | | |
| 14. Release qualification | NOT STARTED | | | |
| 15. Handover/completion audit | NOT STARTED | | | |

Allowed statuses: `NOT STARTED`, `IN PROGRESS`, `BLOCKED`, `COMPLETE`, `DEFERRED WITH APPROVAL`.

---

## 25. Commit and review boundaries

### Recommended commit size

Each commit should be independently reviewable and keep tests green. Useful boundaries are:

1. Contract/document change.
2. Migration plus migration tests.
3. Domain/repository code plus unit/integration tests.
4. Transport/entrypoint wiring.
5. Integration/failure test.
6. Operational/documentation update.

Avoid one cross-repository commit that combines unrelated formatting, dependency upgrades, migrations, domain behavior, and documentation.

### Cross-repository changes

When a contract change requires coordinated repositories:

- Land/freeze the almanac contract first.
- Regenerate and validate `inflora-shared` second.
- Keep consumers backward-compatible during rollout when feasible.
- Record the required deployment order.
- Do not delete old event/RPC compatibility until all producers/consumers have migrated.

### Database migration policy

- Use forward-compatible additive migrations first.
- Deploy code that tolerates old/new fields before destructive cleanup.
- Never rely on a multi-service simultaneous deployment for correctness.
- Treat destructive schema removal as a separate, explicitly approved cleanup phase.

---

## 26. Validation command matrix

Agents must inspect each Makefile before running targets; the following are the expected baseline commands, not permission to invent missing targets.

### Workspace

```bash
cd /Users/frederickmarvel/Inflora/backend
make test-all
make build-all
```

### Per Go repository

For each changed repository, run the supported equivalents of:

```bash
go test ./...
go test -race ./...
go build ./...
go vet ./...
```

Run `make test`, `make build`, and `make lint` when defined.

### Contracts

From the directory containing `buf.yaml`, run the repository-supported equivalents of:

```bash
buf lint
buf generate
buf breaking --against <approved-baseline>
```

Verify generated files have no unexpected diff after regeneration.

### Migrations

Validate:

1. Empty database -> latest.
2. Current baseline -> latest.
3. Down/up for the new migration in an isolated disposable database when supported.
4. Application startup against the migrated schema.

### Integration

Use the checked-in orchestration command established in Phase 9. The command must return non-zero on failed assertions and clean up or preserve diagnostics deterministically.

---

## 27. Blocker and escalation rules

Stop implementation and mark the phase `BLOCKED` when any of these occur:

- A required event/RPC/HTTP field or name is not frozen.
- Two services still appear to own the same write.
- A financial transition lacks an approved posting template.
- A provider semantic cannot be determined from official documentation/sandbox behavior.
- A migration would destroy or reinterpret existing data.
- A required test cannot be made deterministic with the available environment.
- Implementing the requested behavior would violate append-only ledger rules or durable idempotency.

The blocker report must include:

1. Exact conflicting files/sections.
2. The smallest decision needed.
3. Two or more viable options where appropriate.
4. The recommended choice and tradeoff.
5. Which phases are prevented from proceeding.

Do not resolve financial or ownership ambiguity by choosing silently in code.

---

## 28. Required evidence for backend completion

The final release report must link or include:

- Contract-drift resolution table.
- Migration test output.
- Workspace unit/build/lint/race output.
- Donation, payout, and refund E2E output.
- Failure-injection matrix results.
- Ledger balance/invariant report.
- Outbox backlog and dead-letter clean-state evidence after E2E.
- WebSocket restart/multi-replica replay evidence.
- Security/redaction scan results.
- Load-test environment and percentile report.
- Known limitations and approved deferrals.
- Deployment/rollback order.

Without this evidence, the backend remains in implementation or qualification, not complete.

---

## 29. Immediate next action

Start with **Phase 0 only**. Do not begin migrations or service implementation until the almanac unambiguously freezes:

1. Internal Palantir provider-result events.
2. CHARGED versus SETTLED semantics.
3. Ledger posting templates and operation keys.
4. Saruman payout/refund command ownership.
5. WebSocket durable sequence and replay semantics.
6. Overlay internal-auth header behavior.

After those gates pass, execute Phases 1 and 2 in order. Only then begin service feature phases.
