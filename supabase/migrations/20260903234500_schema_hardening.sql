-- Schema hardening (2026-09-03), the outcome of the id-type review:
--
-- 1. FK constraints across the gw_dm_* graph with cascades — the database
--    itself now guarantees no orphaned seasons/rounds/pools/standings/
--    players, replacing app-side cleanup as the only line of defence.
-- 2. COLLATE "C" on the machine-id columns of the dm family. The ids are
--    pure ASCII ('tm…'/'t…'/'r…'), so locale-aware en_US comparison was
--    pure cost (~25% per index probe, benchmarked on PG17). Deliberately
--    NOT changed: gw_dm_events.id (compared against gw_predictions.event_id
--    inside the prediction read-gate policy — both sides must move together,
--    and policy-referenced columns can't ALTER TYPE in place), and every
--    human-text column (names, usernames, labels).
--
-- Ids and app behaviour are untouched; this is index/type surgery only.

-- ── sweep any orphans so constraint creation cannot fail ───────────────────
delete from public.gw_dm_players p
  where p.team_id is not null
    and not exists (select 1 from public.gw_dm_teams t where t.id = p.team_id);
delete from public.gw_dm_season_teams st
  where not exists (select 1 from public.gw_dm_teams t where t.id = st.team_id)
     or not exists (select 1 from public.gw_dm_seasons s
                    where s.tournament_id = st.tournament_id and s.season_key = st.season_key);
delete from public.gw_dm_season_rounds r
  where not exists (select 1 from public.gw_dm_seasons s
                    where s.tournament_id = r.tournament_id and s.season_key = r.season_key);
update public.gw_dm_standings st set team_id = null
  where st.team_id is not null
    and not exists (select 1 from public.gw_dm_teams t where t.id = st.team_id);
delete from public.gw_dm_standings st
  where not exists (select 1 from public.gw_dm_seasons s
                    where s.tournament_id = st.tournament_id and s.season_key = st.season_key);
delete from public.gw_dm_standing_zones z
  where not exists (select 1 from public.gw_dm_seasons s
                    where s.tournament_id = z.tournament_id and s.season_key = z.season_key);
delete from public.gw_dm_seasons s
  where not exists (select 1 from public.gw_dm_tournaments t where t.id = s.tournament_id);

-- ── binary collation on machine-id columns ─────────────────────────────────
-- Both sides of every FK pair change together so equality stays same-collation.
alter table public.gw_dm_teams          alter column id            type text collate "C";
alter table public.gw_dm_tournaments    alter column id            type text collate "C";
alter table public.gw_dm_players        alter column id            type text collate "C",
                                        alter column team_id       type text collate "C";
alter table public.gw_dm_events         alter column home_id       type text collate "C",
                                        alter column away_id       type text collate "C";
alter table public.gw_dm_seasons        alter column tournament_id type text collate "C",
                                        alter column season_key    type text collate "C";
alter table public.gw_dm_season_rounds  alter column id            type text collate "C",
                                        alter column tournament_id type text collate "C",
                                        alter column season_key    type text collate "C";
alter table public.gw_dm_season_teams   alter column tournament_id type text collate "C",
                                        alter column season_key    type text collate "C",
                                        alter column team_id       type text collate "C";
alter table public.gw_dm_standings      alter column tournament_id type text collate "C",
                                        alter column season_key    type text collate "C",
                                        alter column round_id      type text collate "C",
                                        alter column team_id       type text collate "C",
                                        alter column zone_id       type text collate "C";
alter table public.gw_dm_standing_zones alter column tournament_id type text collate "C",
                                        alter column season_key    type text collate "C",
                                        alter column zone_id       type text collate "C";

-- ── the FK graph ───────────────────────────────────────────────────────────
alter table public.gw_dm_players add constraint gw_dm_players_team_fk
  foreign key (team_id) references public.gw_dm_teams(id) on delete cascade;

alter table public.gw_dm_seasons add constraint gw_dm_seasons_tournament_fk
  foreign key (tournament_id) references public.gw_dm_tournaments(id) on delete cascade;

alter table public.gw_dm_season_rounds add constraint gw_dm_season_rounds_season_fk
  foreign key (tournament_id, season_key)
  references public.gw_dm_seasons(tournament_id, season_key) on delete cascade;

alter table public.gw_dm_season_teams add constraint gw_dm_season_teams_season_fk
  foreign key (tournament_id, season_key)
  references public.gw_dm_seasons(tournament_id, season_key) on delete cascade;
alter table public.gw_dm_season_teams add constraint gw_dm_season_teams_team_fk
  foreign key (team_id) references public.gw_dm_teams(id) on delete cascade;

alter table public.gw_dm_standings add constraint gw_dm_standings_season_fk
  foreign key (tournament_id, season_key)
  references public.gw_dm_seasons(tournament_id, season_key) on delete cascade;
-- standings keep rendering after a team is deleted — the name column stays,
-- only the link nulls out
alter table public.gw_dm_standings add constraint gw_dm_standings_team_fk
  foreign key (team_id) references public.gw_dm_teams(id) on delete set null;

alter table public.gw_dm_standing_zones add constraint gw_dm_standing_zones_season_fk
  foreign key (tournament_id, season_key)
  references public.gw_dm_seasons(tournament_id, season_key) on delete cascade;

-- Deliberately no FK: gw_dm_events.home_id/away_id -> teams (an operator
-- deleting a team must not be blocked by historical fixtures; the apps
-- render the raw id as a fallback), gw_dm_season_rounds.event_ids (arrays
-- cannot carry FKs), and everything crossing into the per-tenant layer
-- (event_id in predictions is deliberately polymorphic).
