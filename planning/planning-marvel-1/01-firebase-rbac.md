# 01 — Firebase Authentication + Database RBAC (SUPERADMIN / ADMIN / USER)

> Planning only. Target: "Use Firebase as the Authentication" for human users, with roles **authoritative in the Inflora database** (`SUPERADMIN`, `ADMIN`, `USER`).
> Binding rule (from README safety rules): **Firebase ID tokens are verified at a trust boundary; the browser never supplies a role the server trusts. Roles are resolved server-side from the DB.**
> Distinguish **identity** (who you are — Firebase) from **authorization** (what you may do — Inflora DB).

---

## 1. Decisions made in this plan (RECOMMENDED — owner must ack before implementation)

These are explicit decisions; they were previously open. If the owner changes one, update this section AND `05-phases-and-gates.md` §2 immediately.

| ID | Decision | Rationale |
|---|---|---|
| A-1 | **"USER" = a Streamer.** The three requested roles map to: `USER` = streamer (dashboard user), `ADMIN` = backoffice operator, `SUPERADMIN` = backoffice owner. Donors stay anonymous (no role). | Matches the product: humans who log in are streamers or staff. |
| A-2 | **One Firebase project, one tenant.** No Firebase multi-tenancy at MVP. A single `streamers` and a single `admin_users` table; Firebase UIDs are globally unique so no tenant scoping is required. | Multi-tenant would add custom-token minting and per-tenant claims — unnecessary complexity. |
| A-3 | **Single human-identity table `identities`** mapping `firebase_uid → (principal_kind, principal_id)`. `principal_kind ∈ {STREAMER, BACKOFFICE}`. `roles` and `permissions` tables are the authorization source. (Schema in §4.) | One place to answer "who is this Firebase user"; keeps admin_users/streamers as profile tables. |
| A-4 | **Firebase ID token verification lives only in Tolkien** (the human-facing HTTP facade), in new middleware `inflora-tolkien/internal/middleware/firebase.go`. Verification = JWKS fetch + local verification (alg RS256, `aud` = Firebase project ID, `exp`, `iss = https://securetoken.google.com/<project>`), with a 5-minute JWKS cache. No other service verifies human tokens. | Single trust boundary; matches "all human HTTP goes through tolkien". |
| A-5 | **Pass-through + bridge (two-phase cutover).** Target state: the browser holds a Firebase ID token (Firebase SDK auto-refresh) and sends `Authorization: Bearer <firebase-id-token>` on every dashboard/backoffice call; Tolkien verifies it, resolves role from DB per request (fresh revocation). Migration state: a **bridge endpoint** `POST /v1/auth/firebase/exchange` accepts a verified Firebase ID token and returns the legacy opaque `sk_`/`ak_` session, so the existing frontend keeps working during rollout. `sk_` legacy login paths are removed only in the final phase with telemetry proof (§7). | Preserves a tested rollback path; makes role revocation immediate (no 30-day stale `sk_`). |
| A-6 | **Roles are not additive by default.** The three roles are the complete list; `permissions` rows map role→permission explicitly. Additive composition is only allowed for the OPERATOR-defined custom backoffice roles (deferred, Phase N). At MVP: exact set `{SUPERADMIN, ADMIN, USER}`. | The user asked for exactly three roles; additive role composition is the classic source of accidental privilege. |
| A-7 | **`admin_role` enum retirement path:** migration adds new `app_role` enum `{SUPERADMIN, ADMIN, USER}` + `identities.roles` bridge; legacy `admin_role {ADMIN,FINOPS,OPS}` is mapped (`FINOPS`→`ADMIN[payout:*]+…` explicit permission mapping; `OPS`→`ADMIN`), then dropped in the cleanup migration once telemetry shows zero legacy logins. | No silent role loss; explicit mapping table in §5. |
| A-8 | **First SUPERADMIN bootstrap:** seeded by migration only (like `00008_seed_admin`), with a placeholder Firebase UID that must be replaced by the deployer via a **one-time, audited CLI command** (`tolkien admin bootstrap --firebase-uid <uid>`) before prod go-live. No self-registering SUPERADMIN, ever. | Prevent bootstrapped-admin squatting via public signup. |
| A-9 | **Overlay tokens (`ok_`) are unchanged.** OBS is a machine client; Firebase interactive login is impossible there. ws-gateway continues to validate `ok_` via `POST /v1/internal/validate-overlay-token`. | Frozen contract; no drift needed. |
| A-10 | **Service-to-service auth unchanged** (`X-Internal-Api-Key` / engine-api-key bearer gRPC). Firebase touches human edges only. | No reason to churn internal wiring. |

