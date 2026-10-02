# Database security checklist

> Schema, migrations, ORM configuration, access patterns. Data-layer concerns specifically (handler-level SQL injection lives in `backend.md`). Grounded in OWASP Database Security Cheat Sheet, CIS DB benchmarks (Postgres, MySQL, MongoDB, Redis).

Read this file when the `databases` profile is active.

## Threat outcomes we defend against

1. **Mass data exfiltration** — over-permissive DB user, no encryption-at-rest for PII, backups public
2. **Tenancy escape** — missing row-level security, scoping bugs in queries
3. **Loss of integrity** — destructive migrations without backup, no audit trail
4. **DoS** — missing indexes, unbounded queries, no connection pooling limits

## Checklist (D-1 to D-9)

### D-1: Connection security
- **D-1.1** Connection strings not hardcoded in source. From env / secret manager.
- **D-1.2** TLS enforced for connections (`sslmode=verify-full` for Postgres, `requireSSL=true` for MySQL).
- **D-1.3** Database not directly reachable from the public internet (private subnet / VPC peering / Cloud SQL Auth Proxy).
- **D-1.4** Connection pool has max-connection cap (prevents accidental DoS and signals leaks).

### D-2: Authentication & user model
- **D-2.1** App connects as a **least-privileged role**, not superuser / root / `postgres` / `sa`.
  - App role can typically do `SELECT, INSERT, UPDATE, DELETE` on its own schema, nothing else.
  - DDL (migrations) runs as a separate, narrower role.
- **D-2.2** No `GRANT ALL` to app role. No `PUBLIC` schema write access.
- **D-2.3** Default passwords rotated (Postgres `postgres`, MySQL `root`, MongoDB / Redis default no-auth).
- **D-2.4** Redis: `requirepass` set, or running behind ACL with per-app users. Bind to localhost only if not behind VPC.
- **D-2.5** MongoDB: authentication enabled (`security.authorization: enabled`).

### D-3: Schema & PII handling
- **D-3.1** PII columns (email, phone, full name, address, government ID, payment data) identified and either:
  - encrypted-at-rest at the column level (pgcrypto, app-level AES-GCM with KMS-managed key), OR
  - confirmed protected by DB-level encryption-at-rest (storage encryption) appropriate to threat model.
- **D-3.2** Payment card data: PCI scope minimized — preferably tokenized via a vault (Stripe, Adyen, etc.); never store PAN/CVV.
- **D-3.3** Passwords stored hashed (Argon2id / bcrypt) — surface this even though it's a backend concern, since the schema reveals it.
- **D-3.4** Soft-delete pattern not used for legally-deletable data without a hard-delete path (GDPR right-to-erasure compliance).
- **D-3.5** Audit columns (`created_at`, `updated_at`, `created_by`) present on tables that track sensitive operations.

### D-4: Multi-tenancy
- **D-4.1** If multi-tenant, every tenant-owned table has a `tenant_id` (or equivalent) column.
- **D-4.2** **Row-level security** enforced at the DB layer (Postgres `RLS`) OR scoping middleware verified in every query. Trusting the app to always-filter is fragile — RLS is the defense-in-depth.
- **D-4.3** Cross-tenant queries (admin tooling, analytics) gated behind a separate role.
- **D-4.4** Test exists: tenant A's session cannot read tenant B's row.

### D-5: Migration safety
- **D-5.1** Migrations versioned and committed (no manual `psql` to prod).
- **D-5.2** Destructive operations (`DROP COLUMN`, `DROP TABLE`, `TRUNCATE`) reviewed for:
  - Backup taken before
  - Down migration that can restore data
  - Application code already not reading the column for at least one deploy
- **D-5.3** Long-running migrations on hot tables (`ALTER TABLE ADD COLUMN NOT NULL` without default) require online-migration tooling (pt-online-schema-change, gh-ost, lock-free strategies).
- **D-5.4** No migration runs raw user-tainted SQL.
- **D-5.5** Migration runner has retry / idempotency.

