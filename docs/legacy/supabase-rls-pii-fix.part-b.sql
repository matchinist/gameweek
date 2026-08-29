-- ============================================================================
-- LEGACY - DO NOT RUN. Already applied to the live database; its effects are
-- captured in the committed baseline supabase/migrations/20260829220021_remote_schema.sql.
-- Kept for history only. All new schema changes are Supabase CLI migrations.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- GAMEWEEK — RLS PII fix, PART B (lock the base tables)
-- ⚠️  RUN THIS ONLY AFTER:
--     1. PART A has been run (supabase-rls-pii-fix.part-a.sql), AND
--     2. the app edits (embed/ + widgets/standings/) are deployed to production.
-- Running this before the app reads branding from gw_operators_public will
-- break theming for every visitor. Idempotent; changes no data.
-- ─────────────────────────────────────────────────────────────────────────────

-- ══ PART B — lock the base tables ════════════════════════════════════════════

-- Drop EVERY existing policy on these two tables first. A permissive policy that
-- drifted onto production (the actual cause of the leak) is removed here
-- deterministically no matter what it was named; the intended set is recreated
-- immediately below.
do $$
declare pol record;
begin
  for pol in
    select tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('gw_operators', 'gw_players')
  loop
    execute format('drop policy if exists %I on public.%I', pol.policyname, pol.tablename);
  end loop;
end $$;

alter table public.gw_operators enable row level security;
alter table public.gw_players   enable row level security;

-- ── OPERATORS ────────────────────────────────────────────────────────────────
-- The operator owns their row and reads/updates it in full (email + Stripe IDs
-- are shown in their own billing screen). Row auto-created on first login.
create policy "operators_insert" on public.gw_operators
  for insert to authenticated
  with check (auth.uid() = auth_id);

create policy "operators_read_own" on public.gw_operators
  for select to authenticated
  using (auth.uid() = auth_id);

create policy "operators_update_own" on public.gw_operators
  for update to authenticated
  using (auth.uid() = auth_id)
  with check (auth.uid() = auth_id);

-- Platform admins (the Data Manager) read every operator and toggle billing
-- flags such as subscription_required.
create policy "operators_read_admin" on public.gw_operators
  for select to authenticated
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));

create policy "operators_update_admin" on public.gw_operators
  for update to authenticated
  using      (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));

-- Anonymous visitors get branding ONLY through gw_operators_public.
revoke all on public.gw_operators from anon;
grant select, insert, update on public.gw_operators to authenticated;

-- ── PLAYERS ──────────────────────────────────────────────────────────────────
-- A player owns their row (registration + their own profile/predictions).
create policy "players_insert" on public.gw_players
  for insert to authenticated
  with check (auth.uid() = auth_id);

create policy "players_read_own" on public.gw_players
  for select to authenticated
  using (auth.uid() = auth_id);

create policy "players_update_own" on public.gw_players
  for update to authenticated
  using (auth.uid() = auth_id)
  with check (auth.uid() = auth_id);

-- An operator reads the players registered under their own client_key — the
-- "Users" list in the admin panel. These are that operator's own end users, so
-- seeing their emails is expected; a player still cannot see another player's.
create policy "players_read_operator" on public.gw_players
  for select to authenticated
  using (client_key in (
    select client_key from public.gw_operators where auth_id = auth.uid()
  ));

-- No anonymous access at all — the leaderboard never needs it.
revoke all on public.gw_players from anon;
grant select, insert, update on public.gw_players to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- NOT CHANGED (deliberately, to keep this fix tightly scoped to the PII leak):
--   • gw_predictions stays world-readable (predictions_read USING true). It
--     holds no PII — only game picks plus the already-public display username —
--     but it does let a visitor read others' picks before an event locks. That
--     is a game-integrity hardening for a later pass, not part of this leak.
--   • gw_competitions / gw_rounds / gw_dm_* keep their existing policies.
-- ─────────────────────────────────────────────────────────────────────────────
