# Database Schema Review — 2026-08-31

**Scope:** the live Supabase Postgres (project `mgfzqkesikfdrahherfm`, Postgres 17) — every
`public` table, key, index, policy, function and scheduled job, reviewed against the goal of
supporting a high volume of operators (tenants), players and traffic.

**Method:** all facts below were pulled from the running database on 2026-08-31
(`pg_stat_user_tables`, `pg_constraint`, `pg_stat_user_indexes`, `pg_policies`,
`information_schema.columns`, `pg_proc`, `cron.job`), not from the migration files. Index *scan
counts* are production usage since last stats reset — they show what the workload actually does.

**Context that shapes every recommendation:** RLS is the only security boundary (anon key is
public by design); the embed is the hot path (every player pageview); admin surfaces are
low-traffic; `save_prediction` (SECURITY DEFINER RPC) is the only prediction write path;
server-side scoring (`score-round`) and the provider feed (`data-ingest`) write with the service
role. Today's data is tiny (largest table 1.9 MB / 2,276 rows) — nothing is slow *yet*; this
review is about what breaks first as volume grows, and in what order to fix it.

---

## 1. Current state inventory

### 1.1 Tables (live sizes and row counts)

| Table | Rows | Total size | Purpose / layer |
|---|---|---|---|
| gw_dm_events | 2,276 | 1,920 kB | global fixtures (shared across all tenants) |
| gw_dm_teams | 230 | 416 kB | global teams |
| gw_dm_tournaments | 20 | 312 kB | global tournaments — **`seasons` jsonb megablob** |
| gw_dm_players | 771 | 192 kB | global squads |
| gw_predictions | 145 | 160 kB | tenant: player picks (+ `points` since 3.1) |
| gw_rounds | 107 | 160 kB | tenant: rounds (`event_ids text[]`) |
| gw_operators | 34 | 112 kB | tenant root (branding, domains, sso_secret) |
| gw_league_members / gw_players / gw_leaderboards | 2 / 47 / 84 | ≤96 kB | tenant |
| gw_ingest_runs / gw_competitions / gw_leagues | 61 / 42 / 3 | ≤88 kB | audit / tenant |
| gw_score_runs / gw_campaigns / gw_providers / gw_subscriptions / gw_client_coverage | ≤10 each | ≤48 kB | audit / config |

### 1.2 Keys

- **Primary keys:** every table has one. `gw_predictions`, `gw_leaderboards`, audit tables use
  `uuid`; **all domain tables use client-generated `text` ids** (`ev…`, `tm…`, `c…`, `r…`).
- **Foreign keys: 9 in total.** Present: `gw_admins/gw_operators/gw_players → auth.users`,
  `gw_dm_players → gw_dm_teams`, `gw_league_members → gw_leagues/gw_players`,
  `gw_predictions → gw_players`, `gw_rounds → gw_competitions`, `gw_subscriptions → gw_operators`.
- **Absent (the big gap):** `gw_competitions → gw_operators`, `gw_predictions →
  gw_competitions/gw_rounds`, `gw_leaderboards → anything`, `gw_dm_events → gw_dm_teams`,
  `gw_leagues → gw_operators`, `gw_campaigns/gw_client_coverage → gw_operators`, and no
  integrity at all on `gw_rounds.event_ids text[]` (array of event ids — unenforceable by FK).
- **Unique constraints:** sound where they exist — `gw_players (client_key, username)`,
  `gw_predictions (player_id, competition_id, event_id)`, `gw_leaderboards` scope+player
  (NULLS NOT DISTINCT), `gw_operators (client_key)`, `(email)`.
- **CHECK constraints: none anywhere.** Nothing stops negative points, empty client_keys,
  malformed status strings, or a `prediction` jsonb of arbitrary shape at the SQL layer.

### 1.3 Indexes (with real usage)

Hot (production scan counts): `gw_dm_events_pkey` **652,793**, `gw_dm_teams_pkey` 97,200,
`gw_dm_tournaments_pkey` 11,057, `gw_operators_client_key_key` 6,155, `gw_players_pkey` 3,363,
`gw_rounds_client_idx` 2,951, `gw_competitions_client_idx` 1,851, `gw_predictions_comp_idx` 1,118.

