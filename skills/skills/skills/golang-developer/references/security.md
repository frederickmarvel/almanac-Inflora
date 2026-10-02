# Security Patterns

Authentication, authorization, request signing, validation, secrets, and dependency security for this stack. The team standard is **defense in depth**: every tier (admin/insider/public) enforces its own auth + validation, financial entities are HMAC-signed at the data layer, secrets live in Vault (never in code or env files), and every release runs `govulncheck`.

## Table of Contents

1. [Authentication Per Tier (Admin / Insider / Public)](#1-authentication-per-tier)
2. [TOTP for Service-to-Service](#2-totp-for-service-to-service)
3. [HMAC Signing of Financial Entities](#3-hmac-signing-of-financial-entities)
4. [Input Validation: Proto Tags + Validator](#4-input-validation-proto-tags--validator)
5. [Secrets via Vault + Viper Cascade](#5-secrets-via-vault--viper-cascade)
6. [PII / Encrypted Fields (AES / RSA)](#6-pii--encrypted-fields-aes--rsa)
7. [Dependency Security (`govulncheck`, Snyk)](#7-dependency-security)
8. [SQL Injection Surface (Raw SQL, Go Migrations)](#8-sql-injection-surface)
9. [Rate Limiting](#9-rate-limiting)
10. [Anti-Patterns](#10-anti-patterns)

---

## 1. Authentication Per Tier

Each gRPC server tier has its own auth interceptor with different identity sources:

| Tier | Source | Identity | Interceptor |
|---|---|---|---|
| `admin` | Internal SSO / JWT | Admin user (`user_id`, `role`) | `AdminAuthInterceptor` |
| `insider` | Partner API key + TOTP | Partner system (`partner_id`) | `InsiderAuthInterceptor` |
| `public` | OAuth bearer token | End user (`user_id`, `tenant_id`) | `PublicAuthInterceptor` |

**Interceptor pattern (admin):**

```go
func AdminAuthInterceptor(jwtKey []byte) grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        if isPublicMethod(info.FullMethod) {
            return handler(ctx, req)  // health check, etc.
        }

        token, err := extractBearer(ctx)
        if err != nil {
            return nil, status.Error(codes.Unauthenticated, "missing token")
        }

        claims, err := verifyJWT(token, jwtKey)
        if err != nil {
            return nil, status.Error(codes.Unauthenticated, err.Error())
        }

        ctx = helpers.WithUserID(ctx, claims.UserID)
        ctx = helpers.WithTenantID(ctx, claims.TenantID)
        return handler(ctx, req)
    }
}
```

**Rules:**

- Auth interceptor MUST run AFTER the `sid` and `info` interceptors (so the auth failure log carries trace_id) but BEFORE the `zap` interceptor's business-level logging.
- `codes.Unauthenticated` for missing/invalid credentials; `codes.PermissionDenied` for valid credential but no permission.
- Never log the token itself, even at Debug. Log a hash if you need to correlate.

---

## 2. TOTP for Service-to-Service

Insider-tier endpoints (partner integrations) use TOTP on top of a long-lived API key — adds defense against key leakage.

**Verification:**

```go
func verifyTOTP(secret string, code string, window int) bool {
    // RFC 6238, SHA1, 6 digits, 30s step
    return totp.Validate(code, secret) ||
        (window > 0 && totp.ValidateCustom(code, secret, time.Now(), totp.ValidateOpts{
            Period:    30,
            Skew:      uint(window),  // accept ±N steps for clock skew
            Digits:    otp.DigitsSix,
            Algorithm: otp.AlgorithmSHA1,
        }))
}
```

**Rules:**

- `Skew` (clock tolerance) MUST be at most 1 (±30s). Larger windows weaken security.
- Store the TOTP secret encrypted (AES) in DB, decrypt only at verification time.
- Rate-limit TOTP attempts per partner — 5 failures in 60s → temporary block (see §9).
- Never log the secret or the candidate code.

See `references/provider-integration-patterns.md` §3 for the full insider auth flow.

---

## 3. HMAC Signing of Financial Entities

Financial entities (Order, Payment, Transaction, NAV) MUST implement the `Sign` interface. A row's HMAC is computed over canonical fields and stored in `sign` column; the row is verified on every read.

**Interface:**

```go
type Signable interface {
    GetSignData() string  // canonical concatenation of fields
    GetSign() string      // current signature
    SetSign(sign string)
}

func (e *Order) GetSignData() string {
    return fmt.Sprintf("%d|%s|%s|%d",
        e.ID,
        e.Amount.StringFixed(4),         // decimal with fixed precision
        e.CreatedAt.Unix(),              // unix timestamp, not RFC3339
        e.Status,
    )
}
```

**Rules — these are review-blocking:**

1. `StringFixed(4)` for decimals. Never `String()` — varying precision changes the signature silently.
2. `Unix()` for timestamps. Never RFC3339 — timezone formatting drift breaks signatures across services.
3. Field separator MUST be a character that cannot appear in any field value. The team standard is `|`.
4. NEVER include `updated_at` in sign data — it changes on every save, defeating signing.
5. NEVER include the `sign` field itself in `GetSignData()` — infinite recursion of intent.

**Verify on read:**

```go
func (r *OrderRepoImpl) Get(ctx context.Context) (*entity.Order, error) {
    defer r.clean()
    var order entity.Order
    if err := r.buildQuery(ctx).First(&order).Error; err != nil {
        return nil, err
    }
    if !hmac.VerifyHMAC(order.GetSignData(), order.GetSign(), r.hmacKey) {
        // Tampered or signature drift — alert and refuse
        logger.With(ctx).Error("HMAC mismatch", zap.Uint64("order_id", order.ID))
        return nil, errors.New("integrity check failed")
    }
    return &order, nil
}
```

**Sign on write:**

```go
func (r *OrderRepoImpl) Create(ctx context.Context, order *entity.Order) (*entity.Order, error) {
    defer r.clean()
    order.SetSign(hmac.Sign(order.GetSignData(), r.hmacKey))
    if err := r.buildQuery(ctx).Create(order).Error; err != nil {
        return nil, err
    }
    return order, nil
}
```

**Key rotation:** the HMAC key is versioned (`HMAC_KEY_V1`, `HMAC_KEY_V2`). Rows store the version they were signed with (`sign_version` column). On rotation, sign new rows with the current version and re-sign old rows lazily during update.

---

## 4. Input Validation: Proto Tags + Validator

Every request type (`XxxReqRPC`) field MUST have a `validate:"..."` tag (via `@gotags` magic comment). The controller's `c.Validator.Struct(req)` only enforces fields with a `validate` tag — missing tag = **silent acceptance**.

```proto
message CreateOrderReqRPC {
  // @gotags: validate:"required,min=1"
  uint64 tenant_id = 1;

  // @gotags: validate:"required,decimal_gt=0"
  string amount = 2;

  // @gotags: validate:"required,oneof=PENDING PROCESSING"
  string status = 3;

  // @gotags: validate:"omitempty,email"
  string notification_email = 4;
}
```

After `make protogen`, `*.pb.go` carries the `validate:` tag. Controller:

```go
func (c OrderControllerImpl) Create(ctx context.Context, req *adminv1.CreateOrderReqRPC) (*adminv1.CreateOrderResRPC, error) {
    if err := c.Validator.Struct(req); err != nil {
        // Validation errors → ParamError list → tier-coded response
        return c.Transformer.TransformWrapperCreateOrder(
            errorEnvelope("G-SYS-E-GEN-002"), nil, validationToParamErrors(err),
        ), nil
    }
    // ... build params, call service ...
}
```

**Common tags:**

| Tag | Purpose |
|---|---|
| `required` | Field must be present (non-zero) |
| `oneof=A B C` | Enum-like field, restricted values |
| `min=N` / `max=N` | Length or numeric bound |
| `email` / `uuid` / `url` | Standard format checks |
| `decimal_gt=0` / `decimal_gte=0` | Custom decimal validators |
| `omitempty` | Skip validation when empty |
| `eqfield=OtherField` | Cross-field check |
| `excluded_with=Other` | Mutually exclusive fields |

**Rules:**

- Validation runs at the controller, BEFORE the service. The service's Params validation (`MandatoryErrors`) is for business rules; `validate:` tags are for shape.
- For decimal/timestamp fields (proto type `string`), `required` alone is not enough — add `decimal_gt=0` or RFC3339 check.
- Tier-specific: public tier MUST validate more strictly than insider/admin (e.g., max length on string fields to prevent ReDoS).

→ See `proto-workflow.md` for the `@gotags` magic comment mechanics.

---

## 5. Secrets via Vault + Viper Cascade

Viper reads in this order; later sources override earlier:

1. Defaults (`viper.SetDefault`)
2. Config file (`.env`, `config.yaml`)
3. Environment variables
4. **Vault** (production secrets)

```go
// File: src/config/config.go
viper.SetConfigName("config")
viper.SetConfigType("yaml")
viper.AutomaticEnv()
viper.ReadInConfig()

if viper.GetBool("VAULT_ENABLED") {
    if err := vault.LoadSecrets(viper.GetViper()); err != nil {
        logger.Fatal("vault load failed", zap.Error(err))
    }
}
```

**Rules:**

- ALL of these MUST come from Vault in production: `DB_PASS`, `REDIS_PASS`, `HMAC_KEY_*`, `AES_KEY`, `RSA_PRIVATE_KEY`, `JWT_SIGNING_KEY`, `NATS_NKEY_SEED`, partner API keys.
- NEVER commit `.env` with real secrets. `.env.example` only.
- NEVER log a Vault-sourced value, even at Debug.
- Vault path convention: `secret/{env}/{service-name}/{key}` — single read populates Viper.

→ See `infrastructure.md` §5 for the full Viper + Vault wiring.

---

## 6. PII / Encrypted Fields (AES / RSA)

PII fields (national ID, full name, email, phone, bank account) use custom GORM types that transparently encrypt on write and decrypt on read.

**Custom types** (from `src/model/types/`):

| Type | Algorithm | Use |
|---|---|---|
| `types.AESString` | AES-GCM, key from `AES_KEY` | Symmetric — searchable via deterministic mode (with caveats) |
| `types.RSAString` | RSA-OAEP, key from `RSA_PUBLIC_KEY` | Asymmetric — encrypt-only side stores; decrypt requires private key |
| `types.HashString` | SHA-256 + salt | One-way — for lookup keys when you only need equality |

**Entity field:**

```go
type Customer struct {
    BaseEntity
    Name      types.AESString  `gorm:"type:varbinary(512)"`
    NationalID types.AESString `gorm:"type:varbinary(256);index"`  // searchable hash
    Email     types.AESString  `gorm:"type:varbinary(512)"`
}
```

**Rules:**

- AES key rotation requires re-encryption of all rows — plan downtime or use a versioned scheme.
- RSA fields cannot be searched (no deterministic encryption with RSA-OAEP). Use a hash field alongside if you need lookup.
- NEVER log decrypted PII. Logs use the encrypted form or a redacted placeholder.
- DTOs serialized to the wire MUST redact PII unless the tier's auth confirms the caller is authorized (e.g., admin-tier can see, public-tier cannot).

→ See `entity-patterns.md` §6 for the full type implementations.

---

## 7. Dependency Security

Every PR runs:

```bash
go mod tidy                 # detect drift
go build ./...              # compile
go vet ./...                # static analysis
golangci-lint run           # team config
govulncheck ./...           # CVE scan on dependencies + stdlib
```

`govulncheck` reports vulnerabilities **that the code actually reaches** (not just present in `go.sum`). Treat any reported vulnerability as blocking; either upgrade the package or document why the call path is unreachable.

**Snyk** (CI) covers SBOM + license compliance + transitive dependencies. Snyk findings are reviewed weekly; high-severity findings are tracked as P0 issues.

**Renovate / Dependabot** opens PRs for dependency bumps. Policy: merge patch/minor automatically after CI green; major bumps require manual review.

---

## 8. SQL Injection Surface

GORM with structs + `For*` builder generates parameterized SQL — no injection surface for normal use. The risk areas:

1. **Raw SQL in repository:**

```go
// ✗ Bad — string interpolation
db.Raw("SELECT * FROM orders WHERE status = '" + status + "'").Scan(&orders)

// ✓ Good — parameterized
db.Raw("SELECT * FROM orders WHERE status = ?", status).Scan(&orders)
```

2. **Goose Go migrations** — when using `func(*sql.Tx) error` migrations, hand-written SQL is your responsibility:

```go
func upAddIndex(tx *sql.Tx) error {
    // ✗ Bad — tableName comes from user-controlled source
    _, err := tx.Exec(fmt.Sprintf("CREATE INDEX idx_%s ON %s (status)", tableName, tableName))
    return err
}
```

For migrations, table/column names are static — if you find yourself interpolating them, restructure the migration to be specific.

3. **ORDER BY with user input:**

```go
// ✗ Bad — ORDER BY can't be parameterized
db.Raw("SELECT * FROM orders ORDER BY " + sortField).Scan(&orders)

// ✓ Good — whitelist
allowed := map[string]bool{"created_at": true, "amount": true}
if !allowed[sortField] {
    return nil, errors.New("invalid sort field")
}
db.Order(sortField).Find(&orders)
```

---

## 9. Rate Limiting

Per-tier limits enforced in middleware via Redis token bucket:

| Tier | Default | Granularity |
|---|---|---|
| `admin` | 1000 req/min/user | per user_id |
| `insider` | 600 req/min/partner | per partner_id |
| `public` | 60 req/min/user, 600 req/min/IP | per user_id + IP |

**Implementation sketch:**

```go
func RateLimitInterceptor(rdb *redis.Client, limit int, window time.Duration) grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        key := rateLimitKey(ctx, info.FullMethod)
        n, err := rdb.Incr(ctx, key).Result()
        if err != nil {
            return handler(ctx, req)  // fail open on Redis error — log and continue
        }
        if n == 1 {
            rdb.Expire(ctx, key, window)
        }
        if n > int64(limit) {
            return nil, status.Error(codes.ResourceExhausted, "rate limit exceeded")
        }
        return handler(ctx, req)
    }
}
```

**Fail-open policy:** if Redis is down, requests pass through. Alternative (fail-closed) is safer but causes outages on a Redis blip — team standard is fail-open + monitor.

**Sensitive endpoints** (login, TOTP verify, password reset) get stricter limits and lock the account after N failures regardless of Redis state.

---

## 10. Anti-Patterns

| Anti-pattern | Impact | Fix |
|---|---|---|
| Missing `validate:` tag on `XxxReqRPC` field | Silent acceptance of invalid input → downstream crash or business-rule bypass | Add `@gotags: validate:"..."` in `.proto`, rerun `make protogen` |
| Hand-editing `*.pb.go` to add validation | Lost on next `make protogen` | Use `@gotags` in `.proto` source |
| Hardcoded secret in `config.yaml` committed to git | Credential leak | Move to Vault; rotate the leaked credential |
| Logging the token / TOTP secret / decrypted PII | Secret in log aggregation | Log a hash or redacted placeholder |
| HMAC sign using `String()` instead of `StringFixed(4)` | Signature drifts when precision varies | Always `StringFixed(4)` for decimal |
| Skipping `govulncheck` in CI | Known CVE ships to prod | Make it blocking on every PR |
| Raw SQL with string concat | SQL injection | Parameterized query (`?` placeholders) |
| Fail-closed rate limiting tied to Redis | Redis blip → service outage | Fail-open + alert on Redis health (team standard) |
| `codes.Internal` for auth failures | Leaks information about the failure mode | `codes.Unauthenticated` (missing/invalid creds) or `codes.PermissionDenied` (insufficient permission) |
| Storing TOTP secret in plaintext | Single DB breach compromises all partners | AES-encrypted with rotation policy |
| RBAC checked in service but not in interceptor | Bypassable if a controller forgets to call the check | Enforce in auth interceptor; service can add finer-grained checks on top |

---

## Cross-References

- → See `entity-patterns.md` §5 for the Sign interface details and Signable trait
- → See `provider-integration-patterns.md` §3 for the full insider TOTP flow
- → See `proto-workflow.md` for `@gotags` mechanics
- → See `infrastructure.md` §5 (Vault) and §6 (encryption types)
- → See `context-patterns.md` §1 for tenant/user identity propagation
- → See `samber/cc-skills-golang@golang-security` for Go-generic security patterns (OWASP, supply chain)
