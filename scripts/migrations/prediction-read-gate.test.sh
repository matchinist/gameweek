#!/usr/bin/env bash
# Phase 1.6 test — gate prediction reads (H-6). Written BEFORE the migration.
#
# Replaces predictions_read USING (true) with:
#   * own rows: always visible (any of the caller's tenants)
#   * others' event-keyed rows: visible only once the event is locked
#     (now() >= kickoff_at - 30 min); unknown kickoff (null) = NOT locked
#   * round-keyed rows (no gw_dm_events row — lineup/ranking store the round
#     id in event_id): stay visible to everyone. Their leaderboards read
#     others' rows and the round→event link lives in the seasons JSON blob,
#     so there is no SQL-reachable lock time until Phase 3 moves leaderboards
#     server-side. Documented carve-out.
#   * anon: locked-event rows + round-keyed rows only (public leaderboards
#     keep working logged out)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-readgate-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! ls "$MIGRATIONS_DIR"/*read_gate*.sql >/dev/null 2>&1; then
  echo "FAIL: no prediction read-gate migration found" >&2
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
  ('00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000b1');
insert into gw_customers (client_key, email, company_name) values ('clientA','a-owner@t.io','Client A');
insert into gw_players (id, auth_id, client_id, username, email) values
  ('11111111-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000a1',(select id from gw_customers where client_key='clientA'),'alice','a@t.io'),
  ('11111111-0000-0000-0000-000000000002','00000000-0000-0000-0000-0000000000b1',(select id from gw_customers where client_key='clientA'),'bob','b@t.io');
insert into gw_dm_events (id, home_id, away_id, kickoff, kickoff_at) values
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','', now() - interval '1 hour'),
  ('b0000000-0000-0000-0000-000000000003',   'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','', now() + interval '2 hours'),
  ('b0000000-0000-0000-0000-000000000002',   'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','', null);
insert into gw_predictions (client_id, player_id, username, competition_id, round_id, event_id, prediction) values
  ((select id from gw_customers where client_key='clientA'),'11111111-0000-0000-0000-000000000001','alice','c1','r1','b0000000-0000-0000-0000-000000000001','{"value":"1-0"}'),
  ((select id from gw_customers where client_key='clientA'),'11111111-0000-0000-0000-000000000001','alice','c1','r1','b0000000-0000-0000-0000-000000000003','{"value":"2-0"}'),
  ((select id from gw_customers where client_key='clientA'),'11111111-0000-0000-0000-000000000001','alice','c1','r1','b0000000-0000-0000-0000-000000000002','{"value":"3-0"}'),
  ((select id from gw_customers where client_key='clientA'),'11111111-0000-0000-0000-000000000001','alice','c1','r1','round_lineup_1','{"players":[1]}'),
  ((select id from gw_customers where client_key='clientA'),'11111111-0000-0000-0000-000000000002','bob','c1','r1','b0000000-0000-0000-0000-000000000001','{"value":"0-1"}'),
  ((select id from gw_customers where client_key='clientA'),'11111111-0000-0000-0000-000000000002','bob','c1','r1','b0000000-0000-0000-0000-000000000003','{"value":"0-2"}');
SQL

FAILED=0
ALICE=00000000-0000-0000-0000-0000000000a1

seen() { # seen <anon|uuid> -> sorted "username:event_id" list
  local setup
  if [ "$1" = "anon" ]; then setup="set local role anon;"
  else setup="set local role authenticated; set local \"request.jwt.claim.sub\" = '$1';"
  fi
  docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "begin; $setup select string_agg(username || ':' || event_id, ',' order by username, event_id) from gw_predictions; rollback;" | tail -1
}
check() { local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then echo "PASS  $label"
  else echo "FAIL  $label"; echo "      want: $want"; echo "      got:  $got"; FAILED=1; fi
}

# alice: all her own rows + bob's LOCKED row only
check "alice sees own rows + others' locked rows only" \
  "$(seen $ALICE)" \
  "alice:b0000000-0000-0000-0000-000000000001,alice:b0000000-0000-0000-0000-000000000002,alice:b0000000-0000-0000-0000-000000000003,alice:round_lineup_1,bob:b0000000-0000-0000-0000-000000000001"

# anon: locked-event rows + round-keyed rows (public leaderboards)
check "anon sees locked-event + round-keyed rows only" \
  "$(seen anon)" \
  "alice:b0000000-0000-0000-0000-000000000001,alice:round_lineup_1,bob:b0000000-0000-0000-0000-000000000001"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
