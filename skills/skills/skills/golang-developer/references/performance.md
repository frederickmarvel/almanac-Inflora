# Performance Patterns

Stack-specific performance work. For Go-generic patterns (sync.Pool, slice growth, escape analysis), see `samber/cc-skills-golang@golang-performance`. This file covers what's different *because of the stack*: pprof endpoints already wired, GORM allocation hotspots, NATS consumer backpressure, scheduler job profiling, decimal-heavy hot paths, and the team's benchmark/profiling workflow.

## Table of Contents

1. [Profile-Before-Optimize](#1-profile-before-optimize)
2. [pprof Endpoints (Wired In)](#2-pprof-endpoints-wired-in)
3. [Workflow: Define → Baseline → Diagnose → Improve → Compare](#3-workflow)
4. [Allocation Hotspots in This Stack](#4-allocation-hotspots-in-this-stack)
5. [Decimal Performance](#5-decimal-performance)
6. [GORM Hot-Path Optimizations](#6-gorm-hot-path-optimizations)
7. [NATS Consumer Throughput & Backpressure](#7-nats-consumer-throughput--backpressure)
8. [Scheduler Job Performance](#8-scheduler-job-performance)
9. [Concurrency: Bounded Workers vs Unbounded Goroutines](#9-concurrency-bounded-workers-vs-unbounded-goroutines)
10. [Caching with Redis CacheManager](#10-caching-with-redis-cachemanager)
11. [Anti-Patterns](#11-anti-patterns)

---

## 1. Profile-Before-Optimize

Performance intuition is wrong ~80% of the time. Never optimize a function before pprof shows it on the hot path. The discipline:

1. Reproduce the slowness on a representative workload (load test, replay, prod traffic mirror).
2. Capture a CPU profile AND a heap profile — `cpu.pprof`, `heap.pprof`.
3. Identify the top 3 cost centers. Optimize one; re-profile.
4. Commit the benchstat output so future readers see the win.

This loop matters more than knowing every micro-optimization. Apply `samber/cc-skills-golang@golang-benchmark` for benchmark hygiene; this file documents *what to look at first* in this stack.

---

## 2. pprof Endpoints (Wired In)

Every engine binds `net/http/pprof` on the metrics port (`:9090`):

| Profile | URL | Use |
|---|---|---|
| CPU (30s) | `/debug/pprof/profile?seconds=30` | Hot functions |
| Heap | `/debug/pprof/heap` | Allocation by type |
| Allocs (alloc_objects) | `/debug/pprof/allocs` | Total allocation pressure |
| Goroutine | `/debug/pprof/goroutine` | Leak / contention diagnosis |
| Block | `/debug/pprof/block` | Where goroutines block (lock, ch) |
| Mutex | `/debug/pprof/mutex` | Lock contention |
| Trace (5s) | `/debug/pprof/trace?seconds=5` | Scheduler-level timeline |

**Block/mutex profiles are off by default** (sampling rate 0). Enable in dev/staging when diagnosing contention:

```go
runtime.SetBlockProfileRate(1)  // 1 = every event; bigger = sample
runtime.SetMutexProfileFraction(1)
```

Don't enable in production unless you accept the overhead.

**Capture & analyze:**

```bash
curl -s 'http://localhost:9090/debug/pprof/profile?seconds=30' > cpu.pprof
go tool pprof -http=:8081 cpu.pprof
# OR text mode
go tool pprof -top -cum cpu.pprof | head -30
```

For continuous profiling in production, consider Pyroscope or Datadog — sample at low rate (e.g., 1% of pods) and aggregate.

---

## 3. Workflow

The team-standard performance cycle, mirroring `samber/cc-skills-golang@golang-performance` adapted to this stack:

1. **Define your metric.** Latency p95? Throughput RPS? RSS? Cron job duration? Without a target, optimizations are random.
2. **Write an atomic benchmark.** One function, one benchmark. Avoid coupling so the result attributes cleanly.
3. **Measure baseline.**
   ```bash
   go test -bench=BenchmarkXxx -benchmem -count=6 ./pkg/... | tee /tmp/report-1.txt
   ```
4. **Diagnose.** CPU profile for hot loops; heap profile for alloc pressure; trace for scheduler contention; mutex profile for lock contention.
5. **Improve.** ONE optimization at a time, with a code comment explaining why.
6. **Compare.**
   ```bash
   go install golang.org/x/perf/cmd/benchstat@latest
   benchstat /tmp/report-1.txt /tmp/report-2.txt
   ```
   Only ship if the difference is statistically significant (`benchstat` highlights it).
7. **Commit.** Paste benchstat output in the body of a `perf(scope): summary` commit so future readers know why the code looks unusual.
8. **Repeat** — next bottleneck.

Keep all `/tmp/report-*.txt` files as an audit trail; don't delete on iteration.

---

## 4. Allocation Hotspots in This Stack

When `heap.pprof` opens, the usual suspects in our codebase:

| Hotspot | Why | Mitigation |
|---|---|---|
| `decimal.Decimal` operations | Each arithmetic op allocates | Cache common values; minimize chained ops; use `decimal.NewFromInt` for constants |
| `gorm.Model` reflection on Create | GORM reflects on every operation | Use `Select(...)` to scope to specific columns; consider `Pluck` for scalar queries |
| JSON marshaling of large entities | Reflection + allocation per field | Switch hot paths to `jsoniter` or hand-rolled `MarshalJSON` |
| `proto.Marshal` for large messages | Allocation per nested message | Reuse message structs with `proto.Reset(msg)` when possible |
| `fmt.Sprintf` in log lines | Format string + arg slice allocation | Use `zap.String/Uint64/...` typed fields — they avoid Sprintf |
| `strings.Split` / `Join` in hot paths | Slice allocation | `bytes.Buffer` or pre-sized slice |
| Goroutine per request without pool | Stack allocation × QPS | Use a worker pool for known-bounded work |

**Practical wins seen on this stack:**

- Replacing `fmt.Sprintf` in log fields → 15–30% allocation drop in hot REST handlers
- Caching `decimal.NewFromInt(0)`, `decimal.NewFromInt(1)`, etc. as package-level vars → measurable on NAV calc paths
- Using `sync.Pool` for transformer DTO structs in p99 endpoints → cuts GC pressure under load

---

## 5. Decimal Performance

`shopspring/decimal` is the team standard. It's correct but allocates on most operations.

**Cache constants:**

```go
// File: src/constant/decimal.go
var (
    Zero      = decimal.NewFromInt(0)
    One       = decimal.NewFromInt(1)
    Hundred   = decimal.NewFromInt(100)
    Thousand  = decimal.NewFromInt(1000)
)
```

Use these instead of repeatedly calling `decimal.NewFromInt(0)` — the latter allocates.

**Avoid string conversion in tight loops:**

```go
// ✗ Bad — String() + NewFromString round-trip
total := decimal.Zero
for _, item := range items {
    a, _ := decimal.NewFromString(item.AmountStr)
    total = total.Add(a)
}

// ✓ Good — keep as decimal once parsed at the boundary
total := decimal.Zero
for _, item := range items {
    total = total.Add(item.Amount)  // item.Amount is decimal already
}
```

**For signature/hash inputs**, `StringFixed(4)` is mandatory (see `security.md` §3) — don't try to avoid the allocation there, correctness wins.

**Alternative:** for true hot paths handling money where decimal is the bottleneck, consider an int64-based money type with explicit scale (e.g., always-cents). Discuss with the team before introducing — it's a stack-deviation.

---

## 6. GORM Hot-Path Optimizations

GORM's reflection-based ORM is convenient but slow vs raw SQL. Targeted wins:

**Select only what you need:**

```go
// ✗ Bad — loads all columns; cost grows with table width
db.Where("status = ?", "pending").Find(&orders)

// ✓ Good — explicit columns
db.Select("id", "amount", "status").Where("status = ?", "pending").Find(&orders)
```

**Use `Pluck` for scalar columns:**

```go
var ids []uint64
db.Model(&entity.Order{}).Where("status = ?", "pending").Pluck("id", &ids)
```

**Batch operations:**

```go
// ✗ Bad — N round trips
for _, order := range orders { db.Create(&order) }

// ✓ Good — single INSERT
db.CreateInBatches(orders, 100)
```

**Avoid N+1:**

```go
// Use Preload only for known-needed associations
db.Preload("Items").Find(&orders)
```

But: don't `Preload` everything by default — it's a join-bomb on wide entities. Profile first.

**Skip GORM for truly hot reads:** raw SQL with `database/sql` directly (or `sqlx`) for read-only endpoints serving > 1k RPS — keep the GORM path for writes and complex queries.

**Connection pool sizing:** the default in `infrastructure.md` §1 (`MaxOpenConns=10`, `MaxIdleConns=2`) is per-instance. With N pods and a DB max_connections limit, the budget is `N × MaxOpenConns`. Verify your DB can handle it.

---

## 7. NATS Consumer Throughput & Backpressure

JetStream consumers run on a worker goroutine. If handlers are slow, the consumer falls behind — JetStream buffers messages, but the lag grows and breaches SLO.

**Symptoms:**

- `nats_consumer_processed_total` rate < publish rate → backlog growing
- Consumer's `num_pending` rising in NATS monitoring

**Mitigations:**

1. **Parallel processing within a consumer:** subscribe with a worker pool that fans out per-message work, bounded:

   ```go
   sem := make(chan struct{}, 10)  // 10 in-flight
   _, err := js.Subscribe("order.created", func(msg *nats.Msg) {
       sem <- struct{}{}
       go func() {
           defer func() { <-sem }()
           handle(msg)
       }()
   })
   ```

   Beware ordering — if order matters, don't parallelize within one subject; partition by key with multiple consumers.

2. **Batch ack:** ack after a batch of messages instead of per-message — fewer round trips to JetStream.

3. **Move slow work out of band:** if a handler takes > 100ms, the slow part likely belongs in a worker pool reading from another NATS subject. Keep handlers fast; queue further work.

4. **Profile the handler:** capture a CPU profile while the consumer is under load. Hot spots are usually serialization (proto unmarshal) or DB writes — same fixes as REST.

**MaxAckPending:** the consumer's `MaxAckPending` limit caps the number of unacked messages. Default per-consumer is 1000; if your handler is slow, raise temporarily to let the buffer absorb spikes — but the real fix is making the handler faster.

---

## 8. Scheduler Job Performance

A cron job that overruns its interval causes overlap (handled by CronLocker) and SLO violations. Diagnose:

1. Check `scheduler_job_duration_seconds{job_code="..."}` histogram. p99 close to the interval → at risk.
2. Add an OTel span around `handler(ctx)` (already done in §3 of `scheduler-patterns.md`).
3. If the job is doing batch DB work, the win is usually:
   - `LIMIT` the batch size per run; let the next run pick up where this left off
   - Index the filter column (especially `status` + date range)
   - Use `UPDATE ... LIMIT N` for state transitions instead of fetch-then-update

**Pattern: process in chunks with bookmark:**

```go
const batchSize = 500
for {
    var orders []entity.Order
    err := s.OrderRepo.
        ForStatusIn("pending").
        ForCreatedBefore(cutoff).
        OrderByIDAsc().
        Limit(batchSize).
        Gets(ctx)
    if err != nil { return err }
    if len(orders) == 0 { break }

    // Process batch
    for _, o := range orders { ... }

    if len(orders) < batchSize { break }
}
```

CronLocker TTL should be at least 2× the expected job duration so it doesn't expire mid-run.

---

## 9. Concurrency: Bounded Workers vs Unbounded Goroutines

Spawning a goroutine per work item under load → memory explosion + scheduler overload.

**Bounded worker pool:**

```go
type Worker struct {
    in chan Task
}

func NewWorker(n int, fn func(context.Context, Task)) *Worker {
    w := &Worker{in: make(chan Task, n*2)}
    for i := 0; i < n; i++ {
        go func() {
            for task := range w.in {
                fn(task.Ctx, task)
            }
        }()
    }
    return w
}
```

**`errgroup` for fan-out within a request:**

```go
g, gctx := errgroup.WithContext(ctx)
g.SetLimit(8)
for _, item := range items {
    item := item
    g.Go(func() error {
        return process(gctx, item)
    })
}
if err := g.Wait(); err != nil {
    return err
}
```

`errgroup` cancels siblings on first error — correct behavior for "all-or-nothing" batches.

→ See `samber/cc-skills-golang@golang-concurrency` for goroutine lifecycle patterns.

---

## 10. Caching with Redis CacheManager

Cache hits drop p99 latency dramatically. Patterns:

**Cache-aside (read-through):**

```go
func (s *ProductServiceImpl) Get(ctx context.Context, id uint64) (*entity.Product, error) {
    key := fmt.Sprintf("product:%d", id)
    var p entity.Product
    if err := s.Cache.Get(ctx, key, &p); err == nil {
        return &p, nil
    }
    // Miss → DB
    prod, err := s.ProductRepo.ForID(id).Get(ctx)
    if err != nil || prod == nil { return prod, err }
    _ = s.Cache.Set(ctx, key, prod, 5*time.Minute)
    return prod, nil
}
```

**Cache invalidation on write:**

```go
func (s *ProductServiceImpl) Update(ctx context.Context, ...) (...) {
    // ... update DB ...
    bgCtx := context.WithoutCancel(ctx)
    _ = s.Cache.Delete(bgCtx, fmt.Sprintf("product:%d", id))
    return prod, nil, nil
}
```

Use `WithoutCancel` so cache invalidation completes even if the client disconnects (→ `context-patterns.md` §5).

**Avoid:**

- Caching write-heavy entities — invalidation cost > read savings
- Long TTLs on data that changes — staleness bugs
- Cache key without tenant scope — cross-tenant leaks (`product:%d` should usually be `product:%d:%d` with tenant_id)

**Negative caching (cache misses):** consider for hot keys that frequently miss, e.g., cache "not found" for 30s to absorb stampedes.

---

## 11. Anti-Patterns

| Anti-pattern | Impact | Fix |
|---|---|---|
| Optimizing without profiling | Wasted effort; often makes code worse | Capture CPU/heap profile first |
| Benchmarks that include setup | Skewed measurements | Use `b.ResetTimer()` after setup |
| Single benchmark run | Noise dominates | `-count=6` + benchstat |
| `sync.Pool` for objects whose zero value isn't safe | Subtle correctness bugs | Pool only for safely-resettable objects; document the contract |
| Re-allocating `decimal.Zero` everywhere | Allocation pressure | Use package-level cached constants |
| Loading all columns via `Find()` on wide table | Bytes wasted; GC pressure | `Select(...)` explicit columns |
| Unbounded goroutine per request | OOM under load | Bounded worker pool / `errgroup.SetLimit` |
| Cache key without tenant scope | Cross-tenant leak | Include `tenant_id` in cache key |
| `Preload` everything by default | Join-bomb; slow queries | Preload only what the caller needs |
| MaxOpenConns × pods > DB max_connections | DB refuses connections during spike | Compute the budget; alert on high utilization |
| Synchronous slow work in NATS handler | Backlog grows; SLO breach | Async handoff to worker pool; profile the handler |

---

## Cross-References

- → See `samber/cc-skills-golang@golang-performance` for Go-generic optimization patterns
- → See `samber/cc-skills-golang@golang-benchmark` for benchmark methodology
- → See `samber/cc-skills-golang@golang-concurrency` for goroutine patterns
- → See `references/infrastructure.md` §1 for GORM connection pooling defaults
- → See `references/scheduler-patterns.md` §6 for the per-run CronLocker mechanics
- → See `references/context-patterns.md` §5 for `WithoutCancel` background work
- → See `references/observability.md` §4 for the metrics that drive these decisions
