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
| 0.2 | ☐ **Restrict `gw_dm_*` writes to platform admins.** Replace the `auth.uid() is not null` predicate on `gw_dm_teams` / `gw_dm_tournaments` / `gw_dm_events` (and add one for `gw_dm_players` if the audit shows it open) with `exists (select 1 from gw_admins a where a.auth_id = auth.uid())`, `USING` **and** `WITH CHECK`. Verify `/data` still saves for staff and `/admin`'s tournament picker still reads. | **C-2** |
| 0.3 | ☐ **Give the leagues tables committed RLS.** Enable RLS on `gw_leagues` / `gw_league_members`; policies: authenticated read scoped to the league's `client_key`; create/join/leave only as yourself (membership `username` must equal the caller's `gw_players.username` for that client); add `unique (league_id, username)`. Commit the SQL. | new (§11.4) |
| 0.4 | ☒ **Escape player-controlled HTML.** `${row.u}` at `embed:5288` (and the same leaderboard row in `demo/`); sweep every interpolation of `username`, league `code`, and operator-controlled `company_name` / `logo_url` through the existing escape helper. | **C-4** (sink) |
| 0.5 | ☐ **Username `CHECK` constraint.** `check (username ~ '^[A-Za-z0-9_]{1,24}$')` (match the client rule's charset; confirm the length bound against existing rows first — query for violations before adding). The DB, not the browser, becomes the arbiter. | C-4 (source) |
| 0.6 | ☐ **Deploy an allowlist, not the repo.** In `deploy.yml`, copy only intended-public files into a `_site/` staging dir and upload that: the app/marketing directories, `embed.js`, `robots.txt`, `sitemap.xml`, `favicon.png`, `og-image.png`, `CNAME`, `llms.txt`. This removes all five `.sql` files, `sso-test.html`, `docs/`, and `CLAUDE.md` from www.gameweek.cloud. Verify with `curl -I` after deploy. | M-2 |
| 0.7 | ☒ **Pin and integrity-check CDN scripts.** Pin `supabase-js` to an exact version in all 8 pages; add `integrity=` + `crossorigin` to supabase-js and `xlsx`; upgrade `xlsx` to ≥0.20.2 (advisories) and re-test the `/data` import flows. (Stripe's loader is unversioned by design — accept, note it.) | M-8, M-9 |
| 0.8 | ☒ **Delete the dead duplicate functions.** In `embed/index.html` the *earlier* copies are dead (hoisting — last wins): `renderPredictionsPane` @3116, `scorePoints` @3417, `renderEventCard` @3431. Diff dead vs live first to confirm nothing only-in-dead is wanted. Same for `admin` duplicate `getDM*` getters. Mirror in `demo/` if present. | H-1 |
| 0.9 | ☒ **Repo hygiene.** Add `.gitignore` (`.claude/`, `.serena/`, `.remember/`, `node_modules/`, `_site/`); remove the session-email `console.log`s (`admin:4171`, `data:2930`). | L-1, L-2 |
| 0.10 | ☒ **SSO origin check fails closed.** When `sso_enabled` but the operator has zero Allowed Domains, reject the SSO message instead of accepting any origin. Update [SSO.md](./SSO.md) §6/§10. | SSO.md §10 |
| 0.11 | ☐ **Confirm Stripe test mode is intentional** with the owner; document the answer. | H-5 |

**Exit:** a player token can write only its own predictions/membership; nothing player-reachable mutates global data; no secret-adjacent file is served publicly; the leaderboard cannot execute player HTML.
**Rollback:** every item is an isolated one-line revert (policy, header, or file).

---

## Phase 1 — Database integrity (~2 weeks)

The phase that makes the product's promise true. Pure SQL + small client edits; no build system required.

| # | Task |
|---|---|
| 1.1 | ☐ **Adopt Supabase CLI migrations.** `supabase init` + link; `supabase db pull` → committed baseline in `supabase/migrations/`. Move `supabase-migration.sql` (it **truncates** tables) and the applied one-off fix files to `docs/legacy/` with warning headers. From here, every schema change is a migration file. |
| 1.2 | ☐ **`kickoff_at timestamptz`.** Add to `gw_dm_events`; backfill from the text `kickoff` with a script that **reports unparseable rows** for manual fix before anything depends on it; `/data` writes both fields; embed/demo prefer `kickoff_at`. Keep the text column until 1.7 verifies parity, then plan its removal. (M-12) |
| 1.3 | ☐ **`save_prediction()` RPC** (TARGET-ARCHITECTURE §4.1): security definer; resolves the caller's player row; enforces `now() < kickoff_at - interval '30 minutes'` in the statement; sets `username` from `gw_players`; raises `locked` / `not_registered`. Test with the local-Postgres fixture approach proven by the PII fix (anon, authenticated, wrong-tenant, post-deadline, exactly-at-boundary cases). |
| 1.4 | ☐ **Client cutover.** `savePred()` → `supa.rpc('save_prediction', …)` with a friendly "locked" toast; deploy; watch for a few days of matchday traffic. |
| 1.5 | ☐ **Revoke direct writes**: `revoke insert, update on gw_predictions from anon, authenticated;` — after 1.4 is proven. A devtools `upsert` now gets `permission denied`. **This closes C-1.** Reverting is a single `grant`. |
| 1.6 | ☐ **Gate prediction reads** (H-6): replace `predictions_read USING (true)` with: own rows always; others' rows only once the event is locked (`now() >= kickoff_at - interval '30 minutes'`). Enumerate every read site in embed/widgets first and verify each works (leaderboards only score resulted events — always past lock). |
| 1.7 | ☐ **Kickoff sanity check:** compare `kickoff_at`-derived lock/round state against the legacy parser across all live rounds; fix divergences; then delete the "assume next year" fallback branch. |
| 1.8 | ☐ **Identity hardening** (H-7): trigger making `gw_players.client_key` immutable; restrict player self-update to profile columns; add `player_id` to `gw_league_members`, backfill via `(client_key, username)`, make code join/leave by `player_id` (keep `username` for display). |
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
| 2026-08-28 | 0.7 | supabase-js pinned to `2.112.4` (UMD) with `integrity` + `crossorigin` on all **9** pages (the assessment said 8; `reset-password/` was the ninth, previously loading the bare `@2` default entry). `xlsx` 0.18.5→0.20.3: npm stopped at 0.18.5, so it now loads from SheetJS's own CDN (`cdn.sheetjs.com`) with SRI. Headless round-trip test of every XLSX API `/data` calls (read/sheet_to_json/aoa_to_sheet/book_new/book_append_sheet) passes on 0.20.3; full in-browser import re-test still worth doing on next `/data` use. Stripe's unversioned loader accepted as designed (their TOS requires the evergreen URL). |
| 2026-08-28 | 0.10 | `ssoOriginAllowed()` now returns `false` when the operator has zero Allowed Domains (was: accept-any with a warning). SSO.md §6 rewritten as fail-closed, §10 limitation removed, §9 troubleshooting row added. Note for the lokkaroom rollout: that operator must have its domain configured before SSO will work. |
| 2026-08-28 | 0.4 | Escaped in `embed/`: leaderboard `${row.u}`; profile username/initials/email; league `code`/`id` moved out of inline `onclick` strings into `data-*`; `selectLeague` inline-JSON now `&`-escapes before `'`; operator `logo_url`/`company_name` escaped in both the pre-paint localStorage block (local escaper — block must stay dependency-free) and the post-fetch render. `escapeHtmlLineup` extended to escape quotes for attribute contexts. Mirrored in `demo/` (helper added + both `${row.u}` rows). `toast()` and the header username already use `textContent` — safe. League member lists are only used as filter Sets, never rendered. |
| 2026-08-28 | 0.1 | Live `pg_policies` dump saved to `docs/legacy/live-policies-2026-08.md`. Notable: the three `gw_dm_*` write policies are **already** admin-gated live (implicit WITH CHECK via USING); `gw_dm_players` is wide open (`ALL true/true`); `gw_leagues`/`gw_league_members` writes are `ALL true`. |
