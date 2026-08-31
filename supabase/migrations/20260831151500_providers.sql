-- Multi-provider registry (owner decision, 2026-08-31): SportMonks is the
-- first data provider but not the last — providers, including their API
-- credentials, are configured dynamically from /data instead of function
-- secrets, and every provider normalises into the same gw_dm_* layer via
-- provider_ids mapping. Cross-provider checking can build on this later
-- (multiple provider_ids per row, per-provider ingest runs).
create table public.gw_providers (
  id         text        not null, -- slug: 'sportmonks'
  name       text        not null,
  token      text,                 -- API credential — see RLS below
  base_url   text,
  enabled    boolean     not null default false,
  config     jsonb,                -- per-provider extras (sports, plan, limits)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint gw_providers_pkey primary key (id)
);

alter table public.gw_providers enable row level security;

-- Tokens are secrets: platform admins get full CRUD (that IS the /data
-- page), the service role reads them for the ingest worker, and nobody
-- else can touch the table — anon has no grant at all.
create policy providers_admin_select on public.gw_providers for select
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
create policy providers_admin_insert on public.gw_providers for insert
  with check (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
create policy providers_admin_update on public.gw_providers for update
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
create policy providers_admin_delete on public.gw_providers for delete
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
revoke all on public.gw_providers from anon, authenticated;
grant select, insert, update, delete on public.gw_providers to authenticated;
grant all on public.gw_providers to service_role;

-- Ingest runs are now per provider.
alter table public.gw_ingest_runs add column if not exists provider text;

-- Seed the first provider (disabled until its token is entered in /data).
insert into public.gw_providers (id, name, enabled)
  values ('sportmonks', 'SportMonks', false)
  on conflict (id) do nothing;

-- Reschedule the cron at the generic worker (was sportmonks-ingest).
DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_cron;
  CREATE EXTENSION IF NOT EXISTS pg_net;
  PERFORM cron.unschedule('sportmonks-ingest')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sportmonks-ingest');
  PERFORM cron.unschedule('data-ingest')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'data-ingest');
  PERFORM cron.schedule(
    'data-ingest',
    '*/5 * * * *',
    $cron$
    SELECT net.http_post(
      url := 'https://mgfzqkesikfdrahherfm.supabase.co/functions/v1/data-ingest',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1nZnpxa2VzaWtmZHJhaGhlcmZtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk0NjA5ODAsImV4cCI6MjA5NTAzNjk4MH0.uzhqaPtsEE-dthbpv1tl6krZj7FidfTblV_7ilcAxFI'
      ),
      body := '{"trigger":"cron"}'::jsonb
    );
    $cron$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron/pg_net unavailable on this host - ingest schedule skipped (replay target, not app schema)';
END $$;
