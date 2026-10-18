# 04 — Frontend Plan (User Dashboard + Inflora Backoffice, remote-repo parity)

> Planning only. Two products on the web front: the **User Dashboard** (streamers manage their overlay capabilities and money) and the **Inflora Backoffice** (staff operations, from `02-backoffice.md`). The backend contract for every function listed here either exists today or is queued in `00/01/02/03`.
> **Remote repo status (verified 2026-10-16, UPDATED):** `https://github.com/leolaiherman/inflora-front.git` is private (auth failure without credentials) but was **cloned with owner-supplied credentials on 2026-10-16** to `/home/ubuntu/inflora-dev/inflora-front`. The §7 discovery protocol has been **executed**; results live in **`frontend-parity-matrix.md`** (this directory). Headline findings: it is **not** a parity clone of this dashboard — it is a React 19 + TanStack Query app ("campaign infrastructure for creators": campaigns, overlay widgets + layout editor, live control room, rich tip forms, clips, earnings), 100% mock-backed, with **no auth and no network calls at all**. Planning consequence (per the approved implementation plan): inflora-front becomes the **canonical creator dashboard + viewer tip surface** (phases P0–P5 in the parity matrix); this SvelteKit app keeps the **Inflora Backoffice** and stays as the standby donor page until the React `/tip/:handle` flow passes E2E.

---

## 1. Current assets and what changes

- Local app: `frontend/` (SvelteKit). Routes in `frontend/src/routes/` — donor pages (`d/[streamer_id]/`), dashboard (`dashboard/…`), admin (`admin/…`), auth (`login|logout|signup`).
- API clients: `frontend/src/lib/api/tolkien.ts` (worker-facing), `admin.ts` (operator-facing), `ingest.ts` (donor edge), `base.ts` + `errors.ts` (transport/error translation).
- Stores: `frontend/src/lib/stores/session.ts` (`inflora_sk`), `adminSession.ts` (`inflora_ak`).
- Overlay app: sibling `overlay/` (OBS browser source; consumes `ok_` token + WS) — only touched in this plan by the dashboard's "Overlay" page where the OBS URL is composed.

## 2. Auth-layer changes (Firebase SDK)

Per `01-firebase-rbac.md`:

- New `frontend/src/lib/firebase.ts`: Firebase JS SDK init (`initializeApp`, `getAuth`) using public config from `PUBLIC_FIREBASE_*` env (Vite `import.meta.env` / SvelteKit `$env/dynamic/public`).
- Auth flows (`login`, `signup`, `admin/login`): replace email/password forms' direct backend calls with `signInWithEmailAndPassword` / `createUserWithEmailAndPassword`; on success call `POST /v1/auth/firebase/exchange` **only during the bridge phase**; in target state send the Firebase ID token directly.
- `session.ts`/`adminSession.ts`: store `{firebaseIdToken|null, roles[], principal}`; watch `onIdTokenChanged` to refresh; single-source helper `authHeaders()` used by both API clients.
- Keep `inflora_sk` code paths until the bridge is removed (Phase G), behind a store flag so rollback is one commit.
- Update `frontend/docs/AUTH.md` to describe the Firebase ID token model (and keep a "legacy bridge" section until cutover).

## 3. User Dashboard — function-by-function backend parity matrix

Each row states today's backend status (from `00-current-state.md` verification) and the work item.

