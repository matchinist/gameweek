# Gameweek — Rearchitecture Phases & Tasks

**Status:** ready to execute · **Date:** 2026-08-28 · **Baseline:** `a06b055`
**Plan this implements:** [TARGET-ARCHITECTURE.md](./TARGET-ARCHITECTURE.md) (v2). Findings (C-n/H-n/M-n/L-n): [CODEBASE-ASSESSMENT.md](./CODEBASE-ASSESSMENT.md) §18.

Rules of engagement, applying to every phase:

- The repo stays shippable at every commit; live customers never notice a phase happening (P3).
- The embed contracts are frozen: classic iframe URLs, `embed.js` + the `inline=1` postMessage protocol (`height` / `scroll-top` / `viewport` / `sso`), and the SSO flow must behave identically before and after every task.
- Every database change is a committed migration (from Phase 1 on). Until then, ad-hoc SQL runs are pasted into the phase's migration file retroactively so the repo never lies about the schema again.
- Never cut over anything write-path on a matchday.

Dependencies: 0 → 1 → (2 → 3) → 4 → 5/6. Phase 1 does not need Phase 2's build system — that is deliberate, so the security work is never hostage to the refactor. Phase 4's query-scoping tasks (4.1–4.3) can be pulled earlier if load becomes painful.

---

## Phase 0 — Contain (~1 week)

Stop what is currently exploitable. No architecture change. Every item is independently revertible.

