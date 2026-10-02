# Runbook Template — Inflora

> **Purpose.** When something breaks at 3am, this is the only document the on-call should need.
> One runbook per binary service (palantir-gateway, saruman, ithildin, tolkien in the archive; future services get their own).
> **Filled examples** at the bottom show how to populate this for a real service.

---

## 0. TL;DR

| Field | Value |
|---|---|
| **Service name** | `[service-name]` |
| **What it does (1 line)** | `[one sentence — no jargon]` |
| **Owner** | `[team or person, e.g. founder@inflora.app]` |
| **Escalation (primary)** | `[name + contact]` |
| **Escalation (backstop)** | `[name + contact]` |
| **Grafana dashboard** | `[URL]` |
| **Logs (Loki query)** | `[{service="<name>"}]` |
| **Health check** | `curl -fsS http://<host>:<port>/healthz` |
| **Restart command** | `[make restart / kubectl rollout restart ...]` |

---

## 1. Service overview

- **Language / framework:** `[Go 1.24 + chi]` (or Node, Rust)
- **Binary path:** `[/usr/local/bin/<name>]` (or container image)
- **Process manager:** `[systemd / k8s deployment / bare process]`
- **Listen addresses:**
  - HTTP: `[host:port]`
  - gRPC: `[host:port]` (if any)
  - WebSocket: `[host:port/path]` (if any)
- **Dependencies (upstream):**
  - MySQL `inflora` schema → `[tables this service reads/writes]`
  - NATS :4222 → `[topics this service produces/consumes]`
  - `[other internal services by name + endpoint]`
- **External dependencies:**
  - `[Midtrans / Xendit / Pivot webhook URLs]`
  - `[anything outside our control]`

---

## 2. Key URLs

| What | URL | Auth |
|---|---|---|
| Health | `GET /healthz` | none |
| Readiness | `GET /readyz` | none |
| Metrics (Prometheus) | `GET /metrics` | internal only |
| Admin endpoints | `[list — e.g. POST /v1/admin/streamers/:id/drain]` | admin token |
| Public | `[list — only the public ones]` | per-API |

**Loki log search shortcut:**

```
{service="<name>"} |= "<error substring>" | json | line_format "{{.msg}}"
```

---

## 3. Common alerts

For each alert: meaning, what to check, what to do, when to escalate.

### Alert: `HighErrorRate`

- **Trigger:** > 5% of requests returning 5xx for 5 min
- **Meaning:** something is failing upstream, downstream, or in code

**Check:**
1. Grafana → identify the affected endpoint
2. Logs → filter by status code and endpoint
3. Recent deploys → `kubectl rollout history` / git log

**Do:**
1. If clearly caused by a recent deploy → roll back: `kubectl rollout undo deployment/<name>`
2. If downstream dependency is failing → open the dependency's runbook
3. If no clear cause in 15 min → escalate to backstop

---

### Alert: `HighLatencyP99`

- **Trigger:** p99 latency > 2s for 5 min
- **Meaning:** something is slow — usually DB pool, GC pause, or external API

**Check:**
1. Grafana → DB connection pool saturation
2. Grafana → NATS consumer lag
3. Grafana → goroutine count (for Go services)
4. Logs → any single slow endpoint dominating?

**Do:**
1. If DB pool full → `SHOW PROCESSLIST` (MySQL) / `pg_stat_activity` (Postgres). Kill long txns.
2. If NATS lag → check consumer alive: `nats consumer info <stream> <consumer>`
3. If GC pause → check heap allocation rate
4. If external API slow → check provider status page, throttle if possible

---

### Alert: `WebSocketConnectionsDrop`

- **Trigger:** OBS / dashboard WS count drops > 20% in 1 min
- **Meaning:** clients are disconnecting — usually network, broker, or service restart

**Check:**
1. Provider network status page
2. NATS broker health: `nats server check connection`
3. Service alive: `curl /healthz`
4. Recent deploys on this service

