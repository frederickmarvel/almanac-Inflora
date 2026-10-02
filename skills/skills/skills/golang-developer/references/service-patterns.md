# Service Layer Patterns Reference

## Table of Contents

1. [Triple Return Pattern](#1-triple-return-pattern)
2. [Params Interface](#2-params-interface)
3. [Service Implementation Pattern](#3-service-implementation-pattern)
4. [Error Return Conventions](#4-error-return-conventions)
5. [Transaction Management](#5-transaction-management)
6. [Panic Recovery](#6-panic-recovery)
7. [Key Rules](#7-key-rules)
8. [Anti-Patterns](#8-anti-patterns)

---

## 1. Triple Return Pattern

Service methods return three values in this order:
1. `result` — the business data (nil on error)
2. `error` — system/infrastructure errors (DB down, timeout, etc.)
3. `[]ParamError` — validation errors with field-level detail (user input issues)

This three-part return signature is the cornerstone of this architecture's service design. It allows controllers to distinguish between different error types and respond appropriately.

### Interface Definition

```go
type OrderService interface {
    Create(ctx context.Context, params CreateOrderParams) (*entity.Order, error, []ParamError)
    Get(ctx context.Context, params GetOrderParams) (*entity.Order, error, []ParamError)
    Gets(ctx context.Context, params GetOrdersParams) ([]*entity.Order, error, []ParamError)
    GetPaginate(ctx context.Context, params GetOrderPaginateParams) (paginator.Pagination, error, []ParamError)
    Count(ctx context.Context, params CountOrdersParams) (int64, error, []ParamError)
    Process(ctx context.Context, params ProcessOrderParams) (*entity.Order, error, []ParamError)
    Cancel(ctx context.Context, params CancelOrderParams) (*entity.Order, error, []ParamError)
    Delete(ctx context.Context, params DeleteOrderParams) (error, []ParamError)
}
```

### Return Type Variants

| Method Type | Return Signature | Example |
|---|---|---|
| Single entity | `(*entity.Order, error, []ParamError)` | `Get`, `Create`, `Process` |
| Multiple entities | `([]*entity.Order, error, []ParamError)` | `Gets` |
| Paginated | `(paginator.Pagination, error, []ParamError)` | `GetPaginate` |
| Count/scalar | `(int64, error, []ParamError)` | `Count` |
| Void (no result) | `(error, []ParamError)` | `Delete`, `Suspend`, `Activate` |
| Utility/async | `(*entity.Order, error)` | Internal methods without param validation |

**~95% of methods use the full triple return.** Two-return `(result, error)` is only for internal/async utility methods where param validation happens elsewhere.

### Controller Consumption

Controllers check returns in strict order: **paramErrors → error → nil result → success**:

```go
locale := helpers.GetLocaleFromContext(ctx)
order, err, paramErrors := c.Service.Get(ctx, params)

// 1. Check param validation errors FIRST
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

// 2. Check system errors SECOND
if err != nil {
    res := &transformer.ResponseWrapper{
        Status:  0,
        Code:    "A-ORD-E-GET-001",
        Message: err.Error(),
        Locale:  locale,
    }
    return c.Transformer.TransformWrapperGetOrder(res, nil), nil
}

// 3. Check nil result (not found)
if order == nil {
    res := &transformer.ResponseWrapper{
        Status:  0,
        Code:    "G-SYS-E-GEN-003",
        Message: "data not found",
        Locale:  locale,
    }
    return c.Transformer.TransformWrapperGetOrder(res, nil), nil
}

// 4. Success
res := &transformer.ResponseWrapper{
    Status:  1,
    Code:    "A-ORD-S-GET-001",
    Message: "success",
    Locale:  locale,
}
return c.Transformer.TransformWrapperGetOrder(res, c.Transformer.ToProto(c.Transformer.ToDTO(order))), nil
```

The `TransformErrors` utility bridges service ParamError to proto ErrorData:

```go
func TransformErrors(errors []service.ParamError) []*navadminv1.ErrorData {
    var errorList []*navadminv1.ErrorData
    for _, err := range errors {
        errorList = append(errorList, &navadminv1.ErrorData{
            Field:   err.Field,
            Message: err.Message,
        })
    }
    return errorList
}
```

---

## 2. Params Interface

Every service method input MUST implement the `Params` interface. Defined in `src/service/service_params.go`:

### Interface Definition

```go
type Params interface {
    IsMandatoryFilled() bool
    MandatorySchema() string
    MandatoryErrors() []ParamError
}

type ParamError struct {
    Field   string `json:"field" transx:"field"`
    Message string `json:"message" transx:"message"`
}
```

### Helper Interfaces (same file)

```go
// For list queries with limit/offset
type Limited interface {
    GetLimit() uint64
    GetOffset() uint64
}

// For paginated queries
type Paginated interface {
    GetPage() uint64
    GetPerPage() uint64
}
```

### Interface Methods Explained

**`IsMandatoryFilled() bool`**
- Quick boolean check: are all required fields present and valid?
- Used for early validation in service methods
- Uses pointer checks (`!= nil`) for optional pointer fields, zero checks (`!= 0`) for required values
- Uses `strings.TrimSpace()` for string validation
- Can delegate to nested item validation via helper functions

**`MandatorySchema() string`**
- Returns a formatted string containing BOTH: all mandatory fields AND which ones are unfilled
- Two valid styles:
  - **Simple**: just `"tenant_id & investor_id"` (when no dynamic unfilled tracking needed)
  - **Detailed**: `fmt.Sprintf("mandatory: [%s] - unfilled: [%s]", all, strings.Join(unfilled, " & "))`
- Uses `&` for AND (all required), `|` for OR (any one required)
- Returns `""` if there are no mandatory fields

**`MandatoryErrors() []ParamError`**
- Performs detailed validation and returns all field-level errors
- Each error specifies which field failed and why
- Uses `MandatoryMessage` constant: `fmt.Sprintf(MandatoryMessage, "FieldName")` where `MandatoryMessage = "%s is mandatory"`
- For "at least one of" scenarios, uses combined field: `ParamError{Field: "id | code | reference_id", Message: "at least one must be provided"}`

### Complete Params Implementation

```go
// File: src/service/order_service_params.go

type CreateOrderParams struct {
    TenantID   uint64
    OwnerID    *int64
    ExternalId *string
    Type       string
    Amount     decimal.Decimal
    CategoryID uint64
    Note       string
}

// Quick check: are all mandatory fields present?
// ALWAYS use pointer receiver (*Params)
func (p *CreateOrderParams) IsMandatoryFilled() bool {
    return p.TenantID != 0 &&
           (p.OwnerID != nil || p.ExternalId != nil) &&
           strings.TrimSpace(p.Type) != "" &&
           p.Amount.IsPositive() &&
           p.CategoryID != 0
}

// Document mandatory fields AND report which are unfilled
func (p *CreateOrderParams) MandatorySchema() string {
    all := "tenant_id & (owner_id | external_id) & type & amount & category_id"
    unfilled := []string{}
    if p.TenantID == 0 {
        unfilled = append(unfilled, "tenant_id")
    }
    if p.OwnerID == nil && p.ExternalId == nil {
        unfilled = append(unfilled, "owner_id | external_id")
    }
    if strings.TrimSpace(p.Type) == "" {
        unfilled = append(unfilled, "type")
    }
    if !p.Amount.IsPositive() {
        unfilled = append(unfilled, "amount")
    }
    if p.CategoryID == 0 {
        unfilled = append(unfilled, "category_id")
    }
    return fmt.Sprintf("mandatory: [%s] - unfilled: [%s]", all, strings.Join(unfilled, " & "))
}

// Return detailed field-level errors
func (p *CreateOrderParams) MandatoryErrors() []ParamError {
    var errs []ParamError

    if p.TenantID == 0 {
        errs = append(errs, ParamError{
            Field:   "tenant_id",
            Message: fmt.Sprintf(MandatoryMessage, "Tenant ID"),
        })
    }

    if p.OwnerID == nil && p.ExternalId == nil {
        errs = append(errs, ParamError{
            Field:   "owner_id | external_id",
            Message: "at least one of owner_id or external_id must be provided",
        })
    }

    if strings.TrimSpace(p.Type) == "" {
        errs = append(errs, ParamError{
            Field:   "type",
            Message: fmt.Sprintf(MandatoryMessage, "Type"),
        })
    }

    if !p.Amount.IsPositive() {
        errs = append(errs, ParamError{
            Field:   "amount",
            Message: "amount must be positive",
        })
    }

    if p.CategoryID == 0 {
        errs = append(errs, ParamError{
            Field:   "category_id",
            Message: fmt.Sprintf(MandatoryMessage, "Category ID"),
        })
    }

    return errs
}
```

### No-Mandatory-Fields Params (List/Search)

```go
type GetOrdersParams struct {
    TenantID *uint64
    Status    *string
    Limit     uint64
    Offset    uint64
}

func (p *GetOrdersParams) IsMandatoryFilled() bool { return true }
func (p *GetOrdersParams) MandatorySchema() string { return "" }
func (p *GetOrdersParams) MandatoryErrors() []ParamError { return []ParamError{} }

func (p *GetOrdersParams) GetLimit() uint64 {
    if p.Limit == 0 { return 10 }
    if p.Limit > 1000 { return 1000 }
    return p.Limit
}

func (p *GetOrdersParams) GetOffset() uint64 { return p.Offset }
```

### Nested Params with Helper Validation

```go
type OrderParams struct {
    TenantID   uint64
    InvestorID  *int64
    ExternalId  *string
    ReferenceID string
    Items       []OrderItemParams
}

type OrderItemParams struct {
    ProductID uint64
    Amount    *decimal.Decimal
    Unit      *decimal.Decimal
    Note      string
}

func (p *OrderParams) IsMandatoryFilled() bool {
    return p.TenantID != 0 &&
           (p.InvestorID != nil || p.ExternalId != nil) &&
           strings.TrimSpace(p.ReferenceID) != "" &&
           len(p.Items) > 0 &&
           IsOrderItemsValid(p.Items)  // Helper validates nested items
}

// Helper function for nested item validation
func IsOrderItemsValid(items []OrderItemParams) (valid bool) {
    valid = true
    for _, item := range items {
        if !item.IsMandatoryFilled() {
            valid = false
            break
        }
    }
    return
}
```

---

## 3. Service Implementation Pattern

### File Structure

Each domain entity gets **three files** — never combined, even for a one-method service:

```
src/service/
├── order_service.go           # Interface
├── order_service_impl.go      # Implementation
└── order_service_params.go    # Parameter types + MandatoryMessage constant
```

Shared types live in `src/service/service_params.go` (Params interface, ParamError, Limited, Paginated).

**Adding a method touches all relevant files:** the method signature goes in `x_service.go`, the body in `x_service_impl.go`, and any new Params struct (with its three validation methods) in `x_service_params.go`. Never declare a Params struct or an interface inline in the impl file.

### Struct & Constructor

```go
// File: src/service/order_service_impl.go

type OrderServiceImpl struct {
    Repository         repository.OrderRepository
    ItemRepository     repository.OrderItemRepository
    CategoryRepository repository.CategoryRepository
    AuditService       AuditService  // Services CAN receive other services
}

// Constructor ALWAYS returns interface, pointer to struct
func NewOrderService(
    repo repository.OrderRepository,
    itemRepo repository.OrderItemRepository,
    categoryRepo repository.CategoryRepository,
    auditSvc AuditService,
) OrderService {
    return &OrderServiceImpl{
        Repository:         repo,
        ItemRepository:     itemRepo,
        CategoryRepository: categoryRepo,
        AuditService:       auditSvc,
    }
}
```

**Key conventions:**
- Constructor returns **interface** type, never concrete
- Constructor returns **pointer** `&OrderServiceImpl{}`
- Repository fields can be exported (`Repository`) or unexported (`investorRepo`) — both exist in production
- Other services are injected when cross-domain coordination is needed

### Standard Method Flow

Every service method follows this exact sequence. Use **pointer receiver** `*ServiceImpl`:

```go
func (s *OrderServiceImpl) Create(
    ctx context.Context,
    params CreateOrderParams,
) (*entity.Order, error, []ParamError) {

    // 1. PANIC RECOVERY (ALWAYS first line)
    defer helpers.LogAndCatchPanic()

    // 2. VALIDATE PARAMS (mandatory field check)
    // Returns BOTH error (with schema string) AND ParamErrors (field details)
    if !params.IsMandatoryFilled() {
        return nil, errors.New(params.MandatorySchema()), params.MandatoryErrors()
    }

    // 3. BUSINESS RULE VALIDATION (return ParamError for user mistakes)
    category, err := s.CategoryRepository.ForID(params.CategoryID).Get(ctx)
    if err != nil {
        return nil, err, nil  // System error
    }
    if category == nil {
        return nil, nil, []ParamError{{
            Field:   "category_id",
            Message: "category not found",
        }}
    }

    if category.IsActive != 1 {
        return nil, nil, []ParamError{{
            Field:   "category_id",
            Message: "category is not active",
        }}
    }

    // 4. BUILD ENTITY (prepare business object)
    // NOTE: Do NOT set CreatedAt/UpdatedAt — auto-managed by Timestamp trait
    order := &entity.Order{
        TenantID:   params.TenantID,
        OwnerID:    params.OwnerID,
        Type:       params.Type,
        Amount:     params.Amount,
        CategoryID: params.CategoryID,
        Status:     "pending",
    }

    // 5. TRANSACTION MANAGEMENT
    repo := s.Repository.StartTx(ctx)
    defer func() {
        _ = repo.RollbackTx()  // No-op after commit
    }()

    // 6. EXECUTE
    result, err := repo.Create(ctx, order)
    if err != nil {
        return nil, err, nil
    }

    // 7. COMMIT & RETURN
    if err := repo.CommitTx(); err != nil {
        return nil, err, nil
    }

    return result, nil, nil
}
```

### Fluent Repository Chain Usage

```go
func (s *OrderServiceImpl) Gets(
    ctx context.Context,
    params GetOrdersParams,
) ([]*entity.Order, error, []ParamError) {
    defer helpers.LogAndCatchPanic()

    if !params.IsMandatoryFilled() {
        return nil, errors.New(params.MandatorySchema()), params.MandatoryErrors()
    }

    // Build query with fluent chain — conditionally apply filters
    repo := s.Repository
    if params.TenantID != nil {
        repo = repo.ForTenantID(*params.TenantID)
    }
    if params.Status != nil {
        repo = repo.ForStatus(*params.Status)
    }

    repo = repo.Order(repository.Order{Column: "created_at", Option: repository.OrderDesc})

    orders, err := repo.Limit(params.GetLimit()).Offset(params.GetOffset()).Gets(ctx)
    if err != nil {
        return nil, err, nil
    }

    return orders, nil, nil
}
```

---

## 4. Error Return Conventions

### Mandatory Validation Pattern

The mandatory check returns the schema string as the error (2nd return) for logging, AND the field-level details as ParamErrors (3rd return) for the client:

```go
if !params.IsMandatoryFilled() {
    return nil, errors.New(params.MandatorySchema()), params.MandatoryErrors()
}
```

Alternative pattern (schema in error only, no ParamErrors):
```go
if !params.IsMandatoryFilled() {
    return nil, fmt.Errorf("mandatory %s", params.MandatorySchema()), nil
}
```

### Return Patterns

**System Error (500)**
```go
return nil, fmt.Errorf("database connection failed"), nil
```

**Validation Error (400)**
```go
return nil, nil, []ParamError{
    {Field: "amount", Message: "amount must be positive"},
}
```

**Not Found (as system error)**
```go
if entity == nil {
    return nil, errors.New("transaction not found"), nil
}
```

**Success**
```go
return result, nil, nil
```

### Error Taxonomy

| Scenario | Return Pattern | Cause |
|---|---|---|
| Database is down | `(nil, err, nil)` | Infrastructure |
| Context timeout | `(nil, err, nil)` | Infrastructure |
| Entity not found | `(nil, err, nil)` or `(nil, nil, []ParamError{})` | Depends on context |
| Missing required field | `(nil, err, paramErrors)` | Mandatory check |
| Invalid enum value | `(nil, nil, []ParamError{})` | Business rule |
| Business rule violation | `(nil, nil, []ParamError{})` | Business rule |

---

## 5. Transaction Management

### Pattern 1: Single Repo Transaction (Standard)

Always defer `RollbackTx()` unconditionally. Rollback is a no-op after commit.

```go
repo := s.Repository.StartTx(ctx)
defer func() {
    _ = repo.RollbackTx()
}()

// ... operations ...

if err := repo.CommitTx(); err != nil {
    return nil, err, nil
}
```

### Pattern 2: Multi-Repo Shared Transaction (WithTx + GetTx)

Pass the transaction handle across repositories using `WithTx(tx.GetTx())`:

```go
repo := s.Repository.StartTx(ctx)
defer func() {
    _ = repo.RollbackTx()
}()

// Share transaction across different repositories
navRepo := s.NavRepository.WithTx(repo.GetTx())
fundRepo := s.FundRepository.WithTx(repo.GetTx())

nav, err := navRepo.ForProductID(productID).Get(ctx)
if err != nil {
    return nil, err, nil
}

fund, err := fundRepo.ForTenantID(tenantID).Get(ctx)
if err != nil {
    return nil, err, nil
}

// All operations in the same DB transaction
if err := repo.CommitTx(); err != nil {
    return nil, err, nil
}
```

### Pattern 3: Composable Transaction (Optional Existing Tx)

When a method may be called standalone or as part of a larger transaction:

```go
func (s *JournalServiceImpl) process(
    ctx context.Context,
    journal *entity.Journal,
    existingTx *gorm.DB,
) error {
    var tx repository.JournalRepository
    var shouldCommit bool

    if existingTx != nil {
        tx = s.Repository.WithTx(existingTx)
        shouldCommit = false
    } else {
        tx = s.Repository.StartTx(ctx)
        shouldCommit = true
        defer func() {
            _ = tx.RollbackTx()
        }()
    }

    // ... operations using tx ...

    if shouldCommit {
        if err := tx.CommitTx(); err != nil {
            return fmt.Errorf("failed to commit transaction: %w", err)
        }
    }
    return nil
}
```

---

## 6. Panic Recovery

Every exported service method MUST start with `defer helpers.LogAndCatchPanic()`.

### Standard Pattern

```go
func (s *OrderServiceImpl) Create(
    ctx context.Context,
    params CreateOrderParams,
) (*entity.Order, error, []ParamError) {
    defer helpers.LogAndCatchPanic()

    // ... method body
}
```

### Actual LogAndCatchPanic Implementation

```go
// File: src/helpers/common.go
func LogAndCatchPanic() {
    pc, _, _, _ := runtime.Caller(1)
    fn := runtime.FuncForPC(pc).Name()
    e := recover()
    if e != nil {
        fmt.Printf("Panic caught in %s: %v\n", fn, e)
        fmt.Println(string(dbg.Stack()))
        clog.SendclogRPC(clog.ClogRPC{
            Event:   constant.ClogEventError,
            Level:   clog.ERROR,
            Title:   fn,
            Message: fmt.Sprint(e),
            Fields: []clog.ClogFieldRPC{
                {Key: "Stack", Value: string(dbg.Stack())},
            },
        })
    }
}
```

### Loop-Level Panic Recovery (Batch/Routine Methods)

For batch processing, use inline recovery per iteration to prevent one bad item from stopping the entire batch:

```go
for _, trx := range transactions {
    func() {
        defer func() {
            if e := recover(); e != nil {
                app.Zap.Error("Routine - Process Transactions",
                    zap.String("stack", string(debug.Stack())))
                clog.SendclogRPC(clog.ClogRPC{
                    Event:   constant.ClogEventError,
                    Level:   clog.ERROR,
                    Title:   fmt.Sprintf("Routine - Process Transactions - Trx ID: %d", trx.ID),
                    Message: "Failed to process transactions",
                    Fields: []clog.ClogFieldRPC{
                        {Key: "ID", Value: trx.ID},
                        {Key: "Error", Value: e},
                        {Key: "Stack", Value: string(debug.Stack())},
                    },
                }, clog.LogDiscord)
            }
        }()
        // Process single transaction
        s.ProcessTransaction(ctx, trx)
    }()
}
```

---

## 7. Key Rules

### Architecture Rules

1. **One Service Per Domain Entity**
   - `OrderService` handles order operations
   - `TransactionService` handles transaction operations
   - `NavService` handles NAV calculations
   - Never create god services

2. **Services Receive Dependencies via Constructor**
   - Primarily repositories, but other services are allowed when cross-domain coordination is needed
   - Enables dependency injection via Wire
   - Example: `OrderService` receives `JournalService` and `TransactionProcessingService`

3. **Constructor Returns Interface + Pointer**
   ```go
   func NewOrderService(...) OrderService {
       return &OrderServiceImpl{...}  // Pointer, interface return type
   }
   ```

4. **Context is Always the First Parameter**
   ```go
   func (s *OrderServiceImpl) Create(ctx context.Context, params Params) (...)
   ```

### Receiver Rules

5. **Pointer Receivers for Service Impl**
   ```go
   func (s *OrderServiceImpl) Create(...)   // Good — pointer receiver
   // NOT: func (s OrderServiceImpl) Create(...)
   ```

6. **Pointer Receivers for Params**
   ```go
   func (p *CreateOrderParams) IsMandatoryFilled() bool  // Good — pointer receiver
   // NOT: func (p CreateOrderParams) IsMandatoryFilled() bool
   ```

### Data Type Rules

7. **Use Decimal for All Monetary Values**
   ```go
   Amount decimal.Decimal  // Good — github.com/shopspring/decimal
   // NOT: Amount float64
   ```

8. **Sign Convention: Fees Are Negative**
   ```go
   fee := decimal.NewFromInt(-50)     // Negative value
   amount := decimal.NewFromInt(1000) // Positive value
   // Net = amount + fee + tax (simple addition)
   ```

### Method Design Rules

9. **Always Validate Params First**
   ```go
   if !params.IsMandatoryFilled() {
       return nil, errors.New(params.MandatorySchema()), params.MandatoryErrors()
   }
   ```

10. **Distinguish Validation from Business Rules**
    ```go
    // Business Rule: fund eligibility (ParamError)
    if fund.IsActive != 1 {
        return nil, nil, []ParamError{{Field: "fund_id", Message: "fund is inactive"}}
    }

    // Infrastructure: database (error)
    err := s.Repository.Create(ctx, fund)
    if err != nil {
        return nil, err, nil
    }
    ```

11. **Always Defer Panic Recovery**
    ```go
    defer helpers.LogAndCatchPanic()
    // First line of every exported method
    ```

12. **Never Set CreatedAt/UpdatedAt Manually**
    - Auto-managed by the Timestamp trait embedded in BaseEntity
    - Only set domain-specific datetime fields (ProcessedAt, ApprovedAt, etc.) via trait sync methods

### Code Organization Rules

13. **Method Naming Convention — NO Entity Suffix**
    - `Get(ctx, params)` — retrieve single
    - `Gets(ctx, params)` — retrieve multiple
    - `GetPaginate(ctx, params)` — paginated list
    - `Count(ctx, params)` — count query
    - `Create(ctx, params)` — create
    - `Update(ctx, params)` — update
    - `Delete(ctx, params)` — delete
    - `Process(ctx, params)` — business operation
    - `Complete(ctx, params)` — mark completed
    - `Cancel(ctx, params)` — cancel
    - `Activate(ctx, params)` / `Deactivate(ctx, params)` — toggle state
    - The service already represents the domain (OrderService), so the method name NEVER repeats it
    - Bad: `OrderService.GetOrder()` / Good: `OrderService.Get()`

14. **Parameter Struct Naming (keeps entity name)**
    - Single result: `GetOrderParams`
    - Create operation: `CreateOrderParams`
    - List operation: `GetOrdersParams` (plural)
    - Paginate: `GetOrderPaginateParams`
    - Count: `CountOrdersParams`

---

## Example: Complete Service Implementation

```go
// File: src/service/order_service_impl.go

package service

import (
    "context"
    "errors"
    "fmt"

    "yourmodule/src/helpers"
    "yourmodule/src/model/entity"
    "yourmodule/src/repository"
)

type OrderServiceImpl struct {
    Repository         repository.OrderRepository
    ItemRepository     repository.OrderItemRepository
    CategoryRepository repository.CategoryRepository
    AuditService       AuditService
}

func NewOrderService(
    repo repository.OrderRepository,
    itemRepo repository.OrderItemRepository,
    categoryRepo repository.CategoryRepository,
    auditSvc AuditService,
) OrderService {
    return &OrderServiceImpl{
        Repository:         repo,
        ItemRepository:     itemRepo,
        CategoryRepository: categoryRepo,
        AuditService:       auditSvc,
    }
}

func (s *OrderServiceImpl) Create(
    ctx context.Context,
    params CreateOrderParams,
) (*entity.Order, error, []ParamError) {
    defer helpers.LogAndCatchPanic()

    if !params.IsMandatoryFilled() {
        return nil, errors.New(params.MandatorySchema()), params.MandatoryErrors()
    }

    category, err := s.CategoryRepository.ForID(params.CategoryID).Get(ctx)
    if err != nil {
        return nil, err, nil
    }
    if category == nil {
        return nil, nil, []ParamError{{
            Field:   "category_id",
            Message: "category not found",
        }}
    }

    if category.IsActive != 1 {
        return nil, nil, []ParamError{{
            Field:   "category_id",
            Message: "category is not active",
        }}
    }

    // Do NOT set CreatedAt/UpdatedAt — auto-managed by Timestamp trait
    order := &entity.Order{
        TenantID:   params.TenantID,
        OwnerID:    params.OwnerID,
        Type:       params.Type,
        Amount:     params.Amount,
        CategoryID: params.CategoryID,
        Status:     "pending",
    }

    repo := s.Repository.StartTx(ctx)
    defer func() {
        _ = repo.RollbackTx()
    }()

    result, err := repo.Create(ctx, order)
    if err != nil {
        return nil, err, nil
    }

    if err := repo.CommitTx(); err != nil {
        return nil, err, nil
    }

    return result, nil, nil
}

func (s *OrderServiceImpl) Get(
    ctx context.Context,
    params GetOrderParams,
) (*entity.Order, error, []ParamError) {
    defer helpers.LogAndCatchPanic()

    if !params.IsMandatoryFilled() {
        return nil, errors.New(params.MandatorySchema()), params.MandatoryErrors()
    }

    r := s.Repository
    if params.ID != nil {
        r = r.ForID(*params.ID)
    }
    if params.Code != nil {
        r = r.ForCode(*params.Code)
    }

    order, err := r.Get(ctx)
    if err != nil {
        return nil, err, nil
    }

    return order, nil, nil
}

func (s *OrderServiceImpl) Gets(
    ctx context.Context,
    params GetOrdersParams,
) ([]*entity.Order, error, []ParamError) {
    defer helpers.LogAndCatchPanic()

    if !params.IsMandatoryFilled() {
        return nil, errors.New(params.MandatorySchema()), params.MandatoryErrors()
    }

    r := s.Repository
    if params.TenantID != nil {
        r = r.ForTenantID(*params.TenantID)
    }
    if params.Status != nil {
        r = r.ForStatus(*params.Status)
    }

    r = r.Order(repository.Order{Column: "created_at", Option: repository.OrderDesc})

    orders, err := r.Limit(params.GetLimit()).Offset(params.GetOffset()).Gets(ctx)
    if err != nil {
        return nil, err, nil
    }

    return orders, nil, nil
}
```

---

## 8. Anti-Patterns

| Anti-pattern | Why it breaks | Fix |
|---|---|---|
| Interface, impl, and Params combined in one file | Breaks the team layout (§3); Wire providers and reviewers expect the split; merge conflicts multiply on hot domains | Split into `x_service.go` / `x_service_impl.go` / `x_service_params.go` |
| Returning `(result, error)` instead of `(result, error, []ParamError)` | Controllers must handle validation separately from system errors; mismatching caller expectations | Always use the triple return; consolidate in `error-handling.md §1` |
| Wrapping validation errors in `error` (not `[]ParamError`) | Controller can't extract field-level detail; response code won't include field info | Return param errors as `[]ParamError`; system errors as `error` |
| Missing `defer helpers.LogAndCatchPanic()` at top of exported methods | Unrecovered panics crash the process; Supervisord restarts but you lose the stack trace | Add as the **first line** of every exported service method |
| Method name includes the entity: `GetOrder()`, `CreateOrder()` | Interface grows verbosely; callers can't swap implementations easily | Use `Get()`, `Create()`, `Gets()` — entity is implied by the service type |
| Setting `CreatedAt` / `UpdatedAt` manually | GORM manages these; manual set causes drift in audits | Never assign timestamp fields in service code |
| Missing transaction rollback `defer` | On early return (error, panic), tx never rolls back — partial write persists | `defer func() { _ = repo.RollbackTx() }()` immediately after `StartTx` |
| Committing before all repo writes are done | Race between commit and a pending repo call | Call `CommitTx()` only after ALL repo calls in the tx path succeed |
| Multi-repo transaction without `WithTx` | Second repo runs outside the transaction; partial commit on error | `s.OtherRepo.WithTx(repo.GetTx())` before any write on the second repo |
| Calling service methods from entity hooks (`BeforeCreate`, etc.) | Hooks can't receive service dependencies; creates hidden coupling | Put all business logic in services; entities only handle sign computation and field defaults |
| Not passing `ctx` to repository calls | Repository ignores cancellation; hung query blocks after client disconnects | Pass ctx through to every terminal repo call |

---

## Related References

- **Entity Patterns** (`entity-patterns.md`) — Composable traits, BaseEntity, Sign interface
- **Repository Patterns** (`repository-patterns.md`) — Fluent builder, generics, transactions
- **gRPC Patterns** (`grpc-patterns.md`) — Controller layer, transformers, response wrappers
- **Infrastructure** (`infrastructure.md`) — Event pools, database setup
- **Error Handling** (`error-handling.md`) — ParamError structure, `samber/oops` wrapping, response code matrix
