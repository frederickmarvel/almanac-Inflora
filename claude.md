# AI Repository Guide: Inflora Almanac

## Purpose

This repository is the canonical architecture, contract, planning, and operations reference for the active Inflora platform. Inflora is an Indonesian streamer-donation system that accepts IDR payments, maintains financial state, and delivers paid alerts to OBS overlays.

This repository is documentation-first. It is not a deployable service.

## Sources of truth

- `planning/README.md`: planning index, authority, precedence, and archive policy.
- `planning/WIRE_GUIDE.md`: service boundaries, connections, ports, and ownership.
- `planning/AI_BACKEND_COMPLETION_PLAN.md`: broad phased implementation plan.
- `planning/MANUAL_SETTLEMENT_WITHDRAWALS_PLAN.md`: focused manual settlement
  tracking and creator-withdrawal execution plan.
- `planning/schemas/`: frozen HTTP, event, database, provider, and operational contracts.
- `planning/schemas/INDEX.md`: schema-document index.
- `ops/`: production runbooks and on-call guidance.
- `docs/Pivot_techdocs.md`: payment-provider reference material.

The active implementation is split across six sibling Git repositories under `/Users/frederickmarvel/Inflora/backend/`: `inflora-shared`, `inflora-tolkien`, `inflora-ingest`, `inflora-palantir`, `inflora-saruman`, and `inflora-ws-gateway`.

## Guidance for AI agents

1. Read the relevant frozen contracts before proposing or changing service behavior.
2. Treat money values as integer IDR and preserve financial idempotency, auditability, and transaction boundaries.
3. Keep service ownership explicit. Do not move migrations, ledger writes, provider calls, or public endpoints across boundaries without updating the architecture contracts.
4. When implementation and documentation disagree, identify the drift rather than silently rewriting a contract.
5. Update all affected contract views together: database schema, HTTP API, event
   catalog, flow diagrams, wire guide, and the applicable execution plan.
6. Do not edit repositories under `/Users/frederickmarvel/Inflora/archive/` as though they are part of the active architecture.
7. Treat documents under this repository's `archive/` directory as historical
   context only; never use them to select current implementation work.

## Validation

Documentation changes should be checked for consistent names, ports, event versions, ownership, and links. The optional skills package under `skills/skills/` can be validated with:

```sh
cd skills/skills
npm run check:publication
```
