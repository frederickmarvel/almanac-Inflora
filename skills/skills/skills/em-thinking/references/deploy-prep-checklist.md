# Deploy Prep Checklist (Artifact-Only)

Detail for `/em-works` Phase 3 + Phase 4. **em-works produces a deploy artifact, doesn't execute deployment.** Execution = `release-engineer` / `devops` role (skill matched per env).

---

## Scope Boundary

| em-works owns | em-works does NOT do |
|----------------|------------------------|
| Spec what env vars are needed + storage location | Provisioning secrets in Secrets Manager |
| Spec feature flag definition (name, default, owner) | Creating actual flag on flag platform |
| Spec migration ID + rollback plan | Running migration in staging/prod |
| Spec deploy strategy (canary 5%/25%/100%) | Triggering canary rollout |
| Spec rollback procedure step-by-step | Executing rollback |
| Spec monitoring dashboard plan | Creating actual dashboard |
| Spec alert rules + thresholds | Setting up PagerDuty rules |

em-works = **handoff package** ready for devops to use. Engineer starts coding, devops triggers deploy. Both consume eng-works.md.

---

## 1. Environment Variables Spec

### Format

| Var | Local | Staging | Prod | Sensitive? | Owner |
|-----|-------|---------|------|------------|-------|
| `DB_URL` | `.env.local` | `secrets/staging/db-url` | `secrets/prod/db-url` | Yes | infra-team |
| `EXTERNAL_API_KEY` | `.env.local` | `secrets/staging/api-key` | `secrets/prod/api-key` | Yes | api-team |
| `FEATURE_FLAG_X_DEFAULT` | `false` | `false` | `false` | No | feature-owner |
| `LOG_LEVEL` | `debug` | `info` | `warn` | No | sre-team |

### Convention

- **Local** — file path or literal value (e.g. `.env.local`, `false`)
- **Staging/Prod** — secret manager reference path (e.g. `secrets/staging/db-url`) or "literal" value for non-sensitive
- **Sensitive?** — Yes/No. Yes triggers rotation policy + access list spec.
- **Owner** — team/role accountable for provisioning and rotation.

### Forcing questions

1. "Var X — sensitive or not? a) Yes (PII / credentials / token) b) No (config / level / flag)"
2. "Storage location for prod — Secrets Manager / SSM / KMS / config-server / vault — env-team convention?"

---

## 2. Secrets Spec

### Format

| Secret | Storage location | Rotation policy | Access list | Pre-handoff status |
|--------|------------------|-----------------|-------------|---------------------|
| `db-url-prod` | AWS Secrets Manager | 90 days | infra-team, app-pods | TODO: provision |
| `api-key-payments` | HashiCorp Vault | 30 days | payments-team, app-pods | READY |

### Status keywords

- **`TODO: provision`** — devops needs to create. Engineer cannot start tickets that depend on this.
- **`TODO: rotate`** — exists but needs rotation. Schedule before deploy.
- **`READY`** — confirmed exists & accessible. Engineer free to use.
- **`DEPRECATED`** — old secret to be removed post-deploy. Cleanup ticket.

### Forcing questions

1. "Secret X — pre-handoff status: a) READY b) TODO provision c) TODO rotate d) DEPRECATED"
2. "Rotation policy — frequency: a) 30 days b) 90 days c) 1 year d) Per-incident only"
3. "Access list — who needs access? Pods/services + human emergency access"

---

## 3. Infra Prereqs Checklist

### Common items

- [ ] **Database schema migration** — file path: `migrations/202X-XX-XX-name.sql`. Reviewed: yes/no. Rollback SQL: yes/no.
- [ ] **Queue / topic creation** — broker URL placeholder, topic name, dead-letter topic name, retention policy.
- [ ] **Feature flag definition** — name (`payment.provider_x.enabled`), default (`false`), owner team.
- [ ] **Monitoring dashboard plan** — metrics list (latency P50/P99, error rate, throughput, business metric), grouping, time range default.
- [ ] **Alert rule plan** — threshold (`error rate > 1% / 5min`), escalation (PagerDuty schedule), severity (P1/P2/P3).
- [ ] **Runbook draft** — link or path. Cover: detect, diagnose, mitigate, escalate.
- [ ] **CDN / cache invalidation** — if the application has a CDN layer.
- [ ] **Backup verification** — if new data store, backup tested?

### Status per item

`READY` / `TODO (owner)` / `BLOCKED (waiting on X)`.

### Forcing questions

1. "Infra prereq item [X] — status?"
2. "If TODO — owner + ETA?"
3. "If BLOCKED — what's the blocker, who unblocks?"

---

## 4. Deploy Strategy Selection

Pick one + justify rationale.

### Options

