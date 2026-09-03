#!/usr/bin/env bash
# Phase 1.3 test — save_prediction() RPC (written BEFORE the migration).
#
# The RPC is the future single write path for predictions (1.5 revokes direct
# writes). Contract under test:
#   - security definer; callable by authenticated only (anon: permission denied)
#   - resolves the caller's player row for the given client_key
#     -> no row: raises 'not_registered'
#   - enforces now() < kickoff_at - 30 min IN THE DATABASE
#     -> at or past the boundary: raises 'locked' (>= comparison)
#   - an event id with no gw_dm_events row is NOT locked — lineup and ranking
#     modes store the ROUND id in event_id (savePred(roundId, ...)), so the
#     kickoff lookup legitimately misses; round-level status stays client-side
#     until those modes get their own guard
#   - username comes from gw_players, never from the caller (no such parameter)
#   - upsert semantics on (player_id, competition_id, event_id)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-savepred-test-pg

cleanup() { docker stop "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --rm --name "$CONTAINER" -e POSTGRES_PASSWORD=t postgres:17-alpine >/dev/null
for _ in $(seq 1 30); do
  docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

# Platform preamble (same as replay-test.sh)
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
SQL

shopt -s nullglob
for f in "$MIGRATIONS_DIR"/*.sql; do
  docker cp "$f" "$CONTAINER:/tmp/mig.sql" >/dev/null
  docker exec "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 -f /tmp/mig.sql >/dev/null
done

# Fixtures: two tenants, two players, events at useful kickoff offsets.
docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000b1');
insert into gw_players (id, auth_id, client_key, username, email) values
  ('11111111-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000a1','clientA','alice','a@t.io'),
  ('11111111-0000-0000-0000-000000000002','00000000-0000-0000-0000-0000000000b1','clientB','bob','b@t.io');
insert into gw_dm_events (id, home_id, away_id, kickoff, kickoff_at) values
  ('b0000000-0000-0000-0000-000000000001',     'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','', now() + interval '2 hours'),
  ('b0000000-0000-0000-0000-000000000002',     'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','', now() + interval '10 minutes'),
  ('b0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','', now() + interval '30 minutes'),
  ('b0000000-0000-0000-0000-000000000004',    'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','', null);
SQL

FAILED=0
ALICE=00000000-0000-0000-0000-0000000000a1
BOB=00000000-0000-0000-0000-0000000000b1

# call <who: anon|uuid> <client_key> <event_id> <prediction-json>
call() {
  local who="$1" ck="$2" ev="$3" pred="$4" setup
  if [ "$who" = "anon" ]; then setup="set local role anon;"
  else setup="set local role authenticated; set local \"request.jwt.claim.sub\" = '$who';"
  fi
  docker exec "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -qtA -c \
    "begin; $setup select save_prediction('$ck','comp1','round1','$ev','$pred'::jsonb); commit;" 2>&1
}
expect_err() { # label output needle
  if echo "$2" | grep -q "$3"; then echo "PASS  $1"
  else echo "FAIL  $1 — wanted '$3', got: $(echo "$2" | head -1)"; FAILED=1; fi
}
expect_ok() {
  if echo "$2" | grep -qi "error"; then echo "FAIL  $1 — unexpected error: $(echo "$2" | head -1)"; FAILED=1
  else echo "PASS  $1"; fi
}
q() { docker exec "$CONTAINER" psql -U postgres -qtA -c "$1"; }

echo "== callers =="
expect_err "anon cannot call"                        "$(call anon clientA b0000000-0000-0000-0000-000000000001 '{"value":"1-0"}')" "permission denied"
expect_err "authenticated without player row"        "$(call $ALICE clientB b0000000-0000-0000-0000-000000000001 '{"value":"1-0"}')" "not_registered"
expect_err "wrong tenant (bob into clientA)"         "$(call $BOB clientA b0000000-0000-0000-0000-000000000001 '{"value":"1-0"}')" "not_registered"

echo "== deadline =="
expect_ok  "open event accepted"                     "$(call $ALICE clientA b0000000-0000-0000-0000-000000000001 '{"value":"2-1"}')"
expect_err "10 minutes before kickoff is locked"     "$(call $ALICE clientA b0000000-0000-0000-0000-000000000002 '{"value":"1-1"}')" "locked"
expect_err "exactly at the 30-min boundary is locked" "$(call $ALICE clientA b0000000-0000-0000-0000-000000000003 '{"value":"1-1"}')" "locked"
expect_ok  "event with no kickoff row (lineup/ranking round id) accepted" \
  "$(call $ALICE clientA round_lineup_1 '{"players":[1,2,3]}')"

echo "== row contents =="
GOT=$(q "select username || '|' || client_key || '|' || (prediction->>'value') from gw_predictions where event_id='b0000000-0000-0000-0000-000000000001';")
if [ "$GOT" = "alice|clientA|2-1" ]; then echo "PASS  username set from gw_players, tenant + prediction stored"
else echo "FAIL  row contents: got '$GOT'"; FAILED=1; fi

echo "== upsert =="
expect_ok  "second save updates, not duplicates"     "$(call $ALICE clientA b0000000-0000-0000-0000-000000000001 '{"value":"3-0"}')"
N=$(q "select count(*) from gw_predictions where event_id='b0000000-0000-0000-0000-000000000001';")
V=$(q "select prediction->>'value' from gw_predictions where event_id='b0000000-0000-0000-0000-000000000001';")
if [ "$N" = "1" ] && [ "$V" = "3-0" ]; then echo "PASS  upsert keeps one row with the new value"
else echo "FAIL  upsert: count=$N value=$V"; FAILED=1; fi

echo "== locked update attempt =="
q "update gw_dm_events set kickoff_at = now() + interval '5 minutes' where id='b0000000-0000-0000-0000-000000000001';" >/dev/null
expect_err "existing prediction cannot be changed after lock" \
  "$(call $ALICE clientA b0000000-0000-0000-0000-000000000001 '{"value":"9-9"}')" "locked"
V2=$(q "select prediction->>'value' from gw_predictions where event_id='b0000000-0000-0000-0000-000000000001';")
if [ "$V2" = "3-0" ]; then echo "PASS  locked row unchanged"
else echo "FAIL  locked row was modified: $V2"; FAILED=1; fi

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
