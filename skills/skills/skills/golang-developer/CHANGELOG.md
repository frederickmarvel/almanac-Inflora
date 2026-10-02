# Changelog

All notable changes to the `golang-developer` skill are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [1.5.0] — 2026-08-03

### Added

- **`### File Placement Rules (non-negotiable)` table in `SKILL.md`** — always-in-context rules for where files go: tests only under `test/{layer}/` (never adjacent to source), service = 3 files (`x_service.go` / `x_service_impl.go` / `x_service_params.go`), repository = 2 files, transformer = 2 files, controller single-file exception. Includes the "adding a method touches interface + impl (+ params)" rule.
- **"Tests ride along" router note in `SKILL.md`** — any scaffold task that also produces tests must additionally load `testing.md`, because test placement in this stack is not the Go default and the scaffold references don't cover it.
- **`repository-patterns.md §3` File Structure section** — the two-file layout (`x_repository.go` interface + `x_repository_impl.go` impl) was previously documented **nowhere** in the reference; added with the "update both files" rule and a matching anti-pattern entry.
- **`testing.md §1` placement callout** — explicit "this overrides the Go idiom" block with the three reasons for the centralized `test/` layout (black-box surface, shared fixtures, clean `src/`) and the `-coverpkg=./src/...` coverage consequence; §11 coverage command corrected; §12 gains a "test file adjacent to source" anti-pattern (first row).
- **Two new "Important" review checklist items in `SKILL.md`** — test file adjacent to source, and interface/impl/Params combined in one file — so violations get caught at review even when they slip through generation.

### Changed

- `SKILL.md` scaffold checklists for Service and Repository now open with the file-split rule (previously the split was only mentioned in the low-priority Idiomatic review tier).
- `SKILL.md` Idiomatic review item "Interface in consumer file, implementation separate" reworded — the old phrasing read like the generic Go "define interfaces where consumed" idiom, which contradicts the team's actual `x_service.go` / `x_service_impl.go` layout.
- `service-patterns.md §3` File Structure strengthened: "never combined, even for a one-method service" + explicit adding-a-method file checklist; §8 gains a combined-file anti-pattern (first row).
- `SKILL.md §4 Testing` now states the `test/{layer}/` placement rule inline instead of only deferring to `testing.md`.

### Fixed

- **Adjacent-test-file root cause**: the `test/`-only rule lived exclusively in lazy-loaded `testing.md §1`, which the Task Router only loads for test-centric prompts — so "scaffold X + tests" flows never saw it and the model regressed to the idiomatic-Go adjacent `_test.go` convention. The rule is now in always-loaded `SKILL.md` (layout table + §4 + review checklist) and the router loads `testing.md` whenever tests are a side deliverable.
- **Combined-file root cause**: the service 3-file split was buried mid-file in `service-patterns.md §3`, the repository split was undocumented, and `SKILL.md` only referenced file naming in the lowest-priority review tier with ambiguous phrasing. The split is now stated at generation time (scaffold checklists + File Placement Rules) and at review time (Important tier).

## [1.4.2] — 2026-06-09

### Added

- **`## Anti-Patterns` sections** — added to all 8 references that were missing them: `entity-patterns.md`, `repository-patterns.md`, `service-patterns.md`, `grpc-patterns.md`, `rest-gateway.md`, `infrastructure.md`, `scheduler-patterns.md`, `provider-integration-patterns.md`. All 17 reference files now have a consistent dedicated Anti-Patterns section.
- **`## Related References` footers** — added to `entity-patterns.md`, `repository-patterns.md`, `provider-integration-patterns.md`. All non-leaf references now cross-link adjacent layers.
- **`testing.md` expansion** (200 → 592 lines) — added: controller layer tests, service layer tests with mock pattern, repository integration tests (testcontainers-go + shared test DB options), integration tests, performance benchmarks (`testing.B` + `benchstat`), test fixture factory pattern, 10-entry Anti-Patterns section, Related References footer.
- **`helpers.WithTenantID` canonicalization** in `context-patterns.md §8` — explicit note that `app.WithTenantID` and other non-`helpers` setters are legacy shims, not substitutes. Added corresponding anti-pattern entry in §9 table.
- **Scheduler trait-usage anti-patterns** in `scheduler-patterns.md` — explicit rules: never bypass `ForStatus()` with raw `db.Where(...)`, always call trait methods (`SyncFailedDate()`, `SyncProcessedDate()`) rather than direct field assignment.

