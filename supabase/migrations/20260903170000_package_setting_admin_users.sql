-- Add the "Admin Users" package setting (Data Manager -> Package Settings).
--
-- A per-package number (blank = not set). Values are assigned in the UI;
-- this just seeds an empty row so a fresh `select *` returns it.
insert into public.gw_package_settings (setting_key, label, sort_order, values)
  values ('admin_users', 'Admin Users', 2, '{}'::jsonb)
  on conflict (setting_key) do nothing;