Problems found:

- **Duplicate indexes (pure waste, double write cost):**
  - `gw_players_unique_username` **and** `gw_players_client_username_uidx` — two identical
    `(client_key, username)` uniques.
  - `gw_league_members_pkey` **and** `gw_league_members_league_username_key` — two identical
    `(league_id, username)` btrees.
- **Unused:** `gw_league_members_league_player_key` (0 scans), `gw_leaderboards_pkey` (0 scans —
  fine, upserts go through the scope unique), `gw_dm_events_client_idx` /
  `gw_dm_teams_client_idx` / `gw_dm_tournaments_client_idx` — near-zero scans on **legacy
  `client_key` columns that global tables should no longer have at all** (pre-global-layer
  remnants).
- **Missing for current query shapes:** no index supports `provider_ids->'sportmonks'` lookups
  (data-ingest and mapping run them; sequential scan today, fine at 2k rows, not at 500k); no
  partial index for the ingest hot filter (`status != 'completed'` + kickoff window).

### 1.4 RLS policies (42)

Structure is coherent (post-Phase-1 hardening): public read on game-visible tables
(`competitions`, `rounds`, `leaderboards`, `campaigns`, dm_* reads), self-or-operator scoped
player data, admin-only audit/provider tables, INSERT-only prediction path behind the
`save_prediction` RPC (direct writes grant-revoked). Weaknesses are about *performance shape*,
not access logic — detailed in findings 2.4–2.6.

### 1.5 Functions & jobs

`save_prediction` (SECURITY DEFINER, deadline enforced by DB time), `gw_is_own_player`
(SECURITY DEFINER helper used per-row in the prediction read policy), `gw_players_identity_guard`
trigger, `rls_auto_enable`, legacy `resolve_question`. Scheduled: pg_cron `data-ingest` every
5 minutes; `cron.job_run_details` at 303 rows and `net._http_response` at 72 (both need
retention, see 2.10).

---

## 2. Findings

Severity: **CRITICAL** = will corrupt data or break tenants at scale; **HIGH** = measurable
scale/security ceiling; **MEDIUM** = cost/robustness debt; **LOW** = hygiene.

### 2.1 CRITICAL — No referential integrity across the tenant data chain

`gw_predictions.competition_id/round_id/event_id`, `gw_leaderboards.*`,
`gw_competitions.client_key`, `gw_leagues.client_key` are free-floating text. Nothing in the
database prevents: predictions referencing deleted rounds, leaderboards for competitions that no
longer exist, competitions belonging to no operator. Today the app happens to keep these
consistent; at high volume with concurrent admin edits, feed imports and a scoring worker, silent
orphaning is a *when*, not an *if* — and every orphan is a support ticket about "wrong points."

**Do:** add FKs where the referenced key exists and text ids are stable:
`gw_competitions.client_key → gw_operators(client_key)` (ON DELETE CASCADE),
`gw_rounds.client_key` likewise, `gw_predictions.competition_id → gw_competitions(id)`,
`gw_leagues/gw_campaigns/gw_client_coverage/gw_leaderboards(client_key) → gw_operators`,
`gw_dm_events.home_id/away_id → gw_dm_teams(id)` (RESTRICT — a team in use must not vanish).
Each FK column needs its own index (most already exist). Validate with `NOT VALID` +
`VALIDATE CONSTRAINT` so the additions never lock hot tables.
`gw_rounds.event_ids text[]` cannot be FK-enforced — that is a *data-model* debt: the junction
belongs in a `gw_round_events (round_id, event_id, sort)` table (fits naturally into the Phase-4
tenant-scoping work, since it also unlocks "which rounds use this event" without array scans).

### 2.2 CRITICAL — The `seasons` jsonb megablob is a concurrency and scale trap

