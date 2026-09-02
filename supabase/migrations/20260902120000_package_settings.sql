-- Package Settings (Data Manager → Package Settings page).
--
-- The platform's pricing packages (Free, Start, Growth, Scale, Enterprise)
-- are presented as COLUMNS and every configurable value is a ROW, so more
-- settings can be added over time without a schema change: one row per
-- setting_key, with the per-package numbers in `values` jsonb
-- ({ "free": 1000, "start": 5000, ... }). First setting is Monthly Active
-- Users; the /data page keys its grid off a PACKAGE_SETTING_DEFS list.
create table public.gw_package_settings (
  setting_key text        not null,                       -- 'monthly_active_users'
  label       text        not null,                       -- 'Monthly Active Users'
  values      jsonb       not null default '{}'::jsonb,    -- package slug -> value
  sort_order  integer     not null default 0,
  updated_at  timestamptz not null default now(),
  constraint gw_package_settings_pkey primary key (setting_key)
);

alter table public.gw_package_settings enable row level security;

-- Platform admins get full CRUD (that IS the Package Settings page); every
-- other signed-in role may read the plan definitions; anon has no grant.
create policy package_settings_admin_all on public.gw_package_settings for all
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
create policy package_settings_read on public.gw_package_settings for select
  to authenticated using (true);

revoke all on public.gw_package_settings from anon, authenticated;
grant select, insert, update, delete on public.gw_package_settings to authenticated;
grant all on public.gw_package_settings to service_role;

-- Seed the first setting so the page renders a row before anything is saved.
insert into public.gw_package_settings (setting_key, label, sort_order, values)
  values ('monthly_active_users', 'Monthly Active Users', 0, '{}'::jsonb)
  on conflict (setting_key) do nothing;
