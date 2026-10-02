# Profile detection

> How to decide which profiles apply to the working directory. Used in Phase 1 of `/cso-audit`.

Detection is **signal-based** — find at least one positive signal in the cwd (or a sane recursive scan, capped at depth 4 and excluding `node_modules`, `vendor`, `.git`, `dist`, `build`, `target`, `Pods`, `.next`, `.terraform`) and the profile activates.

When in doubt, propose the profile and let Phase 2 confirmation drop it. False positives at detection are cheap; false negatives are dangerous.

`generic` is always active and doesn't need detection.

---

## `frontend`

A web frontend / SPA / static site. Browser-executed code is the audit target.

**Strong signals (any one triggers):**
- `package.json` with any of: `react`, `next`, `vue`, `nuxt`, `svelte`, `solid`, `astro`, `remix`, `gatsby`, `vite`, `webpack`, `parcel`, `angular`, `@angular/core`, `lit`, `preact`
- `index.html` at repo root or in `public/` / `static/`
- Any `*.tsx`, `*.jsx`, `*.vue`, `*.svelte`, `*.astro` file
- `next.config.*`, `vite.config.*`, `nuxt.config.*`, `astro.config.*`, `vue.config.*`, `svelte.config.*`, `angular.json`

**Weak signals (need a second confirmation):**
- `public/` directory containing static assets
- `Procfile` or deployment config naming a static-host target (Vercel, Netlify, Cloudflare Pages, GitHub Pages)

**Negative signals (do NOT activate `frontend`):**
- A `package.json` whose `main` points to a server file and has zero browser-side dependencies (likely backend-only Node service)

---

## `backend`

Server-side service. Any language. APIs, business logic, datastore access are the audit target.

**Strong signals (any one triggers, grouped by language):**

| Language | Signals |
|----------|---------|
| Go | `go.mod`, `main.go`, `cmd/*/main.go`, `internal/`, `pkg/` containing HTTP/gRPC handlers |
| Node.js | `package.json` with `express`, `fastify`, `koa`, `hapi`, `nestjs`, `hono`, `elysia`, `next` API routes, `apollo-server`, server entry like `server.js` / `app.js` / `index.js` outside `src/` browser code |
| Python | `requirements.txt` / `pyproject.toml` with `django`, `flask`, `fastapi`, `starlette`, `aiohttp`, `tornado`, `bottle`, `pyramid`, `quart`; `wsgi.py`, `asgi.py`, `manage.py` |
| Java / Kotlin | `pom.xml`, `build.gradle*` with `spring-boot`, `quarkus`, `micronaut`, `ktor`, `javalin`, `vertx`; `src/main/java/` or `src/main/kotlin/` |
| Ruby | `Gemfile` with `rails`, `sinatra`, `roda`, `hanami`, `grape`; `config.ru`, `app/controllers/` |
| PHP | `composer.json` with `laravel/framework`, `symfony/framework-bundle`, `slim/slim`, `cakephp/cakephp`, `yiisoft/yii2`; `public/index.php` routing |
| Rust | `Cargo.toml` with `axum`, `actix-web`, `rocket`, `warp`, `tide`, `poem`, `salvo`; `src/main.rs` running a server |
| .NET / C# | `*.csproj`, `*.sln`, `Program.cs` with `WebApplication.CreateBuilder`, `Startup.cs`; `Microsoft.AspNetCore.*` references |
| Elixir | `mix.exs` with `phoenix`, `plug`; `lib/*/router.ex`, `lib/*/endpoint.ex` |

**Weak signals:**
- `Procfile` with a non-static process type (e.g., `web: bundle exec puma`)
- Dockerfile that `CMD`s a server (e.g., `["node","server.js"]`, `["uvicorn","app:asgi"]`)

If multiple languages co-exist (polyglot monorepo), activate `backend` once and audit all detected services.

---

## `infrastructure`

Infrastructure-as-Code, container configs, orchestration, CI/CD. Configuration is the audit target.

**Strong signals (any one triggers):**
- `Dockerfile` (any name matching `Dockerfile*` or `*.dockerfile`)
- `docker-compose.y*ml`, `compose.y*ml`
- `*.tf`, `*.tfvars`, `terragrunt.hcl`
- `Pulumi.yaml`, any `Pulumi.*.yaml`
- `cdk.json`, `cdktf.json`
- `serverless.y*ml`, `sam.y*ml`, `template.yaml` (SAM/CloudFormation)
- Kubernetes manifests — any `*.y*ml` containing `apiVersion:` + `kind:` (Deployment, Service, Ingress, etc.)
- `helm/` or `Chart.yaml`
- `ansible.cfg`, `playbook.y*ml`, `inventory*`, `roles/`
- `.github/workflows/*.y*ml`, `.gitlab-ci.y*ml`, `.circleci/config.y*ml`, `Jenkinsfile`, `bitbucket-pipelines.y*ml`, `azure-pipelines.y*ml`
- `Vagrantfile`
- `*.bicep`, `azuredeploy.json`