### D-6: Query patterns (data-layer; injection lives in backend.md)
- **D-6.1** ORM usage doesn't bypass parameterization with `.raw()` / `.query()` + string concat — grep for those and flag any user-tainted call.
- **D-6.2** No `SELECT *` from sensitive tables exposed to API serialization — list columns explicitly to avoid leaking new sensitive columns when they're added later.
- **D-6.3** Mass operations (`UPDATE without WHERE`, `DELETE without WHERE`) guarded — most ORMs have a safeguard (`Model.update_all` warns, `dangerouslyAcceptAll`).
- **D-6.4** N+1 patterns documented & batched (`includes` / `JOIN`) — DoS surface even with no malicious actor.

### D-7: Indexes & performance as security
- **D-7.1** Auth / session lookup columns (`sessions.token`, `users.email_lower`, `api_keys.key_hash`) indexed — prevents timing attacks and DoS.
- **D-7.2** Foreign keys backed by indexes.
- **D-7.3** Large tables not scanned per request (`EXPLAIN` for hot paths reviewed).

### D-8: Backups & recovery
- **D-8.1** Automated backup configured at provider level (PITR / daily snapshot).
- **D-8.2** Backups stored in a separate account / region / bucket with stricter access controls than the running DB.
- **D-8.3** Backups encrypted at rest with KMS-managed key.
- **D-8.4** Restore tested in the last 90 days (cite test).
- **D-8.5** Backup retention matches RPO + compliance.

### D-9: Logging & monitoring
- **D-9.1** DB audit log enabled for: privilege changes, schema changes, failed logins, super-user activity.
- **D-9.2** Slow query log on — enables DoS detection and performance regression catch.
- **D-9.3** Connection spike alerting.
- **D-9.4** Query results not logged at app layer (PII leak risk).

## Tools mapping

| Item | Tool that catches it |
|------|---------------------|
| D-1.x | gitleaks, grep, manual |
| D-2.x | Manual review of GRANT statements / `pg_roles` / `mysql.user` |
| D-3.x | Manual review of schema; column-name heuristics (`email`, `phone`, `ssn`, `password_hash` etc.) |
| D-4.x | Manual + test review |
| D-5.x | Manual review of migration history |
| D-6.x | semgrep p/sql-injection, ORM-specific rules, manual |
| D-7.x | `EXPLAIN` review, manual |
| D-8.x | Manual / cloud config review |
| D-9.x | Manual / cloud config review |

## Severity calibration cheat sheet

- Critical: production DB credentials in source, app role is superuser, public-facing unauthenticated DB, missing RLS in multi-tenant production system.
- High: missing column-level encryption for PII, no automated backup, destructive migration without backup, default passwords in prod.
- Medium: missing TLS to DB, slow query log off, `SELECT *` exposed via API, missing index on auth column.
- Low: soft-delete without hard-delete path (GDPR concern), missing audit columns, no connection pool cap.
- Info: opportunity to adopt pg_audit, opportunity to test restore quarterly.

## Remediation prompt template

```
Open `<file or schema path>:<line>`. Currently:

    <SQL / migration snippet>

Risk: `<one-sentence threat>` per `<standard>`.

Change to:

    <replacement snippet>

If the change is a schema modification, write a forward migration in `<migrations path>/<timestamp>_<name>.sql` plus a down migration. Run on a staging DB first.

Verify by:
1. `<verification query>` — should return `<expected>`.
2. `<application test>` exercising the affected query path.
3. For PII: confirm the column is no longer readable in plaintext by querying as the app role.
```

## References

- OWASP Database Security Cheat Sheet — https://cheatsheetseries.owasp.org/cheatsheets/Database_Security_Cheat_Sheet.html
- CIS Postgres / MySQL / MongoDB Benchmarks — https://www.cisecurity.org/cis-benchmarks
- PostgreSQL RLS — https://www.postgresql.org/docs/current/ddl-rowsecurity.html
- OWASP Cryptographic Storage Cheat Sheet — https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html
- GDPR / regional privacy requirements — consult local counsel for retention & erasure rules.
