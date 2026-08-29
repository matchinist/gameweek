-- Phase 1.5 — revoke direct prediction writes. THIS CLOSES C-1.
--
-- Since 1.4, every client write goes through save_prediction() (security
-- definer, owner postgres — unaffected by these grants). A devtools upsert,
-- a replayed request, or any stale pre-1.4 tab now gets permission denied at
-- the grant level, before RLS is even consulted. SELECT is governed by the
-- 1.6 read-gate policy; DELETE stays granted for the admin competition-
-- cleanup path (itself still bound by RLS).
--
-- Rollback is a single statement:
--   grant insert, update on gw_predictions to anon, authenticated;

revoke insert, update on gw_predictions from anon, authenticated;
