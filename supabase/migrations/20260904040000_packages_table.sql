-- Pricing packages: EAV settings table → a real gw_packages table (2026-09-04,
-- owner decision).
--
-- gw_package_settings stored packages inside-out: one row per SETTING, every
-- package a key inside a `values` jsonb, and the package itself existing
-- nowhere as a row. gw_customers.plan was a free-text slug with no FK. This
-- makes each package a row in gw_packages with typed columns, points the
-- customer at it by package_id uuid → gw_packages(id) ON DELETE RESTRICT
-- (a package in use can't be deleted out from under its clients), backfills
-- from the jsonb, and drops the EAV table. slug stays as the stable code
-- handle (like client_key on gw_customers) — logic and signup key off it.

create table public.gw_packages (
  id            uuid        primary key default gen_random_uuid(),
  slug          text        not null unique,   -- stable handle: free|start|growth|...
  name          text        not null,          -- display name
  sort_order    integer     not null default 0,
  is_active     boolean     not null default true,
  -- pricing (the package IS the price plan; owner edits these in /data)
  flat_fee      numeric     not null default 0,
  price_per_mau numeric     not null default 0,
  -- limits (null = not configured)
  included_mau     integer,
  tournaments      integer,
  admin_users      integer,
  allowed_domains  integer,
  -- features
  user_analytics text,                          -- 'Basic' | 'Advanced' | null
  sso            boolean not null default false,
  gameweek_logo  boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Seed the five known packages, then pull each value out of the EAV jsonb.
-- A missing key stays null (limits) / false (feature flags), matching how
-- the old grid rendered a blank cell.
insert into public.gw_packages (slug, name, sort_order)
values ('free','Free',0), ('start','Start',1), ('growth','Growth',2),
       ('scale','Scale',3), ('enterprise','Enterprise',4);

update public.gw_packages p set
  included_mau    = nullif(s.v->'monthly_active_users'->>p.slug,'')::int,
  tournaments     = nullif(s.v->'tournaments'->>p.slug,'')::int,
  admin_users     = nullif(s.v->'admin_users'->>p.slug,'')::int,
  allowed_domains = nullif(s.v->'allowed_domains'->>p.slug,'')::int,
  user_analytics  = nullif(s.v->'user_analytics'->>p.slug,''),
  sso             = coalesce((s.v->'sso'->>p.slug) = 'Yes', false),
  gameweek_logo   = coalesce((s.v->'gameweek_logo'->>p.slug) = 'Yes', false)
from (
  select jsonb_object_agg(setting_key, "values") as v from public.gw_package_settings
) s;

-- ── point the customer at the package by uuid FK ──────────────────────────
alter table public.gw_customers add column package_id uuid;
update public.gw_customers c
  set package_id = p.id from public.gw_packages p where p.slug = c.plan;
-- any customer whose plan slug matched nothing lands on free (defensive; live
-- data is all 'free' today)
update public.gw_customers c
  set package_id = (select id from public.gw_packages where slug='free')
  where package_id is null;
alter table public.gw_customers alter column package_id set not null;
alter table public.gw_customers
  add constraint gw_customers_package_id_fkey
  foreign key (package_id) references public.gw_packages(id) on delete restrict;
create index gw_customers_package_id_idx on public.gw_customers (package_id);

-- New customers with no package fall onto the default package (lowest active
-- sort_order — free) so signup code never has to look one up. A BEFORE INSERT
-- trigger satisfies the NOT NULL without a subquery default.
create function public.gw_customers_default_package()
returns trigger language plpgsql as
$$
begin
  if new.package_id is null then
    select id into new.package_id from public.gw_packages
      where is_active order by sort_order, slug limit 1;
  end if;
  return new;
end $$;
create trigger gw_customers_default_package_trg
  before insert on public.gw_customers
  for each row execute function public.gw_customers_default_package();

alter table public.gw_customers drop column plan;

-- The admin-seat limit now reads the package's column instead of the jsonb.
create or replace function public.gw_admin_users_limit(p_client_id uuid)
returns integer language sql stable security definer set search_path = public as
$$
  select coalesce(p.admin_users, 0)
  from public.gw_customers c
  join public.gw_packages p on p.id = c.package_id
  where c.id = p_client_id
$$;

-- ── RLS: platform admins CRUD, any signed-in user reads, anon nothing ─────
alter table public.gw_packages enable row level security;
create policy packages_admin_all on public.gw_packages for all
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
create policy packages_read on public.gw_packages for select
  to authenticated using (true);
revoke all on public.gw_packages from anon, authenticated;
grant select, insert, update, delete on public.gw_packages to authenticated;
grant all on public.gw_packages to service_role;

drop table public.gw_package_settings;
