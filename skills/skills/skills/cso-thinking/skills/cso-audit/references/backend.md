# Backend security checklist

> Server-side services in any language. APIs, business logic, datastore access are the audit target. Grounded in OWASP API Top 10, OWASP ASVS L1/L2, OWASP Top 10 (Web), language-specific cheat sheets.

Read this file when the `backend` profile is active.

## Threat outcomes we defend against

1. **Remote code execution** — deserialization, SSRF-to-RCE, command injection, vulnerable deps
2. **Auth bypass** — broken JWT, missing middleware, IDOR
3. **Data exfiltration** — SQL injection, NoSQL injection, mass assignment, over-fetching
4. **Server compromise** — SSRF, file upload to RCE, path traversal
5. **Resource exhaustion / DoS** — unbounded queries, regex DoS, no rate limit

## Checklist (B-1 to B-12)

### B-1: Injection — OWASP A03:2021
- **B-1.1** SQL: no string concatenation / template interpolation into queries. Use parameterized queries / prepared statements. Grep: `` `.*SELECT.*\$\{`, `"SELECT .* + `, `query.*\+.*req\.`, `f"SELECT.*{` ``.
  - **Tools:** semgrep `p/sql-injection`, language SAST (gosec, bandit, brakeman).
  - **Severity:** confirmed injection on user-facing path = `critical`.
- **B-1.2** NoSQL: MongoDB, DynamoDB — no raw operator passthrough. `find(req.body)` with unsanitized object is operator injection.
- **B-1.3** Command injection: no `exec(userInput)`, `system($userInput)`, `os.system(...)`, `Runtime.exec(...)` with tainted strings. Use array-form spawn and argument lists.
- **B-1.4** LDAP, XPath, template (Jinja, ERB, Twig, Razor) injection — same principle: parameterize or escape.
- **B-1.5** Header injection / log injection — CRLF in `Location:` or log lines.

### B-2: Broken authentication — OWASP A07:2021 / API2:2023
- **B-2.1** Password hashing uses **Argon2id** (preferred), **bcrypt** (cost ≥ 12), or **scrypt**. **NEVER** MD5, SHA1, SHA256-without-salt, or plain.
- **B-2.2** Auth endpoints have rate limiting + lockout (or CAPTCHA after N failures). Brute force protection.
- **B-2.3** JWT: verify signature with the **expected algorithm** (reject `alg=none`, reject algorithm confusion HS256↔RS256). Validate `iss`, `aud`, `exp`, `nbf`.
- **B-2.4** Session tokens use cryptographic randomness (≥128 bits of entropy). Not `Math.random()`, not user ID, not predictable.
- **B-2.5** Session fixation: rotate session ID on login + privilege change.
- **B-2.6** Password reset tokens single-use, short TTL (≤1h), bound to email.

### B-3: Broken access control / authorization — OWASP A01:2021 / API1+API5:2023
- **B-3.1** Every authenticated route has explicit authz check. Route allowlists > denylists.
- **B-3.2** **IDOR**: handler reads `req.params.id` and queries resource — must check `resource.owner_id == current_user.id` or membership. Grep `req\.params.*id|/:id|\{id\}` and review each.
- **B-3.3** Role checks done server-side, never trusted from JWT claims alone unless signed by us.
- **B-3.4** Admin endpoints not reachable via the same domain as user endpoints without additional gating (path prefix + middleware).
- **B-3.5** Mass assignment / over-posting: don't bind request body straight to ORM model. Use explicit allowed-fields list (DTO / Pydantic schema / ActiveModel `permit`).

### B-4: SSRF — OWASP A10:2021 / API7:2023
- **B-4.1** Any handler that fetches a URL provided by the user (webhook, image proxy, URL preview) must:
  - Validate scheme is `http|https`.
  - Block private IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, ::1, fc00::/7).
  - Block metadata endpoints (`169.254.169.254`, `metadata.google.internal`, `metadata.azure.com`).
  - Use a hardened HTTP client without redirects to blocked targets.
- **B-4.2** Server-side image processing / PDF generation that fetches assets is a classic SSRF vector.

### B-5: Cryptography — OWASP A02:2021
- **B-5.1** TLS 1.2+ required; disable older protocols at the LB / framework level.
- **B-5.2** Symmetric: AES-256-GCM or ChaCha20-Poly1305. Never ECB. CBC only with HMAC-then-Encrypt and unique random IV.
- **B-5.3** Asymmetric: RSA ≥2048 (prefer 3072+), or Ed25519 / ECDSA P-256.
- **B-5.4** Random: use language CSPRNG (`crypto.randomBytes`, `secrets`, `rand.Read` from `crypto/rand` not `math/rand`).
- **B-5.5** No hardcoded keys/IVs. Keys from env / secret manager / KMS.
- **B-5.6** No `Math.random()` for security purposes; `rand.Intn` (Go `math/rand`) for tokens; PHP `rand()`/`mt_rand()` for crypto — all `high`.

### B-6: Insecure deserialization — OWASP A08:2021
- **B-6.1** Java: no `ObjectInputStream.readObject()` on untrusted input. Use JSON.
- **B-6.2** Python: no `pickle.loads` on untrusted input. Use JSON or msgpack.
- **B-6.3** Ruby: no `Marshal.load`, no `YAML.load` (use `YAML.safe_load`).
- **B-6.4** PHP: no `unserialize()` on untrusted input.
- **B-6.5** Node: be cautious with `node-serialize`, `funcster`, etc. — avoid.

