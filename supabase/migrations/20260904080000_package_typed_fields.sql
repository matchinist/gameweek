-- Typed package fields replacing the display-text columns (2026-09-04,
-- owner review of 20260904070000).
--
-- The sheet fields went in as free text, which reads fine but can't be
-- ACTED on — nothing can gate a feature on "Yes – Custom CSS". Redesign:
--   * games        → core_games / premium_games smallint (null = no access,
--                    999 = full library, matching the grid's unlimited
--                    convention on other limits)
--   * widgets      → basic_widgets / advanced_widgets boolean
--   * analytics    → gw_analytics_tier enum ('basic'|'advanced', null = none)
--                    + monthly_report boolean (a deliverable, not a tier)
--   * customisation→ gw_customisation_options lookup, FK'd by id — the data
--                    admin defines the vocabulary, packages reference it
--   * support      → gw_support_tiers lookup with typed capabilities
--                    (email, response_sla hours — null = best effort,
--                    shared_channel, csm), FK'd by id
--   * description  → dropped; "best fit for" is marketing copy, not data
-- Lookups are ON DELETE RESTRICT (an option in use can't vanish) and carry
-- the same RLS posture as gw_packages: platform admins write, any signed-in
-- user reads (the admin billing card resolves the labels), anon nothing.

create type public.gw_analytics_tier as enum ('basic','advanced');

create table public.gw_customisation_options (
  id         uuid        primary key default gen_random_uuid(),
  name       text        not null unique,
  sort_order integer     not null default 0,
  created_at timestamptz not null default now()
);

create table public.gw_support_tiers (
  id             uuid        primary key default gen_random_uuid(),
  name           text        not null unique,
  email          boolean     not null default true,
  response_sla   smallint,   -- hours; null = best effort
  shared_channel boolean     not null default false,
  csm            boolean     not null default false,
  sort_order     integer     not null default 0,
  created_at     timestamptz not null default now()
);

alter table public.gw_customisation_options enable row level security;
alter table public.gw_support_tiers         enable row level security;
create policy custopts_admin_all on public.gw_customisation_options for all
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
create policy custopts_read on public.gw_customisation_options for select
  to authenticated using (true);
create policy support_tiers_admin_all on public.gw_support_tiers for all
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
create policy support_tiers_read on public.gw_support_tiers for select
  to authenticated using (true);
revoke all on public.gw_customisation_options, public.gw_support_tiers from anon, authenticated;
grant select, insert, update, delete on public.gw_customisation_options, public.gw_support_tiers to authenticated;
grant all on public.gw_customisation_options, public.gw_support_tiers to service_role;

insert into public.gw_customisation_options (name, sort_order) values
  ('No – Default theme', 0),
  ('Limited – Colour settings', 1),
  ('Yes – Custom CSS', 2),
  ('Yes – Custom Design', 3);

insert into public.gw_support_tiers (name, email, response_sla, shared_channel, csm, sort_order) values
  ('Email — best effort', true, null, false, false, 0),
  ('Email — 1-day SLA',   true, 24,   false, false, 1),
  ('Shared Slack channel',true, null, true,  false, 2),
  ('1-hour SLA + CSM',    true, 1,    true,  true,  3);

alter table public.gw_packages
  add column core_games       smallint,
  add column premium_games    smallint,
  add column basic_widgets    boolean not null default false,
  add column advanced_widgets boolean not null default false,
  add column analytics        public.gw_analytics_tier,
  add column monthly_report   boolean not null default false,
  add column customisation_id uuid references public.gw_customisation_options(id) on delete restrict,
  add column support_id       uuid references public.gw_support_tiers(id) on delete restrict;

comment on column public.gw_packages.core_games is
  'Number of core games included; null = none, 999 = full core library.';
comment on column public.gw_packages.premium_games is
  'Number of premium games included; null = none, 999 = full premium library.';

-- Sheet mapping onto the typed fields, per slug.
update public.gw_packages set
  core_games = 1, basic_widgets = true,
  analytics = 'basic', monthly_report = true,
  customisation_id = (select id from public.gw_customisation_options where name = 'No – Default theme'),
  support_id       = (select id from public.gw_support_tiers where name = 'Email — best effort')
where slug = 'free';

update public.gw_packages set
  core_games = 2, basic_widgets = true,
  analytics = 'basic',
  customisation_id = (select id from public.gw_customisation_options where name = 'Limited – Colour settings'),
  support_id       = (select id from public.gw_support_tiers where name = 'Email — 1-day SLA')
where slug = 'start';

update public.gw_packages set
  core_games = 999, basic_widgets = true, advanced_widgets = true,
  analytics = 'advanced',
  customisation_id = (select id from public.gw_customisation_options where name = 'Yes – Custom CSS'),
  support_id       = (select id from public.gw_support_tiers where name = 'Shared Slack channel')
where slug = 'growth';

update public.gw_packages set
  core_games = 999, premium_games = 999, basic_widgets = true, advanced_widgets = true,
  analytics = 'advanced',
  customisation_id = (select id from public.gw_customisation_options where name = 'Yes – Custom Design'),
  support_id       = (select id from public.gw_support_tiers where name = '1-hour SLA + CSM')
where slug in ('scale', 'enterprise');

alter table public.gw_packages
  drop column description,
  drop column games,
  drop column customisation,
  drop column widgets,
  drop column support,
  drop column user_analytics;
