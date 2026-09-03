-- ID standardisation (owner decision, 2026-09-03): every entity id becomes
-- uuid. Executed now because there are no active customers — the embed URLs
-- and prediction history can change wholesale without breaking anyone.
--
-- What converts: gw_dm_teams/events/players/tournaments/season_rounds ids,
-- gw_competitions.id, gw_rounds.id, gw_leagues.id, gw_campaigns.id — plus
-- every relational reference column, and the id VALUES inside arrays, jsonb
-- (lineups, scorers, lineup_config, prediction picks) and loose text
-- reference columns.
--
-- What stays text, by design (documented in docs/ID-CONVENTIONS.md):
--   * natural keys/slugs: client_key, season_key, league code, comp_aliases
--   * polymorphic references that can hold composed keys:
--     gw_predictions.event_id ('<round uuid>_ranking'), and the log/scope
--     columns on gw_leaderboards / gw_score_runs / gw_ingest_runs /
--     gw_client_coverage — they store uuid STRINGS after this migration.
--
-- Existing uuid-shaped ids pass through unchanged (that is also what makes
-- the docker suites' uuid-literal seeds stable across this migration).

create or replace function public.gw_try_uuid(t text) returns uuid
language sql immutable parallel safe as
$$ select case when t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then t::uuid end $$;

DO $$
BEGIN

-- ── mappings: old text id -> new uuid (uuid-shaped ids keep their value) ───
create temp table m_team  on commit drop as select id as old, coalesce(gw_try_uuid(id), gen_random_uuid()) as new from public.gw_dm_teams;
create temp table m_event on commit drop as select id as old, coalesce(gw_try_uuid(id), gen_random_uuid()) as new from public.gw_dm_events;
create temp table m_player on commit drop as select id as old, coalesce(gw_try_uuid(id), gen_random_uuid()) as new from public.gw_dm_players;
create temp table m_tourn on commit drop as select id as old, coalesce(gw_try_uuid(id), gen_random_uuid()) as new from public.gw_dm_tournaments;
create temp table m_srnd  on commit drop as select id as old, coalesce(gw_try_uuid(id), gen_random_uuid()) as new from public.gw_dm_season_rounds;
create temp table m_comp  on commit drop as select id as old, coalesce(gw_try_uuid(id), gen_random_uuid()) as new from public.gw_competitions;
create temp table m_round on commit drop as select id as old, coalesce(gw_try_uuid(id), gen_random_uuid()) as new from public.gw_rounds;
create temp table m_league on commit drop as select id as old, coalesce(gw_try_uuid(id), gen_random_uuid()) as new from public.gw_leagues;
create temp table m_camp  on commit drop as select id as old, coalesce(gw_try_uuid(id), gen_random_uuid()) as new from public.gw_campaigns;
create unique index on m_team(old); create unique index on m_event(old);
create unique index on m_player(old); create unique index on m_tourn(old);
create unique index on m_srnd(old); create unique index on m_comp(old);
create unique index on m_round(old); create unique index on m_league(old);
create unique index on m_camp(old);

-- ── jsonb rewrites (while everything is still text) ────────────────────────
-- lineup_config on competitions: {teamId, tournamentIds[]}
update public.gw_competitions c set lineup_config =
  (select jsonb_set(
     jsonb_set(c.lineup_config, '{teamId}',
       coalesce(to_jsonb((select new::text from m_team where old = c.lineup_config->>'teamId')),
                c.lineup_config->'teamId')),
     '{tournamentIds}',
     coalesce((select jsonb_agg(coalesce((select to_jsonb(new::text) from m_tourn where old = e.v), to_jsonb(e.v)))
               from jsonb_array_elements_text(c.lineup_config->'tournamentIds') e(v)),
              coalesce(c.lineup_config->'tournamentIds', 'null'::jsonb))))
  where c.lineup_config is not null;

-- saved lineups on events: {home: [...player ids] | {slot: id}, away: ...}
update public.gw_dm_events ev set lineup =
  (select jsonb_object_agg(side.k,
     case jsonb_typeof(side.v)
       when 'array' then (select coalesce(jsonb_agg(coalesce((select to_jsonb(new::text) from m_player where old = e.v), to_jsonb(e.v))), '[]'::jsonb)
                          from jsonb_array_elements_text(side.v) e(v))
       when 'object' then (select coalesce(jsonb_object_agg(s.k, coalesce((select to_jsonb(new::text) from m_player where old = s.v #>> '{}'), s.v)), '{}'::jsonb)
                           from jsonb_each(side.v) s(k, v))
       else side.v
     end)
   from jsonb_each(ev.lineup) side(k, v))
  where ev.lineup is not null;

-- scorers on events: [{playerId|outId|inId: player id, ...}]
update public.gw_dm_events ev set scorers =
  (select jsonb_agg(
     (select jsonb_object_agg(f.k,
        case when f.k in ('playerId','outId','inId')
             then coalesce((select to_jsonb(new::text) from m_player where old = f.v #>> '{}'), f.v)
             else f.v end)
      from jsonb_each(entry.v) f(k, v)))
   from jsonb_array_elements(ev.scorers) entry(v))
  where ev.scorers is not null and jsonb_typeof(ev.scorers) = 'array';

-- lineup prediction picks: {players:[...], bonus:{firstGoal,mvp,firstSubOut}}
update public.gw_predictions p set prediction =
  jsonb_set(p.prediction, '{players}',
    (select coalesce(jsonb_agg(coalesce((select to_jsonb(new::text) from m_player where old = e.v), to_jsonb(e.v))), '[]'::jsonb)
     from jsonb_array_elements_text(p.prediction->'players') e(v)))
  where jsonb_typeof(p.prediction->'players') = 'array';
update public.gw_predictions p set prediction =
  jsonb_set(p.prediction, '{bonus}',
    (select jsonb_object_agg(f.k, coalesce((select to_jsonb(new::text) from m_player where old = f.v #>> '{}'), f.v))
     from jsonb_each(p.prediction->'bonus') f(k, v)))
  where jsonb_typeof(p.prediction->'bonus') = 'object'
    and p.prediction->'bonus' <> '{}'::jsonb;

-- ── loose text reference columns (types stay text) ─────────────────────────
update public.gw_predictions p set event_id = m.new::text
  from m_event m where m.old = p.event_id;
update public.gw_predictions p set event_id = m.new::text || '_ranking'
  from m_round m where p.event_id = m.old || '_ranking';
update public.gw_predictions p set round_id = m.new::text
  from m_round m where m.old = p.round_id;
update public.gw_predictions p set round_id = m.new::text
  from m_event m where m.old = p.round_id; -- lineup rounds ARE fixtures
update public.gw_predictions p set competition_id = m.new::text
  from m_comp m where m.old = p.competition_id;

update public.gw_leaderboards l set competition_id = m.new::text
  from m_comp m where m.old = l.competition_id;
update public.gw_leaderboards l set round_id = m.new::text
  from m_round m where m.old = l.round_id;
update public.gw_leaderboards l set round_id = m.new::text
  from m_event m where m.old = l.round_id;

update public.gw_client_coverage c set tournament_ids =
  (select coalesce(jsonb_agg(coalesce((select to_jsonb(new::text) from m_tourn where old = e.v), to_jsonb(e.v))), '[]'::jsonb)
   from jsonb_array_elements_text(c.tournament_ids) e(v))
  where jsonb_typeof(c.tournament_ids) = 'array';
update public.gw_client_coverage c set team_ids =
  (select coalesce(jsonb_agg(coalesce((select to_jsonb(new::text) from m_team where old = e.v), to_jsonb(e.v))), '[]'::jsonb)
   from jsonb_array_elements_text(c.team_ids) e(v))
  where jsonb_typeof(c.team_ids) = 'array';

-- event-membership arrays (rewritten as text, retyped to uuid[] below).
-- A dangling reference to a long-deleted event maps to nothing and is not
-- uuid-shaped — DROP it rather than let it break the retype: it pointed at
-- nothing renderable anyway.
update public.gw_rounds r set event_ids =
  (select coalesce(array_agg(x) filter (where x is not null), '{}') from
    (select coalesce((select new::text from m_event where old = e),
                     case when gw_try_uuid(e) is not null then e end) as x
     from unnest(r.event_ids) e) q);
update public.gw_dm_season_rounds r set event_ids =
  (select coalesce(array_agg(x) filter (where x is not null), '{}') from
    (select coalesce((select new::text from m_event where old = e),
                     case when gw_try_uuid(e) is not null then e end) as x
     from unnest(r.event_ids) e) q);

-- ── relational columns: rewrite values, then retype ────────────────────────
alter table public.gw_dm_players       drop constraint gw_dm_players_team_fk;
-- baseline-era FKs on the same columns (the hardening pass unknowingly
-- duplicated players->teams; the baseline one retires here for good)
alter table public.gw_dm_players       drop constraint gw_dm_players_team_id_fkey;
alter table public.gw_league_members   drop constraint gw_league_members_league_id_fkey;
alter table public.gw_rounds           drop constraint gw_rounds_competition_id_fkey;
alter table public.gw_dm_seasons       drop constraint gw_dm_seasons_tournament_fk;
alter table public.gw_dm_season_rounds drop constraint gw_dm_season_rounds_season_fk;
alter table public.gw_dm_season_teams  drop constraint gw_dm_season_teams_season_fk,
                                       drop constraint gw_dm_season_teams_team_fk;
alter table public.gw_dm_standings     drop constraint gw_dm_standings_season_fk,
                                       drop constraint gw_dm_standings_team_fk;
alter table public.gw_dm_standing_zones drop constraint gw_dm_standing_zones_season_fk;

update public.gw_dm_teams t set id = m.new::text from m_team m where m.old = t.id;
update public.gw_dm_events e set id = m.new::text from m_event m where m.old = e.id;
update public.gw_dm_events e set home_id = m.new::text from m_team m where m.old = e.home_id;
update public.gw_dm_events e set away_id = m.new::text from m_team m where m.old = e.away_id;
update public.gw_dm_players p set id = m.new::text from m_player m where m.old = p.id;
update public.gw_dm_players p set team_id = m.new::text from m_team m where m.old = p.team_id;
update public.gw_dm_tournaments t set id = m.new::text from m_tourn m where m.old = t.id;
update public.gw_dm_seasons s set tournament_id = m.new::text from m_tourn m where m.old = s.tournament_id;
update public.gw_dm_season_rounds r set id = m.new::text from m_srnd m where m.old = r.id;
update public.gw_dm_season_rounds r set tournament_id = m.new::text from m_tourn m where m.old = r.tournament_id;
update public.gw_dm_season_teams st set tournament_id = m.new::text from m_tourn m where m.old = st.tournament_id;
update public.gw_dm_season_teams st set team_id = m.new::text from m_team m where m.old = st.team_id;
update public.gw_dm_standings st set tournament_id = m.new::text from m_tourn m where m.old = st.tournament_id;
update public.gw_dm_standings st set team_id = m.new::text from m_team m where m.old = st.team_id;
update public.gw_dm_standings st set round_id = m.new::text from m_srnd m where m.old = st.round_id;
update public.gw_dm_standing_zones z set tournament_id = m.new::text from m_tourn m where m.old = z.tournament_id;
update public.gw_competitions c set id = m.new::text from m_comp m where m.old = c.id;
update public.gw_rounds r set id = m.new::text from m_round m where m.old = r.id;
update public.gw_rounds r set competition_id = m.new::text from m_comp m where m.old = r.competition_id;
update public.gw_leagues l set id = m.new::text from m_league m where m.old = l.id;
update public.gw_league_members lm set league_id = m.new::text from m_league m where m.old = lm.league_id;
update public.gw_campaigns c set id = m.new::text from m_camp m where m.old = c.id;

END $$;

-- policies referencing converting columns must not exist while the types
-- change (all recreated below, semantics identical on the new types)
drop policy if exists predictions_read on public.gw_predictions;
drop policy if exists league_members_read on public.gw_league_members;
drop policy if exists league_members_insert_self on public.gw_league_members;

alter table public.gw_dm_teams          alter column id type uuid using id::uuid;
alter table public.gw_dm_events         alter column id type uuid using id::uuid,
                                        alter column home_id type uuid using home_id::uuid,
                                        alter column away_id type uuid using away_id::uuid;
alter table public.gw_dm_players        alter column id drop default,
                                        alter column id type uuid using id::uuid,
                                        alter column id set default gen_random_uuid(),
                                        alter column team_id type uuid using team_id::uuid;
alter table public.gw_dm_tournaments    alter column id type uuid using id::uuid;
alter table public.gw_dm_seasons        alter column tournament_id type uuid using tournament_id::uuid;
alter table public.gw_dm_season_rounds  alter column id type uuid using id::uuid,
                                        alter column tournament_id type uuid using tournament_id::uuid,
                                        alter column event_ids drop default,
                                        alter column event_ids type uuid[] using event_ids::uuid[],
                                        alter column event_ids set default '{}';
alter table public.gw_dm_season_teams   alter column tournament_id type uuid using tournament_id::uuid,
                                        alter column team_id type uuid using team_id::uuid;
alter table public.gw_dm_standings      alter column tournament_id type uuid using tournament_id::uuid,
                                        alter column team_id type uuid using team_id::uuid,
                                        alter column round_id type uuid using round_id::uuid;
alter table public.gw_dm_standing_zones alter column tournament_id type uuid using tournament_id::uuid;
alter table public.gw_competitions      alter column id type uuid using id::uuid;
alter table public.gw_rounds            alter column id type uuid using id::uuid,
                                        alter column competition_id type uuid using competition_id::uuid,
                                        alter column event_ids drop default,
                                        alter column event_ids type uuid[] using event_ids::uuid[],
                                        alter column event_ids set default '{}';
alter table public.gw_leagues           alter column id type uuid using id::uuid,
                                        alter column id set default gen_random_uuid();
alter table public.gw_league_members    alter column league_id type uuid using league_id::uuid;
alter table public.gw_campaigns         alter column id type uuid using id::uuid,
                                        alter column id set default gen_random_uuid();

-- ── restore the FK graph on the new types ──────────────────────────────────
alter table public.gw_dm_players add constraint gw_dm_players_team_fk
  foreign key (team_id) references public.gw_dm_teams(id) on delete cascade;
alter table public.gw_dm_seasons add constraint gw_dm_seasons_tournament_fk
  foreign key (tournament_id) references public.gw_dm_tournaments(id) on delete cascade;
alter table public.gw_dm_season_rounds add constraint gw_dm_season_rounds_season_fk
  foreign key (tournament_id, season_key) references public.gw_dm_seasons(tournament_id, season_key) on delete cascade;
alter table public.gw_dm_season_teams add constraint gw_dm_season_teams_season_fk
  foreign key (tournament_id, season_key) references public.gw_dm_seasons(tournament_id, season_key) on delete cascade;
alter table public.gw_dm_season_teams add constraint gw_dm_season_teams_team_fk
  foreign key (team_id) references public.gw_dm_teams(id) on delete cascade;
alter table public.gw_dm_standings add constraint gw_dm_standings_season_fk
  foreign key (tournament_id, season_key) references public.gw_dm_seasons(tournament_id, season_key) on delete cascade;
alter table public.gw_dm_standings add constraint gw_dm_standings_team_fk
  foreign key (team_id) references public.gw_dm_teams(id) on delete set null;
alter table public.gw_dm_standing_zones add constraint gw_dm_standing_zones_season_fk
  foreign key (tournament_id, season_key) references public.gw_dm_seasons(tournament_id, season_key) on delete cascade;
alter table public.gw_league_members add constraint gw_league_members_league_id_fkey
  foreign key (league_id) references public.gw_leagues(id) on delete cascade;
alter table public.gw_rounds add constraint gw_rounds_competition_id_fkey
  foreign key (competition_id) references public.gw_competitions(id) on delete cascade;

-- league policies, verbatim on the new uuid types
create policy league_members_read on public.gw_league_members
  for select to authenticated
  using (exists (
    select 1 from public.gw_leagues l
    join public.gw_players p on p.client_key = l.client_key
    where l.id = gw_league_members.league_id and p.auth_id = auth.uid()
  ));
create policy league_members_insert_self on public.gw_league_members
  for insert to authenticated
  with check (exists (
    select 1 from public.gw_leagues l
    join public.gw_players p on p.client_key = l.client_key
    where l.id = gw_league_members.league_id
      and p.auth_id = auth.uid()
      and p.id = gw_league_members.player_id
      and p.username = gw_league_members.username
  ));

-- ── policy + RPC that compare events.id against text references ────────────
-- gw_try_uuid keeps the comparison index-friendly and never throws on
-- composed keys like '<round uuid>_ranking' (they simply match no event —
-- the exact semantics the text comparison had).
create policy predictions_read on public.gw_predictions
  for select
  using (
    gw_is_own_player(player_id)
    or not exists (
      select 1 from public.gw_dm_events e
      where e.id = public.gw_try_uuid(gw_predictions.event_id)
    )
    or exists (
      select 1 from public.gw_dm_events e
      where e.id = public.gw_try_uuid(gw_predictions.event_id)
        and e.kickoff_at is not null
        and now() >= e.kickoff_at - interval '30 minutes'
    )
  );

create or replace function public.save_prediction(
  p_client_key text, p_competition_id text, p_round_id text,
  p_event_id text, p_prediction jsonb
) returns void
language plpgsql security definer set search_path = public as
$$
declare
  v_player_id uuid;
  v_username text;
  v_kickoff timestamptz;
begin
  select id, username into v_player_id, v_username
  from gw_players
  where auth_id = auth.uid() and client_key = p_client_key;
  if v_player_id is null then
    raise exception 'not_registered';
  end if;

  select kickoff_at into v_kickoff
  from gw_dm_events
  where id = gw_try_uuid(p_event_id);
  if v_kickoff is not null and now() >= v_kickoff - interval '30 minutes' then
    raise exception 'locked';
  end if;

  insert into gw_predictions
    (client_key, player_id, username, competition_id, round_id, event_id, prediction)
  values
    (p_client_key, v_player_id, v_username, p_competition_id, p_round_id, p_event_id, p_prediction)
  on conflict (player_id, competition_id, event_id)
  do update set
    prediction   = excluded.prediction,
    round_id     = excluded.round_id,
    username     = excluded.username,
    submitted_at = now();
end;
$$;
