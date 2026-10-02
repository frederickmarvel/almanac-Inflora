# Error Handling Patterns

Errors flow through three distinct channels in this stack: **`error`** for system/infrastructure failures, **`[]ParamError`** for field-level user-input validation failures, and **`panic` → `recover`** for unexpected programmer errors. Each channel has a specific handling pattern. Mixing them (e.g., returning a validation issue as `error`) breaks the controller's response mapping.

## Table of Contents

1. [The Three Channels](#1-the-three-channels)
2. [Triple Return: `(result, error, []ParamError)`](#2-triple-return)
3. [`ParamError` Shape & Mandatory Schema](#3-paramerror-shape--mandatory-schema)
4. [Wrapping with `samber/oops`](#4-wrapping-with-samberoops)
5. [Panic Recovery (`helpers.LogAndCatchPanic`)](#5-panic-recovery)
6. [Response Code Matrix (Controller Mapping)](#6-response-code-matrix)
7. [Sentinel vs Wrapped vs Typed Errors](#7-sentinel-vs-wrapped-vs-typed-errors)
8. [Error Logging Policy](#8-error-logging-policy)
9. [Anti-Patterns](#9-anti-patterns)

---

## 1. The Three Channels

| Channel | Carries | Where it originates | Where it's handled |
|---|---|---|---|
| `error` | System/infra failures (DB down, network, malformed proto, unexpected) | Repo, provider, infra calls | Controller → `codes.Internal` / 5xx |
| `[]ParamError` | Field-level user-input issues (missing field, bad format, business-rule violation on a specific field) | Service `Params` validation; service business logic | Controller → `codes.InvalidArgument` / 4xx with `errors` envelope |
| `panic` | Programmer error (nil deref, out-of-bounds, impossible state) | Anywhere | `defer helpers.LogAndCatchPanic()` → logged, surfaced as `error` to caller |

**Rule:** never carry validation in `error` and never carry system failures in `[]ParamError`. The split matters because the controller's response envelope branches on which channel returned non-empty.

---

## 2. Triple Return

Every service method returns three values, in this order:

```go
func (s *OrderServiceImpl) Create(ctx context.Context, params *CreateOrderParams) (*entity.Order, error, []ParamError)
```

1. `result` — the business data; `nil` on any error
2. `error` — system error; `nil` if no system error
3. `[]ParamError` — slice of field-level errors; `nil` or empty if no validation issue

Variant shapes (per `service-patterns.md` §1):

| Method | Signature |
|---|---|
| Single entity | `(*entity.Order, error, []ParamError)` |
| Multiple | `([]*entity.Order, error, []ParamError)` |
| Paginated | `(paginator.Pagination, error, []ParamError)` |
| Count | `(int64, error, []ParamError)` |
| Void | `(error, []ParamError)` |
| Internal/async | `(*entity.Order, error)` — only when there's no user input to validate |

**At the controller**, check in strict order: paramErrors → error → nil result → success. The exact pattern is in `service-patterns.md` §1.

---

## 3. `ParamError` Shape & Mandatory Schema

```go
type ParamError struct {
    Field   string `json:"field"`
    Code    string `json:"code"`
    Message string `json:"message"`
}
```

**Mandatory validation in Params:**

```go
type CreateOrderParams struct {
    TenantID *uint64
    Amount   *decimal.Decimal
    Status   *string
}

func (p *CreateOrderParams) IsMandatoryFilled() bool {
    return p.TenantID != nil && p.Amount != nil && p.Status != nil
}

func (p *CreateOrderParams) MandatorySchema() string {
    // Format: "mandatory: [a & b & c] - unfilled: [missing fields]"
    return "mandatory: [tenant_id & amount & status] - unfilled: [" + p.unfilledList() + "]"
}

func (p *CreateOrderParams) MandatoryErrors() []ParamError {
    errs := []ParamError{}
    if p.TenantID == nil {
        errs = append(errs, ParamError{Field: "tenant_id", Code: "REQUIRED", Message: "tenant_id is required"})
    }
    if p.Amount == nil {
        errs = append(errs, ParamError{Field: "amount", Code: "REQUIRED", Message: "amount is required"})
    }
    if p.Status == nil {
        errs = append(errs, ParamError{Field: "status", Code: "REQUIRED", Message: "status is required"})
    }
    return errs
}
```

**Service entry pattern:**

```go
func (s *OrderServiceImpl) Create(ctx context.Context, params *CreateOrderParams) (*entity.Order, error, []ParamError) {
    defer helpers.LogAndCatchPanic()

    if !params.IsMandatoryFilled() {
        return nil, errors.New(params.MandatorySchema()), params.MandatoryErrors()
    }
    // ... business logic
}
```

**Note:** mandatory validation returns BOTH `error` AND `[]ParamError`. The `error` carries the schema string for logging; the `[]ParamError` carries field-level detail for the response. Controllers must check `[]ParamError` first, so this duplication is harmless and intentional.

**Business-rule validation** (e.g., "amount exceeds available balance") also goes in `[]ParamError`, not `error`:

```go
if params.Amount.GreaterThan(balance) {
    return nil, nil, []ParamError{{
        Field:   "amount",
        Code:    "INSUFFICIENT_BALANCE",
        Message: fmt.Sprintf("amount %s exceeds available balance %s", params.Amount, balance),
    }}
}
```

---

## 4. Wrapping with `samber/oops`

For system errors, use `samber/oops` to attach context (operation, params, hints) that survives through the stack:

```go
import "github.com/samber/oops"

func (s *OrderServiceImpl) processCharge(ctx context.Context, order *entity.Order) error {
    if err := s.PaymentProvider.Charge(ctx, charge); err != nil {
        return oops.
            Code("ORD-E-CHG-001").
            In("OrderService.processCharge").
            With("order_id", order.ID).
            With("amount", order.Amount.String()).
            Tags("payment", "external").
            Hint("Check payment provider status; retry may succeed").
            Wrap(err)
    }
    return nil
}
```

**Why oops over plain `fmt.Errorf("...: %w", err)`:**

- Structured fields land in logs automatically (Zap field extraction)
- `.Code()` matches the team response code convention (tier-domain-severity-action-seq)
- `.Hint()` is captured for operator-facing debugging without exposing it to clients
- Stack trace is preserved

**Convention:**

| oops field | Use |
|---|---|
| `.Code("...")` | Maps 1:1 to the response code (`A-ORD-E-CHG-001`) when the error reaches a controller |
| `.In("Pkg.Method")` | The operation that originated the error |
| `.With(k, v)` | Structured context — surfaced in logs |
| `.Tags("...")` | Categorize for filtering (`payment`, `external`, `transaction`) |
| `.Hint("...")` | Operator-facing remediation hint |
| `.Wrap(err)` / `.Wrapf(err, "...")` | Wrap the underlying cause |

Extract in logger middleware:

```go
if oe, ok := oops.AsOops(err); ok {
    log.Error("operation failed",
        zap.String("code", oe.Code()),
        zap.String("in", oe.In()),
        zap.Any("ctx", oe.Context()),
    )
}
```

---

## 5. Panic Recovery

**Every exported service method** starts with:

```go
defer helpers.LogAndCatchPanic()
```

Implementation (`src/helpers/panic.go`):

```go
func LogAndCatchPanic() {
    if r := recover(); r != nil {
        stack := debug.Stack()
        logger.Error("panic recovered",
            zap.Any("panic", r),
            zap.ByteString("stack", stack),
        )
    }
}
```

This stops a single bad input from crashing the process. The panic is logged with stack trace; the request returns whatever the deferred-function chain produces (typically `nil, nil, nil`, which the controller sees as "system error, no result").

**The pattern is layered:**

1. Service: `defer helpers.LogAndCatchPanic()` in every exported method
2. gRPC: a recovery interceptor (last in the chain) catches anything that escapes the service layer
3. NATS consumer / scheduler job: panic recovery wrapped around the handler invocation

All three layers exist on purpose — the service-layer recover keeps the panic close to its origin (better log context); the outer recovers are insurance.

**When NOT to recover:** programmer errors detected at boot (config missing, key invalid, port unavailable). Those go through `logger.Fatal` so supervisord restarts the process — better than a half-initialized server accepting traffic.

---

## 6. Response Code Matrix

Response codes follow `{TIER}-{DOMAIN}-{SEVERITY}-{ACTION}-{SEQ}`:

| Part | Examples | Meaning |
|---|---|---|
| TIER | `A` (admin), `I` (insider), `P` (public), `G` (generic/shared) | Which API surface |
| DOMAIN | `ORD`, `PAY`, `CST`, `USR`, `SYS` | Business domain |
| SEVERITY | `S` (success), `E` (error), `W` (warn) | Outcome class |
| ACTION | `GET`, `CRT`, `UPD`, `DEL`, `PRC` (process), `CHG` (charge) | What was attempted |
| SEQ | `001`, `002`, ... | Disambiguates within action |

**Generic codes (cross-tier):**

| Code | Meaning |
|---|---|
| `G-SYS-S-GEN-001` | Success |
| `G-SYS-E-GEN-002` | Validation error (paramErrors path) |
| `G-SYS-E-GEN-003` | Resource not found (nil result path) |
| `G-SYS-E-GEN-004` | Unauthorized |
| `G-SYS-E-GEN-005` | Permission denied |
| `G-SYS-E-GEN-006` | Rate limit exceeded |
| `G-SYS-E-GEN-007` | Internal error (uncategorized) |

**Domain-specific examples:**

| Code | When |
|---|---|
| `A-ORD-S-CRT-001` | Admin: order created |
| `A-ORD-E-CRT-002` | Admin: order creation failed — duplicate |
| `A-ORD-E-PRC-001` | Admin: process order failed — invalid state |
| `I-PAY-S-CHG-001` | Insider: charge successful |

**Alert mapping:** `alert.yaml` maps `{code, locale}` → `{type, title, message}` for localized user-facing messages. The transformer reads this when building the response envelope.

→ See `grpc-patterns.md` §6 for the transformer/alert-resolver implementation.

---

## 7. Sentinel vs Wrapped vs Typed Errors

| Form | Use | Example |
|---|---|---|
| **Sentinel** (`var ErrXxx = errors.New("...")`) | Caller needs to branch on identity | `errors.Is(err, gorm.ErrRecordNotFound)` |
| **Wrapped** (`fmt.Errorf("...: %w", err)` or `oops.Wrap(err)`) | Add context while preserving the cause | Most cases |
| **Typed** (`type XxxError struct { ... }`) | Caller needs structured fields | rare; usually `oops.With` is enough |

**Repository convention:** return `nil, nil` (not `nil, gorm.ErrRecordNotFound`) for "not found" — the nil result IS the not-found signal. Reserve `error` for genuine infra failure.

```go
func (r *OrderRepoImpl) Get(ctx context.Context) (*entity.Order, error) {
    defer r.clean()
    var o entity.Order
    if err := r.buildQuery(ctx).First(&o).Error; err != nil {
        if errors.Is(err, gorm.ErrRecordNotFound) {
            return nil, nil  // ← not found = (nil, nil)
        }
        return nil, oops.In("OrderRepo.Get").Wrap(err)
    }
    return &o, nil
}
```

The controller's nil-result check handles "not found" cleanly.

---

## 8. Error Logging Policy

Log errors **once**, at the layer with the most business context.

| Layer | Logs at | Why |
|---|---|---|
| Repository | DEBUG (query trace) only | Caller has more context |
| Provider (outbound) | ERROR (with `oops` context) | Knows the downstream identity |
| Service | ERROR for unexpected failures; INFO for expected | Business-level decision point |
| Controller | DEBUG only (response envelope) | Avoid double-logging |
| Interceptor | ERROR for uncategorized escapes only | Last line of defense |

**Triple-logging is a real issue:** an error logged at the repo, wrapped + re-logged at the service, wrapped + re-logged at the interceptor produces three log entries for one event. Pick one layer. Team standard: the **service** is the canonical logging point for system errors; everywhere else logs only at DEBUG or higher-context derived metrics.

**Sensitive data in errors:** never embed secrets, tokens, decrypted PII, or full request bodies in an error message — it ends up in logs and aggregation indexes. Use `oops.With("user_id", id)` for the ID only, not the credential.

---

## 9. Anti-Patterns

| Anti-pattern | Impact | Fix |
|---|---|---|
| Returning validation issue as `error` | Controller treats it as 500; loses field-level detail | Use `[]ParamError` |
| Returning system failure as `[]ParamError` | Controller returns 400; bug looks like user error | Use `error` |
| Missing `defer helpers.LogAndCatchPanic()` | Panic crashes the process | Add to every exported service method |
| Returning `gorm.ErrRecordNotFound` from repo | Forces every service to check sentinel | Repo returns `nil, nil` |
| Triple-logging the same error | Log volume; alert noise | One canonical log layer (service); others DEBUG |
| `fmt.Errorf("failed: %v", err)` | Loses wrapping (`%v` not `%w`) — `errors.Is/As` won't work | `%w` or `oops.Wrap` |
| Sentinel error per call site | Sentinel explosion; no Go-idiomatic | Use `oops` codes; reserve sentinels for cross-package branching |
| `panic` for expected error paths | Wrong tool — panic is for impossible state | Return `error` |
| Including secret/token in error message | Leak via log aggregation | Log structured ID only |
| `errors.New("invalid input")` in service for a validation issue | No field, no code | `[]ParamError{{Field: ..., Code: ..., Message: ...}}` |

---

## Cross-References

- → See `service-patterns.md` for the full Params interface + triple return mechanics
- → See `grpc-patterns.md` §6 for transformer / alert-resolver implementation
- → See `observability.md` §5 for log level policy
- → See `security.md` §10 for "don't log secrets" detail
- → See `samber/cc-skills-golang@golang-error-handling` for Go-generic error patterns (`errors.Is/As`, wrapping idioms)
- → See `samber/cc-skills-golang@golang-samber-oops` for full oops library reference
