-- Operator-public enumeration hardening (2026-09-03).
--
-- gw_operators_public exposed the right nine columns but as an OPEN view:
-- one anon query dumped the entire operator roster (the customer list, with
-- branding and domains). Public consumers only ever need ONE tenant's row,
-- and they always already know its client_key (it's in the embed URL) — so
-- the public surface becomes a single-row accessor and the view keeps
-- serving only privileged roles.
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
  select client_key, company_name, logo_url, language,
         accent_color, bg_color, surface_color, text_color, domains
  from gw_operators
  where client_key = p_client_key
$$;

revoke all on function public.get_operator_public(text) from public;
grant execute on function public.get_operator_public(text) to anon, authenticated, service_role;

-- The view stays for privileged tooling; browsers lose it.
revoke select on public.gw_operators_public from anon, authenticated;
