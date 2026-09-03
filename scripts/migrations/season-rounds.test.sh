#!/usr/bin/env bash
# DB redesign phase R2 test — written BEFORE the migration.
#
# Season rounds move out of the gw_dm_tournaments.seasons blob into
# gw_dm_season_rounds (one row per round; event membership stays a text[]
# column, mirroring the per-client gw_rounds table's design). The migration
# backfills every blob round (array order -> sort_order) then strips the
# rounds key; apps hydrate the in-memory seasons shape from the table.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-seasonrounds-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*season_rounds*.sql" >/dev/null; then
  echo "FAIL: no season_rounds migration found" >&2
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
  if [[ "$f" == *season_rounds* ]]; then
    docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
insert into gw_dm_tournaments (id, name, seasons) values ('t_sl', 'Super Lig', '{
  "2026-27": {
    "teamIds": ["tmA","tmB"],
    "rounds": [
      {"id":"r_a","label":"Round 1","deadline":"","eventIds":["ev1","ev2"]},
      {"id":"r_b","label":"Round 2","deadline":"2026-09-06","eventIds":["ev3"]}
    ]
  }
}'::jsonb);
SQL
  fi
  docker cp "$f" "$CONTAINER:/tmp/mig.sql" >/dev/null
  docker exec "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 -f /tmp/mig.sql >/dev/null
done

docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000ad'), ('00000000-0000-0000-0000-0000000000bb');
insert into gw_admins (auth_id, email, name) values ('00000000-0000-0000-0000-0000000000ad','admin@t.io','Admin');
SQL

FAILED=0
check() { local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then echo "PASS  $label"
  else echo "FAIL  $label"; echo "      want: $want"; echo "      got:  $got"; FAILED=1; fi
}
sql_as() {
  local who="$1" q="$2" setup
  if [ "$who" = "anon" ]; then setup="set local role anon;"
  else setup="set local role authenticated; set local \"request.jwt.claim.sub\" = '$who';"
  fi
  docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 \
    -c "begin; $setup $q rollback;" 2>/dev/null | tail -1 || echo ERR
}
ADMIN=00000000-0000-0000-0000-0000000000ad
OTHER=00000000-0000-0000-0000-0000000000bb

check "backfill migrated rounds with order and event membership" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "select string_agg(id || ':' || label || ':' || sort_order || ':' || array_to_string(event_ids,'+') || ':' || deadline, ',' order by sort_order) from gw_dm_season_rounds where tournament_id='t_sl' and season_key='2026-27';")" \
  "r_a:Round 1:0:ev1+ev2:,r_b:Round 2:1:ev3:2026-09-06"
check "blob rounds stripped, teamIds intact" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "select (seasons->'2026-27' ? 'rounds')::text || ':' || jsonb_array_length(seasons->'2026-27'->'teamIds') from gw_dm_tournaments where id='t_sl';")" \
  "false:2"
check "anon reads rounds (embed builds gameweek labels logged out)" \
  "$(sql_as anon "select count(*) from gw_dm_season_rounds;")" "2"
check "admin rewrites a season's rounds" \
  "$(sql_as $ADMIN "delete from gw_dm_season_rounds where tournament_id='t_sl'; insert into gw_dm_season_rounds (id,tournament_id,season_key,label,sort_order,event_ids) values ('r_c','t_sl','2026-27','Round X',0,'{ev9}'); select count(*) || ':' || max(label) from gw_dm_season_rounds;")" "1:Round X"
check "non-admin write refused" \
  "$(sql_as $OTHER "insert into gw_dm_season_rounds (id,tournament_id,season_key,label) values ('evil','t','s','x');")" "ERR"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
