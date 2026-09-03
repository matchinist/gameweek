#!/usr/bin/env bash
# Operator-public enumeration hardening test — written BEFORE the migration.
#
# gw_operators_public let anyone with the anon key dump the full operator
# roster in one query. The view's SELECT grant for anon/authenticated is
# revoked; public consumers (embed, widgets) switch to
# get_operator_public(client_key) — same nine safe columns, but you must
# already KNOW a client_key to get its row.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-oppub-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*operator_public*.sql" >/dev/null; then
  echo "FAIL: no operator_public migration found" >&2
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
insert into gw_operators (client_key, company_name, email, language, accent_color, sso_secret, domains)
  values ('acme_x1', 'Acme FC', 'secret@acme.io', 'tr', '#123456', 'topsecret-hmac', '["acme.io"]');
SQL

FAILED=0
check() { local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then echo "PASS  $label"
  else echo "FAIL  $label"; echo "      want: $want"; echo "      got:  $got"; FAILED=1; fi
}
as_anon() { docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 \
  -c "begin; set local role anon; $1 rollback;" 2>/dev/null | tail -1 || echo ERR; }

check "anon can no longer dump the view" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 -c "begin; set local role anon; select count(*) from gw_operators_public; rollback;" >/dev/null 2>&1 && echo OK || echo ERR)" "ERR"
check "authenticated cannot dump it either" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 -c "begin; set local role authenticated; select count(*) from gw_operators_public; rollback;" >/dev/null 2>&1 && echo OK || echo ERR)" "ERR"
check "anon fetches one known client through the accessor" \
  "$(as_anon "select company_name || ':' || language || ':' || accent_color from get_operator_public('acme_x1');")" "Acme FC:tr:#123456"
check "domains ride along (SSO origin gate)" \
  "$(as_anon "select domains::text from get_operator_public('acme_x1');")" '["acme.io"]'
check "unknown client returns nothing, not an error" \
  "$(as_anon "select coalesce(count(*)::text,'ERR') from get_operator_public('nope');")" "0"
check "the accessor exposes exactly the nine safe columns" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "select array_to_string(proargnames[2:], ',') from pg_proc where proname='get_operator_public';")" \
  "client_key,company_name,logo_url,language,accent_color,bg_color,surface_color,text_color,domains"
check "sso_secret and email stay unreachable through it" \
  "$(as_anon "select sso_secret from get_operator_public('acme_x1');")" "ERR"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