`gw_dm_tournaments.seasons` holds team lists, **round structures**, and **standings** for every
season of a tournament in one jsonb value (avg 1.5 kB, max 13.9 kB already, grows unbounded with
every round). Three writers now exist: admin bulk `save()` (read-modify-write of the whole blob),
the standings sync in `/data`, and the `data-ingest` worker. **Last-writer-wins on the entire
blob**: an admin saving while the worker refreshes standings silently reverts one or the other.
No row versioning exists to even detect it. It is also unqueryable (embed downloads all
tournaments' full blobs to find one season's rounds) and rewrites the full TOAST value on every
touch (write amplification + bloat).

**Do (phased):**
1. *Now:* stop worker/admin clobbering — give `gw_dm_tournaments` a `version int` bumped on
   write, and make the worker update standings with `... where id=$1 and version=$2` retrying on
   conflict; or move worker-owned standings out of the blob first (next point).
2. *Structural:* promote the blob's three concerns into real tables —
   `gw_dm_seasons (tournament_id, key, …)`, `gw_dm_season_teams`, `gw_dm_season_rounds`
   (or reuse the `gw_round_events` junction), and `gw_dm_standings (tournament_id, season_key,
   rank, team_id, played, w, d, l, gf, ga, pts, zone, updated_at)` — which also unlocks the
   "standings per round" history the product wants. This is the single highest-leverage
   data-model change in the schema.

### 2.3 HIGH — Text primary keys: the real issue is generation, not the type

Text ids per se are defensible here (they are URL/API surface — `?comp=c123` — and Postgres
btrees handle short text keys fine). The actual problems:
1. **Client-generated randomness** (`'ev'+Math.random()`-style): no collision guarantee, no
   generation authority, and any browser session with write access can mint ids of any shape.
2. **Unbounded `text`** with no format constraint — nothing rejects a 2 MB id or a `'; --` id
   (parameterised queries protect against injection, but garbage keys propagate everywhere).
3. **Fat composite indexes:** every tenant index leads with `client_key text` (~10–20 bytes per
   row per index). At 10M predictions × 5 indexes this is real memory pressure vs. an int/uuid.

**Do:** keep text ids for the public API surface (churning them breaks embeds), but (a) add
CHECK format constraints (`id ~ '^[a-z0-9_]{2,40}$'` per table, `client_key ~ …`), (b) generate
new ids server-side where a server path exists (RPC/worker already do), (c) when the Phase-4/5
load work lands, introduce an internal `bigint identity` surrogate on the highest-churn tables
(`gw_predictions`, `gw_leaderboards`) and point the *internal* indexes/FKs at it, keeping text
keys as unique lookup columns only.

### 2.4 HIGH — RLS policies re-evaluate per row (`auth_rls_initplan`)

Almost every policy calls `auth.uid()` or a subquery **naked**, e.g.
`comps_write_own: auth.uid() = (SELECT … WHERE client_key = gw_competitions.client_key)` and
`dm_*_write: EXISTS (SELECT 1 FROM gw_admins WHERE auth_id = auth.uid())`. Postgres evaluates
these per row unless the stable parts are wrapped as `(SELECT auth.uid())` (initplan, cached per
statement). Worse, `predictions_read` calls the SECURITY DEFINER function
`gw_is_own_player(player_id)` **and** a `NOT EXISTS` on `gw_dm_events` *per prediction row* —
today's leaderboard reads scan 145 rows, a real tenant's will scan tens of thousands.

**Do:** rewrite every policy with `(SELECT auth.uid())`; replace the per-row function call in
`predictions_read` with a join-friendly form (`player_id IN (SELECT id FROM gw_players WHERE
auth_id = (SELECT auth.uid()))`); after the 3.5 leaderboard cutover, *narrow* the prediction read
policy drastically (public reads move to `gw_leaderboards`, so others' prediction rows only need
exposure for the prediction-history popup — or an RPC).

### 2.5 HIGH — Multiple permissive policies on hot tables (`multiple_permissive_policies`)

`gw_operators` (2× SELECT, 2× UPDATE) and `gw_players` (2× SELECT) run **every** policy for
every query of that verb — double subquery cost on two of the most-queried tables
(`gw_operators_client_key_key`: 6,155 scans). **Do:** merge each pair into one policy with `OR`.

### 2.6 HIGH — Every visitor downloads the whole global layer (known: H-2, Phase 4.1)

