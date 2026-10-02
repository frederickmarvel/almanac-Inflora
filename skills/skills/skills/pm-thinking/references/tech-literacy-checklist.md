# Tech Literacy Checklist (for Product PM)

This checklist is used by `/pm-works` when filling in the **Technical Implications** section in a PRD, and by `/pm-decide --review` when auditing a PRD.

**Purpose:** PM is **aware** of the technical impact of their spec — so the engineer isn't surprised at kickoff. PM **doesn't make** engineering decisions — that's the `engineer-manager` domain.

---

## 1. Data layer

| Question | Why it matters | Decision domain |
|----------|-------------|-----------------|
| New schema? | Eng needs to allocate DB work + migration plan | Eng |
| Migration on an existing table? | Risk of downtime, rollback complexity | Eng |
| New data volume — small (<1GB) / medium / large? | Storage cost, query performance | Eng |
| Sensitive data? PII, payment, health, biometric? | Compliance review timeline | PM flag, Legal/Sec decide |
| Retention rule? How long is it kept? | GDPR / regulatory | PM flag, Legal decide |

**PM output:** observation. e.g., "Add column `sso_enabled` to `organizations` table. ~5K rows. No PII change."

**PM should not output:** "Use Postgres / use DynamoDB" — that's an eng decision.

---

## 2. API / Integration

| Question | Why it matters | Decision domain |
|----------|-------------|-----------------|
| New endpoint? | API surface area expansion | Eng |
| Existing endpoint changed? | Backward compat strategy | Eng |
| Breaking change? | Deprecation path, client comms | PM flag + Eng strategy |
| External dependency? Vendor / SaaS / 3rd-party API? | Cost, SLA, lock-in | PM evaluate, Eng implement |
| Auth model change? | Security implication | PM flag, Sec decide |

**PM output:** "New endpoint `POST /api/sso/configure`. No breaking change. Auth: existing org-admin scope."

**PM should not output:** "REST or gRPC, what's the request body schema."

---

## 3. Existing components affected

| Question | Why it matters | Decision domain |
|----------|-------------|-----------------|
| Will Component A be affected? | Regression risk | PM flag, Eng test |
| Reusable component to leverage? | Speed up build, consistency | Eng decides reuse |
| Owned by another team? | Cross-team coordination needed | PM coordinate |

**PM output:** "Login flow component will be modified — currently owned by the Auth team."

---

## 4. Compliance / Privacy / Security

| Question | Why it matters | Decision domain |
|----------|-------------|-----------------|
| Touches PII? | GDPR / CCPA review | Legal / Privacy |
| Touches payment / financial? | PCI-DSS scope | Sec / Legal |
| Touches health / biometric? | HIPAA / regional regulation | Legal |
| Region-specific? Data residency? | Architecture impact | PM flag, Eng decide |
| Audit log requirement? | SOX / SOC2 | Compliance |

**PM output:** "Stores OAuth tokens. Data residency: US-only for v1. Required review: Security team."

---

## 5. Performance / Scale awareness

| Question | Why it matters | Decision domain |
|----------|-------------|-----------------|
| Realistic concurrent user? | Capacity planning | Eng |
| Latency-sensitive? (sub-second UX) | Architecture choice | Eng |
| Heavy compute? (ML, video, large query) | Infrastructure cost | Eng |
| Cache-friendly? | Performance / cost optimization | Eng |

**PM output:** "Expected ~500 concurrent SSO logins at peak. Acceptable login latency: <2s."

**PM should not output:** "Use Redis or Memcached for session storage."

---

## 6. Effort ballpark

| Range | What it means |
|-------|---------------|
| **Days** | Small change — copy edit, bug fix, minor UI tweak |
| **1-2 weeks** | Single-engineer feature — well-scoped, no major dep |
| **1 month** | Multi-engineer feature — touches 2-3 components |
| **1 quarter** | Cross-team initiative — coordination heavy |
| **>1 quarter** | Strategic bet — needs phased approach |

**PM rule:** Always confirmed-by-eng before locking the deadline. Ballpark from PM = guess; ballpark from the engineer-manager skill = commitment-able.

---

## 7. Open technical questions for eng

This section in the PRD = a list of questions that **the PM can't answer** and needs eng input on. Examples:

- "Login session — share with the existing session store or separate?"
- "SAML 2.0 vs OIDC — which do you recommend for v1?"
- "Backward compat for legacy login — what's the strategy?"

The engineer-manager skill will pick up this section at handoff.

---

## Anti-pattern PM tech-literacy

❌ **Decide engineering:** "Use Postgres, schema X, index on column Y."
❌ **Vague:** "Might affect database. Eng figure out."
❌ **Commitment as PM:** "Eng confirmed it's 2 weeks."
❌ **Skip section:** Tech Implications empty / "TBD" everywhere.

✅ **Aware + observe:** "Schema impact: new table. Existing components: Login API. Compliance: PII via OAuth token storage. Effort ballpark: 2-3 weeks (PM guess, pending eng confirm)."
