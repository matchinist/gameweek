-- ═══════════════════════════════════════════════════════════════════════════
-- HOST-PAGE SSO ("connect the game to the account players already have")
-- Run manually in the Supabase SQL editor, like supabase-migration.sql.
--
-- What this enables: a player who is already signed in on the operator's own
-- site (e.g. a Shopify customer) is signed into the embed silently. The host
-- page renders the user's id/email/name plus an HMAC-SHA256 signature made
-- with the operator's sso_secret; the `sso-login` Edge Function
-- (supabase/functions/sso-login/index.ts) verifies the signature with the
-- service role and mints a real Supabase session, because RLS on
-- gw_players/gw_predictions is keyed to auth.uid().
--
-- Deploying the function (one-off, from the repo root):
--   supabase functions deploy sso-login
-- It only needs the SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY env vars that
-- the Edge runtime injects automatically — no extra secrets to configure.
--
-- Security notes:
--  * sso_secret is readable only through gw_operators row-level security:
--    the operator's own row (operators_read_own) and platform admins. The
--    anon-facing gw_operators_public view has a fixed column list
--    (supabase-rls-pii-fix.part-a.sql) and therefore can never expose it.
--  * The Edge Function maps SSO users to synthetic addresses under
--    @sso.gameweek.cloud instead of the real email, so a leaked operator
--    secret can mint sessions only for that operator's own namespace —
--    never for an existing real-email account (a player's, an operator's,
--    or a platform admin's).
-- ═══════════════════════════════════════════════════════════════════════════

alter table gw_operators add column if not exists sso_enabled boolean not null default false;
alter table gw_operators add column if not exists sso_secret  text;

comment on column gw_operators.sso_enabled is
  'Host-page SSO: when true, the sso-login Edge Function accepts signed identities for this client_key.';
comment on column gw_operators.sso_secret is
  'HMAC-SHA256 key the operator''s site signs SSO identities with (hex sig over "id:email"). Never exposed to anon — see gw_operators_public.';

-- ── Expose `domains` through the public projection ─────────────────────────
-- The embed origin-gates SSO messages against the operator's allowed domains
-- (a valid signature alone must not be enough to switch a viewer's account —
-- the message must also come from the operator's real site). The embed uses
-- the anon key, so it can only read those domains through gw_operators_public.
-- `domains` is not sensitive: it lists the public pages the widget is embedded
-- on. This re-creates the view from supabase-rls-pii-fix.part-a.sql with the
-- one column appended — sso_secret and the Stripe/email columns stay excluded.
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
    text_color,
    domains
  from public.gw_operators;

grant select on public.gw_operators_public to anon, authenticated;

-- ── Username uniqueness backstop ───────────────────────────────────────────
-- Both manual registration and SSO first-visit creation check a username is
-- free and then insert; two concurrent signups can pass the check and collide.
-- This constraint turns that race into a duplicate-key error the insert paths
-- already retry on, instead of two rows sharing a username. Run LAST: if any
-- (client_key, username) duplicates already exist it will fail, and they must
-- be de-duplicated first — the column adds above have already applied by then.
create unique index if not exists gw_players_client_username_uidx
  on gw_players(client_key, username);
