-- Per-competition widget theme.
--
-- The operator-level widget theme (gw_operators.accent_color / bg_color /
-- surface_color / text_color, set on the client admin's Customisation page)
-- is the default for every competition. These four nullable columns let a
-- competition carry its own override; the embed uses them ONLY when it is
-- scoped to exactly one competition (?comp=<single id>). NULL = inherit the
-- operator's global colour for that slot.
alter table public.gw_competitions
  add column if not exists accent_color  text,
  add column if not exists bg_color      text,
  add column if not exists surface_color text,
  add column if not exists text_color    text;

comment on column public.gw_competitions.accent_color is
  'Per-competition widget accent override (NULL = inherit gw_operators.accent_color). Applied by the embed only when scoped to this single competition.';