## 2. Concept model

```
Firebase Auth            Inflora DB (authoritative authorization)
─────────────            ──────────────────────────────────────────
UID (sub)              → identities.firebase_uid (UNIQUE)
                            ├─ principal_kind = STREAMER   → principal_id → streamers.id
                            └─ principal_kind = BACKOFFICE → principal_id → admin_users.id
email (claims)         → NOT trusted for identity; only displayed
custom claims (roles)  → OPTIONAL mirror for cache/UI. Never the sole source
                         (verified per README rule: DB is authoritative)
```

Enforcement points:
- **Identity**: Firebase verification (middleware) → `firebase_uid`.
- **Authorization**: DB lookup by `firebase_uid` (tolkien repo) → `roles`/`permissions` → per-route requirement.
- **Ownership** (a USER may only touch their own streamer resources): principal→streamer binding from `identities`; handlers must check `resource.owner == principal.streamer_id` (the existing `/v1/me/*` pattern does this implicitly via `Principal.StreamerID`).

## 3. Firebase configuration

| Item | Value / rule |
|---|---|
| Firebase project id | single env `FIREBASE_PROJECT_ID` (e.g. `inflora-prod`, `inflora-staging` per environment) |
| Auth providers | Email/password minimum; Google sign-in optional in a later phase. **No anonymous auth for the dashboard.** Anonymous auth MAY be used later for donors (Phase N, not planned here). |
| `FIREBASE_AUDIENCE` | = `FIREBASE_PROJECT_ID` (the `aud` claim) |
| Service account | Only needed for (a) Admin SDK custom-claims (optional mirror) and (b) bootstrap tooling. **Token verification does NOT need a service account — use public JWKS + `google.golang.org/api/idtoken` or firebase Admin SDK `auth.VerifyIDToken`.** |
| Env vars (tolkien) | `FIREBASE_PROJECT_ID`, `FIREBASE_JWKS_CACHE_TTL_SEC=300`, `FIREBASE_TOKEN_ISSUER=https://securetoken.google.com/<project>` |
| The frontend | Uses the Firebase Web SDK (`firebase/auth`). Config is public (`firebaseConfig`) — that is normal and safe; secrets are never in it. |

## 4. Database schema (migration sequence)

New migration files in `inflora-saruman/migrations/` (Saruman is the sole migration runner; do NOT create a migration runner in tolkien):

**`00009_firebase_identities.up.sql`**

```sql
CREATE TYPE app_role AS ENUM ('SUPERADMIN', 'ADMIN', 'USER');
CREATE TYPE principal_kind AS ENUM ('STREAMER', 'BACKOFFICE');

CREATE TABLE identities (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  firebase_uid    VARCHAR(128) NOT NULL UNIQUE,
  principal_kind  principal_kind NOT NULL,
  principal_id    UUID NOT NULL,          -- streamers.id OR admin_users.id
  email           CITEXT NOT NULL,        -- requires CREATE EXTENSION IF NOT EXISTS citext
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_principal_matches_kind CHECK ( -- enforced app-side; FK polymorphic note below
    (principal_kind = 'STREAMER' AND EXISTS (SELECT 1 FROM streamers s WHERE s.id = principal_id)) OR
    (principal_kind = 'BACKOFFICE' AND EXISTS (SELECT 1 FROM admin_users a WHERE a.id = principal_id))
  )
);
CREATE INDEX idx_identities_kind ON identities (principal_kind, principal_id);
```

