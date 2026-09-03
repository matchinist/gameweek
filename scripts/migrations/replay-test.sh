#!/usr/bin/env bash
# Phase 1.1 test — the committed schema baseline must replay into a CLEAN
# local Postgres (same major version as live: 17).
#
# Applies every file in supabase/migrations/*.sql, in filename order, to a
# disposable docker Postgres primed with a minimal Supabase-shaped preamble
# (roles + auth.uid() stub — the things the platform provides that a pulled
# public-schema baseline references but does not create). Fails loudly on the
# first SQL error, then sanity-checks that the core tables exist.
#
# Usage: scripts/migrations/replay-test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-replay-test-pg

shopt -s nullglob
FILES=("$MIGRATIONS_DIR"/*.sql)
if [ ${#FILES[@]} -eq 0 ]; then
  echo "FAIL: no migration files in $MIGRATIONS_DIR" >&2
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

# Supabase-platform preamble: the pulled baseline assumes these exist.
docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
create schema if not exists auth;
create schema if not exists extensions;
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create function auth.role() returns text language sql stable as
  $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon') $$;
create function auth.jwt() returns jsonb language sql stable as
  $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
-- Minimal auth.users: the baseline's auth_id foreign keys point at it.
create table auth.users (
  id uuid primary key,
  email text,
  created_at timestamptz default now()
);
-- Minimal storage.objects: the baseline carries the player-photos bucket
-- policies, which need somewhere to attach.
create schema if not exists storage;
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text,
  name text
);
alter table storage.objects enable row level security;
do $$ begin
  if not exists (select from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
grant usage on schema public to anon, authenticated, service_role;
SQL

for f in "${FILES[@]}"; do
  echo "applying $(basename "$f")"
  docker cp "$f" "$CONTAINER:/tmp/mig.sql" >/dev/null
  docker exec "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 -f /tmp/mig.sql >/dev/null
done

# Sanity: the tables the product cannot exist without.
MISSING=$(docker exec "$CONTAINER" psql -U postgres -qtA -c "
  select string_agg(t, ', ') from unnest(array[
    'gw_customers','gw_competitions','gw_rounds','gw_players','gw_predictions',
    'gw_leagues','gw_league_members','gw_dm_teams','gw_dm_tournaments',
    'gw_dm_events','gw_dm_players','gw_admins','gw_client_coverage'
  ]) t where to_regclass('public.'||t) is null;")
if [ -n "$MISSING" ]; then
  echo "FAIL: baseline replayed but tables missing: $MISSING" >&2
  exit 1
fi

TABLES=$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
  "select count(*) from pg_tables where schemaname='public';")
POLICIES=$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
  "select count(*) from pg_policies;")
echo "PASS: baseline replays clean — $TABLES public tables, $POLICIES policies"
