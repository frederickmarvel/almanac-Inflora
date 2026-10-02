# Testing Patterns Reference

## Table of Contents

1. [Test Organization](#1-test-organization)
2. [Manual Mocks with testify](#2-manual-mocks-with-testify)
3. [Table-Driven Tests](#3-table-driven-tests)
4. [Testing the Triple Return](#4-testing-the-triple-return)
5. [Controller Layer Tests](#5-controller-layer-tests)
6. [Service Layer Tests](#6-service-layer-tests)
7. [Repository Layer Tests](#7-repository-layer-tests)
8. [Integration Tests](#8-integration-tests)
9. [Performance Benchmarks](#9-performance-benchmarks)
10. [Test Fixtures & Factories](#10-test-fixtures--factories)
11. [Running Tests](#11-running-tests)
12. [Anti-Patterns](#12-anti-patterns)
13. [Related References](#13-related-references)

---

## 1. Test Organization

Tests live in a **separate `test/` directory** to avoid import cycles with internal packages.

> **Placement rule — this intentionally overrides the Go idiom.** In generic Go projects, `order_service_test.go` sits next to `order_service.go`. **Not in this stack.** Never create `*_test.go` adjacent to source in `src/` or `engine/` — ALL tests (unit, integration, benchmark) go under `test/{layer}/`. Why the team chose centralized:
>
> 1. **Black-box by construction** — `package service_test` in `test/service/` can only touch exported API, so tests exercise the same surface controllers and Wire see. Unexported helpers get covered through the exported methods that use them; if one can't be reached that way, it's dead code or belongs in the interface.
> 2. **Shared fixtures without cycles** — `test/fixtures/` is imported by every layer's tests; adjacent tests would each need their own copies or create `src/ → fixtures → src/` cycles.
> 3. **Clean `src/`** — production tree stays free of mocks and test noise; reviewers diff business logic without test churn mixed in.
>
> **Consequence you must remember:** coverage needs `-coverpkg`. A plain `go test -cover ./test/...` measures the test packages themselves (≈0%). Use `go test -coverpkg=./src/... -coverprofile=coverage.out ./test/...`.

```
test/
├── grpc/                    # Controller-layer tests (gRPC)
│   ├── order_test.go
│   └── transaction_test.go
├── service/                 # Service-layer tests
│   ├── order_service_test.go
│   └── transaction_service_test.go
├── repository/              # Repository-layer tests (optional, usually integration)
│   └── order_repository_test.go
├── integration/             # Full-stack integration tests
│   └── order_flow_test.go
└── fixtures/                # Shared test data factories
    ├── order.go
    └── user.go
```

**Package naming convention:**

| Layer | Package name |
|-------|-------------|
| Controller tests | `controller_test` |
| Service tests | `service_test` |
| Repository tests | `repository_test` |
| Integration tests | `integration_test` |

**File naming:** `Test[Component]_[Method]_[Scenario]` — e.g., `TestOrderController_Create_Success`

**Build tags (optional):**

```go
//go:build grpc_legacy
// +build grpc_legacy

package controller_test
```

Use build tags to isolate tests that require a running DB, external service, or specific binary (e.g., `integration`, `e2e`, `race`).

---

## 2. Manual Mocks with testify

The codebase uses **hand-written mock structs** implementing interfaces via `testify/mock`. No code generation (gomock, mockery) is used — generated mocks drift from the real interface over time without enforcement.

**Mock definition:**

```go
// Defined inline at the top of each test file (or in test/fixtures/ if shared)
type MockOrderService struct {
    mock.Mock
}

// Match the interface signature EXACTLY — all three return values.
func (m *MockOrderService) Create(
    ctx context.Context,
    params service.CreateOrderParams,
) (*entity.Order, error, []service.ParamError) {
    args := m.Called(ctx, params)

    var result *entity.Order
    if args.Get(0) != nil {
        result = args.Get(0).(*entity.Order)
    }
    var paramErrs []service.ParamError
    if args.Get(2) != nil {
        paramErrs = args.Get(2).([]service.ParamError)
    }
    return result, args.Error(1), paramErrs
}
```

**If the mock doesn't match the interface signature exactly**, the compiler rejects it — this is intentional. Do not use `interface{}` shortcuts.

---

## 3. Table-Driven Tests

Every test function **must** use table-driven tests. Use `[]struct` with a `name` field and a `setupMock` function to keep each case self-contained and independent.

```go
func TestOrderService_Create(t *testing.T) {
    tests := []struct {
        name      string
        params    service.CreateOrderParams
        setupMock func(*MockOrderRepo)
        wantOrder bool
        wantErr   bool
        wantParam bool
    }{
        {
            name: "success",
            params: service.CreateOrderParams{
                TenantID: 1,
                ItemID:   42,
                Amount:   decimal.NewFromString("100.00"),
            },
            setupMock: func(repo *MockOrderRepo) {
                repo.On("Create", mock.Anything, mock.AnythingOfType("*entity.Order")).
                    Return(&entity.Order{}, nil)
            },
            wantOrder: true,
        },
        {
            name: "missing amount",
            params: service.CreateOrderParams{TenantID: 1},
            setupMock: func(repo *MockOrderRepo) {
                // No repo call expected — validation fails before reaching repo
            },
            wantParam: true,
        },
        {
            name: "db error",
            params: service.CreateOrderParams{TenantID: 1, Amount: decimal.NewFromString("100.00")},
            setupMock: func(repo *MockOrderRepo) {
                repo.On("Create", mock.Anything, mock.Anything).
                    Return(nil, errors.New("connection reset"))
            },
            wantErr: true,
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            repo := new(MockOrderRepo)
            tt.setupMock(repo)

            svc := service.NewOrderService(repo)
            ctx := context.WithValue(context.Background(), "tenant_id_test", uint64(1))

            result, err, paramErrs := svc.Create(ctx, tt.params)

            assert.Equal(t, tt.wantOrder, result != nil)
            assert.Equal(t, tt.wantErr, err != nil)
            assert.Equal(t, tt.wantParam, len(paramErrs) > 0)

            repo.AssertExpectations(t)
        })
    }
}
```

---

## 4. Testing the Triple Return

Services return `(result, error, []ParamError)`. **All three must be asserted** in every test case.

| Scenario | result | error | paramErrs |
|----------|--------|-------|-----------|
| Success | non-nil | nil | nil |
| Validation failure | nil | nil | non-empty |
| System error (DB, network) | nil | non-nil | nil |
| Partial success (warn) | non-nil | nil | non-empty (rare) |

```go
// Success
result, err, paramErrs := svc.Create(ctx, validParams)
assert.NotNil(t, result)
assert.NoError(t, err)
assert.Nil(t, paramErrs)

// Validation error (NOT system error)
result, err, paramErrs = svc.Create(ctx, invalidParams)
assert.Nil(t, result)
assert.NoError(t, err)           // no system error
assert.NotEmpty(t, paramErrs)    // param errors present
assert.Equal(t, "amount", paramErrs[0].Field)

// System error
result, err, paramErrs = svc.Create(ctx, paramsDBDown)
assert.Nil(t, result)
assert.Error(t, err)
assert.Nil(t, paramErrs)
```

---

## 5. Controller Layer Tests

Controllers translate gRPC request → service call → response envelope. Test the translation logic, not the business logic (that belongs in service tests).

**What to verify:**
- Proto request → `Params` mapping is correct
- Service errors map to the right response code + status false
- ParamErrors appear in the response envelope
- Response envelope fields (`Status`, `Code`, `Message`) match expectations

```go
func TestOrderController_Create(t *testing.T) {
    tests := []struct {
        name        string
        req         *adminv1.CreateOrderReqRPC
        setupMock   func(*MockOrderService)
        wantStatus  bool
        wantCode    string
    }{
        {
            name: "success",
            req:  &adminv1.CreateOrderReqRPC{TenantId: proto.Uint64(1), Amount: "100.00"},
            setupMock: func(svc *MockOrderService) {
                order := &entity.Order{BaseEntitySF: entity.BaseEntitySF{ID: 99}}
                svc.On("Create", mock.Anything, mock.AnythingOfType("CreateOrderParams")).
                    Return(order, nil, nil)
            },
            wantStatus: true,
            wantCode:   "",  // no code on success
        },
        {
            name: "param error from service",
            req:  &adminv1.CreateOrderReqRPC{TenantId: proto.Uint64(1)},
            setupMock: func(svc *MockOrderService) {
                svc.On("Create", mock.Anything, mock.Anything).
                    Return(nil, nil, []service.ParamError{{Field: "amount", Message: "required"}})
            },
            wantStatus: false,
            wantCode:   "A-ORD-E-CRT-001",
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            svc := new(MockOrderService)
            tt.setupMock(svc)

            ctrl := controller.NewOrderController(svc, validator.New(), transformer.NewOrderTransformer())
            resp, err := ctrl.Create(context.Background(), tt.req)

            require.NoError(t, err)  // gRPC-level error should be nil (business errors go in envelope)
            assert.Equal(t, tt.wantStatus, resp.GetStatus())
            if tt.wantCode != "" {
                assert.Equal(t, tt.wantCode, resp.GetCode())
            }

            svc.AssertExpectations(t)
        })
    }
}
```

---

## 6. Service Layer Tests

Service tests mock the **repository layer** only. Never mock the database directly in service tests — mock the repository interface.

**What to verify:**
- Params validation (`IsMandatoryFilled`, `MandatoryErrors`)
- Entity construction (correct field mapping, trait calls)
- Repository calls (correct arguments, called once or not at all)
- Transaction flow (commit on success, rollback on error)
- Triple return semantics

```go
func TestOrderService_Cancel(t *testing.T) {
    tests := []struct {
        name      string
        params    service.CancelOrderParams
        setupMock func(*MockOrderRepo)
        wantErr   bool
        wantParam bool
    }{
        {
            name:   "success — order moved to cancelled",
            params: service.CancelOrderParams{ID: 1, TenantID: 1, Reason: "user request"},
            setupMock: func(repo *MockOrderRepo) {
                order := &entity.Order{Status: "pending"}
                repo.On("ForTenant", uint64(1)).Return(repo)
                repo.On("ForID", uint64(1)).Return(repo)
                repo.On("Get", mock.Anything).Return(order, nil)
                repo.On("Cancel", mock.Anything, mock.AnythingOfType("*entity.Order")).Return(nil)
            },
        },
        {
            name:   "not found → param error, not system error",
            params: service.CancelOrderParams{ID: 99, TenantID: 1},
            setupMock: func(repo *MockOrderRepo) {
                repo.On("ForTenant", uint64(1)).Return(repo)
                repo.On("ForID", uint64(99)).Return(repo)
                repo.On("Get", mock.Anything).Return(nil, nil)  // nil = not found
            },
            wantParam: true,
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            repo := new(MockOrderRepo)
            tt.setupMock(repo)
            svc := service.NewOrderService(repo)

            ctx := helpers.WithTenantID(context.Background(), tt.params.TenantID)
            result, err, paramErrs := svc.Cancel(ctx, tt.params)

            assert.Equal(t, tt.wantErr, err != nil)
            assert.Equal(t, tt.wantParam, len(paramErrs) > 0)
            if !tt.wantErr && !tt.wantParam {
                assert.NotNil(t, result)
            }
            repo.AssertExpectations(t)
        })
    }
}
```

---

## 7. Repository Layer Tests

Repository tests are the one layer where testing against a real database is preferred — mocking GORM produces false confidence. Use `testcontainers-go` or a pre-seeded test DB.

**Option A — testcontainers-go (preferred for CI):**

```go
//go:build integration

package repository_test

import (
    "context"
    "testing"
    "github.com/testcontainers/testcontainers-go/modules/mysql"
)

func setupTestDB(t *testing.T) *gorm.DB {
    t.Helper()
    ctx := context.Background()

    container, err := mysql.RunContainer(ctx,
        testcontainers.WithImage("mysql:8.0"),
        mysql.WithDatabase("testdb"),
        mysql.WithUsername("root"),
        mysql.WithPassword("password"),
    )
    require.NoError(t, err)
    t.Cleanup(func() { container.Terminate(ctx) })

    dsn, _ := container.ConnectionString(ctx, "parseTime=true")
    db, err := gorm.Open(gormmysql.Open(dsn), &gorm.Config{})
    require.NoError(t, err)

    db.AutoMigrate(&entity.Order{})
    return db
}

func TestOrderRepository_Get(t *testing.T) {
    db := setupTestDB(t)
    repo := repository.NewOrderRepository(db)

    // Seed
    order := &entity.Order{TenantID: 1, Status: "pending"}
    db.Create(order)

    tests := []struct {
        name     string
        tenantID uint64
        id       uint64
        wantNil  bool
    }{
        {"found", 1, order.ID, false},
        {"wrong tenant", 2, order.ID, true},  // multi-tenant isolation check
        {"not found", 1, 99999, true},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            result, err := repo.ForTenant(tt.tenantID).ForID(tt.id).Get(context.Background())
            assert.NoError(t, err)
            assert.Equal(t, tt.wantNil, result == nil)
        })
    }
}
```

**Option B — shared test DB (faster, less isolated):**

Configure a dedicated `TEST_DB_DSN` env var pointing to a local MySQL instance with a `_test` suffix database. Run migrations with `goose up` before the test suite.

**What to verify in repository tests:**
- Multi-tenant isolation: `ForTenant(1)` never returns tenant 2's data
- Fluent builder state reset: two calls on the same repo instance don't leak filters
- `defer r.clean()` effectiveness: query state cleared after execution
- Transaction rollback: `RollbackTx()` reverts changes

---

## 8. Integration Tests

Integration tests exercise the full stack (controller → service → repository → DB) without mocking. Tag them `integration` so they don't run in unit test suites.

```go
//go:build integration

package integration_test

func TestOrderFlow_CreateAndCancel(t *testing.T) {
    // Boot the full dependency graph via Wire or manual construction
    db := setupTestDB(t)
    repo := repository.NewOrderRepository(db)
    svc := service.NewOrderService(repo)
    ctrl := controller.NewOrderController(svc, validator.New(), transformer.NewOrderTransformer())

    ctx := helpers.WithTenantID(context.Background(), 1)

    // Create
    createResp, err := ctrl.Create(ctx, &adminv1.CreateOrderReqRPC{
        TenantId: proto.Uint64(1),
        Amount:   "500.00",
    })
    require.NoError(t, err)
    require.True(t, createResp.GetStatus())
    orderID := createResp.GetData().GetId()

    // Cancel
    cancelResp, err := ctrl.Cancel(ctx, &adminv1.CancelOrderReqRPC{
        TenantId: proto.Uint64(1),
        Id:       &orderID,
        Reason:   "integration test teardown",
    })
    require.NoError(t, err)
    require.True(t, cancelResp.GetStatus())
}
```

---

## 9. Performance Benchmarks

Use Go's built-in `testing.B` for performance benchmarks. Run with `-bench` and compare with `benchstat`.

```go
func BenchmarkOrderService_Get(b *testing.B) {
    db := setupBenchDB(b)
    repo := repository.NewOrderRepository(db)
    svc := service.NewOrderService(repo)

    // Seed 1000 orders
    for i := range 1000 {
        db.Create(&entity.Order{TenantID: 1, Amount: decimal.NewFromInt(int64(i))})
    }

    ctx := helpers.WithTenantID(context.Background(), 1)
    params := service.GetOrderParams{ID: 1}

    b.ResetTimer()
    b.ReportAllocs()

    for b.N > 0 {
        _, _, _ = svc.Get(ctx, params)
        b.N--
    }
}
```

**Run and compare:**

```bash
# Baseline
go test -bench=BenchmarkOrderService_Get -benchmem -count=5 ./test/... > old.txt

# After change
go test -bench=BenchmarkOrderService_Get -benchmem -count=5 ./test/... > new.txt

benchstat old.txt new.txt
```

See `references/performance.md §2` for the full profile-before-optimize workflow.

---

## 10. Test Fixtures & Factories

Shared fixtures live in `test/fixtures/`. Each factory returns a ready-to-use entity with sensible defaults that can be overridden.

```go
// test/fixtures/order.go
package fixtures

import (
    "github.com/shopspring/decimal"
    "your-module/src/model/entity"
)

type OrderOption func(*entity.Order)

func WithOrderStatus(s string) OrderOption {
    return func(o *entity.Order) { o.Status = s }
}

func WithOrderAmount(a string) OrderOption {
    return func(o *entity.Order) { o.Amount = decimal.RequireFromString(a) }
}

func NewOrder(opts ...OrderOption) *entity.Order {
    o := &entity.Order{
        TenantID: 1,
        Status:   "pending",
        Amount:   decimal.NewFromInt(100),
    }
    for _, opt := range opts {
        opt(o)
    }
    return o
}
```

**Usage:**

```go
order := fixtures.NewOrder(
    fixtures.WithOrderStatus("completed"),
    fixtures.WithOrderAmount("9999.99"),
)
```

---

## 11. Running Tests

```bash
# All unit tests
go test ./test/...

# By layer
go test ./test/grpc/...
go test ./test/service/...

# Single test
go test -v ./test/grpc/ -run TestOrderController_Create

# With build tags
go test -tags=integration ./test/...

# Race detector (mandatory in CI — see concurrency-patterns.md §14)
go test -race ./test/...

# With coverage — MUST use -coverpkg (plain -cover on test/ packages reports ~0%)
go test -coverpkg=./src/... -coverprofile=coverage.out ./test/...
go tool cover -html=coverage.out
```

---

## 12. Anti-Patterns

| Anti-pattern | Why it breaks | Fix |
|---|---|---|
| Placing `_test.go` next to the source file (`src/service/order_service_test.go`) | Violates the team layout (§1); grants white-box access to layers meant to be tested black-box; fixtures get duplicated per package | Move to `test/{layer}/` with `package *_test`; import the package under test; share fixtures via `test/fixtures/` |
| Using gomock or mockery generated mocks | Generated mocks drift silently when interface changes; compiler won't catch it if the mock file isn't regenerated | Hand-write mock structs; compiler enforces interface match |
| Mocking GORM directly in service tests | GORM's `*gorm.DB` interface is huge; mock diverges from real behavior quickly | Mock the **repository interface**, not GORM |
| Testing all layers in one test | One test tests nothing specifically; failure root cause is unclear | One test per layer; mock the layer below |
| Skipping `repo.AssertExpectations(t)` | Mock calls that never happen are not caught → false positive | Always call `mock.AssertExpectations(t)` at the end of each sub-test |
| Using `t.Parallel()` without isolating DB state | Parallel tests share DB rows; reads/writes interfere | Either use separate schemas per test or ensure fixtures don't overlap |
| Not testing the "not found" / nil return case | Repository returns `(nil, nil)` for not-found; service must handle it | Always include a "not found → param error" case in service test |
| Asserting only `err != nil` on triple-return | Validation errors come through `paramErrs`, not `err`; test passes when it should fail | Assert all three return slots per the triple-return rules (§4) |
| Hardcoding tenant IDs as 0 in tests | ID 0 is the zero value — many `uint64` default to 0; tests pass even when tenant filtering is broken | Always use a non-zero tenant ID (e.g., 1) in tests |
| `context.Background()` in service tests when ctx matters | Service reads `helpers.GetTenantID(ctx)` — returns 0/false with bare Background | Build ctx with `helpers.WithTenantID(context.Background(), 1)` |
| Sharing mock instances across test cases in a loop | testify accumulates expected calls across cases; second case sees previous case's setup | Create fresh mock instances inside each `t.Run` block |

---

## 13. Related References

- → `references/service-patterns.md` — triple return, Params validation, panic recovery
- → `references/repository-patterns.md` — fluent builder, `defer r.clean()`, transaction patterns
- → `references/grpc-patterns.md §7` — controller 7-step flow (what the controller test must verify)
- → `references/context-patterns.md §8` — `helpers.WithTenantID` for building test contexts
- → `references/performance.md §2` — `benchstat` workflow for benchmark comparison
- → `references/concurrency-patterns.md §14` — `-race` CI gate policy
