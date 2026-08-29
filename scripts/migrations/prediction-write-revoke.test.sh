#!/usr/bin/env bash
# Phase 1.5 test — revoke direct prediction writes (closes C-1).
# Written BEFORE the migration.
#
# Contract after the revoke:
#   * authenticated direct INSERT/UPDATE on gw_predictions -> permission denied
#     (grant-level, before RLS is even consulted)
#   * anon direct INSERT -> permission denied
#   * the save_prediction() RPC still works (security definer, owner postgres)
#   * DELETE grant remains (admin competition-cleanup path is untouched)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-revoke-test-pg

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

shopt -s nullglob
for f in "$MIGRATIONS_DIR"/*.sql; do
  docker cp "$f" "$CONTAINER:/tmp/mig.sql" >/dev/null
  docker exec "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 -f /tmp/mig.sql >/dev/null
done

docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000a1');
insert into gw_players (id, auth_id, client_key, username, email) values
  ('11111111-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000a1','clientA','alice','a@t.io');
insert into gw_dm_events (id, home_id, away_id, kickoff, kickoff_at) values
  ('ev_open','h','a','', now() + interval '2 hours');
SQL

FAILED=0
ALICE=00000000-0000-0000-0000-0000000000a1
P_ALICE=11111111-0000-0000-0000-000000000001

as() {
  local who="$1" sql="$2" setup
  if [ "$who" = "anon" ]; then setup="set local role anon;"
  else setup="set local role authenticated; set local \"request.jwt.claim.sub\" = '$who';"
  fi
  docker exec "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -qtA -c "begin; $setup $sql; commit;" 2>&1
}
q() { docker exec "$CONTAINER" psql -U postgres -qtA -c "$1"; }
expect_err() { if echo "$2" | grep -q "$3"; then echo "PASS  $1"; else echo "FAIL  $1 — wanted '$3', got: $(echo "$2" | head -1)"; FAILED=1; fi; }
expect_ok()  { if echo "$2" | grep -qi "error"; then echo "FAIL  $1 — unexpected error: $(echo "$2" | head -1)"; FAILED=1; else echo "PASS  $1"; fi; }

expect_err "authenticated direct insert denied at grant level" \
  "$(as $ALICE "insert into gw_predictions (client_key,player_id,username,competition_id,round_id,event_id,prediction) values ('clientA','$P_ALICE','alice','c1','r1','ev_open','{}')")" \
  "permission denied for table gw_predictions"
expect_err "anon direct insert denied" \
  "$(as anon "insert into gw_predictions (client_key,player_id,username,competition_id,round_id,event_id,prediction) values ('clientA','$P_ALICE','alice','c1','r1','ev_open','{}')")" \
  "permission denied for table gw_predictions"
expect_ok  "RPC write still works" \
  "$(as $ALICE "select save_prediction('clientA','c1','r1','ev_open','{\"value\":\"1-0\"}'::jsonb)")"
expect_err "authenticated direct update denied" \
  "$(as $ALICE "update gw_predictions set prediction='{}'::jsonb where player_id='$P_ALICE'")" \
  "permission denied for table gw_predictions"
V=$(q "select prediction->>'value' from gw_predictions where event_id='ev_open';")
[ "$V" = "1-0" ] && echo "PASS  RPC row landed intact" || { echo "FAIL  RPC row: '$V'"; FAILED=1; }
GRANTS=$(q "select string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants where table_name='gw_predictions' and grantee='authenticated';")
echo "$GRANTS" | grep -q "DELETE" && echo "PASS  DELETE grant kept (admin cleanup path)" || { echo "FAIL  grants now: $GRANTS"; FAILED=1; }
echo "$GRANTS" | grep -qE "INSERT|UPDATE" && { echo "FAIL  INSERT/UPDATE still granted: $GRANTS"; FAILED=1; } || echo "PASS  INSERT/UPDATE revoked"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