### Changed

- `repository-patterns.md §7` renamed from "Common Pitfalls to Avoid" → `## Anti-Patterns`; two additional anti-pattern entries added (raw `db.Where` bypass, nil return handling).
- `service-patterns.md` Related References expanded to include `error-handling.md`.
- `grpc-patterns.md` Related References expanded to include `proto-workflow.md` and `error-handling.md`.
- `rest-gateway.md` Related References updated to include `proto-workflow.md` and `context-patterns.md §7`.
- `infrastructure.md` Related References expanded to include `security.md` and `context-patterns.md`.
- `scheduler-patterns.md` Related References updated to add `entity-patterns.md` trait methods callout and `context-patterns.md §4`.

### Fixed

- **E3 root cause**: `scheduler-patterns.md` now explicitly prohibits raw `db.Where` in job handlers and mandates trait methods for state transition — the exact gap that caused the model to bypass `ForStatus()` and `SyncFailedDate()`.
- **E5 root cause**: `context-patterns.md §8` now names `helpers.WithTenantID` as the only canonical setter and explicitly warns against `app.WithTenantID` — the exact confusion that caused the wrong helper to be used.

## [1.4.1] — 2026-06-08

### Added

- **`references/concurrency-patterns.md`** — stack-specific concurrency patterns: goroutine inventory across the engine (gRPC/REST/NATS/scheduler/worker pools), primitive decision matrix (Mutex/RWMutex/Once/Pool/atomic), `errgroup` vs `WaitGroup`, channel fan-out/fan-in/pipeline, `singleflight` for cache stampede, NATS consumer ordering strategies, GORM `*gorm.DB` thread-safety reality vs the repository fluent builder race risk, provider connection reuse, goroutine leak detection (pprof + `go.uber.org/goleak`), `go test -race` CI gate policy, and 15 anti-patterns.
- **Task Router entry** for concurrency tasks (goroutine/mutex/sync.Once/atomic/errgroup/channel/race/singleflight/leak signals).
- **Debugging table rows** for: `go test -race` flagging repo whereQuery races, climbing goroutine counts, and cache stampedes on hot keys.
- **Eval #8** — `concurrency-bulk-fanout`: tests whether the model uses `errgroup.WithContext + SetLimit(8)`, respects gctx, writes results by index, returns `g.Wait()` error, and notes the repo whereQuery race or `-race` CI gate.

### Changed

- `SKILL.md` description expanded to mention concurrency coverage.
- `.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json`, `gemini-extension.json` — version bumped to 1.4.1; descriptions updated to mention concurrency.
- `MANIFEST` — adds `references/concurrency-patterns.md`.

## [1.4.0] — 2026-06-08

### Added

