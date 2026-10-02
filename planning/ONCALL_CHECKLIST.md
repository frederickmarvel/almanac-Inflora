# On-Call Checklist — Inflora

> **Audience.** Whoever is on-call this week. Keep it on your desk / pinned in your chat.
> **Cadence.** Rotate weekly. Hand off cleanly at the end of the shift.

---

## Pre-shift (start of rotation — 30 min)

- [ ] Read recent incident postmortems (last 7 days)
- [ ] Review open alerts in PagerDuty / Opsgenie — close any stale ones
- [ ] Verify your on-call phone/pager works (trigger a test alert)
- [ ] Verify VPN access to production dashboards
- [ ] Verify SSH access to the production bastion
- [ ] Review deploys in the last 24h (`kubectl get pods -l deploy` / git log)
- [ ] Verify each service's `RUNBOOK.md` is up to date (PR if not)
- [ ] Check the on-call handoff doc from the previous shift — anything open?
- [ ] Confirm you have the runbook URLs bookmarked (per service)

---

## During an incident

### 1. Detect (alert fires)

- [ ] **Acknowledge** the alert in PagerDuty — note the time (used for MTTR — Mean Time To Resolve)
- [ ] Open the **Grafana dashboard** for the affected service
- [ ] Open the **runbook** for that service (`RUNBOOK.<service>.md`)
- [ ] If outside business hours and you need backup: page the backstop now

### 2. Assess (within 5 min)

- [ ] **Real or false positive?** Look at metrics + recent logs.
- [ ] **Scope:** how many users / streamers affected?
- [ ] **Severity:**

  | Level | Meaning |
  |---|---|
  | **SEV-1** | Money lost or wrong, full outage, security incident |
  | **SEV-2** | Service degraded > 15 min, significant user impact |
  | **SEV-3** | Minor bug, no user impact |

- [ ] **Post status** in `#incidents` channel:

  ```
  [SEV-X] [<service>] — <one-line description> — investigating — <your name>
  ```

### 3. Mitigate (within 15 min)

- [ ] Apply the runbook fix if the runbook covers it
- [ ] If unclear → **roll back the most recent change**
  ```bash
  kubectl rollout undo deployment/<service>
  ```
- [ ] Update `#incidents`:

  ```
  [SEV-X] [<service>] — mitigation in progress — <what you tried>
  ```

- [ ] If user-visible (SEV-1 or SEV-2):
  - Update status page (`status.inflora.app`)
  - Post in `#status` for the team
  - Notify affected streamers (in-app banner + Discord)

### 4. Communicate (every 30 min minimum)

- [ ] Update `#incidents` with progress
- [ ] Update status page if user-visible
- [ ] Notify founder if SEV-1 has been open > 30 min

### 5. Resolve

- [ ] Confirm metrics back to normal (Grafana green, no error spike)
- [ ] Confirm logs are clean (no new errors in last 5 min)
- [ ] Update `#incidents`:

  ```
  [SEV-X] [<service>] — resolved at <HH:MM> — root cause: <one sentence>
  ```

- [ ] Mark alert **resolved** in PagerDuty
- [ ] Schedule postmortem within 48h (calendar invite + ticket)

### 6. Document (within 48h)

- [ ] Write postmortem (use `POSTMORTEM_TEMPLATE.md` if present, or PR description format)
- [ ] Identify follow-up tickets — add to backlog with labels: `incident`, `YYYY-MM-DD`
- [ ] **Update the runbook** for the affected service — anything new
- [ ] Review postmortem in the next team sync (first 5 min of the meeting)

---

## Post-shift (end of rotation — 15 min)

- [ ] Hand off open incidents to the next on-call (write in `#incidents` channel)
- [ ] Update the on-call handoff doc with anything they should know
- [ ] Confirm no alerts are still firing that you own
- [ ] Submit shift feedback — what slowed you down? What was missing?
- [ ] Update the on-call rotation if anyone is swapping this week

---

## Communication templates

### Initial incident post

```
[SEV-2] [saruman] — donations failing to settle — investigating — <name>
Started: <HH:MM>
Affected: ~<X>% of donations in last <Y> min
Mitigation: <tried X, Y; rolling back deploy z>
Next update: <HH:MM>
```

### Mitigation update

```
[SEV-2] [saruman] — mitigation in progress
Rolled back to <commit>. Error rate falling. Watching for 5 min before resolving.
```

### Resolution

```
[SEV-2] [saruman] — RESOLVED at <HH:MM>
Root cause: <one sentence>
Duration: <X> min total
Follow-ups: <ticket links>
Postmortem: scheduled <date>, <time>
```

### Escalation

```
[SEV-1] [saruman] — escalating to <person>
Need: <what you need — DBA? another engineer?>
Time-sensitive: <yes / no>
Bridge: <meet link if open>
```

---

## What NOT to do during an incident

- ❌ Don't fix bugs while the fire is burning. **Mitigate first, fix later.**
- ❌ Don't debug silently for hours. **Communicate every 30 min.**
- ❌ Don't roll forward to "fix the bug while you're at it." **Roll back, ship the fix later.**
- ❌ Don't skip the postmortem. **Always write one. SEV-1 and SEV-2 always get a written PM.**
- ❌ Don't blame people in the postmortem. **Blameless. Fix the system, not the human.**
- ❌ Don't skip the runbook update. **If you learned something, write it down. Future-you will thank present-you.**

---

## Postmortem template (one-page)

```markdown
# Postmortem — <incident title>

**Date:** YYYY-MM-DD
**Severity:** SEV-X
**Duration:** X min
**Author:** <your name>

## What happened
<2-3 sentences — what broke, who was affected>

## Root cause
<1-2 sentences — why it broke>

## Timeline (HH:MM)
- HH:MM — alert fired
- HH:MM — acknowledged
- HH:MM — mitigation applied
- HH:MM — resolved

## What went well
- <bullet>

## What went poorly
- <bullet>

## Action items
- [ ] <ticket> — <fix> — owner: <name> — priority: <high/med/low>
```

Keep postmortems to one page. Long ones don't get read.

---

*End of checklist. Print this if it helps — paper is fine at 3am.*