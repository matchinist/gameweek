#!/usr/bin/env bash
# gw_package_settings (EAV) → gw_packages (real table) test — written BEFORE
# the migration.
#
# Pricing packages used to be stored inside-out: one row per SETTING in
# gw_package_settings, every package a key inside a `values` jsonb, and the
# package identity existing nowhere as a row. gw_customers.plan was free text
# with no FK. This migration makes each package a real row in gw_packages
# with typed columns, points gw_customers at it by package_id uuid FK
# (ON DELETE RESTRICT — a package in use can't be deleted out from under its
# clients), backfills from the jsonb, and drops the EAV table. This test
# seeds a customer on the old `plan` text just before the migration, then
# proves the packages world: the 5 packages became rows, limits/features
# backfilled with the right types, the customer FK resolves, the admin-users
# limit reads the package, RESTRICT protects in-use packages, the insert
# trigger defaults new customers to the free package, and RLS still gates
# writes to platform admins.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-packages-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*packages_table*.sql" >/dev/null; then
  echo "FAIL: no packages_table migration found" >&2
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
  if [[ "$f" == *packages_table* ]]; then
    docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
-- old-world seed: customers keyed to a package by the plan text slug, plus a
-- platform admin and a plain client user for the RLS checks
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000e1','admin@gw.io'),
  ('00000000-0000-0000-0000-0000000000e2','client@gw.io');
insert into gw_admins (auth_id) values ('00000000-0000-0000-0000-0000000000e1');
insert into gw_customers (client_key, email, company_name, auth_id, plan) values
  ('pkggrowth','g@t.io','Growth Co','00000000-0000-0000-0000-0000000000e2','growth'),
  ('pkgfree','f@t.io','Free Co',null,'free');
