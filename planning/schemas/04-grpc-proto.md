# 04 — gRPC Proto Definitions (saruman ↔ palantir-gateway)

> Internal RPCs between saruman (engine) and palantir-gateway (provider broker).
> Used for: CreateTopUp, SettleTopUp, CreateWithdrawal, SettleWithdrawal, CreateRefund.
> Auth via shared header: `authorization: Bearer <engine-api-key>`.

---

## File: `palantir/v1/topup.proto`

```protobuf
syntax = "proto3";
package inflora.palantir.v1;

option go_package = "github.com/frederickmarvel/inflora-shared/gen/go/palantir/v1;palantirv1";

// ---------- CreateTopUp ----------

message CreateTopUpRequest {
  string saruman_donation_id = 1;     // uuid, links to donations.id
  string streamer_id         = 2;     // uuid
  int64  amount_idr          = 3;     // minor units
  string currency            = 4;     // "IDR"
  string donor_display_name  = 5;     // optional
  string message             = 6;     // optional, <=500 chars
  bool   is_anonymous        = 7;
  string client_ip           = 8;
  string user_agent          = 9;
  string idempotency_key     = 10;    // uuid, for palantir-palantir idempotency
  int64  expires_at_unix     = 11;    // unix seconds
}

message CreateTopUpResponse {
  string charge_id      = 1;          // provider charge ID
  string payment_url    = 2;          // URL to redirect donor
  string provider_name  = 3;          // "midtrans", "xendit", "pivot"
  int64  expires_at_unix = 4;
}

// ---------- SettleTopUp ----------

message SettleTopUpRequest {
  string provider_event_id = 1;       // from webhook
  string provider_name     = 2;
  string charge_id         = 3;       // from CreateTopUp response
  bytes  raw_payload       = 4;       // original webhook body (for audit)
}

message SettleTopUpResponse {
  string donation_id             = 1;  // saruman's donation.id
  string ledger_correlation_id  = 2;  // links ledger entries from same txn
  int64  platform_fee_idr       = 3;
  int64  net_idr                = 4;
  string provider_charge_id     = 5;
}

// ---------- Service ----------

service TopUpService {
  rpc CreateTopUp(CreateTopUpRequest) returns (CreateTopUpResponse);
  rpc SettleTopUp(SettleTopUpRequest) returns (SettleTopUpResponse);
}
```

---

## File: `palantir/v1/withdrawal.proto`

```protobuf
syntax = "proto3";
package inflora.palantir.v1;

option go_package = "github.com/frederickmarvel/inflora-shared/gen/go/palantir/v1;palantirv1";

message CreateWithdrawalRequest {
  string saruman_payout_id    = 1;     // uuid, links to payouts.id
  string streamer_id          = 2;
  int64  amount_idr           = 3;
  string bank_account_ref     = 4;     // palantir's internal ref (encrypted)
  string idempotency_key      = 5;
  int64  requested_at_unix    = 6;
}

message CreateWithdrawalResponse {
  string provider_payout_id = 1;
  string status             = 2;     // "PROCESSING"
}

message SettleWithdrawalRequest {
  string provider_payout_id = 1;
  string provider_event_id  = 2;
  bytes  raw_payload        = 3;
}

message SettleWithdrawalResponse {
  string payout_id         = 1;
  string status             = 2;     // "SETTLED" | "FAILED"
  string failure_code      = 3;     // optional
  string bank_reference    = 4;     // optional
}

service WithdrawalService {
  rpc CreateWithdrawal(CreateWithdrawalRequest) returns (CreateWithdrawalResponse);
  rpc SettleWithdrawal(SettleWithdrawalRequest) returns (SettleWithdrawalResponse);
}
```

---

## File: `palantir/v1/refund.proto`

