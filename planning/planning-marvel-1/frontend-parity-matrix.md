# frontend-parity-matrix.md — leolaiherman/inflora-front ↔ Inflora backend

> Prepared 2026-10-16 by running the `04 §7` discovery protocol with the owner-supplied credentials.
> Source analyzed: fresh clone at `/home/ubuntu/inflora-dev/inflora-front` (also at `/tmp/inflora-front-analysis` for read-only exploration).
> **Route-name caveat:** every endpoint path below marked **PROPOSED** is a naming suggestion for the reviewer — none of it is frozen. Adding them to the frozen contracts requires CONTRACT_DRIFT rows first (see `../CONTRACT_DRIFT.md`, D-031 series and `04-frontend.md` §7.4). No implementation may use these paths before that ack.

## 0. Repo-level findings (verified by grep + read)

- React 19 + React Router 7 + TanStack Query v5 + Zustand; Vite; TypeScript ~6.0; no backend anywhere.
- **Zero real network calls.** Only `fetch()` reads a local `data:` URL (`src/services/audio/clips.ts:25`). No axios/EventSource/WebSocket in deps; `BroadcastChannel('inflora.live-feed')` is the mock's only "transport" (`src/services/mock-backend/liveSimulator.ts:151`).
- **No auth of any kind.** Single hard-coded creator `cr_juno`/`junoplays` in `src/services/mock-backend/seed.ts:105-122`; DB in localStorage `inflora.mockdb`; no firebase artifacts (zero grep hits); sitemap has no login/signup routes.
- `VITE_API_MODE` (`'mock'|'http'`) is declared at `src/config/app.ts:29` but **not read anywhere** (comment-only at `src/models/repositories/index.ts:2-4`). The HTTP repository layer must be written and wired to this flag.
- Money is integer IDR everywhere (`decimals: 0`, `src/config/app.ts:23`) — matches backend BIGINT IDR.
- `ApiError { status, message }` (`src/services/apiError.ts:2-10`) — the http layer must translate the backend frozen envelope `{error:{code,message,request_id}}` into it.

## 1. Account / identity

| # | Remote function (evidence) | Backend disposition | Work item |
|---|---|---|---|
| A-1 | `accountRepository.get()` → `Account` (`:14,28`) | EXTEND tolkien `GET /v1/me` — add handle, bio, verified, region, categories, coverSeed, connections, liveSessionId, balance | P1. `streamers` gains profile columns via saruman migration. Frozen envelope reused. |
| A-2 | `setConnection(platform, connected)` → `Account` (`:15,32`; 404 unknown platform) | NEW (PROPOSED) `PUT /v1/me/platforms/{platform}` {connected} | P4. Table `streamer_platforms`; OAuth deferred — connect records handle/followers placeholders exactly like mock. |
| A-3 | `setLive(isLive)` → void; fresh `liveSessionId` (`:16,47`) | NEW (PROPOSED) `POST /v1/me/live-sessions` (open/close) | P2. `live_sessions` table + `live.session.started/ended` events; caller/session ownership server-side. |
| A-4 | `profile(handle)` → `PublicProfile { creator, campaigns, isSelf }`, self strips balance/liveSessionId (`:17,59,72`) | NEW (PROPOSED) `GET /v1/public/u/{handle}` | P1/P2 read shape exactly; strips private fields server-side (same rule as mock `:72`). |

## 2. Campaigns

