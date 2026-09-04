-- Pricing-sheet fields on gw_packages (2026-09-04, owner's pricing sheet).
--
-- The owner's Pricing & Packages sheet carries more per-package facts than
-- the table did: a positioning blurb, the game-library tier, language and
-- customisation tiers, widget tier, sponsor slots, data import, the support
-- tier, and four add-on prices. All DISPLAY/config — billing math stays
-- flat_fee + price_per_mau. Values are seeded from the sheet for the five
-- known slugs (new columns only — numbers the owner already manages in
-- /data, like fees and seat counts, are not touched). Add-on prices are
-- numeric and nullable: null renders as "—"; "All Included" / "Custom
-- Volume" on the sheet are display derivations for packages whose base
-- limit is already unlimited, not stored values.
alter table public.gw_packages
  add column description      text,     -- "best fit for" blurb
  add column games            text,     -- game-library tier
  add column languages        integer,  -- 999 = unlimited (grid convention)
  add column customisation    text,
  add column widgets          text,
  add column sponsor_slots    boolean not null default false,
  add column import_migration boolean not null default false,
  add column support          text,
  add column addon_tournament numeric,  -- $ per extra tournament
  add column addon_domain     numeric,  -- $ per extra domain
  add column addon_mau_1000   numeric,  -- $ per extra 1,000 MAU
  add column addon_language   numeric;  -- $ per extra language

update public.gw_packages set
  description      = 'Clubs, blogs and community sites getting started. Grassroots and amateur clubs, fan sites, podcasts and newsletters running a single competition for a small audience.',
  games            = '1 Core Game of your choice',
  languages        = 1,
  customisation    = 'No – Default theme',
  widgets          = 'Basic – Fixture, Standings',
  sponsor_slots    = false,
  import_migration = false,
  support          = 'Email, best-effort response',
  user_analytics   = 'Basic Monthly Report'
where slug = 'free';

update public.gw_packages set
  name             = 'Starter', -- the sheet's name; the row was seeded as "Start"
  description      = 'Single-title publishers and clubs with a regular season audience. Local and regional news sites, semi-pro clubs, small federations and sports media brands running one competition at a time.',
  games            = 'any 2 Core Games',
  languages        = 1,
  customisation    = 'Limited – Colour settings',
  widgets          = 'Basic – Fixture, Standings',
  sponsor_slots    = false,
  import_migration = true,
  support          = 'Email, 1-day response SLA',
  user_analytics   = 'Basic + Export CSV',
  addon_tournament = 69, addon_domain = 99, addon_mau_1000 = 120, addon_language = 69
where slug = 'start';

update public.gw_packages set
  description      = 'National sports media and professional clubs. Established sports publishers, clubs and federations running several competitions across a season, usually with a commercial partner attached.',
  games            = 'Core Game Library Access',
  languages        = 3,
  customisation    = 'Yes – Custom CSS',
  widgets          = 'Advanced – Top Scorers & Squad Analytics',
  sponsor_slots    = true,
  import_migration = true,
  support          = 'Shared Slack channel',
  user_analytics   = 'Advanced Console',
  addon_tournament = 49, addon_domain = 75, addon_mau_1000 = 60, addon_language = 49
where slug = 'growth';

update public.gw_packages set
  description      = 'Publishers operating at national audience scale. Multi-brand media groups, leagues and streaming platforms running year-round competitions across several properties.',
  games            = 'Premium Game Library Access',
  languages        = 10,
  customisation    = 'Yes – Custom Design',
  widgets          = 'Advanced – Top Scorers & Squad Analytics',
  sponsor_slots    = true,
  import_migration = true,
  support          = '1-hour response SLA + CSM',
  user_analytics   = 'Advanced Console',
  addon_tournament = null, addon_domain = 50, addon_mau_1000 = 40, addon_language = 25
where slug = 'scale';

update public.gw_packages set
  description      = 'Broadcasters, publishing groups and governing bodies. Multi-title media groups, leagues, OTT platforms and rights holders operating across markets, languages and brands.',
  games            = 'Premium Game Library Access',
  languages        = 999,
  customisation    = 'Yes – Custom Design',
  widgets          = 'Advanced – Top Scorers & Squad Analytics',
  sponsor_slots    = true,
  import_migration = true,
  support          = '1-hour response SLA + CSM',
  user_analytics   = 'Advanced Console'
where slug = 'enterprise';
