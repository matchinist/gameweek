-- Tenant references: client_key text → client_id uuid (2026-09-03, owner decision).
--
-- Every tenant table referenced gw_customers by its client_key slug — a
-- string derived from the company name at signup, mostly without any FK.
-- From here on the tenant column is client_id uuid → gw_customers(id)
-- ON DELETE CASCADE: rename-safe (a client_key change is one row again),
-- orphan-proof, and half the index width on the hot tables. client_key
-- SURVIVES on gw_customers as the public URL handle (embed snippets keep
-- working; get_customer_public stays key-addressed and now returns the id
-- so anonymous pages can resolve it in the fetch they already make), and
-- on gw_score_runs, whose rows are audit history and are never rewritten.
--
-- The dance: policies and views that mention client_key must go first
-- (they'd block the column drop), the columns convert with a backfill and
-- an orphan sweep, then functions/policies/views come back in client_id
-- form. Function bodies never follow schema changes (they're text), so
-- everything that said client_key on a converted table is recreated here.

-- ── 1. drop dependents ────────────────────────────────────────────────────
drop view public.gw_billing_current;
drop view public.gw_mau_current;

drop policy campaigns_write_own        on public.gw_campaigns;
drop policy coverage_own_read          on public.gw_client_coverage;
drop policy comps_write_own            on public.gw_competitions;
drop policy customers_read_own         on public.gw_customers;
drop policy customers_update_own       on public.gw_customers;
drop policy league_members_insert_self on public.gw_league_members;
drop policy league_members_read        on public.gw_league_members;
drop policy leagues_insert_self        on public.gw_leagues;
drop policy leagues_read               on public.gw_leagues;
drop policy players_read_customer      on public.gw_players;
drop policy rounds_write_own           on public.gw_rounds;
drop policy subscriptions_read_own     on public.gw_subscriptions;
drop policy wi_delete_owner            on public.gw_workspace_invites;
drop policy wi_select                  on public.gw_workspace_invites;
drop policy wm_select                  on public.gw_workspace_members;

drop function public.gw_is_workspace_member(text);
drop function public.gw_my_client_key();
drop function public.gw_admin_users_limit(text);
drop function public.get_customer_public(text); -- return type gains id; must drop to recreate

-- ── 2. convert the tenant column, table by table ──────────────────────────
do $$
declare t text; n bigint;
begin
  foreach t in array array[
    'gw_campaigns','gw_client_coverage','gw_competitions','gw_leaderboards',
    'gw_leagues','gw_players','gw_predictions','gw_rounds','gw_subscriptions',
    'gw_workspace_invites','gw_workspace_members'
  ] loop
    execute format('alter table public.%I add column client_id uuid', t);
    execute format('update public.%I t set client_id = c.id from public.gw_customers c where c.client_key = t.client_key', t);
    -- rows whose client_key matches no customer are unreachable garbage
    -- from long-deleted tenants; sweep them (the FK forbids them anyway)
    execute format('delete from public.%I where client_id is null', t);
    get diagnostics n = row_count;
    if n > 0 then raise notice '%: swept % orphan row(s)', t, n; end if;
    execute format('alter table public.%I alter column client_id set not null', t);
    -- dropping the column takes its indexes, PKs and FKs with it
    execute format('alter table public.%I drop column client_key', t);
    execute format('alter table public.%I add constraint %I foreign key (client_id) references public.gw_customers(id) on delete cascade', t, t || '_client_id_fkey');
  end loop;
end $$;

-- ── 3. rebuild the keys and indexes the column drop took ──────────────────
alter table public.gw_client_coverage   add primary key (client_id);
alter table public.gw_workspace_members add primary key (client_id, auth_id);
alter table public.gw_subscriptions     add constraint gw_subscriptions_client_id_key unique (client_id);
-- the old schema had the players uniqueness twice (a constraint and a
-- duplicate index); it comes back once
alter table public.gw_players           add constraint gw_players_unique_username unique (client_id, username);
alter table public.gw_leaderboards      add constraint gw_leaderboards_scope_player_unique unique nulls not distinct (client_id, competition_id, round_id, player_id);
create unique index idx_gw_leagues_code on public.gw_leagues (client_id, code);
create index gw_leaderboards_scope_points_idx on public.gw_leaderboards (client_id, competition_id, round_id, points desc);
create index gw_predictions_client_round_idx  on public.gw_predictions (client_id, round_id);
create index gw_predictions_comp_idx          on public.gw_predictions (client_id, competition_id);
create index gw_competitions_client_idx       on public.gw_competitions (client_id);
create index gw_rounds_client_idx             on public.gw_rounds (client_id);
create index idx_gw_campaigns_client          on public.gw_campaigns (client_id);
create index idx_gw_leagues_client            on public.gw_leagues (client_id);
create index gw_workspace_invites_client_idx  on public.gw_workspace_invites (client_id);

-- ── 4. dead columns on the global dm tables (all-NULL, unreferenced) ──────
alter table public.gw_dm_teams       drop column client_key;
alter table public.gw_dm_events      drop column client_key;
alter table public.gw_dm_tournaments drop column client_key;

-- ── 5. functions, in client_id form ───────────────────────────────────────
create function public.gw_my_client_id()
returns uuid language sql stable security definer set search_path = public as
$$
  select id from public.gw_customers where auth_id = auth.uid() limit 1
$$;

create function public.gw_is_workspace_member(p_client_id uuid)
returns boolean language sql stable security definer set search_path = public as
$$
  select exists (
    select 1 from public.gw_workspace_members m
    where m.auth_id = auth.uid() and m.client_id = p_client_id
  )
$$;

create function public.gw_admin_users_limit(p_client_id uuid)
returns integer language plpgsql stable security definer set search_path = public as
$function$
declare v_plan text; v_raw text;
begin
  select plan into v_plan from public.gw_customers where id = p_client_id limit 1;
  select ("values" ->> coalesce(v_plan, 'free')) into v_raw
    from public.gw_package_settings where setting_key = 'admin_users';
  if v_raw is null or v_raw !~ '^\d+$' then return 0; end if;
  return v_raw::int;
end $function$;

-- Public accessor keeps its key-based contract (the key is what pages have,
-- from their URL) and now returns the customer id so callers can address
-- every tenant table without a second lookup.
create function public.get_customer_public(p_client_key text)
returns table (
  id            uuid,
  client_key    text,
  company_name  text,
  logo_url      text,
  language      text,
  accent_color  text,
  bg_color      text,
  surface_color text,
  text_color    text,
  domains       jsonb
)
language sql stable security definer set search_path = public as
$$
  select id, client_key, company_name, logo_url, language,
         accent_color, bg_color, surface_color, text_color, domains
  from gw_customers
  where client_key = p_client_key
$$;
revoke all on function public.get_customer_public(text) from public;
grant execute on function public.get_customer_public(text) to anon, authenticated, service_role;

-- save_prediction also keeps its key-based contract (cached embeds keep
-- calling it mid-deploy); the key resolves to the id exactly once here.
create or replace function public.save_prediction(p_client_key text, p_competition_id text, p_round_id text, p_event_id text, p_prediction jsonb)
returns void language plpgsql security definer set search_path = public as
$function$
declare
  v_client_id uuid;
  v_player_id uuid;
  v_username text;
  v_kickoff timestamptz;
begin
  select id into v_client_id from gw_customers where client_key = p_client_key;
  if v_client_id is null then
    raise exception 'not_registered';
  end if;

  select id, username into v_player_id, v_username
  from gw_players
  where auth_id = auth.uid() and client_id = v_client_id;
  if v_player_id is null then
    raise exception 'not_registered';
  end if;

  select kickoff_at into v_kickoff
  from gw_dm_events
  where id = gw_try_uuid(p_event_id);
  if v_kickoff is not null and now() >= v_kickoff - interval '30 minutes' then
    raise exception 'locked';
  end if;

  insert into gw_predictions
    (client_id, player_id, username, competition_id, round_id, event_id, prediction)
  values
    (v_client_id, v_player_id, v_username, p_competition_id, p_round_id, p_event_id, p_prediction)
  on conflict (player_id, competition_id, event_id)
  do update set
    prediction   = excluded.prediction,
    round_id     = excluded.round_id,
    username     = excluded.username,
    submitted_at = now();
end;
$function$;

create or replace function public.gw_players_identity_guard()
returns trigger language plpgsql as
$function$
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') then
    return new;
  end if;
  if new.id is distinct from old.id
     or new.auth_id is distinct from old.auth_id
     or new.client_id is distinct from old.client_id
     or new.username is distinct from old.username then
    raise exception 'identity_immutable';
  end if;
  return new;
end;
$function$;

create or replace function public.gw_create_workspace_invite(p_email text)
returns json language plpgsql security definer set search_path = public as
$function$
declare v_client uuid; v_email text; v_limit int; v_used int; v_token text; v_id uuid;
begin
  v_email := lower(trim(coalesce(p_email, '')));
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Enter a valid email address';
  end if;
  v_client := public.gw_my_client_id();
  if v_client is null then
    raise exception 'Only the workspace owner can invite members';
  end if;
  if exists (select 1 from public.gw_workspace_members
             where client_id = v_client and lower(email) = v_email) then
    raise exception 'That person is already a member';
  end if;
  if exists (select 1 from public.gw_workspace_invites
             where client_id = v_client and lower(email) = v_email and accepted_at is null) then
    raise exception 'An invite for that email is already pending';
  end if;

  v_limit := public.gw_admin_users_limit(v_client);
  v_used  := (select count(*) from public.gw_workspace_members where client_id = v_client)
           + (select count(*) from public.gw_workspace_invites where client_id = v_client and accepted_at is null);
  if v_used >= v_limit then
    raise exception 'PACKAGE_LIMIT';
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.gw_workspace_invites (client_id, email, token, invited_by)
    values (v_client, v_email, v_token, auth.uid())
    returning id into v_id;
  return json_build_object('token', v_token, 'invite_id', v_id, 'email', v_email);
end $function$;

create or replace function public.gw_accept_workspace_invite(p_token text)
returns json language plpgsql security definer set search_path = public as
$function$
declare v_inv public.gw_workspace_invites; v_uid uuid; v_email text; v_limit int; v_used int; v_ck text;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'You must be signed in to accept an invite'; end if;

  select * into v_inv from public.gw_workspace_invites
    where token = p_token and accepted_at is null;
  if v_inv.id is null then
    raise exception 'This invite link is invalid or has already been used';
  end if;

  select lower(email) into v_email from auth.users where id = v_uid;
  if v_email is distinct from lower(v_inv.email) then
    raise exception 'This invite was sent to %. Sign up with that email address.', v_inv.email;
  end if;

  v_limit := public.gw_admin_users_limit(v_inv.client_id);
  v_used  := (select count(*) from public.gw_workspace_members where client_id = v_inv.client_id);
  if v_used >= v_limit then
    raise exception 'This workspace has no seats left. Ask the owner to upgrade their package.';
  end if;

  insert into public.gw_workspace_members (client_id, auth_id, email, invited_by)
    values (v_inv.client_id, v_uid, v_inv.email, v_inv.invited_by)
    on conflict (client_id, auth_id) do nothing;
  update public.gw_workspace_invites
    set accepted_at = now(), accepted_by = v_uid
    where id = v_inv.id;
  -- the invite page still expects the key (it lands the member in /admin)
  select client_key into v_ck from public.gw_customers where id = v_inv.client_id;
  return json_build_object('client_key', v_ck);
end $function$;

create or replace function public.gw_workspace_invite_info(p_token text)
returns json language sql stable security definer set search_path = public as
$$
  select json_build_object(
    'valid', (i.accepted_at is null),
    'email', i.email,
    'company_name', o.company_name
  )
  from public.gw_workspace_invites i
  join public.gw_customers o on o.id = i.client_id
  where i.token = p_token
$$;

-- ── 6. policies, in client_id form ────────────────────────────────────────
create policy campaigns_write_own on public.gw_campaigns for all
  using (auth.uid() = (select o.auth_id from public.gw_customers o where o.id = gw_campaigns.client_id limit 1)
         or public.gw_is_workspace_member(client_id))
  with check (auth.uid() = (select o.auth_id from public.gw_customers o where o.id = gw_campaigns.client_id limit 1)
         or public.gw_is_workspace_member(client_id));

create policy coverage_own_read on public.gw_client_coverage for select
  using (client_id in (select o.id from public.gw_customers o where o.auth_id = auth.uid())
         or public.gw_is_workspace_member(client_id));

create policy comps_write_own on public.gw_competitions for all
  using (auth.uid() = (select o.auth_id from public.gw_customers o where o.id = gw_competitions.client_id limit 1)
         or public.gw_is_workspace_member(client_id))
  with check (auth.uid() = (select o.auth_id from public.gw_customers o where o.id = gw_competitions.client_id limit 1)
         or public.gw_is_workspace_member(client_id));

create policy rounds_write_own on public.gw_rounds for all
  using (auth.uid() = (select o.auth_id from public.gw_customers o where o.id = gw_rounds.client_id limit 1)
         or public.gw_is_workspace_member(client_id))
  with check (auth.uid() = (select o.auth_id from public.gw_customers o where o.id = gw_rounds.client_id limit 1)
         or public.gw_is_workspace_member(client_id));

create policy customers_read_own on public.gw_customers for select to authenticated
  using (auth.uid() = auth_id or public.gw_is_workspace_member(id));

create policy customers_update_own on public.gw_customers for update to authenticated
  using (auth.uid() = auth_id or public.gw_is_workspace_member(id))
  with check (auth.uid() = auth_id or public.gw_is_workspace_member(id));

create policy league_members_insert_self on public.gw_league_members for insert to authenticated
  with check (exists (
    select 1 from public.gw_leagues l
    join public.gw_players p on p.client_id = l.client_id
    where l.id = gw_league_members.league_id
      and p.auth_id = auth.uid()
      and p.id = gw_league_members.player_id
      and p.username = gw_league_members.username));

create policy league_members_read on public.gw_league_members for select to authenticated
  using (exists (
    select 1 from public.gw_leagues l
    join public.gw_players p on p.client_id = l.client_id
    where l.id = gw_league_members.league_id and p.auth_id = auth.uid()));

create policy leagues_insert_self on public.gw_leagues for insert to authenticated
  with check (exists (
    select 1 from public.gw_players p
    where p.auth_id = auth.uid() and p.client_id = gw_leagues.client_id
      and p.username = gw_leagues.created_by));

create policy leagues_read on public.gw_leagues for select to authenticated
  using (exists (
    select 1 from public.gw_players p
    where p.auth_id = auth.uid() and p.client_id = gw_leagues.client_id));

create policy players_read_customer on public.gw_players for select to authenticated
  using (client_id in (select o.id from public.gw_customers o where o.auth_id = auth.uid())
         or public.gw_is_workspace_member(client_id));

create policy subscriptions_read_own on public.gw_subscriptions for select
  using (auth.uid() = (select auth_id from public.gw_customers where id = gw_subscriptions.client_id limit 1));

create policy wi_delete_owner on public.gw_workspace_invites for delete to authenticated
  using (accepted_at is null
         and auth.uid() = (select o.auth_id from public.gw_customers o where o.id = gw_workspace_invites.client_id limit 1));

create policy wi_select on public.gw_workspace_invites for select to authenticated
  using (auth.uid() = (select o.auth_id from public.gw_customers o where o.id = gw_workspace_invites.client_id limit 1));

create policy wm_select on public.gw_workspace_members for select to authenticated
  using (auth_id = auth.uid()
         or auth.uid() = (select o.auth_id from public.gw_customers o where o.id = gw_workspace_members.client_id limit 1));

-- ── 7. billing views ──────────────────────────────────────────────────────
-- Recreated on client_id, and SCOPED: the old views ran with owner rights
-- and were granted to anon — one anonymous query dumped every tenant's
-- billing and MAU. Now each caller sees only their own tenant (owner or
-- workspace member; service_role sees all), and anon has no grant at all.
create view public.gw_mau_current as
  select p.client_id,
         c.client_key,
         count(distinct p.player_id) as mau_count,
         date_trunc('month', now()) as period_start
  from public.gw_predictions p
  join public.gw_customers c on c.id = p.client_id
  where date_trunc('month', p.submitted_at) = date_trunc('month', now())
    and (c.auth_id = auth.uid()
         or public.gw_is_workspace_member(p.client_id)
         or auth.role() = 'service_role')
  group by p.client_id, c.client_key;

create view public.gw_billing_current as
  select c.client_key,
         s.client_id,
         s.plan,
         s.flat_fee,
         s.included_mau,
         s.price_per_mau,
         coalesce(m.mau_count, 0::bigint) as mau_count,
         greatest(0::bigint, coalesce(m.mau_count, 0::bigint) - s.included_mau) as billable_mau,
         s.flat_fee + coalesce(m.mau_count, 0::bigint)::numeric * s.price_per_mau as total_due
  from public.gw_subscriptions s
  join public.gw_customers c on c.id = s.client_id
  left join public.gw_mau_current m on m.client_id = s.client_id
  where c.auth_id = auth.uid()
    or public.gw_is_workspace_member(s.client_id)
    or auth.role() = 'service_role';

revoke all on public.gw_mau_current, public.gw_billing_current from public, anon, authenticated;
grant select on public.gw_mau_current, public.gw_billing_current to authenticated, service_role;
