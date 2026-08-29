-- ============================================================================
-- LEGACY - DO NOT RUN. Already applied to the live database; its effects are
-- captured in the committed baseline supabase/migrations/20260829220021_remote_schema.sql.
-- Kept for history only. All new schema changes are Supabase CLI migrations.
-- ============================================================================

-- ============================================================================
-- Phase 0 — Contain (REARCHITECTURE-PHASES.md tasks 0.2, 0.3, 0.5)
-- Run in the Supabase SQL editor, section by section, top to bottom.
-- Each section is independently revertible (rollback noted at the end of it).
-- Baseline: docs/legacy/live-policies-2026-08.md (live pg_policies, 2026-08).
-- ============================================================================

-- ── Pre-flight ──────────────────────────────────────────────────────────────
-- The 0.1 audit captured pg_policies but not RLS-enabled status. Policies on a
-- table with RLS disabled are inert, so confirm before trusting any of them:
--
--   select relname, relrowsecurity, relforcerowsecurity
--   from pg_class
--   where relnamespace = 'public'::regnamespace and relname like 'gw_%'
--   order by relname;
--
-- Every section below also runs an idempotent ENABLE ROW LEVEL SECURITY on the
-- tables it touches, so those tables are safe either way.


-- ============================================================================
-- 0.2 — Restrict gw_dm_* writes to platform admins (closes C-2)
-- ============================================================================
-- Live state per the audit: dm_teams_write / dm_tournaments_write /
-- dm_events_write already use the gw_admins EXISTS predicate, but only as
-- USING with an implicit WITH CHECK. Recreated here with both made explicit
-- so the repo and the live schema say the same thing.
-- gw_dm_players ("dm_players_all": ALL true/true) is wide open — any player
-- token can rewrite the global squad database. Split into public read +
-- admin-only write.

alter table gw_dm_teams        enable row level security;
alter table gw_dm_tournaments  enable row level security;
alter table gw_dm_events       enable row level security;
alter table gw_dm_players      enable row level security;

drop policy if exists dm_teams_write on gw_dm_teams;
create policy dm_teams_write on gw_dm_teams
  for all
  using      (exists (select 1 from gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from gw_admins a where a.auth_id = auth.uid()));

drop policy if exists dm_tournaments_write on gw_dm_tournaments;
create policy dm_tournaments_write on gw_dm_tournaments
  for all
  using      (exists (select 1 from gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from gw_admins a where a.auth_id = auth.uid()));

drop policy if exists dm_events_write on gw_dm_events;
create policy dm_events_write on gw_dm_events
  for all
  using      (exists (select 1 from gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from gw_admins a where a.auth_id = auth.uid()));

-- gw_dm_players: keep global read (embed lineup mode and the squad widget
-- read squads anonymously), gate every write behind gw_admins.
drop policy if exists dm_players_all on gw_dm_players;
drop policy if exists dm_players_read on gw_dm_players;
create policy dm_players_read on gw_dm_players
  for select
  using (true);
drop policy if exists dm_players_write on gw_dm_players;
create policy dm_players_write on gw_dm_players
  for all
  using      (exists (select 1 from gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from gw_admins a where a.auth_id = auth.uid()));

-- Verify (0.2): /data still saves for a gw_admins member; /admin's tournament
-- picker and the embed's lineup squads still read. As anon, an insert into any
-- gw_dm_* table must fail with a policy violation.
-- Rollback (0.2): recreate the previous policies from
-- docs/legacy/live-policies-2026-08.md (dm_players_all was: for all using
-- (true) with check (true)).


