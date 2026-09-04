-- Optional price display text on a package (2026-09-04).
--
-- Some packages should show a phrase instead of a computed price — e.g.
-- Enterprise as "Get in Touch" rather than a number. price_text is a pure
-- DISPLAY override: null (the default) means "show the numeric price";
-- flat_fee / price_per_mau stay the real billing numbers regardless.
alter table public.gw_packages add column price_text text;

comment on column public.gw_packages.price_text is
  'Optional display override for the price (e.g. "Get in Touch"). Null = show the numeric price. Does not affect billing math.';
