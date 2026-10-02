# Architecture Checklist

Detail for `/em-plan` Phase 3 (Architecture Design). **Not to fill out blindly** — use as a trigger for forcing questions.

ASCII diagram conventions, what makes a good invariant, failure mode enumeration approach, etc.

---

## 1. Component Boundaries

### Goal
State explicitly what's **inside the scope of change** and what's **outside**. Boundary = a contract that can't be violated.

### ASCII box convention

```
┌─────────────────────┐
│   PaymentService    │
│  ┌───────────────┐  │
│  │  Idempotency  │  │  ← split out because reused
│  │     Cache     │  │
│  └───────────────┘  │
└──────────┬──────────┘
           │ calls
           ▼
┌─────────────────────┐
│ PaymentProviderAPI  │  ← external (out of repo)
└─────────────────────┘
```

### Forcing questions

1. **What's inside, what's outside?** Lines must be drawn firmly. Vague boundary = vague responsibility = vague ownership.

2. **What contract does the external system here have?** SLA, retry policy, error semantics, rate limit. State explicitly.

3. **Who owns this module?** Conway's Law check. If there's no clear owner, the service will become an orphan in 6 months.

---

## 2. Data Flow

### Goal
Trace the lifecycle: where data comes in, what it passes through, where it goes out. ASCII diagram is **required** for flows > 2 hops.

### ASCII arrow convention

```
[User]
   │ POST /orders
   ▼
[OrderController]
   │ validate + dispatch
   ▼
[OrderService] ──── enqueue ────▶ [OrderQueue]
                                       │
                                       │ consume
                                       ▼
                                  [OrderWorker]
                                       │
                                       ▼
                                  [Database]
```

### Forcing questions

1. **Synchronous vs async at each hop?** State explicitly. User-facing latency = sum of sync hops only.

2. **Failure at hop X, what's the behavior?** Per hop:
   - Retry?
   - Dead letter?
   - User-facing error?
   - Silent log + retry later?

3. **Backpressure?** If a downstream hop is slow, what happens upstream? (queue accumulate, drop, error?)

4. **Does ordering matter?** FIFO, key-based ordering, or no ordering needed?

5. **Exactly-once / at-least-once / at-most-once?** Be explicit. Vague = future bug.

---

## 3. State Machine

### Goal
Required to draw if entity has state count >2. Implicit state in your head = future bug source.

### ASCII state convention

```
                ┌──────────┐
   create  ────▶│  PENDING │
                └────┬─────┘
                     │ approve
                     ▼
                ┌──────────┐         reject       ┌──────────┐
                │ APPROVED │────────────────────▶│ REJECTED │
                └────┬─────┘                      └──────────┘
                     │ ship
                     ▼
                ┌──────────┐
                │ SHIPPED  │
                └──────────┘
```

### Forcing questions

1. **Are state transitions exhaustively allowed?** What is NOT allowed to transition? (e.g. SHIPPED → PENDING must be impossible.)

2. **Side effect per transition?** Database write, event emit, notification — listed per transition.

3. **Concurrency on state?** What happens if 2 actors try to transition simultaneously? Lock? Optimistic concurrency? Last-write-wins?

4. **Who can transition?** Auth/role check per transition.

---

## 4. Trust Boundaries

### Goal
Identify **where data is validated** vs **where data is trusted as-is**. Common attack vector = a wrong trust boundary.

### Common boundaries

- **HTTP request → Server** — input must be validated. Schema check, sanitization, auth check.
- **Database → Application** — usually trusted (data writer-controlled), but check if there are user-input fields.
- **External API → Application** — semi-trusted. Validate response schema.
- **Service A → Service B (internal)** — trusted in shared cluster, **not trusted** if cross-tenant.
- **User session → Authorization** — never trust user-supplied role/identity. Always re-derive from session.

### Forcing questions

1. **Each data point — where is it validated?** The trust boundary must be explicit. Duplicate validation (across multiple boundaries) = OK; missing validation = bug.

2. **Authorization check — where?** Pre-controller (middleware), per-endpoint, or per-record? Be explicit.

3. **Secret crossing boundary?** API key, token, password. Storage encrypted? Transport encrypted?

---

## 5. Invariants

### Goal
"What must always be true." Statements more specific than prose, but not necessarily formal logic.

### Good invariant characteristics
- **Specific** — not abstract
- **Testable** — can be written as an assert
- **Stateful** — about data/state, not code style
- **Falsifiable** — clear violation criteria

### Examples

✅ **Good:**
- "Account balance can never be negative."
- "Once an order is shipped, it cannot transition back to pending."
- "Session tokens are never logged or persisted in plaintext."
- "Every webhook event is acknowledged exactly once (idempotent processing by event ID)."
- "User can only access records owned by their tenant."

❌ **Bad:**
- "TBD" — if you can't state it, the plan isn't ready
- "Code is clean" — not an invariant, that's an aspiration
- "No bugs" — not an invariant, that's impossible
- "Performance is good" — not an invariant; if yes — quantify (e.g. "P99 latency < 200ms")

---

## 6. Failure Modes

### Goal
Enumerate what can go wrong, plus how the system reacts. Table form mandatory.

### Format

| # | Scenario | Test? | Handling? | Visible to user? | Severity |
|---|----------|-------|-----------|-------------------|----------|
| 1 | Network timeout to upstream | ✓ | ✓ retry | Loud retry message | Med |
| 2 | Race condition in concurrent write | ✗ | ✗ | Silent corruption | **Critical** |
| 3 | Invalid input from user | ✓ | ✓ validate | Error message | Low |

### Critical gap definition
**No test + no handling + silent** = **critical gap**. Block before em-works handoff.

### Forcing questions per row

1. "Failure scenario [X] — covered by test? Path: [test name / location]"
2. "Failure handling — graceful degrade, retry, hard fail? Choice rationale?"
3. "User-visible — error visible immediately, or silent until detected later?"
4. "Severity — if it happens in prod, blast radius?"

### Common scenarios to enumerate (checklist)

- Network: timeout, connection refused, DNS fail
- Concurrency: race, deadlock, double-submit
- Data: empty, max size, malformed, NULL
- External: rate limit, partial failure, schema mismatch
- Resource: out of memory, disk full, file handle exhausted
- Auth: expired token, missing permission, invalid signature

---

## 7. Single Points of Failure

### Goal
Identify SPOFs. For each, decide: **accept** (with rationale) or **mitigate**.

### Common SPOFs

- Database master (mitigate: replica, failover)
- Single message queue cluster (mitigate: multi-region)
- Single deployment region (accept: SLA permits, business decision)
- Single external API dependency (mitigate: cached fallback, queue retry)
- Single team / engineer that owns domain (mitigate: pair, document, rotate)

### Forcing questions

1. "SPOF [X] — accept or mitigate?"
2. "If accept — what's the SLA implication, and do stakeholders agree?"
3. "If mitigate — cost vs benefit reasonable?"

---

## ASCII Diagram Anti-Patterns

❌ **Diagram inaccurate vs code** — a stale diagram is worse than no diagram. Update as part of the change.

❌ **Diagram too busy** — if there are >10 boxes or >15 arrows, split into multiple diagrams (component view + data flow view + state view).

❌ **Diagram with unlabeled arrows** — an unlabeled arrow = guesswork. Label with: action ("calls", "writes"), payload ("event"), or condition ("if invalid").

❌ **Skip diagram for flow > 2 hops** — non-trivial flow, prose alone isn't enough. Diagram mandatory.