- **`references/context-patterns.md`** — stack-specific `context.Context` patterns: unexported tenant/partner key, NATS consumer scoping, gocron job ctx, `context.WithoutCancel` for fire-and-forget to pools, repository fluent builder ctx, outbound provider ctx, REST → gRPC gateway forwarding, anti-patterns.
- **`references/observability.md`** — Zap structured logging with mandatory fields (`trace_id`, `span_id`, `request_id`, `tenant_id`), OpenTelemetry trace propagation across gRPC/NATS/HTTP, Prometheus metrics matrix, log-level policy, log correlation across services, health-check endpoints.
- **`references/security.md`** — auth per tier (admin JWT, insider TOTP, public OAuth), HMAC signing of financial entities with `StringFixed(4)` + `Unix()` rules, validator tag policy, Vault + Viper cascade for secrets, AES/RSA PII fields, `govulncheck` policy, rate limiting, SQL injection surface.
- **`references/performance.md`** — pprof endpoints wired in, profile-before-optimize workflow with benchstat, allocation hotspots in this stack, decimal performance, GORM hot-path optimizations, NATS consumer throughput, scheduler job performance, bounded worker patterns, caching.
- **`references/proto-workflow.md`** — authoritative `make protogen` flow, `buf.yaml`/`buf.gen.yaml`, `@gotags` magic comment syntax, field type mapping, naming conventions, `buf breaking` policy per tier, REST gateway annotations, versioning.
- **`references/error-handling.md`** — the three channels (`error` / `[]ParamError` / `panic`), `samber/oops` wrapping convention, panic recovery layering, response code matrix `{TIER}-{DOMAIN}-{SEVERITY}-{ACTION}-{SEQ}`, sentinel vs wrapped vs typed errors, error logging policy.
- **Project Bootstrap Flow** in `SKILL.md` — confirms stack choice via `AskUserQuestion` when scaffolding a new service; remembers decisions per session.
- **Task Router matrix** in `SKILL.md` — explicit "task class → load these references" mapping, prevents pre-loading all ~9k lines of references on every invocation.
- **Persona + thinking mode** declared in `SKILL.md` — `think` for review, `ultrathink` for restructuring / scaffolding / proto / financial correctness.
- **`allowed-tools`** front-matter — scoped to `Bash(go:*)`, `Bash(buf:*)`, `Bash(make:*)`, `Bash(git:*)`, `Bash(goose:*)`, `Bash(supervisorctl:*)`, `Bash(protoc:*)`, `Bash(protoc-go-inject-tag:*)`, `Bash(golangci-lint:*)`, `Bash(staticcheck:*)`, `Bash(govulncheck:*)`, `Bash(pprof:*)`, `Bash(go tool:*)`, plus `Agent`, `AskUserQuestion`, `WebFetch` — reduces permission prompts.
- **`metadata.openclaw`** block — emoji, homepage, required binaries, install commands for `buf` / `protoc-go-inject-tag` / `goose`.
- **`.cursor-plugin/plugin.json`** — multi-platform distribution to Cursor.
- **`gemini-extension.json`** — multi-platform distribution to Gemini CLI.
- **Evals** — 4 new cases: stack confirmation flow on bootstrap, NATS consumer using `context.Background()` (ctx misuse), missing observability fields on log lines, proto-workflow violation (`buf generate` standalone).

### Changed

- **`SKILL.md` description** — rewritten in the `Use when X / Not for Y / → See` pattern for accurate auto-triggering. Adds cross-links to relevant `samber/cc-skills-golang@*` skills.
- **`SKILL.md` Core Capabilities** — trimmed to per-layer checklists with pointers to the matched reference. Deep detail (entity trait composition, controller 7-step flow, proto validation rules) lives in references; `SKILL.md` is now a router, ~150 lines smaller in content payload.
- **Debugging table** — added context-related symptoms (NATS handler ctx canceled mid-handler, missing log trace fields, alloc growth on hot endpoint, intermittent auth failures) with pointers to new references.
- **Cross-link policy** documented — references load in order proto → grpc → service → repository → entity when a task spans layers.

### Fixed

- Reference to `references/core/testing.md` corrected to `references/testing.md` in the §4 Testing section.

## [1.3.0] — 2026-05-22

- Restructured `SKILL.md` and references.
- Introduced strict proto workflow: `buf lint` pre-commit mandatory; `protoc-go-inject-tag` for `validate`/`json` struct tags; never edit `*.pb.go` by hand.

## [1.2.0] — Earlier

- Initial public-facing release with scaffolding, code review, debugging, and architecture guidance.
