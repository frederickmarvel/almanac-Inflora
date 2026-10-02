# Provider & Integration Patterns

Two complementary patterns for inter-service communication via gRPC: **Providers** (consuming external services) and **Integration SDK** (exposing this service to consumers).

## Table of Contents

1. [Overview](#overview)
2. [Provider Pattern (Outbound Clients)](#provider-pattern-outbound-clients)
3. [Integration SDK Pattern (Inbound Clients)](#integration-sdk-pattern-inbound-clients)
4. [Authentication (TOTP)](#authentication-totp)
5. [Wire Injection](#wire-injection)
6. [Best Practices](#best-practices)
7. [Anti-Patterns](#anti-patterns)
8. [Related References](#related-references)

---

## Overview

```
┌──────────────────────────────────────────────────────────┐
│                    your-service                           │
│                                                          │
│  src/provider/          ←── Outbound: consumes others    │
│    billing_client.go        (billing, catalog,           │
│    catalog_client.go         notification engines)        │
│    notification_client.go                                │
│                                                          │
│  integration/           ←── Inbound: others consume me   │
│    admin/v1/                (gRPC client SDK shipped      │
│    insider/v1/               as Go module for consumers)  │
│    public/v1/                                            │
└──────────────────────────────────────────────────────────┘
```

**Direction matters**:
- `src/provider/` = "I call you" — wraps external service SDKs for internal use
- `integration/` = "You call me" — client SDK this service ships for external consumers

---

## Provider Pattern (Outbound Clients)

### Purpose

Provider files wrap external gRPC client SDKs as Wire-injectable singletons. They handle connection lifecycle, credential management, and lazy initialization.

### File Location

```
src/provider/
├── billing_client.go       # Billing-engine clients (payment gateway, disbursement)
├── catalog_client.go       # Catalog-engine client (product catalog)
└── notification_client.go  # Notification-engine clients (email, push)
```

### Pattern Structure

Each provider file follows this structure:

```go
package provider

import (
    "fmt"
    "sync"

    "github.com/spf13/viper"
    externalintegration "external-org/external-engine/integration"
    "your-module/src/app"
    "your-module/src/constant"
)

var (
    clientOnce sync.Once   // Ensures initialization happens exactly once
    clientErr  error       // Stores init error (if any)
)

// initClient initializes the external service connection (internal).
func initClient() error {
    clientOnce.Do(func() {
        // 1. Read config from Viper
        host := viper.GetString(constant.EXTERNAL_ENGINE_HOST)
        port := viper.GetString(constant.EXTERNAL_ENGINE_PORT)
        clientID := viper.GetString(constant.EXTERNAL_ENGINE_CLIENT_ID)
        clientKey := viper.GetString(constant.EXTERNAL_ENGINE_CLIENT_KEY)
        verifyTLS := viper.GetBool(constant.EXTERNAL_ENGINE_VERIFY_TLS)
        totpFactor := viper.GetInt64(constant.EXTERNAL_ENGINE_TOTP_FACTOR)

        // 2. Validate required config
        if host == "" || port == "" {
            clientErr = fmt.Errorf("external-engine host and port required")
            return
        }
        if clientID == "" || clientKey == "" {
            clientErr = fmt.Errorf("external-engine credentials required")
            return
        }

        // 3. Build config for external SDK
        config := externalintegration.Config{
            Host:       host,
            Port:       port,
            ClientID:   &clientID,
            ClientKey:  &clientKey,
            VerifyTLS:  verifyTLS,
            TotpFactor: totpFactor,
        }

        // 4. Connect each sub-client the service needs
        if err := externalintegration.ConnectSomeClient(config); err != nil {
            clientErr = fmt.Errorf("failed to connect: %w", err)
            return
        }
    })
    return clientErr
}

// ProvideSomeClient returns the client for Wire injection.
func ProvideSomeClient() (externalintegration.SomeClient, error) {
    if err := initClient(); err != nil {
        return nil, err
    }
    return externalintegration.GetSomeClient()
}
```

### Key Characteristics

1. **sync.Once**: Each external service initializes exactly once, even with concurrent callers
2. **Error persistence**: `clientErr` is set once during `Do()` — subsequent calls return the same error
3. **Multiple sub-clients per service**: One `initClient()` can connect multiple sub-clients (e.g., billing → PaymentGateway, Disbursement, Refund)
4. **Provide* functions**: Wire-compatible functions that init + return the specific client interface
5. **Config from Viper constants**: All connection params sourced from env/config

### Example Provider Layout

| Provider | External Service | Sub-Clients |
|----------|-----------------|-------------|
| **billing_client.go** | billing-engine | PaymentGatewayClient, DisbursementClient |
| **catalog_client.go** | catalog-engine | CatalogClient + helper functions (LoadItemForOrder, LoadItemsForOrders) |
| **notification_client.go** | notification-engine | EmailClient, PushClient |

Each external service gets one provider file. Group all sub-clients for that service in the same file.

### Standalone Helper Pattern (for Non-Injectable Contexts)

Some providers include **standalone helper functions** for use in GORM hooks or other contexts where Wire injection is unavailable:

```go
// LoadItemForOrder loads external catalog data for a single order item.
// Used by GORM hooks that cannot receive injected dependencies.
func LoadItemForOrder(ctx context.Context, itemID uint64) (*frame.CatalogItem, error) {
    client, err := ProvideCatalogClient()
    if err != nil {
        return nil, err
    }
    res, err := client.Get(&cataloginsiderv1.GetItemReqRPC{Id: &itemID})
    if err != nil {
        return nil, err
    }
    // Map proto response → frame DTO
    return mapToFrameItem(res.GetData()), nil
}

// LoadItemsForOrders loads items in batch (deduplicates IDs).
func LoadItemsForOrders(ctx context.Context, itemIDs []uint64) (map[uint64]*frame.CatalogItem, error) {
    // Deduplicate IDs, batch fetch, return map[id]*CatalogItem
}
```

---

## Integration SDK Pattern (Inbound Clients)

### Purpose

The `integration/` directory is a **gRPC client SDK** that this microservice ships as part of its Go module. Other microservices import it to call this service's APIs.

### File Location

```
integration/
├── admin/v1/
│   ├── integration.go           # Connection manager + client registry
│   ├── order_client.go          # Interface definition
│   ├── order_client_impl.go     # Implementation
│   ├── category_client.go
│   ├── category_client_impl.go
│   └── ... (one pair per entity)
├── insider/v1/
│   ├── integration.go
│   └── ... (subset of admin clients)
└── public/v1/
    ├── integration.go
    └── ... (read-only subset)
```

### Three Tiers (Mirrors Server)

Each tier exposes only the operations appropriate for that access level:

| Tier | Package | Available Clients |
|------|---------|-------------------|
| **Admin** | `integration/admin/v1` | Order, Transaction, Category, User, Ledger, etc. (all entity clients) |
| **Insider** | `integration/insider/v1` | Order, Transaction, Category, User, etc. (subset) |
| **Public** | `integration/public/v1` | Order, Category, User (read-only subset) |

### Integration.go (Connection Manager)

Each tier has an `integration.go` that manages:

```go
package adminv1

var connection *grpc.ClientConn   // Shared connection per tier
var orderClient OrderClient        // Singleton clients
var fundClient FundClient
// ... more client vars

type Config struct {
    Host       string
    Port       string
    ClientID   *string
    ClientKey  *string
    VerifyTLS  bool
    TotpFactor int64
}

// connect creates or reuses a gRPC connection with auto TLS detection
func connect(config Config) (*grpc.ClientConn, error) {
    if connection != nil && connection.GetState() == connectivity.Ready {
        return connection, nil  // Reuse existing
    }
    // Close stale connection, create new one
    address := fmt.Sprintf("%s:%s", config.Host, config.Port)
    creds := insecure.NewCredentials()
    if IsServerUseTLS(address) {
        creds = credentials.NewTLS(&tls.Config{InsecureSkipVerify: !config.VerifyTLS})
    }
    return grpc.NewClient(address, grpc.WithTransportCredentials(creds))
}

// Per-client Connect/Get pairs
func ConnectOrderClient(config Config) error { /* connect + create */ }
func GetOrderClient() (OrderClient, error)   { /* return or error if nil */ }

// Cleanup
func CloseConnections() { /* close conn + nil all clients */ }
```

### Client Interface + Implementation

**Interface** (`order_client.go`):
```go
type OrderClient interface {
    getContext() (ctx context.Context, cancel context.CancelFunc)
    Get(in *adminv1.GetOrderReqRPC) (r *adminv1.GetOrderResRPC, err error)
    Gets(in *adminv1.GetOrdersReqRPC) (r *adminv1.GetOrdersResRPC, err error)
    // ... all RPC methods
}
```

**Implementation** (`order_client_impl.go`):
```go
type OrderClientImpl struct {
    clientID   *string
    clientKey  *string
    client     adminv1.OrderClient   // Proto-generated gRPC client
    totpFactor int64
}

func (g *OrderClientImpl) Get(in *adminv1.GetOrderReqRPC) (r *adminv1.GetOrderResRPC, err error) {
    ctx, done := g.getContext()   // Creates context with TOTP auth metadata
    defer done()
    r, err = g.client.Get(ctx, in)
    return handleResponse(r, err, "Get")
}
```

### Key Characteristics

1. **Auto TLS detection**: `IsServerUseTLS()` probes the server to determine if TLS is needed
2. **Shared connection**: All clients in a tier share one `*grpc.ClientConn`
3. **TOTP authentication**: Each request adds `X-Client-ID` and `Authorization: TOTP <token>` headers via gRPC metadata
4. **Generic error handler**: `handleResponse[T]()` uses Go generics for uniform error logging
5. **Connect/Get split**: Consumer must call `ConnectXxxClient(config)` before `GetXxxClient()`

---

## Authentication (TOTP)

Both patterns use TOTP (Time-based One-Time Password) for inter-service authentication:

```go
import "git.verzth.work/go/utils"

func (g *OrderClientImpl) getContext() (ctx context.Context, cancel context.CancelFunc) {
    ctx = context.Background()
    if g.clientID != nil && g.clientKey != nil {
        totp := utils.GenerateSignature(*g.clientKey, g.totpFactor)
        ctx = metadata.NewOutgoingContext(ctx, metadata.New(map[string]string{
            "X-Client-ID":   *g.clientID,
            "Authorization": fmt.Sprintf("TOTP %s", totp),
        }))
    }
    return context.WithCancel(ctx)
}
```

- **Client ID**: Identifies the calling service
- **Client Key**: Shared secret used to generate TOTP token
- **TOTP Factor**: Time step in seconds (default 30)
- **Header format**: `Authorization: TOTP <generated_token>`

---

## Wire Injection

### Provider → Service Injection

Provider `Provide*` functions are used in Wire injectors:

```go
// injector/inject/injector.go
func InitializeOrderController() (proto.OrderServer, error) {
    wire.Build(
        controller.NewOrderController,
        service.NewOrderService,
        transformer.NewOrderTransformer,
        repository.NewOrderRepository,
        database.GetDB,

        // External service providers
        provider.ProvideCatalogClient,
        provider.ProvidePaymentGatewayClient,
        // ... other external providers as needed
    )
    return nil, nil
}
```

### Integration SDK Usage (by consumers)

External services import the integration package:

```go
import svcint "yourmodule/integration/admin/v1"

func main() {
    config := svcint.Config{
        Host:      "your-service:50051",
        Port:      "50051",
        ClientID:  &clientID,
        ClientKey: &clientKey,
    }

    // Initialize clients
    svcint.ConnectOrderClient(config)
    svcint.ConnectCategoryClient(config)

    // Use clients
    orderClient, _ := svcint.GetOrderClient()
    res, err := orderClient.Get(&adminv1.GetOrderReqRPC{Id: &orderID})

    // Cleanup
    defer svcint.CloseConnections()
}
```

---

## Best Practices

### Provider Rules

1. **One provider file per external service** — group all sub-clients for that service
2. **sync.Once for initialization** — never init twice, even under concurrency
3. **Provide* functions for Wire** — each sub-client gets its own `Provide*` function
4. **Helper functions for non-injectable contexts** — GORM hooks can't use Wire, so use standalone helpers like `LoadProductForItem()`
5. **Config from constants** — all env vars referenced via `constant.SOME_KEY`
6. **Log init progress** — log each sub-client connection attempt and result

### Integration SDK Rules

1. **Mirror server tiers** — admin/insider/public, same access restrictions
2. **Interface + Impl per client** — interface in `*_client.go`, impl in `*_client_impl.go`
3. **Shared connection per tier** — one `*grpc.ClientConn` for all clients in a tier
4. **Connect before Get** — consumer must call `ConnectXxxClient()` before using
5. **TOTP on every request** — `getContext()` generates fresh TOTP per call
6. **Generic handleResponse** — uniform error logging with method name
7. **CloseConnections cleanup** — nil all clients + close conn on shutdown

### Adding a New Provider

1. Create `src/provider/new_service_client.go`
2. Add `sync.Once` + `clientErr` vars
3. Add `initNewServiceClient()` with config reading + connection
4. Add `ProvideXxxClient()` for each sub-client
5. Add config constants to `src/constant/constant.go`
6. Wire into injector: add `provider.ProvideXxxClient` to relevant `wire.Build()` calls

### Adding a New Integration Client

1. Create interface: `integration/{tier}/v1/new_client.go`
2. Create impl: `integration/{tier}/v1/new_client_impl.go`
3. Add singleton var + Connect/Get in `integration.go`
4. Implement `getContext()` for TOTP auth
5. Wrap each RPC method with `handleResponse()`

---

## Anti-Patterns

| Anti-pattern | Why it breaks | Fix |
|---|---|---|
| Returning `*ServiceImpl` (concrete type) from `Provide*` | Wire can't substitute mocks in tests; breaks Wire's interface-based injection | Return the interface type: `Provide*() (SomeClient, error)` |
| Calling `initClient()` multiple times or skipping `sync.Once` | Concurrent calls create multiple connections; connection state conflicts | All initialization goes inside `clientOnce.Do(...)` |
| One provider file per sub-client | Creates N `sync.Once` vars for the same upstream service; risk of partial init | One file per **external service** — all its sub-clients init together |
| Calling `context.Background()` in `getContext()` for providers | Disconnects deadline cascading; downstream can block after caller has given up | Use the inbound `ctx` passed to the method; create a per-call `WithTimeout` from it (→ `context-patterns.md §6`) |
| Calling `GetXxxClient()` without `ConnectXxxClient()` first | `GetXxxClient` returns error: client is nil | Always call `Connect*` in the Wire injector or integration init; never on-demand in business code |
| Storing client credentials as struct fields on service impls | Credentials leak into business code; breaks if credentials rotate | Credentials stay in `integration.go` / provider init only |
| Skipping `CloseConnections()` on shutdown | gRPC connections linger; port reuse issues on restart | Register `defer svcint.CloseConnections()` in `main()` or the engine shutdown hook |
| Cross-tier imports (`integration/admin/v1` used by insider handler) | Exposes admin-level data to lower-trust tier | Always import the tier-matched package |

---

## Related References

- → `references/context-patterns.md §6` — outbound provider ctx propagation (timeout, metadata injection)
- → `references/security.md` — TOTP generation, client credential rotation, TLS config
- → `references/infrastructure.md §4` — Wire DI wiring patterns for providers
- → `references/concurrency-patterns.md §4` — `sync.Once` correct usage and error-persistence semantics
- → `references/grpc-patterns.md` — server-side counterpart (how the inbound SDK calls are received)
