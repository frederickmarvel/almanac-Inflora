# Scheduler Patterns

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Scheduler Mode](#2-scheduler-mode)
3. [Scheduler Entity](#3-scheduler-entity)
4. [Scheduler Repository](#4-scheduler-repository)
5. [Routine Engine](#5-routine-engine)
6. [Job Registration Pattern](#6-job-registration-pattern)
7. [Hot Reload Mechanism](#7-hot-reload-mechanism)
8. [CronLocker (Distributed Lock)](#8-cronlocker-distributed-lock)
9. [Execution Tracking](#9-execution-tracking)
10. [Error Handling & Recovery](#10-error-handling--recovery)
11. [Event Listeners](#11-event-listeners)
12. [Health Check & Metrics](#12-health-check--metrics)
13. [Key Rules](#13-key-rules)

---

## 1. Architecture Overview

The scheduler supports **four operating modes** configurable via environment variable, allowing the same codebase to run in different deployment topologies — from self-scheduling (database) to externally-triggered (HTTP/message) to fully disabled.

```
┌──────────────────────────────────────────────────────────────┐
│                    routine.go (main binary)                   │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  SCHEDULER_MODE = ?                                          │
│  ┌──────────┬──────────┬──────────┬──────────┐               │
│  │ database │  http    │ message  │ disable  │               │
│  │          │          │          │          │               │
│  │ gocron   │ HTTP     │ NATS     │ no-op    │               │
│  │ + DB     │ endpoints│ consumer │          │               │
│  │ + Redis  │ + Redis  │ (single) │          │               │
│  │ locker   │ locker   │          │          │               │
│  └────┬─────┴────┬─────┴────┬─────┴──────────┘               │
│       │          │          │                                │
│       ▼          ▼          ▼                                │
│  ┌────────────────────────────────┐  ┌───────────────┐       │
│  │ executeJob(sch)                │  │ Event          │       │
│  │ (shared across all modes)      │  │ Listeners      │       │
│  │                                │  │ (always run)   │       │
│  │ → Panic recovery               │  │                │       │
│  │ → Execution tracking           │  │ • Journal      │       │
│  │ → Service layer (Wire DI)      │  │ • Transaction  │       │
│  │ → Success/Failure reporting    │  │ • Order        │       │
│  └────────────────────────────────┘  └───────────────┘       │
│                                                              │
│  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐   │
│  │ Redis           │  │ MySQL          │  │ Health HTTP   │   │
│  │ (CronLocker)    │  │ (Scheduler     │  │ GET /health   │   │
│  │                 │  │  table)        │  │ GET /metrics  │   │
│  └────────────────┘  └────────────────┘  └───────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

**Key characteristics:**

- **Multi-mode** — `database`, `http`, `message`, or `disable` via `SCHEDULER_MODE` env
- **Shared job execution** — all modes use the same `executeJob()` pipeline (panic recovery, tracking, reporting)
- **Hot reload** — database mode reloads every 15 seconds without restart
- **Distributed locking** — Redis-based `CronLocker` in `database` and `http` modes
- **Exactly-once via NATS** — `message` mode uses single consumer for HA without Redis
- **6-field cron** — includes seconds: `Second Minute Hour DayOfMonth Month DayOfWeek`

---

## 2. Scheduler Mode

Set via Viper constant `SCHEDULER_MODE` in `.env` or config source:

```env
SCHEDULER_MODE=database    # default
```

### Mode Comparison

| Aspect | `database` | `http` | `message` | `disable` |
|--------|-----------|--------|-----------|-----------|
| Trigger | gocron (self-scheduling) | External HTTP call | Broker message (NATS, RabbitMQ, etc.) | None |
| Schedule source | `schedulers` table | External (Cloud Scheduler, K8s CronJob) | External publisher | — |
| CronLocker | Yes (Redis) | Yes (Redis) | No (broker guarantees single consumer) | — |
| Hot reload | Yes (15s) | N/A (stateless) | N/A (event-driven) | — |
| Execution tracking | Full (DB) | Full (DB) | Full (DB) | — |
| Multi-replica safe | Via Redis lock | Via Redis lock | Via broker's consumer model | — |
| Broker driver | — | — | `SCHEDULER_MESSAGE_DRIVER` (nats, redis, google, rabbitmq, nsq) | — |
| Best for | Single/few replicas, self-contained | Cloud Run, serverless, external cron | HA with multiple replicas | Maintenance window |

### Mode Initialization

```go
func RunRoutine() {
    mode := viper.GetString(constant.SCHEDULER_MODE)
    if mode == "" {
        mode = "database"
    }

    // Event listeners always run (regardless of mode)
    go startJournalListener()
    go startTransactionListener()
    go startOrderListener()

    // Health check always runs
    go startHealthServer()

    switch mode {
    case "database":
        runDatabaseMode()
    case "http":
        runHTTPMode()
    case "message":
        runMessageMode()
    case "disable":
        runDisableMode()
    default:
        log.Fatal("unknown SCHEDULER_MODE", zap.String("mode", mode))
    }
}
```

### Mode: `database`

The default mode. gocron runs internally, schedules loaded from the `schedulers` table, hot-reloaded every 15 seconds, with Redis CronLocker for multi-replica safety.

```go
func runDatabaseMode() {
    tz := viper.GetString(constant.SCHEDULER_TZ)
    if tz == "" {
        tz = "UTC"
    }
    loc, _ := time.LoadLocation(tz)

    s := gocron.NewScheduler(loc)
    locker := helpers.NewCronLocker(cache.Cache)
    scheduledAt := map[string]*time.Time{}

    s.Every(15).Seconds().Do(func() {
        reloadJobs(s, locker, scheduledAt)
    })

    s.StartBlocking()
}
```

See §5–§9 for full details on job loading, hot reload, locking, and tracking.

### Mode: `http`

Exposes HTTP endpoints. An external scheduler (Google Cloud Scheduler, K8s CronJob, plain cron) hits the endpoint to trigger a job. The path encodes both **tag** and **code**:

```
POST /scheduler/{tag}/{code}
```

```go
func runHTTPMode() {
    port := viper.GetString(constant.SCHEDULER_HTTP_PORT)
    if port == "" {
        port = "8091"
    }

    locker := helpers.NewCronLocker(cache.Cache)

    mux := http.NewServeMux()

    // Trigger endpoint: POST /scheduler/{tag}/{code}
    mux.HandleFunc("/scheduler/", func(w http.ResponseWriter, r *http.Request) {
        if r.Method != http.MethodPost {
            http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
            return
        }

        // Parse path: /scheduler/{tag}/{code}
        parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/scheduler/"), "/")
        if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
            http.Error(w, "path must be /scheduler/{tag}/{code}", http.StatusBadRequest)
            return
        }
        tag, code := parts[0], parts[1]

        // Lookup scheduler from database
        repo := repository.NewSchedulerRepository(database.GetDB())
        sch, err := repo.ForTag(tag).ForCode(code).Get(context.Background())
        if err != nil || sch == nil {
            http.Error(w, fmt.Sprintf("scheduler not found: %s/%s", tag, code), http.StatusNotFound)
            return
        }

        if sch.IsActive != 1 {
            w.WriteHeader(http.StatusOK)
            json.NewEncoder(w).Encode(map[string]interface{}{
                "status":  "skipped",
                "reason":  "scheduler inactive",
                "code":    code,
            })
            return
        }

        // Execute with CronLocker (prevent double-trigger)
        err = locker.TryRunWithLock(r.Context(), sch.Code, 5*time.Minute, func() error {
            updateSchedulerExecutionTime(sch)
            return executeJob(sch)
        })

        if err != nil {
            updateSchedulerFailed(sch, err.Error())
            w.WriteHeader(http.StatusInternalServerError)
            json.NewEncoder(w).Encode(map[string]interface{}{
                "status": "error",
                "code":   code,
                "error":  err.Error(),
            })
            return
        }

        w.WriteHeader(http.StatusOK)
        json.NewEncoder(w).Encode(map[string]interface{}{
            "status": "ok",
            "code":   code,
        })
    })

    // List all registered schedulers
    mux.HandleFunc("/schedulers", func(w http.ResponseWriter, r *http.Request) {
        repo := repository.NewSchedulerRepository(database.GetDB())
        schedulers, _ := repo.ForTag("main").GetAll(context.Background())

        type entry struct {
            Tag    string `json:"tag"`
            Code   string `json:"code"`
            Name   string `json:"name"`
            Active bool   `json:"active"`
            Path   string `json:"path"`
        }
        var list []entry
        for _, sch := range schedulers {
            list = append(list, entry{
                Tag:    sch.Tag,
                Code:   sch.Code,
                Name:   sch.Name,
                Active: sch.IsActive == 1,
                Path:   fmt.Sprintf("/scheduler/%s/%s", sch.Tag, sch.Code),
            })
        }

        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(list)
    })

    log.Info("scheduler HTTP mode", zap.String("port", port))
    http.ListenAndServe(fmt.Sprintf(":%s", port), mux)
}
```

**Endpoints:**

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/scheduler/{tag}/{code}` | Trigger a specific job |
| `GET` | `/schedulers` | List all schedulers with their trigger paths |
| `GET` | `/health` | Liveness (from shared health server) |
| `GET` | `/metrics` | Prometheus metrics |

**External trigger example (Google Cloud Scheduler):**
```bash
# Trigger transaction processing
curl -X POST http://routine-service:8091/scheduler/main/TRXPRC

# Trigger order expiry
curl -X POST http://routine-service:8091/scheduler/main/ORDEXP

# List available jobs
curl http://routine-service:8091/schedulers
```

**Why CronLocker still matters in HTTP mode:** An external scheduler might retry on timeout, or K8s CronJob might create overlapping pods. The Redis lock prevents double-execution even when the trigger source has at-least-once semantics.

### Mode: `message`

Consumes messages from a broker to trigger jobs. The broker is **abstracted behind an interface** — swap between NATS, NSQ, Redis Pub/Sub, Google Pub/Sub, RabbitMQ, or any custom implementation via `SCHEDULER_MESSAGE_DRIVER` env.

**No Redis CronLocker needed** — the broker itself guarantees single-consumer delivery.

#### MessageBroker Interface

```go
// src/scheduler/broker.go

// Message represents a received job trigger.
type Message struct {
    Tag  string // Scheduler tag (e.g., "main")
    Code string // Scheduler code (e.g., "TRXPRC")
    Raw  []byte // Optional payload from publisher
}

// MessageBroker abstracts the message consumption layer.
// Implementations MUST guarantee single-consumer-at-a-time delivery
// (via queue groups, competing consumers, or equivalent mechanism).
type MessageBroker interface {
    // Subscribe starts consuming messages. The handler is called for each
    // received message. Subscribe blocks until ctx is cancelled or an
    // unrecoverable error occurs.
    Subscribe(ctx context.Context, handler func(msg Message) error) error

    // Close gracefully shuts down the broker connection.
    Close() error
}
```

#### Driver Resolution

```go
// src/scheduler/broker_factory.go

func NewMessageBroker() (MessageBroker, error) {
    driver := viper.GetString(constant.SCHEDULER_MESSAGE_DRIVER)
    if driver == "" {
        driver = "nats" // default
    }

    switch driver {
    case "nats":
        return NewNATSBroker()
    case "nsq":
        return NewNSQBroker()
    case "redis":
        return NewRedisBroker()
    case "google":
        return NewGooglePubSubBroker()
    case "rabbitmq":
        return NewRabbitMQBroker()
    default:
        return nil, fmt.Errorf("unknown SCHEDULER_MESSAGE_DRIVER: %s", driver)
    }
}
```

#### runMessageMode (broker-agnostic)

```go
func runMessageMode() {
    broker, err := scheduler.NewMessageBroker()
    if err != nil {
        log.Fatal("failed to create message broker", zap.Error(err))
    }
    defer broker.Close()

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    // Subscribe blocks — handler called per message
    err = broker.Subscribe(ctx, func(msg scheduler.Message) error {
        // Lookup scheduler from database
        repo := repository.NewSchedulerRepository(database.GetDB())
        sch, err := repo.ForTag(msg.Tag).ForCode(msg.Code).Get(context.Background())
        if err != nil || sch == nil {
            log.Warn("scheduler not found",
                zap.String("tag", msg.Tag),
                zap.String("code", msg.Code))
            return nil // Ack — don't redeliver invalid codes
        }

        if sch.IsActive != 1 {
            return nil // Ack — silently skip inactive
        }

        // Execute — no CronLocker needed, broker guarantees single delivery
        updateSchedulerExecutionTime(sch)
        if err := executeJob(sch); err != nil {
            updateSchedulerFailed(sch, err.Error())
            return err // Nak — trigger redelivery
        }

        return nil // Ack
    })

    if err != nil {
        log.Fatal("message broker subscription failed", zap.Error(err))
    }
}
```

#### Driver: NATS JetStream

```go
// src/scheduler/broker_nats.go

type NATSBroker struct {
    js   nats.JetStreamContext
    sub  *nats.Subscription
}

func NewNATSBroker() (*NATSBroker, error) {
    js := pool.GetJetStream()

    // Ensure stream exists
    _, err := js.AddStream(&nats.StreamConfig{
        Name:     "SCHEDULER",
        Subjects: []string{"scheduler.>"},
        Storage:  nats.FileStorage,
        MaxAge:   24 * time.Hour,
    })
    if err != nil {
        return nil, fmt.Errorf("failed to create SCHEDULER stream: %w", err)
    }

    return &NATSBroker{js: js}, nil
}

func (b *NATSBroker) Subscribe(ctx context.Context, handler func(msg Message) error) error {
    var subErr error
    b.sub, subErr = b.js.QueueSubscribe(
        "scheduler.>",
        "scheduler-worker",
        func(m *nats.Msg) {
            // Parse subject: scheduler.{tag}.{code}
            parts := strings.Split(m.Subject, ".")
            if len(parts) != 3 {
                m.Ack()
                return
            }

            err := handler(Message{Tag: parts[1], Code: parts[2], Raw: m.Data})
            if err != nil {
                m.Nak() // Redelivery
            } else {
                m.Ack()
            }
        },
        nats.Durable("scheduler-consumer"),
        nats.MaxDeliver(3),
        nats.AckWait(10*time.Minute),
        nats.MaxAckPending(1),
    )
    if subErr != nil {
        return subErr
    }

    <-ctx.Done()
    return nil
}

func (b *NATSBroker) Close() error {
    if b.sub != nil {
        return b.sub.Unsubscribe()
    }
    return nil
}
```

**Topic format:** `scheduler.{tag}.{code}`

**Publishing:**
```go
js.Publish("scheduler.main.TRXPRC", nil)
```

#### Driver: Redis Pub/Sub

```go
// src/scheduler/broker_redis.go

type RedisBroker struct {
    client *redis.Client
    pubsub *redis.PubSub
}

func NewRedisBroker() (*RedisBroker, error) {
    client := cache.GetRedisClient()
    return &RedisBroker{client: client}, nil
}

func (b *RedisBroker) Subscribe(ctx context.Context, handler func(msg Message) error) error {
    // Subscribe to pattern: scheduler.*.*
    b.pubsub = b.client.PSubscribe(ctx, "scheduler.*.*")
    defer b.pubsub.Close()

    ch := b.pubsub.Channel()
    for {
        select {
        case <-ctx.Done():
            return nil
        case m := <-ch:
            // Parse channel: scheduler.{tag}.{code}
            parts := strings.Split(m.Channel, ".")
            if len(parts) != 3 {
                continue
            }
            handler(Message{Tag: parts[1], Code: parts[2], Raw: []byte(m.Payload)})
            // Redis Pub/Sub has no ack/nak — fire-and-forget
        }
    }
}

func (b *RedisBroker) Close() error {
    if b.pubsub != nil {
        return b.pubsub.Close()
    }
    return nil
}
```

**Note:** Redis Pub/Sub is fire-and-forget — no redelivery on failure. Use only when job loss is acceptable, or pair with CronLocker for idempotency.

**Publishing:**
```go
cache.Cache.Publish(ctx, "scheduler.main.TRXPRC", "")
```

#### Driver: Google Pub/Sub

```go
// src/scheduler/broker_google.go

type GooglePubSubBroker struct {
    client *pubsub.Client
    sub    *pubsub.Subscription
}

func NewGooglePubSubBroker() (*GooglePubSubBroker, error) {
    projectID := viper.GetString(constant.GCP_PROJECT_ID)
    client, err := pubsub.NewClient(context.Background(), projectID)
    if err != nil {
        return nil, err
    }

    subName := viper.GetString(constant.SCHEDULER_MESSAGE_SUBSCRIPTION)
    if subName == "" {
        subName = "scheduler-worker"
    }

    sub := client.Subscription(subName)
    sub.ReceiveSettings.MaxOutstandingMessages = 1 // Single consumer
    sub.ReceiveSettings.NumGoroutines = 1

    return &GooglePubSubBroker{client: client, sub: sub}, nil
}

func (b *GooglePubSubBroker) Subscribe(ctx context.Context, handler func(msg Message) error) error {
    return b.sub.Receive(ctx, func(ctx context.Context, m *pubsub.Message) {
        // Tag and Code from message attributes
        tag := m.Attributes["tag"]
        code := m.Attributes["code"]
        if tag == "" || code == "" {
            m.Ack()
            return
        }

        err := handler(Message{Tag: tag, Code: code, Raw: m.Data})
        if err != nil {
            m.Nack()
        } else {
            m.Ack()
        }
    })
}

func (b *GooglePubSubBroker) Close() error {
    return b.client.Close()
}
```

**Publishing:**
```go
topic.Publish(ctx, &pubsub.Message{
    Attributes: map[string]string{"tag": "main", "code": "TRXPRC"},
})
```

#### Driver: RabbitMQ

```go
// src/scheduler/broker_rabbitmq.go

type RabbitMQBroker struct {
    conn *amqp.Connection
    ch   *amqp.Channel
}

func NewRabbitMQBroker() (*RabbitMQBroker, error) {
    url := viper.GetString(constant.RABBITMQ_URL)
    conn, err := amqp.Dial(url)
    if err != nil {
        return nil, err
    }

    ch, err := conn.Channel()
    if err != nil {
        return nil, err
    }

    // Declare exchange and queue
    ch.ExchangeDeclare("scheduler", "topic", true, false, false, false, nil)
    ch.QueueDeclare("scheduler-worker", true, false, false, false, nil)
    ch.QueueBind("scheduler-worker", "scheduler.*.*", "scheduler", false, nil)
    ch.Qos(1, 0, false) // Prefetch 1 — single job at a time

    return &RabbitMQBroker{conn: conn, ch: ch}, nil
}

func (b *RabbitMQBroker) Subscribe(ctx context.Context, handler func(msg Message) error) error {
    msgs, err := b.ch.Consume("scheduler-worker", "", false, false, false, false, nil)
    if err != nil {
        return err
    }

    for {
        select {
        case <-ctx.Done():
            return nil
        case d := <-msgs:
            // Parse routing key: scheduler.{tag}.{code}
            parts := strings.Split(d.RoutingKey, ".")
            if len(parts) != 3 {
                d.Ack(false)
                continue
            }

            err := handler(Message{Tag: parts[1], Code: parts[2], Raw: d.Body})
            if err != nil {
                d.Nack(false, true) // Requeue
            } else {
                d.Ack(false)
            }
        }
    }
}

func (b *RabbitMQBroker) Close() error {
    b.ch.Close()
    return b.conn.Close()
}
```

**Publishing:**
```go
ch.Publish("scheduler", "scheduler.main.TRXPRC", false, false, amqp.Publishing{})
```

#### Driver: NSQ

```go
// src/scheduler/broker_nsq.go

type NSQBroker struct {
    consumer *nsq.Consumer
}

func NewNSQBroker() (*NSQBroker, error) {
    topic := viper.GetString(constant.SCHEDULER_MESSAGE_TOPIC)
    if topic == "" {
        topic = "scheduler"
    }

    config := nsq.NewConfig()
    config.MaxInFlight = 1 // Single message at a time
    consumer, err := nsq.NewConsumer(topic, "scheduler-worker", config)
    if err != nil {
        return nil, err
    }

    return &NSQBroker{consumer: consumer}, nil
}

func (b *NSQBroker) Subscribe(ctx context.Context, handler func(msg Message) error) error {
    b.consumer.AddHandler(nsq.HandlerFunc(func(m *nsq.Message) error {
        // Parse: tag and code from message body as JSON
        var payload struct {
            Tag  string `json:"tag"`
            Code string `json:"code"`
        }
        if err := json.Unmarshal(m.Body, &payload); err != nil {
            return nil // Finish — don't requeue malformed messages
        }

        return handler(Message{Tag: payload.Tag, Code: payload.Code, Raw: m.Body})
    }))

    nsqdAddr := viper.GetString(constant.NSQ_NSQD_ADDR)
    if err := b.consumer.ConnectToNSQD(nsqdAddr); err != nil {
        return err
    }

    <-ctx.Done()
    return nil
}

func (b *NSQBroker) Close() error {
    b.consumer.Stop()
    return nil
}
```

**Publishing:**
```go
producer.Publish("scheduler", []byte(`{"tag":"main","code":"TRXPRC"}`))
```

#### Driver Comparison

| Driver | Ack/Nak | Redelivery | Single Consumer | Extra Infra |
|--------|---------|------------|----------------|-------------|
| `nats` | Yes | Yes (MaxDeliver) | JetStream durable + MaxAckPending(1) | NATS Server |
| `redis` | No | No (fire-and-forget) | No guarantee | Redis (already have) |
| `google` | Yes | Yes (deadline) | MaxOutstandingMessages(1) | GCP Pub/Sub |
| `rabbitmq` | Yes | Yes (nack + requeue) | Prefetch(1) | RabbitMQ Server |
| `nsq` | Yes | Yes (requeue) | MaxInFlight(1) | NSQ daemon |

#### Failure handling (all drivers with ack/nak support)

| Scenario | Behavior |
|----------|----------|
| Job succeeds | `Ack` — message consumed |
| Job fails | `Nak/Nack` — redelivered up to broker's max retries |
| Consumer crashes | Broker redelivers after ack timeout |
| Invalid tag/code | `Ack` — consume to prevent infinite redelivery |
| Scheduler inactive | `Ack` — silently skip |

#### Adding a Custom Driver

Implement the `MessageBroker` interface and add a case to the factory:

```go
// 1. Create src/scheduler/broker_custom.go
type CustomBroker struct { /* ... */ }

func NewCustomBroker() (*CustomBroker, error) { /* ... */ }

func (b *CustomBroker) Subscribe(ctx context.Context, handler func(msg Message) error) error {
    // Your subscription logic — parse tag/code from incoming messages
    // Call handler(Message{Tag: tag, Code: code})
    // Return handler error to trigger Nak, nil to Ack
}

func (b *CustomBroker) Close() error { /* ... */ }

// 2. Register in broker_factory.go
case "custom":
    return NewCustomBroker()
```

### Mode: `disable`

Kill switch. No jobs run. Event listeners still active (they handle real-time events, not scheduled work). Useful during maintenance windows or database migrations:

```go
func runDisableMode() {
    log.Warn("scheduler disabled — no jobs will run")

    // Block forever — event listeners and health server still run
    select {}
}
```

### Mode Selection Guide

| Scenario | Recommended Mode |
|----------|-----------------|
| Single instance, simple deploy | `database` |
| Cloud Run / serverless (scale to zero) | `http` |
| Multiple replicas, HA required | `message` |
| Database migration / maintenance | `disable` |
| K8s with CronJob controller | `http` |
| On-premise with Redis available | `database` |
| On-premise without Redis | `message` (broker handles locking) |
| Already have RabbitMQ/Google Pub/Sub | `message` (use existing infra) |

---

## 3. Scheduler Entity

```go
type Scheduler struct {
    BaseEntity
    Tag            string     `json:"tag"`               // Group tag (e.g., "main")
    Code           string     `json:"code"`              // Unique job code (e.g., "TRXPRC")
    Name           string     `json:"name"`              // Human-readable name
    Description    string     `json:"description"`       // What the job does
    Cron           string     `json:"cron"`              // 6-field cron with seconds
    CronBackup     string     `json:"cron_backup"`       // Backup cron for incidental changes
    LastExecuteAt  *time.Time `json:"last_execute_at"`   // When job last started
    NextExecuteAt  *time.Time `json:"next_execute_at"`   // Calculated next run (via gronx)
    LastSuccessAt  *time.Time `json:"last_success_at"`   // When job last succeeded
    SuccessMessage string     `json:"success_message"`   // Result from last success
    LastFailedAt   *time.Time `json:"last_failed_at"`    // When job last failed
    FailedMessage  string     `json:"failed_message"`    // Error from last failure
    Activable                                            // Embedded: IsActive int, ActivatedAt *time.Time
    Suspendable                                          // Embedded: IsSuspended int, SuspendedAt *time.Time
}
```

**Embedded traits:**

- `Activable` — provides `IsActive int` (1=active, 0=inactive) and `ActivatedAt *time.Time`
- `Suspendable` — provides `IsSuspended int` (1=suspended, 0=normal) and `SuspendedAt *time.Time`

These are composable traits from `entity-patterns.md`, not inline fields.

**Key fields:**

| Field | Type | Purpose |
|-------|------|---------|
| `Code` | `string` | Unique identifier matched against job registry (e.g., `TRXPRC`, `ORDEXP`) |
| `Cron` | `string` | 6-field cron expression **with seconds** (e.g., `*/30 * * * * *`). Used by `database` mode; informational in other modes |
| `CronBackup` | `string` | Store original cron when temporarily changing schedule |
| `IsActive` | `int` | From `Activable`. `1` = active, `0` = inactive. **Not bool** — uses int for DB compatibility |
| `IsSuspended` | `int` | From `Suspendable`. `1` = suspended, `0` = normal |
| `LastExecuteAt` | `*time.Time` | Updated when job **starts** (before execution). Updated in ALL modes |
| `NextExecuteAt` | `*time.Time` | Calculated by gronx after each execution. Only meaningful in `database` mode |
| `LastSuccessAt` | `*time.Time` | Updated only on successful completion |
| `LastFailedAt` | `*time.Time` | Updated only on failure or panic |

### Cron Expression Format

Uses **6-field cron with seconds** (not standard 5-field):

```
┌──────── second (0-59)
│ ┌────── minute (0-59)
│ │ ┌──── hour (0-23)
│ │ │ ┌── day of month (1-31)
│ │ │ │ ┌ month (1-12)
│ │ │ │ │ ┌ day of week (0-6, Sun=0)
│ │ │ │ │ │
* * * * * *
```

**Common expressions:**

| Expression | Meaning |
|-----------|---------|
| `*/30 * * * * *` | Every 30 seconds |
| `0 * * * * *` | Every minute at second 0 |
| `30 * * * * *` | Every minute at second 30 |
| `15,45 * * * * *` | At seconds 15 and 45 every minute |
| `0 */5 * * * *` | Every 5 minutes |
| `0 0 3 * * *` | Daily at 3:00:00 AM |
| `0 0 0 1 * *` | First day of month at midnight |

---

## 4. Scheduler Repository

### Interface

```go
type SchedulerRepository interface {
    // Query builders (fluent — return self for chaining)
    ForID(id uint) SchedulerRepository
    ForIDs(ids ...uint) SchedulerRepository
    ForCode(code string) SchedulerRepository
    ForCodes(codes ...string) SchedulerRepository
    ForTag(tag string) SchedulerRepository
    ForTags(tags ...string) SchedulerRepository
    ForActive() SchedulerRepository     // WHERE is_active > 0 (no params)
    ForInactive() SchedulerRepository   // WHERE is_active = 0

    // Execution
    Get(ctx context.Context) (*entity.Scheduler, error)
    GetAll(ctx context.Context) ([]*entity.Scheduler, error)
    Create(ctx context.Context, data *entity.Scheduler) error
    Update(ctx context.Context, data *entity.Scheduler) error
    Delete(ctx context.Context, data *entity.Scheduler) error

    // State management
    Activate(ctx context.Context, data *entity.Scheduler) error
    Deactivate(ctx context.Context, data *entity.Scheduler) error

    // Execution tracking (takes ID directly, not from fluent chain)
    UpdateExecutionTime(ctx context.Context, id uint, lastExecuteAt time.Time, nextExecuteAt *time.Time) error
    UpdateExecutionSuccess(ctx context.Context, id uint, message string) error
    UpdateExecutionFailed(ctx context.Context, id uint, message string) error

    // Lifecycle
    Init() SchedulerRepository    // Creates fresh instance (clean state)
    Clean() SchedulerRepository   // Resets whereQuery to nil
}
```

**Key differences from other repositories:**

- `ForActive()` / `ForInactive()` — no parameters, predefined conditions
- `UpdateExecution*` methods take `id uint` directly — not chained from `ForID()`. Called via `schRepo.Init().UpdateExecutionTime(ctx, schID, ...)`
- `Create`/`Update`/`Delete` return `error` only (no entity return)
- Plural query builders (`ForIDs`, `ForCodes`, `ForTags`) for batch operations

### Key Methods

**UpdateExecutionTime** — called at job start:
```go
func (r *SchedulerRepositoryImpl) UpdateExecutionTime(ctx context.Context, id uint, lastExecuteAt time.Time, nextExecuteAt *time.Time) error {
    defer r.Clean()
    return r.db.Model(&entity.Scheduler{}).Where("id = ?", id).
        Updates(map[string]interface{}{
            "last_execute_at": lastExecuteAt,
            "next_execute_at": nextExecuteAt,
        }).Error
}
```

**UpdateExecutionSuccess** — called on success:
```go
func (r *SchedulerRepositoryImpl) UpdateExecutionSuccess(ctx context.Context, id uint, message string) error {
    defer r.Clean()
    return r.db.Model(&entity.Scheduler{}).Where("id = ?", id).
        Updates(map[string]interface{}{
            "last_success_at": time.Now(),
            "success_message": message,
        }).Error
}
```

**UpdateExecutionFailed** — called on failure/panic:
```go
func (r *SchedulerRepositoryImpl) UpdateExecutionFailed(ctx context.Context, id uint, message string) error {
    defer r.Clean()
    return r.db.Model(&entity.Scheduler{}).Where("id = ?", id).
        Updates(map[string]interface{}{
            "last_failed_at": time.Now(),
            "failed_message":  message,
        }).Error
}
```

---

## 5. Routine Engine

The routine engine is a standalone binary (`engine/routine/routine.go`) that branches into the configured mode:

```go
func RunRoutine() {
    mode := viper.GetString(constant.SCHEDULER_MODE)
    if mode == "" {
        mode = "database"
    }

    // These always run regardless of mode
    go startJournalListener()
    go startTransactionListener()
    go startOrderListener()
    go startHealthServer()

    log.Info("starting scheduler", zap.String("mode", mode))

    switch mode {
    case "database":
        runDatabaseMode()
    case "http":
        runHTTPMode()
    case "message":
        runMessageMode()
    case "disable":
        runDisableMode()
    default:
        log.Fatal("unknown SCHEDULER_MODE", zap.String("mode", mode))
    }
}
```

### Database Mode Internals

```go
func runDatabaseMode() {
    tz := viper.GetString(constant.SCHEDULER_TZ)
    if tz == "" {
        tz = "UTC"
    }
    lc, _ := time.LoadLocation(tz)

    s := gocron.NewScheduler(lc)
    startTime := time.Date(2023, 1, 1, 0, 0, 0, 0, lc)

    db := database.GetDB()
    schRepo := repository.NewSchedulerRepository(db)
    redisClient := cache.NewRedisClient()
    cronLocker := helpers.NewCronLocker(redisClient, app.Zap.Logger)
    lockTTL := 5 * time.Minute
    scheduledAt := map[string]*time.Time{}

    s.StartAt(startTime).Every(15).Second().Do(func() {
        ctx := context.WithoutCancel(context.Background())
        schedulers, _ := schRepo.Init().ForTag("main").GetAll(ctx)

        for _, sch := range schedulers {
            // Hot reload check
            if lastUpdate, ok := scheduledAt[sch.Code]; ok {
                if sch.UpdatedAt != nil && lastUpdate != nil && lastUpdate.Equal(*sch.UpdatedAt) {
                    continue
                }
            }

            s.RemoveByTag(sch.Code)
            registerJob(s, sch, schRepo, cronLocker, lc, scheduledAt)
        }
    })

    s.StartBlocking()
}
```

**Key design decisions:**

- **Timezone is dynamic** — loaded from `SCHEDULER_TZ` via Viper (defaults to `UTC` if unset)
- **`scheduledAt` map** prevents unnecessary re-registration on each 15-second tick
- **`StartAt` with a past date** ensures gocron recognizes all cron patterns from the start
- **Event listeners** run in goroutines alongside the scheduler (not as scheduled jobs)

---

## 6. Job Registration Pattern

Jobs are registered by matching the scheduler's `Code` field using `strings.CutPrefix()`. This pattern supports extensibility — new job codes only need a handler function and a new case in the registration switch:

```go
func registerJob(s *gocron.Scheduler, sch *entity.Scheduler, schRepo repository.SchedulerRepository, locker *helpers.CronLocker, lc *time.Location, scheduledAt map[string]*time.Time) {
    // Validate cron expression
    gron := gronx.New()
    if !gron.IsValid(sch.Cron) {
        // Log warning, send Discord notification
        return
    }

    if sch.IsActive < 1 {
        scheduledAt[sch.Code] = sch.UpdatedAt
        return
    }

    // CRITICAL: Capture loop variables to avoid closure bugs
    schID := sch.ID
    schCode := sch.Code
    schCron := sch.Cron

    // Register with gocron
    s.Cron(schCron).Tag(schCode).Do(func() {
        ctx := context.WithoutCancel(context.Background())

        updateSchedulerExecutionTime(schRepo, schID, schCron, lc)

        err := locker.TryRunWithLock(ctx, schCode, 5*time.Minute, func() error {
            // Panic recovery inside the lock
            defer func() {
                if r := recover(); r != nil {
                    updateSchedulerFailed(schRepo, schID, fmt.Sprintf("Panic: %v", r))
                    clog.SendclogRPC(clog.ClogRPC{
                        Event:   constant.ClogEventError,
                        Level:   clog.ERROR,
                        Title:   fmt.Sprintf("Routine - %s", schCode),
                        Message: fmt.Sprintf("Panic: %v", r),
                        Fields: []clog.ClogFieldRPC{
                            {Key: "Caller", Value: helpers.GetCaller()},
                            {Key: "Error", Value: r},
                        },
                    }, clog.LogDiscord)
                }
            }()

            // Execute job via code prefix matching
            result, err := executeJob(schCode)
            if err != nil {
                updateSchedulerFailed(schRepo, schID, err.Error())
                return err
            }
            updateSchedulerSuccess(schRepo, schID, result)
            return nil
        })

        if err != nil {
            updateSchedulerFailed(schRepo, schID, err.Error())
        }
    })

    scheduledAt[sch.Code] = sch.UpdatedAt
}
```

**Variable capture pattern:** `schID := sch.ID`, `schCode := sch.Code`, `schCron := sch.Cron` are captured **outside** the closure. Without this, all closures in the loop would reference the same `sch` pointer — the last scheduler in the iteration. This is a classic Go closure-in-loop bug.

**`context.WithoutCancel`:** Creates a context that won't be cancelled by parent, ensuring long-running jobs complete even if the scheduler cycle resets.

### Shared Job Execution

All modes funnel into the same `executeJob()` — this is the shared pipeline. It takes the code string (already captured), not the entity pointer:

```go
func executeJob(code string) (string, error) {
    // Match by code prefix using strings.CutPrefix
    // Add new domain prefixes as your project grows
    switch {
    case matchCode(code, "TRX"):
        return handleTransactionJob(code)
    case matchCode(code, "ORD"):
        return handleOrderJob(code)
    case matchCode(code, "PDF"):
        return handlePDFJob(code)
    case matchCode(code, "MAIL"):
        return handleMailJob(code)
    case matchCode(code, "LOG"):
        return handleLogJob(code)
    // ... add more domain prefixes as needed
    default:
        return "", fmt.Errorf("no handler for code: %s", code)
    }
}

func matchCode(code, prefix string) bool {
    _, found := strings.CutPrefix(code, prefix)
    return found
}
```

### Job Handler Example

Each domain handler uses **service-only Wire injection** (no controller layer):

```go
func handleOrderJob(code string) (string, error) {
    // Service-only Wire injection — no controller, no transformer
    svc, _ := inject.InitializeOrderService()

    // Strip prefix to get action suffix
    _, action := matchCodeSuffix(code, "ORD")

    switch action {
    case "PRC":
        count, err := svc.ProcessOrders(context.Background())
        return fmt.Sprintf("processed %d orders", count), err

    case "EXP":
        count, err := svc.ExpireUnpaidOrders(context.Background(), service.ExpireOrderParams{
            Limit:       100,
            GracePeriod: 5 * time.Minute,
        })
        return fmt.Sprintf("expired %d orders", count), err

    case "RETRY":
        count, err := svc.RetryStuckOrders(context.Background())
        return fmt.Sprintf("retried %d orders", count), err

    default:
        return "", fmt.Errorf("unknown ORD action: %s", action)
    }
}

// Helper: returns (matched bool, suffix string)
func matchCodeSuffix(code, prefix string) (bool, string) {
    suffix, found := strings.CutPrefix(code, prefix)
    return found, suffix
}
```

### Job Code Convention

Job codes follow `{PREFIX}{ACTION}` format. The prefix is used by `matchCode()` to route to the correct domain handler, the action suffix identifies the specific operation:

```
PREFIX  = domain identifier (e.g., TRX, ORD, PDF, MAIL)
ACTION  = operation within that domain (e.g., PRC, CMP, EXP, RETRY)
CODE    = PREFIX + ACTION (e.g., TRXPRC, ORDEXP, PDFGEN)
```

**Example codes:**

| Code | Prefix | Action | Meaning |
|------|--------|--------|---------|
| `TRXPRC` | `TRX` | `PRC` | Process transactions |
| `TRXCMP` | `TRX` | `CMP` | Complete transactions |
| `ORDEXP` | `ORD` | `EXP` | Expire orders |
| `ORDRETRY` | `ORD` | `RETRY` | Retry stuck orders |
| `PDFGEN` | `PDF` | `GEN` | Generate PDFs |
| `LOGCLEAN` | `LOG` | `CLEAN` | Clean old log files |

Define codes in your migration seed data. Add new prefixes by adding a `case matchCode(code, "NEW"):` branch in `executeJob()`.

---

## 7. Hot Reload Mechanism

**Applies to `database` mode only.**

The scheduler reloads every 15 seconds without restart using `UpdatedAt` timestamp comparison:

```go
scheduledAt := map[string]*time.Time{} // code → last known UpdatedAt

// Inside the 15-second reload loop:
for _, sch := range schedulers {
    // 1. Compare timestamp — skip if unchanged
    if lastUpdate, ok := scheduledAt[sch.Code]; ok {
        if sch.UpdatedAt != nil && lastUpdate != nil && lastUpdate.Equal(*sch.UpdatedAt) {
            continue
        }
    }

    // 2. Remove old job from gocron
    s.RemoveByTag(sch.Code)

    // 3. Skip if inactive (IsActive < 1)
    if sch.IsActive < 1 {
        scheduledAt[sch.Code] = sch.UpdatedAt
        continue
    }

    // 4. Validate cron expression
    gron := gronx.New()
    if !gron.IsValid(sch.Cron) {
        // Send warning to Discord, skip
        continue
    }

    // 5. Register new job
    s.Cron(sch.Cron).Tag(sch.Code).Do(jobFunc)

    // 6. Update cache
    scheduledAt[sch.Code] = sch.UpdatedAt
}
```

**What triggers a reload:**

| Database Change | Effect |
|----------------|--------|
| Update `cron` expression | Job re-registered with new schedule |
| Set `is_active = 0` | Job removed from scheduler |
| Set `is_active = 1` | Job added to scheduler |
| Insert new scheduler | Job registered on next cycle |
| Delete scheduler | Job removed (not in query results) |
| No change | `scheduledAt` cache hit → skip |

**Propagation time:** Maximum 15 seconds from database change to effect.

---

## 8. CronLocker (Distributed Lock)

**Used in `database` and `http` modes.** Not needed in `message` mode (broker guarantees single-consumer delivery).

Prevents duplicate job execution across multiple replicas using Redis `SETNX`:

```go
// src/helpers/cron_locker.go

type CronLocker struct {
    cache      cache.RedisClient
    logger     *zap.Logger
    instanceID string
}

func NewCronLocker(redisClient cache.RedisClient, logger *zap.Logger) *CronLocker {
    return &CronLocker{
        cache:      redisClient,
        logger:     logger,
        instanceID: resolveInstanceID(),
    }
}

// Resolve instance identity (for logging/debugging)
func resolveInstanceID() string {
    // 1. Environment variable (preferred in K8s/Cloud Run)
    if id := os.Getenv("INSTANCE_ID"); id != "" {
        return id
    }
    // 2. Hostname
    if hostname, err := os.Hostname(); err == nil {
        return hostname
    }
    // 3. Random UUID (fallback)
    return uuid.New().String()
}
```

### TryRunWithLock

The core method — acquire, execute, release:

```go
func (l *CronLocker) TryRunWithLock(ctx context.Context, jobName string, ttl time.Duration, fn func() error) error {
    key := fmt.Sprintf("cron_lock:%s", jobName)

    // 1. Atomic lock acquisition via SETNX
    acquired, err := l.cache.SetNX(ctx, key, l.instanceID, ttl)
    if err != nil {
        return fmt.Errorf("redis error acquiring lock: %w", err) // Safe-fail: don't run
    }

    if !acquired {
        // Another instance holds the lock — skip silently
        log.Info("job locked by another instance",
            zap.String("job", jobName),
            zap.String("instance", l.instanceID))
        return nil
    }

    // 2. Execute with guaranteed lock release
    defer l.cache.Del(ctx, key)

    return fn()
}
```

**How it works:**

| Scenario | Behavior |
|----------|----------|
| Lock acquired | Execute job, defer release |
| Lock held by another instance | Log and skip, return `nil` (not an error) |
| Redis error | Return error (safe-fail: job won't run) |
| Job panics | `defer Del` still runs — lock released |
| Job takes longer than TTL | Lock expires, another instance may start — choose TTL carefully |

**Lock key format:** `cron_lock:{CODE}` (e.g., `cron_lock:TRXPRC`)

**Default TTL:** 5 minutes. Choose based on maximum expected job duration.

---

## 9. Execution Tracking

Every job execution is tracked in the database through three update functions. **This applies to ALL modes** — database, http, and message all call the same tracking functions.

### At Job Start

```go
func updateSchedulerExecutionTime(schRepo repository.SchedulerRepository, schID uint, cronExpr string, lc *time.Location) {
    ctx := context.Background()
    gron := gronx.New()

    now := time.Now().In(lc)
    nextTick, _ := gron.NextTickAfter(cronExpr, now, false)

    schRepo.Init().UpdateExecutionTime(ctx, schID, now, &nextTick)
}
```

**Key details:**
- Takes `schRepo` (shared instance), `schID` (captured from loop), `cronExpr` (captured cron string), `lc` (timezone location)
- Uses `schRepo.Init()` to create a fresh repository state before updating — prevents query leakage between calls
- Calculates `nextTick` using gronx with the scheduler's timezone
- Runs **before** the job handler — so `last_execute_at` reflects when the job started, not when it finished

### On Success

```go
func updateSchedulerSuccess(schRepo repository.SchedulerRepository, schID uint, message string) {
    ctx := context.Background()
    schRepo.Init().UpdateExecutionSuccess(ctx, schID, message)
}
```

The `message` is a human-readable result from the job (e.g., `"processed 42 transactions"`, `"expired 3 orders"`).

### On Failure

```go
func updateSchedulerFailed(schRepo repository.SchedulerRepository, schID uint, message string) {
    ctx := context.Background()
    schRepo.Init().UpdateExecutionFailed(ctx, schID, message)
}
```

The `message` includes the error string, or on panic, the full stack trace.

### Monitoring Query

With all tracking fields populated, monitoring is straightforward:

```sql
SELECT code, name, cron,
       last_execute_at,
       last_success_at, success_message,
       last_failed_at, failed_message,
       next_execute_at
FROM schedulers
WHERE tag = 'main' AND is_active = 1
ORDER BY last_execute_at DESC;
```

---

## 10. Error Handling & Recovery

### Panic Recovery

Every job is wrapped in `defer recover()` to prevent one panicking job from crashing the entire scheduler. **This is inside `executeJob()`, so it applies to ALL modes:**

```go
defer func() {
    if r := recover(); r != nil {
        updateSchedulerFailed(schRepo, schID, fmt.Sprintf("Panic: %v", r))

        clog.SendclogRPC(clog.ClogRPC{
            Event:   constant.ClogEventError,
            Level:   clog.ERROR,
            Title:   "Routine - SCHEDULER PANIC",
            Message: fmt.Sprintf("Panic in %s: %v", schCode, r),
            Fields: []clog.ClogFieldRPC{
                {Key: "Caller", Value: helpers.GetCaller()},
                {Key: "Error", Value: r},
            },
        }, clog.LogDiscord)
    }
}()
```

**Key details:**
- Uses `schRepo`, `schID` (captured outside closure to avoid loop variable bugs)
- `clog.ClogRPC` struct with `Event`, `Level`, `Title`, `Message`, `Fields []clog.ClogFieldRPC`
- `clog.LogDiscord` as second argument to specify the log destination
- `helpers.GetCaller()` identifies the panic source in the call stack

### Error Reporting (clog/Discord)

Critical scheduler events are reported to Discord via the **clog** system:

| Event | Severity | Reported |
|-------|----------|----------|
| Job panic | ERROR | Always — includes stack trace |
| Invalid cron expression | WARNING | Always — includes scheduler code |
| Redis lock error | ERROR | Always — indicates infrastructure issue |
| Job execution error | ERROR | Always — includes error message |
| Job success | — | Not reported to Discord (only DB) |

### Cron Validation

Before registering any job (in `database` mode), the cron expression is validated:

```go
gron := gronx.New()
if !gron.IsValid(sch.Cron) {
    clog.SendclogRPC(clog.ClogRPC{
        Event:   constant.ClogEventWarning,
        Level:   clog.WARNING,
        Title:   "Invalid Cron Expression",
        Message: fmt.Sprintf("Scheduler %s has invalid cron: %s", sch.Code, sch.Cron),
    }, clog.LogDiscord)
    return // Don't register
}
```

If someone enters an invalid cron in the database, the job simply won't register. Fix the expression, and the next 15-second reload will pick it up.

---

## 11. Event Listeners

The routine engine also runs **event listeners** alongside the scheduler. These respond to real-time events from Go channels — they are **not** cron-scheduled and **run in ALL modes** (including `disable`).

Event listeners are registered in the `init()` function (before `main()`) using the `pool.ListenXxx` callback pattern:

```go
func init() {
    // Start Prometheus metrics server
    go startPrometheusServer()

    // Register event listeners
    initJournalListener()
    initTransactionListener()
    initOrderListener()
}
```

### Listener Pattern

Each listener uses `pool.ListenXxx(func(entity))` — a callback invoked per event, not a channel subscription:

```go
func initTransactionListener() {
    pool.ListenTransaction(func(t entity.Transaction) {
        // Panic recovery per event
        defer func() { recover() }()

        ctx, done := context.WithCancel(context.Background())
        defer done()

        // Business logic per transaction event
        svc, _ := inject.InitializeTransactionService()
        svc.HandleTransactionEvent(ctx, t)

        // Nested goroutine for PDF generation (non-blocking)
        go func() {
            pdfCtx, pdfDone := context.WithCancel(context.Background())
            defer pdfDone()

            pdfSvc, _ := inject.InitializePDFService()
            pdfSvc.GenerateForTransaction(pdfCtx, t.ID)
        }()
    })
}
```

**Key details:**
- `pool.ListenXxx(callback)` — registers a callback, not a channel subscription
- Each callback creates its own `context.WithCancel` + `defer done()` for cleanup
- Panic recovery per event: `defer func() { recover() }()` — one bad event doesn't kill the listener
- Nested goroutines allowed for non-blocking work (e.g., PDF generation)

**Key differences from scheduled jobs:**

| Aspect | Scheduled Jobs | Event Listeners |
|--------|---------------|-----------------|
| Trigger | Cron / HTTP / NATS (time-based or external) | Channel/NATS event (data-driven) |
| Frequency | Fixed intervals or on-demand | Real-time |
| Locking | CronLocker or NATS consumer | Not needed (channel is per-instance) |
| DB tracking | Yes (scheduler table) | No |
| Affected by mode | Yes | No (always runs) |

---

## 12. Health Check & Metrics

The routine binary exposes two HTTP servers. **Both run in ALL modes:**

### Health Check Server

Started from `main()` as a goroutine:

```go
type HealthCheckResponse struct {
    Status    string `json:"status"`
    Service   string `json:"service"`
    Timestamp string `json:"timestamp"`
}

func startHealthCheckServer() {
    port := viper.GetString(constant.ROUTINE_HEALTH_PORT) // default: 8090
    if port == "" {
        port = "8090"
    }

    mux := http.NewServeMux()
    mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        w.WriteHeader(http.StatusOK)
        json.NewEncoder(w).Encode(HealthCheckResponse{
            Status:    "ok",
            Service:   "{service}-routine",
            Timestamp: time.Now().UTC().Format(time.RFC3339),
        })
    })

    server := &http.Server{Addr: ":" + port, Handler: mux}
    server.ListenAndServe()
}
```

### Prometheus Metrics Server

Started from `init()` (before main) on a **separate port** — port `1{ROUTINE_HEALTH_PORT}` (e.g., `:18090` if health is `:8090`):

```go
func startPrometheusServer() {
    go func() {
        http.Handle("/metrics", promhttp.Handler())
        http.ListenAndServe(
            fmt.Sprintf(":1%s", viper.GetString(constant.ROUTINE_HEALTH_PORT)),
            nil,
        )
    }()
}
```

**Port separation:** Health check and Prometheus run on different ports for isolation. This follows the same `1{PORT}` pattern used by gRPC/REST metrics.

**Note:** In `http` mode, the health server, Prometheus server, and scheduler HTTP server all run on **different ports** (`ROUTINE_HEALTH_PORT` for health, `1{ROUTINE_HEALTH_PORT}` for metrics, `SCHEDULER_HTTP_PORT` for job triggers).

---

## 13. Key Rules

1. **Set `SCHEDULER_MODE` explicitly** — defaults to `database`, but be intentional. Document the mode in deployment config.
2. **6-field cron with seconds** — always include the seconds field. `*/30 * * * * *` not `*/30 * * * *`.
3. **`database` and `http` modes use CronLocker** — prevents duplicate execution via Redis. `message` mode uses NATS single consumer instead.
4. **Use `context.WithoutCancel(context.Background())`** for the main scheduler loop — prevents parent cancellation from interrupting running jobs. Service calls inside handlers use plain `context.Background()`.
5. **Job handlers use service-only Wire injection** — no controller or transformer layer.
6. **`executeJob()` is shared across all modes** — panic recovery, tracking, and reporting happen regardless of trigger source.
7. **Always track execution** — call `updateSchedulerExecutionTime` before, `updateSchedulerSuccess`/`updateSchedulerFailed` after. All modes do this.
8. **Panic recovery is mandatory** — inside `executeJob()`, applies to all modes automatically.
9. **Validate cron expressions** — use `gronx.IsValid()` in `database` mode before registration. Invalid = skip, not crash.
10. **`IsActive` is `int` not `bool`** — from `Activable` trait. Check `sch.IsActive < 1` for inactive. Also has `Suspendable` trait (`IsSuspended`).
11. **Event listeners are mode-independent** — they always run, even in `disable` mode.
12. **Timezone is dynamic** — loaded from `SCHEDULER_TZ` constant via Viper. Defaults to `UTC` if unset.
13. **HTTP mode path format** — `POST /scheduler/{tag}/{code}`. Tag and code from the database.
14. **Message mode is broker-agnostic** — implement `MessageBroker` interface. Set driver via `SCHEDULER_MESSAGE_DRIVER`. Topic format: `scheduler.{tag}.{code}`.
15. **All drivers must guarantee single-consumer delivery** — via prefetch(1), MaxAckPending(1), MaxInFlight(1), or equivalent. Redis Pub/Sub is the exception (fire-and-forget).

---

## Environment Variables

| Constant | Default | Modes | Description |
|----------|---------|-------|-------------|
| `SCHEDULER_MODE` | `database` | All | Operating mode: `database`, `http`, `message`, `disable` |
| `SCHEDULER_TZ` | `UTC` | `database` | Timezone for gocron scheduler |
| `SCHEDULER_HTTP_PORT` | `8091` | `http` | Port for job trigger HTTP endpoints |
| `SCHEDULER_MESSAGE_DRIVER` | `nats` | `message` | Broker driver: `nats`, `redis`, `google`, `rabbitmq`, `nsq` |
| `SCHEDULER_MESSAGE_TOPIC` | `scheduler` | `message` (nsq) | NSQ topic name |
| `SCHEDULER_MESSAGE_SUBSCRIPTION` | `scheduler-worker` | `message` (google) | Google Pub/Sub subscription name |
| `RABBITMQ_URL` | — | `message` (rabbitmq) | RabbitMQ connection URL |
| `NSQ_NSQD_ADDR` | — | `message` (nsq) | NSQ daemon address |
| `GCP_PROJECT_ID` | — | `message` (google) | Google Cloud project ID |
| `ROUTINE_HEALTH_PORT` | `8090` | All | Port for health check and Prometheus metrics |
| `INSTANCE_ID` | hostname | `database`, `http` | Instance identifier for CronLocker logging |

---

## Anti-Patterns

| Anti-pattern | Why it breaks | Fix |
|---|---|---|
| `context.Background()` in `executeJob()` | Disconnects from engine shutdown signal; hung job keeps running after Supervisord stops the process | Use `engineCtx` as parent; wrap with per-job `WithTimeout` |
| `jobRegistry[sch.Code]` called without checking nil | Panics at runtime for unregistered codes — panic propagates if no recovery is in place | Always check `handler == nil` before calling; log + skip missing handlers |
| Using `db.Where("status = ?", ...)` directly in job handler | Bypasses fluent builder; no `defer r.clean()`, no tx support, no ForTenant scoping | Use repository fluent methods: `repo.ForStatus(...).Gets(ctx)` |
| Calling entity state transition with raw field assignment (`sch.FailedAt = &now`) | Skips trait method side effects (sign invalidation, hook triggers, consistent time format) | Call the trait method: `sch.SyncFailedDate()` or `sch.SyncProcessedDate()` |
| Writing execution-tracking updates outside `executeJob()` | Tracking may be skipped if handler panics; inconsistent audit trail | All `updateSchedulerExecutionTime` / `Success` / `Failed` calls live inside `executeJob()`, not in individual handlers |
| Missing `defer locker.Release(ctx)` | Redis lock held until TTL expiry; next run blocked for the full lock TTL | `defer locker.Release(ctx)` immediately after successful `Acquire` |
| CronLocker TTL shorter than the job's expected runtime | Lock expires mid-run; second instance acquires lock and runs concurrently | Set lock TTL ≥ job timeout + 20% buffer |
| 5-field cron expression (minutes not seconds) | gocron uses 6-field expressions with seconds; 5-field expressions parsed incorrectly | Always include the seconds field: `*/30 * * * * *` |
| Sharing one `*RoutineEngine` instance across multiple goroutines without mutex | `jobRegistry` and internal state are written at startup; concurrent hot-reload may cause races | Run hot-reload in a single goroutine; read `jobRegistry` only after init is complete |

---

## Related References

- **Service Patterns** (`service-patterns.md`) — Service-only Wire injection used by job handlers
- **Infrastructure** (`infrastructure.md`) — Redis (CronLocker), NATS JetStream (event listeners), Wire DI, message broker connections
- **Entity Patterns** (`entity-patterns.md`) — BaseEntity, trait methods (SyncFailedDate, SyncProcessedDate, etc.)
- **Repository Patterns** (`repository-patterns.md`) — Fluent builder used by SchedulerRepository
- **Context Patterns** (`context-patterns.md §4`) — gocron job ctx, per-run WithTimeout, engineCtx as parent
