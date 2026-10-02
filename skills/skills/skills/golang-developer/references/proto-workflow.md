# Proto Workflow

The team's `make protogen` pipeline, `buf` configuration, `protoc-go-inject-tag` magic comments, and `buf breaking` policy. This is the **authoritative** reference for any task that touches a `.proto` file. If `grpc-patterns.md` and this file disagree, this file wins.

## Table of Contents

1. [Golden Rule: `make protogen` Only](#1-golden-rule-make-protogen-only)
2. [Pipeline: What `make protogen` Does](#2-pipeline-what-make-protogen-does)
3. [`buf` Configuration](#3-buf-configuration)
4. [`@gotags` Magic Comments](#4-gotags-magic-comments)
5. [Field Type Mapping (Proto ↔ Go ↔ DB)](#5-field-type-mapping)
6. [Naming Conventions](#6-naming-conventions)
7. [`buf breaking` Policy](#7-buf-breaking-policy)
8. [REST Gateway (`google.api.http`)](#8-rest-gateway-googleapihttp)
9. [Versioning & Field Numbers](#9-versioning--field-numbers)
10. [Troubleshooting](#10-troubleshooting)
11. [Anti-Patterns](#11-anti-patterns)

---

## 1. Golden Rule: `make protogen` Only

**ALWAYS run `make protogen`. NEVER call `protoc` or `buf generate` directly.**

The reason: `buf generate` emits `*.pb.go` without honoring `// @gotags:` magic comments. Those magic comments are what give every request field its `validate:"..."` struct tag. Without them, `c.Validator.Struct(req)` validates nothing — silent acceptance of invalid input. This is a security AND correctness issue.

`make protogen` runs the full pipeline in order:

1. `buf lint` — block on style violations
2. `buf generate` — emit `*.pb.go`, `*.pb.gw.go`, `*.swagger.json`
3. `protoc-go-inject-tag -input=...` — apply `@gotags` into `*.pb.go`

If any step fails, the others don't run. The Makefile target:

```makefile
.PHONY: protogen
protogen:
	buf lint
	buf generate
	find ./proto -name '*.pb.go' -exec protoc-go-inject-tag -input={} \;
	@echo "✓ protogen complete"
```

This is a **review-blocking rule.** Any PR that runs `buf generate` standalone (visible in CI logs or commit history) MUST be rejected and redone via `make protogen`.

---

## 2. Pipeline: What `make protogen` Does

Detailed flow for any file under `proto/nav/{admin,insider,public}/v1/`:

```
proto/nav/admin/v1/order.proto
        │
        ├─[1] buf lint
        │      ├── package convention (nav.admin.v1)
        │      ├── field naming (snake_case)
        │      ├── service naming (UpperCamel + Service suffix optional)
        │      └── enum value naming (UPPER_SNAKE)
        │
        ├─[2] buf generate
        │      ├── *.pb.go            (gRPC server/client)
        │      ├── *.pb.gw.go         (REST gateway)
        │      ├── *.swagger.json     (OpenAPI / Swagger UI)
        │      └── *.pb.validate.go   (if protoc-gen-validate enabled)
        │
        └─[3] protoc-go-inject-tag -input=*.pb.go
               └── Replaces struct tags per // @gotags: lines
                   in the .proto source
```

After `protogen`, generated files MUST be checked into git (team standard — no "generate at build time"). Reviewers see the diff and can spot accidental breaking changes.

`buf breaking` is a separate, manual step (see §7) — run before pushing PRs that change tier-public protos.

---

## 3. `buf` Configuration

`buf.yaml` (root):

```yaml
version: v2
modules:
  - path: proto
lint:
  use:
    - STANDARD
  except:
    - PACKAGE_VERSION_SUFFIX  # we use /v1/ in path, not package
breaking:
  use:
    - FILE
```

`buf.gen.yaml` (root):

```yaml
version: v2
plugins:
  - remote: buf.build/protocolbuffers/go
    out: proto
    opt: paths=source_relative
  - remote: buf.build/grpc/go
    out: proto
    opt: paths=source_relative,require_unimplemented_servers=true
  - remote: buf.build/grpc-ecosystem/gateway
    out: proto
    opt: paths=source_relative,generate_unbound_methods=true
  - remote: buf.build/grpc-ecosystem/openapiv2
    out: proto
    opt: allow_merge=true,merge_file_name=swagger
```

**Rules:**

- `require_unimplemented_servers=true` forces controllers to embed `UnimplementedXxxServer` (forward compatibility — new RPCs don't break existing impls).
- `paths=source_relative` keeps generated files alongside the `.proto` source — predictable for imports.
- Lint rules: `STANDARD` set + we exclude `PACKAGE_VERSION_SUFFIX` because the team layout puts version in the directory path, not the package name.

---

## 4. `@gotags` Magic Comments

Use these to inject struct tags into generated Go structs. `protoc-go-inject-tag` reads comments of the form `// @gotags: <tag-content>` placed **directly above the field**.

```proto
message CreateOrderReqRPC {
  // @gotags: validate:"required,min=1"
  uint64 tenant_id = 1;

  // @gotags: validate:"required,decimal_gt=0"
  string amount = 2;

  // @gotags: validate:"required,oneof=PENDING PROCESSING"
  string status = 3;

  // @gotags: validate:"omitempty,email" json:"notification_email,omitempty"
  string notification_email = 4;
}
```

After `make protogen`:

```go
type CreateOrderReqRPC struct {
    TenantID          uint64 `protobuf:"varint,1,opt,name=tenant_id,proto3" json:"tenant_id,omitempty" validate:"required,min=1"`
    Amount            string `protobuf:"bytes,2,opt,name=amount,proto3" json:"amount,omitempty" validate:"required,decimal_gt=0"`
    Status            string `protobuf:"bytes,3,opt,name=status,proto3" json:"status,omitempty" validate:"required,oneof=PENDING PROCESSING"`
    NotificationEmail string `protobuf:"bytes,4,opt,name=notification_email,proto3" json:"notification_email,omitempty" validate:"omitempty,email"`
}
```

**Rules — exact syntax matters:**

| Form | Result |
|---|---|
| `// @gotags: validate:"..."` | ✓ Recognized |
| `// gotags: validate:"..."` | ✗ Silently ignored — missing `@` |
| `// @gotag: validate:"..."` | ✗ Silently ignored — missing `s` |
| `// @gotags:validate:"..."` (no space) | ✓ Recognized (but team style: include the space) |
| Multi-tag: `// @gotags: validate:"required" json:"foo,omitempty"` | ✓ Both injected |
| Multi-line `@gotags` | ✗ Each field needs its own one-liner |

**Common validator tags** — also see `security.md` §4 for the full list:

- `required` — non-zero value
- `omitempty` — skip validation when empty
- `min=N` / `max=N` — length or numeric
- `oneof=A B C` — enum-like
- `decimal_gt=0` — custom for decimal strings
- `email` / `uuid` / `url`
- `eqfield=Other` — match another field

---

## 5. Field Type Mapping

| Domain | Proto type | Go type after gen | DB type (GORM tag) | Notes |
|---|---|---|---|---|
| Snowflake ID | `uint64` | `uint64` | `BIGINT UNSIGNED` | Use `BaseEntitySF` |
| Tenant/Partner ID | `uint64` | `uint64` | `BIGINT UNSIGNED` | — |
| Money / Decimal | **`string`** | `string` (then parsed to `decimal.Decimal`) | `DECIMAL(20,8)` | NEVER use proto `double` for money |
| Timestamp | **`string`** (RFC3339) | `string` (then parsed to `time.Time`) | `TIMESTAMP NULL` | NEVER use `google.protobuf.Timestamp` if it crosses a tier boundary; stay consistent |
| Boolean | `int32` or `optional bool` | `int32` or `*bool` | `tinyint(1)` | Go entity uses `int`, NEVER `bool` |
| Enum | `enum` | generated Go enum | `VARCHAR(32)` | Store the string name in DB, convert at transform |
| Long text | `string` | `string` | `TEXT` | — |
| Optional scalar | `optional string` | `*string` | nullable column | Use sparingly — `omitempty` on the JSON tag often suffices |

**Why `string` for decimal and timestamp:**

- `double` loses precision for money — non-negotiable
- `google.protobuf.Timestamp` is technically correct but introduces a dependency between API contracts and proto library versions; team chose stable RFC3339 strings to decouple

**Transform layer** (`engine/grpc/transformer/`) converts string → `decimal.Decimal` / `time.Time` on the way in and back on the way out.

---

## 6. Naming Conventions

| Element | Convention | Example |
|---|---|---|
| File | `<domain>.proto` | `order.proto`, `customer.proto` |
| Package | `nav.<tier>.v<N>` | `nav.admin.v1` |
| Service | `<Domain>Service` | `OrderService` |
| Request | `<Action><Domain>ReqRPC` | `CreateOrderReqRPC` |
| Response | `<Action><Domain>ResRPC` | `CreateOrderResRPC` |
| Data | `<Domain>Data` | `OrderData` |
| Field | `snake_case` | `tenant_id`, `created_at` |
| Enum | `UPPER_SNAKE` | `STATUS_PENDING` |

**Three-tier rule:** the SAME domain (e.g., Order) has separate proto files in admin/insider/public — they share concepts but the API surface differs. Don't try to share a single proto across tiers.

---

## 7. `buf breaking` Policy

Tiers carry different SLAs:

| Tier | `buf breaking` policy | Why |
|---|---|---|
| `proto/nav/admin/v1/` | Block on breaking; require migration plan | Internal callers are this team — coordinated |
| `proto/nav/insider/v1/` | **Block** on breaking; require partner notification | External partners depend; SLA-bound |
| `proto/nav/public/v1/` | **Block** on breaking; require deprecation cycle | End-user clients (mobile/web); long migration |

Run before push:

```bash
buf breaking --against '.git#branch=main'
```

If breaking changes are needed:

1. Add the new field/RPC as a new field number / new RPC (`v2` if a full surface bump)
2. Deprecate the old (`option deprecated = true`) — generators emit `// Deprecated:` Go comments
3. Communicate to consumers; keep both for the deprecation window
4. Remove only after consumers migrate (CI dashboard tracking which consumers still call the deprecated path)

**Field number rules:**

- Never reuse a field number, even after deletion. `reserved 8, 15;` to lock them.
- Never rename a field once shipped — proto wire uses the number, but JSON uses the name; renaming breaks REST clients silently.

---

## 8. REST Gateway (`google.api.http`)

REST routes are declared as proto annotations:

```proto
import "google/api/annotations.proto";

service OrderService {
  rpc CreateOrder(CreateOrderReqRPC) returns (CreateOrderResRPC) {
    option (google.api.http) = {
      post: "/admin/orders"
      body: "*"
    };
  }
  rpc GetOrder(GetOrderReqRPC) returns (GetOrderResRPC) {
    option (google.api.http) = {
      get: "/admin/orders/{id}"
    };
  }
}
```

**Rules:**

- Path prefix mirrors the tier: `/admin/...`, `/insider/...`, `/public/...`.
- `body: "*"` for POST/PUT; specific field name to bind to body.
- Path parameters MUST exist as fields in the request message.
- Query parameters auto-bind for GET; document them with comments above the field.

→ See `rest-gateway.md` for the runtime side (`GRPCGatewayServer`, header forwarding).

---

## 9. Versioning & Field Numbers

Each tier directory has `v1/`. When `v2` is unavoidable:

1. Create `proto/nav/admin/v2/` with the new surface
2. Run both v1 and v2 services in parallel during migration window
3. v1 is frozen — no new RPCs added; only bug-fix patches
4. Sunset v1 after all consumers migrate

Inside a major version, fields can be ADDED freely. Field numbers must be increasing (`= 7`, `= 8`, ...). Use `reserved` for any deleted numbers AND names:

```proto
message Order {
  reserved 8, 15;
  reserved "old_field_name";  // prevent name reuse
}
```

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `validate:"..."` not in `*.pb.go` after generation | `buf generate` ran without `protoc-go-inject-tag` step | Re-run `make protogen` |
| `protoc-go-inject-tag` reports "no inject tags found" | `@gotags` typo (missing `s`, wrong comment style) | Verify `// @gotags:` exact form |
| `buf lint` fails on PACKAGE_VERSION_SUFFIX | Lint rule not excluded | Check `buf.yaml` — we exclude that rule (§3) |
| Build breaks after pull | Stale generated code | `make protogen` |
| Validator passes invalid input | Field missing `validate:` tag | Add via `@gotags` |
| REST request returns 405 | Missing `google.api.http` annotation | Add option block |
| `buf breaking` flags a field rename | Wire-compatible but JSON-breaking | Don't rename; add a new field, deprecate the old |
| `Unimplemented method` after adding RPC | Controller missing the new method | Run `make protogen` then implement the method or rely on `Unimplemented...Server` |

---

## 11. Anti-Patterns

| Anti-pattern | Impact | Fix |
|---|---|---|
| `buf generate` directly (CI or local) | Strips inject-tag → silent validation bypass | `make protogen` always |
| Hand-editing `*.pb.go` | Lost on next generation | Use `@gotags` in `.proto`; for other tweaks, the proto needs to change |
| Reusing a deleted field number | Wire collision; old clients misinterpret bytes | `reserved N;` |
| Renaming a shipped field | REST JSON breaks silently | Add new field, deprecate old, never rename |
| Using `double` for money | Float precision loss on cents | `string` proto → `decimal.Decimal` |
| `google.protobuf.Timestamp` mixed with plain `string` timestamps | Inconsistent client handling | Pick one per tier and stick |
| Sharing one proto across admin/insider/public | Tiers diverge over time; one becomes accidentally exposed to wrong audience | Separate proto file per tier |
| Skipping `buf breaking` for insider/public | Silent partner/client breakage | Make it a CI step that blocks on PRs to those dirs |
| `// gotags:` (missing `@`) | Silently ignored — fields have no validation | Use `// @gotags:` exactly |

---

## Cross-References

- → See `grpc-patterns.md` for controller wiring, interceptors, transformers
- → See `rest-gateway.md` for the REST runtime (`GRPCGatewayServer`, CORS, auth)
- → See `security.md` §4 for the validator tags and tier-specific validation policy
- → See `entity-patterns.md` for entity ↔ DTO ↔ proto mapping (the Transform layer)
- → See `samber/cc-skills-golang@golang-grpc` for Go-generic gRPC patterns
