#!/usr/bin/env bash
# Multi-provider registry test — written BEFORE the migration.
#
# gw_providers: dynamic data-provider config (SportMonks today, others
# later) INCLUDING the API credential, managed from /data. Tokens are
# secrets: platform admins have full CRUD (that is the point of the page),
# the service role reads them for the ingest worker, and nothing else can
# see the table at all — anon has no grant, a signed-in non-admin gets
# nothing through the policies.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-providers-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*providers*.sql" >/dev/null; then
  echo "FAIL: no providers migration found" >&2
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

# the migration seeds a disabled 'sportmonks' row, so counts start at 1
check "admin creates a provider with a token" \
  "$(sql_as $ADMIN "insert into gw_providers (id,name,token,enabled) values ('testp','Test P','sk-secret',true); select count(*) from gw_providers;")" "2"
check "admin updates and deletes" \
  "$(sql_as $ADMIN "insert into gw_providers (id,name) values ('x','X'); update gw_providers set enabled=true where id='x'; delete from gw_providers where id='x'; select count(*) from gw_providers;")" "1"
check "the sportmonks seed exists and starts disabled" \
  "$(sql_as $ADMIN "select id || ':' || enabled from gw_providers;")" "sportmonks:false"
check "non-admin sees nothing" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 -c "insert into gw_providers (id,name,token) values ('sm','SM','sk-live-secret');" >/dev/null; sql_as $OTHER "select count(*) from gw_providers;")" "0"
check "non-admin cannot insert" \
  "$(sql_as $OTHER "insert into gw_providers (id,name) values ('evil','Evil');")" "ERR"
check "anon has no access at all" \
  "$(sql_as anon "select count(*) from gw_providers;")" "ERR"
check "service role reads tokens (the ingest worker)" \
  "$(sql_as service_role "select token from gw_providers where id='sm';")" "sk-live-secret"
check "gw_ingest_runs carries a provider column" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c "select count(*) from information_schema.columns where table_name='gw_ingest_runs' and column_name='provider';")" "1"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
