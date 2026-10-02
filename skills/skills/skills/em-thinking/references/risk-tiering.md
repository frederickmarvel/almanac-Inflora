# Risk Tiering — T0 / T1 / T2 / T3

Risk tier determines **the discipline that applies** to plan, code review, and deploy. T0 has strict gates, T3 has fast lane.

Generic taxonomy — not tied to a specific domain. For regulated finance / MMF / healthcare flavor, see optional flavor extension (TBD, future).

---

## Where to Use

- `/em-plan` Phase 1 Step 2 — initial classification for the plan
- `/em-works` Phase 4 — gate for deploy strategy choice (T0/T1 must be feature flag/canary)
- `/em-review` Mode A — gate for LGTM threshold (T0/T1 strict, T2/T3 loose)
- `/em-review` Mode B — debug severity matching tier

Shared with `pm-thinking` (will be cross-referenced from pm-thinking PRD risk section later — currently standalone in em-thinking).

---

## T0 — Critical

### Definition
Surface that **cannot be undone easily if wrong** or **can cause significant harm to user / business / reputation**.

### Surfaces (generic categories)
- **Irreversible operations** — writes that can't be rolled back without data loss (delete, payment send, irrevocable state transition)
- **Security boundaries** — auth, authz, secret management, session handling, encryption boundaries
- **State machines with concurrency** — distributed lock, saga, transaction coordinator, exactly-once processing
- **External system contracts** — webhook receiver, idempotency key handling, retries, contracts with third-party API that have financial/legal consequence
- **Sensitive data** — PII, regulated data (HIPAA / GDPR / PCI), financial records, health records

### Examples (generic)
- Critical write path (e.g. order placement, payment send, irreversible content delete)
- Login / session / authentication flow
- Distributed lock, saga, transaction coordinator
- Webhook receiver from payment provider
- Data export endpoint with sensitive fields
- Migration that touches sensitive columns

### Required discipline
- **Test-first** — required. Core invariant 100% covered.
- **Security review** — `security-reviewer` role parallel to em-works.
- **Postmortem-grade documentation** — invariants explicit, failure modes complete, rollback procedure tested in staging.
- **Deploy strategy** — feature flag or canary, never big bang.
- **On-call window** — extended (>24h) post-deploy attention.

---

## T1 — High

### Definition
Surface that **causes serious user-visible problems if wrong but is recoverable** with reasonable effort.

### Surfaces (generic categories)
- **Schema migrations** — DDL changes, column adds that touch nullable→NOT NULL, type widening/narrowing
- **Breaking API changes** — request/response shape changes, contract changes that force client update
- **Multi-service coordination** — fanout, cross-service transaction (not T0-grade but still tricky)
- **Observability gap on sensitive surface** — cases where T0-adjacent code lacks sufficient tracing/logging

### Examples (generic)
- Add NOT NULL column to existing large table
- Change response field from string to typed enum
- Cross-service transaction (payment + ledger + notification)
- Refactor logging library used by sensitive endpoint

### Required discipline
- **Test strategy explicit** — failure modes documented, edge cases enumerated.
- **Migration plan reviewed** — backwards-compat plan written, rollback procedure for data too.
- **Backward compat** — addressed if breaking. Deprecation path documented.
- **Deploy strategy** — feature flag or canary preferred. Big bang acceptable if low-volume + reversible.
- **On-call window** — standard (24h) post-deploy.

---

## T2 — Standard

### Definition
Surface that's **isolated, additive, reversible, and low blast radius**. Most feature work lives here.

### Surfaces (generic categories)
- Single-module feature (new endpoint, new helper, new internal tool)
- Additive backward-compat changes (new optional field, new feature flag, new metric emission)
- UI changes that don't affect data flow
- Performance optimization that doesn't change semantics

### Examples (generic)
- New endpoint with feature flag default off
- Internal helper module
- New dashboard widget
- Caching layer for read-heavy endpoint

### Required discipline
- **Standard test coverage** — unit + integration per team convention.
- **Invariants stated** — minimum 1 per ticket.
- **Deploy strategy** — flag/canary recommended, big bang acceptable if truly isolated.
- **On-call** — normal rotation.

---

## T3 — Trivial

### Definition
Surface that **doesn't touch product behavior**. Pure config, docs, dev tooling, style.

### Surfaces (generic categories)
- Documentation update
- CI/CD config (that doesn't touch deployment safety)
- Lint rule, formatter config
- Dev script, README, ADR
- Comment-only code change

### Examples (generic)
- README typo fix
- Add new lint rule that doesn't break existing code
- Update CI runner version
- Add inline code comment

### Required discipline
- **Sanity check only** — sufficient.
- **Skip heavy review** — single reviewer, focus on intent clarity.
- **Deploy** — auto-deploy via CI typical.

---

## Tier Boundary Forcing Questions

Ambiguous between T0 vs T1, or T1 vs T2? Ask:

1. **"If this bug ships to prod, and is only caught after 1 hour — recoverable?"**
   - Yes, no data harm → T1 or lower
   - No, data harm or financial / reputational → T0

2. **"Does sensitive data touch this path?"**
   - Yes (PII, regulated, financial) → minimum T1, possibly T0
   - No → T1 maximum

3. **"Cross-service coordination?"**
   - Yes, with financial implication → T0
   - Yes, low-stake → T1
   - No → T2 or lower

4. **"Reversibility — can a feature flag toggle it off?"**
   - Yes, instant → T1 or T2 (despite blast radius, mitigation cheap)
   - No, must hot-fix → T0 or T1

5. **"Compliance/regulatory implication?"**
   - Yes → minimum T1, possibly T0
   - No → ignore in calculation

Default to a higher tier if ambiguous. Promoting down is cheaper than upgrading up after an incident.

---

## Escalation Triggers

T2 plan that must be promoted to T1 or T0 if:
- Discovery reveals path touches sensitive data not detected initially
- Post-implementation, cross-service coordination emerges
- Volume / scale assumption wrong, blast radius bigger than initial
- Compliance team flags late-stage

T1 that must be promoted to T0:
- Security review finds an attack surface
- Migration finds a data anomaly that requires manual remediation

---

## Integration with pm-thinking

`pm-thinking`'s PRD section `## Tech Implications (For Eng Kickoff)` already has **Section 4: Compliance / Privacy / Security**. This section feeds naturally into risk tier classification at em-plan.

Future cross-reference: pm-thinking can explicitly suggest tier in PRD ("PM hypothesis: T1, requires em-plan validation"), em-plan validates or adjusts.
