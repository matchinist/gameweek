-- Workspace members — let a client-admin workspace (a gw_operators row,
-- identified by client_key) have more than one admin user.
--
-- Model: the owner's gw_operators row stays the single workspace identity.
-- Extra people are rows in gw_workspace_members (auth_id -> client_key). The
-- write RLS policies on the workspace tables are widened to also accept a
-- matching member row, so a member has the same admin privileges as the
-- owner "for now" (per product decision). All member mutations go through
-- SECURITY DEFINER RPCs (invite / accept) or the remove-workspace-member
-- Edge Function (service role) — never a direct client write.
--
-- Seat limit: the "admin_users" row of gw_package_settings, indexed by the
-- workspace's package (gw_operators.plan) = how many members the owner may
-- add. Enforced in the RPCs; the admin UI mirrors it and prompts to upgrade.

-- ── tables ────────────────────────────────────────────────────────────────
create table public.gw_workspace_members (
  client_key  text        not null references public.gw_operators(client_key) on delete cascade,
  auth_id     uuid        not null references auth.users(id) on delete cascade,
  email       text        not null,
  invited_by  uuid,
  created_at  timestamptz not null default now(),
  primary key (client_key, auth_id)
);
create index gw_workspace_members_auth_idx on public.gw_workspace_members (auth_id);

create table public.gw_workspace_invites (
  id          uuid        primary key default gen_random_uuid(),
  client_key  text        not null references public.gw_operators(client_key) on delete cascade,
  email       text        not null,
  token       text        not null unique,
  invited_by  uuid,
  created_at  timestamptz not null default now(),
  accepted_at timestamptz,
  accepted_by uuid
);
create index gw_workspace_invites_client_idx on public.gw_workspace_invites (client_key);
create index gw_workspace_invites_token_idx  on public.gw_workspace_invites (token);

alter table public.gw_workspace_members enable row level security;
alter table public.gw_workspace_invites enable row level security;

-- ── helpers ───────────────────────────────────────────────────────────────
-- SECURITY DEFINER so RLS policies can call it without recursing into
-- gw_workspace_members' own policy.
create or replace function public.gw_is_workspace_member(p_client_key text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.gw_workspace_members m
    where m.auth_id = auth.uid() and m.client_key = p_client_key
  )
$$;

create or replace function public.gw_my_client_key()
returns text language sql stable security definer set search_path = public as $$
  select client_key from public.gw_operators where auth_id = auth.uid() limit 1
$$;

-- How many members the workspace's package allows (0 when unset).
create or replace function public.gw_admin_users_limit(p_client_key text)
returns integer language plpgsql stable security definer set search_path = public as $$
declare v_plan text; v_raw text;
begin
  select plan into v_plan from public.gw_operators where client_key = p_client_key limit 1;
  select ("values" ->> coalesce(v_plan, 'free')) into v_raw
    from public.gw_package_settings where setting_key = 'admin_users';
  if v_raw is null or v_raw !~ '^\d+$' then return 0; end if;
  return v_raw::int;
end $$;

-- ── RPCs ──────────────────────────────────────────────────────────────────
create or replace function public.gw_create_workspace_invite(p_email text)
returns json language plpgsql security definer set search_path = public as $$
declare v_client text; v_email text; v_limit int; v_used int; v_token text; v_id uuid;
begin
  v_email := lower(trim(coalesce(p_email, '')));
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Enter a valid email address';
  end if;
  v_client := public.gw_my_client_key();
  if v_client is null then
    raise exception 'Only the workspace owner can invite members';
  end if;
  if exists (select 1 from public.gw_workspace_members
             where client_key = v_client and lower(email) = v_email) then
    raise exception 'That person is already a member';
  end if;
  if exists (select 1 from public.gw_workspace_invites
             where client_key = v_client and lower(email) = v_email and accepted_at is null) then
    raise exception 'An invite for that email is already pending';
  end if;

  v_limit := public.gw_admin_users_limit(v_client);
  v_used  := (select count(*) from public.gw_workspace_members where client_key = v_client)
           + (select count(*) from public.gw_workspace_invites where client_key = v_client and accepted_at is null);
  if v_used >= v_limit then
    raise exception 'PACKAGE_LIMIT';   -- the admin UI turns this into an upgrade prompt
  end if;

  v_token := encode(gen_random_bytes(24), 'hex');
  insert into public.gw_workspace_invites (client_key, email, token, invited_by)
    values (v_client, v_email, v_token, auth.uid())
    returning id into v_id;
  return json_build_object('token', v_token, 'invite_id', v_id, 'email', v_email);
end $$;

-- Anon-callable: the /invite page shows the workspace name before sign-up.
create or replace function public.gw_workspace_invite_info(p_token text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'valid', (i.accepted_at is null),
    'email', i.email,
    'company_name', o.company_name
  )
  from public.gw_workspace_invites i
  join public.gw_operators o on o.client_key = i.client_key
  where i.token = p_token
$$;