| # | Remote function (evidence) | Backend disposition | Work item |
|---|---|---|---|
| C-1 | `list(query)` → `CampaignView[]`; server-side fuzzy search (title/summary/owner/tags), sort ending|budget|newest, scopes discover|joined|mine|active (`campaignRepository.ts:25,49-85`) | NEW (PROPOSED) `GET /v1/campaigns` | P4. `campaigns` + `campaign_participations` tables; full-array response at MVP (drift row: no pagination). |
| C-2 | `get(id)` (`:26,87`) | NEW `GET /v1/campaigns/{id}` | P4 |
| C-3 | `assets(id)` → campaign sponsor widgets (`:27,91`) | NEW `GET /v1/campaigns/{id}/assets` | P4 |
| C-4 | `join(id)` → `JoinResult`; eligibility check, copies sponsor widgets into library, participation++, `participantCount++` (`:28,100-116`) | NEW `POST /v1/campaigns/{id}/join` — 409 joinState reason codes per `rules/campaignRules.ts:160` | P4 |
| C-5 | `leave(id)` — participation 'left', count--, **deletes campaign widgets + strips them from every theme** (`:29,123-137`) | NEW `POST /v1/campaigns/{id}/leave` | P4 |
| C-6 | `create(request)` → owner view; **wallet debit** (402 not-enough), charge = budget + 10% fee, auto sponsor/goal widgets, requirements synthesized from clipSpec (`:30,144-196`) | NEW `POST /v1/campaigns`; money write = **saruman command** (tolkien facade never writes money — Phase C grep gate) | P4 |
| C-7 | `history()` → ended campaigns sorted (`:31,234`) | NEW `GET /v1/me/campaigns/history` | P4 |

## 3. Widgets (library)

| # | Remote function (evidence) | Backend disposition | Work item |
|---|---|---|---|
| W-1 | `list()` (`widgetRepository.ts:21,29`) | NEW `GET /v1/me/widgets` | P3. `widgets` table (JSONB content + appearance + source). |
| W-2 | `create(input)` — 422 validation (`:22,36,109-116`) | NEW `POST /v1/me/widgets` | P3 |
| W-3 | `update(id, input)` — **server re-fits layout spots whose footprint changed, on every theme/frame** (`:24,57,74-89`) | NEW `PATCH /v1/me/widgets/{id}`; re-fit is server-side on save | P3 |
| W-4 | `remove(id)` — 404; **409 sponsor widget of actively-joined campaign**; strips from all themes (`:26,92-103`) | NEW `DELETE /v1/me/widgets/{id}` | P3 |

## 4. Themes & layouts

| # | Remote function (evidence) | Backend disposition | Work item |
|---|---|---|---|
| T-1 | `library()` → `ThemeLibrary { themes, activeThemeId }` (`themeRepository.ts:17,39`) | NEW `GET /v1/me/themes` | P3. `themes` JSONB rows; frames landscape/portrait/square/classic. |
| T-2 | `create({name, copyFromId?})` — duplicate scene/layouts/setup (`:19,44`) | NEW `POST /v1/me/themes` | P3 |
| T-3 | `save(theme)` — full server validation: grid fit/no-overlap/known widgets, tiers, integer prices, marathon rules (`:20,63-92`) | NEW `PUT /v1/me/themes/{id}`; server-stamped `updatedAt`; validation constants ported from `rules/themeSetup.ts`, `layoutGrid.ts`, `marathon.ts` | P3 |
| T-4 | `remove(id)` — 409 "keep at least one"; active falls back (`:21,94-100`) | NEW `DELETE /v1/me/themes/{id}` | P3 |
| T-5 | `activate(id)` → on-stream theme switch; mid-stream offer-diff check (`:23,106` + `rules/themeSetup.ts offerChanges`) | NEW `POST /v1/me/themes/{id}/activate` | P3 |

## 5. Clips (VOD)

| # | Remote function (evidence) | Backend disposition | Work item |
|---|---|---|---|
| CL-1 | `sources()` → past streams from YT/Twitch (`clipRepository.ts:20,25`) | NEW `GET /v1/me/clip-sources` — stub list at MVP; ingestion later | P4 |
| CL-2 | `list()` (`:21,32`) | NEW `GET /v1/me/clips` | P4 |
| CL-3 | `create(input)` → draft|tracking; trim validation; submissions++ on submit (`:22,38,63-66`) | NEW `POST /v1/me/clips`; backend owns tracking→approved/rejected lifecycle + views/earned | P4 |

## 6. Tips / supporter flow (viewer-facing, PUBLIC)