### B-7: Logging & monitoring — OWASP A09:2021
- **B-7.1** Auth events logged: success, failure, lockout, password change, MFA enroll/disable.
- **B-7.2** Sensitive values **never** in logs: passwords, tokens, full PII, full PAN. Use redaction middleware.
- **B-7.3** Logs structured (JSON) and shipped off-host.
- **B-7.4** No PII in error messages / stack traces returned to client. Generic error in prod, detail in logs only.

### B-8: Rate limiting & abuse
- **B-8.1** Global rate limit per IP / per user. Tighter for auth endpoints.
- **B-8.2** Pagination has max page-size cap. Open-ended `?limit=...` is a DoS surface.
- **B-8.3** Regex compiled at module load, not per-request. No user-controlled regex (ReDoS).
- **B-8.4** Bulk endpoints have explicit caps (`/api/users/bulk` accepting 1M items = `high`).

### B-9: File upload & storage
- **B-9.1** Server-side MIME and magic-byte validation (not just extension).
- **B-9.2** Re-encode images server-side (strip EXIF, prevent polyglot attacks).
- **B-9.3** Uploaded files served from separate origin or with `Content-Disposition: attachment` + `X-Content-Type-Options: nosniff`.
- **B-9.4** Filename sanitization: strip path traversal (`../`), normalize Unicode, randomize.
- **B-9.5** Antivirus scan if accepting docs from untrusted users (ClamAV).
- **B-9.6** Storage path not predictable; or use opaque IDs.

### B-10: CSRF — for cookie-auth APIs
- **B-10.1** State-changing requests require either `SameSite=Lax|Strict` cookies **plus** custom header check, or a synchronizer token.
- **B-10.2** GET handlers do not have side effects.

### B-11: Configuration & secrets
- **B-11.1** Secrets in env vars or secret manager, **never** in source.
- **B-11.2** Debug / dev endpoints (`/debug`, `/__inspect`, `/_status`, framework dev tools) disabled in prod.
- **B-11.3** Default credentials changed (admin/admin, root, etc.).
- **B-11.4** Verbose errors disabled in prod.
- **B-11.5** Trust proxy headers (`X-Forwarded-For`, `X-Real-IP`) only when behind known LB; otherwise spoofable.

### B-12: Dependencies & supply chain
- **B-12.1** Run the language-specific vuln scanner (see `tools.md`). Map CVSS → our severity.
- **B-12.2** Lockfile present and committed.
- **B-12.3** No floating major versions on security-critical deps.
- **B-12.4** Direct dependency count audit — flag if importing 200+ direct deps without reason (supply-chain surface).
- **B-12.5** Post-install scripts review (npm `postinstall`, Composer scripts) — flag if they fetch remote code.

## Tools mapping

| Item | Tool that catches it |
|------|---------------------|
| B-1.x | semgrep p/sql-injection, p/command-injection, language SAST |
| B-2.x, B-3.x | semgrep p/owasp-top-ten, p/jwt, manual review |
| B-4.x | semgrep p/ssrf, manual |
| B-5.x | semgrep p/insecure-transport, language SAST, manual |
| B-6.x | Language SAST (bandit picks up pickle, brakeman picks up Marshal) |
| B-7.x | grep, manual |
| B-8.x | Manual |
| B-9.x | semgrep p/path-traversal, manual |
| B-10.x | Manual |
| B-11.x | gitleaks, semgrep p/secrets, manual |
| B-12.x | npm/pnpm/yarn audit, pip-audit, govulncheck, cargo audit, composer audit, etc. |

## Severity calibration cheat sheet

- Critical: SQL/NoSQL injection on user-reachable path, RCE via deserialization, hardcoded prod DB password, JWT alg-confusion, exposed admin endpoint without auth.
- High: IDOR on sensitive resource, weak password hash (MD5/SHA1/unsalted), missing authz on internal endpoint, SSRF to localhost.
- Medium: missing rate limit on auth, weak JWT signing key, verbose error in prod, vulnerable dep without active exploit.
- Low: no audit log for auth event, missing `SameSite` on cookie, defense-in-depth gap.
- Info: opportunity for finer-grained logging, opportunity for service mesh mTLS.

## Remediation prompt template

```
Open `<file>:<line>` (function `<name>`). Currently the handler does:

    <snippet>

Risk: `<one-sentence threat>` per `<standard>`. Specifically, `<attack-scenario>`.

Change to use `<exact API or pattern>`:

    <replacement snippet>

Add a test in `<test file>` covering: `<attack input>` should return `<safe response>`.

Verify by:
1. `<test command>`
2. `<curl or e2e check>`

If the project uses `<framework>`, the idiomatic helper is `<helper>`.
```

## References

- OWASP Top 10 2021 — https://owasp.org/Top10/
- OWASP API Security Top 10 2023 — https://owasp.org/API-Security/editions/2023/en/0x11-t10/
- OWASP ASVS — https://owasp.org/www-project-application-security-verification-standard/
- OWASP Cheat Sheets — https://cheatsheetseries.owasp.org/
- OWASP Proactive Controls — https://owasp.org/www-project-proactive-controls/
