#!/usr/bin/env bash
# Packages ↔ workspace-seats test — written BEFORE the pending-invite guard
# migration.
#
# The chain under test: gw_packages carries admin_users (seats per pricing
# package), gw_customers points at a package (default Free via trigger),
# gw_admin_users_limit reads the package column, gw_create_workspace_invite
# enforces the cap, gw_accept_workspace_invite turns an invite into a
# gw_workspace_members row — the "customer admin users" table. Members are
# admin-panel-only at the DB layer: they read their workspace's customer row
# but hold no gw_admins row, so the Data Manager's write policies refuse
# them; they also cannot invite (owner-only).
#
# New in this migration: gw_my_pending_invite() — an invited person cannot
# read their own pending invite under RLS (only the owner can), so the admin
# login bootstrap needs a definer rpc to know "this email belongs in someone
# else's workspace" BEFORE it auto-creates a fresh shadow workspace.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-pkgws-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*pending_invite*.sql" >/dev/null; then
  echo "FAIL: no pending_invite migration found" >&2
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

# Post-chain fixtures. The chain's EAV seed carried no per-plan numbers, so
# the seat values are pinned here the way the owner sets them in /data.
docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
update gw_packages set admin_users = 3 where slug = 'growth';
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000e1','owner@pkg.io'),
  ('00000000-0000-0000-0000-0000000000e2','a@pkg.io'),
  ('00000000-0000-0000-0000-0000000000e3','b@pkg.io'),
  ('00000000-0000-0000-0000-0000000000e4','nobody@pkg.io');
-- no package_id on purpose: the default-package trigger must assign Free
insert into gw_customers (client_key, email, company_name, auth_id) values
  ('pkgco','owner@pkg.io','Pkg Co','00000000-0000-0000-0000-0000000000e1');
insert into gw_dm_teams (id, name, short, color) values
  ('a2000000-0000-0000-0000-000000000001','PkgTeam','PT','#333');
SQL

FAILED=0
check() { local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then echo "PASS  $label"
  else echo "FAIL  $label"; echo "      want: $want"; echo "      got:  $got"; FAILED=1; fi
}
q() { docker exec "$CONTAINER" psql -U postgres -qtA -c "$1" 2>/dev/null | tail -1; }
as_jwt() { docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 \
  -c "begin; set local role authenticated; set local \"request.jwt.claim.sub\" = '$1'; $2 commit;" 2>&1 | tail -1; }
# error assertions need the ERROR line, which tail -1 would drop (psql
# prints a CONTEXT line after it)
as_jwt_err() { docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 \
  -c "begin; set local role authenticated; set local \"request.jwt.claim.sub\" = '$1'; $2 commit;" 2>&1; }

OWNER=00000000-0000-0000-0000-0000000000e1
MEM_A=00000000-0000-0000-0000-0000000000e2
MEM_B=00000000-0000-0000-0000-0000000000e3
NOBODY=00000000-0000-0000-0000-0000000000e4
CID=$(q "select id from gw_customers where client_key='pkgco';")

check "packages carry admin_users; the five known slugs exist" \
  "$(q "select count(*) from gw_packages where slug in ('free','start','growth','scale','enterprise');")-$(q "select count(*) from information_schema.columns where table_name='gw_packages' and column_name='admin_users';")" "5-1"
check "a new customer lands on the Free package via the default trigger" \
  "$(q "select p.slug from gw_customers c join gw_packages p on p.id=c.package_id where c.client_key='pkgco';")" "free"
docker exec "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 -c \
  "update gw_customers set package_id=(select id from gw_packages where slug='growth') where client_key='pkgco';"
check "gw_admin_users_limit reads the package's seat count" \
  "$(q "select gw_admin_users_limit('$CID');")" "3"

TOK_A=$(as_jwt "$OWNER" "select gw_create_workspace_invite('a@pkg.io')->>'token';")
TOK_B=$(as_jwt "$OWNER" "select gw_create_workspace_invite('b@pkg.io')->>'token';")
as_jwt "$OWNER" "select gw_create_workspace_invite('c@pkg.io');" >/dev/null
check "three invites fit in three seats" \
  "$(q "select count(*) from gw_workspace_invites where accepted_at is null;")" "3"
check "the fourth invite is refused at the package's seat cap" \
  "$(as_jwt_err "$OWNER" "select gw_create_workspace_invite('d@pkg.io');" | grep -c PACKAGE_LIMIT)" "1"
check "an invited email sees its pending invite (definer rpc for the login guard)" \
  "$(as_jwt "$MEM_A" "select gw_my_pending_invite()->>'company_name';")" "Pkg Co"
check "an uninvited email sees none" \
  "$(as_jwt "$NOBODY" "select coalesce(gw_my_pending_invite()::text,'none');")" "none"

as_jwt "$MEM_A" "select gw_accept_workspace_invite('$TOK_A');" >/dev/null
check "accepting the invite creates the customer-admin-user row" \
  "$(q "select count(*) from gw_workspace_members m join gw_customers c on c.id=m.client_id where c.client_key='pkgco' and m.auth_id='$MEM_A';")" "1"
check "after accepting, the pending-invite rpc goes quiet" \
  "$(as_jwt "$MEM_A" "select coalesce(gw_my_pending_invite()::text,'none');")" "none"
check "a member reads the workspace's customer row (admin panel login works)" \
  "$(as_jwt "$MEM_A" "select count(*) from gw_customers where client_key='pkgco';")" "1"
check "a member cannot invite (owner-only)" \
  "$(as_jwt_err "$MEM_A" "select gw_create_workspace_invite('x@pkg.io');" | grep -c 'workspace owner')" "1"
check "a member is not a platform admin: Data Manager writes refuse them" \
  "$(as_jwt "$MEM_A" "with u as (update gw_dm_teams set name='Hax' where id='a2000000-0000-0000-0000-000000000001' returning 1) select count(*) from u;")" "0"
check "accepted seats still count against the cap (2 pending + 1 member = full)" \
  "$(as_jwt_err "$OWNER" "select gw_create_workspace_invite('e@pkg.io');" | grep -c PACKAGE_LIMIT)" "1"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
