-- ============================================================================
-- LEGACY - DO NOT RUN. THIS FILE TRUNCATES TABLES - running it against live
-- would DESTROY production data. The real schema lives in the committed
-- baseline supabase/migrations/20260829220021_remote_schema.sql; all new
-- schema changes are Supabase CLI migrations. Kept for history only.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- GAMEWEEK — Supabase Auth Migration
-- Run in Supabase SQL Editor in one go
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. CLEAN SLATE ───────────────────────────────────────────────────────────
truncate gw_predictions cascade;
truncate gw_players     cascade;
truncate gw_operators   cascade;
truncate gw_competitions cascade;
truncate gw_rounds      cascade;

-- ── 2. SCHEMA CHANGES ────────────────────────────────────────────────────────

-- Operators: remove password, add auth_id
alter table gw_operators drop column if exists password;
alter table gw_operators add column if not exists auth_id uuid references auth.users(id) on delete cascade;
alter table gw_operators add column if not exists username text;

-- Players: remove password, add auth_id + username
alter table gw_players drop column if exists password;
alter table gw_players add column if not exists auth_id uuid references auth.users(id) on delete cascade;
alter table gw_players add column if not exists username text;

-- ── 3. ENABLE RLS ON ALL TABLES ──────────────────────────────────────────────
alter table gw_operators     enable row level security;
alter table gw_competitions  enable row level security;
alter table gw_rounds        enable row level security;
alter table gw_players       enable row level security;
alter table gw_predictions   enable row level security;
alter table gw_dm_teams      enable row level security;
alter table gw_dm_tournaments enable row level security;
alter table gw_dm_events     enable row level security;

-- ── 4. DROP OLD POLICIES (clean start) ───────────────────────────────────────
drop policy if exists "operators_read_own"       on gw_operators;
drop policy if exists "operators_update_own"     on gw_operators;
drop policy if exists "operators_insert"         on gw_operators;
drop policy if exists "operators_read_admin"     on gw_operators;
drop policy if exists "operators_update_admin"   on gw_operators;
drop policy if exists "comps_read"               on gw_competitions;
drop policy if exists "comps_write_own"          on gw_competitions;
drop policy if exists "rounds_read"              on gw_rounds;
drop policy if exists "rounds_write_own"         on gw_rounds;
drop policy if exists "players_insert"           on gw_players;
drop policy if exists "players_read_own"         on gw_players;
drop policy if exists "players_update_own"       on gw_players;
drop policy if exists "players_read_operator"    on gw_players;
drop policy if exists "players_read_public"      on gw_players;
drop policy if exists "predictions_read"         on gw_predictions;
drop policy if exists "predictions_write_own"    on gw_predictions;
drop policy if exists "dm_teams_read"            on gw_dm_teams;
drop policy if exists "dm_tournaments_read"      on gw_dm_tournaments;
drop policy if exists "dm_events_read"           on gw_dm_events;
drop policy if exists "dm_teams_write"           on gw_dm_teams;
drop policy if exists "dm_tournaments_write"     on gw_dm_tournaments;
drop policy if exists "dm_events_write"          on gw_dm_events;

-- ── 5. RLS POLICIES ──────────────────────────────────────────────────────────

-- OPERATORS
-- Base table holds email + Stripe IDs, so it is owner-only (plus platform
-- admins). Public branding is served through gw_operators_public (section 5b),
-- never from this table. See supabase-rls-pii-fix.sql for the standalone,
-- idempotent version of this lockdown.
create policy "operators_insert" on gw_operators
  for insert to authenticated with check (auth.uid() = auth_id);

create policy "operators_read_own" on gw_operators
  for select to authenticated using (auth.uid() = auth_id);

create policy "operators_update_own" on gw_operators
  for update to authenticated using (auth.uid() = auth_id) with check (auth.uid() = auth_id);

