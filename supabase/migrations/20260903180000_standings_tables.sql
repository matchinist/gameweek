-- DB redesign phase R1 (owner decision, 2026-09-03): standings move out of
-- the gw_dm_tournaments.seasons jsonb blob into real tables. Why standings
-- first: two concurrent writers (the /data editor's bulk save and the
-- ingest worker's daily refresh) were doing read-modify-write on the same
-- blob and could silently clobber each other; row-level tables end that,
-- and the round_id column is the slot for per-round snapshot history.
create table public.gw_dm_standings (
  id            uuid        not null default gen_random_uuid(),
  tournament_id text        not null,
  season_key    text        not null,
  round_id      text,       -- null = the current table; per-round snapshots later
  rank          integer     not null,
  team_id       text,       -- null when a provider row matched no team yet
  name          text        not null,
  played        integer     not null default 0,
  w             integer     not null default 0,
  d             integer     not null default 0,
  l             integer     not null default 0,
  gf            integer     not null default 0,
  ga            integer     not null default 0,
  diff          integer     not null default 0,
  pts           integer     not null default 0,
  zone_id       text,
  updated_at    timestamptz not null default now(),
  constraint gw_dm_standings_pkey primary key (id),
  constraint gw_dm_standings_scope_rank_unique
    unique nulls not distinct (tournament_id, season_key, round_id, rank)
);
create index gw_dm_standings_scope_idx on public.gw_dm_standings (tournament_id, season_key);

-- Promotion/relegation bands. Zones describe table POSITIONS, so they are
-- per (tournament, season), assigned to rows via zone_id.
create table public.gw_dm_standing_zones (
  tournament_id text not null,
  season_key    text not null,
  zone_id       text not null,
  name          text,
  color         text,
  sort          integer not null default 0,
  constraint gw_dm_standing_zones_pkey primary key (tournament_id, season_key, zone_id)
);

-- RLS mirrors the gw_dm_* family: public read (the standings widget renders
-- logged out), writes for platform admins (/data) — service role bypasses.
alter table public.gw_dm_standings enable row level security;
alter table public.gw_dm_standing_zones enable row level security;
create policy dm_standings_read on public.gw_dm_standings for select to public using (true);
create policy dm_standings_write on public.gw_dm_standings for all to public
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
create policy dm_standing_zones_read on public.gw_dm_standing_zones for select to public using (true);
create policy dm_standing_zones_write on public.gw_dm_standing_zones for all to public
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));

-- Grants: policies decide WHO, grants decide WHAT'S POSSIBLE. Widgets read
-- anonymously; only signed-in admins (via the policies above) can write.
grant select on public.gw_dm_standings, public.gw_dm_standing_zones to anon;
grant select, insert, update, delete on public.gw_dm_standings, public.gw_dm_standing_zones to authenticated;
grant all on public.gw_dm_standings, public.gw_dm_standing_zones to service_role;

-- ── backfill from the blobs, then strip them ───────────────────────────────
-- One source of truth from day 1: every seasons->*->standings blob becomes
-- rows, then the standings key is removed from every season object. The
-- rest of the season blob (teamIds, rounds, …) is untouched — those are
-- later phases of the decomposition.
DO $$
DECLARE
  t record; s record; z jsonb; r jsonb;
BEGIN
  FOR t IN SELECT id, seasons FROM public.gw_dm_tournaments WHERE seasons IS NOT NULL LOOP
    FOR s IN SELECT key, value FROM jsonb_each(t.seasons) LOOP
      CONTINUE WHEN s.value->'standings' IS NULL;
      FOR z IN SELECT * FROM jsonb_array_elements(coalesce(s.value->'standings'->'zones','[]'::jsonb)) LOOP
        INSERT INTO public.gw_dm_standing_zones (tournament_id, season_key, zone_id, name, color, sort)
        VALUES (t.id, s.key, z->>'id', z->>'name', z->>'color', 0)
        ON CONFLICT DO NOTHING;
      END LOOP;
      FOR r IN SELECT * FROM jsonb_array_elements(coalesce(s.value->'standings'->'rows','[]'::jsonb)) LOOP
        INSERT INTO public.gw_dm_standings
          (tournament_id, season_key, round_id, rank, team_id, name,
           played, w, d, l, gf, ga, diff, pts, zone_id, updated_at)
        VALUES
          (t.id, s.key, NULL, (r->>'rank')::int, r->>'teamId', coalesce(r->>'name','?'),
           coalesce((r->>'played')::int,0), coalesce((r->>'w')::int,0), coalesce((r->>'d')::int,0),
           coalesce((r->>'l')::int,0), coalesce((r->>'gf')::int,0), coalesce((r->>'ga')::int,0),
           coalesce((r->>'diff')::int,0), coalesce((r->>'pts')::int,0), r->>'zoneId',
           coalesce((s.value->'standings'->>'updatedAt')::timestamptz, now()))
        ON CONFLICT DO NOTHING;
      END LOOP;
    END LOOP;
    UPDATE public.gw_dm_tournaments
      SET seasons = (SELECT coalesce(jsonb_object_agg(e.key, e.value - 'standings'), '{}'::jsonb)
                     FROM jsonb_each(gw_dm_tournaments.seasons) e)
      WHERE id = t.id;
  END LOOP;
END $$;
