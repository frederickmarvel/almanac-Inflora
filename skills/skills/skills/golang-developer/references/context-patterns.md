# Context Propagation Patterns

Stack-specific `context.Context` usage for this microservice layout. For Go context fundamentals (lifecycle, ownership, value key types), see `samber/cc-skills-golang@golang-context`. This file documents what's different *because of the stack*: multi-tenant tracking via context value, NATS consumer scoping, gocron job scoping, fluent repository builders, and fire-and-forget to pools.

## Table of Contents

1. [Tenant & Partner ID in Context](#1-tenant--partner-id-in-context)
2. [Context in Repository Fluent Builder](#2-context-in-repository-fluent-builder)
3. [Context in NATS JetStream Consumer](#3-context-in-nats-jetstream-consumer)
4. [Context in gocron Scheduler Jobs](#4-context-in-gocron-scheduler-jobs)
5. [Fire-and-Forget to Event Pool — `WithoutCancel`](#5-fire-and-forget-to-event-pool--withoutcancel)
6. [Context in Outbound Provider gRPC Calls](#6-context-in-outbound-provider-grpc-calls)
7. [Context in REST → gRPC Gateway Forwarding](#7-context-in-rest--grpc-gateway-forwarding)
8. [Context Helpers (`helpers.GetLocaleFromContext`, etc.)](#8-context-helpers)
9. [Anti-Patterns](#9-anti-patterns)

---

## 1. Tenant & Partner ID in Context

Multi-tenant requests carry `tenant_id` and (optionally) `partner_id` in context — propagated by auth middleware, read by repositories and services.

**Key type — unexported, per package:**

```go
// File: src/helpers/context_keys.go
package helpers

type contextKey int

const (
    keyTenantID contextKey = iota + 1
    keyPartnerID
    keyUserID
    keyRequestID
    keyLocale
    keyTraceID
)
```

**Setter (auth middleware only):**

```go
// File: src/middleware/auth.go — gRPC interceptor
func TenantAuthInterceptor(...) grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        tenantID, err := extractTenantFromMD(ctx)
        if err != nil {
            return nil, status.Error(codes.Unauthenticated, "missing tenant")
        }
        ctx = helpers.WithTenantID(ctx, tenantID)
        return handler(ctx, req)
    }
}

// File: src/helpers/context.go
func WithTenantID(ctx context.Context, id uint64) context.Context {
    return context.WithValue(ctx, keyTenantID, id)
}

func GetTenantID(ctx context.Context) (uint64, bool) {
    id, ok := ctx.Value(keyTenantID).(uint64)
    return id, ok
}
```

**Consumer (service/repository):**

```go
func (s *OrderServiceImpl) Get(ctx context.Context, params *GetOrderParams) (*entity.Order, error, []ParamError) {
    defer helpers.LogAndCatchPanic()

    tenantID, ok := helpers.GetTenantID(ctx)
    if !ok {
        return nil, errors.New("tenant_id missing from context"), nil
    }

    return s.OrderRepo.
        ForTenant(tenantID).      // fluent filter scoped to tenant
        ForID(params.GetID()).
        Get(ctx)
}
```

**Rules:**

- Tenant/partner IDs are `uint64` (matches DB schema). Don't store them as `int` or `string`.
- The key type MUST be unexported and unique per package. Use a typed constant (`type contextKey int`), not `string`, to prevent collisions across packages and silent overwrites.
- Never look up tenant ID via `ctx.Value("tenant_id")` — that's the string-key anti-pattern (→ §9).
- Repository methods that filter by tenant MUST call `ForTenant(id)` explicitly. Do not auto-inject from ctx inside the repository — keep filtering explicit so multi-tenant queries can be audited grep-style.

---

## 2. Context in Repository Fluent Builder

The fluent `For*` builder accumulates state. **Ctx is passed only to the terminal method** (`Get`, `Gets`, `Count`, `Create`, etc.), not to `For*` filters:

```go
order, err := s.OrderRepo.
    ForTenant(tenantID).      // no ctx
    ForStatus("pending").     // no ctx
    ForID(orderID).           // no ctx
    Get(ctx)                  // ctx here — execution boundary
```

**Why:** the `For*` chain is pure query-building; it doesn't I/O. The terminal method opens the GORM session, runs the query, and respects ctx cancellation. Passing ctx to every `For*` would be noise.

**Inside the terminal method:**

```go
func (r *OrderRepoImpl) Get(ctx context.Context) (*entity.Order, error) {
    defer r.clean()  // CRITICAL: clears whereQuery state (→ repository-patterns.md)

    db := r.buildQuery(ctx)  // applies the accumulated For* filters

    var order entity.Order
    if err := db.WithContext(ctx).First(&order).Error; err != nil {
        if errors.Is(err, gorm.ErrRecordNotFound) {
            return nil, nil
        }
        return nil, err
    }
    return &order, nil
}
```

**Rules:**

- ALL terminal methods (`Get`, `Gets`, `Count`, `Create`, `Update`, `Delete`, `GetPaginate`) MUST call `db.WithContext(ctx)` — otherwise ctx cancellation is ignored.
- `defer r.clean()` is NOT a context concern but a state-cleanup concern — leaving stale `whereQuery` means the next call leaks filters. Both `defer cancel()` (when applicable) and `defer r.clean()` go together.

---

## 3. Context in NATS JetStream Consumer

Consumer handlers run in goroutines spawned by the JetStream subscription. The handler's ctx is **NOT** the producer's request ctx — it's a consumer-scoped ctx derived from the engine's lifetime.

```go
// File: src/pool/order_pool.go
func (p *OrderPool) Subscribe(parentCtx context.Context) error {
    _, err := p.js.Subscribe("order.created", func(msg *nats.Msg) {
        // Handler gets a fresh ctx tied to consumer lifetime, NOT producer's request ctx.
        ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
        defer cancel()

        // Restore propagated values (trace_id, tenant_id) from message headers
        ctx = restoreContextFromHeaders(ctx, msg.Header)

        if err := p.handle(ctx, msg); err != nil {
            logger.Error("handler failed", zap.Error(err))
            msg.Nak()
            return
        }
        msg.Ack()
    }, nats.Durable("order-pool-consumer"))
    return err
}

func restoreContextFromHeaders(ctx context.Context, h nats.Header) context.Context {
    if tid := h.Get("X-Tenant-ID"); tid != "" {
        if id, err := strconv.ParseUint(tid, 10, 64); err == nil {
            ctx = helpers.WithTenantID(ctx, id)
        }
    }
    if traceID := h.Get("X-Trace-ID"); traceID != "" {
        ctx = helpers.WithTraceID(ctx, traceID)
    }
    return ctx
}
```

**Rules:**

- The **parent ctx** is the consumer engine's lifecycle ctx (cancelled on supervisord stop / graceful shutdown). Do NOT use `context.Background()` — that disconnects the handler from shutdown signals.
- ALWAYS wrap with `WithTimeout` per message — otherwise a stuck handler blocks the consumer forever.
- ALWAYS `defer cancel()` on the per-message ctx — leaking these accumulates timer goroutines under heavy traffic.
- Restore propagated values (tenant, trace) from NATS headers. The producer side MUST set them when publishing:

```go
// Publisher
msg := &nats.Msg{Subject: "order.created", Data: payload}
msg.Header = nats.Header{}
if tid, ok := helpers.GetTenantID(ctx); ok {
    msg.Header.Set("X-Tenant-ID", strconv.FormatUint(tid, 10))
}
if traceID, ok := helpers.GetTraceID(ctx); ok {
    msg.Header.Set("X-Trace-ID", traceID)
}
js.PublishMsg(msg)
```

**Anti-pattern:** passing the publisher's request `ctx` into the consumer handler via closure capture. The request will return before the message is consumed — the ctx will already be done.

---

## 4. Context in gocron Scheduler Jobs

Each scheduler run gets a **fresh ctx**, not the previous run's. The routine engine creates a per-run ctx scoped to (a) the job's timeout configuration and (b) the engine's lifecycle:

```go
// File: engine/routine/executor.go
func (e *RoutineEngine) executeJob(sch *entity.Scheduler) {
    // Fresh ctx per run, derived from engine lifecycle.
    ctx, cancel := context.WithTimeout(e.engineCtx, sch.GetTimeout())
    defer cancel()

    // Inject tenant context if the job is tenant-scoped
    if sch.TenantID > 0 {
        ctx = helpers.WithTenantID(ctx, sch.TenantID)
    }
    ctx = helpers.WithRequestID(ctx, fmt.Sprintf("cron-%s-%d", sch.Code, time.Now().Unix()))
    ctx = helpers.WithTraceID(ctx, generateTraceID())

    // CronLocker (Redis SetNX) — prevents duplicate execution across replicas
    locker := cron.NewCronLocker(e.redis, sch.Code, sch.GetLockTTL())
    acquired, err := locker.Acquire(ctx)
    if err != nil || !acquired {
        return
    }
    defer locker.Release(ctx)

    defer helpers.LogAndCatchPanic()

    handler := e.jobRegistry[sch.Code]
    if handler == nil {
        logger.Error("unknown job", zap.String("code", sch.Code))
        return
    }
    if err := handler(ctx); err != nil {
        e.reportFailure(ctx, sch, err)
        return
    }
    e.reportSuccess(ctx, sch)
}
```

**Rules:**

- Job ctx parent = `engineCtx` (cancelled on shutdown), not `context.Background()`.
- Each run MUST have its own `WithTimeout` — otherwise a hung job blocks the next run.
- ALWAYS `defer cancel()` — gocron fires jobs at intervals; leaking timers compounds.
- Trace ID MUST be generated per run (use snowflake or UUID v4). Re-using a trace ID across runs makes log correlation impossible.
- CronLocker `Acquire/Release` both take ctx — respect cancellation so a Redis hang doesn't block the entire engine.

---

## 5. Fire-and-Forget to Event Pool — `WithoutCancel`

When a request handler triggers a background operation that **must outlive the request** (audit log, async notification, async PDF generation), use `context.WithoutCancel` (Go 1.21+) to keep propagated values (tenant, trace) without inheriting cancellation:

```go
func (c OrderControllerImpl) Create(ctx context.Context, req *adminv1.CreateOrderReqRPC) (*adminv1.CreateOrderResRPC, error) {
    // ... validation, service call ...
    order, err, _ := c.Service.Create(ctx, params)
    if err != nil {
        return errorResponse(err), nil
    }

    // Audit log MUST be written even if the client disconnects.
    bgCtx := context.WithoutCancel(ctx)
    c.AuditPool.Enqueue(bgCtx, audit.Event{
        TenantID:  helpers.MustGetTenantID(bgCtx),
        TraceID:   helpers.MustGetTraceID(bgCtx),
        Action:    "order.create",
        EntityID:  order.ID,
    })

    return successResponse(order), nil
}
```

**Why `WithoutCancel` and not `context.Background()`:**

- `context.Background()` loses tenant ID, trace ID, request ID, locale — the audit entry becomes orphaned.
- `WithoutCancel` keeps all values but ignores parent cancellation, so the worker can complete after the HTTP/gRPC handler returns.

**When to use:**

| Operation | Use |
|---|---|
| Audit log, journaling | `WithoutCancel` |
| Async notification (email, webhook) | `WithoutCancel` + own timeout for the downstream call |
| PDF / report generation queued to worker | `WithoutCancel` |
| Cache invalidation that must complete | `WithoutCancel` |
| Anything the client *might* care about the result of | Same `ctx` — let cancellation propagate |

**Anti-pattern:** wrapping `WithoutCancel` and then NOT adding a timeout downstream — the background goroutine can block forever on a slow dependency.

```go
// ✗ Bad — no downstream timeout, leak on slow worker
bgCtx := context.WithoutCancel(ctx)
go p.SlowOperation(bgCtx)

// ✓ Good — bounded downstream
bgCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 1*time.Minute)
go func() {
    defer cancel()
    p.SlowOperation(bgCtx)
}()
```

---

## 6. Context in Outbound Provider gRPC Calls

When calling another service via the `src/provider/*` outbound client, propagate the request ctx so deadlines cascade across the call chain:

```go
// File: src/provider/payment_provider.go
func (p *PaymentProviderImpl) Charge(ctx context.Context, req ChargeReq) (*ChargeResp, error) {
    // Derive a per-call timeout from the inbound deadline.
    callCtx, cancel := context.WithTimeout(ctx, p.callTimeout)
    defer cancel()

    // Forward propagated values via gRPC metadata (tenant, trace).
    callCtx = injectMetadata(callCtx)

    return p.client.Charge(callCtx, req.ToProto())
}

func injectMetadata(ctx context.Context) context.Context {
    md := metadata.MD{}
    if tid, ok := helpers.GetTenantID(ctx); ok {
        md.Set("x-tenant-id", strconv.FormatUint(tid, 10))
    }
    if traceID, ok := helpers.GetTraceID(ctx); ok {
        md.Set("x-trace-id", traceID)
    }
    return metadata.NewOutgoingContext(ctx, md)
}
```

**Rules:**

- ALWAYS pass the inbound ctx through. Never call `context.Background()` from a service-layer method.
- ALWAYS add a per-call `WithTimeout` capped at a sane budget — even if the inbound ctx has a deadline, downstream may need a tighter bound.
- Inject tenant/trace via gRPC metadata so the downstream service can restore them on its side (see §3 for the NATS analog).
- Retry loops MUST create a fresh `WithTimeout` per attempt (samber/golang-context eval #2 trap):

```go
for attempt := 0; attempt < 3; attempt++ {
    attemptCtx, cancel := context.WithTimeout(ctx, p.callTimeout)
    resp, err := p.client.Charge(attemptCtx, req.ToProto())
    cancel()  // release immediately after attempt, not via defer in loop
    if err == nil {
        return resp, nil
    }
}
```

Note: `defer cancel()` inside a loop leaks until the function returns. Either call `cancel()` directly after each attempt or move the attempt into its own function.

---

## 7. Context in REST → gRPC Gateway Forwarding

The `engine/rest*` gateways translate HTTP to gRPC. The handler ctx is `r.Context()` (HTTP request lifecycle); grpc-gateway forwards it to the gRPC server with metadata derived from headers.

```go
// File: engine/rest/server.go (grpc-gateway init)
mux := runtime.NewServeMux(
    runtime.WithIncomingHeaderMatcher(headerMatcher),
)

func headerMatcher(key string) (string, bool) {
    // Forward our standard headers as gRPC metadata
    switch strings.ToLower(key) {
    case "x-tenant-id", "x-partner-id", "x-trace-id", "x-locale", "authorization":
        return key, true
    }
    return runtime.DefaultHeaderMatcher(key)
}
```

**On the gRPC side**, the interceptor reads the incoming metadata and re-populates the typed context values (see §1 for the unexported key pattern).

**Rules:**

- DO NOT extract headers in REST middleware then re-attach via `context.WithValue` with string keys. Let grpc-gateway carry them via metadata; let the gRPC server's interceptor convert to typed keys exactly once.
- The HTTP handler's `r.Context()` MUST be passed through — never `context.Background()` mid-handler. (samber/golang-context eval #1 trap.)

---

## 8. Context Helpers

`src/helpers/context.go` exposes the canonical getters/setters. **Use these — do not call `ctx.Value(...)` directly in business code.**

| Helper | Purpose |
|---|---|
| `helpers.WithTenantID(ctx, id) / GetTenantID(ctx) / MustGetTenantID(ctx)` | Tenant scope |
| `helpers.WithPartnerID / GetPartnerID / MustGetPartnerID` | Partner scope (sub-tenant) |
| `helpers.WithRequestID / GetRequestID` | Per-request correlation ID |
| `helpers.WithTraceID / GetTraceID` | Distributed trace ID (OTel-compatible) |
| `helpers.WithLocale / GetLocaleFromContext` | Locale for response messages (i18n) |
| `helpers.WithUserID / GetUserID` | Authenticated principal (admin/insider/public differ) |

**These are the ONLY canonical context helpers.** They live in `src/helpers/context.go` and use the unexported `contextKey` type defined there. If `app.WithTenantID`, `app.WithTraceID`, or any other app-package equivalents exist in the codebase, treat them as **legacy shims** — they may use a different key type, causing silent lookup failures when paired with `helpers.GetTenantID`. Always use the `helpers.*` functions.

**Why `MustGet*`:** for values that auth middleware guarantees, the call site shouldn't litter with `ok` checks. `MustGet*` panics with a clear message — and `helpers.LogAndCatchPanic()` in the service will recover and surface a structured error. Use `MustGet*` in code paths past the auth boundary; use `Get*` in middleware itself or in optional paths (cron jobs without tenant scope).

---

## 9. Anti-Patterns

| Anti-pattern | Why it breaks | Fix |
|---|---|---|
| `context.Background()` inside a request handler | Disconnects from request cancellation; client disconnect doesn't propagate | Use the inbound ctx (`r.Context()` for HTTP, the gRPC handler's `ctx`) |
| `context.WithValue(ctx, "tenant_id", ...)` (string key) | Namespace collision across packages; silent overwrite | Use the unexported `contextKey` type (§1) |
| `app.WithTenantID(ctx, id)` or other non-`helpers` setters | Uses a different unexported key type — `helpers.GetTenantID` returns zero/false; services silently get wrong tenant | Always use `helpers.WithTenantID` from `src/helpers/context.go` (§8) |
| Storing `ctx context.Context` in a struct field | Ctx outlives the call; cancellation semantics break; static analysis flags it | Pass ctx through method parameters; if you need a per-instance lifecycle, store a `cancel` func separately |
| `_ = cancel` after `WithTimeout` | Cancel never called → timer goroutine leak | `defer cancel()` immediately after the `WithTimeout` line |
| `defer cancel()` inside a retry loop | All cancels deferred to function exit; only the last one runs in time | Call `cancel()` directly after each attempt, or wrap each attempt in its own function |
| Passing producer's request ctx into NATS handler via closure | Producer's request is long-done by the time handler runs | Use the consumer's engine ctx + per-message `WithTimeout` (§3) |
| Re-using a single `ctx context.Context` across all cron runs | One job's timeout cancels another's | Per-run `WithTimeout(engineCtx, ...)` (§4) |
| `context.Background()` to keep audit log alive past request | Loses tenant/trace propagation; audit becomes orphaned | `context.WithoutCancel(ctx)` (§5) |
| Repository auto-reads tenant from ctx implicitly | Multi-tenant queries can't be audited grep-style; cross-tenant leaks are silent | Always require explicit `.ForTenant(id)` in fluent chain |
| `db.First(&x)` without `.WithContext(ctx)` | Ctx cancellation ignored; query runs even after client disconnect | `db.WithContext(ctx).First(&x)` (§2) |

---

## Cross-References

- → See `samber/cc-skills-golang@golang-context` for Go context fundamentals (lifecycle, key types, `context.TODO()` vs `context.Background()`, common pitfalls)
- → See `references/service-patterns.md` §6 for `helpers.LogAndCatchPanic()` semantics
- → See `references/repository-patterns.md` for `defer r.clean()` and fluent builder mechanics
- → See `references/scheduler-patterns.md` for CronLocker + multi-mode scheduler details
- → See `references/observability.md` for trace ID generation and OTel correlation
- → See `references/provider-integration-patterns.md` for outbound gRPC SDK shape

## Enforce with Linters

`govet` catches missing `cancel` calls. Enable `contextcheck` in `golangci-lint` to flag missing ctx propagation. See team `.golangci.yml`.
