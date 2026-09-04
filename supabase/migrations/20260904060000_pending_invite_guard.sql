-- Pending-invite login guard (2026-09-04).
--
-- An invited person who signs into /admin directly (without their invite
-- link) used to fall through to the auto-create branch and get a fresh
-- workspace of their own — which then SHADOWS the membership forever,
-- because the login bootstrap finds a customer row by auth_id before it
-- ever checks gw_workspace_members. The bootstrap needs to know "this
-- email has a pending invite" before creating anything, but RLS
-- (correctly) lets only the workspace owner read invites — hence this
-- definer rpc: it reveals to a signed-in user only their OWN pending
-- invite (matched on their verified auth email), and only the inviting
-- company's name, never the token.
create function public.gw_my_pending_invite()
returns json language sql stable security definer set search_path = public as
$$
  select json_build_object('company_name', o.company_name, 'email', i.email)
  from public.gw_workspace_invites i
  join public.gw_customers o on o.id = i.client_id
  join auth.users u on lower(u.email) = lower(i.email)
  where u.id = auth.uid() and i.accepted_at is null
  order by i.created_at desc
  limit 1
$$;

revoke all on function public.gw_my_pending_invite() from public;
grant execute on function public.gw_my_pending_invite() to authenticated, service_role;
