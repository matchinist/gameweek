-- Drop the get_operator_public compat wrapper (owner call, 2026-09-03).
--
-- 20260904010000 kept the old rpc name alive as a wrapper around
-- get_customer_public so embeds served from browser/CDN cache would not
-- lose their theme during the rename rollout. The renamed code has been
-- live since the same evening and nothing in the repo calls the old name;
-- from here on the only public accessor is get_customer_public.
drop function public.get_operator_public(text);
