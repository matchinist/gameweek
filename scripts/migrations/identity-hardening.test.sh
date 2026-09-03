#!/usr/bin/env bash
# Phase 1.8 test — identity hardening (written BEFORE the migration).
#
# Contract:
#   * gw_players identity columns (id, auth_id, client_key, username) are
#     immutable for players — a trigger raises 'identity_immutable'; email
#     (profile) stays editable. service_role bypasses (future account tools).
#   * gw_league_members gets player_id (FK gw_players): backfilled for
#     existing rows via (league client_key, username); join/leave policies
#     require the caller's OWN player_id AND matching username (no display
#     spoofing); legacy no-match rows keep null player_id and survive.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-identity-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
# Split the chain around the identity migration: seed legacy-shaped data
# BEFORE it so the backfill is exercised, then apply it and everything after.
BEFORE=(); FROM=(); seen_identity=0
for f in "${ALL[@]}"; do
  if [[ "$f" == *identity* ]]; then seen_identity=1; fi
  if [ $seen_identity -eq 1 ]; then FROM+=("$f"); else BEFORE+=("$f"); fi
done
if [ $seen_identity -eq 0 ]; then
  echo "FAIL: no identity-hardening migration found" >&2
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
-- Real Supabase grants the API roles usage on the auth schema (auth.uid() is
-- called from client-issued statements, not only from policies).
grant usage on schema auth to anon, authenticated, service_role;
SQL

# Apply everything EXCEPT the identity migration, then seed legacy data,
# then apply the identity migration — proving the backfill on real-shaped rows.
for f in "${BEFORE[@]}"; do
  docker cp "$f" "$CONTAINER:/tmp/mig.sql" >/dev/null
  docker exec "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 -f /tmp/mig.sql >/dev/null
done

docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000b1');
-- this seed runs BEFORE the uuid/rename/client_id migrations, so the
-- operator-era table name and client_key columns are correct here; a
-- customer row must exist or the client_id backfill sweeps these as orphans
insert into gw_operators (client_key, email, company_name) values ('clientA','a-owner@t.io','Client A');
insert into gw_players (id, auth_id, client_key, username, email) values
  ('11111111-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000a1','clientA','alice','a@t.io'),
  ('11111111-0000-0000-0000-000000000002','00000000-0000-0000-0000-0000000000b1','clientA','bob','b@t.io');
insert into gw_leagues (id, client_key, name, code, created_by) values
  ('e0000000-0000-0000-0000-000000000001','clientA','A league','CODEA','alice');
-- legacy membership rows: alice matches a player; ghost does not
insert into gw_league_members (league_id, username) values
  ('e0000000-0000-0000-0000-000000000001','alice'),
  ('e0000000-0000-0000-0000-000000000001','ghost_no_player');
SQL

for f in "${FROM[@]}"; do
  docker cp "$f" "$CONTAINER:/tmp/identity.sql" >/dev/null
  docker exec "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 -f /tmp/identity.sql >/dev/null
done

FAILED=0
ALICE=00000000-0000-0000-0000-0000000000a1
BOB=00000000-0000-0000-0000-0000000000b1
P_ALICE=11111111-0000-0000-0000-000000000001
P_BOB=11111111-0000-0000-0000-000000000002

as() { # as <uuid> <sql>
  docker exec "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -qtA -c \
    "begin; set local role authenticated; set local \"request.jwt.claim.sub\" = '$1'; $2; commit;" 2>&1
}
q() { docker exec "$CONTAINER" psql -U postgres -qtA -c "$1"; }
expect_err() { if echo "$2" | grep -q "$3"; then echo "PASS  $1"; else echo "FAIL  $1 — wanted '$3', got: $(echo "$2" | head -1)"; FAILED=1; fi; }
expect_ok()  { if echo "$2" | grep -qi "error"; then echo "FAIL  $1 — unexpected error: $(echo "$2" | head -1)"; FAILED=1; else echo "PASS  $1"; fi; }

echo "== backfill =="
GOT=$(q "select player_id from gw_league_members where username='alice';")
[ "$GOT" = "$P_ALICE" ] && echo "PASS  legacy membership backfilled to player_id" || { echo "FAIL  backfill: got '$GOT'"; FAILED=1; }
GOT=$(q "select player_id is null from gw_league_members where username='ghost_no_player';")
[ "$GOT" = "t" ] && echo "PASS  no-match legacy row survives with null player_id" || { echo "FAIL  ghost row: got '$GOT'"; FAILED=1; }

echo "== gw_players immutability =="
expect_ok  "email update allowed"          "$(as $ALICE "update gw_players set email='new@t.io' where auth_id=auth.uid()")"
expect_err "client_id change blocked"      "$(as $ALICE "update gw_players set client_id='00000000-0000-0000-0000-00000000beef' where auth_id=auth.uid()")" "identity_immutable"
expect_err "username change blocked"       "$(as $ALICE "update gw_players set username='alice2' where auth_id=auth.uid()")" "identity_immutable"
expect_err "auth_id change blocked"        "$(as $ALICE "update gw_players set auth_id='$BOB' where auth_id=auth.uid()")" "identity_immutable"
GOT=$(as $ALICE "update gw_players set email='x@t.io' where username='bob' returning 1")
[ -z "$(echo "$GOT" | head -1)" ] || echo "$GOT" | grep -qi error && true
N=$(q "select email from gw_players where username='bob';")
[ "$N" = "b@t.io" ] && echo "PASS  cannot update another player's row (RLS)" || { echo "FAIL  bob's email changed: $N"; FAILED=1; }

echo "== league membership by player_id =="
expect_ok  "bob joins with own player_id + username" \
  "$(as $BOB "insert into gw_league_members (league_id, username, player_id) values ('e0000000-0000-0000-0000-000000000001','bob','$P_BOB')")"
expect_err "join with someone else's player_id blocked" \
  "$(as $ALICE "insert into gw_league_members (league_id, username, player_id) values ('e0000000-0000-0000-0000-000000000001','alice','$P_BOB')")" "row-level security"
expect_err "join with own player_id but spoofed username blocked" \
  "$(as $BOB "delete from gw_league_members where username='bob'; insert into gw_league_members (league_id, username, player_id) values ('e0000000-0000-0000-0000-000000000001','alice','$P_BOB')")" "row-level security"
expect_err "join without player_id blocked (legacy insert path closed)" \
  "$(as $BOB "insert into gw_league_members (league_id, username, player_id) values ('e0000000-0000-0000-0000-000000000001','bob2',null)")" "row-level security"
GOT=$(as $BOB "delete from gw_league_members where player_id='$P_ALICE' returning 1")
N=$(q "select count(*) from gw_league_members where username='alice';")
[ "$N" = "1" ] && echo "PASS  cannot delete another player's membership" || { echo "FAIL  alice's membership deleted"; FAILED=1; }
expect_ok  "leave own membership by player_id" \
  "$(as $ALICE "delete from gw_league_members where player_id='$P_ALICE'")"
N=$(q "select count(*) from gw_league_members where username='alice';")
[ "$N" = "0" ] && echo "PASS  own membership removed" || { echo "FAIL  leave failed"; FAILED=1; }

echo "== service_role bypass =="
expect_ok  "service_role may rename (account tooling)" \
  "$(docker exec "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -qtA -c "begin; set local role service_role; update gw_players set username='alice_renamed' where id='$P_ALICE'; rollback;" 2>&1)"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