> Polymorphic FK note: Postgres cannot FK two tables in one column with a runtime-kind discriminator;
> the CHECK above is the pragmatic enforcement, plus an application-side invariant test. Alternative
> (cleaner but more churn): add `firebase_uid CITEXT UNIQUE NULL` directly to `streamers` and `admin_users`.
> **Recommended**: use columns on both tables instead of a polymorphic `identities` table —
> `ALTER TABLE streamers ADD COLUMN firebase_uid CITEXT UNIQUE; ALTER TABLE admin_users ADD COLUMN firebase_uid CITEXT UNIQUE;`
> and a view `v_identities` UNIONS them. This keeps FKs real. Choose this variant unless the reviewer prefers the table.

```sql
CREATE TABLE roles (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        app_role NOT NULL UNIQUE,
  description TEXT NOT NULL DEFAULT ''
);

CREATE TABLE permissions (
  id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name  VARCHAR(80) NOT NULL UNIQUE,      -- e.g. 'PayoutBatch:Create'
  description TEXT NOT NULL DEFAULT ''
);

CREATE TABLE role_permissions (
  role_id       UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_id UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

-- Role assignment tables (DB-authoritative):
CREATE TABLE admin_roles (
  admin_user_id UUID NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  role_id       UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  granted_by    UUID NOT NULL REFERENCES admin_users(id),
  granted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (admin_user_id, role_id)
);
-- USER role for streamers is implicit: every active streamer IS a USER.
-- (Explicit streamer_roles table is unnecessary at three-role scope; add only if custom roles arrive.)

-- Admin table gains the Firebase column and softer password requirement:
ALTER TABLE admin_users ADD COLUMN firebase_uid CITEXT UNIQUE;
ALTER TABLE admin_users ALTER COLUMN password_hash DROP NOT NULL;  -- Firebase-managed accounts have no local password
```

**Data migration (same migration file or `00010`):**
1. Insert roles: `SUPERADMIN`, `ADMIN`, `USER`.
2. Insert MVP permissions and map them (table §5).
3. Backfill `identities`/`firebase_uid` for **existing dev-only** users by convention — only the seeded dev accounts exist pre-prod; production backfill is a CLI command (Phase R, see `05-phases-and-gates.md`).
4. Map legacy roles: for each `admin_users` row, `role=FINOPS → ADMIN` + `PayoutBatch:*, FundHold:*, Withdrawal:Review` (see §5 mapping); `role=OPS → ADMIN` + monitoring-only; `role=ADMIN → ADMIN` (full MVP permission set minus anything reserved for SUPERADMIN). Record the mapping in `audit_log` with `action='ROLE_MIGRATION'`.

**Clean-up migration** (`00011_drop_legacy_admin_role`, scheduled in the final phase): `DROP TYPE admin_role` after `admin_users.role` column is dropped and all code switched; keep `admin_sessions.password_hash` column for break-glass (see §8).

## 5. Permission matrix (MVP)

Route requirements are checked by middleware `requireRole(...)` / `requirePerm("perm")` in tolkien.

| Permission | Meaning | USER | ADMIN | SUPERADMIN |
|---|---|---|---|---|
| `Me:Read` | `/v1/me*` own resources | ✓ | ✓ (impersonate only via dedicated flow) | ✓ |
| `Settings:Write` | own settings | ✓ | — | — |
| `BankAccount:Write` | own bank accounts | ✓ | — | — |
| `OverlayToken:Rotate` | own overlay token | ✓ | — | — |
| `Payout:Create` | create own payout (`POST /v1/me/payouts`) | ✓ | — (admin does not pay out themselves) | — |
| `Donation:Read` (`/v1/me/donations`) | own donations | ✓ | ✓ | ✓ |
| `Donation:ReadAll` | backoffice donation console | — | ✓ | ✓ |
| `Donation:Override` | force stuck donation terminal | — | ✓ | ✓ |
| `FundHold:Create/Read/Release` | holds | — | ✓ | ✓ |
| `PayoutBatch:Create` | create batch (DRAFT) | — | ✓ | ✓ |
| `PayoutBatch:Execute` | execute a batch (send money) | — | ✓ | ✓ |
| `Payout:Review` | resolve `NEEDS_REVIEW` / retry / cancel | — | ✓ (maker-checker: see §9) | ✓ |
| `Receipt:Resend` | resend donor receipt | — | ✓ | ✓ |
| `User:Manage` | list streamers, activate/deactivate | — | — | ✓ |
| `Admin:Manage` | create/disable backoffice operators, assign roles | — | — | ✓ |
| `Audit:Read` | read audit log | — | — | ✓ |
| `Replay:Trigger` | NATS replay ops tool | — | — | ✓ |
| `Refund/Drain/RotateToken` (saruman facade) | privileged ops | — | ✓ | ✓ |

