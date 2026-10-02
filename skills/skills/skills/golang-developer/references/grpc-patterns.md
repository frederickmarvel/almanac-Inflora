# gRPC Patterns for Three-Tier API System

A comprehensive reference for implementing gRPC APIs across Admin, Insider, and Public tiers in Go microservices.

## Table of Contents

1. [Three-Tier API Architecture](#1-three-tier-api-architecture)
2. [Controller Pattern](#2-controller-pattern)
3. [Transformer Pattern](#3-transformer-pattern)
4. [Response Envelope](#4-response-envelope)
5. [DTO Pattern](#5-dto-pattern)
6. [Alert System](#6-alert-system)
7. [Response Code Format](#7-response-code-format)
8. [Proto Management with buf](#8-proto-management-with-buf)
9. [Wire DI for Controllers](#9-wire-di-for-controllers)
10. [Interceptor Chain](#10-interceptor-chain)
11. [Health Check Endpoint](#11-health-check-endpoint)
12. [Anti-Patterns](#12-anti-patterns)

---

## 1. Three-Tier API Architecture

The system provides three separate gRPC servers, each running on its own port with isolated configurations and capabilities.

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Client Requests                          │
└─────────────────────────────────────────────────────────────┘
                  │               │               │
        ┌─────────┘               │               └─────────┐
        │                         │                         │
        ▼                         ▼                         ▼
    [Admin API]             [Insider API]            [Public API]
    Port: GRPC_PORT         Port: GRPC_INSIDER_PORT  Port: GRPC_PUBLIC_PORT
    Full Access             Tenant Access            Read-Heavy
        │                         │                         │
        ├─────────────────────────┼─────────────────────────┤
        │
        ▼
┌─────────────────────────┐
│   Shared Services       │
│   Repositories          │
│   Database              │
└─────────────────────────┘
```

### Tier Responsibilities

#### Admin (`engine/grpc/`)
- **Access Level**: Full administrative access
- **Use Cases**: Internal operations, system management, resource onboarding
- **Controllers**: All entity controllers
- **Proto Package**: `proto/{project}/admin/v1/`
- **Operations**: Full CRUD, process, reconcile
- **Background**: Background pool listeners, async workers

#### Insider (`engine/grpc-insider/`)
- **Access Level**: Internal tenant access
- **Use Cases**: Tenant portal, order management, approval callbacks
- **Controllers**: Subset of admin controllers + tier-specific services
- **Proto Package**: `proto/{project}/insider/v1/`
- **Operations**: Read, create orders, view transactions, approval callbacks
- **Extra Middleware**: Request/response logging for callback endpoints

#### Public (`engine/grpc-public/`)
- **Access Level**: Public-facing API
- **Use Cases**: Investor portal, fund information, portfolio queries
- **Controllers**: Minimal read-only subset
- **Proto Package**: `proto/{project}/public/v1/`
- **Operations**: Read-heavy, strict validation
- **Extra Middleware**: Additional interceptors may be added per project (e.g., tenant extraction)

### Isolation Pattern

Each tier has its own server, middleware chain, and controller set. Controllers are injected per tier with different implementations/subsets. For example:
- Admin `OrderController` → Full CRUD + Process + Cancel
- Insider `OrderController` → Create, Gets, Get (no delete, no process)
- Public `OrderController` → Get, Gets only (read-only)

---

## 2. Controller Pattern

Controllers are the interface adapters that handle gRPC requests. They bridge the proto layer and the service layer.

### File Structure

Controllers use a **single-file pattern** — only `*_impl.go` files exist. The proto-generated `UnimplementedXxxServer` already serves as the interface contract:

```
engine/grpc/controller/
├── order_controller_impl.go
├── transaction_controller_impl.go
├── investor_controller_impl.go
├── nav_controller_impl.go
└── ...
```

Each tier has its own controller directory:
- `engine/grpc/controller/` — Admin
- `engine/grpc-insider/controller/` — Insider
- `engine/grpc-public/controller/` — Public

### Implementation Structure

```go
// File: engine/grpc/controller/order_controller_impl.go
package controller

import (
    "context"

    adminv2 "yourmodule/proto/admin/v1"
    "yourmodule/engine/grpc/transformer"
    "yourmodule/src/service"
    "yourmodule/src/utils"
)

type OrderControllerImpl struct {
    adminv2.UnimplementedOrderServer         // Proto-generated interface
    Service     service.OrderService         // Domain service
    Validator   *utils.CustomValidator       // Shared validator (NOT per-entity)
    Transformer transformer.OrderTransformer // Response transformer
}

// Constructor returns proto server interface, NOT a controller interface
func NewOrderController(
    svc service.OrderService,
    val *utils.CustomValidator,
    trans transformer.OrderTransformer,
) adminv2.OrderServer {
    return &OrderControllerImpl{
        Service:     svc,
        Validator:   val,
        Transformer: trans,
    }
}
```

**Key conventions:**
- Embeds `UnimplementedXxxServer` from proto-generated code
- `Validator` is always `*utils.CustomValidator` (shared across all controllers)
- Constructor returns **proto server interface** type (e.g., `adminv2.OrderServer`)
- Can have multiple services if needed (e.g., `TransactionControllerImpl` has `Service` + `FeesTaxesChargesBonusesService`)

### Request Flow (7-Step Pattern)

Every RPC method follows this exact sequence. Controllers use **value receiver**:

```go
func (c OrderControllerImpl) Get(
    ctx context.Context,
    req *adminv2.GetOrderReqRPC,
) (*adminv2.GetOrderResRPC, error) {
    locale := helpers.GetLocaleFromContext(ctx)

    // STEP 1: VALIDATE REQUEST STRUCTURE
    err := c.Validator.Validate.Struct(req)
    if err != nil {
        errF, _ := utils.ConvertErrMsg[adminv2.ErrorData](c.Validator.GetErrMsgField(err))
        res := &transformer.ResponseWrapper{
            Status:  0,
            Code:    "G-SYS-E-GEN-002",
            Message: "invalid parameter",
            Locale:  locale,
        }
        return c.Transformer.TransformWrapperGetOrder(res, nil, errF), nil
    }

    // STEP 2: BUILD SERVICE PARAMETERS (conditional assignment for optional fields)
    params := service.GetOrderParams{}
    if req.Id != 0 {
        params.ID = utils.VarToPointer(int64(req.Id))
    }
    if req.TenantId != 0 {
        params.TenantID = utils.VarToPointer(req.TenantId)
    }
    if req.Code != "" {
        params.Code = utils.VarToPointer(req.Code)
    }

    // STEP 3: CALL SERVICE (triple return)
    order, err, paramErrors := c.Service.Get(ctx, params)

    // STEP 4: HANDLE PARAM ERRORS (validation from service)
    if paramErrors != nil && len(paramErrors) > 0 {
        errF := transformer.TransformErrors(paramErrors)
        res := &transformer.ResponseWrapper{
            Status:  0,
            Code:    "G-SYS-E-GEN-002",
            Message: "invalid parameter",
            Locale:  locale,
        }
        return c.Transformer.TransformWrapperGetOrder(res, nil, errF), nil
    }

    // STEP 5: HANDLE SERVICE ERROR
    if err != nil {
        res := &transformer.ResponseWrapper{
            Status:  0,
            Code:    "A-ORD-E-GET-001",
            Message: err.Error(),
            Locale:  locale,
        }
        return c.Transformer.TransformWrapperGetOrder(res, nil), nil
    }

    // STEP 6: HANDLE NOT FOUND
    if order == nil {
        res := &transformer.ResponseWrapper{
            Status:  0,
            Code:    "G-SYS-E-GEN-003",
            Message: "data not found",
            Locale:  locale,
        }
        return c.Transformer.TransformWrapperGetOrder(res, nil), nil
    }

    // STEP 7: SUCCESS RESPONSE
    res := &transformer.ResponseWrapper{
        Status:  1,
        Code:    "A-ORD-S-GET-001",
        Message: "success",
        Locale:  locale,
    }
    return c.Transformer.TransformWrapperGetOrder(res, c.Transformer.ToProto(c.Transformer.ToDTO(order))), nil
}
```

### Create Method Example

```go
func (c OrderControllerImpl) Create(
    ctx context.Context,
    req *adminv2.CreateOrderReqRPC,
) (*adminv2.CreateOrderResRPC, error) {
    locale := helpers.GetLocaleFromContext(ctx)

    // Step 1: Validate
    err := c.Validator.Validate.Struct(req)
    if err != nil {
        errF, _ := utils.ConvertErrMsg[adminv2.ErrorData](c.Validator.GetErrMsgField(err))
        res := &transformer.ResponseWrapper{
            Status:  0,
            Code:    "G-SYS-E-GEN-002",
            Message: "invalid parameter",
            Locale:  locale,
        }
        return c.Transformer.TransformWrapperCreateOrder(res, nil, errF), nil
    }

    // Step 2: Build params (with pointer conversion for optional fields)
    params := service.CreateOrderParams{
        TenantID: req.TenantId,
        Type:      req.Type,
    }
    if req.InvestorId != 0 {
        params.InvestorID = utils.VarToPointer(int64(req.InvestorId))
    }
    if req.ExternalId != "" {
        params.ExternalId = utils.VarToPointer(req.ExternalId)
    }
    if req.Amount != "" {
        amt, _ := decimal.NewFromString(req.Amount)
        params.Amount = &amt
    }
    // Boolean conversion: proto int32/bool → Go int via pointer
    if req.IsActive != nil {
        params.IsActive = utils.VarToPointer(int(*req.IsActive))
    }

    // Steps 3-7: Call service, handle triple return, transform response
    order, err, paramErrors := c.Service.Create(ctx, params)

    if paramErrors != nil && len(paramErrors) > 0 {
        errF := transformer.TransformErrors(paramErrors)
        res := &transformer.ResponseWrapper{Status: 0, Code: "G-SYS-E-GEN-002", Message: "invalid parameter", Locale: locale}
        return c.Transformer.TransformWrapperCreateOrder(res, nil, errF), nil
    }

    if err != nil {
        res := &transformer.ResponseWrapper{Status: 0, Code: "A-ORD-E-CRT-001", Message: err.Error(), Locale: locale}
        return c.Transformer.TransformWrapperCreateOrder(res, nil), nil
    }

    res := &transformer.ResponseWrapper{
        Status:  1,
        Code:    "A-ORD-S-CRT-001",
        Message: "order created successfully",
        Locale:  locale,
    }
    return c.Transformer.TransformWrapperCreateOrder(res, c.Transformer.ToProto(c.Transformer.ToDTO(order))), nil
}
```

### Error Code Reference

Codes follow the format `{TIER}-{DOMAIN}-{SEVERITY}-{ACTION}-{SEQ}` — see [Section 7: Response Code Format](#7-response-code-format).

| Code | Status | Meaning |
|------|--------|---------|
| `G-SYS-S-GEN-001` | 1 | Generic success |
| `G-SYS-E-GEN-002` | 0 | Validation error (struct or param) |
| `G-SYS-E-GEN-003` | 0 | Not found |
| `G-SYS-E-GEN-001` | 0 | Unknown/unexpected error |
| `A-ORD-S-CRT-001` | 1 | Order created (domain-specific success) |
| `A-ORD-E-CRT-001` | 0 | Order creation failed (domain-specific error) |

**Status field**: `1` = success, `0` = error. Integer, not boolean.

---

## 3. Transformer Pattern

Transformers convert between domain entities and protobuf messages. Each entity has a separate interface + impl file pair.

### File Structure

```
engine/grpc/transformer/
├── transformer.go                    # Shared: ResponseWrapper + TransformErrors
├── order_transformer.go              # Interface
├── order_transformer_impl.go         # Implementation
├── investor_transformer.go           # Interface
├── investor_transformer_impl.go      # Implementation
└── ...
```

### Shared Types (transformer.go)

```go
// File: engine/grpc/transformer/transformer.go

// ResponseWrapper is an intermediate struct used in controllers.
// Contains ONLY status/code/message. SID and duration are injected by interceptor.
type ResponseWrapper struct {
    Status  int    `json:"status"`
    Code    string `json:"code"`
    Message string `json:"message"`
}

// TransformErrors bridges service.ParamError → proto ErrorData
func TransformErrors(errors []service.ParamError) []*adminv2.ErrorData {
    var errorList []*adminv2.ErrorData
    for _, err := range errors {
        errorList = append(errorList, &adminv2.ErrorData{
            Field:   err.Field,
            Message: err.Message,
        })
    }
    return errorList
}
```

### Transformer Interface

Each transformer defines TWO categories of methods:

```go
// File: engine/grpc/transformer/order_transformer.go

type OrderTransformer interface {
    // === DATA TRANSFORMERS (entity → proto message) ===
    TransformOrder(data *entity.Order) *adminv2.OrderData
    TransformOrders(data []*entity.Order) []*adminv2.OrderData
    TransformOrderPaginate(p paginator.Pagination) *adminv2.OrderPaginatedData

    // === WRAPPER TRANSFORMERS (ResponseWrapper + data → full RPC response) ===
    // Each RPC method gets its own wrapper transformer
    // Errors are variadic: ...[]*adminv2.ErrorData
    TransformWrapperGetOrder(res *ResponseWrapper, data *adminv2.OrderData, errors ...[]*adminv2.ErrorData) *adminv2.GetOrderResRPC
    TransformWrapperGetOrders(res *ResponseWrapper, data []*adminv2.OrderData, errors ...[]*adminv2.ErrorData) *adminv2.GetOrdersResRPC
    TransformWrapperCreateOrder(res *ResponseWrapper, data *adminv2.OrderData, errors ...[]*adminv2.ErrorData) *adminv2.CreateOrderResRPC
    // ... one wrapper per RPC method (Update, Delete, Process, etc.)
}
```

### Transformer Implementation

```go
// File: engine/grpc/transformer/order_transformer_impl.go

type OrderTransformerImpl struct{}

func NewOrderTransformer() OrderTransformer {
    return &OrderTransformerImpl{}
}

// Data transformer: entity → proto
func (t OrderTransformerImpl) TransformOrder(data *entity.Order) *adminv2.OrderData {
    if data != nil {
        return &adminv2.OrderData{
            Id:        uint64(data.ID),
            TenantId: data.TenantID,
            Code:      data.Code,
            Amount:    data.Amount.StringFixed(8),    // decimal.Decimal → string
            Status:    data.Status,
            CreatedAt: data.CreatedAt.Format(time.RFC3339),
            UpdatedAt: helpers.RFC3339(data.UpdatedAt),
        }
    }
    return nil
}

// Multiple entities transformer
func (t OrderTransformerImpl) TransformOrders(data []*entity.Order) []*adminv2.OrderData {
    if data == nil || len(data) == 0 {
        return []*adminv2.OrderData{}
    }
    transformed := make([]*adminv2.OrderData, 0, len(data))
    for _, d := range data {
        transformed = append(transformed, t.TransformOrder(d))
    }
    return transformed
}

// Wrapper transformer: ResponseWrapper + data → full RPC response
func (t OrderTransformerImpl) TransformWrapperGetOrder(
    res *ResponseWrapper,
    data *adminv2.OrderData,
    errors ...[]*adminv2.ErrorData,
) *adminv2.GetOrderResRPC {
    r := &adminv2.GetOrderResRPC{
        Status:  int64(res.Status),
        Code:    res.Code,
        Message: res.Message,
        Data:    data,
    }
    if len(errors) > 0 {
        r.Errors = errors[0]
    }
    return r
}
```

### Type Conversion Rules

| Entity Type | Proto Type | Conversion |
|---|---|---|
| `decimal.Decimal` | `string` | `amount.StringFixed(8)` — fixed 8 decimal precision |
| `time.Time` | `string` | `t.Format(time.RFC3339)` |
| `*time.Time` | `string` | `helpers.RFC3339Ptr(t)` — returns `""` for nil |
| `int` (boolean) | `int32` | `int32(data.IsActive)` |
| `types.EncryptedAES` | `string` | Direct `string()` cast |
| `uint` (entity ID) | `uint64` | `uint64(data.ID)` |

---

## 4. Response Envelope

All gRPC responses use a standardized envelope. The proto response types are generated per-RPC method.

### Proto Base Messages

```protobuf
// File: proto/nav/admin/v1/base.proto
syntax = "proto3";
package nav.admin.v1;

// ErrorData for field-level validation errors
message ErrorData {
    string field = 1;
    string message = 2;
}

// GenericResponse for generic RPC responses
message GenericResponse {
    string sid = 1;
    string duration = 2;
    int64 status = 3;
    string code = 4;
    string message = 5;
    google.protobuf.Any data = 6;
    google.protobuf.Any errors = 7;
}
```

### Per-RPC Response Messages

```protobuf
// Each RPC gets its own typed response
message GetOrderResRPC {
    string sid = 1;
    string duration = 2;
    int64 status = 3;
    string code = 4;
    string message = 5;
    OrderData data = 6;
    repeated ErrorData errors = 7;
}

message GetOrdersResRPC {
    string sid = 1;
    string duration = 2;
    int64 status = 3;
    string code = 4;
    string message = 5;
    repeated OrderData data = 6;
    repeated ErrorData errors = 7;
}
```

### Envelope Fields

| Field | Type | Source | Description |
|---|---|---|---|
| `sid` | `string` | Interceptor | Session/Request ID (UUID), injected by SID middleware |
| `duration` | `string` | Interceptor | Processing time, injected by middleware |
| `status` | `int64` | Controller | `1` = success, `0` = error |
| `code` | `string` | Controller | Application error code |
| `message` | `string` | Controller | Human-readable message |
| `data` | typed message | Transformer | Payload (nil on error) |
| `errors` | `repeated ErrorData` | Transformer | Field-level validation errors |

**Key**: `sid` and `duration` are NOT set by controllers. They are injected by the interceptor chain. Controllers only set `status`, `code`, `message` via ResponseWrapper, and `data`/`errors` via transformer.

---

## 5. DTO Pattern

DTOs (Data Transfer Objects) decouple the user-facing data structure from proto-generated types. They sit at the `engine/grpc/dto/` layer.

### Purpose

```
Entity (domain) → DTO (presentation) → Proto (wire format)
```

- **Entity**: Business domain model with GORM tags, traits, Sign interface
- **DTO**: Presentation-layer struct — clean field names, computed fields, formatted values
- **Proto**: Wire format — field numbers, protobuf types, auto-generated code

Without DTOs, transformers do too much: field mapping, formatting, computed values, and proto construction all in one step. DTOs let you separate *what to show* from *how to serialize*.

### File Structure

```
engine/grpc/dto/
├── order_dto.go
├── investor_dto.go
├── transaction_dto.go
├── nav_dto.go
└── ...
```

### DTO Definition

```go
// File: engine/grpc/dto/order_dto.go
package dto

type OrderDTO struct {
    ID            uint64  `json:"id"`
    TenantID     uint64  `json:"tenant_id"`
    InvestorID    int64   `json:"investor_id"`
    Code          string  `json:"code"`
    Type          string  `json:"type"`
    Status        string  `json:"status"`
    Amount        string  `json:"amount"`         // decimal → string (8 precision)
    Fee           string  `json:"fee"`
    Tax           string  `json:"tax"`
    NetAmount     string  `json:"net_amount"`      // computed field
    InvestorName  string  `json:"investor_name"`   // flattened from relation
    FundName      string  `json:"fund_name"`       // flattened from relation
    CreatedAt     string  `json:"created_at"`      // RFC3339 formatted
    UpdatedAt     string  `json:"updated_at"`
    ProcessedAt   string  `json:"processed_at"`    // nullable → empty string
}

type OrderPaginateDTO struct {
    Items      []*OrderDTO `json:"items"`
    Page       int64       `json:"page"`
    PerPage    int64       `json:"per_page"`
    TotalItems int64       `json:"total_items"`
    TotalPages int64       `json:"total_pages"`
}
```

### Updated Transformer Flow

With DTOs, transformers split into two stages:

```go
// File: engine/grpc/transformer/order_transformer.go

type OrderTransformer interface {
    // Stage 1: Entity → DTO (formatting, computed fields)
    ToDTO(data *entity.Order) *dto.OrderDTO
    ToDTOs(data []*entity.Order) []*dto.OrderDTO
    ToPaginateDTO(data []*entity.Order, p paginator.Pagination) *dto.OrderPaginateDTO

    // Stage 2: DTO → Proto (field mapping only)
    ToProto(data *dto.OrderDTO) *adminv2.OrderData
    ToProtos(data []*dto.OrderDTO) []*adminv2.OrderData

    // Wrapper: ResponseWrapper + proto → full RPC response
    TransformWrapperGetOrder(res *ResponseWrapper, data *adminv2.OrderData, errors ...[]*adminv2.ErrorData) *adminv2.GetOrderResRPC
    // ... other wrappers
}
```

```go
// File: engine/grpc/transformer/order_transformer_impl.go

// Stage 1: Entity → DTO
func (t OrderTransformerImpl) ToDTO(data *entity.Order) *dto.OrderDTO {
    if data == nil {
        return nil
    }
    return &dto.OrderDTO{
        ID:           uint64(data.ID),
        TenantID:    data.TenantID,
        InvestorID:   data.InvestorID,
        Code:         data.Code,
        Type:         data.Type,
        Status:       data.Status,
        Amount:       data.Amount.StringFixed(8),
        Fee:          data.Fee.StringFixed(8),
        Tax:          data.Tax.StringFixed(8),
        NetAmount:    data.Amount.Add(data.Fee).Add(data.Tax).StringFixed(8),  // computed
        InvestorName: string(data.Investor.Firstname) + " " + string(data.Investor.Lastname),
        FundName:     data.Fund.Name,
        CreatedAt:    data.CreatedAt.Format(time.RFC3339),
        UpdatedAt:    helpers.RFC3339(data.UpdatedAt),
        ProcessedAt:  helpers.RFC3339Ptr(data.ProcessedAt),
    }
}

// Stage 2: DTO → Proto (simple mapping, no logic)
func (t OrderTransformerImpl) ToProto(data *dto.OrderDTO) *adminv2.OrderData {
    if data == nil {
        return nil
    }
    return &adminv2.OrderData{
        Id:           data.ID,
        TenantId:    data.TenantID,
        InvestorId:   data.InvestorID,
        Code:         data.Code,
        Type:         data.Type,
        Status:       data.Status,
        Amount:       data.Amount,
        Fee:          data.Fee,
        Tax:          data.Tax,
        NetAmount:    data.NetAmount,
        InvestorName: data.InvestorName,
        FundName:     data.FundName,
        CreatedAt:    data.CreatedAt,
        UpdatedAt:    data.UpdatedAt,
        ProcessedAt:  data.ProcessedAt,
    }
}
```

### Controller Usage (Updated)

```go
// Before DTO: controller calls transformer directly
return c.Transformer.TransformWrapperGetOrder(res, c.Transformer.TransformOrder(order)), nil

// After DTO: controller chains ToDTO → ToProto
orderDTO := c.Transformer.ToDTO(order)
return c.Transformer.TransformWrapperGetOrder(res, c.Transformer.ToProto(orderDTO)), nil
```

### When to Use DTOs

- **New entities**: Always create a DTO
- **Existing entities**: Migrate to DTOs when modifying the transformer
- **Simple entities** (< 5 fields, no computed values): DTO is optional, direct Entity → Proto is acceptable

---

## 6. Alert System

Alerts provide user-facing feedback messages separate from the system error code. Each response code maps to a localized alert via `alert.yaml`.

### Proto Definition

```protobuf
// Added to base.proto in each tier
message AlertData {
    string type = 1;      // success, error, warning, info
    string title = 2;
    string message = 3;
}

// Added as field 8 in every RPC response
message GetOrderResRPC {
    string sid = 1;
    string duration = 2;
    int64 status = 3;
    string code = 4;
    string message = 5;
    OrderData data = 6;
    repeated ErrorData errors = 7;
    AlertData alert = 8;            // NEW
}
```

### alert.yaml Format

File starts directly from codes — no wrapper key:

```yaml
# File: config/alert.yaml

G-SYS-S-GEN-001:
  en:
    type: success
    title: Success
    message: Operation completed successfully
  id:
    type: success
    title: Berhasil
    message: Operasi berhasil dilakukan

G-SYS-E-GEN-001:
  en:
    type: error
    title: Error
    message: An unexpected error occurred
  id:
    type: error
    title: Kesalahan
    message: Terjadi kesalahan yang tidak terduga

G-SYS-E-GEN-002:
  en:
    type: error
    title: Validation Error
    message: Please check your input and try again
  id:
    type: error
    title: Kesalahan Validasi
    message: Silakan periksa input Anda dan coba lagi

G-SYS-E-GEN-003:
  en:
    type: error
    title: Not Found
    message: The requested data was not found
  id:
    type: error
    title: Tidak Ditemukan
    message: Data yang diminta tidak ditemukan

G-SYS-W-GEN-001:
  en:
    type: warning
    title: Warning
    message: Operation completed with warnings
  id:
    type: warning
    title: Peringatan
    message: Operasi selesai dengan peringatan

G-SYS-I-GEN-001:
  en:
    type: info
    title: Information
    message: No changes were made
  id:
    type: info
    title: Informasi
    message: Tidak ada perubahan yang dilakukan

A-ORD-S-CRT-001:
  en:
    type: success
    title: Order Created
    message: Your order has been submitted successfully
  id:
    type: success
    title: Order Dibuat
    message: Order Anda berhasil dikirim

A-ORD-E-CRT-001:
  en:
    type: error
    title: Order Failed
    message: Failed to create order. Please try again
  id:
    type: error
    title: Order Gagal
    message: Gagal membuat order. Silakan coba lagi
```

### Go Implementation

```go
// File: src/alert/alert.go
package alert

import (
    "os"
    "gopkg.in/yaml.v3"
)

type Alert struct {
    Type    string `yaml:"type"`
    Title   string `yaml:"title"`
    Message string `yaml:"message"`
}

// Top-level map: code → locale → Alert
type AlertMap map[string]map[string]Alert

var alerts AlertMap

func Init(path string) error {
    data, err := os.ReadFile(path)
    if err != nil {
        return err
    }
    return yaml.Unmarshal(data, &alerts)
}

func Get(code, locale string) *Alert {
    locales, ok := alerts[code]
    if !ok {
        return nil
    }
    a, ok := locales[locale]
    if !ok {
        // Fallback to English
        a, ok = locales["en"]
        if !ok {
            return nil
        }
    }
    return &a
}
```

### Locale Extraction

Locale is extracted from the `Accept-Language` gRPC metadata header:

```go
// In interceptor or helper
func GetLocaleFromContext(ctx context.Context) string {
    md, ok := metadata.FromIncomingContext(ctx)
    if !ok {
        return "en"
    }
    langs := md.Get("accept-language")
    if len(langs) == 0 || langs[0] == "" {
        return "en"
    }
    // Parse first language tag (e.g., "id-ID" → "id", "en-US" → "en")
    tag := strings.Split(langs[0], "-")[0]
    tag = strings.Split(tag, ",")[0]
    return strings.ToLower(strings.TrimSpace(tag))
}
```

### Controller Integration

Alert is resolved in the wrapper transformer, NOT in the controller:

```go
// File: engine/grpc/transformer/order_transformer_impl.go

func (t OrderTransformerImpl) TransformWrapperGetOrder(
    res *ResponseWrapper,
    data *adminv2.OrderData,
    errors ...[]*adminv2.ErrorData,
) *adminv2.GetOrderResRPC {
    r := &adminv2.GetOrderResRPC{
        Status:  int64(res.Status),
        Code:    res.Code,
        Message: res.Message,
        Data:    data,
    }
    if len(errors) > 0 {
        r.Errors = errors[0]
    }

    // Resolve alert from code + locale
    if a := alert.Get(res.Code, res.Locale); a != nil {
        r.Alert = &adminv2.AlertData{
            Type:    a.Type,
            Title:   a.Title,
            Message: a.Message,
        }
    }

    return r
}
```

**ResponseWrapper update** — add Locale field:

```go
type ResponseWrapper struct {
    Status  int    `json:"status"`
    Code    string `json:"code"`
    Message string `json:"message"`
    Locale  string `json:"locale"`   // NEW: from Accept-Language header
}
```

Controller passes locale when building ResponseWrapper:

```go
locale := helpers.GetLocaleFromContext(ctx)
res := &transformer.ResponseWrapper{
    Status:  1,
    Code:    "A-ORD-S-CRT-001",
    Message: "order created successfully",
    Locale:  locale,
}
```

### Initialization

Load alerts at application startup:

```go
// In engine/grpc/grpc.go (and grpc-insider, grpc-public)
func main() {
    // Load alert config
    if err := alert.Init("config/alert.yaml"); err != nil {
        log.Fatalf("failed to load alerts: %v", err)
    }
    // ... rest of setup
}
```

---

## 7. Response Code Format

Response codes follow a structured format that encodes tier, domain, severity, action, and sequence.

### Format

```
{TIER}-{DOMAIN}-{SEVERITY}-{ACTION}-{SEQ}
```

| Segment | Values | Description |
|---|---|---|
| TIER | `A` (Admin), `I` (Insider), `P` (Public), `G` (Generic) | API tier where code originates |
| DOMAIN | 3-letter code: `ORD`, `TRX`, `INV`, `NAV`, `FND`, `JRN`, `SYS` | Business domain |
| SEVERITY | `S` (Success), `E` (Error), `W` (Warning), `I` (Info) | Response severity |
| ACTION | 3-letter code: `CRT`, `UPD`, `DEL`, `GET`, `PRC`, `RCN` | Operation that triggered the code |
| SEQ | 3-digit: `001`-`999` | Sequence within tier+domain+action |

### Action Codes

| Code | Meaning |
|---|---|
| `CRT` | Create |
| `UPD` | Update |
| `DEL` | Delete |
| `GET` | Get / Gets / Paginate |
| `PRC` | Process |
| `RCN` | Reconcile |
| `ACT` | Activate |
| `DAC` | Deactivate |
| `SUS` | Suspend |
| `APR` | Approve |
| `REJ` | Reject |
| `GEN` | General (for generic codes) |

### Generic Shared Codes

These 8 codes are shared across all tiers and domains:

| Code | Severity | Usage |
|---|---|---|
| `G-SYS-S-GEN-001` | Success | Generic success |
| `G-SYS-E-GEN-001` | Error | Unknown/unexpected error |
| `G-SYS-E-GEN-002` | Error | Validation error (struct) |
| `G-SYS-E-GEN-003` | Error | Not found |
| `G-SYS-E-GEN-004` | Error | Unauthorized |
| `G-SYS-E-GEN-005` | Error | Forbidden |
| `G-SYS-W-GEN-001` | Warning | Operation completed with warnings |
| `G-SYS-I-GEN-001` | Info | No changes / informational |

### Domain-Specific Examples

```
A-ORD-S-CRT-001  → Admin: Order created successfully
A-ORD-E-CRT-001  → Admin: Order creation failed
A-ORD-S-PRC-001  → Admin: Order processed successfully
I-ORD-S-CRT-001  → Insider: Order created successfully
P-INV-S-GET-001  → Public: Investor retrieved successfully
A-TRX-S-RCN-001  → Admin: Transaction reconciled successfully
A-NAV-S-PRC-001  → Admin: NAV processed successfully
```

### Controller Usage

```go
// Domain-specific success
res := &transformer.ResponseWrapper{
    Status:  1,
    Code:    "A-ORD-S-CRT-001",
    Message: "order created successfully",
    Locale:  locale,
}

// Generic error (not domain-specific)
res := &transformer.ResponseWrapper{
    Status:  0,
    Code:    "G-SYS-E-GEN-002",
    Message: "invalid parameter",
    Locale:  locale,
}
```

---

## 8. Proto Management with buf

### Directory Structure

```
proto/nav/
├── buf.yaml                    # Module config (v2)
├── buf.gen.yaml                # Default generation config
├── buf.gen.admin.yaml          # Admin-specific generation
├── buf.gen.insider.yaml        # Insider-specific generation
├── buf.gen.public.yaml         # Public-specific generation
├── admin/v1/
│   ├── base.proto              # Shared ErrorData, GenericResponse
│   ├── health.proto
│   ├── order.proto
│   └── ...
├── insider/v1/
│   ├── base.proto
│   ├── health.proto
│   └── ...
└── public/v1/
    ├── base.proto
    ├── health.proto
    └── ...
```

### buf Configuration

```yaml
# File: proto/buf.yaml
version: v2
name: buf.build/your-org/your-service
deps:
  - buf.build/googleapis/googleapis
  - buf.build/grpc-ecosystem/grpc-gateway
```

```yaml
# File: proto/nav/buf.gen.yaml
version: v2
plugins:
  - local: protoc-gen-go              # Go message types
    out: .
    opt:
      - paths=source_relative
  - local: protoc-gen-go-grpc         # gRPC service stubs
    out: .
    opt:
      - paths=source_relative
  - local: protoc-gen-grpc-gateway    # REST gateway handlers
    out: .
    opt:
      - paths=source_relative
      - generate_unbound_methods=true
```

### Proto Service Definition

```protobuf
syntax = "proto3";
package nav.admin.v1;

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
}
```

### Proto Naming Conventions

- **Request types**: `XxxReqRPC` (e.g., `CreateOrderReqRPC`, `GetOrderReqRPC`)
- **Response types**: `XxxResRPC` (e.g., `CreateOrderResRPC`, `GetOrderResRPC`)
- **Data types**: `XxxData` (e.g., `OrderData`, `InvestorData`)
- **Decimal fields**: Always `string` in proto (converted via `decimal.NewFromString`)
- **Timestamp fields**: Always `string` in proto (RFC3339 format)
- **Boolean fields**: Can be `int32` or `optional bool` in proto, always `int` in Go entity

### Generation Workflow

`make protogen` runs the full pipeline. Never call `protoc` directly — buf wraps it and adds dependency resolution, plugin pinning, and lint integration.

```bash
# Generate all proto files (runs lint → 4 buf generate passes → tag injection)
make protogen

# Breakdown:
# 1. buf lint                                  (MANDATORY pre-gate — blocks on failure)
# 2. buf generate                              (default — base messages, googleapis)
# 3. buf generate --template buf.gen.admin.yaml --path proto/nav/admin
# 4. buf generate --template buf.gen.insider.yaml --path proto/nav/insider
# 5. buf generate --template buf.gen.public.yaml --path proto/nav/public
# 6. protoc-go-inject-tag --input="proto/**/**/**/*.pb.go"

# Clean generated files
make protoclean
```

If `buf lint` fails at step 1, the rest of `make protogen` MUST NOT run. Lint failures usually mean a `.proto` file violates a naming/style rule that breaks consumer codegen downstream.

### Custom Struct Tags via protoc-go-inject-tag

`buf generate` only emits the default `protobuf:"..."` struct tag on each generated Go field. To add validation, JSON overrides, or other tags, use **`protoc-go-inject-tag`** — a post-processor that reads a magic comment above each proto field and appends tags to the matching Go struct field after generation.

**Magic comment syntax** (placed directly above the field in the `.proto` file):

```protobuf
message CreateOrderReqRPC {
    // @gotags: validate:"required,uuid"
    string id = 1;

    // @gotags: validate:"required,min=1" json:"order_total,omitempty"
    string amount = 2;

    // @gotags: validate:"required,oneof=pending paid cancelled"
    string status = 3;

    // No magic comment → no extra tags injected (just the default protobuf tag)
    string note = 4;
}
```

**After `buf generate` (before inject):**
```go
type CreateOrderReqRPC struct {
    Id     string `protobuf:"bytes,1,opt,name=id,proto3"`
    Amount string `protobuf:"bytes,2,opt,name=amount,proto3"`
    Status string `protobuf:"bytes,3,opt,name=status,proto3"`
    Note   string `protobuf:"bytes,4,opt,name=note,proto3"`
}
```

**After `protoc-go-inject-tag` runs:**
```go
type CreateOrderReqRPC struct {
    Id     string `protobuf:"bytes,1,opt,name=id,proto3" validate:"required,uuid"`
    Amount string `protobuf:"bytes,2,opt,name=amount,proto3" validate:"required,min=1" json:"order_total,omitempty"`
    Status string `protobuf:"bytes,3,opt,name=status,proto3" validate:"required,oneof=pending paid cancelled"`
    Note   string `protobuf:"bytes,4,opt,name=note,proto3"`
}
```

**Tags the team injects:**
- **`validate:"..."`** — go-playground/validator rules for request/response messages. The controller's `c.Validator.Struct(req)` call (Step 1 of the controller flow, see Section 2) relies on these. **Without inject, no request validation happens.**
- **`json:"..."`** — only when you need a JSON field name that differs from the proto field name, or when you need `omitempty`. The default `protojson` marshaler doesn't honor `omitempty`, but the gateway path that goes through `encoding/json` does.

**Rules of thumb:**
- Every request message field (`XxxReqRPC`) that has constraints **must** have a `validate:` tag. Missing tags = silent acceptance of invalid input.
- Response message fields (`XxxResRPC`) and data types (`XxxData`) rarely need inject tags — they're transformer output, already shaped correctly.
- The magic comment is part of the `.proto` source — it travels with the field. Renaming or moving a field carries the tag with it.
- `// @gotags:` (no space after `@`) is the exact prefix the tool recognizes. `// gotags:` or `// @gotag:` is silently ignored.
- Inject runs AFTER `buf generate`, never before. If you regenerate without inject, all validation tags vanish — re-run `make protogen` (don't call `buf generate` directly).
- Never hand-edit `*.pb.go` to add tags — they will be wiped on the next generation. Always put the tag in the `.proto` magic comment.

### Quality Gates: buf lint, format, breaking

Three buf commands are part of the workflow beyond `buf generate`. Each has a specific moment it runs.

| Command | When to run | What it does | Failure policy |
|---|---|---|---|
| `buf lint` | **Before every commit** that touches `.proto`, and as step 1 of `make protogen` | Enforces naming conventions, package layout, service/RPC shape (e.g., RPCs must take a request message, not a primitive) | **Blocking.** Do not commit. Do not generate. Fix the proto. |
| `buf format -w` | Before commit, optional | Reformats `.proto` files to canonical style (whitespace, alignment). Idempotent. | Non-blocking, but a follow-up `buf lint` may then pass cleanly. |
| `buf breaking --against '.git#branch=main'` | Before pushing a PR | Detects backward-incompatible changes vs `main` (field number reuse, removed RPCs, changed types). Catches wire-protocol breakage that compiles but breaks running consumers. | **Blocking on Admin/Insider/Public protos** (they have live consumers — other services' gRPC client SDKs). Soft-warning on internal-only protos. |

**`buf lint` is mandatory.** If a model is editing a `.proto` file, it should run `buf lint` before considering the change done — and treat any failure as blocking, same as a `go build` error. The reason: lint rules are tuned to the generators (`protoc-gen-go`, `protoc-gen-go-grpc`, `protoc-gen-grpc-gateway`) so that a lint-clean proto produces sane Go bindings. A lint violation usually means generation will succeed but produce something downstream code can't use (e.g., a service whose name is parsed as a different identifier in the gateway).

**`buf breaking` is the silent-incident catcher.** Field-number reuse and type changes don't break the build — they break clients in production. Run it as part of CI on every PR that modifies `proto/nav/admin/`, `proto/nav/insider/`, or `proto/nav/public/`.

### Field Numbering Rules

1. **Never reuse field numbers** (even for deprecated fields)
2. **Reserve deprecated numbers**: `reserved 8, 15;`
3. **1-15**: Frequently used fields (compact 1-byte encoding)
4. **16-2047**: Normal fields (2-byte encoding)

---

## 9. Wire DI for Controllers

Wire is used for compile-time dependency injection. Each entity/service has corresponding Initialize functions.

### Injector Structure

```go
// File: injector/inject/injector.go
//go:build wireinject

package inject

import (
    "github.com/google/wire"
    // ... imports
)
```

### Naming Convention

Wire functions follow a strict naming pattern per tier:

| Tier | Pattern | Example |
|---|---|---|
| Admin | `InitializeXxxControllerGRPC` | `InitializeOrderControllerGRPC` |
| Insider | `InitializeXxxControllerGRPCInsider` | `InitializeOrderControllerGRPCInsider` |
| Public | `InitializeXxxControllerGRPCPublic` | `InitializeOrderControllerGRPCPublic` |
| Service-only | `InitializeXxxService` | `InitializeOrderService` |

### Controller Injection Example

```go
func InitializeOrderControllerGRPC() (adminv2.OrderServer, error) {
    wire.Build(
        controller.NewOrderController,
        service.NewOrderService,
        transformer.NewOrderTransformer,
        repository.NewOrderRepository,
        database.GetDB,
        // ... additional dependencies as needed
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

### Wire Generation

```bash
# Generate wire_gen.go
make injector
# Runs: wire ./injector/**

# NEVER edit wire_gen.go manually
```

### Registering Controllers in Server

```go
// File: engine/grpc/grpc.go

func main() {
    // Create gRPC server with interceptor chain
    server := grpc.NewServer(
        grpc.ChainUnaryInterceptor(
            middleware.SIDUnaryServerInterceptor(),
            middleware.InfoUnaryServerInterceptor(),
            middleware.GRPCZapLoggerUnaryServerInterceptor(),
            middleware.RecoveryUnaryServerInterceptor(),
            middleware.AuthUnaryServerInterceptor(),
        ),
        grpc.ChainStreamInterceptor(
            middleware.SIDStreamServerInterceptor(),
            middleware.InfoStreamServerInterceptor(),
            middleware.GRPCZapLoggerStreamServerInterceptor(),
            middleware.RecoveryStreamServerInterceptor(),
            middleware.AuthStreamServerInterceptor(),
        ),
    )

    // Inject and register all controllers
    orderCtrl, _ := inject.InitializeOrderControllerGRPC()
    adminv2.RegisterOrderServer(server, orderCtrl)

    healthCtrl, _ := inject.InitializeHealthControllerGRPC()
    adminv2.RegisterHealthServer(server, healthCtrl)

    // ... register all other service controllers

    // Start background pools and workers
    pool.StartAsyncListeners()
    worker.StartBackgroundWorkers()

    // Listen
    listener, _ := net.Listen("tcp", ":"+constant.GRPC_PORT)
    server.Serve(listener)
}
```

---

## 10. Interceptor Chain

Interceptors are gRPC middleware. Each tier has its own chain.

### Middleware Chain Order

**Admin/Insider**:
```
SID → Info → ZapLogger → Recovery → Auth → [Handler]
```

**Public** (may add project-specific interceptors):
```
SID → Info → ZapLogger → Recovery → Auth → [Custom] → [Handler]
```

**Optional** (per-endpoint):
```
RequestResponseLog (async DB logging for callback endpoints)
```

### Middleware Files

All middleware lives in `src/middleware/`:

| File | Purpose |
|------|---------|
| `sid_middleware.go` | Inject unique Session/Request ID into context |
| `info_middleware.go` | Extract geolocation, user-agent, client metadata |
| `grpc_zap_logger_middleware.go` | Structured logging adapter (1KB msg / 512B field limits) |
| `grpc_auth_middleware.go` | Bearer/TOTP application authentication |
| `rest_auth_middleware.go` | HTTP variant of auth middleware |
| `request_response_log_middleware.go` | Selective req/res DB logging |
| `tenant_id_middleware.go` | Tenant identification from context |
| `identify_middleware.go` | Client identification |
| `rest_notfound_middleware.go` | Custom 404 handler |
| `middleware.go` | Core types, constants (MaxMessageSize: 50MB) |

### Server Registration

```go
// File: engine/grpc/grpc.go
grpcServer := grpc.NewServer(
    grpc.MaxRecvMsgSize(middleware.MaxMessageSize),  // 50MB
    grpc.MaxSendMsgSize(middleware.MaxMessageSize),
    grpc.ChainUnaryInterceptor(
        middleware.SIDUnaryServerInterceptor(),
        middleware.InfoUnaryServerInterceptor(),
        grpc_zap.UnaryServerInterceptor(zapLogger),
        grpc_recovery.UnaryServerInterceptor(),
        middleware.AuthUnaryServerInterceptor(),
    ),
    grpc.ChainStreamInterceptor(
        middleware.SIDStreamServerInterceptor(),
        middleware.InfoStreamServerInterceptor(),
        grpc_zap.StreamServerInterceptor(zapLogger),
        grpc_recovery.StreamServerInterceptor(),
        middleware.AuthStreamServerInterceptor(),
    ),
)
```

### SID Middleware (Request ID)

Generates a unique Session ID per request and stores it in context. All downstream logging uses this for correlation:

```go
func SIDUnaryServerInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
        sid := uuid.New().String()
        ctx = context.WithValue(ctx, helpers.SIDCtxKey, sid)
        // Also inject into gRPC response header for client correlation
        grpc.SetHeader(ctx, metadata.Pairs("x-sid", sid))
        return handler(ctx, req)
    }
}
```

### Info Middleware (Metadata Extraction)

Extracts client metadata from gRPC headers and stores in context:

```go
func InfoUnaryServerInterceptor() grpc.UnaryServerInterceptor {
    // Extracts from metadata:
    // - x-forwarded-for → client IP
    // - user-agent → client info
    // - x-client-id → application code
    // - referer → request origin
    // Stores all as context values for downstream use
}
```

### Auth Interceptor

The auth interceptor validates application identity via `x-client-id` header and authorization:

```go
func AuthUnaryServerInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {

        // Whitelist: health checks, reflection, specific callbacks
        switch info.FullMethod {
        case navadminv1.Health_Check_FullMethodName,
             navinsiderv1.Health_Check_FullMethodName,
             navpublicv1.Health_Check_FullMethodName:
            return handler(ctx, req)
        }

        // 1. Extract client IP from context
        ip, ok := getRemoteAddressFromContext(ctx)

        // 2. Extract x-client-id from metadata
        md, _ := metadata.FromIncomingContext(ctx)
        clientID := md.Get("x-client-id")

        // 3. Lookup Application by code
        appRepo := repository.NewApplicationRepository(database.GetDB())
        ap, _ := appRepo.ForCode(clientID[0]).Get(ctx)

        // 4. Validate application is active and not suspended
        // ap.IsActive == 1 && ap.IsSuspended == 0

        // 5. Validate IP host eligibility
        hosts, _ := appRepo.ForApplicationID(ap.ID).ForIPs(ip).GetHosts(ctx)

        // 6. Validate authorization header
        auth := md.Get("authorization")
        crs := strings.Split(auth[0], " ")  // "Bearer xxx" or "TOTP xxx"

        switch crs[0] {
        case "Bearer":
            // SHA256 hash of ServerKey must match
            h := sha256.New()
            h.Write([]byte(ap.ServerKey))
            hash := h.Sum(nil)
            // Compare: crs[1] == hex.EncodeToString(hash)

        case "TOTP":
            // Time-based signature verification
            utils.VerifySignature(ap.ClientKey.String(), crs[1], int64(totpFactor))
        }

        // 7. Store application in context for downstream use
        ctx = context.WithValue(ctx, AppKey, ap)

        return handler(ctx, req)
    }
}
```

### Request/Response Logging Interceptor

For specific endpoints (e.g., payment callbacks), logs request and response to database asynchronously:

```go
func RequestResponseLogUnaryServerInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
        if !shouldLogEndpoint(ctx, info.FullMethod) {
            return handler(ctx, req)
        }

        startTime := time.Now()
        resp, err := handler(ctx, req)
        duration := time.Since(startTime).Milliseconds()

        // Log asynchronously to database
        go func() {
            logService.Create(context.Background(), service.CreateRequestResponseLogParams{
                SID:          helpers.GetSIDFromContext(ctx),
                Endpoint:     info.FullMethod,
                Method:       "gRPC",
                RequestBody:  serializeProto(req),
                ResponseBody: serializeProto(resp),
                Duration:     duration,
                ClientIP:     getClientIPFromContext(ctx),
            })
        }()

        return resp, err
    }
}
```

---

## 11. Health Check Endpoint

Every gRPC tier **must** expose a `/health` endpoint. Health checks are stateless, require no authentication, and return basic liveness info.

### Proto Definition

Each tier defines its own `health.proto` — identical structure, different package:

```proto
// proto/nav/{admin|insider|public}/v1/health.proto
syntax = "proto3";
package nav.admin.v1;  // or nav.insider.v1, nav.public.v1

import "google/api/annotations.proto";
import "google/protobuf/empty.proto";

message HealthCheckResponse {
  string status = 1;       // Always "ok" for liveness
  string service = 2;      // Identifies which tier responded
  string timestamp = 3;    // RFC3339 UTC timestamp
}

service Health {
  rpc Check (google.protobuf.Empty) returns (HealthCheckResponse) {
    option (google.api.http) = {
      get: "/health"
    };
  }
}
```

### Controller Implementation

Health controllers are the simplest controllers in the system — no service layer, no transformer, no DI:

```go
// engine/grpc/controller/health_controller_impl.go
package controller

import (
    "context"
    "time"

    adminv1 "yourmodule/gen/go/admin/v1"
    "google.golang.org/protobuf/types/known/emptypb"
)

type HealthControllerImpl struct {
    adminv1.UnimplementedHealthServer
}

func NewHealthController() adminv1.HealthServer {
    return &HealthControllerImpl{}
}

func (c HealthControllerImpl) Check(ctx context.Context, req *emptypb.Empty) (*adminv1.HealthCheckResponse, error) {
    return &adminv1.HealthCheckResponse{
        Status:    "ok",
        Service:   "{service}-admin",
        Timestamp: time.Now().UTC().Format(time.RFC3339),
    }, nil
}
```

Each tier has its own copy with the correct proto import and service name:

| Tier | Service Name | Proto Package |
|------|-------------|---------------|
| Admin | `{service}-admin` | `adminv1` |
| Insider | `{service}-insider` | `insiderv1` |
| Public | `{service}-public` | `publicv1` |

### Registration

Health controllers are instantiated **directly** — no Wire injection needed since they have zero dependencies:

```go
// In each tier's main server file (grpc.go, grpc-insider.go, grpc-public.go)
healthCtrl := controller.NewHealthController()
adminv1.RegisterHealthServer(grpcServer, healthCtrl)  // or insiderv1, publicv1
```

### Auth Bypass

Health endpoints **must** be whitelisted in the auth interceptor. Without this, load balancers and orchestrators (K8s, Cloud Run) cannot reach the health check:

```go
// In AuthUnaryServerInterceptor
switch info.FullMethod {
case adminv1.Health_Check_FullMethodName,
     insiderv1.Health_Check_FullMethodName,
     publicv1.Health_Check_FullMethodName:
    return handler(ctx, req)  // Skip all auth
}
```

The `Health_Check_FullMethodName` constants are auto-generated by protoc (e.g., `"/nav.admin.v1.Health/Check"`).

### REST Gateway

Via grpc-gateway, the health check is automatically available as:

```
GET /health → { "status": "ok", "service": "{service}-admin", "timestamp": "2026-04-10T12:00:00Z" }
```

No additional REST registration needed — the `google.api.http` annotation in the proto handles it.

### Key Rules

1. **One health proto per tier** — each tier has its own package, never share across tiers
2. **No Wire DI** — health controllers have no dependencies, instantiate directly
3. **Always whitelist** — health endpoints must bypass auth interceptor
4. **Value receiver** — `(c HealthControllerImpl)` not pointer, same as all controllers
5. **UTC timestamps** — always `time.Now().UTC().Format(time.RFC3339)`
6. **Constructor returns proto interface** — `NewHealthController() navadminv1.HealthServer`

---

## REST Gateway

Each gRPC tier has a corresponding REST gateway that translates HTTP ↔ gRPC:

```
engine/rest/         → Admin REST gateway → connects to engine/grpc/
engine/rest-insider/ → Insider REST gateway → connects to engine/grpc-insider/
engine/rest-public/  → Public REST gateway → connects to engine/grpc-public/
```

### Gateway Configuration

```go
// Uses grpc-gateway/v2 with protojson marshaling
mux := runtime.NewServeMux(
    runtime.WithMarshalerOption(runtime.MIMEWildcard, &runtime.JSONPb{
        MarshalOptions: protojson.MarshalOptions{
            UseProtoNames:   true,    // Preserves snake_case in JSON
            EmitUnpopulated: true,    // Includes zero-value fields
        },
    }),
)
```

### Metadata Forwarding

REST gateway forwards these HTTP headers as gRPC metadata:
- `X-Forwarded-For`
- `User-Agent`
- `X-Client-ID`
- `Referer`

---

## 12. Anti-Patterns

| Anti-pattern | Why it breaks | Fix |
|---|---|---|
| Controller method returns `(ControllerInterface, error)` from constructor | Wire requires the proto server interface return type to auto-wire; returning a custom interface breaks registration | Constructor must return `(proto.XxxServer, error)` |
| Value receiver on constructor, pointer receiver on methods | Constructor builds a value; methods mutate the pointer — receiver mismatch means method changes don't persist | Use pointer receivers consistently on implementation methods |
| Skipping the `validate struct` step (step 1 of 7-step flow) | Invalid input reaches the service layer; service must defensively re-validate | Always validate the request struct before building Params |
| Returning a gRPC `status.Error` for business / param errors | gRPC status errors bypass the response envelope; callers receive raw gRPC status, not the structured `{Status, Code, Message}` | Wrap param errors in the response envelope; use gRPC status only for infrastructure failures (authentication, unavailable) |
| Controller embedding a controller interface instead of `UnimplementedXxxServer` | Missing proto methods panic at runtime when a new method is added to the proto | Embed the `Unimplemented*` struct from the generated proto package |
| Hand-editing `*.pb.go` files | Next `make protogen` overwrites changes silently | Use `// @gotags:` comments in `.proto` files; see `proto-workflow.md` |
| Calling `buf generate` directly (not `make protogen`) | `buf generate` runs without `protoc-go-inject-tag` — struct validation tags are stripped | Always use `make protogen`; see `proto-workflow.md §1` |
| Putting business logic in transformers | Transformers translate shape only; business logic there is untested and unrecovered from panics | Keep transformers pure field-mapping; all decisions happen in services |
| Using concrete type return (`*OrderTransformerImpl`) for transformer in controller | Can't swap transformers in tests | Return interface from constructor |
| Response code that doesn't follow `{TIER}-{DOMAIN}-{SEV}-{ACTION}-{SEQ}` format | Ops can't parse tier/domain/severity from logs automatically | Use the format strictly: e.g., `A-ORD-S-CRT-001` (Admin, Order, Success, Create, #1) |

---

## Related References

- **Service Patterns** (`service-patterns.md`) — Triple return, Params validation, service implementation
- **Entity Patterns** (`entity-patterns.md`) — Composable traits, BaseEntity
- **Repository Patterns** (`repository-patterns.md`) — Fluent builder, transactions
- **Infrastructure** (`infrastructure.md`) — Database, event pools, encryption
- **Proto Workflow** (`proto-workflow.md`) — Authoritative `make protogen` flow, buf lint/breaking
- **Error Handling** (`error-handling.md`) — ParamError structure, response code matrix
