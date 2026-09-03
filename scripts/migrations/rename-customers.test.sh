#!/usr/bin/env bash
# operators → customers rename test — written BEFORE the migration.
#
# The rename itself is mechanical (views, policies and constraints follow a
# table rename automatically because they reference it by OID) — the part
# that silently breaks is FUNCTION BODIES: they are stored as text, so every
# function whose body says "gw_operators" keeps saying it and starts failing
# at its next call. This test seeds an operator-era world just before the
# rename migration, then proves the customer-era world end to end: table and
# view renamed, every dependent function recompiled against gw_customers,
# the public accessor renamed (with the old name kept as a compat wrapper
# for browser-cached embeds during the deploy gap), and no object left with
# "operator" in its name.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-rename-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*rename_operators_to_customers*.sql" >/dev/null; then
  echo "FAIL: no rename_operators_to_customers migration found" >&2
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
  if [[ "$f" == *rename_operators_to_customers* ]]; then
    docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
-- operator-era seed, inserted under the OLD names just before the rename
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000cc');
insert into gw_operators (client_key, email, company_name, language, accent_color, bg_color, surface_color, text_color, logo_url, domains, auth_id, plan, sso_enabled, sso_secret) values
  ('renacme','ren@acme.io','Ren Acme','tr','#abc123',null,null,null,null,'["acme.example"]'::jsonb,'00000000-0000-0000-0000-0000000000cc','free',true,'topsecret');
insert into gw_workspace_invites (client_key, email, token) values ('renacme','new@acme.io','tok-ren-1');
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
as_anon() { docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 -c "begin; set local role anon; $1 rollback;" 2>/dev/null | tail -1; }

check "gw_customers exists, gw_operators is gone" \
  "$(q "select (to_regclass('public.gw_customers') is not null)::text || ':' || (to_regclass('public.gw_operators') is null)::text;")" "true:true"
check "view renamed to gw_customers_public" \
  "$(q "select (select count(*) from pg_views where viewname='gw_customers_public') + (select count(*) from pg_views where viewname='gw_operators_public');")" "1"
check "the view revoke survived the rename (anon still cannot dump it)" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 -c "begin; set local role anon; select count(*) from gw_customers_public; rollback;" >/dev/null 2>&1 && echo OK || echo ERR)" "ERR"
check "get_customer_public serves the single row to anon" \
  "$(as_anon "select company_name || ':' || language || ':' || accent_color || ':' || domains::text from get_customer_public('renacme');")" 'Ren Acme:tr:#abc123:["acme.example"]'
# The rename migration created a compat wrapper under the old rpc name for
# browser-cached embeds; 20260904020000 drops it (owner call, same day).
check "old get_operator_public is gone (wrapper dropped)" \
  "$(q "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and proname='get_operator_public';")" "0"
# gw_my_client_key was superseded by gw_my_client_id in the client_id
# migration; the identity it resolves is the same customer
check "gw_my_client_id resolves the signed-in owner's customer" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 -c "begin; set local role authenticated; set local \"request.jwt.claim.sub\" = '00000000-0000-0000-0000-0000000000cc'; select gw_my_client_id() = (select id from gw_customers where client_key='renacme'); rollback;" | tail -1)" "t"
check "gw_workspace_invite_info recompiled (joins gw_customers for the company name)" \
  "$(as_anon "select gw_workspace_invite_info('tok-ren-1')->>'company_name';")" "Ren Acme"
check "gw_admin_users_limit recompiled (executes without error; uuid form since client_id)" \
  "$(q "select gw_admin_users_limit((select id from gw_customers where client_key='renacme')) >= 0;")" "t"
check "customer reads own row through the renamed policy" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 -c "begin; set local role authenticated; set local \"request.jwt.claim.sub\" = '00000000-0000-0000-0000-0000000000cc'; select count(*) from gw_customers; rollback;" | tail -1)" "1"
# Phase 0 revoked anon's grant on the table, so the probe errors ("blocked")
# rather than returning an RLS-filtered 0 — both mean anon reads nothing.
ANON_DIRECT="$(as_anon "select count(*) from gw_customers;" || true)"
check "anon reads nothing from gw_customers directly" \
  "${ANON_DIRECT:-blocked}" "blocked"
check "no policy, constraint or index named *operator* remains" \
  "$(q "select (select count(*) from pg_policies where policyname like '%operator%') + (select count(*) from pg_constraint co join pg_class c on c.oid=co.conrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and conname like '%operator%') + (select count(*) from pg_indexes where schemaname='public' and indexname like '%operator%');")" "0"
check "no function body still says gw_operators" \
  "$(q "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and prosrc like '%gw_operators%';")" "0"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
