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


