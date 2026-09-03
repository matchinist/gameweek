#!/usr/bin/env bash
# DB redesign phase R4 test — written BEFORE the migration.
#
# The last blob: season KEYS become gw_dm_seasons rows and the
# gw_dm_tournaments.seasons jsonb column is DROPPED. Apps reconstruct the
# in-memory seasons shape entirely from gw_dm_seasons + the R1-R3 tables.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-seasons-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*seasons_table*.sql" >/dev/null; then
  echo "FAIL: no seasons_table migration found" >&2
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
  if [[ "$f" == *seasons_table* ]]; then
    docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
-- post-R3 shape: seasons hold only their keys
insert into gw_dm_tournaments (id, name, seasons) values
  ('t_a', 'League A', '{"2026/27": {}, "2025/26": {}}'::jsonb),
  ('t_b', 'League B', '{"2026/27": {}}'::jsonb);
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

check "backfill created season rows per tournament" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "select tournament_id || ':' || string_agg(season_key, '+' order by season_key) from gw_dm_seasons where tournament_id in ('t_a','t_b') group by tournament_id order by tournament_id;" | paste -sd, -)" \
  "t_a:2025/26+2026/27,t_b:2026/27"
check "the seasons blob column is gone" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "select count(*) from information_schema.columns where table_name='gw_dm_tournaments' and column_name='seasons';")" "0"
check "anon reads seasons (embed and widgets hydrate logged out)" \
  "$(sql_as anon "select count(*) from gw_dm_seasons where tournament_id in ('t_a','t_b');")" "3"
check "admin creates and deletes a season" \
  "$(sql_as $ADMIN "insert into gw_dm_seasons (tournament_id,season_key) values ('t_a','2027/28'); delete from gw_dm_seasons where tournament_id='t_a' and season_key='2025/26'; select count(*) from gw_dm_seasons where tournament_id='t_a';")" "2"
check "non-admin write refused" \
  "$(sql_as $OTHER "insert into gw_dm_seasons (tournament_id,season_key) values ('t_a','evil');")" "ERR"
check "duplicate season refused" \
  "$(sql_as $ADMIN "insert into gw_dm_seasons (tournament_id,season_key) values ('t_a','2026/27');")" "ERR"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
