-- Rename "operator" → "customer" across the schema (2026-09-03, owner decision).
--
-- Views, policies and constraints reference the table by OID, so they follow
-- the rename automatically — only their NAMES keep saying "operator", which
-- is renamed below for consistency. Function bodies do NOT follow: they are
-- stored as text and would keep querying the vanished gw_operators, so every
-- function the live catalog showed with gw_operators in its body
-- (gw_my_client_key, gw_admin_users_limit, gw_workspace_invite_info,
-- get_operator_public) is recreated here against gw_customers.

alter table public.gw_operators rename to gw_customers;
alter view  public.gw_operators_public rename to gw_customers_public;

alter table public.gw_customers rename constraint gw_operators_pkey to gw_customers_pkey;
alter table public.gw_customers rename constraint gw_operators_email_key to gw_customers_email_key;
alter table public.gw_customers rename constraint gw_operators_client_key_key to gw_customers_client_key_key;
alter table public.gw_customers rename constraint gw_operators_auth_id_fkey to gw_customers_auth_id_fkey;
alter index public.gw_operators_auth_id_idx rename to gw_customers_auth_id_idx;

alter policy operators_insert       on public.gw_customers rename to customers_insert;
alter policy operators_read_own     on public.gw_customers rename to customers_read_own;
alter policy operators_update_own   on public.gw_customers rename to customers_update_own;
alter policy operators_read_admin   on public.gw_customers rename to customers_read_admin;
alter policy operators_update_admin on public.gw_customers rename to customers_update_admin;
alter policy players_read_operator  on public.gw_players   rename to players_read_customer;

create or replace function public.gw_my_client_key()
returns text language sql stable security definer set search_path = public as
$$
  select client_key from public.gw_customers where auth_id = auth.uid() limit 1
$$;

create or replace function public.gw_admin_users_limit(p_client_key text)
returns integer language plpgsql stable security definer set search_path = public as
$function$
declare v_plan text; v_raw text;
begin
  select plan into v_plan from public.gw_customers where client_key = p_client_key limit 1;
  select ("values" ->> coalesce(v_plan, 'free')) into v_raw
    from public.gw_package_settings where setting_key = 'admin_users';
  if v_raw is null or v_raw !~ '^\d+$' then return 0; end if;
  return v_raw::int;
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
  join public.gw_customers o on o.client_key = i.client_key
  where i.token = p_token
$$;

-- The renamed public accessor (single-row, enumeration-hardened — see
-- 20260904003000). Same nine safe columns as before.
create or replace function public.get_customer_public(p_client_key text)
returns table (
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
  select client_key, company_name, logo_url, language,
         accent_color, bg_color, surface_color, text_color, domains
  from gw_customers
  where client_key = p_client_key
$$;

revoke all on function public.get_customer_public(text) from public;
grant execute on function public.get_customer_public(text) to anon, authenticated, service_role;

-- Compatibility wrapper: embeds served from browser/CDN cache keep calling
-- the old name for a while after the rename ships. Drop once cached pages
-- have aged out.
create or replace function public.get_operator_public(p_client_key text)
returns table (
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
  select * from public.get_customer_public(p_client_key)
$$;