**Weak signals:**
- `infra/`, `terraform/`, `k8s/`, `kubernetes/`, `deploy/`, `ops/` directories

---

## `databases`

Schema, migrations, ORM configuration, access patterns. Note: this is a *focused* lens on data-layer concerns — auth/injection issues in handlers belong to `backend`.

**Strong signals (any one triggers):**
- A directory named `migrations/`, `db/migrate/`, `db/migrations/`, `prisma/migrations/`, `alembic/versions/`, `flyway/`, `liquibase/`, `internal/migrate/`
- `schema.sql`, `schema.prisma`, `schema.rb`
- `prisma/schema.prisma`
- ORM dependency: `prisma`, `typeorm`, `sequelize`, `mongoose`, `gorm.io/gorm`, `ent.`, `sqlalchemy`, `peewee`, `django.db.models`, `activerecord`, `eloquent`, `diesel`, `sqlx`, `entity-framework`
- DB driver dependency without ORM also counts: `pg`, `mysql2`, `psycopg`, `pymongo`, `redis`, `mongodb`, `couchbase`, `cassandra-driver`, `cqlsh`, `clickhouse-driver`
- DB config files: `database.yml` (Rails), `knexfile.*`, `mongo-init.js`

**What to look for (sets the audit scope, doesn't change detection):**
- SQL injection surface in queries
- Missing indexes that enable DoS via slow queries
- Sensitive columns not encrypted at rest
- Migration scripts that drop without backup
- Hardcoded connection strings
- Over-permissive DB users (granting `ALL` to app role)
- Missing row-level security where multi-tenant

---

## `android`

Native Android application code.

**Strong signals (any one triggers):**
- `AndroidManifest.xml` (anywhere, not in `node_modules`)
- `build.gradle` or `build.gradle.kts` with `com.android.application` or `com.android.library` plugin
- `app/src/main/AndroidManifest.xml`
- `*.gradle` referencing `compileSdkVersion`, `minSdkVersion`, or `targetSdkVersion`
- Hybrid frameworks targeting Android — React Native (`android/` directory + `react-native.config.js`), Flutter (`android/` + `pubspec.yaml`), Cordova/Ionic (`config.xml` + `android/`)

**Weak signals:**
- Kotlin (`*.kt`) or Java (`*.java`) files under an `android/` path — confirm with manifest before activating

---

## `ios`

Native iOS application code.

**Strong signals (any one triggers):**
- `*.xcodeproj/` or `*.xcworkspace/`
- `Info.plist` (anywhere, not in `node_modules`)
- `Podfile` or `Podfile.lock`
- `Package.swift` with iOS / iPadOS / macOS / watchOS / tvOS platform target
- Swift (`*.swift`) or Objective-C (`*.m`, `*.mm`, `*.h`) source under an `ios/` path
- Hybrid frameworks targeting iOS — React Native (`ios/` + `react-native.config.js`), Flutter (`ios/` + `pubspec.yaml`), Cordova/Ionic (`config.xml` + `ios/`)
- `.xcconfig`, `entitlements.plist`

---

## `generic` (always-on)

Baseline checks that apply to any software project. Active for every audit.

**What it covers (no detection needed):**
- Secrets in git history and current tree (gitleaks, trufflehog)
- Dependency vulnerabilities for whichever package managers exist (npm, pip, gem, cargo, go mod, composer, gradle, mvn)
- Supply-chain hygiene (SLSA provenance hints, lockfile presence, pinned vs floating versions)
- License compliance flags (GPL-where-not-allowed, missing LICENSE)
- Repo hygiene (`.env` committed, `*.pem`/`*.key`/`*.p12` committed, sensitive paths not in `.gitignore`)
- Branch protection / signing hints if `.github/` or `.gitlab/` config exists

---

## Multi-profile scenarios

Common combinations:

| Repo type | Likely profiles |
|-----------|-----------------|
| Next.js fullstack app | `frontend` + `backend` + `generic` (+ `infrastructure` if Dockerfile) |
| Go microservice with Helm | `backend` + `infrastructure` + `generic` (+ `databases` if migrations) |
| React Native app | `frontend` + `android` + `ios` + `generic` |
| Terraform-only repo | `infrastructure` + `generic` |
| DB schema repo | `databases` + `generic` |
| Monorepo (web + api + infra + mobile) | All seven, but ask user in Phase 2 to scope down if they only care about one |

If more than four profiles activate, Phase 2 should default-suggest the user split into focused runs ("scope is broad — recommend running `frontend+backend+generic` first, then `infrastructure+databases` separately").

## Anti-patterns

- ❌ Activating `frontend` because `node_modules/react/...` exists (it's a transitive dep). Only count *direct* dependencies.
- ❌ Activating `backend` from a single `index.js` that's just a build script. Confirm with a framework signal.
- ❌ Skipping `generic` because the user said "just audit the frontend." `generic` is always active — secrets in `.env` matter even for a frontend-only repo.
