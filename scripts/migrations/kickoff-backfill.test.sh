#!/usr/bin/env bash
# Phase 1.2 test — the kickoff_at backfill migration must agree with the
# tested JS parser (scripts/kickoff-backfill/parse-kickoff.mjs) on every
# format found in the live census, fail loudly on unparseable text, and
# leave empty/blank kickoffs NULL.
#
# Written BEFORE the migration exists (TDD). Flow: clean Postgres 17 →
# platform preamble → baseline migration → insert fixture rows → apply the
# kickoff_at migration(s) → assert each row's kickoff_at.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
BASELINE="$MIGRATIONS_DIR/20260829220021_remote_schema.sql"
CONTAINER=gw-kickoff-test-pg

shopt -s nullglob
LATER=()
for f in "$MIGRATIONS_DIR"/*.sql; do
  [ "$f" = "$BASELINE" ] || LATER+=("$f")
done
if [ ${#LATER[@]} -eq 0 ]; then
  echo "FAIL: no post-baseline migration found (kickoff_at migration missing)" >&2
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

psqlc() { docker exec "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 "$@"; }

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

docker cp "$BASELINE" "$CONTAINER:/tmp/baseline.sql" >/dev/null
psqlc -f /tmp/baseline.sql >/dev/null

# Fixture rows — one per live format, plus DST edges and rejects. Session
# timezone is deliberately NOT UTC so the migration only passes if it is
# timezone-explicit.
docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
set timezone = 'America/New_York';
insert into gw_dm_events (id, home_id, away_id, kickoff) values
  ('b0000000-0000-0000-0000-000000000001',   'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','2026-10-18T00:00:00.000Z'),
  ('b0000000-0000-0000-0000-000000000002',  'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','2026-11-07T22:59:59.999Z'),
  ('b0000000-0000-0000-0000-000000000003',       'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','2026-12-26 14:00:00+00'),
  ('b0000000-0000-0000-0000-000000000004',    'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','2026-12-30 18:44:59.999+00'),
  ('b0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','2027-03-20'),
  ('b0000000-0000-0000-0000-000000000006',   'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','2026-12-26T14:00'),
  ('b0000000-0000-0000-0000-000000000007',   'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','2026-09-19T20:00'),
  ('b0000000-0000-0000-0000-000000000008',    'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002',''),
  ('b0000000-0000-0000-0000-000000000009',     'a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002',null);
SQL

for f in "${LATER[@]}"; do
  echo "applying $(basename "$f")"
  docker cp "$f" "$CONTAINER:/tmp/mig.sql" >/dev/null
  psqlc -f /tmp/mig.sql >/dev/null
done

# Expected values mirror parse-kickoff.mjs (utc exact; date-only = UTC
# midnight; zoneless = Europe/London reading per the reviewed backfill policy).
check() {
  local id="$1" want="$2"
  local got
  got=$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "set timezone='UTC'; select coalesce(kickoff_at::text, '<null>') from gw_dm_events where id='$id';" | tail -1)
  if [ "$got" = "$want" ]; then echo "PASS  $id = $want"
  else echo "FAIL  $id want='$want' got='$got'"; FAILED=1; fi
}
FAILED=0
check b0000000-0000-0000-0000-000000000001   '2026-10-18 00:00:00+00'
check b0000000-0000-0000-0000-000000000002  '2026-11-07 22:59:59.999+00'
check b0000000-0000-0000-0000-000000000003       '2026-12-26 14:00:00+00'
check b0000000-0000-0000-0000-000000000004    '2026-12-30 18:44:59.999+00'
check b0000000-0000-0000-0000-000000000005 '2027-03-20 00:00:00+00'
check b0000000-0000-0000-0000-000000000006   '2026-12-26 14:00:00+00'
check b0000000-0000-0000-0000-000000000007   '2026-09-19 19:00:00+00'
check b0000000-0000-0000-0000-000000000008    '<null>'
check b0000000-0000-0000-0000-000000000009     '<null>'

# Unparseable text must make the migration's guard raise, not silently NULL.
set +e
docker exec "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -qc \
  "insert into gw_dm_events (id, home_id, away_id, kickoff) values ('b0000000-0000-0000-0000-000000000000','a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','not a date');" >/dev/null
docker cp "${LATER[0]}" "$CONTAINER:/tmp/again.sql" >/dev/null
OUT=$(docker exec "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -f /tmp/again.sql 2>&1)
RC=$?
set -e
if [ $RC -ne 0 ] && echo "$OUT" | grep -qi "unparseable"; then
  echo "PASS  unparseable kickoff raises instead of silently nulling"
else
  echo "FAIL  expected the migration to raise on unparseable kickoff (rc=$RC)"; FAILED=1
fi

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