-- ============================================================================
-- 0.3 — Committed RLS for the leagues tables (assessment §11.4)
-- ============================================================================
-- Live state per the audit: leagues_read/leagues_write and
-- league_members_read/league_members_write are all `true` — any token can
-- create, rename, or delete any league and any membership.
-- New model:
--   read       -> authenticated, scoped to leagues of a client the caller has
--                 a player row in
--   create     -> only as yourself (created_by must be your username for that
--                 league's client)
--   join/leave -> only your own membership row (username must be yours for
--                 that league's client)
-- No update/delete policy on gw_leagues and no update on gw_league_members:
-- those code paths don't exist in the embed, so nobody gets them until a
-- later phase adds ownership properly.

alter table gw_leagues        enable row level security;
alter table gw_league_members enable row level security;

-- Duplicate memberships would block the unique index; check first:
--   select league_id, username, count(*) from gw_league_members
--   group by 1, 2 having count(*) > 1;
-- (Delete the extras before continuing if any rows come back.)
create unique index if not exists gw_league_members_league_username_key
  on gw_league_members (league_id, username);

drop policy if exists leagues_read on gw_leagues;
create policy leagues_read on gw_leagues
  for select to authenticated
  using (exists (
    select 1 from gw_players p
    where p.auth_id = auth.uid()
      and p.client_key = gw_leagues.client_key
  ));

drop policy if exists leagues_write on gw_leagues;
create policy leagues_insert_self on gw_leagues
  for insert to authenticated
  with check (exists (
    select 1 from gw_players p
    where p.auth_id = auth.uid()
      and p.client_key = gw_leagues.client_key
      and p.username = gw_leagues.created_by
  ));

drop policy if exists league_members_read on gw_league_members;
create policy league_members_read on gw_league_members
  for select to authenticated
  using (exists (
    select 1
    from gw_leagues l
    join gw_players p on p.client_key = l.client_key
    where l.id = gw_league_members.league_id
      and p.auth_id = auth.uid()
  ));

drop policy if exists league_members_write on gw_league_members;
create policy league_members_insert_self on gw_league_members
  for insert to authenticated
  with check (exists (
    select 1
    from gw_leagues l
    join gw_players p on p.client_key = l.client_key
    where l.id = gw_league_members.league_id
      and p.auth_id = auth.uid()
      and p.username = gw_league_members.username
  ));

create policy league_members_delete_self on gw_league_members
  for delete to authenticated
  using (exists (
    select 1
    from gw_leagues l
    join gw_players p on p.client_key = l.client_key
    where l.id = gw_league_members.league_id
      and p.auth_id = auth.uid()
      and p.username = gw_league_members.username
  ));

-- Verify (0.3): in the embed as a signed-in player — create a league, copy the
-- code, join it from a second account, view its leaderboard, leave it. As a
-- player of client A, reading a client-B league by id must return zero rows.
-- Rollback (0.3): drop the five policies above and recreate leagues_read/
-- leagues_write/league_members_read/league_members_write as `true` per the
-- audit file; drop index gw_league_members_league_username_key.


-- ============================================================================
-- 0.5 — Username CHECK constraint (closes the C-4 source)
-- ============================================================================
-- The DB, not the browser, becomes the arbiter of the username charset.
-- Charset matches the client rule (embed registration: /^[a-zA-Z0-9_]+$/).
-- Length bound 24 matches the SSO username generator's base slice; the client
-- now enforces max 24 on manual registration and suffix-aware slicing in SSO
-- dedup (embed/index.html, same commit as this file).
--
-- RUN THIS FIRST — the constraint validates existing rows and the ALTER will
-- fail (harmlessly, but loudly) if any row violates it:
--
--   select id, client_key, username, length(username)
--   from gw_players
--   where username !~ '^[A-Za-z0-9_]{1,24}$';
--
-- Fix any offending rows (rename, coordinating with the operator if the
-- player is active), or — if long-but-clean usernames exist and renaming is
-- not wanted — raise the bound here AND in the embed's validation together.

alter table gw_players
  add constraint gw_players_username_format
  check (username ~ '^[A-Za-z0-9_]{1,24}$');

-- Verify (0.5): manual registration with a 25-char or non-[A-Za-z0-9_]
-- username is rejected client-side; a devtools insert bypassing the client is
-- rejected by the constraint.
-- Rollback (0.5):
--   alter table gw_players drop constraint gw_players_username_format;