The embed pulls `gw_dm_events` (limit 10,000), all teams and all tournaments *per pageview*,
because global tables have blanket `SELECT true` policies and no tenant scoping. This is the #1
bandwidth/latency ceiling and it grows linearly with *platform* size, not tenant size — at 50k
events every player of every tenant downloads 50k rows. Confirmed by index stats: 652k pkey
scans on `gw_dm_events`. **Do:** the already-planned Phase 4.1 (fetch only events referenced by
this client's rounds, explicit column lists) plus a `gw_round_events` junction (2.1) makes that
query indexable server-side. Add API-level guardrails too: PostgREST `db-max-rows`, and
`statement_timeout` for the `anon`/`authenticated` roles.

### 2.7 MEDIUM — Bulk `save()` rewrites entire tables

`/data`'s save upserts **all 230 teams / 20 tournaments / 2,276 events** on any change; admin
saves in the operator panel behave similarly (`saveAdminState()`). Beyond write amplification,
concurrent admins clobber each other (same pattern as 2.2, table-wide). **Do:** move surfaces to
narrow updates progressively (the codebase already has the pattern: `saveEventFields`,
`saveTeamEdit` could diff); add `updated_at` triggers so clobbers are at least detectable and
ordered.

### 2.8 MEDIUM — Denormalized `username` as an identity key

`gw_predictions.username` duplicates `gw_players.username`; `gw_league_members` is *keyed* by
`(league_id, username)` with `player_id` merely along for the ride. A username rename desyncs
history, league membership and leaderboards. **Do:** after the 3.5 cutover (leaderboards keyed
by `player_id` — already the case in `gw_leaderboards`), flip league membership PK to
`(league_id, player_id)`, keep `username` as display-only, and stop writing it into predictions
(derive at read time).

### 2.9 MEDIUM — Secrets and PII placement

- `gw_providers.token` is plaintext in a table (admin-RLS'd, service-readable). Acceptable
  posture for now and a deliberate UX choice, but at higher stakes move it to **Supabase Vault**
  (`vault.secrets`) and keep only a reference in `gw_providers`.
- `gw_operators.sso_secret` sits next to branding fields read by the operator panel — same
  Vault candidate.
- Audit tables store admin emails (`initiated_by`) — fine (admin-only read), but add that to the
  GDPR deletion story (Phase 6.2).

### 2.10 MEDIUM — Unbounded growth tables with no retention

`gw_score_runs` and `gw_ingest_runs` grow forever (every result save × every scope; every feed
iteration). `cron.job_run_details` (303 rows in hours) and `net._http_response` grow with every
cron tick. **Do:** one pg_cron purge job: delete audit rows older than 90 days,
`cron.job_run_details`/`net._http_response` older than 7 days.

### 2.11 MEDIUM — No capacity plan for `gw_predictions`

The one table with true high-volume growth: players × events. 10k weekly-active players × 10
picks/week ≈ 5M rows/year, each also UPDATEd once by scoring (`points`). Plan now, act later:
(a) the composite indexes from 2.3c, (b) `fillfactor=90` so scoring's point-updates stay HOT
(no index amplification), (c) partition by `client_key` hash or by time **only** when row count
approaches ~50M — premature partitioning would complicate RLS and PostgREST for nothing today.

### 2.12 LOW — Hygiene list

- Drop duplicate indexes: `gw_players_client_username_uidx`, `gw_league_members_league_username_key`;
  drop unused `gw_league_members_league_player_key` (re-add with the 2.8 re-key).
- Drop legacy `client_key` columns + indexes from `gw_dm_teams/events/tournaments` (global
  tables; columns are pre-Phase-1 remnants).
- Add `created_at`/`updated_at` (+ trigger) uniformly (`gw_rounds` has `created_at` but several
  tables have neither).
- `SET search_path` on SECURITY DEFINER functions (`save_prediction` etc.) if not already pinned
  (Supabase lint 0011).
- Verify views `gw_operators_public`, `gw_billing_current` are `security_invoker = true`
  (lint 0010) — re-check at implementation time.
- Standardise `status` fields to CHECKed enums (`'upcoming'|'completed'|…`).

---

## 3. Resiliency & redundancy (beyond schema)

| Area | Today | Recommendation |
|---|---|---|
| Backups | Weekly `pg_dump` via GitHub Actions (restore-drilled) + provider daily backups | Move to **PITR** when the Supabase plan allows; keep the external dump as provider-independent copy; add a quarterly restore drill to the runbook |
| Read scaling | Single instance | The Phase-4.1 payload cuts come first (100× cheaper than replicas); Supabase read replicas only when p95 read latency says so |
| Connection load | PostgREST + Supavisor pooling (platform-managed) | Set `db-max-rows` and per-role `statement_timeout`; keep Edge Functions on the pooled port |
| Cache layer | None (every embed load hits the DB) | After 4.1, the global-layer reads become per-tenant and small; if still hot, put the read-only embed bootstrap behind a short-TTL edge cache (Cloudflare) rather than a DB-side cache |
| Failure blast radius | One DB for all tenants | Acceptable for this product stage; the FK + RLS work above is what makes a per-tenant restore *possible* (cascade-scoped deletes/exports by `client_key`) |

---

## 4. Remediation roadmap

Ordered by risk-reduction per unit of work; each step is a normal CLI migration with a docker
test, deployable independently (matching the phase discipline used so far).

| # | Change | Finding | Risk of change |
|---|---|---|---|
| R1 | Policy rewrite: `(SELECT auth.uid())` everywhere, merge duplicate permissive policies, de-per-row `predictions_read` | 2.4, 2.5 | Low (pure predicate rewrite; test with existing RLS suites) |
| R2 | Drop duplicate/unused/legacy indexes + legacy dm client_key columns | 2.12 | Low |
| R3 | FK pass with `NOT VALID` + `VALIDATE`, + missing FK indexes | 2.1 | Low-medium (validate finds existing orphans first — fix data, then constrain) |
| R4 | CHECK constraints: id/client_key formats, status enums, points ≥ 0 | 2.3, 2.12 | Low |
| R5 | Retention cron for audit/cron/net tables | 2.10 | Trivial |
| R6 | `version` column + compare-and-set on `gw_dm_tournaments` (stop blob clobbers) | 2.2(1) | Low |
| R7 | `gw_round_events` junction + Phase-4.1 tenant-scoped reads + `db-max-rows`/timeouts | 2.1, 2.6 | Medium (embed query changes — behind the existing contract tests) |
| R8 | Seasons blob decomposition (`gw_dm_seasons/_teams/_rounds/_standings`) | 2.2(2) | High (touches /data + embed + widgets; do after 3.5 cutover, alongside 4.1) |
| R9 | League membership re-key to `player_id`; stop writing `username` into predictions | 2.8 | Medium (needs a small backfill; after 3.5) |
| R10 | Vault for provider tokens + sso_secret | 2.9 | Low |
| R11 | `gw_predictions` fillfactor + surrogate-key/partitioning decision point | 2.11 | Revisit at ~5M rows |

**Deliberately not recommended:** converting all text PKs to uuid (breaks the public URL/API
surface for marginal gain — constrain and govern them instead); table partitioning today
(complexity without payoff at current volume); microservice/db-per-tenant splits (RLS +
`client_key` scoping is the right multi-tenancy model for this product's scale).

---

## Appendix — raw index usage snapshot (2026-08-31)

Top scans: `gw_dm_events_pkey` 652,793 · `gw_dm_teams_pkey` 97,200 · `gw_dm_tournaments_pkey`
11,057 · `gw_operators_client_key_key` 6,155 · `gw_players_pkey` 3,363 · `gw_players_auth_id_idx`
2,584 · `gw_rounds_client_idx` 2,951 · `gw_competitions_client_idx` 1,851 ·
`gw_predictions_comp_idx` 1,118. Zero-scan: `gw_leaderboards_pkey`,
`gw_league_members_league_player_key`. Near-zero legacy: `gw_dm_teams_client_idx` (10),
`gw_dm_tournaments_client_idx` (12), `gw_dm_events_client_idx` (36).