-- The seed migrations only create empty {} rows; the real per-package numbers
-- are entered later through the admin UI and live only in the database. Mirror
-- that production state here so the migration's jsonb→columns backfill has
-- something to copy.
update gw_package_settings set "values" = '{"free":300,"start":1000,"growth":5000,"scale":25000}'::jsonb where setting_key='monthly_active_users';
update gw_package_settings set "values" = '{"free":1,"start":3,"growth":10}'::jsonb where setting_key='tournaments';
update gw_package_settings set "values" = '{"free":1,"start":1,"growth":3}'::jsonb where setting_key='admin_users';
update gw_package_settings set "values" = '{"start":"Basic","growth":"Advanced","scale":"Advanced","enterprise":"Advanced"}'::jsonb where setting_key='user_analytics';
update gw_package_settings set "values" = '{"free":"No","start":"No","growth":"Yes","scale":"Yes","enterprise":"Yes"}'::jsonb where setting_key='sso';
update gw_package_settings set "values" = '{"free":"Yes","start":"No","growth":"No","scale":"No","enterprise":"No"}'::jsonb where setting_key='gameweek_logo';
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
# value-returning read as a role (pipe masks exit code — reads only)
read_as() { docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 -c "begin; set local role $1; ${2:-} $3 rollback;" 2>/dev/null | tail -1 || true; }
# runs a statement and reports OK/ERR by the REAL psql exit code (for the
# "must be refused" checks — no pipe to swallow the failure)
try_as() { if docker exec "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -c "begin; set local role $1; ${2:-} $3 rollback;" >/dev/null 2>&1; then echo OK; else echo ERR; fi; }

check "gw_packages exists; gw_package_settings dropped" \
  "$(q "select (to_regclass('public.gw_packages') is not null)::text||':'||(to_regclass('public.gw_package_settings') is null)::text;")" "true:true"
check "the 5 packages became rows" \
  "$(q "select string_agg(slug, ',' order by sort_order) from gw_packages;")" "free,start,growth,scale,enterprise"
check "typed columns exist with the right types" \
  "$(q "select string_agg(column_name||':'||data_type, ',' order by column_name) from information_schema.columns where table_name='gw_packages' and column_name in ('slug','name','sort_order','is_active','flat_fee','price_per_mau','included_mau','tournaments','admin_users','allowed_domains','user_analytics','sso','gameweek_logo');")" \
  "admin_users:integer,allowed_domains:integer,flat_fee:numeric,gameweek_logo:boolean,included_mau:integer,is_active:boolean,name:text,price_per_mau:numeric,slug:text,sort_order:integer,sso:boolean,tournaments:integer,user_analytics:text"
check "slug is unique" \
  "$(q "select count(*) from pg_constraint where conrelid='public.gw_packages'::regclass and contype='u';")" "1"
check "numeric limits backfilled from the jsonb (growth: mau 5000, tournaments 10, admin_users 3)" \
  "$(q "select included_mau||'/'||tournaments||'/'||admin_users from gw_packages where slug='growth';")" "5000/10/3"
check "enum + boolean features backfilled (growth: analytics Advanced, sso true; free: gameweek_logo true, sso false)" \
  "$(q "select (select user_analytics from gw_packages where slug='growth')||'/'||(select sso from gw_packages where slug='growth')||'/'||(select gameweek_logo from gw_packages where slug='free')||'/'||(select sso from gw_packages where slug='free');")" "Advanced/true/true/false"
check "gw_customers.plan dropped; package_id uuid NOT NULL added" \
  "$(q "select (select count(*) from information_schema.columns where table_name='gw_customers' and column_name='plan')::text||':'||(select data_type||'/'||is_nullable from information_schema.columns where table_name='gw_customers' and column_name='package_id');")" "0:uuid/NO"
check "package_id FK references gw_packages with ON DELETE RESTRICT" \
  "$(q "select confdeltype from pg_constraint where conrelid='public.gw_customers'::regclass and contype='f' and confrelid='public.gw_packages'::regclass;")" "r"
check "backfill: the growth-seeded customer resolves to the growth package" \
  "$(q "select p.slug from gw_customers c join gw_packages p on p.id=c.package_id where c.client_key='pkggrowth';")" "growth"
check "gw_admin_users_limit reads the package (growth -> 3)" \
  "$(q "select gw_admin_users_limit((select id from gw_customers where client_key='pkggrowth'));")" "3"
check "in-use package cannot be deleted (RESTRICT)" \
  "$(try_as postgres "" "delete from gw_packages where slug='growth';")" "ERR"
check "an unused package can be deleted" \
  "$(q "delete from gw_packages where slug='enterprise'; select count(*) from gw_packages where slug='enterprise';")" "0"
check "new customer with no package defaults to the free package (insert trigger)" \
  "$(q "insert into gw_customers (client_key, email, company_name) values ('pkgnew','n@t.io','New Co'); select p.slug from gw_customers c join gw_packages p on p.id=c.package_id where c.client_key='pkgnew';")" "free"
check "platform admin can insert a package (RLS)" \
  "$(read_as authenticated "set local \"request.jwt.claim.sub\"='00000000-0000-0000-0000-0000000000e1';" "insert into gw_packages (slug,name,sort_order) values ('team','Team',9); select count(*) from gw_packages where slug='team';")" "1"
check "a plain client user cannot write packages (RLS)" \
  "$(try_as authenticated "set local \"request.jwt.claim.sub\"='00000000-0000-0000-0000-0000000000e2';" "insert into gw_packages (slug,name) values ('sneak','Sneak');")" "ERR"
# (enterprise was deleted above, so compare against the live count rather
# than a fixed number — the point is the client sees every package)
check "a plain client user CAN read packages (billing page)" \
  "$(read_as authenticated "set local \"request.jwt.claim.sub\"='00000000-0000-0000-0000-0000000000e2';" "select count(*) from gw_packages;")" "$(q "select count(*) from gw_packages;")"
ANON_READ="$(read_as anon "" "select count(*) from gw_packages;")"
check "anon cannot read packages" "${ANON_READ:-blocked}" "blocked"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