-- Platform admins (Data Manager) read every operator and toggle billing flags.
create policy "operators_read_admin" on gw_operators
  for select to authenticated
  using (exists (select 1 from gw_admins a where a.auth_id = auth.uid()));

create policy "operators_update_admin" on gw_operators
  for update to authenticated
  using      (exists (select 1 from gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from gw_admins a where a.auth_id = auth.uid()));

revoke all on gw_operators from anon;
grant select, insert, update on gw_operators to authenticated;

-- COMPETITIONS (operators manage their own; anyone can read for embed)
create policy "comps_read" on gw_competitions
  for select using (true);

create policy "comps_write_own" on gw_competitions
  for all using (
    auth.uid() = (select auth_id from gw_operators where client_key = gw_competitions.client_key limit 1)
  );

-- ROUNDS (same as competitions)
create policy "rounds_read" on gw_rounds
  for select using (true);

create policy "rounds_write_own" on gw_rounds
  for all using (
    auth.uid() = (select auth_id from gw_operators where client_key = gw_rounds.client_key limit 1)
  );

-- PLAYERS
-- Holds player email, so it is owner-only (plus the operator whose client_key
-- the player belongs to, for the admin Users list). Leaderboards read the
-- denormalized gw_predictions.username, so no public read of this table is
-- needed. (Previously a `players_read_public USING (true)` policy leaked every
-- player's email to the anon key — removed.)
create policy "players_insert" on gw_players
  for insert to authenticated with check (auth.uid() = auth_id);

create policy "players_read_own" on gw_players
  for select to authenticated using (auth.uid() = auth_id);

create policy "players_update_own" on gw_players
  for update to authenticated using (auth.uid() = auth_id) with check (auth.uid() = auth_id);

-- An operator reads the players registered under its own client_key.
create policy "players_read_operator" on gw_players
  for select to authenticated
  using (client_key in (select client_key from gw_operators where auth_id = auth.uid()));

revoke all on gw_players from anon;
grant select, insert, update on gw_players to authenticated;

-- PREDICTIONS (anyone can read for leaderboard; users write own)
create policy "predictions_read" on gw_predictions
  for select using (true);

create policy "predictions_write_own" on gw_predictions
  for insert with check (
    auth.uid() = (select auth_id from gw_players where id = gw_predictions.player_id limit 1)
  );

create policy "predictions_update_own" on gw_predictions
  for update using (
    auth.uid() = (select auth_id from gw_players where id = gw_predictions.player_id limit 1)
  );

-- DM TABLES (global read; only authenticated operators can write)
create policy "dm_teams_read"      on gw_dm_teams      for select using (true);
create policy "dm_tournaments_read" on gw_dm_tournaments for select using (true);
create policy "dm_events_read"     on gw_dm_events     for select using (true);

create policy "dm_teams_write"      on gw_dm_teams      for all using (auth.uid() is not null);
create policy "dm_tournaments_write" on gw_dm_tournaments for all using (auth.uid() is not null);
create policy "dm_events_write"     on gw_dm_events     for all using (auth.uid() is not null);

-- ── 5b. PUBLIC PROJECTIONS ───────────────────────────────────────────────────
-- Safe, non-sensitive columns of gw_operators, readable by everyone so the
-- embed and widgets can theme themselves before (and without) login. Runs with
-- owner rights (security definer) so it bypasses the owner-only RLS above, but
-- exposes only these branding columns — email and Stripe IDs are not present.
create or replace view public.gw_operators_public
  with (security_invoker = false) as
  select client_key, company_name, logo_url, language,
         accent_color, bg_color, surface_color, text_color
  from public.gw_operators;

grant select on public.gw_operators_public to anon, authenticated;

-- ── 6. INDEXES ────────────────────────────────────────────────────────────────
create index if not exists gw_operators_auth_id_idx on gw_operators(auth_id);
create index if not exists gw_players_auth_id_idx   on gw_players(auth_id);
create index if not exists gw_players_client_key_idx on gw_players(client_key);