The role→permission mapping is seeded in `role_permissions` by migration; the code checks **permissions**, not role names, so future custom roles are a data change.

## 6. Legacy `admin_role` mapping (explicit)

| Legacy role | New assignment |
|---|---|
| `FINOPS` | `ADMIN` + scoped to payout/hold/withdrawal permissions only (no `Donation:Override`, no `User:Manage`) |
| `OPS` | `ADMIN` + monitoring-only (Donation:ReadAll) |
| `ADMIN` | `ADMIN` (full MVP set) |
| (no row) | deny |

Legacy mapping is **temporary**; new accounts are created only with `SUPERADMIN`/`ADMIN`/`USER`.

## 7. Endpoints added/changed

| Endpoint | Change |
|---|---|
| `POST /v1/auth/firebase/exchange` | NEW. Body `{id_token}`; verifies Firebase token; resolves `identities`; issues legacy `sk_` (STREAMER) or `ak_` (BACKOFFICE) session. Returns `{session_token, expires_at, roles, principal}`. Used by the bridge during rollout. |
| `POST /v1/auth/login` / `/v1/auth/signup` | POST-migration: REMOVED (or return 410 with instructions to use Firebase). During rollback window: kept, behind `AUTH_LEGACY_ENABLED` flag, telemetry-counted. |
| Existing `/v1/me/*` | middleware now accepts **either** a valid `sk_` session **or** a valid Firebase ID token (resolved to the same `Principal`). |
| Existing `/v1/admin/*` monitoring endpoints | `adminSession` middleware replaced with `requirePerm` middleware accepting `ak_` (bridge) or Firebase ID token. |
| Existing `/v1/admin/holds*`, `/v1/admin/payout-batches*` legacy `admin()` (internal key + `X-Actor-Id`) | **Removed** in favor of a proper Backoffice-authenticated call with real actor identity. The Saruman command path (`X-*-Id` internal) becomes service-to-service only, with the actor derived from the **verified** session principal, never from a client-supplied header. See `02-backoffice.md` §6. |
| `GET /v1/admin/users`, `POST /v1/admin/users`, `PATCH /v1/admin/users/{id}`, `POST /v1/admin/users/{id}/roles` | NEW (SUPERADMIN only) — backoffice operator management (list/create/disable/assign role). |
| `GET /v1/backoffice/sessions` (list/revoke active+historical sessions) | NEW (SUPERADMIN) — session management incl. revalidating Firebase revocation (Firebase `auth().revokeRefreshTokens` + `sessions.valid_since` check; SDK-side `CHECK_SESSION_REVOKED`/`auth_time` verification is enable-able). Do an `auth_time` check against the Firebase user record's `tokensValidAfterTime` when available. |

## 8. Break-glass access (Firebase outage)

If Firebase (or its JWKS endpoint) is unreachable, verify-token middleware fails **closed** by default. Provide:

- `FIREBASE_VERIFY_MODE=closed|degraded`. `degraded` allows `ak_` legacy sessions (bridge) to keep working when Firebase ID-token verification fails, but **never** allows issuing new sessions. Log every degraded accept at WARN to `audit_log` (`action='BREAKGLASS_DEGRADED_AUTH'`).
- At least one **break-glass backoffice account** retains a local password (bcrypt) for post-incident access; documented in ops runbook; login counts are alerting thresholds.
- The WS overlay path (`ok_`) is unaffected by Firebase outages by design.

