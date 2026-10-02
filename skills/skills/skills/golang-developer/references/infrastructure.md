# Infrastructure Patterns Reference

A comprehensive guide to database, caching, event streaming, dependency injection, configuration, logging, and encryption patterns.

## Table of Contents

1. [Database (GORM + MySQL)](#1-database-gorm--mysql)
2. [Redis (CacheManager)](#2-redis-cachemanager)
3. [Event Pools](#3-event-pools)
4. [Google Wire (Dependency Injection)](#4-google-wire-dependency-injection)
5. [Configuration (Viper + Vault + GSM)](#5-configuration-viper--vault--gsm)
6. [Encryption (PII Protection)](#6-encryption-pii-protection)
7. [Zap Logger](#7-zap-logger)
8. [App Initialization](#8-app-initialization)
9. [Context Helpers](#9-context-helpers)
10. [PDF Infrastructure](#10-pdf-infrastructure)
11. [Supervisord (Multi-Process)](#11-supervisord-multi-process)
12. [Helpers & Calculators](#12-helpers--calculators)
13. [Anti-Patterns](#13-anti-patterns)

---

## 1. Database (GORM + MySQL)

### Singleton Connection

```go
// File: src/database/database.go

var db = newDB()  // Package-level singleton initialization

func GetDB() *gorm.DB {
    return db
}

func newDB() *gorm.DB {
    // Register TLS config if certificates are present
    registerTLSConfig()

    dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?charset=utf8mb4&parseTime=True&loc=%s",
        viper.GetString(constant.DB_USER),
        viper.GetString(constant.DB_PASS),
        viper.GetString(constant.DB_HOST),
        viper.GetString(constant.DB_PORT),
        viper.GetString(constant.DB_NAME),
        viper.GetString(constant.DB_TIMEZONE),
    )

    // Determine log level: Info for dev, Warning for prod
    logLevel := logger.Warn
    if viper.GetString("MODE") != "production" {
        logLevel = logger.Info
    }

    db, err := gorm.Open(mysql.Open(dsn), &gorm.Config{
        SkipDefaultTransaction: true,
        Logger:                 logger.Default.LogMode(logLevel),
        NamingStrategy: schema.NamingStrategy{
            TablePrefix: viper.GetString(constant.DB_PREFIX),
        },
        AllowGlobalUpdate:    true,
        FullSaveAssociations: false,
    })

    sqlDB, _ := db.DB()
    sqlDB.SetMaxOpenConns(10)
    sqlDB.SetMaxIdleConns(2)
    sqlDB.SetConnMaxIdleTime(1 * time.Minute)

    return db
}
```

### TLS Configuration

For environments requiring encrypted database connections:

```go
func registerTLSConfig() {
    caCert := viper.GetString(constant.CA_CERT)
    clientCert := viper.GetString(constant.CLIENT_CERT)
    clientKey := viper.GetString(constant.CLIENT_KEY)

    if caCert == "" {
        return
    }

    rootCertPool := x509.NewCertPool()
    pem, _ := os.ReadFile(caCert)
    rootCertPool.AppendCertsFromPEM(pem)

    clientCertPair, _ := tls.LoadX509KeyPair(clientCert, clientKey)

    mysql.RegisterTLSConfig("custom", &tls.Config{
        RootCAs:      rootCertPool,
        Certificates: []tls.Certificate{clientCertPair},
    })
}
```

### Key Configuration Settings

| Setting | Value | Purpose |
|---|---|---|
| `SkipDefaultTransaction` | `true` | No auto-wrapping queries in transactions — use explicit tx only when needed |
| `AllowGlobalUpdate` | `true` | Allows UPDATE/DELETE without WHERE clause (be careful) |
| `FullSaveAssociations` | `false` | Prevents auto-saving associations on Create/Update |
| `MaxOpenConns` | `10` | Max open DB connections per instance |
| `MaxIdleConns` | `2` | Min idle connections to maintain |
| `ConnMaxIdleTime` | `1 minute` | Idle connections close after 1 min |
| `TablePrefix` | from `DB_PREFIX` | Optional prefix for all table names |
| `charset=utf8mb4` | — | Full Unicode support (emoji, CJK) |
| `parseTime=True` | — | Auto-parse DATE/DATETIME into `time.Time` |
| `loc` | from `DB_TIMEZONE` | Timezone for time parsing |

### Transaction Pattern

Uses unconditional defer rollback + explicit commit:

```go
repo := s.OrderRepo.StartTx(ctx)
defer func() {
    _ = repo.RollbackTx()  // No-op if already committed
}()

// Multi-repo transaction sharing
s.TransactionRepo.WithTx(repo.GetTx())

// Operations...
order, err := repo.Create(ctx, &orderEntity)
if err != nil {
    return nil, err, nil  // Rollback happens via defer
}

_ = repo.CommitTx()  // Explicit commit on success
return order, nil, nil
```

### Goose Migrations

Migrations use GORM AutoMigrate from entity structs:

```go
// File: src/schema/migrations/20260101000001_create_orders.go
package migrations

func init() {
    goose.AddMigration(upCreateOrders, downCreateOrders)
}

func upCreateOrders(tx *sql.Tx) error {
    db, _ := gorm.Open(mysql.New(mysql.Config{Conn: tx}), &gorm.Config{})
    return db.AutoMigrate(&entity.Order{})
}

func downCreateOrders(tx *sql.Tx) error {
    return tx.Exec("DROP TABLE IF EXISTS orders").Error
}
```

**Naming**: `{YYYYMMDDHHmmss}_create_{entity}.go` (UTC timestamp)

```bash
go run engine/goose/goose.go up       # Run all pending
go run engine/goose/goose.go down     # Rollback last
go run engine/goose/goose.go status   # Check status
```

---

## 2. Redis (CacheManager)

### Interface and Singleton

```go
// File: src/cache/cache.go

type RedisClient interface {
    SetNX(ctx context.Context, key string, value interface{}, expiration time.Duration) (bool, error)
    Del(ctx context.Context, keys ...string) (int64, error)
    Get(ctx context.Context, key string) (string, error)
    GetCache() *redis.Client
}

type CacheManager struct {
    client *redis.Client
}

var Cache CacheManager  // Global singleton

func NewRedisClient() RedisClient {
    Cache = CacheManager{
        client: redis.NewClient(&redis.Options{
            Addr:     fmt.Sprintf("%s:%s", viper.GetString(constant.REDIS_HOST), viper.GetString(constant.REDIS_PORT)),
            Username: viper.GetString(constant.REDIS_USER),
            Password: viper.GetString(constant.REDIS_PASS),
            DB:       viper.GetInt(constant.REDIS_DB),
        }),
    }
    return &Cache
}
```

### Core Operations

```go
// Distributed lock (SetNX = set if not exists)
acquired, err := Cache.SetNX(ctx, "lock:process-nav", "node-1", 5*time.Minute)
if !acquired {
    return fmt.Errorf("another instance is already processing")
}
defer Cache.Del(ctx, "lock:process-nav")

// Simple get/set via underlying client
Cache.GetCache().Set(ctx, "user:123:profile", userJSON, 1*time.Hour)
val, err := Cache.Get(ctx, "user:123:profile")
```

### Key Naming Convention

```
{entity}:{id}:{attribute}
cron_lock:{job_name}

Examples:
user:123:profile
order:456:items
nav:total
cron_lock:process-nav
```

---

## 3. Event Pools

Two distinct patterns for event-driven processing.

### Pattern 1: Go Channel Pools (In-Process)

Most domains use buffered Go channels. Fast but in-memory only (lost on process restart).

```go
// File: src/pool/order_pool.go
package pool

const POOL_SIZE = 100

var orderChannel chan entity.Order

func init() {
    orderChannel = make(chan entity.Order, POOL_SIZE)
}

func PostOrder(order entity.Order) {
    orderChannel <- order
}

func ListenOrder(callback func(entity.Order)) {
    go func() {
        for order := range orderChannel {
            callback(order)
        }
    }()
}
```

**Common pool domains include**: Order, Transaction, Notification, etc. (all use size 100 buffer)

### Pattern 2: NATS JetStream (Distributed Persistent)

Only **PDF_GENERATION** uses NATS JetStream for persistent, distributed processing.

#### Connection (Singleton)

```go
// File: src/pool/nats_connection_pool.go
var natsConn *NATSConnection
var natsOnce sync.Once

func GetNATSConnection() *NATSConnection {
    natsOnce.Do(func() {
        nc, _ := nats.Connect(
            viper.GetString(constant.NATS_URL),
            nats.MaxReconnects(-1),
            nats.ReconnectWait(2*time.Second),
            nats.Timeout(10*time.Second),
        )
        js, _ := nc.JetStream(
            nats.PublishAsyncMaxPending(256),
            nats.MaxWait(10*time.Second),
        )
        natsConn = &NATSConnection{conn: nc, js: js}
    })
    return natsConn
}
```

#### Stream Configuration

```go
// File: src/pool/pdf_generation_stream_config.go
const (
    PDFGenerationStreamName   = "PDF_GENERATION"
    PDFGenerationSubject      = "pdf.generation.jobs"
    PDFGenerationConsumerName = "pdf-generation-worker"
    PDFGenerationQueueGroup   = "pdf-workers"
)
```

| Setting | Value | Purpose |
|---|---|---|
| Storage | `FileStorage` | Persistent across restarts |
| Retention | `LimitsPolicy` | Evict by age/count limits |
| MaxMsgs | 10,000 | Max messages in stream |
| MaxAge | 7 days | Auto-delete after 7 days |
| MaxMsgSize | 10MB | Per-message size limit |
| Deduplication | 1 minute window | Via `nats.MsgId(jobID)` |
| AckPolicy | `AckExplicit` | Manual ACK/NAK required |
| AckWait | 5 minutes | Redeliver if not ACKed |
| MaxDeliver | 3 | Max redelivery attempts |
| MaxAckPending | 10 | Max inflight per consumer |

#### Publishing

```go
publisher := pool.NewPDFGenerationPublisher(natsConn)
publisher.PublishPDFJob(jobID, payload)       // Sync
publisher.PublishPDFJobAsync(jobID, payload)  // Async with PubAckFuture
publisher.PublishBatch(jobs)                  // Batch
```

#### Consuming

```go
consumer := pool.NewPDFGenerationConsumer(natsConn)
consumer.Subscribe(func(msg *nats.Msg) {
    if err := processPDF(msg.Data); err != nil {
        msg.Nak()   // Redeliver (up to MaxDeliver)
        return
    }
    msg.Ack()       // Done
})
```

**Consumer metrics**: Tracks processed, error, ack, nak counts. 10-minute per-message timeout. Terminal vs. redeliverable error handling.

### When to Use Which

| Aspect | Go Channels | NATS JetStream |
|---|---|---|
| Persistence | In-memory only | Disk-backed |
| Delivery | Fire-and-forget | Explicit ACK/NAK |
| Scaling | Single process | Multiple consumers (queue group) |
| Use for | In-process coordination | Jobs that must survive restarts |

---

## 4. Google Wire (Dependency Injection)

### Build Tag and Signature

```go
// File: injector/inject/injector.go
//go:build wireinject
// +build wireinject

package inject

import "github.com/google/wire"
```

### Naming Convention

| Tier | Pattern | Return Type |
|---|---|---|
| Admin | `InitializeXxxControllerGRPC` | `navadminv2.XxxServer` |
| Insider | `InitializeXxxControllerGRPCInsider` | `navinsiderv2.XxxServer` |
| Public | `InitializeXxxControllerGRPCPublic` | `navpublicv2.XxxServer` |
| Service-only | `InitializeXxxService` | `service.XxxService` |
| Worker | `InitializeXxxWorkerManager` | `*worker.XxxWorkerManager` |

### Controller Injection (Full Stack)

```go
func InitializeOrderControllerGRPC() (navadminv2.OrderServer, error) {
    wire.Build(
        // Controller + transformer
        controller.NewOrderController,
        transformer.NewOrderTransformer,
        utils.NewCustomValidator,

        // Services (including cross-domain when needed)
        service.NewOrderService,
        service.NewAuditService,
        // ... other services as needed

        // Repositories
        repository.NewOrderRepository,
        repository.NewOrderItemRepository,
        repository.NewCategoryRepository,
        // ... other repositories as needed

        // Infrastructure
        database.GetDB,
    )
    return nil, nil
}
```

### Service-Only Injection (for CLI/Routine)

```go
func InitializeOrderService() (service.OrderService, error) {
    wire.Build(
        service.NewOrderService,
        repository.NewOrderRepository,
        repository.NewOrderItemRepository,
        repository.NewFundRepository,
        database.GetDB,
    )
    return nil, nil
}
```

### Constructor Function Rules

Constructors return **interface type** and accept dependencies as interfaces:

```go
// Service constructor — returns interface, NOT *ServiceImpl
func NewOrderService(
    orderRepo repository.OrderRepository,
    itemRepo repository.OrderItemRepository,
    categoryRepo repository.CategoryRepository,
    auditSvc service.AuditService,
) service.OrderService {
    return &OrderServiceImpl{
        Repository:         orderRepo,
        ItemRepository:     itemRepo,
        CategoryRepository: categoryRepo,
        AuditService:       auditSvc,
    }
}

// Repository constructor — returns interface
func NewOrderRepository(db *gorm.DB) repository.OrderRepository {
    return &OrderRepositoryImpl{db: db, whereQuery: db}
}

// Singleton infrastructure — no error return needed
func GetDB() *gorm.DB {
    return db  // package-level singleton
}
```

**Key**: Constructors do NOT return error as second value. Wire handles the dependency graph; if a provider fails, it propagates at initialization.

### External Client Injection

```go
// File: src/provider/payment_client.go
var paymentOnce sync.Once
var paymentConn *grpc.ClientConn

func ProvideAdminPaymentGatewayClient() paymentadminv1.PaymentGatewayClient {
    paymentOnce.Do(func() {
        paymentConn, _ = grpc.NewClient(
            fmt.Sprintf("%s:%s", viper.GetString(constant.PAYMENT_HOST), viper.GetString(constant.PAYMENT_PORT)),
            grpc.WithTransportCredentials(insecure.NewCredentials()),
        )
    })
    return paymentadminv1.NewPaymentGatewayClient(paymentConn)
}

func ProvideAdminDisbursementClient() paymentadminv1.DisbursementClient {
    paymentOnce.Do(func() { /* same connection setup */ })
    return paymentadminv1.NewDisbursementClient(paymentConn)
}
```

### Regeneration

```bash
make injector   # Runs: wire ./injector/**
# NEVER edit wire_gen.go manually
```

Run `make injector` after adding/modifying constructors, services, or repositories.

---

## 5. Configuration (Viper + Vault + GSM)

### Loading Priority (Highest to Lowest)

1. **OS Environment Variables** — override everything
2. **.env File** — local development (dotenv format)
3. **config.json** — application defaults (from `/config/` or cwd)
4. **Google Secret Manager** — production secrets
5. **HashiCorp Vault** — enterprise secrets (KVv2 engine)

### Setup

```go
// File: src/config/config.go

func LoadConfig() {
    // 1. Load .env file
    viper.SetConfigFile(".env")
    viper.ReadInConfig()  // Ignore errors (file optional)

    // 2. Load config.json
    viper.SetConfigName("config")
    viper.AddConfigPath("/config/")
    viper.AddConfigPath(".")
    viper.MergeInConfig()

    // 3. OS env overrides
    viper.AutomaticEnv()

    // 4. Google Secret Manager (if configured)
    if viper.GetString("GSM_PROJECT_ID") != "" {
        loadFromGSM()
    }

    // 5. Vault (if configured)
    if viper.GetString(constant.VAULT_ADDRESS) != "" {
        loadFromVault()
    }
}
```

### Vault Integration

```go
// File: src/config/vault.go

// Vault env vars:
// VAULT_ADDRESS, VAULT_TOKEN, VAULT_MOUNT, VAULT_SECRET, VAULT_GLOBAL

func loadFromVault() {
    client, _ := vault.NewClient(&vault.Config{Address: viper.GetString(constant.VAULT_ADDRESS)})
    client.SetToken(viper.GetString(constant.VAULT_TOKEN))

    // KVv2 engine read
    secret, _ := client.KVv2(viper.GetString(constant.VAULT_MOUNT)).Get(ctx, viper.GetString(constant.VAULT_SECRET))

    // Merge into Viper
    for key, val := range secret.Data {
        viper.Set(key, val)
    }
}
```

### Constants Pattern

All configuration keys are defined as constants (not a Config struct):

```go
// File: src/constant/constant.go

const (
    // Database
    DB_HOST               = "DB_HOST"
    DB_PORT               = "DB_PORT"
    DB_USER               = "DB_USER"
    DB_PASS               = "DB_PASS"
    DB_NAME               = "DB_NAME"
    DB_TIMEZONE           = "DB_TIMEZONE"
    DB_PREFIX             = "DB_PREFIX"
    DB_RETRY_MAX_ATTEMPTS = "DB_RETRY_MAX_ATTEMPTS"

    // Cache
    REDIS_HOST = "REDIS_HOST"
    REDIS_PORT = "REDIS_PORT"
    REDIS_USER = "REDIS_USER"
    REDIS_PASS = "REDIS_PASS"
    REDIS_DB   = "REDIS_DB"

    // Messaging
    NATS_URL = "NATS_URL"

    // Server ports
    GRPC_PORT          = "GRPC_PORT"
    REST_PORT          = "REST_PORT"
    GRPC_INSIDER_PORT  = "GRPC_INSIDER_PORT"
    REST_INSIDER_PORT  = "REST_INSIDER_PORT"
    GRPC_PUBLIC_PORT   = "GRPC_PUBLIC_PORT"
    REST_PUBLIC_PORT   = "REST_PUBLIC_PORT"

    // Encryption
    AES_KEY     = "AES_KEY"
    AES_128_KEY = "AES_128_KEY"
    HMAC_KEY    = "HMAC_KEY"

    // TLS
    CA_CERT     = "CA_CERT"
    CLIENT_CERT = "CLIENT_CERT"
    CLIENT_KEY  = "CLIENT_KEY"

    // External services (examples below; adjust per your integration needs)
    EXTERNAL_SERVICE_1_HOST = "EXTERNAL_SERVICE_1_HOST"
    EXTERNAL_SERVICE_1_PORT = "EXTERNAL_SERVICE_1_PORT"
    EXTERNAL_SERVICE_2_HOST = "EXTERNAL_SERVICE_2_HOST"
    EXTERNAL_SERVICE_2_PORT = "EXTERNAL_SERVICE_2_PORT"

    // Vault
    VAULT_ADDRESS = "VAULT_ADDRESS"
    VAULT_TOKEN   = "VAULT_TOKEN"
    VAULT_MOUNT   = "VAULT_MOUNT"
    VAULT_SECRET  = "VAULT_SECRET"

    // Zap Logger
    ZAP_LOG_LEVEL   = "ZAP_LOG_LEVEL"
    ZAP_LOG_FORMAT  = "ZAP_LOG_FORMAT"
    ZAP_LOG_OUTPUT  = "ZAP_LOG_OUTPUT"
    ZAP_LOG_FILE    = "ZAP_LOG_FILE"

    // PDF
    PDF_STORAGE_TYPE      = "PDF_STORAGE_TYPE"
    PDF_GCS_BUCKET        = "PDF_GCS_BUCKET"
    PDF_LOCAL_PATH        = "PDF_LOCAL_PATH"
    PDF_CHROME_PATH       = "PDF_CHROME_PATH"
    PDF_CONVERTER_TIMEOUT = "PDF_CONVERTER_TIMEOUT"
    PDF_CONVERTER_MEMORY  = "PDF_CONVERTER_MEMORY"
)
```

### Reading Config in Code

```go
// Always use viper.GetString/GetInt with constant keys
port := viper.GetString(constant.GRPC_PORT)
maxConns := viper.GetInt(constant.DB_RETRY_MAX_ATTEMPTS)
```

---

## 6. Encryption (PII Protection)

Three encryption tiers using external SDK + internal helpers.

### Primary SDK: Encryption Library

```go
import "yourmodule/go-sdk/crypt"

// AES-256-CBC (highest sensitivity: bank accounts, SSN, passport)
encrypted, err := crypt.EncryptAES256CBC(key, plaintext)
decrypted, err := crypt.DecryptAES256CBC(key, ciphertext)

// RSA-OAEP (inter-service communication, key exchange)
encrypted, err := crypt.EncryptRSAOAEP(pubKey, plaintext)
decrypted, err := crypt.DecryptRSAOAEP(privKey, ciphertext)

// HMAC-SHA256 (signature validation)
signature := crypt.HmacSHA256(key, message)
```

### Internal Helpers: AES-128

```go
// File: src/helpers/common.go

// AES-128-CBC (standard PII: names, addresses)
encrypted, err := helpers.EncryptAES128CBC(key, plaintext)
decrypted, err := helpers.DecryptAES128CBC(key, ciphertext)
```

Padding uses PKCS7 via `github.com/mergermarket/go-pkcs7`. Output is hex-encoded.

### Custom GORM Types for Transparent Encryption

```go
// File: src/model/types/
type EncryptedAES string   // Implements driver.Valuer (encrypt on write) + sql.Scanner (decrypt on read)
```

Usage in entities:

```go
type User struct {
    BaseEntitySF
    Firstname types.EncryptedAES `gorm:"column:firstname"`   // Auto-encrypted
    Lastname  types.EncryptedAES `gorm:"column:lastname"`    // Auto-encrypted
    Email     types.EncryptedAES `gorm:"column:email"`       // Auto-encrypted
    Phone     types.EncryptedAES `gorm:"column:phone"`       // Auto-encrypted
}
```

### Encryption Tiers

| Data Type | Encryption | Key |
|---|---|---|
| Bank account numbers | AES-256-CBC | `AES_KEY` (32 bytes) |
| SSN, passport numbers | AES-256-CBC | `AES_KEY` (32 bytes) |
| User names, addresses | AES-128-CBC | `AES_128_KEY` (16 bytes) |
| Email, phone (in EncryptedAES type) | AES-128-CBC | `AES_128_KEY` (16 bytes) |
| Order IDs, non-sensitive data | None | Not sensitive |

### Signature Generation

```go
// File: src/helpers/signature_helpers.go
// SHA256 hash of deterministic JSON for data integrity
func GenerateChargesSignature(charges []ChargeItem) string {
    data, _ := json.Marshal(charges)
    hash := sha256.Sum256(data)
    return hex.EncodeToString(hash[:])
}
```

---

## 7. Zap Logger

### Setup

```go
// File: src/logger/zap_logger.go

func NewZapLogger() *zap.Logger {
    level := parseLevel(viper.GetString(constant.ZAP_LOG_LEVEL))  // default: info
    format := viper.GetString(constant.ZAP_LOG_FORMAT)            // json or console
    output := viper.GetString(constant.ZAP_LOG_OUTPUT)            // stdout, file, or both

    encoderConfig := zapcore.EncoderConfig{
        TimeKey:        "timestamp",
        LevelKey:       "level",
        MessageKey:     "message",
        CallerKey:      "caller",
        StacktraceKey:  "stacktrace",
        EncodeTime:     zapcore.ISO8601TimeEncoder,
        EncodeLevel:    zapcore.LowercaseLevelEncoder,
        EncodeCaller:   zapcore.ShortCallerEncoder,
    }

    // File rotation via lumberjack
    fileWriter := &lumberjack.Logger{
        Filename:   viper.GetString(constant.ZAP_LOG_FILE),  // default: /var/data/app.log
        MaxSize:    100,   // MB
        MaxBackups: 7,
        MaxAge:     14,    // days
        Compress:   true,
    }

    // Build core based on output setting
    var core zapcore.Core
    switch output {
    case "file":
        core = zapcore.NewCore(encoder, zapcore.AddSync(fileWriter), level)
    case "both":
        core = zapcore.NewTee(
            zapcore.NewCore(encoder, zapcore.AddSync(os.Stdout), level),
            zapcore.NewCore(encoder, zapcore.AddSync(fileWriter), level),
        )
    default: // stdout
        core = zapcore.NewCore(encoder, zapcore.AddSync(os.Stdout), level)
    }

    return zap.New(core, zap.AddCaller(), zap.AddStacktrace(zap.ErrorLevel))
}
```

### Defaults

| Setting | Default | Constant |
|---|---|---|
| Log level | `info` | `ZAP_LOG_LEVEL` |
| Format | `json` | `ZAP_LOG_FORMAT` |
| Output | `stdout` | `ZAP_LOG_OUTPUT` |
| File path | `/var/data/app.log` | `ZAP_LOG_FILE` |
| Max size | 100 MB | — |
| Max backups | 7 files | — |
| Max age | 14 days | — |
| Compression | enabled | — |

### Usage in Services

```go
// Via global Zap instance in src/app/app.go
app.Zap.Info("order created",
    zap.Uint64("order_id", order.ID),
    zap.String("code", order.Code),
    zap.Duration("processing_time", duration),
)

app.Zap.Error("failed to process order",
    zap.Error(err),
    zap.Uint64("order_id", orderID),
)
```

### Common Structured Fields

Use consistent field names across the codebase:

| Field | Type | Context |
|-------|------|---------|
| `sid` | `zap.String` | Session/request ID (from SID middleware) |
| `endpoint` | `zap.String` | gRPC full method name |
| `order_id` | `zap.Uint64` | Entity correlation |
| `transaction_id` | `zap.Uint64` | Entity correlation |
| `processing_time` | `zap.Duration` | Latency tracking |
| `error` | `zap.Error` | Error context |

### Panic Recovery Pattern

Every exported service method must use `defer helpers.LogAndCatchPanic()`:

```go
// File: src/helpers/common.go
func LogAndCatchPanic() {
    if r := recover(); r != nil {
        // Log to external crash reporting service (ClogRPC)
        clog.Report(r, string(debug.Stack()))
        // Print stack trace to stderr
        fmt.Fprintf(os.Stderr, "panic: %v\n%s", r, debug.Stack())
    }
}

// Variant that re-panics after logging (for middleware use)
func LogAndRethrowPanic() {
    if r := recover(); r != nil {
        clog.Report(r, string(debug.Stack()))
        panic(r)
    }
}
```

### gRPC Logging Middleware

```go
// File: src/middleware/grpc_zap_logger_middleware.go
func ZapInterceptorLogger(l *zap.Logger) logging.Logger {
    // Defensive limits to prevent memory issues:
    // - Message body: max 1KB
    // - Field values: max 512B
    // Truncates silently if exceeded
}
```

### Request/Response Logging

Selective logging via `LoggableEndpoints` map — only configured endpoints log full req/res:

```go
// File: src/middleware/request_response_log_middleware.go
// Triggered by: endpoint in LoggableEndpoints map OR x-log-request-response header
// Captures: request body, response, latency, client IP, user agent
// Stores to: RequestResponseLog entity
```

---

## 8. App Initialization

### Global Resources

```go
// File: src/app/app.go

var Logger *logrus.Logger       // Logrus instance (JSON format)
var LoggerEntry *logrus.Entry   // Logrus entry point
var Zap *zap.Logger             // Zap logger with file rotation
```

### Encryption Key Auto-Generation

On first startup, encryption keys are auto-generated if missing from `.env`:

```go
func InitKeys() {
    // 1. AES-256 key (32 bytes) — for highest sensitivity data
    if viper.GetString(constant.AES_KEY) == "" {
        key := make([]byte, 32)
        rand.Read(key)
        viper.Set(constant.AES_KEY, base64.StdEncoding.EncodeToString(key))
    }

    // 2. AES-128 key (16 bytes) — for standard PII
    if viper.GetString(constant.AES_128_KEY) == "" {
        key := make([]byte, 16)
        rand.Read(key)
        viper.Set(constant.AES_128_KEY, base64.StdEncoding.EncodeToString(key))
    }

    // 3. RSA-2048 keypair — for inter-service encryption
    if viper.GetString("RSA_PUBLIC_KEY") == "" {
        privKey, _ := rsa.GenerateKey(rand.Reader, 2048)
        pubPEM := marshalPublicKey(&privKey.PublicKey)
        privPEM := marshalPrivateKey(privKey)
        // Encrypt private key with AES-256 before storing
        encPriv, _ := crypt.EncryptAES256CBC(viper.GetString(constant.AES_KEY), string(privPEM))
        viper.Set("RSA_PUBLIC_KEY", string(pubPEM))
        viper.Set("RSA_PRIVATE_KEY", encPriv)
    }

    // Persist to .env
    viper.WriteConfig()
}
```

### Snowflake ID Generation

Per-entity type Snowflake nodes for distributed unique ID generation:

```go
// Map of entity type → snowflake node
var snowflakeNodes map[reflect.Type]*snowflake.Node

func GetSnowflakeID(entityType interface{}) snowflake.ID {
    t := reflect.TypeOf(entityType)
    node, exists := snowflakeNodes[t]
    if !exists {
        node, _ = snowflake.NewNode(1)  // Node ID 1 for all entities
        snowflakeNodes[t] = node
    }
    return node.Generate()
}
```

---

## 9. Context Helpers

### Context Keys

```go
// File: src/helpers/context_helper.go

const (
    ContextKeyIP        = "__ip__"
    ContextKeyUserAgent = "__user_agent__"
    ContextKeyCountry   = "__country__"
    ContextKeyLocation  = "__location__"
    AppKey              = "_app_"
    StaffSessionKey     = "_staff_session_"
    StaffKey            = "_staff_"
    SIDContextKey       = "_request_sid_"
    RestAppIdCtxKey     = "_rest_app_id"
    StartTimeContextKey = "_start_time_"
)
```

### Type-Safe Extractors

```go
func GetIPFromContext(ctx context.Context) string {
    if val, ok := ctx.Value(ContextKeyIP).(string); ok {
        return val
    }
    return ""
}

func GetSIDFromContext(ctx context.Context) string {
    if val, ok := ctx.Value(SIDContextKey).(string); ok {
        return val
    }
    return ""
}

func GetDurationFromContext(ctx context.Context) string {
    if startTime, ok := ctx.Value(StartTimeContextKey).(time.Time); ok {
        return fmt.Sprintf("%dms", time.Since(startTime).Milliseconds())
    }
    return ""
}

func GetLocaleFromContext(ctx context.Context) string {
    md, ok := metadata.FromIncomingContext(ctx)
    if !ok {
        return "en"
    }
    langs := md.Get("accept-language")
    if len(langs) == 0 || langs[0] == "" {
        return "en"
    }
    tag := strings.Split(langs[0], "-")[0]
    tag = strings.Split(tag, ",")[0]
    return strings.ToLower(strings.TrimSpace(tag))
}
```

### Common Utility Functions

```go
// File: src/helpers/common.go

// Time formatting helpers
func RFC3339(t *time.Time) string {
    if t != nil {
        return t.Format(time.RFC3339)
    }
    return ""
}

func RFC3339Ptr(t *time.Time) string {
    if t == nil {
        return ""
    }
    return t.Format(time.RFC3339)
}

// Panic recovery with logging
func RecoverPanic(label string) {
    if r := recover(); r != nil {
        app.Zap.Error("panic recovered",
            zap.String("label", label),
            zap.Any("error", r),
            zap.String("stack", string(debug.Stack())),
        )
    }
}

// Client IP extraction from HTTP request
func GetClientIP(r *http.Request) string {
    forwarded := r.Header.Get("X-Forwarded-For")
    if forwarded != "" {
        return strings.Split(forwarded, ",")[0]
    }
    realIP := r.Header.Get("X-Real-IP")
    if realIP != "" {
        return realIP
    }
    ip, _, _ := net.SplitHostPort(r.RemoteAddr)
    return ip
}
```

### Message Size Constants

```go
// File: src/middleware/middleware.go
const (
    MaxMessageSize  = 50 * 1024 * 1024  // 50MB
    MaxRequestSize  = 50 * 1024 * 1024  // 50MB
    MaxResponseSize = 50 * 1024 * 1024  // 50MB
)
```

---

## 10. PDF Infrastructure

### Storage Provider Interface

```go
// File: src/helpers/pdf_storage_provider.go

type PDFStorageProvider interface {
    Store(ctx context.Context, data []byte, path string) (string, error)
    StoreFromReader(ctx context.Context, reader io.Reader, path string) (string, error)
    Retrieve(ctx context.Context, path string) ([]byte, error)
    RetrieveReader(ctx context.Context, path string) (io.ReadCloser, error)
    Delete(ctx context.Context, path string) error
    GetURL(ctx context.Context, path string) (string, error)
    Exists(ctx context.Context, path string) (bool, error)
}
```

### Storage Types

| Type | Config Value | Description |
|---|---|---|
| `local` | `PDF_STORAGE_TYPE=local` | Local filesystem, configured with `PDF_LOCAL_PATH` |
| `gcs` | `PDF_STORAGE_TYPE=gcs` | Google Cloud Storage, configured with `PDF_GCS_BUCKET` |

### HTML to PDF Converter

Chromium-based conversion via headless browser:

```go
// File: src/helpers/pdf_html_converter.go

type PDFHTMLConverter struct {
    ChromePath string        // from PDF_CHROME_PATH
    Timeout    time.Duration // from PDF_CONVERTER_TIMEOUT (default 30s)
    MemoryLimit string       // from PDF_CONVERTER_MEMORY (default 512MB)
}

func (c *PDFHTMLConverter) Convert(html string) ([]byte, error) {
    // Launch headless Chrome/Chromium
    // Render HTML → PDF via Puppeteer protocol
    // Return PDF bytes
}
```

### Worker Manager

PDF generation is processed asynchronously via NATS JetStream (see Section 3):

```go
// File: src/worker/pdf_generation_worker_manager.go

type PDFGenerationWorkerManager struct {
    consumer   *pool.PDFGenerationConsumer
    converter  *helpers.PDFHTMLConverter
    storage    helpers.PDFStorageProvider
    templateSvc service.PDFTemplateService
}

// Tracks: active consumers, processed jobs, failed jobs
// Supports: health check, graceful shutdown
```

Started in the admin gRPC server:

```go
// In engine/grpc/grpc.go
worker.StartPDFGenerationWorkerManager(pdfWorkerCount)
```

---

## 11. Supervisord (Multi-Process)

### Overview

Supervisord runs all server processes on a single machine:

| Process | Binary | Priority | Group |
|---|---|---|---|
| gRPC Admin | `/app/grpc` | 100 | api-servers |
| gRPC Insider | `/app/grpc-insider` | 101 | api-servers |
| gRPC Public | `/app/grpc-public` | 102 | api-servers |
| REST Admin | `/app/rest` | 103 | api-servers |
| REST Insider | `/app/rest-insider` | 104 | api-servers |
| REST Public | `/app/rest-public` | 105 | api-servers |
| Routine | `/app/routine` | 106 | background |

Priorities control startup order (lower starts first): gRPC servers → REST gateways → background routine.

### Configuration

```ini
[program:grpc-admin]
command=/app/grpc
directory=/app
autostart=true
autorestart=true
stdout_logfile=/var/log/grpc-admin.log
stderr_logfile=/var/log/grpc-admin-error.log
priority=100

; ... similar blocks for each process
```

### Building Binaries

```bash
make build-linux
# Output: build/grpc, build/grpc-insider, build/grpc-public,
#         build/rest, build/rest-insider, build/rest-public, build/routine
```

### Managing Processes

```bash
supervisorctl start all
supervisorctl start api-servers
supervisorctl stop all
supervisorctl restart grpc-admin
supervisorctl status
supervisorctl tail grpc-admin -f
```

---

## Summary Table

| Component | Purpose | Library | Pattern |
|---|---|---|---|
| Database | Entity persistence | GORM + MySQL | Singleton `GetDB()` |
| Redis | Caching + distributed locks | go-redis | Singleton `Cache` |
| Channels | In-process event passing | stdlib | Per-domain pool (100 buffer) |
| NATS | Persistent job processing | nats-go + JetStream | PDF_GENERATION stream |
| Wire DI | Constructor injection | google/wire | `wire_gen.go` |
| Config | Environment management | Viper + Vault + GSM | Constants pattern |
| Encryption | PII protection | go-sdk/crypt + stdlib | AES-256/128, RSA-2048 |
| Logging | Structured logging | Zap + lumberjack | JSON + file rotation |
| PDF | Document generation | Chromium + GCS/local | NATS-driven async |
| Process Mgmt | Multi-process orchestration | Supervisord | 7 binaries |

---

## 12. Helpers & Calculators

Financial calculations live in `src/helpers/` as pure functions. All follow the **sign convention**: fees, charges, and taxes are stored as **negative values**; only bonuses are positive.

### Calculator Files

| File | Purpose | Sign |
|------|---------|------|
| `fee_calculator.go` | Subscription/redemption fee (inclusive/deductive) | **Negative** |
| `charge_calculator.go` | Charges (% or fixed, before/after fee) | **Negative** |
| `tax_calculator.go` | Tax on fees | **Negative** |
| `bonus_calculator.go` | Bonuses (% or fixed) | **Positive** |

### Sign Convention

```
Fee    = -(amount × feeRate)           // Always negative
Charge = -(amount × chargeRate)        // Always negative
Tax    = -(abs(feeAmount) × taxRate)   // Always negative (calculated on absolute fee)
Bonus  = +(amount × bonusRate)         // Only positive item
```

When calculating net amount: `GrossAmount + Fee + Tax + Charge + Bonus` — negatives subtract naturally.

### Function Signatures

```go
// src/helpers/fee_calculator.go
func CalculateSubscriptionFee(totalAmount, feePercentage decimal.Decimal) FeeCalculationResult
func CalculateRedemptionFee(baseAmount, feePercentage decimal.Decimal) FeeCalculationResult

// src/helpers/charge_calculator.go
func ApplySubscriptionCharges(baseAmount decimal.Decimal, charges []ChargeConfig, isAfterFee bool) ChargeCalculationResult

// src/helpers/tax_calculator.go
func CalculateSubscriptionTax(feeAmount, taxPercentage decimal.Decimal) TaxCalculationResult

// src/helpers/bonus_calculator.go
func ApplySubscriptionBonuses(baseAmount decimal.Decimal, bonuses []BonusConfig) BonusCalculationResult
```

### Decimal Precision Rules

- **Library**: `shopspring/decimal` — never use `float64` for money
- **Calculation**: `.Truncate(14)` after every calculator result
- **Display**: `.StringFixed(8)` for user-facing output (DEFAULT_PRECISION = 8)
- **Storage**: `DECIMAL(64,15)` in database
- **Rounding**: Always truncate (round down) — never round up for user-facing amounts

### Service Calculation Flow

```
GrossAmount
  → Apply before-fee bonuses     (+)
  → Apply before-fee charges     (-)
  → CalculateFee()               (-)
  → CalculateTax(abs(fee))       (-)
  → Apply after-fee bonuses      (+)
  → Apply after-fee charges      (-)
  → FinalAmount = sum of all
```

### Shared Helper Functions

```go
// Decimal to fixed-string (for Sign interface, display, etc.)
func DecimalPtrToStringFixed(d *decimal.Decimal, precision int32) string

// Panic recovery — mandatory at top of every exported service method
func LogAndCatchPanic()

// Transaction helper — commit on success, rollback on panic
func CommitOrRollback(repo repository.BaseRepository, err *error)
```

---

## 13. Anti-Patterns

| Anti-pattern | Why it breaks | Fix |
|---|---|---|
| `SkipDefaultTransaction: false` (GORM default) | GORM wraps every single write in a transaction — ~3× slower on simple inserts | Set `SkipDefaultTransaction: true`; wrap explicitly only where needed |
| `PrepareStmt: false` (GORM default) | Re-parses SQL on every call — wasted CPU on hot paths | Set `PrepareStmt: true` for the production connection pool |
| Opening DB connection directly in service/controller | Connection is not pooled; can't be mocked in tests; Wire can't inject it | Always inject `*gorm.DB` via Wire from `database.GetDB()` |
| Using Redis `Set` without TTL for application-level caches | Key lives forever; Redis OOMs on large keyspaces | Always set a TTL: `CacheManager.Set(key, value, ttl)` |
| Using Redis `KEYS *` for cache invalidation by pattern | Blocks Redis single-threaded event loop while scanning all keys | Use `SCAN` with a cursor, or design keys so invalidation targets exact IDs |
| NATS publish without setting tenant/trace headers | Consumer loses tenant context; audit trail breaks | Set `X-Tenant-ID` and `X-Trace-ID` in `msg.Header` before `js.PublishMsg` |
| Calling `wire.Build(...)` in business code | Wire generators parse `wire.Build` at codegen time; runtime calls panic | `wire.Build` is only valid inside `//go:build wireinject` files in `injector/inject/` |
| Returning concrete `*ServiceImpl` from `New*` constructor | Wire can't resolve interface → implementation mapping | Constructor must return the interface: `func NewOrderService(...) OrderService` |
| Reading `viper.Get*` directly in service or repository | Couples business code to config; impossible to test with different values | Inject config values through constructors or use a typed `Config` struct |
| Using `app.GetXxx()` singletons inside unit-tested code | Singletons require full app init; unit tests can't run in isolation | Inject dependencies via Wire; `app.GetXxx()` only in `engine/` entry points |
| Plaintext sensitive field in entity struct (`type Email string`) | DB stores plaintext; logs may leak PII | Use `types.EncryptedAES128` or appropriate encrypted type |
| Supervisord `autorestart=false` for critical processes | Process crash stops silently; no recovery until manual intervention | Set `autorestart=true`, `startretries=3` for all 7 processes |

---

## Related References

- **Service Patterns** (`service-patterns.md`) — Transaction management with `StartTx`/`CommitTx`/`RollbackTx`
- **Scheduler Patterns** (`scheduler-patterns.md`) — CronLocker distributed locking, DB-driven scheduling
- **Provider Integration** (`provider-integration-patterns.md`) — External service clients (Payment, Product, Backoffice)
- **Security** (`security.md`) — Encryption key management, govulncheck, Vault secrets
- **Context Patterns** (`context-patterns.md`) — How to propagate tenant/trace through NATS, gRPC, HTTP
