# Repository Layer Patterns — Reference Guide

**Version**: 1.0  
**Last Updated**: 2026-04-10  
**Author**: Claude  
**Purpose**: Comprehensive reference for implementing the Repository pattern in Go microservices

---

## Table of Contents

1. [Overview](#overview)
2. [Generic Base Interfaces](#1-generic-base-interfaces)
3. [Repository Interface Pattern](#2-repository-interface-pattern)
4. [Implementation Pattern](#3-implementation-pattern)
5. [Transaction Management](#4-transaction-management)
6. [Method Chaining Usage](#5-method-chaining-usage)
7. [Key Rules & Best Practices](#6-key-rules--best-practices)
8. [Anti-Patterns](#anti-patterns)

---

## Overview

The Repository pattern in this architecture uses composable generic interfaces and fluent method chaining to provide a clean, type-safe data access layer. Each entity repository combines three base interfaces with domain-specific query builders, enabling expressive queries while maintaining clear separation of concerns.

**Core Principles:**
- Query builders are fluent and chainable (return `self`)
- Execution methods always clean query state to prevent leaks
- Transactions are explicit and managed at the call site
- Generics enable code reuse across repositories
- State transitions are tracked with dated sync methods

---

## 1. Generic Base Interfaces

All repositories build on three composable generic interfaces that provide common functionality.

### BaseRepository[T] — Query Building

Provides pagination, sorting, and limit controls.

```go
type BaseRepository[T any] interface {
    // Query state management
    clean()                               // Reset whereQuery after execution
    buildQuery() *gorm.DB                // Returns tx if in transaction, else db
    
    // Pagination
    Limit(limit int) T                   // Set LIMIT
    Offset(offset int) T                 // Set OFFSET
    Page(page, limit int) T              // Calculate offset from page number
    
    // Sorting
    Order(order Order, orders ...Order) T // Set ORDER BY (chainable)
}
```

#### clean() — Resets Query State

Called via `defer` in every execution method. Prevents query conditions from leaking to the next call.

```go
func (r OrderRepositoryImpl) clean() {
    r.whereQuery = nil
}
```

#### buildQuery() — Connection Resolver

Always use this to get the active database connection. Never access `db` or `tx` fields directly.

```go
func (r OrderRepositoryImpl) buildQuery() *gorm.DB {
    if r.tx != nil {
        return r.tx  // Use transaction if in one
    }
    return r.db      // Use main connection otherwise
}
```

---

### DBTransaction[T] — Transaction Management

Provides explicit transaction control with proper error handling.

```go
type DBTransaction[T any] interface {
    // Start a new transaction (or join an existing one)
    StartTx(ctx context.Context, tx ...*gorm.DB) T
    
    // Commit the transaction
    CommitTx() error
    
    // Rollback the transaction
    RollbackTx() error
    
    // Get the current transaction handle
    GetTx() *gorm.DB
    
    // Attach to an external transaction
    WithTx(tx *gorm.DB) T
}
```

#### StartTx — Begin or Join a Transaction

Starts a new transaction on the main connection, or joins an existing one if passed as an argument.

```go
func (r OrderRepositoryImpl) StartTx(ctx context.Context, tx ...*gorm.DB) OrderRepository {
    if len(tx) > 0 && tx[0] != nil {
        // Join existing transaction
        r.tx = tx[0]
    } else {
        // Start new transaction
        r.tx = r.db.BeginTx(ctx, nil)
    }
    return r
}
```

#### CommitTx & RollbackTx — Transaction Control

```go
func (r OrderRepositoryImpl) CommitTx() error {
    if r.tx != nil {
        return r.tx.Commit().Error
    }
    return nil
}

func (r OrderRepositoryImpl) RollbackTx() error {
    if r.tx != nil {
        return r.tx.Rollback().Error
    }
    return nil
}
```

#### WithTx — Attach to External Transaction

Joins a transaction started elsewhere (common in multi-repository operations).

```go
func (r OrderRepositoryImpl) WithTx(tx *gorm.DB) OrderRepository {
    r.tx = tx
    return r
}
```

---

### SearchableRepository[T] — Text Search Support

Provides keyword search across designated columns.

```go
type SearchableRepository[T any] interface {
    // Return columns that support search
    SearchableKeys() []string
    
    // Search with LIKE across searchable columns
    Search(keyword string) T
    
    // Search with IN operator
    SearchIn(keyword string) T
    
    // Explicit LIKE search
    SearchLike(keyword string) T
}
```

#### SearchableKeys — Define Searchable Columns

```go
func (r OrderRepositoryImpl) SearchableKeys() []string {
    return []string{"order_number", "reference_code", "description"}
}
```

#### Search — LIKE Search Across Keys

```go
func (r OrderRepositoryImpl) Search(keyword string) OrderRepository {
    keys := r.SearchableKeys()
    if len(keys) == 0 {
        return r
    }
    
    query := r.buildQuery()
    for i, key := range keys {
        if i == 0 {
            query = query.Where(fmt.Sprintf("%s LIKE ?", key), "%"+keyword+"%")
        } else {
            query = query.Or(fmt.Sprintf("%s LIKE ?", key), "%"+keyword+"%")
        }
    }
    r.whereQuery = query
    return r
}
```

---

## 2. Repository Interface Pattern

Each entity repository is a custom interface that combines the three base generics plus domain-specific query builders and execution methods.

### Example: OrderRepository Interface

```go
type OrderRepository interface {
    // Embed base interfaces
    BaseRepository[OrderRepository]
    DBTransaction[OrderRepository]
    SearchableRepository[OrderRepository]
    
    // Domain-specific query builders (fluent, return self)
    ForID(id int64) OrderRepository
    ForTenantID(tenantID uint64) OrderRepository
    ForInvestorID(investorID uint64) OrderRepository
    ForStatus(status string) OrderRepository
    ForType(orderType string) OrderRepository
    ForDateRange(start, end time.Time) OrderRepository
    
    // Execution methods (clean query state after)
    Get(ctx context.Context) (*entity.Order, error)
    Gets(ctx context.Context) ([]*entity.Order, error)
    GetPaginate(ctx context.Context) ([]*entity.Order, int64, error)
    Count(ctx context.Context) (int64, error)
    Create(ctx context.Context, order *entity.Order) (*entity.Order, error)
    Update(ctx context.Context, order *entity.Order) (*entity.Order, error)
    Delete(ctx context.Context, order *entity.Order) error
    
    // State transition methods
    Process(ctx context.Context, order *entity.Order) (*entity.Order, error)
    Complete(ctx context.Context, order *entity.Order) (*entity.Order, error)
    Fail(ctx context.Context, order *entity.Order) (*entity.Order, error)
    Cancel(ctx context.Context, order *entity.Order) (*entity.Order, error)
}
```

### Query Builder Methods (For*)

All query builders should:
- Use the `For` prefix (e.g., `ForID`, `ForStatus`, `ForTenantID`)
- Return the repository interface for chaining
- Check if `whereQuery` already exists before adding conditions
- Use value receivers so each method returns a new copy with accumulated conditions

**Single Condition:**
```go
func (r OrderRepositoryImpl) ForID(id int64) OrderRepository {
    r.whereQuery = r.buildQuery().Where("id = ?", id)
    return r
}
```

**Multiple Conditions (OR/AND chaining):**
```go
func (r OrderRepositoryImpl) ForTenantID(tenantID uint64) OrderRepository {
    if r.whereQuery != nil {
        r.whereQuery = r.whereQuery.Where("tenant_id = ?", tenantID)
    } else {
        r.whereQuery = r.buildQuery().Where("tenant_id = ?", tenantID)
    }
    return r
}

func (r OrderRepositoryImpl) ForStatus(status string) OrderRepository {
    if r.whereQuery != nil {
        r.whereQuery = r.whereQuery.Where("status = ?", status)
    } else {
        r.whereQuery = r.buildQuery().Where("status = ?", status)
    }
    return r
}
```

---

## 3. Implementation Pattern

### File Structure

Each domain entity gets **two files** — interface and implementation are never combined:

```
src/repository/
├── order_repository.go        # Interface: embedded base generics + For* builders + execution methods
└── order_repository_impl.go   # Implementation: struct, constructor, all methods
```

Shared generic bases (`BaseRepository[T]`, `DBTransaction[T]`, `SearchableRepository[T]`) live in `src/repository/repository.go`. When adding a query builder or execution method, update **both** files — never declare a new interface method only on the impl, and never inline the interface into `*_impl.go`.

Every repository implementation follows the same three-field structure.

### Struct Definition

```go
type OrderRepositoryImpl struct {
    db         *gorm.DB  // Main database connection (initialized via Wire)
    tx         *gorm.DB  // Transaction connection (nil if not in transaction)
    whereQuery *gorm.DB  // Accumulated query conditions
}
```

### Constructor

Always return the **interface**, not the concrete struct.

```go
func NewOrderRepository(db *gorm.DB) OrderRepository {
    return OrderRepositoryImpl{db: db}
}
```

### Query State Management

Every field serves a specific purpose:

| Field | Purpose | When Set |
|-------|---------|----------|
| `db` | Main database connection | Constructor |
| `tx` | Active transaction (if any) | `StartTx()` or `WithTx()` |
| `whereQuery` | Accumulated WHERE clauses | Query builder methods (`ForID`, `ForStatus`, etc.) |

---

### Fluent For* Methods — Detailed Examples

#### Simple ForID with Single Condition

```go
func (r OrderRepositoryImpl) ForID(id int64) OrderRepository {
    r.whereQuery = r.buildQuery().Where("id = ?", id)
    return r
}
```

#### Chaining Multiple ForTenantID Conditions

```go
func (r OrderRepositoryImpl) ForTenantID(tenantID uint64) OrderRepository {
    if r.whereQuery != nil {
        // Append to existing conditions
        r.whereQuery = r.whereQuery.Where("tenant_id = ?", tenantID)
    } else {
        // Start new query
        r.whereQuery = r.buildQuery().Where("tenant_id = ?", tenantID)
    }
    return r
}
```

#### Date Range Query

```go
func (r OrderRepositoryImpl) ForDateRange(start, end time.Time) OrderRepository {
    if r.whereQuery != nil {
        r.whereQuery = r.whereQuery.Where("created_at BETWEEN ? AND ?", start, end)
    } else {
        r.whereQuery = r.buildQuery().Where("created_at BETWEEN ? AND ?", start, end)
    }
    return r
}
```

---

### Execution Methods — CRITICAL: Always defer clean()

Every execution method (`Get`, `Gets`, `Create`, etc.) **MUST** defer `clean()` at the start. Without this, query conditions leak to the next call on the same repository instance.

#### Get — Single Entity

```go
func (r OrderRepositoryImpl) Get(ctx context.Context) (*entity.Order, error) {
    defer r.clean()  // CRITICAL: Always clean on exit
    
    var result entity.Order
    query := r.whereQuery
    if query == nil {
        query = r.buildQuery()
    }
    
    err := query.WithContext(ctx).First(&result).Error
    if err != nil {
        return nil, err
    }
    return &result, nil
}
```

#### Gets — All Entities Matching Conditions

```go
func (r OrderRepositoryImpl) Gets(ctx context.Context) ([]*entity.Order, error) {
    defer r.clean()  // CRITICAL: Always clean on exit
    
    var results []*entity.Order
    query := r.whereQuery
    if query == nil {
        query = r.buildQuery()
    }
    
    err := query.WithContext(ctx).Find(&results).Error
    return results, err
}
```

#### GetPaginate — Entities with Count

Returns results, total count, and error.

```go
func (r OrderRepositoryImpl) GetPaginate(ctx context.Context) ([]*entity.Order, int64, error) {
    defer r.clean()  // CRITICAL: Always clean on exit
    
    var results []*entity.Order
    var total int64
    query := r.whereQuery
    if query == nil {
        query = r.buildQuery()
    }
    
    // Count total before applying limit/offset
    countErr := query.WithContext(ctx).Model(&entity.Order{}).Count(&total).Error
    if countErr != nil {
        return nil, 0, countErr
    }
    
    // Fetch paginated results
    err := query.WithContext(ctx).Find(&results).Error
    return results, total, err
}
```

#### Count — Row Count

```go
func (r OrderRepositoryImpl) Count(ctx context.Context) (int64, error) {
    defer r.clean()  // CRITICAL: Always clean on exit
    
    var total int64
    query := r.whereQuery
    if query == nil {
        query = r.buildQuery()
    }
    
    err := query.WithContext(ctx).Model(&entity.Order{}).Count(&total).Error
    return total, err
}
```

#### Create — Insert New Entity

```go
func (r OrderRepositoryImpl) Create(ctx context.Context, order *entity.Order) (*entity.Order, error) {
    defer r.clean()  // CRITICAL: Always clean on exit
    
    if order == nil {
        return nil, errors.New("order cannot be nil")
    }
    
    err := r.buildQuery().WithContext(ctx).Create(order).Error
    if err != nil {
        return nil, err
    }
    
    return order, nil
}
```

#### Update — Modify Existing Entity

```go
func (r OrderRepositoryImpl) Update(ctx context.Context, order *entity.Order) (*entity.Order, error) {
    defer r.clean()  // CRITICAL: Always clean on exit
    
    if order == nil {
        return nil, errors.New("order cannot be nil")
    }
    
    err := r.buildQuery().WithContext(ctx).Save(order).Error
    if err != nil {
        return nil, err
    }
    
    return order, nil
}
```

#### Delete — Remove Entity

```go
func (r OrderRepositoryImpl) Delete(ctx context.Context, order *entity.Order) error {
    defer r.clean()  // CRITICAL: Always clean on exit
    
    if order == nil {
        return errors.New("order cannot be nil")
    }
    
    return r.buildQuery().WithContext(ctx).Delete(order).Error
}
```

---

### State Transition Methods

State transition methods update the entity's status field and call its sync method (e.g., `SyncProcessedDate()` if the entity has a `ProcessedDate` trait).

#### Process Transition

```go
func (r OrderRepositoryImpl) Process(ctx context.Context, order *entity.Order) (*entity.Order, error) {
    defer r.clean()  // CRITICAL: Always clean on exit
    
    if order == nil {
        return nil, errors.New("order cannot be nil")
    }
    
    // Update status
    order.Status = "processing"
    
    // Sync any date fields that track this transition
    if syncable, ok := interface{}(order).(interface{ SyncProcessedDate() }); ok {
        syncable.SyncProcessedDate()
    }
    
    // Save and return
    err := r.buildQuery().WithContext(ctx).Save(order).Error
    return order, err
}
```

#### Complete Transition

```go
func (r OrderRepositoryImpl) Complete(ctx context.Context, order *entity.Order) (*entity.Order, error) {
    defer r.clean()  // CRITICAL: Always clean on exit
    
    if order == nil {
        return nil, errors.New("order cannot be nil")
    }
    
    order.Status = "completed"
    
    if syncable, ok := interface{}(order).(interface{ SyncCompletedDate() }); ok {
        syncable.SyncCompletedDate()
    }
    
    err := r.buildQuery().WithContext(ctx).Save(order).Error
    return order, err
}
```

#### Fail Transition

```go
func (r OrderRepositoryImpl) Fail(ctx context.Context, order *entity.Order) (*entity.Order, error) {
    defer r.clean()  // CRITICAL: Always clean on exit
    
    if order == nil {
        return nil, errors.New("order cannot be nil")
    }
    
    order.Status = "failed"
    
    if syncable, ok := interface{}(order).(interface{ SyncFailedDate() }); ok {
        syncable.SyncFailedDate()
    }
    
    err := r.buildQuery().WithContext(ctx).Save(order).Error
    return order, err
}
```

#### Cancel Transition

```go
func (r OrderRepositoryImpl) Cancel(ctx context.Context, order *entity.Order) (*entity.Order, error) {
    defer r.clean()  // CRITICAL: Always clean on exit
    
    if order == nil {
        return nil, errors.New("order cannot be nil")
    }
    
    order.Status = "cancelled"
    
    if syncable, ok := interface{}(order).(interface{ SyncCancelledDate() }); ok {
        syncable.SyncCancelledDate()
    }
    
    err := r.buildQuery().WithContext(ctx).Save(order).Error
    return order, err
}
```

---

## 4. Transaction Management

Transactions are explicit and managed at the call site. This pattern ensures clear error handling and resource cleanup.

### Standard Transaction Pattern

Use `defer` to ensure cleanup even if an error occurs:

```go
// Get repositories
orderRepo := repositories.OrderRepository
transactionRepo := repositories.TransactionRepository

// Start transaction on first repository
orderRepo = orderRepo.StartTx(ctx)

// Attach second repository to same transaction
transactionRepo = transactionRepo.WithTx(orderRepo.GetTx())

// Defer cleanup
defer func() {
    if err != nil {
        orderRepo.RollbackTx()
    } else {
        orderRepo.CommitTx()
    }
}()

// Both operations use the same transaction
order, err = orderRepo.Create(ctx, order)
if err != nil {
    return nil, err
}

trx, err = transactionRepo.Create(ctx, transaction)
if err != nil {
    return nil, err
}

return order, nil
```

### Multi-Step Transaction Example

```go
func (s *OrderServiceImpl) ProcessMultipleOrders(ctx context.Context, orderIDs []int64) error {
    // Start transaction
    repo := s.orderRepo.StartTx(ctx)
    defer func() {
        if err != nil {
            repo.RollbackTx()
        } else {
            repo.CommitTx()
        }
    }()
    
    for _, id := range orderIDs {
        order, err := repo.ForID(id).Get(ctx)
        if err != nil {
            return err
        }
        
        // Process the order
        order, err = repo.Process(ctx, order)
        if err != nil {
            return err
        }
    }
    
    return nil
}
```

### Nested Transaction Support

When passing transactions between repositories:

```go
func (s *OrderServiceImpl) CreateOrderWithTransactions(ctx context.Context, order *Order) error {
    // Start transaction
    orderRepo := s.orderRepo.StartTx(ctx)
    defer func() {
        if err != nil {
            orderRepo.RollbackTx()
        } else {
            orderRepo.CommitTx()
        }
    }()
    
    // Create order
    createdOrder, err := orderRepo.Create(ctx, order)
    if err != nil {
        return err
    }
    
    // Use same transaction for transactions
    txRepo := s.transactionRepo.WithTx(orderRepo.GetTx())
    
    for _, tx := range order.Transactions {
        tx.OrderID = createdOrder.ID
        _, err = txRepo.Create(ctx, tx)
        if err != nil {
            return err
        }
    }
    
    return nil
}
```

---

## 5. Method Chaining Usage

The fluent interface enables readable, chainable query building.

### Single Entity Lookup

```go
order, err := orderRepo.
    ForID(123).
    Get(ctx)
```

### Filtered List with Pagination

```go
orders, total, err := orderRepo.
    ForTenantID(tenantID).
    ForStatus("pending").
    ForType("subscription").
    Order(repository.OrderDesc("created_at")).
    Page(1, 20).
    GetPaginate(ctx)
```

### Filtering with Date Range

```go
orders, err := orderRepo.
    ForTenantID(tenantID).
    ForDateRange(startDate, endDate).
    Order(repository.OrderAsc("created_at")).
    Gets(ctx)
```

### Text Search

```go
orders, err := orderRepo.
    ForTenantID(tenantID).
    Search("ACME Corp").
    Limit(50).
    Gets(ctx)
```

### Count with Filters

```go
count, err := orderRepo.
    ForStatus("processing").
    ForTenantID(tenantID).
    Count(ctx)
```

### Complex Multi-Condition Query

```go
orders, total, err := orderRepo.
    ForTenantID(tenantID).
    ForStatus("pending").
    ForDateRange(startDate, endDate).
    Search(keyword).
    Order(repository.OrderDesc("created_at")).
    Limit(25).
    Offset(0).
    GetPaginate(ctx)
```

---

## 6. Key Rules & Best Practices

### CRITICAL Rules

1. **Every execution method MUST `defer r.clean()`**
   - Without this, query conditions leak to the next call on the same instance
   - This is the most common source of bugs in repository patterns
   - Always add it as the first line of the execution method

2. **Use `buildQuery()` instead of accessing `db` or `tx` directly**
   - This ensures the correct connection (main or transaction) is used
   - Never write `r.db.Where(...)` — always write `r.buildQuery().Where(...)`

3. **Query builders return the repository interface for chaining**
   - Methods like `ForID`, `ForStatus`, etc. must return `self` (the repository)
   - This enables method chaining: `repo.ForID(1).ForStatus("active").Get(ctx)`

4. **Constructor returns the interface, not the struct**
   ```go
   func NewOrderRepository(db *gorm.DB) OrderRepository {
       return OrderRepositoryImpl{db: db}  // Returns interface, not struct
   }
   ```

### Best Practices

- **Pagination:** Use `Page(1, 20)` instead of manually calculating `Offset(0).Limit(20)`
- **Ordering:** Always provide sort order for predictable results; chain `Order()` before pagination
- **Context:** Always pass `ctx` to execution methods for timeout support and cancellation
- **Nil Checks:** Check for nil entities in Create/Update/Delete to prevent panics
- **Error Handling:** Propagate repository errors up to services; don't swallow them
- **Transaction Cleanup:** Always use `defer` for transaction cleanup; never rely on implicit cleanup
- **Query State:** Reset `whereQuery` in `clean()`; don't manually reset it

### Naming Conventions

| Category | Pattern | Example |
|----------|---------|---------|
| Interface | PascalCase | `OrderRepository` |
| Struct | `[Name]Impl` | `OrderRepositoryImpl` |
| Query builders | `For[Field]` | `ForID`, `ForStatus`, `ForTenantID` |
| Execution methods | Verb first | `Get`, `Gets`, `Create`, `Update`, `Delete` |
| Transitions | `[Verb]` | `Process`, `Complete`, `Fail`, `Cancel` |
| Generics | `[T]` | `BaseRepository[T]` |

## Anti-Patterns

❌ **DON'T:** Combine interface and implementation in one file
```go
// Wrong — order_repository.go containing both the interface AND OrderRepositoryImpl
```

✅ **DO:** Split per the file structure (§3)
```go
// Correct — order_repository.go (interface) + order_repository_impl.go (impl)
```

---

❌ **DON'T:** Access `db` or `tx` directly
```go
// Wrong
err := r.db.Where("id = ?", id).First(&order).Error
```

✅ **DO:** Use `buildQuery()`
```go
// Correct
err := r.buildQuery().Where("id = ?", id).First(&order).Error
```

---

❌ **DON'T:** Forget to defer clean()
```go
// Wrong
func (r OrderRepositoryImpl) Get(ctx context.Context) (*entity.Order, error) {
    var result entity.Order
    err := r.whereQuery.WithContext(ctx).First(&result).Error
    return &result, err  // Query state never cleaned!
}
```

✅ **DO:** Always defer clean()
```go
// Correct
func (r OrderRepositoryImpl) Get(ctx context.Context) (*entity.Order, error) {
    defer r.clean()
    var result entity.Order
    query := r.whereQuery
    if query == nil {
        query = r.buildQuery()
    }
    err := query.WithContext(ctx).First(&result).Error
    return &result, err
}
```

---

❌ **DON'T:** Return concrete types from constructors
```go
// Wrong
func NewOrderRepository(db *gorm.DB) *OrderRepositoryImpl {
    return &OrderRepositoryImpl{db: db}
}
```

✅ **DO:** Return interfaces
```go
// Correct
func NewOrderRepository(db *gorm.DB) OrderRepository {
    return OrderRepositoryImpl{db: db}
}
```

---

❌ **DON'T:** Manually manage transaction cleanup
```go
// Wrong
repo = repo.StartTx(ctx)
order, _ := repo.Create(ctx, order)
if err != nil {
    repo.RollbackTx()  // Easy to forget!
}
repo.CommitTx()
```

✅ **DO:** Use defer for guaranteed cleanup
```go
// Correct
repo = repo.StartTx(ctx)
defer func() {
    if err != nil {
        repo.RollbackTx()
    } else {
        repo.CommitTx()
    }
}()
order, err := repo.Create(ctx, order)
```

---

---

❌ **DON'T:** Use raw `db.Where(...)` instead of `For*` fluent methods
```go
// Wrong — bypasses the fluent chain, no clean(), no buildQuery()
orders, _ := r.db.Where("status = ? AND tenant_id = ?", "pending", tenantID).Find(&orders).Error
```

✅ **DO:** Use fluent `For*` builders and let `buildQuery()` resolve db/tx
```go
orders, err := r.ForTenant(tenantID).ForStatus("pending").Gets(ctx)
```

---

❌ **DON'T:** Ignore the `nil` return from `Get` (not-found case)
```go
// Wrong — order may be nil if not found; dereferencing panics
order, _ := r.ForID(id).Get(ctx)
doSomething(order.ID)   // panic if not found
```

✅ **DO:** Check for nil before using the result
```go
order, err := r.ForID(id).Get(ctx)
if err != nil {
    return nil, err
}
if order == nil {
    return nil, nil  // caller turns this into a ParamError
}
```

---

## Summary

The repository pattern in this architecture provides:

- **Type Safety**: Generic interfaces and domain-specific implementations
- **Fluent API**: Chainable query builders for readable code
- **Explicit Transactions**: Clear transaction management at the call site
- **Separation of Concerns**: Data access logic isolated in repositories
- **Reusability**: Base interfaces shared across all repositories
- **Maintainability**: Consistent patterns across the codebase

Follow the patterns in this guide, especially the critical rules about `defer r.clean()` and using `buildQuery()`, and your repositories will be robust, testable, and maintainable.

---

## Related References

- → `references/entity-patterns.md` — entity struct definitions, trait composition, field types
- → `references/service-patterns.md §5` — transaction management patterns (`StartTx`/`CommitTx`/`RollbackTx`)
- → `references/infrastructure.md §1` — GORM/MySQL connection setup, pool config, `SkipDefaultTransaction`
- → `references/context-patterns.md §2` — how ctx flows through the fluent builder to terminal methods
- → `references/testing.md §7` — repository integration test patterns with testcontainers
