#!/usr/bin/env bash
# Phase 3.1 test — written BEFORE the migration.
#
# gw_predictions.points (nullable int = unscored) + gw_leaderboards:
#   * scope = (client_key, competition_id, round_id) with round_id NULL
#     meaning the overall scope — the unique key must treat NULL round_ids
#     as EQUAL (nulls not distinct) or every "overall" upsert would stack
#     duplicate rows per player.
#   * public read for everyone (anon included — leaderboards render logged
#     out); the only identifying column is the display username.
#   * no client-side writes at all: like the C-1 prediction revoke this is
#     enforced at the GRANT level, so there is no RLS policy to get wrong.
#     Only the service role (score-round Edge Function) writes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-leaderboards-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*leaderboards*.sql" >/dev/null; then
  echo "FAIL: no leaderboards migration found" >&2
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

FAILED=0
check() { local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then echo "PASS  $label"
  else echo "FAIL  $label"; echo "      want: $want"; echo "      got:  $got"; FAILED=1; fi
}
sql_as() { # sql_as <role> <sql> -> last line of output (errors -> "ERR")
  local role="$1" q="$2"
  docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 \
    -c "begin; set local role $role; $q rollback;" 2>/dev/null | tail -1 || echo ERR
}

# ── gw_predictions.points ──────────────────────────────────────────────────
check "gw_predictions.points exists, int, nullable" \
  "$(docker exec "$CONTAINER" psql -U postgres -qtA -c \
    "select data_type || ':' || is_nullable from information_schema.columns
     where table_name='gw_predictions' and column_name='points';")" \
  "integer:YES"

# ── seed leaderboard rows as the service path would ────────────────────────
docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
insert into gw_leaderboards (client_key, competition_id, round_id, player_id, username, points, correct, total) values
  ('clientA','c1','r1','11111111-0000-0000-0000-000000000001','alice',12,3,4),
  ('clientA','c1',null,'11111111-0000-0000-0000-000000000001','alice',19,6,8),
  ('clientA','c1',null,'11111111-0000-0000-0000-000000000002','bob',14,6,8);
SQL

# ── reads: public for anon and authenticated ───────────────────────────────
check "anon reads leaderboards" \
  "$(sql_as anon "select count(*) from gw_leaderboards;")" "3"
check "authenticated reads leaderboards" \
  "$(sql_as authenticated "select count(*) from gw_leaderboards;")" "3"

# ── writes: every client-side verb refused ─────────────────────────────────
check "anon insert refused" \
  "$(sql_as anon "insert into gw_leaderboards (client_key,competition_id,round_id,player_id,username,points) values ('x','c',null,'11111111-0000-0000-0000-000000000009','mallory',999);")" "ERR"
check "authenticated insert refused" \
  "$(sql_as authenticated "insert into gw_leaderboards (client_key,competition_id,round_id,player_id,username,points) values ('x','c',null,'11111111-0000-0000-0000-000000000009','mallory',999);")" "ERR"
check "authenticated update refused" \
  "$(sql_as authenticated "update gw_leaderboards set points=999;")" "ERR"
check "authenticated delete refused" \
  "$(sql_as authenticated "delete from gw_leaderboards;")" "ERR"
check "authenticated cannot write gw_predictions.points" \
  "$(sql_as authenticated "update gw_predictions set points=99;")" "ERR"

# ── service role writes (the score-round path) ─────────────────────────────
check "service_role upserts a round row" \
  "$(sql_as service_role "insert into gw_leaderboards (client_key,competition_id,round_id,player_id,username,points) values ('clientA','c1','r1','11111111-0000-0000-0000-000000000001','alice',15) on conflict (client_key,competition_id,round_id,player_id) do update set points=excluded.points, updated_at=now(); select points from gw_leaderboards where round_id='r1';")" "15"

# ── the overall scope (round_id null) must upsert, not stack ───────────────
check "duplicate overall row refused (nulls not distinct)" \
  "$(sql_as service_role "insert into gw_leaderboards (client_key,competition_id,round_id,player_id,username,points) values ('clientA','c1',null,'11111111-0000-0000-0000-000000000001','alice',20);")" "ERR"
check "service_role upserts the overall row in place" \
  "$(sql_as service_role "insert into gw_leaderboards (client_key,competition_id,round_id,player_id,username,points) values ('clientA','c1',null,'11111111-0000-0000-0000-000000000001','alice',21) on conflict (client_key,competition_id,round_id,player_id) do update set points=excluded.points, updated_at=now(); select count(*) || ':' || max(points) from gw_leaderboards where round_id is null and username='alice';")" "1:21"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