| # | Remote function (evidence) | Backend disposition | Work item |
|---|---|---|---|
| S-1 | `session(handle)` → `TipSession { creator, live, sessionId, layoutWidgets }` — widgets **as the on-stream theme prices them**; polled every 2s (`supportRepository.ts:39,58` + `useTipFormController.ts:61`) | NEW (PROPOSED) `GET /v1/public/u/{handle}/tip-session`. Read-only: theme setup × layout × live session. Cached, rate-limited. | P2 |
| S-2 | `send(handle, input)` → `SentDonation`; `checkTip` server-side: priced-on-layout (404), gift amount = price×qty (422), alert ≥ price, call tickets [1,2,3] + `allowedMs` server-computed, voice/media rules, **409 stream ended / stale sessionId** (`:40,85,197-233`) | EXTEND ingest `POST /v1/donations` rich payload (widgetId, quantity, tier, media, call) + server checkTip pre-check; drift row vs frozen §4. Backend publishes donation/call to live feed. | P2 |
| S-3 | `supporter()` → `SupporterAccount {name,email} | null` (`:42,164`) | NEW `GET /v1/supporters/me` (Firebase USER identity, optional) | P2. Revisits A-1: anonymous donors may become USER-role supporters. |
| S-4 | `signUp(account, claimIds?)` — creates supporter; **claims guest tips by email/ids** (`:44,168-177`) | NEW `POST /v1/supporters` + claim semantics on donations (`claimed` flag) | P2 |
| S-5 | `history()` → claimed SentDonations (`:46,191`) | NEW `GET /v1/supporters/me/tips` | P2 |
| S-6 | `leaveCall(handle, callId)` → relays `call-leave` (`:48,183`) | NEW (PROPOSED) `POST /v1/public/u/{handle}/calls/{id}/leave` → live event | P2/P3 |

## 7. Earnings / withdraw

| # | Remote function (evidence) | Backend disposition | Work item |
|---|---|---|---|
| E-1 | `summary()` → `{available, pending, lifetime, months[6], sources: campaigns|clips|donations}` (`earningsRepository.ts:5,12-14`) | EXTEND `GET /v1/me/balance` — monthly chart + source split requires ledger source tagging (drift row: frozen posting template §1 shape) | P2 — **D-032 design in flight 2026-10-18** (ledger `source` tag + earnings shape) |
| E-2 | `withdraw()` → whole balance; 400 if ≤ 0 (`:6,17`) | `POST /v1/me/payouts` per Marvel `03-withdrawals.md` Phase C; frontend maps 400/422 codes | Marvel phases C–E; React wiring P2 |

## 8. Assets / uploads

| # | Remote function (evidence) | Backend disposition | Work item |
|---|---|---|---|
| AS-1 | `list()` (`assetRepository.ts:8,18`) | NEW `GET /v1/me/assets` | P4. Uploads to object store (dev volume, prod S3-compatible). |
| AS-2 | `add(kind, file)` — per-kind mime/duration validation, 507 quota (`:10,22,33` + `rules/assets.ts`) | NEW `POST /v1/me/assets` (multipart) | P4 |
| AS-3 | `remove(id)` (`:11,38`) | NEW `DELETE /v1/me/assets/{id}` | P4 |
| AS-4 | `url(id)` → serving URL (`:12,42`) | NEW `GET /v1/me/assets/{id}/url` (or signed URL) | P4 |
| AS-5 | Voice notes: data-URL inside `TipInput.voice.audio` → upload+stream URLs in prod (`services/audio/clips.ts:8-10`) | NEW upload endpoint for voice media (same assets pipeline) | P2 upload path, streaming P3 |

## 9. Realtime live channel (ws-gateway extension)

| # | Remote contract | Backend disposition | Work item |
|---|---|---|---|
| R-1 | `LiveFeed` interface: `connectChats(platforms)`, `subscribe(listener)`, `disconnect()`, `publish(ev)` (`services/realtime/liveFeed.ts:8-21`) | NEW duplex WS channel on ws-gateway (`/live`), auth `sk_`/Firebase (control room + caller tabs); overlay keeps `ok_`; NATS `live.*.<streamer_id>`; durable replay; client id-dedup honored | P3 |
| R-2 | `LiveEvent` union: message / donation / source / call / call-leave / viewers / follow (`models/entities/live.ts:190-198`) | Backend authors these events; duplicate-tolerant replay on subscribe (mock behavior `liveSimulator.ts:148,266`) | P2 donation+call; P3 rest |
| R-3 | Backend `publish()` consumers: web tips → creator control room + overlay; call state; viewer counts | ws-gateway projections similar to `donation.*` frames | P2/P3 |

