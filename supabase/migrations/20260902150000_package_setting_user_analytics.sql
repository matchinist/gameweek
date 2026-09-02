-- Add the "User Analytics" package setting (Data Manager -> Package Settings).
--
-- Unlike Monthly Active Users this one is a pick, not a number: each package
-- gets Basic, Advanced, or left blank. Values are assigned in the UI; this
-- just seeds an empty row so a fresh `select *` returns it.
insert into public.gw_package_settings (setting_key, label, sort_order, values)
  values ('user_analytics', 'User Analytics', 1, '{}'::jsonb)
  on conflict (setting_key) do nothing;
