-- ============================================================================
-- LEGACY - DO NOT RUN. Already applied to the live database; its effects are
-- captured in the committed baseline supabase/migrations/20260829220021_remote_schema.sql.
-- Kept for history only. All new schema changes are Supabase CLI migrations.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- GAMEWEEK — RLS PII fix
-- Stops the public anon key from reading operator/player secrets.
--
-- Run in the Supabase SQL Editor. It changes NO data — only policies, grants,
-- and two read-only views — and is safe to run more than once (idempotent).
--
-- WHY THIS EXISTS
--   With the public anon key, `gw_operators` returned `email`,
--   `stripe_customer_id`, and `stripe_subscription_id`, and `gw_players`
--   returned `email`, to anyone. Branding has to stay public (the embed themes
--   itself before login), so the fix serves ONLY non-sensitive columns through
--   security-definer views and locks the base tables to their owner — plus, for
--   operators, the platform admins listed in `gw_admins`.
--
--   A logged-in player is an `authenticated` user but is NOT the operator, and
--   a player JWT is trivial to obtain (anyone can register on any embed). So the
--   sensitive columns must be hidden from every role except the row's owner and
--   platform admins — which is exactly what the base-table lockdown below does,
--   while the *_public views carry branding to everyone.
--
-- ZERO-DOWNTIME RUN ORDER
--   1. Run PART A (creates the public views). Purely additive — nothing breaks.
--   2. Deploy the app change that reads branding from the *_public views
--      (embed/ and widgets/standings/ — see the commit that ships with this).
--   3. Run PART B (locks the base tables). The app is already on the views.
--   Running A and B together is fine too, but ONLY once the app is on the
--   views; otherwise anonymous branding reads break in the gap before deploy.
-- ─────────────────────────────────────────────────────────────────────────────


-- ══ PART A — public projections (safe, additive) ═════════════════════════════

-- Branding/theme columns, and nothing else. Because the view runs with its
-- owner's rights (owner = postgres, which bypasses RLS), it returns branding
-- for every operator — but email and the Stripe IDs are not columns of the
-- view, so they can never be selected through it.
-- (Supabase's linter will flag this as a "security definer view". That is
--  intentional here: it is a deliberate public projection of safe columns.)
create or replace view public.gw_operators_public
  with (security_invoker = false) as
  select
    client_key,
    company_name,
    logo_url,
    language,
    accent_color,
    bg_color,
    surface_color,
    text_color
  from public.gw_operators;

grant select on public.gw_operators_public to anon, authenticated;

-- Note: gw_players needs no public view. The leaderboard and "other players'
-- picks" read usernames from gw_predictions.username (denormalized), never from
-- gw_players — so anonymous visitors never need the players table at all, and
-- it can be locked outright in PART B.


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
