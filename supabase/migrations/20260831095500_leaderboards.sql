-- Phase 3.1 — server-side scoring storage.
--
-- gw_predictions.points: per-prediction score written by the score-round
-- Edge Function (service role). NULL = not yet scored, so the shadow-compare
-- release can tell "scored as 0" apart from "never scored".
alter table public.gw_predictions add column if not exists points integer;

-- gw_leaderboards: one row per (scope, player). Scope is
-- (client_key, competition_id, round_id) with round_id NULL meaning the
-- overall/all-rounds scope. NULLS NOT DISTINCT so the overall rows upsert
-- in place instead of stacking one duplicate per re-score.
create table public.gw_leaderboards (
  id             uuid        not null default gen_random_uuid(),
  client_key     text        not null,
  competition_id text        not null,
  round_id       text,
  player_id      uuid        not null,
  username       text        not null,
  points         integer     not null default 0,
  -- score/ranking leaderboards display "6/8 correct"; null for modes
  -- that only track points (betting, lineup).
  correct        integer,
  total          integer,
  updated_at     timestamptz not null default now(),
  constraint gw_leaderboards_pkey primary key (id),
  constraint gw_leaderboards_scope_player_unique
    unique nulls not distinct (client_key, competition_id, round_id, player_id)
);

-- The read path: one scope's rows ordered by points, paginated.
create index gw_leaderboards_scope_points_idx
  on public.gw_leaderboards (client_key, competition_id, round_id, points desc);

alter table public.gw_leaderboards enable row level security;

-- Public read — leaderboards render logged out; username is the only
-- identifying column (player_id is an opaque uuid).
create policy leaderboards_read on public.gw_leaderboards
  for select using (true);

-- Writes: service role only (the score-round Edge Function). Enforced at
-- the GRANT level like the C-1 prediction-write revoke — no write policy
-- exists to get wrong, and PostgREST can't even attempt the verb.
revoke all on public.gw_leaderboards from anon, authenticated;
grant select on public.gw_leaderboards to anon, authenticated;
grant all on public.gw_leaderboards to service_role;