## 9. Maker–checker (mandatory for money movement)

- Moving money (batch `execute`, payout `retry`, payout `cancel/refund-resolution`, override) requires **two distinct human actors**: maker (submits) and checker (approves). Both roles ADMIN+ (`ADMIN` or `SUPERADMIN`); **the same actor cannot approve their own submission**.
- All maker/checker rows: `payout_approvals` table or `metadata` JSONB on batch (`maker_admin_id`, `checker_admin_id`, `checker_at`), with `audit_log` rows `BATCH_SUBMITTED`/`BATCH_APPROVED`.
- SUPERADMIN may (documented, audit-logged) bypass checker in declared emergencies via `?bypass_reason=` which is **always** recorded.

## 10. Security invariants & tests

- Firebase tokens: alg RS256, `iss`/`aud` pinned, `exp` enforced, `sub` non-empty, `auth_time` optional check, failed-open impossible.
- Role/perm resolution never accepts client-supplied role data; `GET /v1/backoffice/me` returns roles for display only.
- Ownership: every `/v1/me/*` handler must derive `streamer_id` from the verified principal, not the request body/URL.
- Tests: unit (token verify table tests incl. expired, wrong-aud, wrong-iss, alg=none, RS256 garbage), integration (bridge exchange, role escalation attempts get 403, maker==checker rejection, `FIREBASE_VERIFY_MODE` semantics), and a revocation test (deactivate Firebase user → next request 401 once token expires/refresh check lands).
- Every privileged action records actor identity (firebase_uid + admin_user_id), role, reason, request id, and idempotency key — the existing `audit_log` columns plus `metadata` JSONB.

## 11. Files and symbols the implementer will touch

- Backend: `inflora-shared/auth` (new `firebase` verify helper), `inflora-tolkien/internal/middleware/firebase.go` (new), `inflora-tolkien/internal/app/app.go` (Login/Signup replaced by exchange; `Principal` gains `FirebaseUID`), `inflora-tolkien/internal/app/admin.go` (role resolution via `role_permissions`; `AdminPrincipal.Role` → `Roles []string` + `Perms set[string]`), `inflora-tolkien/internal/httpapi/server.go` (routing + middleware), `inflora-tolkien/internal/httpapi/admin.go` (replace `adminSession` with `requirePerm`), `inflora-tolkien/internal/httpapi/admin_holds.go`/`admin_batches.go` (drop `admin()` internal-key route auth — replace with Backoffice session + Saruman commands per D-004), `inflora-saruman/migrations/00009*.sql…00011*.sql`, `inflora-saruman/internal/migrate/runner_test.go` (update migration-count expectations).
- Frontend: `frontend/src/lib/firebase.ts` (new SDK init), `frontend/src/lib/api/*` (send Firebase ID token; exchange for `sk_` during bridge), `frontend/src/lib/stores/session.ts`/`adminSession.ts` (store roles; purge on 401), routes `login/+page.svelte`, `signup/+page.svelte`, `admin/login/+page.svelte` (Firebase UI flows).
- Docs to update: `frontend/docs/AUTH.md` (new token model), and a new row in `CONTRACT_DRIFT.md` (D-024, see §12).

## 12. Contract-drift rows to add (before implementation)

Propose these explicit rows in `CONTRACT_DRIFT.md` (Phase reviewers decide before coding):

- **D-024** — Human auth: legacy Argon2id/`sk_`/`ak_` → Firebase ID tokens as the primary human credential; Tolkien is the sole verifier; overlay `ok_` and internal service auth unchanged (A-4, A-5, A-9).
- **D-025** — Roles: `admin_role{ADMIN,FINOPS,OPS}` is superseded by `app_role{SUPERADMIN,ADMIN,USER}` + `role_permissions`; DB authoritative; mapping in §6; legacy enum dropped after telemetry gate.
- **D-026** — Backoffice actor identity: `X-Actor-Id` + internal key is no longer a client-facing auth method for human admin actions; actor identity comes from the verified principal; `X-Actor-Id` retained only for service-to-service call attribution (tolkien→saruman command surface).