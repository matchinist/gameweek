#!/usr/bin/env bash
# Schema hardening test — written BEFORE the migration.
#
# Two things the id-type discussion landed on (2026-09-03):
#   * FK constraints across the gw_dm_* graph with cascades — the DB itself
#     now guarantees no orphaned seasons/rounds/pools/standings/players.
#   * COLLATE "C" on the machine-id columns of the dm family — the ids are
#     pure ASCII, so locale-aware comparison was pure cost (benchmarked
#     ~25% per index probe). Scoped to columns NOT referenced inside RLS
#     policy expressions and not compared column-to-column against
#     unchanged columns (gw_dm_events.id stays — the prediction read-gate
#     policy compares it to gw_predictions.event_id).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-hardening-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*schema_hardening*.sql" >/dev/null; then
  echo "FAIL: no schema_hardening migration found" >&2
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
  if [[ "$f" == *schema_hardening* ]]; then
    docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
insert into gw_dm_teams (id, name, short, color) values ('tmX','Xteam','X','#111'), ('tmY','Yteam','Y','#222');
insert into gw_dm_players (id, team_id, full_name) values ('plX','tmX','Player X');
insert into gw_dm_tournaments (id, name) values ('t_h','Hard Cup');
insert into gw_dm_seasons (tournament_id, season_key) values ('t_h','2026/27');
insert into gw_dm_season_rounds (id, tournament_id, season_key, label, sort_order, event_ids) values ('r_h','t_h','2026/27','Round 1',0,'{}');
insert into gw_dm_season_teams (tournament_id, season_key, team_id) values ('t_h','2026/27','tmX');
insert into gw_dm_standing_zones (tournament_id, season_key, zone_id, name) values ('t_h','2026/27','z1','CL');
insert into gw_dm_standings (tournament_id, season_key, rank, team_id, name, pts, zone_id) values ('t_h','2026/27',1,'tmX','Xteam',9,'z1');
-- an orphan the migration must sweep before constraints go on
insert into gw_dm_season_teams (tournament_id, season_key, team_id) values ('t_h','2026/27','tm_GONE');
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
q() { docker exec "$CONTAINER" psql -U postgres -qtA -c "$1" 2>/dev/null | tail -1 || echo ERR; }

check "orphan pool row swept before constraints" \
  "$(q "select count(*) from gw_dm_season_teams where team_id='tm_GONE';")" "0"
check "deleting a tournament cascades the whole season graph" \
  "$(q "delete from gw_dm_tournaments where id='t_h'; select (select count(*) from gw_dm_seasons where tournament_id='t_h') + (select count(*) from gw_dm_season_rounds where tournament_id='t_h') + (select count(*) from gw_dm_season_teams where tournament_id='t_h') + (select count(*) from gw_dm_standings where tournament_id='t_h') + (select count(*) from gw_dm_standing_zones where tournament_id='t_h');")" "0"
docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
insert into gw_dm_tournaments (id, name) values ('t_h','Hard Cup');
insert into gw_dm_seasons (tournament_id, season_key) values ('t_h','2026/27');
insert into gw_dm_season_teams (tournament_id, season_key, team_id) values ('t_h','2026/27','tmX');
insert into gw_dm_standings (tournament_id, season_key, rank, team_id, name, pts) values ('t_h','2026/27',1,'tmX','Xteam',9);
SQL
check "deleting a team cascades players + pool rows, standings keep the name (team_id nulled)" \
  "$(q "delete from gw_dm_teams where id='tmX'; select (select count(*) from gw_dm_players where id='plX')::text || ':' || (select count(*) from gw_dm_season_teams where team_id='tmX')::text || ':' || (select name || '/' || coalesce(team_id,'-') from gw_dm_standings where tournament_id='t_h' and rank=1);")" \
  "0:0:Xteam/-"
check "inserting a pool row for a missing season is refused" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 -c "insert into gw_dm_season_teams (tournament_id,season_key,team_id) values ('t_h','1999/00','tmY');" >/dev/null 2>&1 && echo OK || echo ERR)" "ERR"
check "machine-id columns use binary collation" \
  "$(q "select count(*) from information_schema.columns where table_schema='public' and collation_name='C' and (table_name,column_name) in (('gw_dm_teams','id'),('gw_dm_tournaments','id'),('gw_dm_seasons','tournament_id'),('gw_dm_season_rounds','id'),('gw_dm_season_teams','team_id'),('gw_dm_standings','team_id'),('gw_dm_players','team_id'),('gw_dm_events','home_id'));")" "8"
check "gw_dm_events.id deliberately unchanged (policy-referenced)" \
  "$(q "select coalesce(collation_name,'default') from information_schema.columns where table_name='gw_dm_events' and column_name='id';")" "default"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
