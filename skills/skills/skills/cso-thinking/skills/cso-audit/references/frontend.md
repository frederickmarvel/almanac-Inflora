# Frontend security checklist

> Web / SPA / static-site frontends. Browser-executed code is the audit target. Grounded in OWASP Top 10 (Web), OWASP Cheat Sheets, MDN web security, CSP Level 3.

Read this file when the `frontend` profile is active.

## Threat outcomes we defend against

1. **Account takeover** — XSS, CSRF, session theft, OAuth misconfiguration
2. **Sensitive data exposure** — secrets in bundle, PII in localStorage, unencrypted fetch
3. **Supply-chain compromise** — vulnerable npm dep, postinstall scripts, unpinned versions
4. **Phishing-style abuse** — open redirect, clickjacking, missing CSP

## Checklist (F-1 to F-9)

### F-1: Cross-site scripting (XSS) — OWASP A03:2021
- **F-1.1** No `dangerouslySetInnerHTML`, `v-html`, `[innerHTML]=`, `innerHTML =`, or template literal interpolation of unsanitized user input.
  - **Grep:** `dangerouslySetInnerHTML|v-html|innerHTML\s*=|\.html\(`
  - **Tool:** semgrep `p/xss`, eslint-plugin-security `detect-non-literal-fs-filename`, react-specific rules.
  - **Severity:** sink + tainted source = `high` to `critical`; sink + constant = `info`.
- **F-1.2** Output encoding done by the framework — confirm no custom string-template HTML rendering.
- **F-1.3** Markdown rendering uses a sanitizer (`DOMPurify`, `sanitize-html`, `rehype-sanitize`); `marked`/`markdown-it` raw without sanitizer = `high`.

### F-2: Content Security Policy — OWASP Cheat Sheet
- **F-2.1** CSP header present (response header OR `<meta http-equiv="Content-Security-Policy">`).
- **F-2.2** No `unsafe-inline` in `script-src` (use nonces / hashes for required inline scripts). `unsafe-inline` = `medium`; on a high-value app = `high`.
- **F-2.3** No `unsafe-eval`. If framework requires it (some dev builds), document and ensure prod build doesn't ship it.
- **F-2.4** `default-src 'self'`, `object-src 'none'`, `base-uri 'self'`, `frame-ancestors` set (anti-clickjacking).
- **F-2.5** `Trusted-Types` directive set for modern apps (defense-in-depth against DOM XSS).

### F-3: Security headers — OWASP Secure Headers Project
- **F-3.1** `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload` on production HTTPS.
- **F-3.2** `X-Content-Type-Options: nosniff`.
- **F-3.3** `Referrer-Policy: strict-origin-when-cross-origin` or stricter.
- **F-3.4** `Permissions-Policy` denying camera/microphone/geolocation unless used.
- **F-3.5** `X-Frame-Options: DENY` (or CSP `frame-ancestors 'none'`).

### F-4: Authentication & session
- **F-4.1** Tokens stored in **HttpOnly Secure SameSite=Lax|Strict** cookies, **not** `localStorage` / `sessionStorage`. Storing JWT in localStorage = `high`.
- **F-4.2** Logout invalidates the session server-side (not just clears the client).
- **F-4.3** OAuth flows use PKCE; redirect URIs are exact-match allowlist (no wildcards); `state` parameter validated.
- **F-4.4** No password handling client-side beyond passing to server over HTTPS — never hash on the client and "save the round-trip."
- **F-4.5** Multi-factor: if app handles auth, MFA option exists for sensitive accounts.

### F-5: Secrets in bundle — high false-negative rate from tools, grep aggressively
- **F-5.1** Search the production bundle (built output) for: `sk_live`, `AKIA`, `xoxb-`, `xoxp-`, `BEGIN PRIVATE KEY`, `bearer `, `Authorization:`. Any hit on a server-side secret = `critical`.
- **F-5.2** Public anon keys (Supabase anon, Firebase, Stripe `pk_live_`) are fine in the bundle by design — confirm RLS / rules limit damage.
- **F-5.3** `.env.local` not in `.gitignore` and committed = `high`.

### F-6: Dependency vulnerabilities
- **F-6.1** Run `npm audit` / `pnpm audit` / `yarn audit`. Map output severities to our scale.
- **F-6.2** Run `osv-scanner` or `retire.js`. Cross-reference.
- **F-6.3** Lockfile present and pinned (`package-lock.json` / `pnpm-lock.yaml` / `yarn.lock`).
- **F-6.4** No floating `^` / `~` for security-critical libs (auth libs, crypto libs).

### F-7: CORS & cross-origin
- **F-7.1** No `Access-Control-Allow-Origin: *` with `Access-Control-Allow-Credentials: true` — that combination is a hard `critical`.
- **F-7.2** Origin allowlist explicit, not regex-derived from request.
- **F-7.3** Preflight (`OPTIONS`) handled, not just primary verbs.

### F-8: Open redirect & URL handling
- **F-8.1** Redirect targets validated against an allowlist; never `window.location = req.query.next` without validation.
- **F-8.2** No raw `target="_blank"` without `rel="noopener noreferrer"`.
- **F-8.3** Deep-link / postMessage handlers validate `event.origin`.

### F-9: Subresource Integrity & third-party loading
- **F-9.1** External `<script src>` and `<link rel="stylesheet">` use `integrity="sha384-..."` + `crossorigin="anonymous"`.
- **F-9.2** Avoid loading scripts from CDNs at runtime — bundle dependencies. Tag managers (GTM), analytics, etc. accepted but documented.
- **F-9.3** Iframe embeds use `sandbox` attribute.

## Tools mapping

| Item | Tool that catches it |
|------|---------------------|
| F-1.x | semgrep p/xss, eslint-plugin-security |
| F-2.x, F-3.x | Manual (read framework config / response headers) |
| F-4.x | Manual + semgrep p/jwt |
| F-5.x | gitleaks/trufflehog on built bundle, grep |
| F-6.x | npm/pnpm/yarn audit, osv-scanner, retire.js |
| F-7.x | grep CORS config, manual |
| F-8.x | semgrep p/open-redirect, manual |
| F-9.x | Manual (parse HTML / framework config) |

## Severity calibration cheat sheet

- Critical: secret leaked in bundle, CORS wildcard + credentials, XSS sink with user-tainted input on auth flow, dependency CVE with active exploit in core dep.
- High: JWT in localStorage, missing CSP on production, OAuth state not validated, dependency CVE high severity.
- Medium: missing security header, CSP with `unsafe-inline`, vulnerable dev dependency.
- Low: missing `rel="noopener"`, defense-in-depth gap, deprecated browser API.
- Info: opportunity to adopt SRI, opportunity to adopt Trusted-Types.

## Remediation prompt template

```
Open `<file>:<line>`. Currently: `<snippet>`. The risk is `<one sentence>` per `<standard>`.

Change to: `<exact replacement code>`.

Verify by:
1. `<command or manual step>`
2. `<second check>`

If using framework `<X>`, prefer the built-in helper `<helper name>` over manual sanitization.
```

## References

- OWASP Top 10 2021 — https://owasp.org/Top10/
- OWASP Cheat Sheets — https://cheatsheetseries.owasp.org/
- MDN Web Security — https://developer.mozilla.org/en-US/docs/Web/Security
- CSP Level 3 — https://www.w3.org/TR/CSP3/
- OWASP Secure Headers — https://owasp.org/www-project-secure-headers/
