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
drop policy if exists "comps_read"               on gw_competitions;
drop policy if exists "comps_write_own"          on gw_competitions;
drop policy if exists "rounds_read"              on gw_rounds;
drop policy if exists "rounds_write_own"         on gw_rounds;
drop policy if exists "players_insert"           on gw_players;
drop policy if exists "players_read_own"         on gw_players;
drop policy if exists "players_update_own"       on gw_players;
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
create policy "operators_insert" on gw_operators
  for insert with check (auth.uid() = auth_id);

create policy "operators_read_own" on gw_operators
  for select using (auth.uid() = auth_id);

create policy "operators_update_own" on gw_operators
  for update using (auth.uid() = auth_id);

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
create policy "players_insert" on gw_players
  for insert with check (auth.uid() = auth_id);

create policy "players_read_own" on gw_players
  for select using (auth.uid() = auth_id);

create policy "players_update_own" on gw_players
  for update using (auth.uid() = auth_id);

-- Allow reading username+id for leaderboard (needed by other players)
create policy "players_read_public" on gw_players
  for select using (true);

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

-- ── 6. INDEXES ────────────────────────────────────────────────────────────────
create index if not exists gw_operators_auth_id_idx on gw_operators(auth_id);
create index if not exists gw_players_auth_id_idx   on gw_players(auth_id);
create index if not exists gw_players_client_key_idx on gw_players(client_key);
