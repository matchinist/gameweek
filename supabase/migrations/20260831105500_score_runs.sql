-- Scoring audit log (owner request, 2026-08-31): one row per score-round
-- invocation, written ONLY by the Edge Function's service role so the trail
-- can't be forged or skipped from a browser. Backs the /data "Scoring Log"
-- page: who initiated, when, how long, which tenant/scope, rows affected,
-- and the error text when a run failed.
create table public.gw_score_runs (
  id                  uuid        not null default gen_random_uuid(),
  run_at              timestamptz not null default now(),
  initiated_by        text        not null, -- admin email from the verified JWT
  client_key          text        not null,
  competition_id      text        not null,
  round_id            text        not null,
  mode                text,
  duration_ms         integer,
  predictions_scored  integer,
  predictions_updated integer,
  round_rows          integer,
  overall_rows        integer,
  ok                  boolean     not null default false,
  error               text,
  constraint gw_score_runs_pkey primary key (id)
);

-- The log page reads newest-first.
create index gw_score_runs_time_idx on public.gw_score_runs (run_at desc);

alter table public.gw_score_runs enable row level security;

-- Platform admins only — the log names operator tenants and admin emails,
-- so unlike gw_leaderboards it is NOT public. anon gets no SELECT grant at
-- all; a signed-in non-admin passes the grant but the policy yields nothing.
create policy score_runs_admin_read on public.gw_score_runs
  for select using (
    exists (select 1 from public.gw_admins a where a.auth_id = auth.uid())
  );

-- Writes: service role only, grant-enforced like gw_leaderboards (C-1
-- pattern — no write policy exists to get wrong).
revoke all on public.gw_score_runs from anon, authenticated;
grant select on public.gw_score_runs to authenticated;
grant all on public.gw_score_runs to service_role;
