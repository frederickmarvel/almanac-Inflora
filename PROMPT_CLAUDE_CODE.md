# Claude Code Query — Build Inflora Backend Polyrepo

> **Guidance**
> - **Use this when:** starting Phase 0 of the Inflora backend build (create 6 GitHub repos with skeletons), or any subsequent phase.
> - **Audience:** Marvel (the user) gives this to Claude Code (CLI agent).
> -**Related:** almanac docs at https://github.com/frederickmarvel/almanac-Inflora
> - **One prompt per phase.** Don't dump all phases on Claude Code at once. Use the**Phase Prompt Template** at the bottom for Phases 1+.

---

## How to use this doc

1. Copy the **Master Query** below into Claude Code.
2. Claude Code reads the almanac docs at the GitHub URLs in the query.
3. Claude Code outputs a **plan** first (no code yet).
4. Review the plan. Approve or iterate.
5. Claude Code executes Phase 0 (create workspace + 6 repos + push to GitHub).
6. Move to Phase 1 using the **Phase Prompt Template** at the bottom.

---

## Master Query (for Phase 0: Bootstrap)

Copy this entire block into Claude Code:

````markdown
# Task: Build Inflora Backend Polyrepo — Phase 0 (Bootstrap)

## Context

You are bootstrapping the backend for **Inflora**, a streamer-donation platform for Indonesian Indonesian Rupiah (IDR). The founder ( Marvel) has spent 4 days preparing comprehensive planning docs in the **almanac** repository at https://github.com/frederickmarvel/almanac-Inflora.

This is a **fresh build from scratch**. No existing code in `backend/`. (`archive/` contains old frozen repos — reference only, do not touch.)

## Source of truth — READ FIRST, NO EXCEPTIONS

Before doing ANY work, read all of these in order:

1. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/README.md
2. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/WIRE_GUIDE.md
3. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/BACKEND_BUILD_PLAN.md
4. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/schemas/INDEX.md
5. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/schemas/00-frozen-contracts.md
6. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/schemas/02-database-schema.sql
7. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/schemas/03-http-api.md
8. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/schemas/04-grpc-proto.md

**Anti-hallucination rule:** if a name (service, event, table, column, endpoint, port, RPC) is not in these docs, **it doesn't exist**. Do not invent. If you think something is missing, **edit the almanac docs first, then write code**.

## What to build in THIS task

Execute **Phase 0** of BACKEND_BUILD_PLAN.md: **Bootstrap polyrepo**. Deliverable: 6 GitHub repos at `github.com/frederickmarvel/`, each with a skeleton, plus workspace-level files.

The 6 repos (per WIRE_GUIDE.md §1):

