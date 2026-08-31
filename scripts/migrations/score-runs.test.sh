#!/usr/bin/env bash
# Scoring audit log test — written BEFORE the migration.
#
# gw_score_runs: one row per score-round invocation, written ONLY by the
# Edge Function (service role) so the trail can't be forged or skipped from
# a browser. Readable exclusively by platform admins (the /data Scoring Log
# page); anon has no SELECT grant at all, and a signed-in non-admin gets
# zero rows through the policy rather than an error.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-scoreruns-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*score_runs*.sql" >/dev/null; then
  echo "FAIL: no score_runs migration found" >&2
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
SQL

FAILED=0
check() { local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then echo "PASS  $label"
  else echo "FAIL  $label"; echo "      want: $want"; echo "      got:  $got"; FAILED=1; fi
}
sql_as() { # sql_as <anon|service_role|uuid> <sql>
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

# service role (the Edge Function) writes rows — seed one for the reads
docker exec "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 -c \
  "insert into gw_score_runs (initiated_by, client_key, competition_id, round_id, mode, duration_ms, predictions_scored, predictions_updated, round_rows, overall_rows, ok)
   values ('admin@t.io','clientA','c1','r1','score',412,20,5,9,9,true);"

check "service_role inserts a run row" \
  "$(sql_as service_role "insert into gw_score_runs (initiated_by,client_key,competition_id,round_id,ok,error) values ('admin@t.io','x','c','r',false,'boom'); select count(*) from gw_score_runs;")" "2"
check "platform admin reads the log" \
  "$(sql_as $ADMIN "select count(*) from gw_score_runs;")" "1"
check "signed-in non-admin sees zero rows" \
  "$(sql_as $OTHER "select count(*) from gw_score_runs;")" "0"
check "anon select refused outright" \
  "$(sql_as anon "select count(*) from gw_score_runs;")" "ERR"
check "authenticated insert refused" \
  "$(sql_as $ADMIN "insert into gw_score_runs (initiated_by,client_key,competition_id,round_id) values ('x','x','c','r');")" "ERR"
check "authenticated update refused" \
  "$(sql_as $ADMIN "update gw_score_runs set ok=false;")" "ERR"
check "authenticated delete refused" \
  "$(sql_as $ADMIN "delete from gw_score_runs;")" "ERR"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
