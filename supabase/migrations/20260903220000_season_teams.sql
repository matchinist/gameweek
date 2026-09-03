-- DB redesign phase R3 (2026-09-03): season team pools move out of the
-- gw_dm_tournaments.seasons blob into gw_dm_season_teams — one row per team
-- per season, blob array order preserved via sort. After this, the seasons
-- blob holds nothing but the season keys themselves (R4 retires it).
create table public.gw_dm_season_teams (
  tournament_id text        not null,
  season_key    text        not null,
  team_id       text        not null,
  sort          integer     not null default 0,
  created_at    timestamptz not null default now(),
  constraint gw_dm_season_teams_pkey primary key (tournament_id, season_key, team_id)
);
create index gw_dm_season_teams_team_idx on public.gw_dm_season_teams (team_id);

alter table public.gw_dm_season_teams enable row level security;
create policy dm_season_teams_read on public.gw_dm_season_teams for select to public using (true);
create policy dm_season_teams_write on public.gw_dm_season_teams for all to public
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
grant select on public.gw_dm_season_teams to anon;
grant select, insert, update, delete on public.gw_dm_season_teams to authenticated;
grant all on public.gw_dm_season_teams to service_role;

-- ── backfill from the blobs, then strip them ───────────────────────────────
DO $$
DECLARE
  t record; s record; tm text; i integer;
BEGIN
  FOR t IN SELECT id, seasons FROM public.gw_dm_tournaments WHERE seasons IS NOT NULL LOOP
    FOR s IN SELECT key, value FROM jsonb_each(t.seasons) LOOP
      CONTINUE WHEN s.value->'teamIds' IS NULL;
      i := 0;
      FOR tm IN SELECT jsonb_array_elements_text(coalesce(s.value->'teamIds','[]'::jsonb)) LOOP
        INSERT INTO public.gw_dm_season_teams (tournament_id, season_key, team_id, sort)
        VALUES (t.id, s.key, tm, i)
        ON CONFLICT DO NOTHING;
        i := i + 1;
      END LOOP;
    END LOOP;
    UPDATE public.gw_dm_tournaments
      SET seasons = (SELECT coalesce(jsonb_object_agg(e.key, e.value - 'teamIds'), '{}'::jsonb)
                     FROM jsonb_each(gw_dm_tournaments.seasons) e)
      WHERE id = t.id;
  END LOOP;
END $$;