| # | Dashboard function (streamer) | Backend endpoint (frozen) | Status today | Work |
|---|---|---|---|---|
| D-1 | Sign up / log in / log out | `/v1/auth/*` (+ Firebase exchange) | sk_-based | Firebase flow (§2) |
| D-2 | Profile (`GET /v1/me`) | implemented | ready | store roles from server, render |
| D-3 | Balance card | `GET /v1/me/balance` | implemented | add `pending vs available vs held` visualization; poll on visibility |
| D-4 | Settings (display rate, min/max, voice/youtube toggles) | `GET|PUT /v1/me/settings` | implemented | no backend change; add error translations |
| D-5 | Bank accounts list/add | `GET|POST /v1/me/bank-accounts` | implemented (schema bug idx: primary uniqueness — see 00 §6.3) | migrate constraint fix before this page is advertised |
| D-6 | Overlay capability center (the core "manage overlay capabilities") | `POST /v1/me/overlay-token/rotate` + WS URL builder | implemented | page additions: show OBS URL with `?token=ok_…`, copy button, "what my viewers see" preview link (overlay app), per-settings integration test |
| D-7 | Donations history | `GET /v1/me/donations` (`?limit&cursor`, spec `03-http-api.md` §5, cursor per `00-frozen-contracts.md`) | **missing** | NEW tolkien endpoint (read-only, personal scope); page enrichment: status chips (CHARGED/SETTLED/REFUNDED), receipt re-send |
| D-8 | Payouts: request + history | `POST /v1/me/payouts` + `GET /v1/me/payouts` | **missing** (both) | NEW: POST per frozen spec (§5 of `03-http-api.md`, validations incl. `422 INSUFFICIENT_BALANCE`, `422 BELOW_MIN_WITHDRAWAL`, `403 STREAMER_HOLD_ACTIVE`); GET list own payouts (read-only scope). Backend command surface from `03-withdrawals.md` §3 |
| D-9 | Notifications on donations (overlay) | `streamer_settings.notify_on_donation` consumed by ws-gateway | partial (gateway consumes `donation.settled.v1` when flag true) | verify + smoke test via OBS sim |

## 4. Backoffice frontend — page-by-page

Source of design: `02-backoffice.md` §2 IA; new API client `frontend/src/lib/api/backoffice.ts`. Reuse `admin/` route tree, rename brand to "Inflora Backoffice".

| Page | Uses | Notes |
|---|---|---|
| login | Firebase + `/v1/auth/firebase/exchange` | shows role names post-login |
| Overview | summary + new payout KPIs (`GET /v1/backoffice/stats` NEW — read-only aggregates; add to tolkien) | reuse `AdminStatus.svelte` |
| Donations (existing) | existing `GET /v1/admin/donations*` | unchanged backend; perm-checked |
| Payout queue | `GET /v1/backoffice/payouts?status=&cursor=` | FIFO; filter chips; batch builder (select N → create DRAFT) |
| Batch detail | `GET /v1/backoffice/payout-batches/{id}` | maker submit / checker approve buttons; per-payout outcome table; close on PARTIAL_FAILED |
| Exceptions | `GET /v1/backoffice/exceptions?kind=` | tabs: Stuck / Needs review / Dead letters / Drift; each row actions from `02 §6` (refresh-provider-state, retry, force-fail [SUPERADMIN badge], dismiss, replay) |
| Holds | existing holds endpoints (re-pointed to Saruman + RBAC) | create/release forms + ACTIVE filters |
| Streamers | NEW superadmin endpoints | activate/deactivate, balance snapshot |
| Team | NEW `/v1/backoffice/users*` | role chips, disable, session revoke |
| Audit | NEW `GET /v1/backoffice/audit` | filters by actor/action/resource |

## 5. Contract compliance for new/getting-real endpoints (do not invent shapes)

- Pagination: cursor envelope `{data, pagination:{next_cursor, has_more}}` (`00-frozen-contracts.md`); implementer must not introduce offset-only APIs.
- Errors: frozen envelope with request id (`{error:{code,message,request_id}}`); new error codes used in this plan: `MAKER_CHECKER_CONFLICT` (409), `PAYOUT_NOT_BATCHABLE` (409, already in spec), `BATCH_HAS_HOLDS` (409, already in spec), `INVALID_TRANSITION` (409 + details `{current_status, from, to}`).
- A route with a placeholder today (`dashboard/donations`, `dashboard/payouts`) must show **real data or a precise onboarding state** ("withdrawals open after bank account verified") — never a fake table.

