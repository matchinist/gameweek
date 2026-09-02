-- Client packages.
--
-- Repurposes the (previously unused) gw_operators.plan column as the pricing
-- package slug: 'free' | 'start' | 'growth' | 'scale' | 'enterprise' — the
-- same five packages defined on Data Manager → Package Settings.
--
-- The Data Manager Clients page now assigns a package per client via a
-- dropdown (replacing the old free-access / subscription-required toggle),
-- and the client admin's Subscription page shows the assigned package name
-- plus each per-setting value from gw_package_settings.

alter table public.gw_operators alter column plan set default 'free';

-- Move every existing client onto the Free package.
update public.gw_operators
  set plan = 'free'
  where plan is null
     or plan not in ('free', 'start', 'growth', 'scale', 'enterprise');

-- Keep the (currently unused) access gate consistent with the package:
-- Free = no subscription required, any paid package = required.
update public.gw_operators
  set subscription_required = (plan <> 'free');

comment on column public.gw_operators.plan is
  'Pricing package slug: free | start | growth | scale | enterprise. Assigned in Data Manager -> Clients; limits come from gw_package_settings.';
