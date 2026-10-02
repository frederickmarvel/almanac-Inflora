# Concurrency Patterns

Stack-specific concurrency. For Go-generic fundamentals (channel semantics, race-condition theory, goroutine scheduling), see `samber/cc-skills-golang@golang-concurrency`. This file covers what's different *because of the stack*: where goroutines actually spawn in our binaries, which `sync` primitives are correct for each layer, cache stampede protection, NATS consumer ordering, GORM thread-safety claim, and the team's `go test -race` policy.

## Table of Contents

1. [Where Goroutines Spawn (Stack Map)](#1-where-goroutines-spawn-stack-map)
2. [Primitive Decision Matrix](#2-primitive-decision-matrix)
3. [`sync.Mutex` / `RWMutex` — App Singletons & Caches](#3-syncmutex--rwmutex--app-singletons--caches)
4. [`sync.Once` — Lazy Init](#4-synconce--lazy-init)
5. [`sync.Pool` — Allocation Reduction](#5-syncpool--allocation-reduction)
6. [`atomic` — Counters & Flags](#6-atomic--counters--flags)
7. [`errgroup` vs `sync.WaitGroup`](#7-errgroup-vs-syncwaitgroup)
8. [Channel Patterns: Fan-Out, Fan-In, Pipeline](#8-channel-patterns)
9. [Singleflight: Cache Stampede Protection](#9-singleflight-cache-stampede-protection)
10. [NATS Consumer Ordering](#10-nats-consumer-ordering)
11. [GORM Thread-Safety Reality](#11-gorm-thread-safety-reality)
12. [Provider Connection Reuse](#12-provider-connection-reuse)
13. [Goroutine Leak Detection](#13-goroutine-leak-detection)
14. [`go test -race` Policy](#14-go-test--race-policy)
15. [Anti-Patterns](#15-anti-patterns)

---

## 1. Where Goroutines Spawn (Stack Map)

Knowing the goroutine inventory is half the battle. In a running engine, these are the goroutine sources, in roughly descending count:

| Source | Count | Lifecycle | Concurrency concern |
|---|---|---|---|
| gRPC server handlers | per-request, capped by `grpc.MaxConcurrentStreams` | request-bound | ctx propagation, panic recovery |
| REST gateway handlers | per-request | request-bound | same |
| NATS JetStream consumers | 1 per subscription, +N if parallelized (§10) | engine-bound | ordering, ack/nak, backpressure |
| gocron scheduler ticks | 1 per scheduled job per tick | per-run | CronLocker, per-run ctx (`context-patterns.md` §4) |
| Worker pools (`src/worker/`) | bounded N | engine-bound | bounded channel inbox |
| Event pools (`src/pool/`) | 1 per pool consumer | engine-bound | NATS-side semantics |
| `context.WithoutCancel` fire-and-forget | per call site | bounded by own ctx | own timeout required (`context-patterns.md` §5) |
| Logger Zap async sink | 1 (singleton) | engine-bound | `logger.Sync()` on shutdown |
| OTel exporter batch sender | 1 (singleton) | engine-bound | flush on shutdown |
| Metrics scraper / GC | runtime | n/a | n/a |

**Rule:** every goroutine MUST have a known termination — either bound to a context (cancellation), a closed channel, or a bounded operation. Spawning a goroutine without a stop signal is a leak in the making (§13).

---

## 2. Primitive Decision Matrix

Pick the smallest primitive that fits:

| Need | Use | Why not the alternatives |
|---|---|---|
| Protect a struct field from concurrent read/write | `sync.Mutex` | `RWMutex` is heavier; only use when reads >> writes AND lock is held long enough that the contention matters |
| Mostly-read, infrequently-written cache | `sync.RWMutex` | `Mutex` would serialize reads |
| One-time initialization | `sync.Once` | Mutex + bool works but is verbose and error-prone |
| Object reuse (transient allocations on hot path) | `sync.Pool` | Manual freelist is bug-prone; GC integration matters |
| Monotonic counter (RPS, byte count) | `atomic.Int64.Add` | Mutex is overkill |
| Boolean flag (shutdown, ready) | `atomic.Bool` | Same |
| Fan-out N tasks, wait for all, propagate first error | `errgroup.Group` | `WaitGroup` doesn't propagate errors; needs error channel + select boilerplate |
| Fan-out N tasks, all must complete, no error semantics | `sync.WaitGroup` | `errgroup` is fine too; pick whichever is clearer |
| Coalesce duplicate concurrent requests for same key | `golang.org/x/sync/singleflight` | Mutex-per-key works but is finer-grained than needed |
| Limit concurrent operations | `errgroup.SetLimit` or buffered channel as semaphore | Manual counter+mutex reinvents this |
| Cross-process distributed lock | Redis CronLocker (`scheduler-patterns.md` §8) | In-process primitives don't span instances |

**When in doubt:** start with `sync.Mutex`. Optimize to `RWMutex` / `atomic` only when profiling shows the lock is contended (§14 with `-mutexprofile`).

---

## 3. `sync.Mutex` / `RWMutex` — App Singletons & Caches

**Pattern: in-process cache with `RWMutex`:**

```go
// File: src/app/feature_flag_cache.go
type FeatureFlagCache struct {
    mu    sync.RWMutex
    flags map[string]bool
}

func (c *FeatureFlagCache) Get(key string) bool {
    c.mu.RLock()
    defer c.mu.RUnlock()
    return c.flags[key]
}

func (c *FeatureFlagCache) Set(key string, val bool) {
    c.mu.Lock()
    defer c.mu.Unlock()
    if c.flags == nil {
        c.flags = make(map[string]bool)
    }
    c.flags[key] = val
}

func (c *FeatureFlagCache) Snapshot() map[string]bool {
    c.mu.RLock()
    defer c.mu.RUnlock()
    out := make(map[string]bool, len(c.flags))
    for k, v := range c.flags {
        out[k] = v
    }
    return out
}
```

**Rules:**

- ALWAYS `defer mu.Unlock()` immediately after `Lock()` — never an inline `Unlock()` at function end; panic-safe via defer.
- READ holders MUST use `RLock`/`RUnlock`. Calling `RLock` then mutating is a race the compiler won't catch — `-race` will.
- DO NOT hold a mutex across I/O calls (DB, Redis, RPC). That blocks every other reader; convert to read-snapshot pattern: copy-under-lock, do I/O outside.
- DO NOT take two mutexes in different orders across goroutines — deadlock. Document lock order at the package level if multiple mutexes interact.
- A `RWMutex` is NOT recursive in Go. Calling `RLock` while already holding `RLock` in the same goroutine deadlocks under writer contention.

**Anti-pattern:** mutex inside a hot per-request path. If the lock is contended, the entire request fleet serializes. Move to `atomic`, `sync.Map`, or sharded mutexes.

---

## 4. `sync.Once` — Lazy Init

Engine singletons that are expensive to construct (DB connection, NATS conn, OTel provider) use `sync.Once`:

```go
// File: src/database/database.go
var (
    db     *gorm.DB
    dbOnce sync.Once
)

func GetDB() *gorm.DB {
    dbOnce.Do(func() {
        db = mustOpenDB()
    })
    return db
}
```

**Rules:**

- `sync.Once.Do(f)` runs `f` exactly once across all goroutines. Subsequent calls return after the first `f` completes.
- If `f` panics, the Once is still "done" — subsequent calls return without retrying. Make `f` idempotent and `mustX`-style (panic = boot-time fail).
- Don't use `Once` for things that may legitimately need reinit (config reload, key rotation). Use a versioned cache or explicit `Reload()` method.

`Once` is the right primitive even when the surrounding code is single-threaded today — it's cheap insurance against accidental concurrent init from a future engine refactor.

---

## 5. `sync.Pool` — Allocation Reduction

For per-request scratch buffers, transformer DTOs, or proto messages on hot paths, pooling cuts GC pressure. See `performance.md` §4 for the win sizes.

```go
var dtoPool = sync.Pool{
    New: func() any { return new(OrderDTO) },
}

func transform(order *entity.Order) *adminv1.OrderData {
    dto := dtoPool.Get().(*OrderDTO)
    defer func() {
        dto.Reset()        // CRITICAL: clear all fields before returning to pool
        dtoPool.Put(dto)
    }()
    dto.ID = order.ID
    dto.Amount = order.Amount.StringFixed(4)
    return dto.ToProto()
}
```

**Rules:**

- The pooled type MUST have a `Reset()` (or equivalent) that zeroes every field. Forgetting to reset a single pointer field leaks the previous value into the next caller — a tenant data leak risk in this stack.
- DO NOT pool types whose zero value isn't safe (pointers, embedded maps that need allocation).
- Pool only for objects with **measurable** allocation cost. `sync.Pool` itself has overhead — pooling a `struct{ int }` makes things slower.
- Items in `sync.Pool` may be evicted at any time (between GC cycles). Treat `Get()` as "you might get a fresh `New()` instance" — never depend on previous state.

---

## 6. `atomic` — Counters & Flags

For monotonic counters (RPS, byte counts) and boolean flags (shutdown, ready), `sync/atomic` is faster than a mutex by an order of magnitude.

```go
type ConsumerStats struct {
    processed atomic.Int64
    errors    atomic.Int64
    shutdown  atomic.Bool
}

func (s *ConsumerStats) Tick(err error) {
    if err != nil {
        s.errors.Add(1)
    } else {
        s.processed.Add(1)
    }
}

func (s *ConsumerStats) Snapshot() (processed, errs int64) {
    return s.processed.Load(), s.errors.Load()
}
```

**Rules (Go 1.19+):**

- Use the typed wrappers (`atomic.Int64`, `atomic.Bool`, `atomic.Pointer[T]`) — NOT the legacy `atomic.AddInt64` / `atomic.LoadInt64` functions on raw `int64`. Typed wrappers prevent alignment bugs and are easier to read.
- DO NOT mix `atomic` access with plain `=` assignment of the same variable. Either everywhere atomic or everywhere mutex-protected.
- `atomic.Bool.CompareAndSwap` is the right primitive for "claim ownership exactly once" without a mutex.
- DO NOT use `atomic` for "check then act" multi-step logic — that needs a mutex or CAS loop.

**`atomic.Pointer[T]`** is great for **lock-free read-mostly state** (e.g., the current config snapshot that occasionally rotates):

```go
type ConfigCache struct {
    snapshot atomic.Pointer[Config]
}

func (c *ConfigCache) Reload(cfg *Config) {
    c.snapshot.Store(cfg)
}

func (c *ConfigCache) Get() *Config {
    return c.snapshot.Load()
}
```

Readers never block; writers swap the pointer atomically. The previous snapshot lives until no goroutine references it.

---

## 7. `errgroup` vs `sync.WaitGroup`

The team default for fan-out work in a service method is **`errgroup`** — it propagates the first error, cancels siblings, and supports concurrency limits.

```go
import "golang.org/x/sync/errgroup"

func (s *OrderServiceImpl) BulkProcess(ctx context.Context, ids []uint64) ([]ProcessResult, error, []ParamError) {
    defer helpers.LogAndCatchPanic()

    g, gctx := errgroup.WithContext(ctx)
    g.SetLimit(8)  // bounded concurrency

    results := make([]ProcessResult, len(ids))
    for i, id := range ids {
        i, id := i, id  // REQUIRED on Go <1.22: shadows loop vars so each closure captures its own copy; redundant on Go 1.22+ (per-iteration semantics), but harmless — always include it or note why it's absent
        g.Go(func() error {
            r, err := s.process(gctx, id)
            if err != nil {
                return err
            }
            results[i] = r  // index assignment is race-free
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        return nil, err, nil
    }
    return results, nil, nil
}
```

**When `WaitGroup` is correct instead:**

- No error semantics needed (fire-and-forget metrics emission)
- You want to wait for goroutines that intentionally don't return errors (e.g., background log flushers)

**Rules:**

- `errgroup.WithContext(ctx)` cancels `gctx` on first error → siblings see cancellation via `gctx.Done()`. Workers MUST respect `gctx` to actually stop early — `g.Go` doesn't kill goroutines.
- `g.SetLimit(N)` caps concurrent `g.Go` calls. Without it, fanning out 10k items spawns 10k goroutines simultaneously.
- `g.Wait()` returns the FIRST error encountered. Other errors are discarded — log them inside the worker if you need to keep them.
- Writing to a shared `results` slice by distinct indices is race-free. Writing to a shared map needs a mutex or `sync.Map`.

---

## 8. Channel Patterns

**Fan-out / Fan-in (worker pool with shared output):**

```go
func ParallelMap[In, Out any](ctx context.Context, items []In, workers int, fn func(context.Context, In) (Out, error)) ([]Out, error) {
    in := make(chan int, len(items))
    out := make([]Out, len(items))

    g, gctx := errgroup.WithContext(ctx)
    g.SetLimit(workers)

    for i := range items {
        in <- i
    }
    close(in)

    for i := 0; i < workers; i++ {
        g.Go(func() error {
            for {
                select {
                case <-gctx.Done():
                    return gctx.Err()
                case idx, ok := <-in:
                    if !ok {
                        return nil
                    }
                    v, err := fn(gctx, items[idx])
                    if err != nil {
                        return err
                    }
                    out[idx] = v
                }
            }
        })
    }
    return out, g.Wait()
}
```

**Pipeline (stage chains):**

When stages have different cost profiles, chain channels — earlier stages can keep producing while later ones drain. Always have an explicit shutdown signal (ctx or "done" channel) so stages can exit cleanly.

**Rules for channels:**

- **Buffer size is a back-pressure decision, not an optimization.** `make(chan X, 1)` smooths over a single tick of slowness; `make(chan X, 1000)` lets producers run far ahead of consumers — usually a bug masquerade.
- **Closing a channel is the SENDER's job, never the receiver's.** Closing from receiver side panics the sender.
- **`for range ch` exits when ch is closed.** `select` on `<-ch` returns the zero value + `!ok` on closed channel — handle the `!ok` case.
- **A leaked goroutine blocked on `<-ch`** can never be GC'd. Always have a `case <-ctx.Done()` arm.

---

## 9. Singleflight: Cache Stampede Protection

When N concurrent requests miss the same cache key, the default behavior is N concurrent DB queries — a stampede. `golang.org/x/sync/singleflight` coalesces them into ONE in-flight query; the other N-1 callers wait and share the result.

```go
import "golang.org/x/sync/singleflight"

type ProductServiceImpl struct {
    Repo  repository.ProductRepository
    Cache cache.CacheManager
    sf    singleflight.Group
}

func (s *ProductServiceImpl) Get(ctx context.Context, id uint64) (*entity.Product, error) {
    key := fmt.Sprintf("product:%d", id)

    // Cache hit fast path
    var p entity.Product
    if err := s.Cache.Get(ctx, key, &p); err == nil {
        return &p, nil
    }

    // Coalesce concurrent misses
    v, err, _ := s.sf.Do(key, func() (any, error) {
        prod, err := s.Repo.ForID(id).Get(ctx)
        if err != nil || prod == nil {
            return prod, err
        }
        _ = s.Cache.Set(ctx, key, prod, 5*time.Minute)
        return prod, nil
    })
    if err != nil {
        return nil, err
    }
    return v.(*entity.Product), nil
}
```

**Rules:**

- Singleflight is per-process. For multi-instance fleets, combine with Redis cache + locker.
- The `key` MUST include tenant scope (`fmt.Sprintf("product:%d:%d", tenantID, id)`) — coalescing across tenants is a data leak.
- The shared function's `ctx` belongs to the FIRST caller — if that caller cancels, the in-flight function continues; other callers still get the result. If you want all callers to cancel together, use `sf.DoChan` and a select on `ctx.Done()`.

→ See `performance.md` §10 for the broader caching pattern.

---

## 10. NATS Consumer Ordering

`nats.Subscribe` with a single consumer processes messages in delivery order — sequential, but slow.

To parallelize within a subject while preserving per-key order:

| Strategy | Order preserved? | Throughput | Notes |
|---|---|---|---|
| Single consumer, sequential | Yes (subject-wide) | 1× | Default; bottleneck on slow handler |
| Single consumer + worker pool with shared queue | NO (interleaving) | N× | Use when order doesn't matter |
| **Multiple durable consumers, hash by key** | Yes (per-key) | N× | Best of both — partition by key |
| `OrderedConsumer` (JetStream) | Yes (subject-wide) | 1× | Stricter ordering guarantees, lower throughput |

**Partition-by-key example:**

```go
// 4 durable consumers, each handling a hash slot
for slot := 0; slot < 4; slot++ {
    slot := slot
    durable := fmt.Sprintf("order-pool-slot-%d", slot)
    _, err := js.Subscribe("order.created", func(msg *nats.Msg) {
        key := msg.Header.Get("X-Tenant-ID")
        if hash(key) % 4 != slot { return }  // skip — wrong slot
        handle(msg)
    }, nats.Durable(durable))
}
```

Better: have the publisher route to per-slot subjects (`order.created.0`, `order.created.1`, ...) so consumers don't filter — the broker does.

**Rules:**

- Default to sequential per-subject ordering unless profiling shows the handler is the bottleneck.
- DO NOT parallelize with `go handle(msg)` inside a single subscription handler without bounding — that's the unbounded goroutine anti-pattern (§15).
- For "exactly-once + ordered" semantics, JetStream's `OrderedConsumer` is the tightest contract; combine with idempotency keys at the handler layer.

→ See `context-patterns.md` §3 for ctx scoping in handlers.

---

## 11. GORM Thread-Safety Reality

GORM documents `*gorm.DB` as safe for concurrent use. That's true for the underlying `*sql.DB` connection pool — but **method-chain builders are NOT safe** to share across goroutines.

```go
// ✗ Bad — chain mutation is shared across goroutines
shared := db.Where("status = ?", "pending")
go shared.Find(&a)
go shared.Where("amount > 0").Find(&b)  // mutates the builder used by other goroutine
```

```go
// ✓ Good — each goroutine starts from the root *gorm.DB
go db.Where("status = ?", "pending").Find(&a)
go db.Where("status = ?", "pending").Where("amount > 0").Find(&b)
```

**Our repository fluent builder** holds `whereQuery` on the struct — that's NOT safe to share across goroutines either. Each goroutine MUST get its own repository instance OR start from a fresh fluent chain. Inside a worker pool that calls the same repo, prefer:

```go
// Single repo, separate fluent chains per call
for _, id := range ids {
    id := id
    g.Go(func() error {
        _, err := s.Repo.ForID(id).Get(gctx)  // ForID starts fresh; clean() at end
        return err
    })
}
```

`defer r.clean()` in execution methods (`repository-patterns.md`) clears `whereQuery` — making the same repo instance usable for the next call. But two goroutines calling `s.Repo.ForID(...)` simultaneously WILL race on `whereQuery`. Solutions:

1. **Make repository methods stateless** — return a query builder, don't store on the receiver. Bigger refactor.
2. **One repo per goroutine** — fan-out goroutines each get an injected repo instance. Cheap; recommended.
3. **Mutex around the chain** — kills parallelism, only acceptable for very low-frequency calls.

Recommended pattern when fanning out from a service:

```go
g, gctx := errgroup.WithContext(ctx)
g.SetLimit(8)
for _, id := range ids {
    id := id
    g.Go(func() error {
        // Construct a fresh fluent chain per call. defer r.clean() inside terminal
        // method resets whereQuery. SAFE only if there are no two concurrent users
        // of the SAME repo instance — verify with -race in CI.
        _, err := s.Repo.ForID(id).Get(gctx)
        return err
    })
}
```

**Verify with `-race`** (§14). If the chain is hot enough to actually race, the test exposes it.

---

## 12. Provider Connection Reuse

Outbound gRPC clients (`src/provider/*`) hold long-lived `*grpc.ClientConn`. `ClientConn` IS safe for concurrent use — you SHOULD share one per provider across all goroutines. Creating one per request is the leak source.

```go
// ✓ Good — one ClientConn at app init, shared via Wire
type PaymentProviderImpl struct {
    client paymentv1.PaymentClient  // wraps a shared *grpc.ClientConn
}

// ✗ Bad — new connection per call
func (p *PaymentProviderImpl) Charge(ctx context.Context, req ChargeReq) error {
    conn, _ := grpc.Dial(...)   // leaks connections, blows past server's MaxConcurrentStreams
    defer conn.Close()
    client := paymentv1.NewPaymentClient(conn)
    return client.Charge(ctx, req.ToProto())
}
```

**Rules:**

- One `ClientConn` per upstream service, created at app init via Wire, lives for the engine lifetime.
- gRPC's HTTP/2 multiplexes many concurrent RPCs over one TCP connection. The pool size you need is usually 1.
- `*sql.DB` (under GORM) is the same shape — singleton; never construct per request.
- `*redis.Client` from `go-redis` is also safe for concurrent use; share one.
- NATS `nats.Conn` is safe for concurrent publish; share one. JetStream context is also concurrent-safe.

---

## 13. Goroutine Leak Detection

A leaked goroutine is one stuck on a channel/lock/syscall with no possible termination. Symptoms:

- `runtime.NumGoroutine()` climbs over time
- `/debug/pprof/goroutine` shows N goroutines blocked at the same call site
- Memory grows even with stable RPS

**Diagnose:**

```bash
curl -s 'http://localhost:9090/debug/pprof/goroutine?debug=2' > goroutines.txt
sort goroutines.txt | uniq -c | sort -rn | head
```

The top entry is your leak's call stack. Common culprits in this stack:

| Stack | Cause |
|---|---|
| `runtime.gopark / nats.(*Subscription).fetchMsg` | NATS consumer not unsubscribed on shutdown |
| `runtime.gopark / chan receive` | Worker goroutine waiting on a channel nobody closes |
| `runtime.gopark / select` | Select arm without `ctx.Done()` — goroutine waits forever |
| `net.(*conn).Read` | Outbound HTTP without timeout; downstream hung |

**In tests**, use `go.uber.org/goleak` to assert no goroutines leak across tests:

```go
func TestMain(m *testing.M) {
    goleak.VerifyTestMain(m)
}
```

This catches leaks in CI before they reach production.

**Prevention checklist (every new goroutine):**

1. Does it have a termination signal (ctx, channel close, bounded op)? Yes / no — if no, fix.
2. Does every `select` have a `ctx.Done()` arm? Yes / no.
3. Does every channel receive handle the `!ok` (closed) case?
4. Does every wait-on-result respect ctx cancellation?

---

## 14. `go test -race` Policy

The race detector is the only tool that catches concurrency bugs reliably. Without it, races are invisible until production shows symptoms (corrupted state, intermittent test failures, weird panics).

**Team policy:**

```bash
# Pre-commit / CI — REQUIRED
go test -race ./...
```

- Every CI run executes `-race`. PR is blocked on failure.
- Local `go test ./...` (no `-race`) for fast iteration is fine, but the final pre-push check is `-race`.
- Benchmarks DO NOT run with `-race` (10-100× slower; misleading numbers).
- Tests that exercise concurrent code paths (cache, worker pool, scheduler) MUST exist — `-race` only flags races in code paths actually exercised.

**Race detector overhead:**

- ~5-10× CPU, ~2× memory. Acceptable for tests; not for production binaries.
- Tagged builds: `-tags=race` is for production canary runs only, in a separate replica.

**Common race-detector findings in this stack:**

- Shared `whereQuery` on repo struct across goroutines (§11)
- Unprotected map write from concurrent handlers
- `time.Time` mutation via aliased `*time.Time`
- `decimal.Decimal` operations that look pure but aliased big.Int internals (rare; depends on version)

---

## 15. Anti-Patterns

| Anti-pattern | Impact | Fix |
|---|---|---|
| `go fn(ctx)` for any per-request work without a bound | Unbounded goroutines under load → OOM | Worker pool / `errgroup.SetLimit` |
| Shared mutex around DB / RPC call | Serializes the entire request fleet on that call | Snapshot-under-lock; I/O outside |
| Two mutexes acquired in inconsistent order | Deadlock | Document lock order; prefer single mutex |
| `_ = sync.Pool.Get()` without Reset before Put | Stale data leak (potentially cross-tenant) | Reset every field before `Put` |
| `atomic.Add` mixed with plain `=` on same var | Race; `-race` flags | All accesses atomic |
| `for range ch` without ctx cancellation arm | Goroutine leak if ch never closes | `select { case <-ctx.Done(): ... case v := <-ch: ... }` |
| `WithTimeout` inside a loop without `cancel()` | Timer goroutine leak | `cancel()` per iteration, not deferred to function end |
| `singleflight.Do` key without tenant scope | Cross-tenant data leak | Include tenant ID in key |
| Sharing repository fluent builder across goroutines | `whereQuery` race | Per-goroutine repo OR fresh chain per call |
| New `grpc.Dial` per request | Connection exhaustion, slow | Shared `ClientConn` (§12) |
| Closing a channel from receiver side | Panic on next send | Sender owns close |
| Ignoring `g.Wait()` error from `errgroup` | Silent failures | Always handle `g.Wait()` return |
| Missing `i, id := i, id` shadow before `g.Go` closure on Go <1.22 | All goroutines capture the loop's final `i`/`id` value — silent wrong-index writes | Add `i, id := i, id` as the first line inside the loop, before `g.Go(func() { ... })`. On Go 1.22+ loop variables are per-iteration by default, making this redundant — mention either the shadow or note Go 1.22+ semantics |
| Production-deploying without `-race` ever run | First race symptom is data corruption | CI gate on `go test -race ./...` |
| `RWMutex.RLock` recursively in same goroutine | Deadlock under writer contention | Restructure; don't nest RLocks |
| Holding mutex during `time.Sleep` | Blocks entire fleet | Sleep outside the critical section |

---

## Cross-References

- → See `samber/cc-skills-golang@golang-concurrency` for Go-generic concurrency fundamentals (channel semantics, scheduler, memory model, common bugs)
- → See `context-patterns.md` §3 for NATS consumer ctx scoping
- → See `context-patterns.md` §4 for gocron job per-run ctx
- → See `context-patterns.md` §5 for `context.WithoutCancel` background work
- → See `performance.md` §9 for the "bounded worker pool" baseline pattern
- → See `performance.md` §10 for cache invalidation + `WithoutCancel`
- → See `scheduler-patterns.md` §8 for CronLocker (distributed lock)
- → See `repository-patterns.md` for `defer r.clean()` and the fluent builder mechanics that interact with §11

## Enforce with Tools

- `go test -race ./...` — CI gate (§14)
- `go.uber.org/goleak` — leak detection in tests (§13)
- `go test -bench -mutexprofile` — surface lock contention (`performance.md` §2)
- `golangci-lint` rules: `contextcheck` (ctx propagation), `gosec` (rule G103 unsafe pointer), team-tuned `unused` for dead lock fields