| Repo | Role | Port |
|---|---|---|
| `inflora-shared` | Go library: proto + event types + auth + observability + db + ledger + provider + config | — |
| `inflora-tolkien` | HTTP API: streamer auth, /v1/me/*, /v1/admin/* | HTTP 8080 |
| `inflora-ingest` | HTTP API: donor page, donations intent, webhook edge | HTTP 8081 |
| `inflora-palantir` | gRPC API: payment provider broker | gRPC 7001 |
| `inflora-saruman` | gRPC + NATS + cron + migration runner | gRPC 7002, HTTP 8082 |
| `inflora-ws-gateway` | HTTP + WebSocket: OBS overlay gateway (friend's work) | HTTP+WS 8083 |

Workspace path: `/Users/frederickmarvel/Inflora/backend/`

Each repo directory must contain (per WIRE_GUIDE.md §7):

```
inflora-<name>/
├── README.md                       # service overview, run instructions
├── ARCHITECTURE.md                 # service-internal design
├── CHANGELOG.md                    # version history
├── Makefile                        # make build, make test, make run, make lint
├── Dockerfile                      # service repos only: Go builder + distroless runtime
├── go.mod                          # module github.com/frederickmarvel/inflora-<name>
├── go.sum
├── .golangci.yml                   # linter config (revive, govet, errcheck, staticcheck)
├── .gitignore
├── .dockerignore
├── .github/
│   └── workflows/
│       └── ci.yml                  # lint + test + build on PR
├── cmd/
│   └── server/main.go              # HTTP/gRPC server boot
└── internal/                       # empty dirs for now (Phase 1+)
```

For `inflora-saruman`, also include `cmd/migrate/main.go` (migration runner, see BACKEND_BUILD_PLAN.md Phase 2).

For `inflora-shared`, NO cmd/server/main.go (it's a library). Layout:
```
inflora-shared/
├── README.md
├── go.mod                          # module github.com/frederickmarvel/inflora-shared
├── proto/
│   └── palantir/v1/
│       ├── topup.proto
│       ├── withdrawal.proto
│       ├── refund.proto
│       └── health.proto            # generated Go code checked in OR generated in CI
├── events/                         # Go structs matching almanac 01-event-catalog
│   ├── doc.go
│   ├── envelope.go
│   ├── donation_charged.go
│   ├── donation_settled.go
│   ├── (one file per event)
├── auth/                           # token gen/validate, password hash
├── observability/                  # logger, tracer, metrics
├── db/                             # Postgres pool, transaction helper
├── ledger/                         # double-entry helpers
├── provider/                       # payment provider interface (no impls)
├── config/                         # env var loader
└── middleware/                     # request_id, logging, recovery, cors, ratelimit
```

Workspace-level files at `/Users/frederickmarvel/Inflora/backend/`:

```
backend/
├── README.md                       # workspace overview
├── REPO-STRUCTURE.md                # decision doc: why polyrepo (link to WIRE_GUIDE.md §1)
├── docker-compose.dev.yml           # PostgreSQL 15+, NATS 2.10 JetStream, Redis 7
├── Makefile                        # workspace-level: make dev, make test-all, make build-all
├── .gitignore                       # workspace-level
└── README-how-to-clone.md          # tells devs to clone each repo separately
```

## Required tool versions

- Go 1.24+
- Docker 24+ (for local dev services)
- Node 22+ (for `web/` folders later, not Phase 0)
- buf CLI for proto generation (only `inflora-shared`Phase 1)

Check tools with `go version`, `docker --version`, etc. Report any missing.

## Workflow (MANDATORY)

### Step 1: READ ALL DOCS

Before writing anything, fetch and read each URL listed under "Source of truth". Print a 1-line summary of what each doc contributes:

- README.md: workspace overview, reading order
- WIRE_GUIDE.md: service registry, ports, connections
- BACKEND_BUILD_PLAN.md: phase-by-phase build instructions
- ...

**Stop.** Don't proceed to Step 2 until all docs are read.

### Step 2: PLAN (no code yet)

Output a plan covering:

1. **Workspace tree** — show the full tree you'll create at `/Users/frederickmarvel/Inflora/backend/`
2. **Each repo skeleton** — list files per repo (just file names, not contents yet)
3. **Makefile targets per repo** — make build, test, run, lint, migrate (saruman only)
4. **Dockerfile strategy** — multi-stage gorilla+builder → distroless runtime; non-root user
5. **CI strategy** — one workflow per repo, matrix on Go version, runs lint + test + build
6. **GitHub repo creation strategy** — how will you create 6 repos on GitHub? Options:
   - Option A: `gh repo create frederickmarvel/inflora-<name> --public --source=. --remote=origin --push` (requires `gh` CLI installed + authenticated)
   - Option B: curl + API token + git push
   - Option C: tell Marvel to create empty repos manually at github.com/new, then you git push
   - **Choose one and explain why.**
7. **Expected output** — what files you'll create, total line count, expected final commit hashes (just estimate)

**Stop. Wait for Marvel's approval** before proceeding to Step 3.

### Step 3: CREATE WORKSPACE

Create the workspace tree at `/Users/frederickmarvel/Inflora/backend/`:

```
mkdir -p /Users/frederickmarvel/Inflora/backend/{inflora-shared/{proto/palantir/v1,events,auth,observability,db,ledger,provider,config,middleware},inflora-tolkien/{cmd/server,internal/{config,handler,middleware,repo,service,events,cache,audit,testutil},.github/workflows},inflora-ingest/{cmd/server,internal/{config,handler,middleware,repo,saruman,palantir,idempotency,signature,events,testutil},.github/workflows},inflora-palantir/{cmd/server,internal/{config,grpc,provider/{midtrans,pivot,xendit},repo,events},.github/workflows},inflora-saruman/{cmd/{server,migrate},internal/{config,handler,grpc,service,subscriber,events,ledger,repo,cron,email,testutil},migrations,.github/workflows},inflora-ws-gateway/{cmd/gateway,internal/{config,ws,auth,subscriber,seq,handler,testutil},.github/workflows}}
```

Report what was created.

### Step 4: CREATE EACH REPO

For each of 6 repos, in order:

1. `cd <repo-dir>`
2. Write all skeleton files (Makefile, Dockerfile, .gitignore, .golangci.yml, README.md, ARCHITECTURE.md, CHANGELOG.md, go.mod, cmd/server/main.go or cmd/gateway/main.go, .github/workflows/ci.yml)
3. `git init && git add . && git commit -m "Initial scaffold: <name>"`
4. **Stop.** Push after all 6 repos are initialized locally.

**Each `cmd/server/main.go` should just print a TODO message and exit 0.****No business logic in Phase 0.**

Example `cmd/server/main.go` for inflora-tolkien:

```go
package main

import "fmt"

func main() {
    fmt.Println("inflora-tolkien: TODO (Phase 3 per BACKEND_BUILD_PLAN.md)")
}
```

**Each Makefile must have these targets:**
- `make build` — compile binary to `./bin/<name>`
- `make test` — `go test -race ./...`
- `make run` — run locally with env from `.env.example`
- `make lint` — `golangci-lint run`
- `make tidy` — `go mod tidy`
- For saruman: `make migrate-up`, `make migrate-down`

**Each Dockerfile is multi-stage:**

```dockerfile
# syntax=docker/dockerfile:1.6
FROM golang:1.24-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -o /out/<name> ./cmd/server

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /out/<name> /usr/local/bin/<name>
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/<name>"]
EXPOSE 8080
```

(Adjust port per service.)

**Each .github/workflows/ci.yml:**

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.24' }
      - run: go mod download
      - run: go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
      - run: make lint
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.24' }
      - run: go mod download
      - run: make test
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.24' }
      - run: go mod download
      - run: make build
```

**Each go.mod:**
```
module github.com/frederickmarvel/inflora-<name>

go 1.24
```

No dependencies yet (Phase 0 skeleton only). Phase 1 will add `github.com/frederickmarvel/inflora-shared v0.1.0`.

### Step 5: CREATE GITHUB REPOS + PUSH

You choose one of these strategies in Step 2 plan:

**Strategy A (gh CLI):**
```bash
gh repo create frederickmarvel/inflora-shared --public --description "Inflora backend shared library" --source=./inflora-shared --remote=origin --push
# repeat for each of 6 repos
```

If `gh` not installed or not authenticated, fall back to Strategy B or C.

**Strategy B (curl + PAT):**
Ask Marvel for a Personal Access Token. Then:
```bash
curl -H "Authorization: token $PAT" https://api.github.com/user/repos -d '{"name":"inflora-shared","private":false}'
git -C inflora-shared remote add origin git@github.com:frederickmarvel/inflora-shared.git
git -C inflora-shared push -u origin main
# repeat for each of 6 repos
```

**Strategy C (manual):**
Tell Marvel: "Please create 6 empty repos at github://github.com/new with these names and no README: `inflora-shared`, `inflora-tolkien`, `inflora-ingest`, `inflora-palantir`, `inflora-saruman`, `inflora-ws-gateway`. Reply when done, I'll then `git remote add origin` + push."

After push, verify each repo exists at https://github.com/frederickmarvel/inflora-<name>.

### Step 6: WORKSPACE FILES

Create at `/Users/frederickmarvel/Inflora/backend/`:

1. **README.md** — explain the polyrepo, link to WIRE_GUIDE.md and BACKEND_BUILD_PLAN.md, list the 6 repos with one-line descriptions, instructions for new devs.

2. **REPO-STRUCTURE.md** — 1-page decision doc: why polyrepo (not monorepo), per-repo ownership matrix, when to split (cites WIRE_GUIDE.md §1).

3. **docker-compose.dev.yml** — services for local dev:
```yaml
version: '3.9'
services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_USER: inflora
      POSTGRES_PASSWORD: dev
      POSTGRES_DB: inflora
    ports: ["5432:5432"]
    volumes: ["postgres-data:/var/lib/postgresql/data"]
  nats:
    image: nats:2.10-alpine
    command: ["-js"]
    ports: ["4222:4222"]
  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]
volumes:
  postgres-data:
```

4. **Makefile** — workspace-level targets:
```makefile
dev:
	docker compose -f docker-compose.dev.yml up -d

dev-down:
	docker compose -f docker-compose.dev.yml down

test-all:
	@for repo in inflora-shared inflora-tolkien inflora-ingest inflora-palantir inflora-saruman inflora-ws-gateway; do \
		echo "==> $$repo" \
		&& (cd $$repo && make test) || exit 1; \
	done

build-all:
	@for repo in inflora-shared inflora-tolkien inflora-ingest inflora-palantir inflora-saruman inflora-ws-gateway; do \
		echo "==> $$repo" \
		&& (cd $$repo && make build) || exit 1; \
	done
```

5. **README-how-to-clone.md** — explain that workspace is local-only, each repo is independent on GitHub. Devs clone  `git clone` on each service repo they work on.

`backend/` itself is NOT a git repo. It's a workspace folder.

### Step 7: FINAL REPORT

Print a report:

```
✅ Phase 0 complete.

Repos created (6/6):
- https://github.com/frederickmarvel/inflora-shared    [commit: <hash>]
- https://github.com/frederickmarvel/inflora-tolkien   [commit: <hash>]
- https://github.com/frederickmarvel/inflora-ingest    [commit: <hash>]
- https://github.com/frederickmarvel/inflora-palantir  [commit: <hash>]
- https://github.com/frederickmarvel/inflora-saruman   [commit: <hash>]
- https://github.com/frederickmarvel/inflora-ws-gateway [commit: <hash>]

Workspace files:
- backend/README.md
- backend/REPO-STRUCTURE.md
- backend/docker-compose.dev.yml
- backend/Makefile
- backend/README-how-to-clone.md

CI status: green/yellow/red (per repo)

Total files created: <N>
Total lines: <N>

Next phase: Phase 1 — shared library (inflora-shared). Use the Phase Prompt Template below.
```

## Anti-ham rules (DON'T DO)

- ❌ **Don't invent event names, ports, table columns, endpoint paths, RPC names.** All are in almanac docs. Edit docs first if needed.
- ❌ **Don't add business logic in Phase 0.** Only skeletons. `cmd/server/main.go` prints "TODO" + exit 0.
- ❌ **Don't push without** showing Marvel the plan first and getting approval.
- ❌ **Don't write different versions of port/event/endpoint than WIRE_GUIDE.md §1-5.** Those are canon.
- ❌ **Don't create monorepo.** Polyrepo only (6 separate gits).
- ❌ **Don't run`make dev` yet** (no business logic to test).
- ❌ **Don't create** `backend/.git` (workspace folder is not a git repo).
- ❌ **Don't add CI that requires secrets** at Phase 0 (no Midtrans keys, no internal API keys, etc.).
- ❌ **Don't push to main directly without** Marvel's OK**. Always show plan first.

## Acceptance criteria for Phase 0

- [ ] All 6 GitHub repos exist at github.com/frederickmarvel/
- [ ] Each repo has skeleton files: README.md, ARCHITECTURE.md, CHANGELOG.md, Makefile, Dockerfile, go.mod, .gitignore, .golangci.yml, cmd/server/main.go (or cmd/gateway/main.go for ws-gateway), .github/workflows/ci.yml
- [ ] For saruman: also cmd/migrate/main.go (empty stub)
- [ ] For shared: NO cmd/server/main.go, but go.mod + empty package dirs per layout
- [ ] Workspace-level: backend/README.md, REPO-STRUCTURE.md, docker-compose.dev.yml, Makefile, README-how-to-clone.md
- [ ] All 6 initial commits pushed to GitHub
- [ ] CI workflows visible in each repo's Actions tab (may be yellow until first real test runs)
- [ ] No invented names. Everything cross-references to almanac docs.

## When stuck

If something is ambiguous or missing from almanac docs:

1. **Stop.** Don't guess.
2. **Tell** Marvel** what you need: "I'm about to do X, but I can't find Y in almanac. Options are A, B, C. Which?"
3. Wait for user response.
4. If**** Marvel says "use your judgment", document the choice in almanac docs first, then proceed.

## Output format

After each step, output:
1. What you did
2. Where you put it (file paths)
3. Any errors or surprises
4. Next step

At end of Phase 0, output the Final Report.
````

---

## Phase Prompt Template (for Phases 1+)

Use this template when starting each subsequent phase (1-14). Copy and fill in.

```markdown
# Task: Build Inflora Backend — Phase N — <Phase Name>

## Context

This is **Phase N** of the Inflora backend build (continue from Phase N-1).

Already done (per BACKEND_BUILD_PLAN.md):
- Phase 0: 6 GitHub repos with skeletons, all pushed ✅
- Phase 1: <list what's done>
- ...

## Source of truth — READ FIRST

Read all of these in order, same as Phase 0:

1. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/WIRE_GUIDE.md
2. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/BACKEND_BUILD_PLAN.md
3. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/schemas/INDEX.md
4. Other schema files as needed

**Anti-hallucination:** same as Phase 0. Never invent.

## What to build in THIS task

Execute **Phase N — <name>** of BACKEND_BUILD_PLAN.md:

[Paste the relevant Phase N section from BACKEND_BUILD_PLAN.md]

## Deliverables for Phase N

[Same structure as Phase 0: plan first, get approval, then code, then push, then report]

## Workflow (same as Phase 0)

1. Read docs
2. Plan — show****** proposal, stop for approval
3. Implement
4. Test locally
5. Push to GitHub
6. Final report

## Acceptance criteria for Phase N

[Specific to this phase, e.g.:
- All Go files compile (`go build ./...`)
- All tests pass (`go test -race ./...`)
- 80%+ coverage on internal packages
- Lint clean (`make lint`)
- CI green on the repo
- Demo: `<specific scenario>` works end-to-end]
```

---

## Specific prompts for each service (after Phase 1)

Once the polyrepo exists and shared library is in place, use these prompts to**start Phase 3-7 services**:

### Phase 3 prompt (tolkien)

```markdown
# Task: Phase 3 — Build tolkien service

## Context

Phase 0-2 complete. `inflora-shared` exists with proto definitions. `inflora-tolkien` is a Go module.

## Read first

1. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/WIRE_GUIDE.md §1, §6, §8.1
2. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/BACKEND_BUILD_PLAN.md Phase 3
3. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/schemas/03-http-api.md (tolkien endpoints)
4. https://raw.githubusercontent.com/frederickmarvel/almanac-Inflora/main/planning/schemas/01-event-catalog.md (events tolkien publishes)

## What to build

Execute Phase 3 of BACKEND_BUILD_PLAN.md: tolkien service.

**Constraints:**
- Port: HTTP 8080 (do not change)
- Go + chi + sqlc + nats.go + zap + OpenTelemetry
- Uses inflora-shared v0.1.0+ for events, auth, observability, db, config
- All HTTP responses follow error format from 00-frozen-contracts.md §6
- All tokens: opaque, prefixed sk_/ok_, bcrypt-hashed
- Money: BIGINT IDR, no decimals
- Test coverage: 80%+ on internal packages

## Deliverables

[Paste Phase 3 deliverables list from BACKEND_BUILD_PLAN.md]

## Acceptance criteria

[Paste Phase 3 test cases + acceptance criteria]

## Workflow

[Plan → approve → code → test → push → report]
```

(Phase 4-7 follow the same template, replace "tolkien" with relevant service.)

---

## Anti-hallucination cheat sheet (paste into any Claude Code session)

```markdown
Inflora backend rules. Never violate:

1. Schema is ground truth. Read almanac/planning/schemas/ before inventing.
2. Money = BIGINT IDR, no decimals.
3. Ledger is append-only. Corrections are reversal entries.
4. Every webhook has idempotency key.
5. Tokens are opaque, prefixed sk_/ok_, bcrypt-hashed.
6. Events flow via NATS JetStream, not HTTP.
7. HTTP errors follow format from 00-frozen-contracts §6.
8. WebSocket errors follow close codes from 05-websocket-protocol §5.
9. Per-streamer isolation: lock granularity per hub, not global.
10. Migrations run via saruman's cmd/migrate, no service owns its own migration runner.
11. Ports: tolkien 8080, ingest 8081, palantir 7001, saruman 7002+8082, ws-gateway 8083.
12. DB ownership: see WIRE_GUIDE.md §6. Never write a table not in your row.
13. All inter-service HTTP uses X-Internal-Api-Key header.
14. All gRPC uses authorization: Bearer <engine-api-key> header.
15. Don't push to main without user approval.
```

Save this cheat sheet as `.claude/rules.md` or similar in your workspace so every Claude Code session loads it.

---

*This file is the master reference for prompting Claude Code on the Inflora backend build.*