**Do:**
1. If NATS down → restart broker first; clients auto-reconnect
2. If service OOM/restart loop → check logs, scale or fix leak
3. If just network → wait, monitor; clients auto-reconnect with backoff

---

### Alert: `LedgerImbalance`

- **Trigger:** daily reconciliation drift > Rp 1.000
- **Meaning:** sum of debits != sum of credits, OR ledger vs provider != channel
- **THIS IS SEV-1. Money math is wrong.**

**Check:**
1. Open the reconciliation dashboard
2. Identify which entry type + which streamer
4. Look at recent webhook deliveries

**Do:**
1. **Stop publishing new events for the affected streamer.**
2. Open incident bridge.
3. Pull manual reconciliation report.
4. Fix root cause before re-enabling.
5. SEV-1 → notify founder immediately.

---

## 4. Common operations

### Restart the service

```bash
# If managed by k8s:
kubectl rollout restart deployment/<service-name>

# If bare process:
make restart

# If systemd:
sudo systemctl restart <service-name>
```

Wait 30s. Check `/healthz`. Check `/readyz`. Check Grafana for recovery.

---

### Drain a streamer (force-disconnect their OBS clients)

```bash
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  $HOST/v1/admin/streamers/$STREAMER_ID/drain
# reason: "investigating alert spam"
```

Use only when a streamer's client is misbehaving. Logs to `audit_log` with operator_id.

---

### Replay events from a timestamp

```bash
# NATS JetStream: seek a consumer to a timestamp
nats consumer seek <stream> <consumer> --since=2026-09-23T13:00:00Z
```

Use after a bug fix — replay events that were dropped or mishandled.

---

### Rotate overlay token for a streamer

```bash
# Normally done by the streamer themselves via dashboard.
# Admin rotation only when token is exposed:
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  $HOST/v1/admin/streamers/$STREAMER_ID/rotate-token
```

Logs to `audit_log`. Notify the streamer immediately.

---

### Scale (only if not auto-scaling)

```yaml
kubectl scale deployment/<service-name> --replicas=N
```

Watch HPA / cluster capacity. Don't scale beyond 2x without checking the dependency (DB, NATS, downstream service).

---

## 5. Escalation paths

| Severity | Trigger | First contact | Backstop |
|---|---|---|---|
| **SEV-1** | Money lost or wrong; full outage > 15 min | Tech lead + founder (both) | All-hands |
| **SEV-2** | Service degraded for > 15 min; significant user impact | Tech lead | Founder |
| **SEV-3** | Minor bug, no user impact | Next-day backlog | — |

**Always escalate SEV-1 within 5 minutes.** Don't try to fix it alone — open the bridge and pull the team.

---

## 6. After any incident

1. Write a postmortem (template: `POSTMORTEM_TEMPLATE.md` if present, else this PR description format)
2. Add follow-up tickets to the backlog with labels: `incident`, `YYYY-MM-DD`
3. Update **this runbook** with anything you learned that would have helped
5. Review the postmortem in the next team sync

---

## Appendix A — Filled example: `saruman`

```yaml
service: saruman
what_it_does: "Processes donations; double-entry ledger; publishes sm.overlay.alert"
owner: founder@inflora.app
escalation:
  primary: tech-lead
  backstop: founder
dashboard: https://grafana.inflora.app/d/saruman
logs: '{service="saruman"}'
health: curl http://<host>:8082/healthz
restart: kubectl rollout restart deployment/saruman

listen:
  http: ":8082"
  grpc: ":7002"
  ws:   ":7003/ws"

dependencies:
  mysql: [donations, ledger_entries, ledger_accounts, idempotency]
  nats:
    consumes: [pg.gateway.topup.completed, pg.gateway.refund.completed]
    produces: [sm.overlay.alert]
  palantir: ":7001 (gRPC)"
  ithildin: ":7003 (ws inbound)"
```

(Trim/extend per service. Real runbook for production is typically 4-8 pages.)

---

*End of template. Each service has its own file: `RUNBOOK.saruman.md`, `RUNBOOK.palantir-gateway.md`, etc.*