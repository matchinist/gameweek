#!/usr/bin/env bash
# DB redesign phase R3 test — written BEFORE the migration.
#
# Season team pools move out of the gw_dm_tournaments.seasons blob into
# gw_dm_season_teams (one row per team per season, array order preserved via
# sort). Backfill + strip, dm-family RLS; apps hydrate season.teamIds at
# load; widgets read the table directly with blob fallback.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-seasonteams-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*season_teams*.sql" >/dev/null; then
  echo "FAIL: no season_teams migration found" >&2
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
  if [[ "$f" == *season_teams* ]]; then
    docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
insert into gw_dm_teams (id, name, short, color) values
  ('a0000000-0000-0000-0000-000000000001','Team A','TA','#111'),
  ('a0000000-0000-0000-0000-000000000002','Team B','TB','#222'),
  ('a0000000-0000-0000-0000-000000000003','Team C','TC','#333'),
  ('a0000000-0000-0000-0000-000000000004','Team Z','TZ','#444');
insert into gw_dm_tournaments (id, name, seasons) values ('c0000000-0000-0000-0000-000000000002', 'Pool Cup', '{
  "2026-27": { "teamIds": ["a0000000-0000-0000-0000-000000000002","a0000000-0000-0000-0000-000000000001","a0000000-0000-0000-0000-000000000003"] },
  "2025-26": { "teamIds": [] }
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

check "backfill preserved pool membership and array order" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "select string_agg(team_id::text, ',' order by sort) from gw_dm_season_teams where tournament_id='c0000000-0000-0000-0000-000000000002' and season_key='2026-27';")" \
  "a0000000-0000-0000-0000-000000000002,a0000000-0000-0000-0000-000000000001,a0000000-0000-0000-0000-000000000003"
check "both seasons survive as gw_dm_seasons rows (blob column retires in R4)" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "select string_agg(season_key, ',' order by season_key) from gw_dm_seasons where tournament_id='c0000000-0000-0000-0000-000000000002';")" \
  "2025-26,2026-27"
check "anon reads pools (widgets scope by season teams logged out)" \
  "$(sql_as anon "select count(*) from gw_dm_season_teams;")" "3"
check "admin rewrites a pool" \
  "$(sql_as $ADMIN "delete from gw_dm_season_teams where tournament_id='c0000000-0000-0000-0000-000000000002'; insert into gw_dm_season_teams (tournament_id,season_key,team_id,sort) values ('c0000000-0000-0000-0000-000000000002','2026-27','a0000000-0000-0000-0000-000000000004',0); select count(*) || ':' || max(team_id::text) from gw_dm_season_teams;")" "1:a0000000-0000-0000-0000-000000000004"
check "non-admin write refused" \
  "$(sql_as $OTHER "insert into gw_dm_season_teams (tournament_id,season_key,team_id) values ('c0000000-0000-0000-0000-000000000009','s','a0000000-0000-0000-0000-000000000009');")" "ERR"
check "duplicate membership refused" \
  "$(sql_as $ADMIN "insert into gw_dm_season_teams (tournament_id,season_key,team_id) values ('c0000000-0000-0000-0000-000000000002','2026-27','a0000000-0000-0000-0000-000000000001');")" "ERR"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
