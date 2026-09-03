#!/usr/bin/env bash
# client_key → client_id test — written BEFORE the migration.
#
# Every tenant table used to carry the customer's client_key (text slug) as
# its tenant column, mostly without FK protection. The migration replaces it
# with client_id uuid → gw_customers(id) ON DELETE CASCADE everywhere except
# gw_customers itself (client_key survives there as the public URL handle)
# and gw_score_runs (audit history stays text). This test seeds an old-world
# graph — including an orphan row whose client_key matches no customer, and
# a workspace member — just before the migration, then proves the converted
# world: columns, FK fan-in, backfill joins, orphan sweep, rewritten
# policies/functions (RLS exercised under real jwts), the key-based
# save_prediction contract kept, the self-scoping billing views, and the
# one-statement tenant cascade.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"
CONTAINER=gw-clientid-test-pg

shopt -s nullglob
ALL=("$MIGRATIONS_DIR"/*.sql)
if ! compgen -G "$MIGRATIONS_DIR/*client_id*.sql" >/dev/null; then
  echo "FAIL: no client_id migration found" >&2
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
  if [[ "$f" == *client_id* ]]; then
    docker exec -i "$CONTAINER" psql -q -U postgres -v ON_ERROR_STOP=1 <<'SQL'
-- OLD-WORLD seed: tenant rows keyed by client_key text, exactly as live had
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000d1','own@cid.io'),
  ('00000000-0000-0000-0000-0000000000d2','mem@cid.io'),
  ('00000000-0000-0000-0000-0000000000d3','c2@t.io'),
  ('00000000-0000-0000-0000-0000000000d4','ghost@t.io');
insert into gw_customers (client_key, email, company_name, auth_id, plan) values
  ('cidacme','own@cid.io','Cid Acme','00000000-0000-0000-0000-0000000000d1','free');
insert into gw_workspace_members (client_key, auth_id, email) values
  ('cidacme','00000000-0000-0000-0000-0000000000d2','mem@cid.io');
insert into gw_workspace_invites (client_key, email, token) values ('cidacme','inv@cid.io','tok-cid-1');
insert into gw_dm_teams (id, name, short, color) values
  ('a1000000-0000-0000-0000-000000000001','CidHome','CH','#111'),
  ('a1000000-0000-0000-0000-000000000002','CidAway','CA','#222');
insert into gw_dm_events (id, home_id, away_id, kickoff, kickoff_at) values
  ('e1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000002','', now() + interval '2 days');
insert into gw_competitions (id, client_key, name, mode) values
  ('c1000000-0000-0000-0000-000000000001','cidacme','Cid Comp','score');
insert into gw_rounds (id, competition_id, client_key, label, event_ids, sort_order) values
  ('b1000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','cidacme','R1','{e1000000-0000-0000-0000-000000000001}',0);
insert into gw_players (id, auth_id, client_key, username, email) values
  ('15000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000d3','cidacme','carla2','c2@t.io'),
  ('15000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-0000000000d4','ghost','ghostie','ghost@t.io');
insert into gw_predictions (client_key, player_id, username, competition_id, round_id, event_id, prediction) values
  ('cidacme','15000000-0000-0000-0000-000000000001','carla2','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001','{"h":1,"a":0}');
insert into gw_leagues (id, client_key, name, code, created_by) values
  ('16000000-0000-0000-0000-000000000001','cidacme','Cid Office','CID1','carla2');
insert into gw_league_members (league_id, username, player_id) values
  ('16000000-0000-0000-0000-000000000001','carla2','15000000-0000-0000-0000-000000000001');
insert into gw_leaderboards (client_key, competition_id, round_id, player_id, username, points) values
  ('cidacme','c1000000-0000-0000-0000-000000000001',null,'15000000-0000-0000-0000-000000000001','carla2',5);
insert into gw_client_coverage (client_key) values ('cidacme');
insert into gw_subscriptions (client_key) values ('cidacme');
insert into gw_campaigns (id, client_key, brand_name) values
  ('17000000-0000-0000-0000-000000000001','cidacme','BrandX');
insert into gw_score_runs (initiated_by, client_key, competition_id, round_id) values
  ('test:seed','cidacme','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001');
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
as_jwt() { docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 \
  -c "begin; set local role authenticated; set local \"request.jwt.claim.sub\" = '$1'; $2 rollback;" 2>/dev/null | tail -1; }

check "client_id uuid NOT NULL on all 11 tenant tables" \
  "$(q "select count(*) from information_schema.columns where table_schema='public' and column_name='client_id' and data_type='uuid' and is_nullable='NO' and table_name in ('gw_campaigns','gw_client_coverage','gw_competitions','gw_leaderboards','gw_leagues','gw_players','gw_predictions','gw_rounds','gw_subscriptions','gw_workspace_invites','gw_workspace_members');")" "11"
check "client_key survives only on gw_customers and gw_score_runs (audit)" \
  "$(q "select count(*) from information_schema.columns c join pg_class r on r.relname=c.table_name join pg_namespace n on n.oid=r.relnamespace and n.nspname='public' where c.table_schema='public' and c.column_name='client_key' and r.relkind='r' and c.table_name not in ('gw_customers','gw_score_runs');")" "0"
check "dead client_key columns dropped from the global dm tables" \
  "$(q "select count(*) from information_schema.columns where table_schema='public' and column_name='client_key' and table_name like 'gw_dm_%';")" "0"
check "11 FKs now fan into gw_customers(id)" \
  "$(q "select count(*) from pg_constraint where contype='f' and confrelid='public.gw_customers'::regclass;")" "11"
check "backfill: every seeded tenant row joins its customer by client_id" \
  "$(q "with c as (select id from gw_customers where client_key='cidacme')
        select (select count(*) from gw_competitions t, c where t.client_id=c.id)
             + (select count(*) from gw_rounds t, c where t.client_id=c.id)
             + (select count(*) from gw_players t, c where t.client_id=c.id)
             + (select count(*) from gw_predictions t, c where t.client_id=c.id)
             + (select count(*) from gw_leagues t, c where t.client_id=c.id)
             + (select count(*) from gw_leaderboards t, c where t.client_id=c.id)
             + (select count(*) from gw_client_coverage t, c where t.client_id=c.id)
             + (select count(*) from gw_subscriptions t, c where t.client_id=c.id)
             + (select count(*) from gw_campaigns t, c where t.client_id=c.id)
             + (select count(*) from gw_workspace_members t, c where t.client_id=c.id)
             + (select count(*) from gw_workspace_invites t, c where t.client_id=c.id);")" "11"
check "orphan tenant row (client_key with no customer) swept" \
  "$(q "select count(*) from gw_players where username='ghostie';")" "0"
# the rpc runs under the player's jwt; the count runs as postgres because
# the player's RLS view of gw_customers is (correctly) empty
SAVED="$(docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 -c "begin; set local role authenticated; set local \"request.jwt.claim.sub\" = '00000000-0000-0000-0000-0000000000d3'; select save_prediction('cidacme','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001','{\"h\":2,\"a\":2}'::jsonb); select 'saved'; commit;" 2>/dev/null | tail -1)"
check "save_prediction keeps its key-based contract and writes client_id" \
  "${SAVED}-$(q "select count(*) from gw_predictions p join gw_customers c on c.id=p.client_id where p.prediction->>'h'='2';")" "saved-1"
check "workspace member can write the customer's competitions (rewritten policy + uuid gw_is_workspace_member)" \
  "$(as_jwt "00000000-0000-0000-0000-0000000000d2" "with u as (update gw_competitions set name='Cid Comp 2' where id='c1000000-0000-0000-0000-000000000001' returning 1) select count(*) from u;")" "1"
check "player sees their tenant's league (leagues_read via client_id)" \
  "$(as_jwt "00000000-0000-0000-0000-0000000000d3" "select count(*) from gw_leagues;")" "1"
check "get_customer_public now exposes the customer id" \
  "$(q "select (select id from get_customer_public('cidacme')) = (select id from gw_customers where client_key='cidacme');")" "t"
check "billing view: owner sees own row with the month's MAU" \
  "$(as_jwt "00000000-0000-0000-0000-0000000000d1" "select mau_count from gw_billing_current where client_key='cidacme';")" "1"
BILL_ANON="$(docker exec "$CONTAINER" psql -U postgres -qtA -v ON_ERROR_STOP=1 -c "begin; set local role anon; select count(*) from gw_billing_current; rollback;" 2>/dev/null | tail -1 || true)"
check "billing view: anon reads nothing (grant revoked or zero rows)" \
  "${BILL_ANON:-blocked}" "blocked"
check "identity guard recompiled against client_id" \
  "$(q "select (prosrc like '%client_id%' and prosrc not like '%client_key%')::text from pg_proc where proname='gw_players_identity_guard';")" "true"
check "workspace invite info joins customers via client_id" \
  "$(q "begin; set local role anon; select gw_workspace_invite_info('tok-cid-1')->>'company_name'; rollback;")" "Cid Acme"
check "old text-keyed helper signatures are gone" \
  "$(q "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and ((proname='gw_is_workspace_member' and pg_get_function_identity_arguments(p.oid) like '%text%') or proname='gw_my_client_key' or (proname='gw_admin_users_limit' and pg_get_function_identity_arguments(p.oid) like '%text%'));")" "0"
check "deleting the customer cascades the whole tenant in one statement" \
  "$(q "delete from gw_customers where client_key='cidacme';
        select (select count(*) from gw_competitions where name like 'Cid%')
             + (select count(*) from gw_rounds where label='R1' and client_id is not null)
             + (select count(*) from gw_players where username='carla2')
             + (select count(*) from gw_predictions p where not exists (select 1 from gw_customers c where c.id=p.client_id))
             + (select count(*) from gw_leagues where code='CID1')
             + (select count(*) from gw_subscriptions s where not exists (select 1 from gw_customers c where c.id=s.client_id))
             + (select count(*) from gw_workspace_members m where not exists (select 1 from gw_customers c where c.id=m.client_id));")" "0"

[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