## 10. Creator moderation & live commands (mock `liveStore` mutations → real endpoints)

Each verb below is today a client mutation (`models/stores/liveStore.ts:221-316`); production requires a tolkien endpoint + `live.*` fan-out to overlay/caller tabs:

| # | Verb | PROPOSED endpoint | Phase |
|---|---|---|---|
| M-1 | message approve / hide / takedown / restore | `POST /v1/me/live/messages/{id}/moderation` | P3 |
| M-2 | donation approve / reject | `POST /v1/me/donations/{id}/review` (`{"decision":"approve"|"reject"}`) + a review-queue read — **owner-acked 2026-10-18 (D-038, in scope P2)**; reject = replay-safe takedown of an already-aired donation, terminal | P2 |
| M-3 | call accept / hold / extend / end / decline | `POST /v1/me/live/calls/{id}/{action}` | P3 |
| M-4 | widget toggle / trigger | `POST /v1/me/live/widgets/{id}/{action}` | P3 |
| M-5 | marathon pause / lock / adjust | `POST /v1/me/live/marathon/{action}` | P3 |

Server-owned review state (D-038, owner-amended 2026-10-18): donations air **immediately** at charge — no 10s pre-air window (owner decision; the old `reviewEndsAt`/10s timer model below is superseded). The server records moderation flags at charge (`moderation.ts` port → `flag_reason` badge in the dashboard queue); the creator's reject is post-hoc takedown and approve is an idempotent confirm. Display duration stays the streamer's per-rupiah pricing (`display_duration_sec`). Superseded model kept for history: ~~`status: review|flagged|approved|rejected`, `reviewEndsAt`, `airedAt` (10s constants from `rules/moderation.ts` / `donationReview.ts`)~~.

## 11. Dispositions summary

- **Exists / extend (no new domain):** A-1 (`/v1/me`), E-1 (balance), E-2 (payouts, planned Marvel), S-2 (ingest intent).
- **NEW backend domains:** campaigns, widgets, themes, clips, assets, live sessions, live channel (ws-gateway), supporter identity, public routes (`/v1/public/*`).
- **Explicit no (with alternative):**
  - `demoRepository.reset()` — not served in `http` mode; replaced by real data + a dev-only reseed script.
  - QR code rendering — none needed; QR images are generated client-side (`rules/qrCode.ts`), only widget content persisted.
  - Layout drag/magnet/part-snap UX — client-side; server validates the saved layout only.
  - Platform OAuth + chat ingestion — deferred (P4 stubs); connections are records, chats are stubs, until provider work is scoped.
- **Client-side only (keep):** MediaRecorder voice capture (uploaded after), QR, editor interactions.

## 12. Contract-drift rows required before implementation (reviewer decision)

1. D-031: rich tip payload extends frozen ingest intent §4 (widgetId/quantity/tier/media/call). — **implemented + pushed 2026-10-18 (ingest, saruman 00010, React).**
2. D-032: ledger source tagging for earnings split (campaigns/clips/donations) — touches posting template §1. — **ACCEPTED (2026-10-18); design in flight this session.**
3. D-033: public `/v1/public/*` route family (unauthenticated reads: tip-session, creator page) + rate limiting + audit journal. — **implemented + pushed 2026-10-18 (tolkien).**
4. D-034: `payment_method` additions (`QRIS`, `VIRTUAL_ACCOUNT`, `EWALLET_*`) vs mock's card/apple-pay/google-pay/paypal — display + provider mapping. — **implemented + pushed 2026-10-18 (ingest edge 422, React methods).**
5. D-035: supporter identity (anonymous donors → optional USER identities).
6. D-036: full-array list responses at MVP (no cursor) — cursor only when repositories gain pagination.
7. D-038: donation review state ownership — **owner-acked 2026-10-18 with amended semantics (immediate airing, post-hoc takedown, decision API in P2); redesign in flight this session.** (Sibling D-039 registered: chat-message moderation authority, P3.)