```protobuf
syntax = "proto3";
package inflora.palantir.v1;

option go_package = "github.com/frederickmarvel/inflora-shared/gen/go/palantir/v1;palantirv1";

message CreateRefundRequest {
  string saruman_refund_id    = 1;     // uuid
  string donation_id          = 2;
  string streamer_id          = 3;
  int64  amount_idr           = 4;     // full or partial
  string reason               = 5;     // "ADMIN_REFUND" | "USER_REQUEST" | "CHARGEBACK"
  string idempotency_key      = 6;
}

message CreateRefundResponse {
  string provider_refund_id = 1;
  string status             = 2;     // "PROCESSING"
}

service RefundService {
  rpc CreateRefund(CreateRefundRequest) returns (CreateRefundResponse);
}
```

---

## File: `palantir/v1/health.proto`

```protobuf
syntax = "proto3";
package inflora.palantir.v1;

option go_package = "github.com/frederickmarvel/inflora-shared/gen/go/palantir/v1;palantirv1";

import "google/protobuf/empty.proto";

message HealthCheckResponse {
  enum ServingStatus {
    UNKNOWN = 0;
    SERVING = 1;
    NOT_SERVING = 2;
  }
  ServingStatus status = 1;
  string version       = 2;
  int64  uptime_seconds = 3;
}

service HealthService {
  rpc Check(google.protobuf.Empty) returns (HealthCheckResponse);
}
```

---

## gRPC metadata (headers)

Every request MUST include:

```
authorization: Bearer <engine-api-key>
x-request-id:   <uuid>           # propagated from HTTP layer
x-correlation-id: <uuid>          # optional, groups related calls
x-causation-id:  <uuid>           # optional, parent request
x-trace-id:                       # from OpenTelemetry context
```

Server attaches:

```
x-request-id: <uuid>              # echoed or generated
```

---

## Error mapping

gRPC errors map to HTTP status:

| gRPC code | HTTP | Notes |
|---|---|---|
| `OK` | 200 | Success |
| `INVALID_ARGUMENT` | 400 | Validation failed |
| `UNAUTHENTICATED` | 401 | Bad engine API key |
| `PERMISSION_DENIED` | 403 | Streamer inactive |
| `NOT_FOUND` | 404 | Donation not found |
| `ALREADY_EXISTS` | 409 | Idempotency conflict |
| `FAILED_PRECONDITION` | 422 | State machine violation |
| `RESOURCE_EXHAUSTED` | 429 | Rate limited |
| `INTERNAL` | 500 | |
| `UNAVAILABLE` | 503 | Provider down |

Use `google.rpc.Status` with `details` for structured error info.

```json
{
  "code": 3,
  "message": "donation not in CHARGED state",
  "details": [
    {
      "@type": "type.googleapis.com/inflora.palantir.v1.ErrorInfo",
      "code": "DONATION_NOT_CHARGED",
      "donation_id": "abc-123",
      "current_status": "REFUNDED"
    }
  ]
}
```

---

## Connection settings

- TLS: required in production (palantir uses Let's Encrypt or internal CA).
- Keepalive: client sends keepalive every 30s, server expects ping every 60s.
- Timeout: per-RPC timeout (e.g., CreateTopUp 5s, SettleTopUp 30s).
- Retries: only for `UNAVAILABLE` and `INTERNAL`, with backoff. Never for `INVALID_ARGUMENT` etc.
- Max message size: 4 MB.

---

## Code generation

For Go, use `buf`:

```yaml
# buf.gen.yaml
version: v1
plugins:
  - name: go
    out: gen/go
    opt: paths=source_relative
  - name: go-grpc
    out: gen/go
    opt: paths=source_relative
```

For TypeScript (if dashboard uses gRPC-web):

```yaml
plugins:
  - name: ts
    out: gen/ts
    opt: paths=source_relative
  - name: grpc-web
    out: gen/ts
    opt: paths=source_relative
```

(Note: dashboard uses REST, not gRPC. gRPC is internal only.)

---

*Pin this file. Proto changes require a major version bump of the package.*