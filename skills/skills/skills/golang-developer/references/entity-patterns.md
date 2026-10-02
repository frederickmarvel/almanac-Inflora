# Entity Layer Patterns - Go Microservice Reference

A comprehensive guide to Entity layer patterns for Go microservices. This document covers the design patterns, architectural conventions, and implementation details for building scalable, maintainable domain entities in Go.

## Table of Contents

1. [Overview](#overview)
2. [Base Entity Variants](#base-entity-variants)
3. [Composable Trait Mixins](#composable-trait-mixins)
4. [Multi-Tenant Pattern](#multi-tenant-pattern)
5. [Entity Composition Example](#entity-composition-example)
6. [Sign Interface for Financial Entities](#sign-interface-for-financial-entities)
7. [GORM Conventions](#gorm-conventions)
8. [Frame/DTO Layer (Three-Tier DTO Architecture)](#framedto-layer)
9. [Value Types](#value-types)
10. [When to Use Each Pattern](#when-to-use-each-pattern)
11. [Encrypted Field Types](#encrypted-field-types)
12. [Best Practices](#best-practices)
13. [Anti-Patterns](#anti-patterns)

---

## Overview

The Entity layer represents domain models that form the core of the microservice's business logic. Entities use a **composition-based approach** with:

- **Base Entities**: Provide primary key, timestamps, and soft-delete support
- **Trait Mixins**: Composable behavioral patterns (signing, processing, approval workflows)
- **Flexible ID Strategies**: Support auto-increment, UUID, uint64, and Snowflake IDs
- **GORM Integration**: Full ORM support with conventions for columns, indexes, and relationships

This pattern enables:
- Reusable behavioral traits across multiple domain entities
- Clear separation of concerns (state vs. behavior)
- Flexible ID generation strategies
- Type safety with strong typing
- Audit trail support (who, when, reason) for critical operations

---

## Base Entity Variants

All entities must embed one of the four base types. Choose based on your ID strategy and scale requirements.

### Shared Structs: Timestamp and SoftDelete

Before the base entity variants, note that timestamps and soft-delete are **separate composable structs**, not embedded in the base entities directly:

```go
type Timestamp struct {
    CreatedAt time.Time  `json:"created_at" gorm:"column:created_at;type:timestamp;not null;autoCreateTime;default:NOW();->"`
    UpdatedAt *time.Time `json:"updated_at" gorm:"column:updated_at;type:timestamp ON UPDATE CURRENT_TIMESTAMP;null;autoUpdateTime"`
}

type SoftDelete struct {
    DeletedAt gorm.DeletedAt `json:"deleted_at" gorm:"column:deleted_at;type:timestamp;null"`
}
```

**Key details**:
- `UpdatedAt` is a **pointer** (`*time.Time`), nullable — only set on update
- `CreatedAt` is read-only from Go side (`->` tag), set by DB default `NOW()`
- `SoftDelete` is a **separate trait** — only embed it in entities that need soft deletion
- All base entities embed `Timestamp` automatically, but NOT `SoftDelete`

---

### 1. BaseEntity (Auto-Increment uint)

**Use for**: Most standard entities, small-to-medium scale deployments.

```go
type BaseEntity struct {
    ID uint `json:"id" gorm:"primary_key"`
    Timestamp
}
```

**Characteristics**:
- Standard auto-incrementing primary key (starts at 1)
- Automatic timestamp management by GORM via embedded `Timestamp`
- **No soft delete by default** — add `SoftDelete` trait if needed
- Maximum ID value: ~4.2 billion (suitable for most applications)

**Example Entity**:
```go
type Customer struct {
    BaseEntity
    SoftDelete  // Only if soft-delete is needed
    Name     string
    Email    string
    Status   string
}
// NO TableName() — GORM auto-derives table name from struct name.
// Defining TableName() breaks the DB/Table prefix mechanism.
```

---

### 2. BaseEntityUint64 (Auto-Increment uint64)

**Use for**: Tenant IDs, multi-tenant systems, large-scale deployments.

```go
type BaseEntityUint64 struct {
    ID uint64 `json:"id" gorm:"primary_key"`
    Timestamp
}
```

**Characteristics**:
- 64-bit unsigned integer primary key
- Auto-incrementing (suitable for sequential IDs at scale)
- Handles very large datasets (up to ~18 quintillion)
- Commonly used for tenant IDs, investor IDs, external reference IDs
- Embeds `Timestamp` (no soft-delete by default)

**Example Entity**:
```go
type Tenant struct {
    BaseEntityUint64
    SoftDelete  // Only if needed
    TenantID    uint64  // Multi-tenant isolation field
    Name        string
}
// NO TableName() — let GORM derive it automatically.
```

---

### 3. BaseEntityUuid (UUID Primary Key)

**Use for**: Globally distributed systems, microservices that need cluster-wide uniqueness, privacy-conscious systems.

```go
type BaseEntityUuid struct {
    UID *uuid.UUID `gorm:"type:char(36);primary_key"`
    Timestamp
}
```

**Characteristics**:
- Field name is `UID` (not `ID`), type is `*uuid.UUID` (pointer, not string)
- Globally unique, generated via `SetUUID()` GORM BeforeCreate hook
- No server coordination required
- Larger storage footprint than numeric IDs
- Better for privacy (IDs are non-sequential and non-guessable)

**Example Entity**:
```go
type ApiKey struct {
    BaseEntityUuid
    SoftDelete
    TenantID    uint64
    KeyHash     string  // SHA-256 of the actual API key
    Name        string
    ExpiresAt   *time.Time
}
// NO TableName() — GORM derives "api_keys" from struct name automatically.
// UUID is auto-generated by GORM BeforeCreate hook via SetUUID()
```

---

### 4. BaseEntitySF (Snowflake ID)

**Use for**: High-throughput systems, microservices needing distributed ID generation, financial systems requiring millisecond-precision timestamps.

```go
type BaseEntitySF struct {
    ID int64 `json:"id" gorm:"primary_key;autoIncrement:false;type:bigint"`
    Timestamp
}
```

**Characteristics**:
- 64-bit Snowflake ID (Twitter's distributed ID generation algorithm)
- Composed of: timestamp (41 bits) + machine/datacenter ID (10 bits) + sequence (12 bits)
- Sortable by creation time (suitable for range queries)
- No server coordination needed
- Supports millions of IDs per second per machine
- Requires a Snowflake ID generator service or library

**Example Entity**:
```go
type Order struct {
    BaseEntitySF
    TenantID    uint64
    Status      string
    Amount      decimal.Decimal
}
// NO TableName() — GORM derives "orders" automatically.

// ID must be set by Snowflake generator before saving
func NewOrder(tenantID uint64, snowflakeID int64) *Order {
    return &Order{
        BaseEntitySF: BaseEntitySF{
            ID: snowflakeID,
        },
        TenantID: tenantID,
    }
}
```

**When to Use Snowflake**:
- Handling 10,000+ IDs per second
- Distributed systems across multiple datacenters
- Financial transactions requiring precise timing
- Analytics requiring time-based sorting of all records

---

## Composable Trait Mixins

Traits are small, focused structs that encapsulate specific behavioral patterns. Entities compose traits by embedding them. Each trait includes:

- **Fields**: Data representing the trait state (who, when, reason)
- **SyncDate Method**: Updates the timestamp to `time.Now()`

This enables clean separation: entities embed traits they need, rather than having monolithic base classes.

### Comprehensive Trait Reference

| Trait | Fields | Sync Method | Use Case |
|-------|--------|------------|----------|
| **Signable** | Signature, SignedAt | SyncSignedDate() | HMAC integrity verification |
| **Activable** | ActivatedBy, ActivatedByName, ActivatedAt | SyncActivatedDate() | Resource activation/enablement |
| **Processable** | ProcessedBy, ProcessedByName, ProcessedAt | SyncProcessedDate() | Processing/queue completion |
| **Completable** | CompletedBy, CompletedByName, CompletedAt | SyncCompletedDate() | Task/workflow completion |
| **Retryable** | RetriedBy, RetriedByName, RetriedAt, RetryCount | SyncRetriedDate() | Retry logic tracking |
| **Failable** | FailedBy, FailedByName, FailedAt, FailedReason | SyncFailedDate() | Error tracking |
| **Cancelable** | CancelledBy, CancelledByName, CancelledAt, CancelledReason | SyncCancelledDate() | Operation cancellation |
| **Voidable** | VoidedBy, VoidedByName, VoidedAt, VoidedReason | SyncVoidedDate() | Record reversal |
| **Verifiable** | VerifiedBy, VerifiedByName, VerifiedAt | SyncVerifiedDate() | Verification/validation |
| **Approvable** | ApprovedBy, ApprovedByName, ApprovedAt | SyncApprovedDate() | Approval workflow |
| **Rejectable** | RejectedBy, RejectedByName, RejectedAt, RejectedReason | SyncRejectedDate() | Rejection with reason |
| **Scheduleable** | ScheduledBy, ScheduledByName, ScheduledAt | SyncScheduledDate() | Job scheduling |
| **Lockable** | LockedBy, LockedByName, LockedAt, LockedReason | SyncLockedDate() | Resource locking |
| **Unlockable** | UnlockedBy, UnlockedByName, UnlockedAt | SyncUnlockedDate() | Resource unlocking |
| **Suspendable** | SuspendedBy, SuspendedByName, SuspendedAt, SuspendedReason | SyncSuspendedDate() | Temporary suspension |

### Example: Processable Trait (Complete Implementation)

```go
// Processable trait for operations that undergo processing
type Processable struct {
    ProcessedBy     string     `gorm:"column:processed_by" json:"processed_by"`
    ProcessedByName string     `gorm:"column:processed_by_name" json:"processed_by_name"`
    ProcessedAt     *time.Time `gorm:"column:processed_at;type:timestamp;null;index" json:"processed_at"`
}

// SyncProcessedDate updates the ProcessedAt timestamp to now
func (p *Processable) SyncProcessedDate() {
    now := time.Now().UTC()
    p.ProcessedAt = &now
}

// Helper: Mark as processed by a specific user
func (p *Processable) MarkProcessed(userID string, userName string) {
    p.ProcessedBy = userID
    p.ProcessedByName = userName
    p.SyncProcessedDate()
}

// Helper: Check if processed
func (p *Processable) IsProcessed() bool {
    return p.ProcessedAt != nil
}
```

### Example: Approvable Trait (Workflow Approval)

```go
// Approvable trait for approval workflows
type Approvable struct {
    ApprovedBy     string     `gorm:"column:approved_by" json:"approved_by"`
    ApprovedByName string     `gorm:"column:approved_by_name" json:"approved_by_name"`
    ApprovedAt     *time.Time `gorm:"column:approved_at;type:timestamp;null;index" json:"approved_at"`
}

// SyncApprovedDate updates the ApprovedAt timestamp to now
func (a *Approvable) SyncApprovedDate() {
    now := time.Now().UTC()
    a.ApprovedAt = &now
}

// Helper: Mark as approved by a specific user
func (a *Approvable) MarkApproved(userID string, userName string) {
    a.ApprovedBy = userID
    a.ApprovedByName = userName
    a.SyncApprovedDate()
}

// Helper: Check if approved
func (a *Approvable) IsApproved() bool {
    return a.ApprovedAt != nil
}
```

### Example: Rejectable Trait (With Reason)

```go
// Rejectable trait for operations that can be rejected
type Rejectable struct {
    RejectedBy     string     `gorm:"column:rejected_by" json:"rejected_by"`
    RejectedByName string     `gorm:"column:rejected_by_name" json:"rejected_by_name"`
    RejectedAt     *time.Time `gorm:"column:rejected_at;type:timestamp;null;index" json:"rejected_at"`
    RejectedReason string     `gorm:"column:rejected_reason;type:text" json:"rejected_reason"`
}

// SyncRejectedDate updates the RejectedAt timestamp to now
func (r *Rejectable) SyncRejectedDate() {
    now := time.Now().UTC()
    r.RejectedAt = &now
}

// Helper: Mark as rejected with reason
func (r *Rejectable) MarkRejected(userID string, userName string, reason string) {
    r.RejectedBy = userID
    r.RejectedByName = userName
    r.RejectedReason = reason
    r.SyncRejectedDate()
}

// Helper: Check if rejected
func (r *Rejectable) IsRejected() bool {
    return r.RejectedAt != nil
}
```

### Example: Failable Trait (Error Tracking)

```go
// Failable trait for operations that can fail
type Failable struct {
    FailedBy     string     `gorm:"column:failed_by" json:"failed_by"`
    FailedByName string     `gorm:"column:failed_by_name" json:"failed_by_name"`
    FailedAt     *time.Time `gorm:"column:failed_at;type:timestamp;null;index" json:"failed_at"`
    FailedReason string     `gorm:"column:failed_reason;type:text" json:"failed_reason"`
}

// SyncFailedDate updates the FailedAt timestamp to now
func (f *Failable) SyncFailedDate() {
    now := time.Now().UTC()
    f.FailedAt = &now
}

// Helper: Mark as failed with reason
func (f *Failable) MarkFailed(userID string, userName string, reason string) {
    f.FailedBy = userID
    f.FailedByName = userName
    f.FailedReason = reason
    f.SyncFailedDate()
}

// Helper: Check if failed
func (f *Failable) IsFailed() bool {
    return f.FailedAt != nil
}
```

---

## Multi-Tenant Pattern

Multi-tenancy is implemented via a `TenantID` field on every entity that needs data isolation. This is a shared-database, shared-schema approach where all tenants live in the same tables.

### Entity Layer

Every tenant-scoped entity includes `TenantID uint64` as a required field:

```go
type Order struct {
    BaseEntitySF
    TenantID    uint64          `gorm:"column:tenant_id;index" json:"tenant_id"`
    InvestorID  uint64          `gorm:"column:investor_id;index" json:"investor_id"`
    Code        string          `gorm:"column:code;uniqueIndex" json:"code"`
    // ... domain fields
}
```

**Key conventions**:
- Type is always `uint64` (supports external ID systems)
- Always indexed (`index` tag) — every query filters by tenant
- NOT embedded in a trait — it's a direct field (unlike timestamps which are trait-based)

### Repository Layer

Every tenant-scoped repository has a `ForTenantID` fluent method:

```go
type OrderRepository interface {
    ForTenantID(tenantID uint64) OrderRepository
    ForID(id int64) OrderRepository
    // ...
}

func (r OrderRepositoryImpl) ForTenantID(tenantID uint64) OrderRepository {
    r.whereQuery = r.whereQuery.Where("tenant_id = ?", tenantID)
    return r
}
```

**Almost every query chains `ForTenantID` first** to ensure tenant isolation:

```go
orders, err := repo.
    ForTenantID(tenantID).
    ForStatus("pending").
    Gets(ctx)
```

### Service Layer

Tenant ID flows through service params:

```go
type CreateOrderParams struct {
    TenantID   uint64           // Required — mandatory validation
    InvestorID *int64
    Amount     decimal.Decimal
    // ...
}

func (p *CreateOrderParams) IsMandatoryFilled() bool {
    return p.TenantID != 0 && p.Amount.IsPositive()
}
```

For read operations where tenant is optional (admin can query across tenants):

```go
type GetOrdersParams struct {
    TenantID *uint64   // Optional — pointer means "filter if provided"
    Status   *string
    Limit    uint64
    Offset   uint64
}
```

### Controller Layer

Tenant ID comes from the request (proto field) or can be extracted from auth context:

```go
// From request field
if req.TenantId != 0 {
    params.TenantID = utils.VarToPointer(req.TenantId)
}

// Or from auth context (application → tenant mapping)
app := helpers.GetApp(ctx)
params.TenantID = app.TenantID
```

### Three-Tier Access Control

| Tier | Tenant Behavior |
|---|---|
| Admin | Can query across tenants (TenantID is optional filter) |
| Insider | Scoped to the authenticated tenant (TenantID from auth) |
| Public | Scoped to the authenticated tenant (TenantID from auth) |

### Key Rules

1. **Every write operation MUST include TenantID** — mandatory validation in service params
2. **Every read query SHOULD filter by TenantID** — unless admin cross-tenant access is intended
3. **TenantID is immutable after creation** — never allow updates to tenant ownership
4. **Index tenant_id on every table** — it's the most common WHERE clause
5. **Composite unique constraints** include tenant: `uniqueIndex:idx_tenant_code` on `(tenant_id, code)`

---

## Entity Composition Example

### Real-World Order Entity

A production Order entity that demonstrates:
- Base entity composition (Snowflake IDs for high-throughput)
- Multiple trait mixins (processing, completion, cancellation, failure, signature)
- Domain-specific fields
- Proper GORM configuration

```go
package entity

import (
    "time"
    "github.com/shopspring/decimal"
    "gorm.io/datatypes"
)

// Order represents a financial order in the system
type Order struct {
    BaseEntitySF      // Primary key: Snowflake ID (int64)
    Processable       // Processing workflow
    Completable       // Completion state
    Cancelable        // Cancellation option
    Failable          // Error tracking
    Signable          // HMAC signature for integrity

    // Multi-tenant isolation + relationship fields
    TenantID          uint64              `gorm:"column:tenant_id;index" json:"tenant_id"`
    InvestorID        uint64              `gorm:"column:investor_id;index" json:"investor_id"`

    // Domain fields
    Type              string              `gorm:"column:type;index" json:"type"` // "BUY", "SELL", "TRANSFER"
    Status            string              `gorm:"column:status;index" json:"status"` // "PENDING", "PROCESSED", "COMPLETED", "CANCELLED"
    Amount            decimal.Decimal     `gorm:"column:amount;type:decimal(20,2)" json:"amount"`
    Currency          string              `gorm:"column:currency;default:'USD'" json:"currency"`
    
    // Additional metadata
    ExternalRef       string              `gorm:"column:external_ref;index" json:"external_ref"`
    Metadata          datatypes.JSONType  `gorm:"column:metadata;type:json" json:"metadata"`
}

// NO TableName() — GORM auto-derives from struct name.
// Defining TableName() breaks the DB/Table prefix mechanism.

// BeforeCreate hook for GORM - sets signature before inserting
func (o *Order) BeforeCreate(tx *gorm.DB) error {
    if signer, ok := interface{}(o).(Sign); ok {
        signature := ComputeSignature(signer)
        o.Signature = signature
        o.SyncSignedDate()
    }
    return nil
}

// BeforeUpdate hook for GORM - refreshes signature on update
func (o *Order) BeforeUpdate(tx *gorm.DB) error {
    if signer, ok := interface{}(o).(Sign); ok {
        signature := ComputeSignature(signer)
        o.Signature = signature
        o.SyncSignedDate()
    }
    return nil
}

// Helper: Transition order to processed state
func (o *Order) MarkProcessed(processedBy string, processedByName string) {
    o.Processable.MarkProcessed(processedBy, processedByName)
    o.Status = "PROCESSED"
}

// Helper: Complete the order
func (o *Order) Complete(completedBy string, completedByName string) {
    o.Completable.MarkCompleted(completedBy, completedByName)
    o.Status = "COMPLETED"
}

// Helper: Cancel the order with reason
func (o *Order) Cancel(cancelledBy string, cancelledByName string, reason string) {
    o.Cancelable.MarkCancelled(cancelledBy, cancelledByName, reason)
    o.Status = "CANCELLED"
}
```

### Another Example: Transaction Entity

```go
type Transaction struct {
    BaseEntityUint64  // Use uint64 for financial transaction IDs
    Verifiable        // Verification workflow
    Approvable        // Approval workflow
    Failable          // Error tracking
    Signable          // HMAC signature

    TenantID          uint64              `gorm:"column:tenant_id;index" json:"tenant_id"`
    OrderID           int64               `gorm:"column:order_id;index" json:"order_id"`
    Type              string              `gorm:"column:type" json:"type"` // "DEBIT", "CREDIT"
    Amount            decimal.Decimal     `gorm:"column:amount;type:decimal(20,2)" json:"amount"`
    Status            string              `gorm:"column:status;index" json:"status"` // "PENDING", "VERIFIED", "APPROVED", "FAILED"
    Description       string              `gorm:"column:description;type:text" json:"description"`
}

// NO TableName() — GORM auto-derives from struct name.
```

---

## Sign Interface for Financial Entities

The `Sign` interface enables HMAC-based integrity verification for financial records. This is critical for regulatory compliance and fraud detection.

### Interface Definition

```go
// Sign interface for entities that require cryptographic integrity verification
type Sign interface {
    // GetSignKey returns the HMAC signing key (secret)
    // Typically derived from the entity's sensitive fields or a master key
    GetSignKey() string

    // GetSignData returns the data to be signed (message)
    // Concatenate all relevant fields that should be integrity-checked
    // Order matters: must be consistent across all operations
    GetSignData() string
}
```

### Implementation Example: Order Signing

```go
// GetSignKey returns the HMAC key for signing
// In production, this might be derived from a master key and tenant ID
func (o *Order) GetSignKey() string {
    // Example: concatenate tenant ID and a master key
    return fmt.Sprintf("%d:%s", o.TenantID, masterHmacKey)
}

// GetSignData returns the concatenated data to sign
// RULES for signature data:
//   1. NEVER use JSON data type — always use pipe-delimited string format
//   2. Decimal amounts: ALWAYS use StringFixed(4) — fixed 4 decimal places
//   3. Datetime fields: ALWAYS use Unix timestamp (second precision only)
//   4. Field order is critical — must be consistent across all operations
func (o *Order) GetSignData() string {
    return fmt.Sprintf(
        "%d|%d|%d|%s|%s|%s|%d",
        o.ID,
        o.TenantID,
        o.InvestorID,
        o.Type,
        o.Amount.StringFixed(4),    // Fixed 4 decimal places, NOT .String()
        o.Currency,
        o.CreatedAt.Unix(),         // Unix second precision, NOT RFC3339
    )
}

// ComputeSignature generates HMAC-SHA256 signature for the entity
func ComputeSignature(signer Sign) string {
    key := signer.GetSignKey()
    data := signer.GetSignData()
    
    h := hmac.New(sha256.New, []byte(key))
    h.Write([]byte(data))
    return hex.EncodeToString(h.Sum(nil))
}

// VerifySignature validates the entity's integrity
func (o *Order) VerifySignature() bool {
    expected := ComputeSignature(o)
    return subtle.ConstantTimeCompare([]byte(o.Signature), []byte(expected)) == 1
}
```

### GORM Hooks for Auto-Signing

```go
// BeforeCreate hook - automatically sign before inserting
func (o *Order) BeforeCreate(tx *gorm.DB) error {
    if signer, ok := interface{}(o).(Sign); ok {
        o.Signature = ComputeSignature(signer)
        o.SyncSignedDate()
    }
    return nil
}

// BeforeUpdate hook - refresh signature before updating
func (o *Order) BeforeUpdate(tx *gorm.DB) error {
    if signer, ok := interface{}(o).(Sign); ok {
        o.Signature = ComputeSignature(signer)
        o.SyncSignedDate()
    }
    return nil
}

// AfterFind hook - verify signature after loading from database
func (o *Order) AfterFind(tx *gorm.DB) error {
    if !o.VerifySignature() {
        return errors.New("signature verification failed - data integrity compromised")
    }
    return nil
}
```

### Signature Data Rules (Non-Negotiable)

| Rule | Wrong ❌ | Correct ✅ |
|------|---------|-----------|
| **No JSON** | `json.Marshal(data)` | `fmt.Sprintf("%d\|%s\|%s", ...)` pipe-delimited |
| **Decimal = Fixed 4** | `amount.String()` (variable precision) | `amount.StringFixed(4)` (always 4 decimal places) |
| **Datetime = Unix second** | `time.Format(time.RFC3339)` | `time.Unix()` (int64, second precision only) |
| **No sub-second precision** | `time.UnixMilli()` or `time.UnixNano()` | `time.Unix()` |

These rules prevent signature mismatches caused by floating precision, timezone formatting, or JSON field ordering differences.

### When to Use Sign

- Financial transactions (orders, transfers, settlements)
- Customer account changes (balance adjustments, transfers)
- Regulatory compliance records (audit trails)
- Payment processing
- High-value operations requiring integrity guarantees

**Entities That Should Implement Signing**:
Any entity that handles financial data, audit trails, or regulatory compliance records should implement the Sign interface to provide cryptographic integrity guarantees. Examples include Order, Transaction, and any entity recording financial events or state changes.

---

## GORM Conventions

### Column Naming

All entity fields should follow these conventions:

1. **Database Column Names**: Use snake_case, lowercase
   ```go
   type Order struct {
       TenantID    uint64    `gorm:"column:tenant_id"`
       InvestorID  uint64    `gorm:"column:investor_id"`
       OrderAmount decimal.Decimal `gorm:"column:order_amount"`
   }
   ```

2. **JSON Tags**: Use snake_case for API responses
   ```go
   type Order struct {
       TenantID    uint64    `json:"tenant_id"`
       CreatedAt   time.Time `json:"created_at"`
   }
   ```

### Data Type Guidelines

```go
// Integer IDs - Use based on scale
uint            // Standard IDs (up to ~4.2 billion)
uint64          // Tenant IDs, external references, large scale (up to ~18 quintillion)
int64           // Snowflake IDs, timestamps

// Monetary Values - ALWAYS use decimal.Decimal
// Never use float64 for money (precision issues)
Amount  decimal.Decimal `gorm:"column:amount;type:decimal(20,2)"`

// Timestamps — ALL datetime fields MUST be `type:timestamp;null` EXCEPT created_at/updated_at
// created_at and updated_at follow the Timestamp struct convention (managed by GORM)
ProcessedAt *time.Time `gorm:"column:processed_at;type:timestamp;null"`
ExpiredAt   *time.Time `gorm:"column:expired_at;type:timestamp;null"`
// NEVER omit type:timestamp;null on datetime fields (GORM defaults can vary)

// Soft Deletes
DeletedAt gorm.DeletedAt `gorm:"index"`

// Text Fields
Description string `gorm:"column:description;type:text"`
Reason      string `gorm:"column:reason;type:text"`

// JSON Fields
Metadata datatypes.JSONType `gorm:"column:metadata;type:json"`

// Booleans — ALWAYS use int in Go + tinyint(1) in DB. NEVER use bool.
IsActive int `gorm:"column:is_active;type:tinyint(1);not null;default:1"`
IsHidden int `gorm:"column:is_hidden;type:tinyint(1);not null;default:0"`
```

### GORM Tags Reference

```go
// Primary Key
ID uint `gorm:"primaryKey"`

// Auto-Increment
ID uint `gorm:"primaryKey;autoIncrement"`
ID int64 `gorm:"primaryKey;autoIncrement:false"` // For Snowflake

// Indexes
TenantID uint64 `gorm:"index"`
Status   string `gorm:"index"`
CreatedAt time.Time `gorm:"index"`

// Composite Index
// Use in GORM model hooks or migration
// type Order struct {
//     TenantID uint64
//     InvestorID uint64
// }
// Index: `gorm:"index:idx_tenant_investor;compound"`

// Column Definition
Amount decimal.Decimal `gorm:"column:amount;type:decimal(20,2)"`

// Constraints
Email string `gorm:"uniqueIndex"`
Status string `gorm:"default:'PENDING'"`

// Relationships — use gorm:"-" for non-persisted associations
// NEVER define foreignKey tags — too many edge cases with GORM
Items []*OrderItem `json:"items" gorm:"-"`
```

### Table Naming

**NEVER define `TableName()` on entities.** GORM auto-derives the table name from the struct name (pluralized, snake_case). Defining `TableName()` breaks the DB/Table prefix mechanism used for multi-tenant or environment-based table prefixes.

```go
// WRONG ❌ — breaks DB/Table prefix
func (Order) TableName() string {
    return "orders"
}

// CORRECT ✅ — let GORM derive it
type Order struct {
    BaseEntitySF
    // ... fields
}
// GORM auto-maps to table "orders"
```

### Migrations

**Always use GORM AutoMigrate from entity models — never raw SQL.** This keeps the schema definition in a single source of truth (the entity struct) and avoids drift between entity fields and table columns.

```go
// src/schema/migrations/20260101000001_create_orders.go
package migrations

import (
    "database/sql"
    "github.com/pressly/goose/v3"
    "gorm.io/driver/mysql"
    "gorm.io/gorm"
    "your-module/src/model/entity"
)

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

---

## Frame/DTO Layer

The architecture uses a **three-tier DTO strategy** that separates generic data structures from protocol-specific response shapes. This ensures domain entities stay clean while each API tier (Admin, Insider, Public) controls exactly what data is exposed.

### DTO Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│  src/model/frame/              GENERIC DTOs (Frame Layer)    │
│  ─────────────────────────────────────────────────────────── │
│  Protocol-agnostic structs. Used as GORM JSON column types,  │
│  calculation contexts, and cross-service data holders.       │
│  Implement sql.Scanner + driver.Valuer for DB serialization. │
│  JSON tags only — no proto/gRPC awareness.                   │
└─────────────────────────┬────────────────────────────────────┘
                          │ referenced by entities + services
                          ▼
┌──────────────────────────────────────────────────────────────┐
│  src/model/entity/             DOMAIN ENTITIES               │
│  ─────────────────────────────────────────────────────────── │
│  Business objects with GORM mappings. Embed frame types as   │
│  JSON columns (e.g., Charges []frame.Charge).                │
└─────────────────────────┬────────────────────────────────────┘
                          │ consumed by transformers
                          ▼
┌──────────────────────────────────────────────────────────────┐
│  engine/grpc/transformer/      ADMIN gRPC DTOs               │
│  engine/grpc-insider/transformer/  INSIDER gRPC DTOs         │
│  engine/grpc-public/transformer/   PUBLIC gRPC DTOs          │
│  engine/rest/dto/              ADMIN REST DTOs (if needed)    │
│  engine/rest-insider/dto/      INSIDER REST DTOs (if needed)  │
│  engine/rest-public/dto/       PUBLIC REST DTOs (if needed)   │
│  ─────────────────────────────────────────────────────────── │
│  Protocol-specific response shapes. gRPC uses proto messages │
│  via transformers. REST uses dedicated DTO structs when the   │
│  response shape differs from proto (custom endpoints, file    │
│  downloads, aggregations). Each tier exposes different fields.│
└──────────────────────────────────────────────────────────────┘
```

### Layer 1: Generic Frame DTOs (`src/model/frame/`)

Frames are **protocol-agnostic data structures** separate from domain entities. They serve three purposes:
1. **JSON column types** — stored as JSON blobs in MySQL, auto-serialized via GORM hooks
2. **Calculation contexts** — intermediate results during fee/charge/bonus calculations
3. **Cross-service data holders** — external data from other microservices (e.g., product-engine)

**Key trait**: All DB-persisted frames implement `sql.Scanner` + `driver.Valuer` for automatic JSON marshaling.

```go
package frame

// Charge is a generic DTO stored as JSON column in entity tables.
// Used by Product, Order, and Transaction entities.
type Charge struct {
    Name                        string          `json:"name"`
    Description                 string          `json:"description"`
    Type                        string          `json:"type"`         // "amount" or "percentage"
    Amount                      decimal.Decimal `json:"amount"`
    IsApplySubscription         bool            `json:"is_apply_subscription"`
    IsApplyRedemption           bool            `json:"is_apply_redemption"`
    IsApplyAfterSubscriptionFee bool            `json:"is_apply_after_subscription_fee"`
    IsApplyAfterRedemptionFee   bool            `json:"is_apply_after_redemption_fee"`
    IsApplyOnRealized           bool            `json:"is_apply_on_realized"`
    IsExclusive                 bool            `json:"is_exclusive"`
}

// Scan implements sql.Scanner — deserialize JSON from DB
func (t *Charge) Scan(value any) error {
    if value != nil {
        bytes, ok := value.([]byte)
        if !ok {
            return errors.New(fmt.Sprint("Failed to unmarshal JSONB value:", value))
        }
        result := Charge{}
        err := json.Unmarshal(bytes, &result)
        *t = result
        return err
    }
    *t = Charge{}
    return nil
}

// Value implements driver.Valuer — serialize to JSON for DB
func (t Charge) Value() (driver.Value, error) {
    return t.String(), nil
}
```

**Frame types by purpose**:

| Frame | Purpose | DB-Persisted |
|-------|---------|:---:|
| `Charge` | Fee/charge definition with apply flags | Yes |
| `Bonus` | Bonus definition with apply flags | Yes |
| `CalculationBreakdown` | Full calculation audit trail (amounts, fees, charges per stage) | Yes |
| `ChargeBreakdown` | Per-charge calculation detail | Yes |
| `BonusBreakdown` | Per-bonus calculation detail | Yes |
| `FeesTaxesSummaryResponse` | Aggregated fee/tax summary with breakdowns | No (query result) |
| `Product` | External product data from product-engine | No (cross-service) |
| `PdfTemplate` | PDF generation template data | No (render context) |

**How entities use frames** (JSON column embedding):
```go
type Product struct {
    BaseEntity
    TenantID    uint64
    Name        string
    // Frame types as JSON columns — auto-serialized by GORM
    Charges     datatypes.JSONSlice[frame.Charge]  `gorm:"column:charges;type:json"`
    Bonuses     datatypes.JSONSlice[frame.Bonus]   `gorm:"column:bonuses;type:json"`
}
```

### Type Mapping Across Layers

Boolean flags use `int` (0/1) throughout — NOT Go `bool`. This aligns with MySQL TINYINT columns and protobuf int32 representation. The only exception is frame config flags (e.g., `IsApplySubscription` in Charge/Bonus) which use `bool` because they're JSON-serialized, not DB columns.

| Type | Entity (GORM) | Frame DTO | Proto (.proto) | Proto (Go generated) |
|------|:------------:|:---------:|:--------------:|:-------------------:|
| Boolean flags | `int` (0/1) | `int` or `bool` | `int32` | `int32` |
| Primary key (auto-inc) | `uint` | — | `uint64` | `uint64` |
| Primary key (snowflake) | `int64` | — | `int64` | `int64` |
| Tenant ID | `uint64` | `uint64` | `uint64` | `uint64` |
| Money/decimal | `decimal.Decimal` | `decimal.Decimal` | `string` | `string` |
| Timestamps | `*time.Time` | `*time.Time` | `string` (RFC3339) | `string` |
| Counters/retry | `int` | `int` | `int32` | `int32` |

**Key rules**:
- **Entity → Proto boolean conversion**: `int` to `int32` (direct cast, both 0/1)
- **Frame → Proto boolean conversion**: `bool` to `int32` (requires explicit conversion)
- **Decimal → Proto**: Always `.StringFixed(PRECISION)` — never float
- **Proto uses `int32` not `int`** — protobuf has no native `int` type, only `int32`/`int64`
- **Frame DTOs that mirror external proto** (e.g., `frame.Product` from product-engine) use `int32` to stay aligned with the source proto definition

**Example — transformer type conversion**:
```go
// Entity (int) → Proto (int32)
fundData.IsActive = int32(data.IsActive)

// Frame bool → Proto int32
if charge.IsExclusive {
    protoCharge.IsExclusive = 1
} else {
    protoCharge.IsExclusive = 0
}

// Decimal → Proto string
fundData.AvgPrice = data.AvgPrice.StringFixed(DEFAULT_PRECISION)
```

### Layer 2: Protocol-Specific DTOs (Transformer + DTO packages)

Each API tier has its own response shapes that control **what data is exposed** to the consumer. The key principle: **the same entity gets transformed differently per tier**.

#### gRPC DTOs (via Transformers + Proto)

For gRPC APIs, the proto-generated messages ARE the DTOs. Transformers convert entities to proto messages:

```go
// engine/grpc/transformer/ — Admin tier (full data)
func (c FundTransformerImpl) TransformFund(data *entity.Fund) *adminv2.FundData {
    fundData := &adminv2.FundData{
        Id:         uint64(data.ID),
        InvestorId: data.InvestorID,
        TenantId:   data.TenantID,        // Admin sees tenant ID
        // ... all fields exposed
    }
    if data.Investor != nil {
        fundData.Investor = c.TransformInvestor(data.Investor)  // Full investor data
    }
    return fundData
}

// engine/grpc-public/transformer/ — Public tier (restricted data)
func (t FundTransformerImpl) TransformToFundData(fund *entity.Fund) *publicv2.FundData {
    fundData := &publicv2.FundData{
        Id:         fund.ID,              // int64, not uint64
        InvestorId: fund.InvestorID,
        // TenantId:  NOT exposed to public
        // Investor:  NOT exposed to public
    }
    return fundData
}
```

**Per-tier field exposure rules**:

| Field | Admin | Insider | Public |
|-------|:-----:|:-------:|:------:|
| `TenantId` | Yes | Yes | No |
| `Investor` (nested) | Yes (full) | Yes (full) | No |
| `ID` type | `uint64` | `uint64` | `int64` |
| Transform prefix | `Transform*` | `Transform*` | `TransformTo*` |
| Wrapper methods | `TransformWrapper*` | No | No |

#### REST DTOs (dedicated DTO packages)

For REST endpoints that need response shapes **different from proto messages** (custom aggregations, file downloads, dashboard data), use dedicated DTO structs:

```go
// engine/rest/dto/summary_dto.go — Admin REST-specific DTO
package dto

type FundSummaryResponse struct {
    TotalFunds    int             `json:"total_funds"`
    TotalAUM      decimal.Decimal `json:"total_aum"`
    ByProduct     []ProductAUM    `json:"by_product"`
    GeneratedAt   time.Time       `json:"generated_at"`
}

type ProductAUM struct {
    ProductID   uint64          `json:"product_id"`
    ProductName string          `json:"product_name"`
    AUM         decimal.Decimal `json:"aum"`
    FundCount   int             `json:"fund_count"`
}
```

**When to use REST DTO vs proto message**:
- **Use proto** (via grpc-gateway): Standard CRUD responses that mirror the gRPC API
- **Use REST DTO**: Custom aggregations, file downloads, dashboard endpoints, webhook payloads, or any shape that doesn't map to a proto message

### Data Flow Summary

```
DB → Entity (with frame JSON columns)
  → Service (business logic, uses frame types for calculations)
    → Controller
      ├── gRPC: Transformer → Proto Message → gRPC Response
      └── REST: Transformer → REST DTO (or Proto via gateway) → JSON Response
```

### Key Rules

1. **Frame DTOs are protocol-agnostic** — never import proto or gRPC packages in `src/model/frame/`
2. **Entities own frame types** — frames are embedded as JSON columns, not standalone DB tables
3. **Each API tier controls its own exposure** — Admin/Insider/Public transformers decide what to include
4. **REST DTOs only when needed** — if grpc-gateway already produces the right JSON shape, don't duplicate
5. **Frame types implement Scanner/Valuer** — any frame stored in DB MUST have these GORM hooks
6. **Never return raw entities from controllers** — always transform to the appropriate DTO/proto message

---

## Value Types

Value types provide domain-specific wrappers with typed conversion methods.

### AmountItem Type

```go
// types/AmountItem.go
package types

import "github.com/shopspring/decimal"

// AmountItem represents a flexible amount with a type and reference
type AmountItem struct {
    Type        string          `json:"type"`        // "FEE", "TAX", "CHARGE", "DISCOUNT"
    ReferenceID string          `json:"reference_id"` // Reference to the item (e.g., charge ID)
    Amount      decimal.Decimal `json:"amount"`
}

// Helper: Sum multiple AmountItems
func SumAmountItems(items []AmountItem) decimal.Decimal {
    total := decimal.Zero
    for _, item := range items {
        total = total.Add(item.Amount)
    }
    return total
}

// Helper: Filter by type
func FilterByType(items []AmountItem, itemType string) []AmountItem {
    var filtered []AmountItem
    for _, item := range items {
        if item.Type == itemType {
            filtered = append(filtered, item)
        }
    }
    return filtered
}
```

### MutatedValue Type

```go
// types/MutatedValue.go
package types

import "strconv"

// MutatedValue is a string wrapper with typed conversion methods
type MutatedValue string

// ToInt converts to integer with default fallback
func (m MutatedValue) ToInt() int {
    val, err := strconv.Atoi(string(m))
    if err != nil {
        return 0
    }
    return val
}

// ToFloat converts to float64 with default fallback
func (m MutatedValue) ToFloat() float64 {
    val, err := strconv.ParseFloat(string(m), 64)
    if err != nil {
        return 0.0
    }
    return val
}

// ToBool converts to boolean
func (m MutatedValue) ToBool() bool {
    s := string(m)
    return s == "true" || s == "1" || s == "yes"
}

// ToString returns the raw string value
func (m MutatedValue) ToString() string {
    return string(m)
}

// IsEmpty checks if the value is empty
func (m MutatedValue) IsEmpty() bool {
    return string(m) == ""
}

// Usage Example
var val MutatedValue = "42"
intVal := val.ToInt()        // 42
floatVal := val.ToFloat()    // 42.0
strVal := val.ToString()     // "42"
```

---

## When to Use Each Pattern

### Choosing Base Entity Type

```
Scale < 1M records     → BaseEntity (uint)
Multi-tenant system    → BaseEntityUint64
Distributed system     → BaseEntityUuid
High-throughput (>10K  → BaseEntitySF (Snowflake)
  IDs/sec) + precise
  timing
```

### Trait Selection Matrix

| Entity Type | Traits | Reason |
|------------|--------|--------|
| Order | Processable, Completable, Cancelable, Failable, Signable | Full workflow with signing |
| Transaction | Verifiable, Approvable, Failable, Signable | Approval + integrity critical |
| Product | Activable, Verifiable, Approvable | Activation + approval gating |
| Pricing Record | Processable, Completable, Signable | Processing + integrity |
| Audit Entry | Signable, Verifiable | Integrity + traceability |
| User/Account | Verifiable, Activable | Activation + verification |
| Dispute | Rejectable, Approvable, Completable | Workflow + resolution |
| Locked Resource | Lockable, Unlockable | Concurrency control |
| Retry Job | Retryable, Failable | Automatic retry logic |
| ... other entities | (follow same pattern) | Select traits matching your domain |

---

## Best Practices

### 1. Entity Immutability (Audit Trail)

Entities should be **immutable after key lifecycle events**. Use traits to lock operations:

```go
// Once approved, order state shouldn't change except through formal processes
func (o *Order) CanModify() bool {
    return !o.IsApproved() && !o.IsCompleted() && !o.IsCancelled()
}
```

### 2. Validation in Entity Methods

Add business logic validation to entity methods:

```go
func (o *Order) UpdateAmount(newAmount decimal.Decimal) error {
    if o.IsProcessed() {
        return errors.New("cannot modify amount of processed order")
    }
    if newAmount.LessThanOrEqual(decimal.Zero) {
        return errors.New("amount must be positive")
    }
    o.Amount = newAmount
    return nil
}
```

### 3. Time Handling

Always use UTC timestamps:

```go
// In SyncDate methods
func (p *Processable) SyncProcessedDate() {
    now := time.Now().UTC()  // Always UTC
    p.ProcessedAt = &now
}
```

### 4. Nullable vs Non-Nullable Fields

Use pointers for optional timestamps/dates:

```go
type Order struct {
    CreatedAt   time.Time      // Required (non-nullable)
    ProcessedAt *time.Time     // Optional (nullable)
    CompletedAt *time.Time     // Optional (nullable)
}
```

### 5. Signature Generation Order

Signature data must be generated in **consistent order** for verification to work:

```go
// ALWAYS concatenate in same order
func (o *Order) GetSignData() string {
    // Order matters: ID, TenantID, InvestorID, Type, Amount, Currency, CreatedAt
    // NEVER change this order - backward compatibility depends on it
    return fmt.Sprintf(
        "%d|%d|%d|%s|%s|%s|%d",
        o.ID,
        o.TenantID,
        o.InvestorID,
        o.Type,
        o.Amount.String(),
        o.Currency,
        o.CreatedAt.Unix(),
    )
}
```

### 6. Monetary Fields

ALWAYS use `decimal.Decimal` for financial values:

```go
// CORRECT
Amount decimal.Decimal `gorm:"column:amount;type:decimal(20,2)"`

// WRONG - precision loss
Amount float64 `gorm:"column:amount"`

// Arithmetic
total := amount1.Add(amount2)
fee := total.Mul(decimal.NewFromString("0.02"))
```

### 7. Multi-Entity Transactions

Use repository transactions for operations spanning multiple entities:

```go
// Service layer
func (s *OrderService) CompleteOrder(ctx context.Context, orderID int64) error {
    repo := s.orderRepo.StartTx(ctx)
    defer func() {
        if err != nil {
            repo.RollbackTx()
        } else {
            repo.CommitTx()
        }
    }()

    order, _ := repo.ForID(orderID).Get(ctx)
    order.Complete(userID, userName)
    
    // Also update ledger, inventory, etc. in same transaction
    s.updateLedger(repo, order)
    
    return repo.Update(ctx, order)
}
```

### 8. Repository Query Cleanup

Always clean repository queries after execution:

```go
func (r *OrderRepositoryImpl) Get(ctx context.Context) (*Order, error) {
    defer r.clean()  // CRITICAL: clean state after execution
    
    order := &Order{}
    if err := r.buildQuery().First(order).Error; err != nil {
        return nil, err
    }
    return order, nil
}
```

---

## Encrypted Field Types

Sensitive PII fields use custom Go types that **automatically encrypt on write and decrypt on read** via GORM's `sql.Scanner` and `driver.Valuer` interfaces. Business logic never touches plaintext/ciphertext — it's fully transparent.

### Available Types

| Type | Algorithm | Key Size | Use Case |
|------|-----------|----------|----------|
| `EncryptedAES` | AES-256-CBC | 32 bytes | High sensitivity (API keys, server credentials) |
| `EncryptedAES128` | AES-128-CBC | 16 bytes | Standard PII (bank accounts, addresses) |
| `EncryptedAES128ECB` | AES-128-ECB | 16 bytes | Legacy system compatibility only |
| `EncryptedRSA` | RSA-OAEP | 2048-bit | Asymmetric encryption (cross-service sharing) |

### Type Definition Pattern

Each encrypted type is defined in `src/model/types/`:

```go
// src/model/types/encrypted_aes128.go
type EncryptedAES128 string

// GORM auto-decrypts on database read
func (t *EncryptedAES128) Scan(value any) error {
    decrypted, err := helpers.DecryptAES128CBC(
        viper.GetString(constant.AES_128_KEY),
        string(value.([]byte)),
    )
    *t = EncryptedAES128(decrypted)
    return err
}

// GORM auto-encrypts on database write
func (t EncryptedAES128) Value() (driver.Value, error) {
    encrypted, err := helpers.EncryptAES128CBC(
        viper.GetString(constant.AES_128_KEY),
        string(t),
    )
    return encrypted, nil
}
```

### Entity Usage

Just declare the field type — no manual encrypt/decrypt calls needed:

```go
type User struct {
    BaseEntitySF
    Firstname types.EncryptedAES128ECB  // Auto-encrypted PII
    Lastname  types.EncryptedAES128ECB
    Email     types.EncryptedAES128ECB
    Phone     types.EncryptedAES128ECB
    TaxID     types.EncryptedAES        // Higher security tier
}
```

### Key Management

- **AES keys**: Stored in `.env` via Viper constants (`AES_KEY`, `AES_128_KEY`)
- **RSA keys**: Generated as 2048-bit pairs, stored AES-encrypted in `.env`, loaded at startup via `app.GetRSAPublicKey()` / `app.GetRSAPrivateKey()`
- **Auto-generation**: Keys auto-generated on first run if not present

### Rules

- **Database column type**: `TEXT` (stores hex-encoded ciphertext)
- **Never use `string`** for sensitive fields — always use an encrypted type
- **Choose tier by sensitivity**: API keys → AES-256, PII → AES-128, legacy → AES-128-ECB
- **ECB mode is legacy only** — never use for new fields (identical plaintext = identical ciphertext)
- **RSA for cross-service**: When another service needs to decrypt without sharing the same symmetric key

---

## Anti-Patterns

| Anti-pattern | Why it breaks | Fix |
|---|---|---|
| Defining `TableName()` on an entity | Breaks the DB/Table prefix strategy; entities auto-name from struct + prefix | Remove `TableName()`; configure the global table prefix in GORM config |
| Using `bool` for boolean columns | MySQL TINYINT(1) → stored as 0/1; `bool` type creates type mismatch on some drivers | Use `int` with `type:tinyint(1)` GORM tag |
| Using `time.Time` (non-pointer) for nullable timestamps | Non-pointer `time.Time` can't represent NULL; GORM stores zero-value as epoch | Use `*time.Time` with `type:timestamp;null` tag |
| Using `foreignKey` GORM tag on associations | Creates implicit foreign key constraints; migrations become fragile; removes cross-DB portability | Use manual `uint` / `uint64` ID fields; load related entities explicitly |
| Skipping trait composition on a state-transitioning entity | State fields (`processed_at`, `failed_at`, etc.) must be set consistently via trait methods; raw assignment misses side effects (hooks, sign invalidation) | Compose `Processable`, `Completable`, `Failable` etc. and call trait methods (`SyncProcessedDate()`, `SyncFailedDate()`) |
| Storing monetary amounts as `float64` | Floating-point arithmetic produces rounding errors for financial values | Use `decimal.Decimal` (shopspring/decimal) for all monetary fields |
| Setting `created_at` / `updated_at` manually | GORM manages these automatically; manual setting causes drift | Never assign `CreatedAt`/`UpdatedAt` in code; let GORM handle them |
| Using `int` / `int64` for tenant/partner IDs | Schema and protobuf use `uint64`; sign mismatch causes silent truncation on large IDs | Use `uint64` for all tenant/partner ID fields |
| Adding HMAC sign field as plain `string` | Plain string allows silent mutation without re-sign detection | Implement the `Sign` interface; use HMAC-SHA256 with `StringFixed(4)` + `Unix()` per `security.md` |
| Embedding `BaseEntity` for entities that need global uniqueness | Autoincrement ID collides across shards; no distributed ordering guarantee | Use `BaseEntitySF` (snowflake) for cross-service / event-sourced entities |
| Putting business logic in entity methods | Entities are data structures; logic in methods bypasses service validation and panic recovery | Keep business logic in service methods; entities provide only trait mutations and sign computation |
| Using `string` for encrypted PII fields | Stores plaintext in DB; no automatic encryption/decryption | Use `types.EncryptedAES128` or `types.EncryptedAES` from `src/model/types/` |

---

## Summary

Entity layer patterns enable:

✓ **Reusability**: Compose traits across multiple entity types  
✓ **Auditability**: Track who did what and when for all operations  
✓ **Integrity**: HMAC signatures verify financial data hasn't been tampered  
✓ **Flexibility**: Choose ID generation strategy based on scale  
✓ **Type Safety**: Strong typing prevents runtime errors  
✓ **Maintainability**: Clear separation of concerns with trait mixins  

Use this guide to design entities that scale, are auditable, and maintain data integrity in production microservices.

---

## Related References

- → `references/repository-patterns.md` — fluent builder that consumes these entities; `ForStatus`, `ForTenant` rely on entity field names
- → `references/service-patterns.md` — service methods that compose trait mutations (`SyncProcessedDate`, `SyncFailedDate`, etc.)
- → `references/security.md` — HMAC sign convention, `StringFixed(4)` + `Unix()` rules, AES/RSA key management
- → `references/infrastructure.md §6` — encrypted field type definitions (`EncryptedAES128`, `EncryptedAES`)
- → `references/grpc-patterns.md §5` — Frame/DTO layer and transformer mapping from entity to proto
