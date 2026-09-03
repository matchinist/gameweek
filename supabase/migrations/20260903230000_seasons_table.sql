-- DB redesign phase R4 (2026-09-03) — the last blob. Season keys become
-- gw_dm_seasons rows and the gw_dm_tournaments.seasons jsonb column is
-- DROPPED: after R1 (standings), R2 (rounds) and R3 (team pools) it held
-- nothing but empty per-season objects. Apps reconstruct the in-memory
-- seasons shape from gw_dm_seasons + the three R1-R3 tables at load.
create table public.gw_dm_seasons (
  tournament_id text        not null,
  season_key    text        not null,
  created_at    timestamptz not null default now(),
  constraint gw_dm_seasons_pkey primary key (tournament_id, season_key)
);

alter table public.gw_dm_seasons enable row level security;
create policy dm_seasons_read on public.gw_dm_seasons for select to public using (true);
create policy dm_seasons_write on public.gw_dm_seasons for all to public
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
grant select on public.gw_dm_seasons to anon;
grant select, insert, update, delete on public.gw_dm_seasons to authenticated;
grant all on public.gw_dm_seasons to service_role;

-- ── backfill the keys, then retire the column ──────────────────────────────
insert into public.gw_dm_seasons (tournament_id, season_key)
  select t.id, e.key
  from public.gw_dm_tournaments t, jsonb_each(t.seasons) e
  where t.seasons is not null
on conflict do nothing;

-- Season keys can also exist only in the R1-R3 tables (e.g. rows written
-- after the earlier strips against a season the blob never knew) — sweep
-- those in too so nothing orphans.
insert into public.gw_dm_seasons (tournament_id, season_key)
  select distinct tournament_id, season_key from public.gw_dm_season_rounds
on conflict do nothing;
insert into public.gw_dm_seasons (tournament_id, season_key)
  select distinct tournament_id, season_key from public.gw_dm_season_teams
on conflict do nothing;
insert into public.gw_dm_seasons (tournament_id, season_key)
  select distinct tournament_id, season_key from public.gw_dm_standings
on conflict do nothing;

alter table public.gw_dm_tournaments drop column seasons;