| Strategy | When to pick | Rollback ease | Risk |
|----------|--------------|---------------|------|
| **Feature flag toggle** | Code deploys disabled, flag flips per cohort. Default for T0/T1 with user-facing behavior change. | Instant (toggle off) | Lowest |
| **Canary rollout** | Deploy to small % of traffic, observe, expand (5% → 25% → 100%). Use when no flag-friendly UX boundary. | Fast (rollback canary instance) | Low |
| **Blue-green** | Full new env, switchover. Use when DB schema change or breaking API. | Fast (switch back to blue) | Medium |
| **Big bang** | Deploy + activate immediately. Acceptable for T2/T3 only with low blast radius. | Slow (re-deploy previous) | High |

### Rule of thumb

- **T0 / T1** → feature flag or canary, **never big bang**
- **T2** → flag/canary preferred, big bang acceptable if truly isolated
- **T3** → big bang typical (low risk, low value to gate)

### Forcing questions

1. "Pick deploy strategy: a) Feature flag b) Canary c) Blue-green d) Big bang. Rationale?"
2. "Risk tier inherited from plan: T0/T1/T2/T3. Strategy match? (T0 + big bang = anti-pattern)"

---

## 5. Rollback Procedure Template

Required: written in artifact, tested in staging first if T0/T1.

### Required sections

#### Trigger conditions
Explicit threshold that triggers the rollback decision. Examples:
- Error rate > 5% sustained 5 minutes
- Latency P99 > 500ms sustained 10 minutes  
- Manual decision by on-call engineer (justification logged)

#### Procedure (step-by-step)
Target: < 5 minute execution. Numbered steps.

```
1. Toggle feature flag `payment.provider_x.enabled` to `false`
2. Verify error rate dropping (Datadog dashboard X, link)
3. Drain in-flight requests (sleep 30s)
4. (If schema migration involved) Run rollback migration: `migrations/202X-XX-XX-rollback.sql`
5. Notify #payments-engineering: "Rolled back, investigating"
6. Capture artifact: log + metrics snapshot pre/post rollback
```

#### Data implications
If migration involved:
- Forward-compatible schema? (new code reads old data)
- Backfill plan? (if a new data field needs to be populated for old records)
- Data corruption risk? (will rollback corrupt new data?)

#### Communication plan
- Pre-rollback: notify channel
- Post-rollback: status update, postmortem trigger

### Forcing questions

1. "Rollback target time: a) < 1 min b) < 5 min c) < 15 min d) > 15 min — if (d), reconsider strategy"
2. "Trigger condition — automated alert, manual decision, or hybrid?"
3. "Data rollback — needed? a) No (forward compat) b) Yes (rollback migration tested) c) Partial (some manual)"
4. "Comms channel + audience — defined?"

---

## 6. Monitoring Window

### First 24 hours
- **On-call window-1 owner** — name + link to runbook
- **Watch metrics** — error rate, latency P99, throughput, business KPI
- **Threshold to escalate** — explicit number

### First 7 days
- **Review cadence** — daily 1-pager? End-of-day Slack message?
- **Sign-off criteria** — if metric is stable + no incident, safe to proceed (full ramp / remove canary / fully roll out flag)

### First 30 days
- **Drift watch** — if there's metric drift, root cause investigation
- **Cleanup** — deprecate the flag (if intent is stable behavior), remove canary tooling, archive runbook

### Forcing questions

1. "On-call window-1 owner: name + escalation chain"
2. "Sign-off criteria — explicit number per metric"
3. "Cleanup ticket — created for flag deprecation post-stable?"

---

## 7. Comms Plan

### Pre-deploy
- **Channels** — Slack channel, email list, status page
- **Scope statement** — what will deploy, target window, expected user impact
- **Rollback awareness** — stakeholders aware that rollback is possible

### During deploy
- **Live status update** — per phase (start, 25% canary, 50% canary, 100%)
- **Channel** — usually #deploys or feature-specific channel

### Post-deploy
- **Retrospective trigger** — if there's an incident, postmortem within 48h
- **Metric snapshot** — baseline vs post-deploy, share with stakeholder

### Forcing questions

1. "Stakeholder list — who must be notified pre-deploy?"
2. "Channel update cadence — phase-based or time-based?"

---

## Anti-pattern (don't do this)

- ❌ **Skip env/secrets spec.** Engineer will get stuck in local setup.
- ❌ **Big bang deploy for T0/T1.** Always feature flag or canary.
- ❌ **Rollback procedure = "git revert"** without data plan. Migrations need a forward compat strategy.
- ❌ **No on-call window-1 owner.** "Owner: TBD" = future incident with no responder.
- ❌ **No sign-off criteria.** The team never knows when deploy is "done", canary stuck forever.
- ❌ **Test rollback only in prod.** For T0/T1, rollback tested in staging first.
- ❌ **em-works execute deployment.** Out of scope. Hand off to devops/release role.
