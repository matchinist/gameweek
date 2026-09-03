#!/usr/bin/env bash
# ID standardisation test — written BEFORE the migration.
#
# Seeds a full OLD-STYLE graph (prefixed text ids, composed prediction keys,
# ids inside jsonb lineups/scorers/picks and event_ids arrays) just before
# the uuid migration, then proves the converted world end to end: uuid
# column types, every reference rewritten consistently, composed keys
# re-composed around the new round id, the read-gate policy and the
# save_prediction RPC still behaving across the text/uuid boundary.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-uuid-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*uuid_ids*.sql" >/dev/null; then
  echo "FAIL: no uuid_ids migration found" >&2
  exit 1
fi

cleanup() { docker stop "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --rm --name "$CONTAINER" -e POSTGRES_PASSWORD=t postgres:17-alpine >/dev/null
for _ in $(seq 1 30); do
  docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
create schema if not exists auth;
create schema if not exists extensions;
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create function auth.role() returns text language sql stable as
  $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon') $$;
create function auth.jwt() returns jsonb language sql stable as
  $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create table auth.users (id uuid primary key, email text, created_at timestamptz default now());
create schema if not exists storage;
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
do $$ begin
  if not exists (select from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth to anon, authenticated, service_role;
SQL

for f in "${ALL[@]}"; do
  if [[ "$f" == *uuid_ids* ]]; then
    docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
-- OLD-STYLE graph, exactly the shapes live had before the conversion
insert into gw_dm_teams (id, name, short, color) values
  ('tmHOME','Homers','HOM','#111'), ('tmAWAY','Awayers','AWY','#222');
insert into gw_dm_players (id, team_id, full_name, position) values
  ('plGK','tmHOME','Keeper One','GK'), ('plST','tmHOME','Striker Two','FWD');
insert into gw_dm_events (id, home_id, away_id, kickoff, kickoff_at, result, lineup, scorers) values
  ('evLOCKED','tmHOME','tmAWAY','', now() - interval '2 hours', '{"h":2,"a":1}',
   '{"home": ["plGK","plST"], "away": null}',
   '[{"type":"goal","playerId":"plST","minute":12},{"type":"sub","outId":"plST","inId":"plGK","minute":70}]'),
  ('evOPEN','tmHOME','tmAWAY','', now() + interval '2 days', null, null, null);
insert into gw_dm_tournaments (id, name) values ('tOLD','Old League');
insert into gw_dm_seasons (tournament_id, season_key) values ('tOLD','2026/27');
insert into gw_dm_season_rounds (id, tournament_id, season_key, label, sort_order, event_ids) values
  ('srOLD','tOLD','2026/27','GW 1',0,'{evLOCKED,evOPEN,evGONE}');
insert into gw_dm_season_teams (tournament_id, season_key, team_id) values ('tOLD','2026/27','tmHOME');
insert into gw_dm_standings (tournament_id, season_key, rank, team_id, name, pts) values ('tOLD','2026/27',1,'tmHOME','Homers',3);
insert into gw_competitions (id, client_key, name, mode, lineup_config) values
  ('cSCORE','clientA','Score Comp','score', null),
  ('cLINE','clientA','Lineup Comp','lineup', '{"teamId":"tmHOME","tournamentIds":["tOLD"]}');
insert into gw_rounds (id, competition_id, client_key, label, event_ids, sort_order) values
  ('rOLD','cSCORE','clientA','Round 1','{evLOCKED,evOPEN}',0);
insert into gw_leagues (id, client_key, name, code) values ('lgOLD','clientA','Office','OFF1');
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000aa');
insert into gw_players (id, auth_id, client_key, username, email) values
  ('22222222-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000aa','clientA','carla','c@t.io');
insert into gw_league_members (league_id, username, player_id) values ('lgOLD','carla','22222222-0000-0000-0000-000000000001');
insert into gw_predictions (client_key, player_id, username, competition_id, round_id, event_id, prediction) values
  ('clientA','22222222-0000-0000-0000-000000000001','carla','cSCORE','rOLD','evLOCKED','{"h":2,"a":1}'),
  ('clientA','22222222-0000-0000-0000-000000000001','carla','cSCORE','rOLD','rOLD_ranking','["x1","x2"]'),
  ('clientA','22222222-0000-0000-0000-000000000001','carla','cLINE','evLOCKED','evLOCKED','{"players":["plGK","plST"],"bonus":{"firstGoal":"plST","mvp":"plGK"}}');
insert into gw_leaderboards (client_key, competition_id, round_id, player_id, username, points) values
  ('clientA','cSCORE','rOLD','22222222-0000-0000-0000-000000000001','carla',5),
  ('clientA','cSCORE',null,'22222222-0000-0000-0000-000000000001','carla',5);
insert into gw_client_coverage (client_key, tournament_ids, team_ids) values ('clientA','["tOLD"]','["tmHOME","tmAWAY"]');
SQL
  fi
  docker cp "$f" "$CONTAINER:/tmp/mig.sql" >/dev/null
  docker exec "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 -f /tmp/mig.sql >/dev/null
done

FAILED=0
check() { local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then echo "PASS  $label"
  else echo "FAIL  $label"; echo "      want: $want"; echo "      got:  $got"; FAILED=1; fi
}
q() { docker exec "$CONTAINER" psql -U postgres -qtA -c "$1" 2>/dev/null | tail -1; }

check "entity id columns are uuid" \
  "$(q "select count(*) from information_schema.columns where table_schema='public' and data_type='uuid' and (table_name,column_name) in (('gw_dm_teams','id'),('gw_dm_events','id'),('gw_dm_players','id'),('gw_dm_tournaments','id'),('gw_dm_season_rounds','id'),('gw_competitions','id'),('gw_rounds','id'),('gw_leagues','id'),('gw_campaigns','id'),('gw_rounds','competition_id'),('gw_league_members','league_id'));")" "11"
check "membership arrays are uuid[] with the dangling ref dropped" \
  "$(q "select data_type from information_schema.columns where table_name='gw_dm_season_rounds' and column_name='event_ids';")-$(q "select array_length(event_ids,1) from gw_dm_season_rounds;")" "ARRAY-2"
check "the whole graph still joins (no orphaned references)" \
  "$(q "select (select count(*) from gw_dm_events e join gw_dm_teams h on h.id=e.home_id join gw_dm_teams a on a.id=e.away_id) + (select count(*) from gw_dm_players p join gw_dm_teams t on t.id=p.team_id) + (select count(*) from gw_rounds r join gw_competitions c on c.id=r.competition_id) + (select count(*) from gw_league_members m join gw_leagues l on l.id=m.league_id);")" "6"
check "prediction plain event ref follows the event's new uuid" \
  "$(q "select count(*) from gw_predictions p join gw_dm_events e on e.id::text = p.event_id where p.competition_id = (select id::text from gw_competitions where name='Score Comp');")" "1"
check "composed ranking key recomposed around the new round uuid" \
  "$(q "select count(*) from gw_predictions p join gw_rounds r on p.event_id = r.id::text || '_ranking';")" "1"
check "lineup jsonb, scorers and prediction picks all follow the players" \
  "$(q "select (select count(*) from gw_dm_events e join gw_dm_players pl on to_jsonb(pl.id::text) = e.lineup->'home'->0) + (select count(*) from gw_dm_events e join gw_dm_players pl on pl.id::text = e.scorers->0->>'playerId') + (select count(*) from gw_predictions p join gw_dm_players pl on to_jsonb(pl.id::text) = p.prediction->'players'->0) + (select count(*) from gw_predictions p join gw_dm_players pl on pl.id::text = p.prediction->'bonus'->>'firstGoal');")" "4"
check "lineup_config teamId and tournamentIds rewritten" \
  "$(q "select (select count(*) from gw_competitions c join gw_dm_teams t on t.id::text = c.lineup_config->>'teamId') + (select count(*) from gw_competitions c join gw_dm_tournaments tr on to_jsonb(tr.id::text) = c.lineup_config->'tournamentIds'->0);")" "2"
check "coverage arrays follow" \
  "$(q "select count(*) from gw_client_coverage c join gw_dm_tournaments t on to_jsonb(t.id::text) = c.tournament_ids->0;")" "1"
check "leaderboard scope strings follow comp and round" \
  "$(q "select (select count(*) from gw_leaderboards l join gw_competitions c on c.id::text = l.competition_id) + (select count(*) from gw_leaderboards l join gw_rounds r on r.id::text = l.round_id);")" "3"
check "read-gate: anon sees the locked-event row and the round-keyed row, not the open-event lineup row" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c "begin; set local role anon; select count(*) from gw_predictions; rollback;" | tail -1)" "3"
check "save_prediction still locks by kickoff across the type boundary" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c "begin; set local role authenticated; set local \"request.jwt.claim.sub\" = '00000000-0000-0000-0000-0000000000aa'; select save_prediction('clientA', (select id::text from gw_competitions where name='Score Comp'), (select id::text from gw_rounds limit 1), (select id::text from gw_dm_events where kickoff_at < now()), '{\"h\":1,\"a\":1}'::jsonb); rollback;" 2>&1 | grep -c 'locked')" "1"
check "save_prediction accepts an open event" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c "begin; set local role authenticated; set local \"request.jwt.claim.sub\" = '00000000-0000-0000-0000-0000000000aa'; select save_prediction('clientA', (select id::text from gw_competitions where name='Score Comp'), (select id::text from gw_rounds limit 1), (select id::text from gw_dm_events where kickoff_at > now()), '{\"h\":1,\"a\":1}'::jsonb); select count(*) from gw_predictions; rollback;" | tail -1)" "4"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