## 6. Overlay capability management specifics (the user's core dashboard ask)

Overlay capabilities = settings (§D-4), media toggles (voice/youtube, `allow_voice`, `allow_youtube`, `auto_play_*`), token rotation (§D-6), OBS wiring help, and donation preview. Deliverables:

1. Page: current overlay URL, `Rotate` (confirm modal warns "old OBS sources break"), copy URL.
2. Help block: OBS > Browser Source > URL, plus troubleshooting table (4401 token expired → rotate; 4403 account disabled; 4408 reconnect; 4429 rate limit).
3. "Preview" button opens the sibling `overlay/` build with a demo donation (dev-only fixture) — requires ingest dev fixture, not a production endpoint (no new backend needed if the overlay app accepts a query param, else a dev flag).
4. If the streamer toggles settings, the dashboard hints "takes effect on the next donation" (per snapshot semantics in `01-event-catalog.md` §2).

## 7. Remote repository discovery protocol (run when credentials exist) — **STATUS: COMPLETED**

Executed 2026-10-16 with owner credentials. Complete findings: `frontend-parity-matrix.md` (every repository symbol ↔ backend disposition, drift rows D-031…D-036). The steps below are kept as the record of what was run.

The implementer (who has access to leolaiherman/inflora-front) must:

1. `git clone https://github.com/leolaiherman/inflora-front.git` with the authorised account; if private, escalate access before planning further.
2. Extract: framework + version, `package.json` dependency diff vs local `frontend/`, route tree, Firebase config expectations (`firebaseConfig` fields it reads), env var names (`PUBLIC_*`), every `fetch/axios/http` call (endpoint method + path + auth header + body), overlay functions (token handling, WS connection, media playback), and any i18n keys.
3. Produce **`frontend-parity-matrix.md`** in THIS directory: rows = remote function; columns = remote implementation evidence, local equivalent, backend availability status (exists/missing/planned in `03-withdrawals.md`/`05-phases-and-gates.md` phase), and work item.
4. Conflicts: for each remote endpoint that contradicts the frozen contracts (different path, param, envelope), **do not implement silently** — add a CONTRACT_DRIFT row (D-031 open series) and record the decision.
5. Parity bar: after implementation, for every remote function in the matrix, the function must be served by the backend (real endpoint or explicitly rejected with a designed error), with a test. Anything that cannot be served (e.g., an external service the project won't adopt) gets an "explicit no + alternative" row.
6. If the clone still fails at implementation time, do not block: the frozen-contracts parity matrix (§3/§4 here) is the binding scope, and this protocol remains queued.

## 8. Backend endpoint additions batting list (frontend-driven)

Already covered in 01/02/03; consolidated here for the frontend implementer:

- `GET /v1/me/donations`, `POST /v1/me/payouts`, `GET /v1/me/payouts` (D-7/D-8)
- `GET /v1/backoffice/stats` (aggregates only)
- Backoffice operational endpoints (`02 §7`)
- `POST /v1/auth/firebase/exchange` + Firebase middleware (`01 §7`)
- All authenticating fences: Firebase ID token (target) or `sk_`/`ak_` bridge (rollout); **never** internal key from the browser.

## 9. Acceptance criteria

1. `Inflora Backoffice` branding everywhere visible; zero user-visible "Inflora Admin" strings.
2. Streamer can: sign up with Firebase → set settings → provisions bank → sees real donations list with working cursor → sees real payout flow → rotates overlay token and gets a working OBS URL.
3. Backoffice operator can: view queues, batch payouts (submit), be blocked from approving their own batch, see exceptions, act on each class from `02 §6`.
4. Remote-repo parity matrix exists and every row has a disposition (implemented/planned/explicit-no), with the e2e test ids from `05-phases-and-gates.md`.