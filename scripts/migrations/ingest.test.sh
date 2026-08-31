#!/usr/bin/env bash
# SportMonks ingest foundations test — written BEFORE the migration.
#
#   * gw_ingest_runs: audit trail for feed iterations — written only by the
#     ingest Edge Function's service role, readable by platform admins only
#     (same posture as gw_score_runs).
#   * provider_ids jsonb on the four global gw_dm_* tables — maps provider
#     entity ids (e.g. {"sportmonks": 123}) onto OUR hand-curated rows, so
#     the feed can only ever touch rows an admin explicitly mapped.
#   * name_i18n jsonb on teams/tournaments/players — per-language display
#     name overrides ({"tr": "...", "de": "...", "pt": "..."}).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-ingest-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*ingest*.sql" >/dev/null; then
  echo "FAIL: no ingest migration found" >&2
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
  docker cp "$f" "$CONTAINER:/tmp/mig.sql" >/dev/null
  docker exec "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 -f /tmp/mig.sql >/dev/null
done

docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000ad'),
  ('00000000-0000-0000-0000-0000000000bb');
insert into gw_admins (auth_id, email, name) values
  ('00000000-0000-0000-0000-0000000000ad','admin@t.io','Admin');
insert into gw_ingest_runs (trigger_source, initiated_by, ok, duration_ms, stats)
  values ('manual','admin@t.io',true,1500,'{"results_updated":3}');
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

check "service_role inserts an ingest run" \
  "$(sql_as service_role "insert into gw_ingest_runs (trigger_source, ok) values ('cron', false); select count(*) from gw_ingest_runs;")" "2"
check "platform admin reads the ingest log" \
  "$(sql_as $ADMIN "select count(*) from gw_ingest_runs;")" "1"
check "signed-in non-admin sees zero rows" \
  "$(sql_as $OTHER "select count(*) from gw_ingest_runs;")" "0"
check "anon select refused outright" \
  "$(sql_as anon "select count(*) from gw_ingest_runs;")" "ERR"
check "authenticated insert refused" \
  "$(sql_as $ADMIN "insert into gw_ingest_runs (trigger_source) values ('manual');")" "ERR"

cols() { docker exec "$CONTAINER" psql -U postgres -qtA -c \
  "select count(*) from information_schema.columns where table_name='$1' and column_name='$2' and data_type='jsonb';"; }
check "provider_ids on all four gw_dm tables" \
  "$(cols gw_dm_teams provider_ids)$(cols gw_dm_events provider_ids)$(cols gw_dm_players provider_ids)$(cols gw_dm_tournaments provider_ids)" "1111"
check "name_i18n on teams, tournaments, players" \
  "$(cols gw_dm_teams name_i18n)$(cols gw_dm_tournaments name_i18n)$(cols gw_dm_players name_i18n)" "111"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
