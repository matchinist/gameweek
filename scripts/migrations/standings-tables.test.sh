#!/usr/bin/env bash
# DB redesign phase R1 test — written BEFORE the migration.
#
# Standings move out of the gw_dm_tournaments.seasons jsonb blob into real
# tables (gw_dm_standings + gw_dm_standing_zones):
#   * migration BACKFILLS existing blob standings into rows, then STRIPS the
#     standings key from every season blob — one source of truth from day 1
#   * scope = (tournament_id, season_key, round_id) with round_id NULL as
#     the current table (nulls-not-distinct unique on scope+rank) — the
#     round_id column is the future per-round-snapshot slot
#   * RLS mirrors the gw_dm_* family: public read (widgets render logged
#     out), writes for platform admins (the /data editor) and service role
#     (the ingest worker)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-standings-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*standings_tables*.sql" >/dev/null; then
  echo "FAIL: no standings_tables migration found" >&2
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

# Apply the chain, seeding a blob-holding tournament JUST BEFORE the
# standings migration so its backfill has something real to migrate.
for f in "${ALL[@]}"; do
  if [[ "$f" == *standings_tables* ]]; then
    docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
insert into gw_dm_tournaments (id, name, seasons) values ('t_sl', 'Super Lig', '{
  "2026-27": {
    "teamIds": ["tmA","tmB"],
    "rounds": [],
    "standings": {
      "updatedAt": "2026-09-01T10:00:00Z",
      "zones": [{"id":"z1","name":"Champions League","color":"#22c55e"}],
      "rows": [
        {"rank":1,"name":"Galatasaray","teamId":"tmA","played":3,"w":3,"d":0,"l":0,"gf":8,"ga":2,"diff":6,"pts":9,"zoneId":"z1"},
        {"rank":2,"name":"Fenerbahce","teamId":"tmB","played":3,"w":2,"d":1,"l":0,"gf":6,"ga":3,"diff":3,"pts":7,"zoneId":null}
      ]
    }
  },
  "2025-26": { "teamIds": [], "rounds": [] }
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
  elif [ "$who" = "service_role" ]; then setup="set local role service_role;"
  else setup="set local role authenticated; set local \"request.jwt.claim.sub\" = '$who';"
  fi
  docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 \
    -c "begin; $setup $q rollback;" 2>/dev/null | tail -1 || echo ERR
}
ADMIN=00000000-0000-0000-0000-0000000000ad
OTHER=00000000-0000-0000-0000-0000000000bb

check "backfill migrated blob rows" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "select string_agg(rank || ':' || name || ':' || pts || ':' || coalesce(zone_id,'-'), ',' order by rank) from gw_dm_standings where tournament_id='t_sl' and season_key='2026-27' and round_id is null;")" \
  "1:Galatasaray:9:z1,2:Fenerbahce:7:-"
check "backfill migrated zones" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "select zone_id || ':' || name from gw_dm_standing_zones where tournament_id='t_sl';")" \
  "z1:Champions League"
check "blob standings stripped, both seasons survive" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "select (seasons->'2026-27' ? 'standings')::text || ':' || (seasons ? '2026-27')::text || ':' || (seasons ? '2025-26')::text from gw_dm_tournaments where id='t_sl';")" \
  "false:true:true"
check "anon reads standings (widgets render logged out)" \
  "$(sql_as anon "select count(*) from gw_dm_standings;")" "2"
check "admin replaces the table" \
  "$(sql_as $ADMIN "delete from gw_dm_standings where tournament_id='t_sl'; insert into gw_dm_standings (tournament_id,season_key,rank,name,pts) values ('t_sl','2026-27',1,'Besiktas',12); select count(*) || ':' || max(name) from gw_dm_standings;")" "1:Besiktas"
check "non-admin write refused" \
  "$(sql_as $OTHER "insert into gw_dm_standings (tournament_id,season_key,rank,name) values ('x','s',1,'evil');")" "ERR"
check "duplicate rank in the same current-table scope refused (nulls not distinct)" \
  "$(sql_as service_role "insert into gw_dm_standings (tournament_id,season_key,rank,name) values ('t_sl','2026-27',1,'dupe');")" "ERR"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
