# REST Gateway Reference

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [GRPCGatewayServer Pattern](#2-grpcgatewayserver-pattern)
3. [Gateway Entry Point](#3-gateway-entry-point)
4. [Service Registration](#4-service-registration)
5. [Metadata Forwarding](#5-metadata-forwarding)
6. [Response Format](#6-response-format)
7. [Marshaler Options](#7-marshaler-options)
8. [HTTP Middleware Chain](#8-http-middleware-chain)
9. [Proto HTTP Annotations](#9-proto-http-annotations)
10. [Query Parameter Normalization](#10-query-parameter-normalization)
11. [Swagger & Metrics Endpoints](#11-swagger--metrics-endpoints)
12. [Health & Connection Check](#12-health--connection-check)
13. [Key Rules](#13-key-rules)
14. [Anti-Patterns](#14-anti-patterns)

---

## 1. Architecture Overview

REST is **not** implemented separately. It is auto-generated from gRPC proto definitions via **grpc-gateway/v2**. Each gRPC tier has a corresponding REST gateway running on its own port:

```
┌───────────────────────────────────────────────────────────────┐
│                     HTTP/1.1 Clients                          │
└───────────────────────────────────────────────────────────────┘
           │                    │                    │
           ▼                    ▼                    ▼
    [Admin REST]          [Insider REST]       [Public REST]
    Port: REST_PORT       REST_INSIDER_PORT    REST_PUBLIC_PORT
    gorilla/mux           gorilla/mux          gorilla/mux
    /v1/* → gRPC          /v1/* → gRPC         /v1/* → gRPC
    /docs/ → Swagger      /docs/ → Swagger     /docs/ → Swagger
    /metrics              /metrics             /metrics
           │                    │                    │
           ▼                    ▼                    ▼
    [Admin gRPC]          [Insider gRPC]       [Public gRPC]
    Port: GRPC_PORT       GRPC_INSIDER_PORT    GRPC_PUBLIC_PORT
```

The gateway receives HTTP/1.1 requests, translates them to gRPC calls via local connection (same machine, insecure credentials), and transforms gRPC responses back to JSON.

### File Structure

```
engine/rest/
├── rest.go                        # Admin gateway entry point
└── gateway/
    └── grpc_gateway.go            # GRPCGatewayServer + service registration

engine/rest-insider/
├── rest-insider.go                # Insider gateway entry point
└── gateway/
    └── grpc_gateway.go            # GRPCGatewayServer + service registration

engine/rest-public/
├── rest-public.go                 # Public gateway entry point
└── gateway/
    └── grpc_gateway.go            # GRPCGatewayServer + service registration
```

---

## 2. GRPCGatewayServer Pattern

Each gateway uses a `GRPCGatewayServer` struct that encapsulates the grpc-gateway ServeMux, connection, and service registration.

```go
// File: engine/rest/gateway/grpc_gateway.go

type GRPCGatewayServer struct {
    grpcServerAddr string
    gatewayMux     *runtime.ServeMux
}

func NewGRPCGatewayServer(grpcServerAddr string) *GRPCGatewayServer {
    gatewayMux := runtime.NewServeMux(
        // JSON marshaling options
        runtime.WithMarshalerOption(runtime.MIMEWildcard, &runtime.JSONPb{
            MarshalOptions: protojson.MarshalOptions{
                UseProtoNames:   true,
                EmitUnpopulated: true,
            },
            UnmarshalOptions: protojson.UnmarshalOptions{
                DiscardUnknown: true,
            },
        }),
        // Error handler
        runtime.WithErrorHandler(runtime.DefaultHTTPErrorHandler),
        // Metadata forwarding from HTTP headers → gRPC metadata
        runtime.WithMetadata(func(ctx context.Context, req *http.Request) metadata.MD {
            headerMap := make(map[string]string)

            if len(req.Header.Values("X-Forwarded-For")) > 0 {
                headerMap["x-forwarded-for"] = req.Header.Get("X-Forwarded-For")
            }
            if len(req.Header.Values("User-Agent")) > 0 {
                headerMap["user-agent"] = req.Header.Get("User-Agent")
            }
            if len(req.Header.Values("X-Client-ID")) > 0 {
                headerMap["x-client-id"] = req.Header.Get("X-Client-ID")
            }
            if len(req.Header.Values("Referer")) > 0 {
                headerMap["referer"] = req.Header.Get("Referer")
            }

            return metadata.New(headerMap)
        }),
    )

    return &GRPCGatewayServer{
        grpcServerAddr: grpcServerAddr,
        gatewayMux:     gatewayMux,
    }
}
```

### RegisterServices

Connects to the gRPC server and registers all service handlers:

```go
func (g *GRPCGatewayServer) RegisterServices(ctx context.Context) error {
    conn, err := grpc.NewClient(
        g.grpcServerAddr,
        grpc.WithTransportCredentials(insecure.NewCredentials()),
    )
    if err != nil {
        return fmt.Errorf("failed to connect to gRPC server: %w", err)
    }

    // Register all service handlers (see Section 4)
    if err := adminv2.RegisterOrderHandler(ctx, g.gatewayMux, conn); err != nil {
        return fmt.Errorf("failed to register Order handler: %w", err)
    }
    // ... more services

    return nil
}
```

### AttachToRouter

Mounts the gateway on the router with `/v1` path prefix and query normalization middleware:

```go
func (g *GRPCGatewayServer) AttachToRouter(router *mux.Router, pathPrefix string) {
    gatewayRouter := router.PathPrefix(pathPrefix).Subrouter()
    handler := normalizeArrayQueryParams(g.gatewayMux)
    gatewayRouter.PathPrefix("/").Handler(http.StripPrefix(pathPrefix, handler))
}
```

---

## 3. Gateway Entry Point

Each gateway entry point creates a gorilla/mux router, initializes the GRPCGatewayServer, registers services, adds middleware, and starts the HTTP server.

```go
// File: engine/rest/rest.go
package main

import (
    "context"
    "fmt"
    "os"

    gorillaHandlers "github.com/gorilla/handlers"
    "github.com/gorilla/mux"
    "github.com/prometheus/client_golang/prometheus/promhttp"
    "github.com/spf13/viper"
)

//go:embed openapi/* index.html
var content embed.FS

func main() {
    // Load config
    config.LoadConfig()

    // Create router
    r := mux.NewRouter()
    r.Use(mux.CORSMethodMiddleware(r))

    // Create and register gateway
    grpcAddress := fmt.Sprintf(":%s", viper.GetString(constant.GRPC_PORT))
    gatewayServer := gateway.NewGRPCGatewayServer(grpcAddress)
    ctx := context.Background()
    if err := gatewayServer.RegisterServices(ctx); err != nil {
        log.Fatalf("Failed to register gRPC gateway services: %v", err)
    }
    gatewayServer.AttachToRouter(r, "/v1")

    // Swagger docs
    subFS, _ := fs.Sub(content, ".")
    r.PathPrefix("/docs/").Handler(http.StripPrefix("/docs/", http.FileServer(http.FS(subFS))))

    // Metrics
    r.Handle("/metrics", promhttp.Handler())
    r.HandleFunc("/grpc-metrics", grpcMetricsProxy)

    // CORS config
    originsOk := gorillaHandlers.AllowedOrigins([]string{"*"})
    headersOk := gorillaHandlers.AllowedHeaders([]string{
        "Accept", "Authorization", "Content-Type", "Referer", "X-Client-ID",
    })

    // Start server with middleware chain
    restPort := fmt.Sprintf(":%s", viper.GetString(constant.REST_PORT))
    http.ListenAndServe(restPort,
        gorillaHandlers.CORS(originsOk, headersOk)(
            gorillaHandlers.CompressHandler(
                gorillaHandlers.LoggingHandler(os.Stdout, r),
            ),
        ),
    )
}
```

---

## 4. Service Registration

Each tier registers a different set of services. All use the auto-generated `RegisterXxxHandler()` function from proto.

### Admin Gateway

```go
func (g *GRPCGatewayServer) RegisterServices(ctx context.Context) error {
    conn, err := grpc.NewClient(g.grpcServerAddr,
        grpc.WithTransportCredentials(insecure.NewCredentials()))

    adminv2.RegisterOrderHandler(ctx, g.gatewayMux, conn)
    adminv2.RegisterOrderItemHandler(ctx, g.gatewayMux, conn)
    adminv2.RegisterHealthHandler(ctx, g.gatewayMux, conn)
    // ... register all other service handlers

    return nil
}
```

### Insider Gateway

```go
insiderv2.RegisterOrderHandler(ctx, g.gatewayMux, conn)
insiderv2.RegisterHealthHandler(ctx, g.gatewayMux, conn)
// ... register tier-specific handlers
```

### Public Gateway

```go
publicv2.RegisterOrderHandler(ctx, g.gatewayMux, conn)
publicv2.RegisterHealthHandler(ctx, g.gatewayMux, conn)
// ... register read-only handlers
```

---

## 5. Metadata Forwarding

HTTP headers are forwarded as gRPC metadata via `runtime.WithMetadata`. The `Authorization` header is auto-forwarded by grpc-gateway and does not need explicit configuration.

### Headers Forwarded (all tiers)

| HTTP Header | gRPC Metadata Key | Purpose |
|---|---|---|
| `X-Forwarded-For` | `x-forwarded-for` | Client IP from proxy |
| `User-Agent` | `user-agent` | HTTP User-Agent |
| `X-Client-ID` | `x-client-id` | Application identifier |
| `Referer` | `referer` | HTTP Referer |
| `Accept-Language` | `accept-language` | Locale for alert resolution |
| `Authorization` | `authorization` | Auto-forwarded by grpc-gateway |

### Extraction Pattern

```go
runtime.WithMetadata(func(ctx context.Context, req *http.Request) metadata.MD {
    headerMap := make(map[string]string)

    if len(req.Header.Values("X-Forwarded-For")) > 0 {
        headerMap["x-forwarded-for"] = req.Header.Get("X-Forwarded-For")
    }
    if len(req.Header.Values("User-Agent")) > 0 {
        headerMap["user-agent"] = req.Header.Get("User-Agent")
    }
    if len(req.Header.Values("X-Client-ID")) > 0 {
        headerMap["x-client-id"] = req.Header.Get("X-Client-ID")
    }
    if len(req.Header.Values("Referer")) > 0 {
        headerMap["referer"] = req.Header.Get("Referer")
    }
    if len(req.Header.Values("Accept-Language")) > 0 {
        headerMap["accept-language"] = req.Header.Get("Accept-Language")
    }

    return metadata.New(headerMap)
})
```

**Key pattern**: Check `req.Header.Values()` length before extracting with `req.Header.Get()`. This avoids setting empty metadata keys.

---

## 6. Response Format

The REST gateway passes through the gRPC response envelope unchanged, serialized via protojson. All field names use snake_case (proto names preserved).

### Success Response

```json
{
    "sid": "550e8400-e29b-41d4-a716-446655440000",
    "duration": "45ms",
    "status": 1,
    "code": "A-ORD-S-GET-001",
    "message": "success",
    "data": {
        "id": 123,
        "tenant_id": 1,
        "code": "ORD-2026-001",
        "amount": "1000000.00000000",
        "status": "completed"
    },
    "errors": [],
    "alert": {
        "type": "success",
        "title": "Success",
        "message": "Operation completed successfully"
    }
}
```

### Error Response

```json
{
    "sid": "550e8400-e29b-41d4-a716-446655440000",
    "duration": "12ms",
    "status": 0,
    "code": "G-SYS-E-GEN-002",
    "message": "invalid parameter",
    "data": null,
    "errors": [
        { "field": "amount", "message": "amount must be positive" }
    ],
    "alert": {
        "type": "error",
        "title": "Validation Error",
        "message": "Please check your input and try again"
    }
}
```

### Envelope Fields

| Field | Type | Source | Description |
|---|---|---|---|
| `sid` | `string` | Interceptor | Request ID (UUID), injected by SID middleware |
| `duration` | `string` | Interceptor | Processing time, injected by middleware |
| `status` | `int64` | Controller | `1` = success, `0` = error (integer, not boolean) |
| `code` | `string` | Controller | Response code (`{TIER}-{DOMAIN}-{SEVERITY}-{ACTION}-{SEQ}`) |
| `message` | `string` | Controller | Human-readable message |
| `data` | typed message | Transformer | Payload (nil on error) |
| `errors` | `repeated ErrorData` | Transformer | Field-level validation errors |
| `alert` | `AlertData` | Transformer | Localized user-facing alert from `alert.yaml` |

---

## 7. Marshaler Options

The `JSONPb` marshaler controls JSON serialization for all REST responses:

```go
runtime.WithMarshalerOption(runtime.MIMEWildcard, &runtime.JSONPb{
    MarshalOptions: protojson.MarshalOptions{
        UseProtoNames:   true,
        EmitUnpopulated: true,
    },
    UnmarshalOptions: protojson.UnmarshalOptions{
        DiscardUnknown: true,
    },
})
```

| Option | Value | Purpose |
|---|---|---|
| `UseProtoNames` | `true` | Preserves `snake_case` field names from proto. Without this, protojson defaults to `camelCase`. **Critical for API consistency.** |
| `EmitUnpopulated` | `true` | Includes zero-value fields (`""`, `0`, `false`, empty arrays) in response. Without this, clients receive sparse JSON with missing fields. |
| `DiscardUnknown` | `true` | Silently ignores unknown fields in request body. Prevents breaking clients when proto evolves. |
| `MIMEWildcard` | `*/*` | Applies to all content types, not just `application/json`. |

---

## 8. HTTP Middleware Chain

The middleware chain wraps the gorilla/mux router at the HTTP server level.

### Admin/Insider Chain

```
Request → CORS → Compress → Logging → [gorilla/mux Router]
                                          ├── /v1/*        → normalizeArrayQueryParams → grpc-gateway
                                          ├── /docs/*      → embed.FS file server
                                          ├── /metrics     → promhttp
                                          └── /grpc-metrics → proxy to gRPC metrics
```

```go
http.ListenAndServe(restPort,
    gorillaHandlers.CORS(originsOk, headersOk)(
        gorillaHandlers.CompressHandler(
            gorillaHandlers.LoggingHandler(os.Stdout, r),
        ),
    ),
)
```

### CORS Configuration

```go
originsOk := gorillaHandlers.AllowedOrigins([]string{"*"})
headersOk := gorillaHandlers.AllowedHeaders([]string{
    "Accept", "Authorization", "Content-Type", "Referer", "X-Client-ID",
})
```

### REST Auth Middleware

For endpoints that bypass gRPC gateway (direct REST handlers), use the REST auth middleware:

```go
// File: src/middleware/rest_auth_middleware.go
func RestApplicationAuthMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Same validation as gRPC auth interceptor:
        // 1. Extract X-Client-ID header
        // 2. Lookup Application by code
        // 3. Validate active + not suspended
        // 4. Validate IP host eligibility
        // 5. Validate Authorization (Bearer SHA256 or TOTP)
        // 6. Store application in request context via helpers.RestAppIdCtxKey
        ctx := context.WithValue(r.Context(), helpers.RestAppIdCtxKey, app)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}
```

### Gateway Metadata Forwarding

The REST gateway forwards HTTP headers as gRPC metadata so the gRPC interceptor chain works transparently:

```go
// File: src/middleware/grpc_gateway.go
// Forwarded headers: x-forwarded-for, user-agent, x-client-id, referer
// PHP-style array params normalized: ?param[]=val → ?param=val
```

**Note**: Public gateways may add extra headers and middleware depending on project-specific needs (e.g., tenant identification, tenant isolation). Add custom CORS headers and extraction middleware at the router level.

### Message Size Limits

```go
const (
    MaxMessageSize  = 50 * 1024 * 1024  // 50MB
    MaxRequestSize  = 50 * 1024 * 1024  // 50MB
    MaxResponseSize = 50 * 1024 * 1024  // 50MB
)
```

---

## 9. Proto HTTP Annotations

HTTP routes are defined in `.proto` files using `google.api.http` annotations. The gateway auto-generates REST endpoints from these.

```protobuf
import "google/api/annotations.proto";

service OrderService {
    rpc CreateOrder(CreateOrderReqRPC) returns (CreateOrderResRPC) {
        option (google.api.http) = {
            post: "/v1/orders"
            body: "*"
        };
    }

    rpc GetOrder(GetOrderReqRPC) returns (GetOrderResRPC) {
        option (google.api.http) = {
            get: "/v1/orders/{id}"
        };
    }

    rpc GetOrders(GetOrdersReqRPC) returns (GetOrdersResRPC) {
        option (google.api.http) = {
            get: "/v1/orders"
        };
    }

    rpc UpdateOrder(UpdateOrderReqRPC) returns (UpdateOrderResRPC) {
        option (google.api.http) = {
            patch: "/v1/orders/{id}"
            body: "*"
        };
    }

    rpc DeleteOrder(DeleteOrderReqRPC) returns (DeleteOrderResRPC) {
        option (google.api.http) = {
            delete: "/v1/orders/{id}"
        };
    }
}
```

### HTTP Method Mapping

| RPC Pattern | HTTP Method | Path Pattern | Body |
|---|---|---|---|
| `CreateXxx` | `POST` | `/v1/{resource}` | `body: "*"` |
| `GetXxx` | `GET` | `/v1/{resource}/{id}` | — |
| `GetXxxs` / `GetXxxPaginate` | `GET` | `/v1/{resource}` | — |
| `UpdateXxx` | `PATCH` | `/v1/{resource}/{id}` | `body: "*"` |
| `DeleteXxx` | `DELETE` | `/v1/{resource}/{id}` | — |
| `ProcessXxx` | `POST` | `/v1/{resource}/{id}/process` | `body: "*"` |

### Query Parameters

GET request query parameters map directly from proto fields:

```protobuf
message GetOrdersReqRPC {
    uint64 tenant_id = 1;
    string status = 2;
    int32 page = 3;
    int32 per_page = 4;
}
// → GET /v1/orders?tenant_id=1&status=completed&page=1&per_page=10
```

### Path Parameters

Fields referenced in the path template are extracted automatically:

```protobuf
// {id} maps to the `id` field in the request message
rpc GetOrder(GetOrderReqRPC) returns (GetOrderResRPC) {
    option (google.api.http) = {
        get: "/v1/orders/{id}"
    };
}

message GetOrderReqRPC {
    uint64 id = 1;
}
```

---

## 10. Query Parameter Normalization

Middleware that converts PHP-style array notation to gRPC-gateway compatible format. Applied at the gateway subrouter level via `AttachToRouter`.

```go
func normalizeArrayQueryParams(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        queryParams := r.URL.Query()
        normalized := url.Values{}

        for key, values := range queryParams {
            if strings.HasSuffix(key, "[]") {
                // Remove [] suffix: "ids[]" → "ids"
                normalizedKey := strings.TrimSuffix(key, "[]")
                for _, value := range values {
                    if value != "" {
                        normalized.Add(normalizedKey, value)
                    }
                }
            } else {
                for _, value := range values {
                    normalized.Add(key, value)
                }
            }
        }

        r.URL.RawQuery = normalized.Encode()
        next.ServeHTTP(w, r)
    })
}
```

**Before**: `?ids[]=1&ids[]=2&ids[]=3`
**After**: `?ids=1&ids=2&ids=3`

---

## 11. Swagger & Metrics Endpoints

### Swagger/OpenAPI Documentation

All three gateways serve embedded OpenAPI documentation:

```go
//go:embed openapi/* index.html
var content embed.FS

// Register in router
subFS, _ := fs.Sub(content, ".")
r.PathPrefix("/docs/").Handler(http.StripPrefix("/docs/", http.FileServer(http.FS(subFS))))

// Index page redirect
r.HandleFunc("/docs/", func(w http.ResponseWriter, r *http.Request) {
    data, _ := content.ReadFile("index.html")
    w.Header().Set("Content-Type", "text/html")
    w.Write(data)
})
```

**Access**: `http://host:port/docs/`

### Prometheus Metrics

REST gateway exposes its own metrics:

```go
r.Handle("/metrics", promhttp.Handler())
```

### gRPC Metrics Proxy

Proxies metrics from the gRPC server's Prometheus endpoint. The gRPC metrics port is formed by prefixing `1` to the gRPC port (e.g., port `8080` → `18080`):

```go
r.HandleFunc("/grpc-metrics", func(w http.ResponseWriter, r *http.Request) {
    grpcMetricsPort := fmt.Sprintf("1%s", viper.GetString(constant.GRPC_PORT))
    grpcMetricsURL := fmt.Sprintf("http://localhost:%s/metrics", grpcMetricsPort)

    client := &http.Client{}
    req, _ := http.NewRequest("GET", grpcMetricsURL, nil)
    req.Header = r.Header
    resp, err := client.Do(req)
    if err != nil {
        http.Error(w, "gRPC metrics unavailable", http.StatusBadGateway)
        return
    }
    defer resp.Body.Close()

    for key, values := range resp.Header {
        for _, value := range values {
            w.Header().Add(key, value)
        }
    }
    w.WriteHeader(resp.StatusCode)
    io.Copy(w, resp.Body)
})
```

---

## 12. Health & Connection Check

REST gateways expose **two** dedicated health endpoints registered directly on the gorilla/mux router — **not** through grpc-gateway. This separates the REST process health from the gRPC backend connectivity.

### `/health` — REST Liveness

Confirms the REST gateway HTTP server itself is alive. No external dependencies checked — if this responds, the HTTP process is running:

```go
r.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]interface{}{
        "status":    "ok",
        "service":   "{service}-admin-rest",  // or -insider-rest, -public-rest
        "timestamp": time.Now().UTC().Format(time.RFC3339),
    })
})
```

**Response**:
```json
{
  "status": "ok",
  "service": "{service}-admin-rest",
  "timestamp": "2026-04-10T12:00:00Z"
}
```

### `/connection` — gRPC Backend Connectivity

Verifies the REST gateway can reach its upstream gRPC server. This is a **readiness check** — if gRPC is down, the REST gateway is alive but unable to serve business requests:

```go
r.HandleFunc("/connection", func(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")

    grpcPort := viper.GetString(constant.GRPC_PORT)
    grpcTarget := fmt.Sprintf("localhost:%s", grpcPort)

    ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
    defer cancel()

    conn, err := grpc.DialContext(ctx, grpcTarget, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithBlock())
    if err != nil {
        w.WriteHeader(http.StatusBadGateway)
        json.NewEncoder(w).Encode(map[string]interface{}{
            "status":    "error",
            "service":   "{service}-admin-rest",
            "grpc":      grpcTarget,
            "error":     err.Error(),
            "timestamp": time.Now().UTC().Format(time.RFC3339),
        })
        return
    }
    defer conn.Close()

    // Call the gRPC Health endpoint
    healthClient := adminv1.NewHealthClient(conn)
    resp, err := healthClient.Check(ctx, &emptypb.Empty{})
    if err != nil {
        w.WriteHeader(http.StatusBadGateway)
        json.NewEncoder(w).Encode(map[string]interface{}{
            "status":    "error",
            "service":   "{service}-admin-rest",
            "grpc":      grpcTarget,
            "error":     err.Error(),
            "timestamp": time.Now().UTC().Format(time.RFC3339),
        })
        return
    }

    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]interface{}{
        "status":    "ok",
        "service":   "{service}-admin-rest",
        "grpc":      resp.GetService(),
        "timestamp": time.Now().UTC().Format(time.RFC3339),
    })
})
```

**Response (success)**:
```json
{
  "status": "ok",
  "service": "{service}-admin-rest",
  "grpc": "{service}-admin",
  "timestamp": "2026-04-10T12:00:00Z"
}
```

**Response (gRPC down)**:
```json
{
  "status": "error",
  "service": "{service}-admin-rest",
  "grpc": "localhost:8080",
  "error": "context deadline exceeded",
  "timestamp": "2026-04-10T12:00:00Z"
}
```

### Use Cases

| Endpoint | What It Checks | HTTP Status | Used By |
|----------|---------------|-------------|---------|
| `GET /health` | REST HTTP process alive | `200` always if process runs | Load balancer liveness probe |
| `GET /connection` | REST → gRPC connectivity | `200` if gRPC reachable, `502` if not | K8s readiness probe, monitoring |
| `GET /v1/health` | gRPC Health via gateway (existing) | `200` always | End-to-end check through full gateway stack |

### Registration Order

These endpoints go right after the gRPC gateway is attached and before middleware wrapping:

```go
// 1. Attach gRPC gateway
gw.AttachToRouter(r, "/v1")

// 2. Health & connection (direct handlers)
r.HandleFunc("/health", healthHandler)
r.HandleFunc("/connection", connectionHandler)

// 3. Operational endpoints
r.Handle("/metrics", promhttp.Handler())
r.HandleFunc("/grpc-metrics", grpcMetricsHandler)
r.PathPrefix("/docs/").Handler(docsHandler)

// 4. Wrap with middleware
handler := handlers.CORS(...)(r)
handler = handlers.CompressHandler(handler)
handler = handlers.LoggingHandler(os.Stdout, handler)
```

### Key Points

1. **`/health` has zero dependencies** — no DB, no Redis, no gRPC. Pure liveness.
2. **`/connection` has a 3-second timeout** — prevents probe hangs when gRPC is unresponsive.
3. **Both bypass all middleware** — registered before CORS/Compress wrapping doesn't matter since they respond raw JSON, but ensure they're accessible even if middleware has issues.
4. **`/v1/health` still exists** — the gRPC Health endpoint via grpc-gateway works as before. These two new endpoints complement it, not replace it.
5. **Service name convention** — append `-rest` to distinguish from gRPC tier names (e.g., `{service}-admin-rest` vs `{service}-admin`).

---

## 13. Key Rules

1. **Never implement REST handlers manually** — always use grpc-gateway auto-generation from proto annotations.
2. **One REST gateway per gRPC tier** — admin, insider, and public each have their own gateway server.
3. **All HTTP routing goes in `.proto` files** via `google.api.http` annotations, not Go code.
4. **Gateway connects to gRPC server locally** — same machine, insecure credentials, different ports.
5. **Path prefix is `/v1`** — all gateway routes are mounted under `/v1/*` via `AttachToRouter`.
6. **CORS and HTTP middleware** are added at the gateway HTTP server level (gorilla/handlers), not in gRPC.
7. **Public gateway may add extra middleware** — project-specific headers and extraction middleware at the router level.
8. **Proto regeneration required** — after modifying proto files, run `make protogen`.
9. **UseProtoNames must be true** — ensures snake_case JSON keys match proto field names.
10. **EmitUnpopulated must be true** — ensures clients always receive all fields.

---

## 14. Anti-Patterns

| Anti-pattern | Why it breaks | Fix |
|---|---|---|
| Writing REST route handlers manually in Go | Bypasses grpc-gateway; routes diverge from proto definitions; no auto-generated OpenAPI | Define HTTP bindings in `.proto` via `google.api.http`; use `make protogen` |
| One shared gateway for all tiers | Admin and public clients get each other's routes; impossible to apply per-tier middleware | One `GRPCGatewayServer` per tier — admin, insider, public each separate |
| Mounting routes without the `/v1` prefix | Client URLs break when adding versioning; existing integrations need migration | `AttachToRouter` always registers under `/v1/*` |
| `UseProtoNames: false` | JSON keys become camelCase (Go default), not snake_case (proto default); clients break on field name mismatch | Always set `UseProtoNames: true` in the marshaler |
| `EmitUnpopulated: false` | Clients receive no key for zero-value fields; must null-check every field | Always set `EmitUnpopulated: true` |
| Connecting gateway to gRPC server with TLS locally | Same-machine connection adds TLS overhead with no security benefit (no network hop) | Use `grpc.WithTransportCredentials(insecure.NewCredentials())` for local connections |
| Applying CORS in the gRPC interceptor chain | gRPC interceptors run after the HTTP layer; OPTIONS preflight never reaches gRPC | Add CORS via `handlers.CORS(...)` on the `gorilla/mux` router before gateway registration |
| Adding business logic in REST middleware | Business rules bypass service validation and panic recovery | Keep REST middleware to header extraction and metadata forwarding only |
| Skipping `make protogen` after proto annotation change | Stale `*.pb.gw.go` — new HTTP bindings not registered | Always run `make protogen` after any `.proto` edit |

---

## Related References

- **gRPC Patterns** (`grpc-patterns.md`) — Controller, transformer, interceptor patterns
- **Proto Workflow** (`proto-workflow.md`) — Authoritative `make protogen` flow, buf lint/breaking
- **Context Patterns** (`context-patterns.md §7`) — REST → gRPC header forwarding and metadata strategy
- **Alert System** (`grpc-patterns.md#6`) — Alert resolution and `Accept-Language` usage
