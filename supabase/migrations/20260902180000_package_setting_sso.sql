-- Add the "SSO" package setting (Data Manager -> Package Settings).
--
-- A Yes / No pick per package (blank = not set). Values are assigned in the
-- UI; this just seeds an empty row so a fresh `select *` returns it.
insert into public.gw_package_settings (setting_key, label, sort_order, values)
  values ('sso', 'SSO', 2, '{}'::jsonb)
  on conflict (setting_key) do nothing;