| # | Task | Closes |
|---|---|---|
| 0.1 | ☒ **Audit the live database.** In the SQL editor: `select * from pg_policies order by tablename, policyname` and RLS-enabled status for all **15** tables (the 13 assessed + `gw_leagues`, `gw_league_members`). Save the output to `docs/legacy/live-policies-2026-08.md`. Every later item is checked against this, not against assumptions. | C-5 |
| 0.2 | ☒ **Restrict `gw_dm_*` writes to platform admins.** Replace the `auth.uid() is not null` predicate on `gw_dm_teams` / `gw_dm_tournaments` / `gw_dm_events` (and add one for `gw_dm_players` if the audit shows it open) with `exists (select 1 from gw_admins a where a.auth_id = auth.uid())`, `USING` **and** `WITH CHECK`. Verify `/data` still saves for staff and `/admin`'s tournament picker still reads. | **C-2** |
| 0.3 | ☒ **Give the leagues tables committed RLS.** Enable RLS on `gw_leagues` / `gw_league_members`; policies: authenticated read scoped to the league's `client_key`; create/join/leave only as yourself (membership `username` must equal the caller's `gw_players.username` for that client); add `unique (league_id, username)`. Commit the SQL. | new (§11.4) |
| 0.4 | ☒ **Escape player-controlled HTML.** `${row.u}` at `embed:5288` (and the same leaderboard row in `demo/`); sweep every interpolation of `username`, league `code`, and operator-controlled `company_name` / `logo_url` through the existing escape helper. | **C-4** (sink) |
| 0.5 | ☒ **Username `CHECK` constraint.** `check (username ~ '^[A-Za-z0-9_]{1,24}$')` (match the client rule's charset; confirm the length bound against existing rows first — query for violations before adding). The DB, not the browser, becomes the arbiter. | C-4 (source) |
| 0.6 | ☒ **Deploy an allowlist, not the repo.** In `deploy.yml`, copy only intended-public files into a `_site/` staging dir and upload that: the app/marketing directories, `embed.js`, `robots.txt`, `sitemap.xml`, `favicon.png`, `og-image.png`, `CNAME`, `llms.txt`. This removes all five `.sql` files, `sso-test.html`, `docs/`, and `CLAUDE.md` from www.gameweek.cloud. Verify with `curl -I` after deploy. | M-2 |
| 0.7 | ☒ **Pin and integrity-check CDN scripts.** Pin `supabase-js` to an exact version in all 8 pages; add `integrity=` + `crossorigin` to supabase-js and `xlsx`; upgrade `xlsx` to ≥0.20.2 (advisories) and re-test the `/data` import flows. (Stripe's loader is unversioned by design — accept, note it.) | M-8, M-9 |
| 0.8 | ☒ **Delete the dead duplicate functions.** In `embed/index.html` the *earlier* copies are dead (hoisting — last wins): `renderPredictionsPane` @3116, `scorePoints` @3417, `renderEventCard` @3431. Diff dead vs live first to confirm nothing only-in-dead is wanted. Same for `admin` duplicate `getDM*` getters. Mirror in `demo/` if present. | H-1 |
| 0.9 | ☒ **Repo hygiene.** Add `.gitignore` (`.claude/`, `.serena/`, `.remember/`, `node_modules/`, `_site/`); remove the session-email `console.log`s (`admin:4171`, `data:2930`). | L-1, L-2 |
| 0.10 | ☒ **SSO origin check fails closed.** When `sso_enabled` but the operator has zero Allowed Domains, reject the SSO message instead of accepting any origin. Update [SSO.md](./SSO.md) §6/§10. | SSO.md §10 |
| 0.11 | ☒ **Confirm Stripe test mode is intentional** with the owner; document the answer. | H-5 |

**Exit:** a player token can write only its own predictions/membership; nothing player-reachable mutates global data; no secret-adjacent file is served publicly; the leaderboard cannot execute player HTML.
**Rollback:** every item is an isolated one-line revert (policy, header, or file).

---

## Phase 1 — Database integrity (~2 weeks)

The phase that makes the product's promise true. Pure SQL + small client edits; no build system required.

| # | Task |
|---|---|
| 1.1 | ☒ **Adopt Supabase CLI migrations.** `supabase init` + link; `supabase db pull` → committed baseline in `supabase/migrations/`. Move `supabase-migration.sql` (it **truncates** tables) and the applied one-off fix files to `docs/legacy/` with warning headers. From here, every schema change is a migration file. |
| 1.2 | ☒ **`kickoff_at timestamptz`.** Add to `gw_dm_events`; backfill from the text `kickoff` with a script that **reports unparseable rows** for manual fix before anything depends on it; `/data` writes both fields; embed/demo prefer `kickoff_at`. Keep the text column until 1.7 verifies parity, then plan its removal. (M-12) |
| 1.3 | ☒ **`save_prediction()` RPC** (TARGET-ARCHITECTURE §4.1): security definer; resolves the caller's player row; enforces `now() < kickoff_at - interval '30 minutes'` in the statement; sets `username` from `gw_players`; raises `locked` / `not_registered`. Test with the local-Postgres fixture approach proven by the PII fix (anon, authenticated, wrong-tenant, post-deadline, exactly-at-boundary cases). |
| 1.4 | ☒ **Client cutover.** `savePred()` → `supa.rpc('save_prediction', …)` with a friendly "locked" toast; deploy; watch for a few days of matchday traffic. |
| 1.5 | ☒ **Revoke direct writes**: `revoke insert, update on gw_predictions from anon, authenticated;` — after 1.4 is proven. A devtools `upsert` now gets `permission denied`. **This closes C-1.** Reverting is a single `grant`. |
| 1.6 | ☒ **Gate prediction reads** (H-6): replace `predictions_read USING (true)` with: own rows always; others' rows only once the event is locked (`now() >= kickoff_at - interval '30 minutes'`). Enumerate every read site in embed/widgets first and verify each works (leaderboards only score resulted events — always past lock). |
| 1.7 | ☒ **Kickoff sanity check:** compare `kickoff_at`-derived lock/round state against the legacy parser across all live rounds; fix divergences; then delete the "assume next year" fallback branch. |
| 1.8 | ☒ **Identity hardening** (H-7): trigger making `gw_players.client_key` immutable; restrict player self-update to profile columns; add `player_id` to `gw_league_members`, backfill via `(client_key, username)`, make code join/leave by `player_id` (keep `username` for display). |
| 1.9 | ☐ **Backups become real.** Confirm the Supabase backup schedule/retention; add a weekly `pg_dump` GitHub Action to private off-platform storage; run **one restore drill** into a local Postgres and note the runtime in the runbook. The hand-typed global sports DB is irreplaceable labour. |

**Exit:** there is no code path, from any client, that writes a late prediction or another identity's data; the repo's migrations replay to the live schema; a tested backup exists off-platform.
**Risk watch:** 1.2 backfill quality (report before trust); 1.5 timing (never on a matchday).

---

## Phase 2 — Foundations (~3 weeks)

Everything after this depends on a build, tests, and rollback. Deliberately zero behaviour change.

| # | Task |
|---|---|
| 2.1 | ☐ **Scaffold**: pnpm workspaces; `apps/embed·admin·data·widgets·marketing`; Vite per app with `allowJs`, no strict mode. Output paths/URLs stay identical. |
| 2.2 | ☐ **Extract `packages/theme`** (`gwLum`/`gwContrast`/`gwReadableText`/`gwApplySemantics`) unchanged, with unit tests — it is already good. |
| 2.3 | ☐ **Extract `packages/scoring`** from the *live* embed implementations (the post-0.8 survivors). **Tests first**: golden cases per mode (score/betting/ranking/lineup) captured from real rendered leaderboards, so extraction cannot silently change results. Target >90% coverage — this is the highest-value suite in the repo. |
| 2.4 | ☐ **Extract `packages/i18n`** (I18N + RULES_HTML, en·tr·de·pt) so a new language is one file. |
| 2.5 | ☐ **Kill the demo fork** (M-3): `demo` becomes `apps/embed` + a mock data adapter behind the same fetch interface. Deletes ~4,400 drifting lines. Do this last in the phase — it's the bulk and the least urgent. |
| 2.6 | ☐ **Cloudflare Pages**: project + build; PR preview deploys; custom-domain cutover for www.gameweek.cloud after visual parity checks; keep GitHub Pages warm until then; verify one-click rollback. Global security headers (`HSTS`, `X-Content-Type-Options`, `Referrer-Policy`) via `_headers`. |
| 2.7 | ☐ **CI gate** (blocks deploy): typecheck, `vitest`, build, duplicate-declaration check, forbidden-pattern grep (`console.log`, unescaped `${` on known user-string vars). |
| 2.8 | ☐ **Observability**: Sentry (free tier) in all four apps; a free uptime check hitting `/embed?client=demo`. |
| 2.9 | ☐ **Embed-contract regression tests** (Playwright): classic iframe renders; `inline=1` height handshake with a stub host page; SSO postMessage accepted from an allowed origin and rejected otherwise. These pin P3 (“never break the contract”) in CI forever. |

**Exit:** `pnpm test` green in CI; every PR gets a preview URL; production rolls back in one click; scoring engine tested; demo fork gone.
**Risk watch:** timebox to 3 weeks; if 2.5 threatens the box, ship without it and schedule it — everything else still lands.

---

## Phase 3 — Scoring & leaderboards (~2 weeks) — needs Phase 2

| # | Task |
|---|---|
| 3.1 | ☐ Migration: `gw_predictions.points int` (nullable = unscored); `gw_leaderboards` (`client_key`, `competition_id`, `round_id` nullable for overall, `player_id`, `username`, `points`, `updated_at`; unique on the scope + player). Public read policy (no PII beyond the display username); writes only via service role. |
| 3.2 | ☐ **`score-round` Edge Function**: verifies the caller is a platform admin (later: the competition's operator); loads the round's predictions + result; runs `packages/scoring`; writes `points`; upserts `gw_leaderboards` for round and overall scopes. Same deploy pipeline as `sso-login`. |
| 3.3 | ☐ Wire `/data`'s `saveResultTab()` to invoke it after a result save; add a "re-score round" button for corrections (idempotent by construction). |
| 3.4 | ☐ **Backfill**: script scores every historical resulted round through the same function. |
| 3.5 | ☐ **Shadow-compare, then cut over**: for one release, embed computes leaderboards client-side *and* fetches stored rows, reporting mismatches to Sentry; when clean, leaderboard tabs read only `gw_leaderboards`, paginated (`range()`), keyed by `player_id`. Per-event "you got 3 points" feedback stays client-side from the same scoring package. |

**Exit:** leaderboard render does zero scoring work and one paginated indexed read; a disputed score is explainable from stored data; a scoring-rule change no longer rewrites history.

---

## Phase 4 — Read path & per-tenant headers (~1–2 weeks)

| # | Task |
|---|---|
| 4.1 | ☐ **Tenant-scope the global reads** (H-2): fetch only events in this client's rounds (`.in('id', eventIds)` from `gw_rounds.event_ids`), plus the fixture/squad data a lineup competition's team needs; explicit column lists everywhere (`seasons` blob only for tournaments the client's coverage allows). Measure payload before/after on a real operator. |
| 4.2 | ☐ Replace `teamById` linear scan with a `Map` (kills the O(teams×events) main-thread scan). |
| 4.3 | ☐ **Parallelise init**: auth restore and data load run concurrently; drop the 3-second fallback wait. |
| 4.4 | ☐ **Per-tenant `frame-ancestors`** (H-3): a small Pages Function on `/embed` reads `client`, looks up `gw_operators_public.domains` (edge-cached ~60s), emits the CSP header; no domains configured → no restriction (documented default), domains configured → allowlist enforced. The admin UI's promise finally holds, and it backstops SSO origin-gating at the browser level. |
| 4.5 | ☐ Cache headers for widgets and static assets. |

**Exit:** a cold embed load transfers tenant-sized data (target: order-of-magnitude payload drop for a single-competition operator); an unlisted site cannot iframe an operator who configured domains.

---

## Phase 5 — Sports data feed (~4–5 weeks, business-gated)

Unchanged from v1 in substance. The largest business constraint is that every fixture and result is typed by hand.

| # | Task |
|---|---|
| 5.1 | ☐ Choose provider (API-Football / SportMonks — startup-priced); confirm coverage for the sports operators actually run (open question #3). |
| 5.2 | ☐ **Reconciliation UI first** in `/data`: map provider team/fixture IDs onto existing `gw_dm_*` rows; review-and-approve, not auto-overwrite; manual override stays forever. |
| 5.3 | ☐ Scheduled ingest via Supabase scheduled Edge Function / `pg_cron`: fixtures, kickoffs (`kickoff_at` native), results, lineups, scorers → each result triggers `score-round`. |
| 5.4 | ☐ **Operators enter results for their own competitions** (H-4): real UI in `/admin` guarded by an operator-ownership policy; delete the dead result modal and its `state.events` remnants. |

**Exit:** football results land and score without a human; onboarding an operator adds no data-entry load.

---

## Phase 6 — Surface quality (~3–4 weeks, parallelisable with 5)

| # | Task |
|---|---|
| 6.1 | ☐ Accessibility pass on embed (M-4): landmarks, labels, focus-trapped modals with Escape, keyboard-reachable interactive elements, `document.documentElement.lang = LANG`, `prefers-reduced-motion`, a non-colour channel for correct/incorrect, image dimensions + lazy loading. |
| 6.2 | ☐ GDPR (M-15): account deletion + data export (one small Edge Function each), consent timestamp + policy version at registration. |
| 6.3 | ☐ SEO (M-6, M-7, L-5): meta/OG/canonical on `/demo`; delete or `noindex` `/pricingtest`, `/cs2fantasy`, `/reset`; complete `sitemap.xml`. |
| 6.4 | ☐ Mode registry (assessment §10): one object per mode `{render, score, explain, rulesKey, adminConfig}`; delete the `lms`/`fantasy`/`matchups` render paths; translate `roulette` or drop it from the picker (L-4). |
| 6.5 | ☐ i18n polish: locale-aware date formatting; error-message audit; keep the 4-language parity check in CI. |

---

## Deferred (from TARGET-ARCHITECTURE §8 — do not start without the trigger)

Leave Supabase · Hono API tier · KV/edge caching · Queues · R2 · rate limiting beyond defaults · audit log · SOC 2 · multi-region · operator SAML. Each has its trigger and cost in the target doc.

---

## Progress log

| Date | Phase.Task | Note |
|---|---|---|
| 2026-08-28 | — | Document created at `a06b055`. Pre-work already done: C-3 closed in production (PII RLS fix); `gw_operators_public` live; username unique index shipped with SSO SQL. |
| 2026-08-28 | 0.9 | `.gitignore` added; both session-email `console.log`s removed. |
| 2026-08-28 | 0.8 | Dead copies deleted from `embed/` (~455 lines) and `admin/` (getDM* triple, byte-identical). `demo/` has no duplicates. Diff finding: the dead `renderPredictionsPane` dispatched `roulette` to `renderRouletteHTML()`; the live one does **not** — so roulette comps already render the generic pane in production. Relevant to 6.4 (translate roulette or drop it). Dead `renderEventCard` also had an "awaiting result" betting recap the live one dropped. All inline scripts pass `node --check` after excision. |
| 2026-08-29 | 1.5 | Migration `20260829223940_revoke_direct_prediction_writes.sql` live (owner cleared the soak — no matchday concerns). `revoke insert, update on gw_predictions from anon, authenticated`; DELETE grant kept (admin cleanup, still RLS-bound); the security-definer RPC is unaffected by grants. Tests first: 7-assert suite (grant-level denial for both roles, RPC still writes, DELETE kept, INSERT/UPDATE gone) + full regression suite green. **Live-verified with a real player session: devtools-style direct upsert → `permission denied`; `savePred()` via RPC saved 3-1 fine; anon direct insert → 42501. C-1 CLOSED** — there is no client-reachable path that writes a late or spoofed prediction. Rollback remains a single `grant`. |
| 2026-08-29 | 1.6 | Migration `20260829223104_prediction_read_gate.sql` live. `predictions_read` now: own rows always (via a **security-definer helper** `gw_is_own_player()` — anon has no grant on `gw_players` since the PII fix, and a bare policy subquery on it failed every anon SELECT; the fixture caught this before live did); others' event-keyed rows only once locked (`now() ≥ kickoff_at − 30min`, null = not locked); **carve-out:** round-keyed rows (lineup/ranking — no `gw_dm_events` row; the round→event link lives in the seasons JSON blob so no SQL-reachable lock time) stay world-readable until Phase 3 stores leaderboards server-side. Tests first (2-persona visibility matrix incl. anon), full suite re-run green (identity test's chain-split guard fixed). Live-verified: anon can no longer read TesterPSFAI's unlocked pick (`[]`), locked + `_ranking` rows still served, owner sees own unlocked pick in round queries. No client change needed — reads just filter. |
| 2026-08-29 | 1.8 | Migration `20260829222701_identity_hardening.sql`: trigger freezes `gw_players` id/auth_id/client_key/username (email stays editable; service_role bypass for future account tooling) — no client code updates `gw_players` at all, so the old permissive update policy was pure attack surface. `gw_league_members.player_id` added (FK, cascade), backfilled via (league client_key, username) — legacy no-match rows stay as display-only ghosts (loud NOTICE); partial unique on (league_id, player_id); join/leave policies now require the caller's OWN player_id AND matching username (display spoofing closed; the no-player_id insert path closed). Embed joins/leaves/queries by `player_id` (username kept for display). Tests first: 15-case suite green (backfill, ghost survival, immutability incl. service-role bypass, all join/leave spoof paths). Deploy order: client first (old policy tolerates the extra column), then `db push`. Fixture-fidelity fix: test preamble now grants API roles usage on schema auth, matching real Supabase. |
| 2026-08-29 | 1.4 | Both embed write sites (savePred + post-login flush) cut over to `save_prediction()`; locked → translated "Predictions locked" toast (existing key). Deployed (owner cleared the window) and **E2E-verified on production**: TesterPSFAI saved 2-1 on an open Chelsea–Brighton through the deployed RPC path; row landed with server-resolved username. Embed has zero remaining direct `gw_predictions` writes. 1.5 held for a short soak: pre-deploy tabs still run direct-upsert code and would break on revoke. Also noted: `admin`'s comp-delete DELETE on predictions already matches 0 rows (no DELETE policy exists) — pre-existing orphan behaviour, untouched. |
| 2026-08-29 | 1.7 | Parity gate `scripts/kickoff-backfill/parity-check.mjs` across 5 viewer timezones: 1,823 rows identical everywhere; 431 zoneless rows divergent (max 11h — Sydney reading) but **permanently boundary-safe** (both readings' kickoff+3h lie in the past, so no lock or round predicate can ever differ again; the gate initially flagged two Aug-27 events under a blanket 48h margin — replaced with the exact predicate, which proves them safe). Year-inference fallback branch deleted from embed `parseKickoffMs` (unreachable: kickoffRaw always ISO/timestamptz now; display-string fallback only ever received 'TBD'). `demo/` keeps its copy deliberately — its hardcoded data uses the "D Mon HH:MM" format. Kickoff unit tests still 17/17. |
| 2026-08-29 | 1.3 | Migration `20260829221400_save_prediction_rpc.sql` pushed live. Security definer; EXECUTE only for `authenticated` (live anon probe → `permission denied`); resolves the caller's player row per tenant (`not_registered`); deadline `now() >= kickoff_at − 30min` → `locked` (inclusive boundary); username copied from `gw_players` — no username parameter exists; upsert on the client's exact conflict key. **Design note:** an `event_id` with no `gw_dm_events` row is NOT locked, because lineup/ranking modes store the round id in `event_id` — rejecting unknowns would break both modes. Tests first: `scripts/migrations/save-prediction.test.sh`, 12 asserts (anon/no-player/wrong-tenant/open/10-min/boundary/no-kickoff/username-source/upsert/locked-update) — all green; full chain replay + kickoff tests still green. Nothing calls the RPC yet — 1.4 is the cutover, **not before Monday** (matchday rule). Side-find for 1.8: `gw_players.email` is NOT NULL live, but `ensureSsoPlayer` can pass a null email (invalid host email) — that insert path would fail today. |
| 2026-08-29 | 1.2 | Migration `20260829220710_add_kickoff_at.sql` pushed live via `db push`: adds `kickoff_at timestamptz` + index, backfills all four census formats timezone-explicitly (zoneless → Europe/London per review — all past events; date-only → UTC midnight, matching current client behaviour — all future), and RAISEs on unparseable rows instead of silently nulling. Tests first: `scripts/migrations/kickoff-backfill.test.sh` (10 asserts incl. BST/GMT and the raise path, session TZ deliberately America/New_York) — SQL agrees with the JS parser everywhere. Live verified: 2,254/2,254 backfilled, 0 left behind, Oct-BST row → 19:00Z. Clients: `/data` loads/carries `kickoff_at` and writes both fields at every save site (bulk save preserves backfilled values on untouched rows — the clobber risk); embed prefers `kickoff_at` over the text column (2 sites: EVENTS build + legacy single-event rounds). Browser-verified against live: 2,254/2,254 events using timestamptz, 10 cards, zero console errors. `demo/` untouched (hardcoded data, no Supabase). Text column stays until 1.7. |
| 2026-08-29 | 1.1 | CLI linked to `mgfzqkesikfdrahherfm`; `db pull` baseline committed as `supabase/migrations/20260829220021_remote_schema.sql` (15 tables, 37 policies — includes all Phase 0 work; remote migration history repaired to applied). Test written FIRST: `scripts/migrations/replay-test.sh` replays the chain into clean Postgres 17 + a minimal platform preamble (roles, `auth.uid()`, `auth.users`, `storage.objects`) — green. Index-advisor extensions (`hypopg`/`index_advisor`) guarded to skip where unavailable (dashboard tooling, not app schema). All 6 pre-CLI SQL files moved to `docs/legacy/` with DO-NOT-RUN headers; CLAUDE.md + SSO.md references updated. Baseline also revealed live has an `rls_auto_enable` event trigger (auto-enables RLS on new tables). Work is also tracked on the GameWeek Rearchitecture Trello board from here on; this log stays the detailed record. |
| 2026-08-28 | Phase 0 shipped | Owner's two smoke tests passed (`/data` staff save; manual registration). Merged to `main` (`10e4fe0`, branch kept for later phases) and deployed. Post-deploy verification: all 9 excluded paths 404 (all `.sql`, `sso-test.html`, `CLAUDE.md`, `docs/`, `supabase/` — **0.6's post-merge TODO done, M-2 closed**); all 20 public paths 200; SRI-pinned supabase-js loads on production; embed renders with a restored player session and zero console errors. One transient blank render observed in the first ~2 min after deploy (CDN propagation) — resolved itself, not reproducible locally or after. |
| 2026-08-28 | 0.2/0.3/0.5 → ☒ | Owner ran `supabase-phase0-contain.sql` against live. Verified live afterwards: **anon REST probes** — `gw_dm_teams`/`gw_dm_players` inserts → 401 RLS violation, `gw_dm_players` update touches 0 rows (target row confirmed untouched), `gw_dm_*` reads still 200; `gw_leagues`/`gw_league_members` anon reads now `[]` (were world-readable), anon inserts → 401. **Signed-in player on production** (old client code, leaguefooty test client): create league → "League created!", open it (league+member reads OK), leave → "You left the league". C-2 closed. Remaining smoke tests, low risk: a `/data` staff save on next use (same admin EXISTS predicate `dm_teams` already used live), and one manual registration. Leftover: empty league row "Phase0 Test League" in `gw_leagues` (memberless, invisible in UI, no delete path by design). |
| 2026-08-28 | 0.11 | Owner confirmed 2026-08-28: Stripe test mode is **intentional** — billing is not live yet. H-5 closed in the assessment; swap to the live publishable key + live pricing table when charging starts. |
| 2026-08-28 | 0.2/0.3/0.5 | ◐ = SQL authored in `supabase-phase0-contain.sql` and green against a local Postgres 16 fixture (26-case adversarial matrix: anon/player/wrong-tenant/admin across dm writes, league create/join/leave scoping, username check) — **awaiting the manual SQL-editor run against live**, then flip to ☒. 0.5's client half shipped in the same commit: registration max-24 (validation + `maxlength` + `errUsernameLong` ×4 langs) and SSO dedup suffix-aware slicing so `base+suffix` ≤ 24. Run 0.5's violations query before the ALTER. Note: the 0.1 audit lacks RLS-*enabled* status (only `pg_policies`); the SQL file's pre-flight query covers it and each section enables RLS idempotently. |
| 2026-08-28 | 0.6 | `deploy.yml` now stages an explicit allowlist into `_site/` (13 dirs + 8 root files = 23 files on dry-run) and uploads that. Dry-run locally verified: no `.sql`, `sso-test.html`, `docs/`, `CLAUDE.md`, or `supabase/` staged. **Post-merge TODO:** after this branch deploys to main, `curl -I https://www.gameweek.cloud/supabase-migration.sql` (and the other excluded paths) must return 404. |
| 2026-08-28 | 0.7 | supabase-js pinned to `2.112.4` (UMD) with `integrity` + `crossorigin` on all **9** pages (the assessment said 8; `reset-password/` was the ninth, previously loading the bare `@2` default entry). `xlsx` 0.18.5→0.20.3: npm stopped at 0.18.5, so it now loads from SheetJS's own CDN (`cdn.sheetjs.com`) with SRI. Headless round-trip test of every XLSX API `/data` calls (read/sheet_to_json/aoa_to_sheet/book_new/book_append_sheet) passes on 0.20.3; full in-browser import re-test still worth doing on next `/data` use. Stripe's unversioned loader accepted as designed (their TOS requires the evergreen URL). |
| 2026-08-28 | 0.10 | `ssoOriginAllowed()` now returns `false` when the operator has zero Allowed Domains (was: accept-any with a warning). SSO.md §6 rewritten as fail-closed, §10 limitation removed, §9 troubleshooting row added. Note for the lokkaroom rollout: that operator must have its domain configured before SSO will work. |
| 2026-08-28 | 0.4 | Escaped in `embed/`: leaderboard `${row.u}`; profile username/initials/email; league `code`/`id` moved out of inline `onclick` strings into `data-*`; `selectLeague` inline-JSON now `&`-escapes before `'`; operator `logo_url`/`company_name` escaped in both the pre-paint localStorage block (local escaper — block must stay dependency-free) and the post-fetch render. `escapeHtmlLineup` extended to escape quotes for attribute contexts. Mirrored in `demo/` (helper added + both `${row.u}` rows). `toast()` and the header username already use `textContent` — safe. League member lists are only used as filter Sets, never rendered. |
| 2026-08-28 | 0.1 | Live `pg_policies` dump saved to `docs/legacy/live-policies-2026-08.md`. Notable: the three `gw_dm_*` write policies are **already** admin-gated live (implicit WITH CHECK via USING); `gw_dm_players` is wide open (`ALL true/true`); `gw_leagues`/`gw_league_members` writes are `ALL true`. |
