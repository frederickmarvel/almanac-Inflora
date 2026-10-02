# Observability Patterns

Stack-specific logging, tracing, and metrics for this microservice layout. The three pillars are **Zap structured logging**, **OpenTelemetry distributed tracing**, and **Prometheus-compatible metrics** — all wired so a single `trace_id` correlates logs across services and a single dashboard surfaces SLO signals.

## Table of Contents

1. [Structured Logging with Zap](#1-structured-logging-with-zap)
2. [Mandatory Log Fields](#2-mandatory-log-fields)
3. [Trace Context Propagation (OpenTelemetry)](#3-trace-context-propagation-opentelemetry)
4. [Metrics: gRPC, REST, Scheduler, DB, NATS](#4-metrics-grpc-rest-scheduler-db-nats)
5. [Log Level Policy](#5-log-level-policy)
6. [Log Correlation Across Services](#6-log-correlation-across-services)
7. [Health Check Endpoints](#7-health-check-endpoints)
8. [Anti-Patterns](#8-anti-patterns)

---

## 1. Structured Logging with Zap

Use the package-level singleton in `src/logger/`. Never use `fmt.Println` or `log.Printf` in business code — those bypass structured fields and severity routing.

```go
// File: src/logger/logger.go
var log *zap.Logger = newLogger()

func newLogger() *zap.Logger {
    cfg := zap.NewProductionConfig()
    if viper.GetString("MODE") != "production" {
        cfg = zap.NewDevelopmentConfig()
    }
    cfg.EncoderConfig.TimeKey = "ts"
    cfg.EncoderConfig.EncodeTime = zapcore.ISO8601TimeEncoder
    l, _ := cfg.Build(zap.AddCallerSkip(1))
    return l
}

func Info(msg string, fields ...zap.Field) { log.Info(msg, fields...) }
func Warn(msg string, fields ...zap.Field) { log.Warn(msg, fields...) }
func Error(msg string, fields ...zap.Field) { log.Error(msg, fields...) }
func With(ctx context.Context, fields ...zap.Field) *zap.Logger {
    fields = append(fields, ctxFields(ctx)...)
    return log.With(fields...)
}
```

**`logger.With(ctx, ...)` is the canonical entry point** for any log call inside a request scope — it automatically attaches tenant ID, trace ID, request ID, and span ID from context.

```go
// Usage in service
func (s *OrderServiceImpl) Create(ctx context.Context, params *CreateOrderParams) (*entity.Order, error, []ParamError) {
    defer helpers.LogAndCatchPanic()

    l := logger.With(ctx, zap.String("op", "order.create"))
    l.Info("creating order", zap.Uint64("amount", params.Amount))

    // ... business logic ...

    if err != nil {
        l.Error("order create failed", zap.Error(err))
        return nil, err, nil
    }
    l.Info("order created", zap.Uint64("order_id", order.ID))
    return order, nil, nil
}
```

---

## 2. Mandatory Log Fields

Every log line emitted by request-scoped code MUST carry these fields (auto-attached by `logger.With(ctx, ...)`):

| Field | Type | Source | Why |
|---|---|---|---|
| `ts` | ISO8601 string | Zap encoder | Time correlation |
| `level` | string | Zap | Filter/alert |
| `caller` | `file:line` | Zap | Locate code path |
| `trace_id` | string | ctx → OTel span context | Cross-service correlation |
| `span_id` | string | ctx → OTel span context | Per-span identification |
| `request_id` | string | ctx (auth middleware) | Per-request correlation |
| `tenant_id` | uint64 | ctx | Multi-tenant filtering |
| `partner_id` | uint64 (optional) | ctx | Sub-tenant filtering |
| `service` | string | env var `SERVICE_NAME` | Source identification |
| `tier` | string (`admin`/`insider`/`public`/`routine`) | engine init | Which API surface |
| `op` | string | call-site annotation | Logical operation name |

**Helper:**

```go
func ctxFields(ctx context.Context) []zap.Field {
    fields := []zap.Field{}
    if tid, ok := helpers.GetTraceID(ctx); ok {
        fields = append(fields, zap.String("trace_id", tid))
    }
    if sid, ok := helpers.GetSpanID(ctx); ok {
        fields = append(fields, zap.String("span_id", sid))
    }
    if rid, ok := helpers.GetRequestID(ctx); ok {
        fields = append(fields, zap.String("request_id", rid))
    }
    if tnt, ok := helpers.GetTenantID(ctx); ok {
        fields = append(fields, zap.Uint64("tenant_id", tnt))
    }
    if prt, ok := helpers.GetPartnerID(ctx); ok {
        fields = append(fields, zap.Uint64("partner_id", prt))
    }
    return fields
}
```

**Rule:** if a log line in business code uses `logger.Info/Warn/Error` directly without `With(ctx, ...)`, that's a review-blocking issue — the line is unfilterable in production.

---

## 3. Trace Context Propagation (OpenTelemetry)

Tracing flows through every layer: REST → gRPC → service → repository → outbound provider → NATS publish → consumer (downstream service).

**Setup (engine init):**

```go
// File: engine/grpc/server.go
tp, err := tracer.InitProvider(ctx, tracer.Config{
    ServiceName:    viper.GetString("SERVICE_NAME"),
    Endpoint:       viper.GetString("OTEL_EXPORTER_OTLP_ENDPOINT"),
    SamplingRatio:  viper.GetFloat64("OTEL_SAMPLING_RATIO"),
})
defer tp.Shutdown(ctx)

grpcServer := grpc.NewServer(
    grpc.UnaryInterceptor(
        chain(
            otelgrpc.UnaryServerInterceptor(),  // first — establishes span
            sidInterceptor,
            tenantAuthInterceptor,
            zapInterceptor,
            recoveryInterceptor,
        ),
    ),
)
```

**Inside a service**, the OTel SDK reads the current span from context — manual span creation only for business-meaningful operations:

```go
func (s *OrderServiceImpl) Create(ctx context.Context, params *CreateOrderParams) (*entity.Order, error, []ParamError) {
    ctx, span := tracer.Start(ctx, "OrderService.Create",
        trace.WithAttributes(
            attribute.Int64("tenant_id", int64(params.TenantID)),
            attribute.Int64("amount", params.Amount),
        ),
    )
    defer span.End()

    // ... work ...

    if err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return nil, err, nil
    }
    span.SetAttributes(attribute.Uint64("order_id", order.ID))
    return order, nil, nil
}
```

**Outbound propagation:**

- **gRPC outbound:** otelgrpc client interceptor auto-injects W3C trace headers into gRPC metadata.
- **NATS publish:** manually inject via message headers (see `context-patterns.md` §3) — there is no auto-injection for NATS.
- **HTTP outbound:** wrap `http.RoundTripper` with `otelhttp.NewTransport` for auto-injection of `traceparent` header.

**Sampling:** default to `0.1` (10%) in production via `OTEL_SAMPLING_RATIO`; `1.0` in dev. Always-sample for error spans by configuring `ParentBased(TraceIDRatio(...))` with error-biased sampling.

---

## 4. Metrics: gRPC, REST, Scheduler, DB, NATS

Use Prometheus instrumentation via the standard interceptors and the `prometheus/client_golang` library. Metrics are exposed at `:9090/metrics` (separate from the API ports).

### Standard metrics (auto-emitted by interceptors)

| Metric | Type | Labels | Source |
|---|---|---|---|
| `grpc_server_started_total` | counter | `grpc_service`, `grpc_method` | otelgrpc / prom interceptor |
| `grpc_server_handled_total` | counter | + `grpc_code` | same |
| `grpc_server_handling_seconds` | histogram | + `grpc_code` | same |
| `http_requests_total` | counter | `path`, `method`, `status` | REST middleware |
| `http_request_duration_seconds` | histogram | same | same |
| `scheduler_job_runs_total` | counter | `job_code`, `result` (success/failure/skipped) | routine engine |
| `scheduler_job_duration_seconds` | histogram | `job_code` | same |
| `db_connections_open` | gauge | — | GORM hook |
| `nats_consumer_processed_total` | counter | `subject`, `result` (ack/nak) | pool |

### Custom business metrics

For SLO-relevant business events, register a counter/histogram at package level:

```go
var (
    orderCreatedTotal = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "orders_created_total",
            Help: "Total orders created.",
        },
        []string{"tenant_id", "status"},
    )
)

func init() { prometheus.MustRegister(orderCreatedTotal) }
```

**Cardinality discipline:** never label with `request_id`, `order_id`, or any unbounded value — that blows Prometheus memory. Tenant ID is acceptable if the tenant count is bounded (< few thousand); use a hash or `tenant_tier` label otherwise.

---

## 5. Log Level Policy

| Level | When | Examples |
|---|---|---|
| `Debug` | Local dev only — never in production | Raw GORM SQL, full request body |
| `Info` | Normal operations, state transitions, successful business events | "order created", "scheduler job completed", "consumer ack" |
| `Warn` | Recoverable issues, fallbacks taken, soft errors | "retry attempt 2", "cache miss fell back to DB", "validation failed" |
| `Error` | Operation failed; needs investigation | "transaction rollback", "HMAC mismatch", "external service unavailable" |
| `Fatal` | Process cannot continue — exits with code 1 | Startup config invalid, required dependency unreachable on boot |

**Rules:**

- `MODE=production` → log level `Info`. Never enable `Debug` in production.
- `Fatal` is reserved for boot-time failures. After the engine is running, an `Error` plus letting supervisord restart is preferred to `Fatal`.
- `Warn` is for soft failures the operator might want to see; `Error` is for incidents. Pick one and be consistent — if every error logs at both `Warn` and `Error`, alerts double-fire.

---

## 6. Log Correlation Across Services

A single client request can traverse 3–5 services. Correlation requires three IDs flowing intact:

| ID | Set by | Carried through | Propagated via |
|---|---|---|---|
| `trace_id` | edge gateway (entry point) | All spans, all logs | OTel W3C headers; NATS `X-Trace-ID` header |
| `request_id` | edge gateway (entry point) | All logs in the request scope | gRPC metadata `x-request-id`; NATS `X-Request-ID` |
| `span_id` | each service's local OTel SDK | Logs from that service only | implicit (per-span) |

**At log aggregation (Loki / Elasticsearch / CloudWatch):**

- Query by `trace_id` → all services' logs for one request, ordered by `ts`
- Query by `tenant_id` + time range → debug a specific tenant
- Query by `op` + `level=error` → error budget breakdown by operation

**Worked example.** A 500 on `POST /admin/orders`:

1. Open the trace in OTel UI by `trace_id` → see which service has the red span
2. Filter logs by `trace_id` in Loki → read the surrounding context
3. Cross-check with `scheduler_job_runs_total{result="failure"}` if the error was in async path

Without `trace_id` in every log, this debugging loop fails. The "missing trace fields" review flag in `SKILL.md` exists for this reason.

---

## 7. Health Check Endpoints

Each engine exposes:

| Endpoint | Returns | Use |
|---|---|---|
| `GET /health` | 200 if up | k8s liveness / supervisord readiness |
| `GET /ready` | 200 if dependencies reachable (DB, Redis, NATS) | k8s readiness / load balancer |
| `GET /metrics` | Prometheus exposition format | Scrape |
| gRPC `grpc.health.v1.Health/Check` | `SERVING` / `NOT_SERVING` | gRPC clients & service mesh |

**`/ready` MUST check actual dependency connectivity** — not just "the server is bound to a port". A common bug: `/ready` returns 200 while the DB is unreachable, so the load balancer sends traffic to a broken instance. Verify the check actually pings the dependency on each call (with a short timeout, e.g., 1s).

---

## 8. Anti-Patterns

| Anti-pattern | Why it breaks | Fix |
|---|---|---|
| `fmt.Println("error:", err)` in business code | Bypasses structured fields; no level routing; not aggregated | `logger.With(ctx, ...).Error("...", zap.Error(err))` |
| `logger.Info("...")` without `With(ctx, ...)` | No `trace_id` / `tenant_id` — log is unfilterable | Always `logger.With(ctx, ...).Info(...)` in request scope |
| Logging full request body at Info | PII leak + log volume explosion | Log specific fields; redact sensitive ones |
| Custom span everywhere, including trivial getters | Trace UI noise; sampling cost | Manual span only for business-meaningful operations |
| Prometheus label with `order_id` or other unbounded value | Cardinality explosion; OOM on the scraper | Bucket into categories; never per-entity labels |
| `Fatal` after boot | Crashes a healthy process; kills in-flight requests | `Error` + supervisord restart |
| `/ready` returns 200 without checking deps | Load balancer sends traffic to broken pod | Actually ping the dep on each call (short timeout) |
| Logging error AND returning it AND letting interceptor log it again | Triple-logged errors clutter the index | Choose one layer: usually the highest layer that has business context |

---

## Cross-References

- → See `references/context-patterns.md` for trace ID propagation through NATS / cron / outbound gRPC
- → See `references/infrastructure.md` §7 for Zap logger init details
- → See `references/grpc-patterns.md` for interceptor chain (SID/Info/Zap/Recovery/Auth) ordering
- → See `references/security.md` for PII redaction in logs
- → See `samber/cc-skills-golang@golang-observability` for Go-generic observability patterns (when this skill is unavailable)
