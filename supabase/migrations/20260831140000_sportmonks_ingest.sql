-- SportMonks ingest foundations (owner-initiated, 2026-08-31).
--
-- The feed pipeline: pg_cron (inside this database) POSTs to the
-- sportmonks-ingest Edge Function every 5 minutes; the function syncs
-- kickoffs/results for MAPPED events only and chains score-round for every
-- affected round. Manual runs come from /data's Ingest page. Every
-- iteration — cron or manual, success or failure — lands here.

-- ── audit trail ─────────────────────────────────────────────────────────────
create table public.gw_ingest_runs (
  id             uuid        not null default gen_random_uuid(),
  run_at         timestamptz not null default now(),
  trigger_source text        not null, -- 'cron' | 'manual'
  initiated_by   text,                 -- admin email for manual runs, null for cron
  ok             boolean     not null default false,
  duration_ms    integer,
  -- counters: {events_mapped, fixtures_checked, results_updated,
  --            kickoffs_updated, rounds_scored, ...} — jsonb so the adapter
  -- can grow fields without migrations
  stats          jsonb,
  -- per-entity detail lines for the log page: [{level, msg}, ...]
  log            jsonb,
  error          text,
  constraint gw_ingest_runs_pkey primary key (id)
);

create index gw_ingest_runs_time_idx on public.gw_ingest_runs (run_at desc);

alter table public.gw_ingest_runs enable row level security;

-- Same posture as gw_score_runs: admins read, only the service role writes,
-- anon has no SELECT grant at all.
create policy ingest_runs_admin_read on public.gw_ingest_runs
  for select using (
    exists (select 1 from public.gw_admins a where a.auth_id = auth.uid())
  );
revoke all on public.gw_ingest_runs from anon, authenticated;
grant select on public.gw_ingest_runs to authenticated;
grant all on public.gw_ingest_runs to service_role;

-- ── provider id mapping ─────────────────────────────────────────────────────
-- {"sportmonks": <id>} — provider-agnostic on purpose. The feed may ONLY
-- touch rows an admin explicitly mapped; unmapped rows are invisible to it,
-- which is what keeps the hand-curated database safe from the feed.
alter table public.gw_dm_teams       add column if not exists provider_ids jsonb;
alter table public.gw_dm_events      add column if not exists provider_ids jsonb;
alter table public.gw_dm_players     add column if not exists provider_ids jsonb;
alter table public.gw_dm_tournaments add column if not exists provider_ids jsonb;

-- ── per-language display-name overrides ─────────────────────────────────────
-- {"tr": "...", "de": "...", "pt": "..."} — canonical `name` stays the
-- English/base name. Consumption in the embed follows the leaderboard
-- cutover (client-side ranking still matches teams BY NAME until then, so
-- localizing rendered names before the cutover would break it).
alter table public.gw_dm_teams       add column if not exists name_i18n jsonb;
alter table public.gw_dm_tournaments add column if not exists name_i18n jsonb;
alter table public.gw_dm_players     add column if not exists name_i18n jsonb;

-- ── schedule ────────────────────────────────────────────────────────────────
-- pg_cron + pg_net exist on Supabase but not on a plain replay target —
-- skip gracefully there (same pattern as the baseline's index-advisor
-- guard). The anon key in the header is the PUBLIC key already hardcoded
-- in every page of the site; the function itself decides what a cron
-- trigger may do (rate-limited, no key → silent no-op).
DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_cron;
  CREATE EXTENSION IF NOT EXISTS pg_net;
  PERFORM cron.unschedule('sportmonks-ingest')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sportmonks-ingest');
  PERFORM cron.schedule(
    'sportmonks-ingest',
    '*/5 * * * *',
    $cron$
    SELECT net.http_post(
      url := 'https://mgfzqkesikfdrahherfm.supabase.co/functions/v1/sportmonks-ingest',
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