create or replace function public.gw_accept_workspace_invite(p_token text)
returns json language plpgsql security definer set search_path = public as $$
declare v_inv public.gw_workspace_invites; v_uid uuid; v_email text; v_limit int; v_used int;
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

  v_limit := public.gw_admin_users_limit(v_inv.client_key);
  v_used  := (select count(*) from public.gw_workspace_members where client_key = v_inv.client_key);
  if v_used >= v_limit then
    raise exception 'This workspace has no seats left. Ask the owner to upgrade their package.';
  end if;

  insert into public.gw_workspace_members (client_key, auth_id, email, invited_by)
    values (v_inv.client_key, v_uid, v_inv.email, v_inv.invited_by)
    on conflict (client_key, auth_id) do nothing;
  update public.gw_workspace_invites
    set accepted_at = now(), accepted_by = v_uid
    where id = v_inv.id;
  return json_build_object('client_key', v_inv.client_key);
end $$;

-- ── RLS on the new tables (reads only; writes via RPC / Edge Function) ─────
create policy wm_select on public.gw_workspace_members for select to authenticated
  using (
    auth_id = auth.uid()
    or auth.uid() = (select o.auth_id from public.gw_operators o
                     where o.client_key = gw_workspace_members.client_key limit 1)
  );

create policy wi_select on public.gw_workspace_invites for select to authenticated
  using (
    auth.uid() = (select o.auth_id from public.gw_operators o
                  where o.client_key = gw_workspace_invites.client_key limit 1)
  );
-- The owner may cancel a not-yet-accepted invite.
create policy wi_delete_owner on public.gw_workspace_invites for delete to authenticated
  using (
    accepted_at is null
    and auth.uid() = (select o.auth_id from public.gw_operators o
                      where o.client_key = gw_workspace_invites.client_key limit 1)
  );

revoke all on public.gw_workspace_members, public.gw_workspace_invites from anon;
grant select on public.gw_workspace_members to authenticated;
grant select, delete on public.gw_workspace_invites to authenticated;
grant all on public.gw_workspace_members, public.gw_workspace_invites to service_role;

grant execute on function public.gw_is_workspace_member(text)      to authenticated;
grant execute on function public.gw_my_client_key()                to authenticated;
grant execute on function public.gw_admin_users_limit(text)        to authenticated;
grant execute on function public.gw_create_workspace_invite(text)  to authenticated;
grant execute on function public.gw_accept_workspace_invite(text)  to authenticated;
grant execute on function public.gw_workspace_invite_info(text)    to anon, authenticated;

-- ── widen the workspace write/read policies to accept a member ────────────
drop policy if exists comps_write_own on public.gw_competitions;
create policy comps_write_own on public.gw_competitions for all to public
  using (
    auth.uid() = (select o.auth_id from public.gw_operators o where o.client_key = gw_competitions.client_key limit 1)
    or public.gw_is_workspace_member(gw_competitions.client_key)
  )
  with check (
    auth.uid() = (select o.auth_id from public.gw_operators o where o.client_key = gw_competitions.client_key limit 1)
    or public.gw_is_workspace_member(gw_competitions.client_key)
  );

drop policy if exists rounds_write_own on public.gw_rounds;
create policy rounds_write_own on public.gw_rounds for all to public
  using (
    auth.uid() = (select o.auth_id from public.gw_operators o where o.client_key = gw_rounds.client_key limit 1)
    or public.gw_is_workspace_member(gw_rounds.client_key)
  )
  with check (
    auth.uid() = (select o.auth_id from public.gw_operators o where o.client_key = gw_rounds.client_key limit 1)
    or public.gw_is_workspace_member(gw_rounds.client_key)
  );

drop policy if exists campaigns_write_own on public.gw_campaigns;
create policy campaigns_write_own on public.gw_campaigns for all to public
  using (
    auth.uid() = (select o.auth_id from public.gw_operators o where o.client_key = gw_campaigns.client_key limit 1)
    or public.gw_is_workspace_member(gw_campaigns.client_key)
  )
  with check (
    auth.uid() = (select o.auth_id from public.gw_operators o where o.client_key = gw_campaigns.client_key limit 1)
    or public.gw_is_workspace_member(gw_campaigns.client_key)
  );

drop policy if exists coverage_own_read on public.gw_client_coverage;
create policy coverage_own_read on public.gw_client_coverage for select to public
  using (
    client_key = (select o.client_key from public.gw_operators o where o.auth_id = auth.uid())
    or public.gw_is_workspace_member(gw_client_coverage.client_key)
  );

drop policy if exists players_read_operator on public.gw_players;
create policy players_read_operator on public.gw_players for select to authenticated
  using (
    client_key in (select o.client_key from public.gw_operators o where o.auth_id = auth.uid())
    or public.gw_is_workspace_member(gw_players.client_key)
  );

drop policy if exists operators_read_own on public.gw_operators;
create policy operators_read_own on public.gw_operators for select to authenticated
  using ( auth.uid() = auth_id or public.gw_is_workspace_member(client_key) );

drop policy if exists operators_update_own on public.gw_operators;
create policy operators_update_own on public.gw_operators for update to authenticated
  using ( auth.uid() = auth_id or public.gw_is_workspace_member(client_key) )
  with check ( auth.uid() = auth_id or public.gw_is_workspace_member(client_key) );
