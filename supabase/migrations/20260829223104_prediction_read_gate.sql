-- Phase 1.6 — gate prediction reads (H-6).
--
-- Replaces predictions_read USING (true), which let anyone read everyone's
-- picks before kickoff. New rule:
--   * own rows: always visible
--   * others' event-keyed rows: visible only once the event is locked
--     (now() >= kickoff_at - 30 min). A null kickoff_at means "unknown,
--     not yet passed" -> hidden from others, same convention as the client.
--   * rows whose event_id has NO gw_dm_events row stay visible to everyone:
--     lineup and ranking modes store the ROUND id in event_id, their
--     leaderboards read others' rows, and the round->event link lives in the
--     seasons JSON blob, so there is no SQL-reachable lock time for them.
--     Documented carve-out until Phase 3 moves leaderboards server-side.
--   * anon keeps working: locked-event + round-keyed rows only, which is
--     exactly what logged-out leaderboards need.
--
-- The own-row check goes through a SECURITY DEFINER helper because anon has
-- no grant on gw_players at all (revoked in the PII fix) — a bare policy
-- subquery on it would fail every anon SELECT with permission denied.

create or replace function public.gw_is_own_player(p_player_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from gw_players p
    where p.id = p_player_id
      and p.auth_id = auth.uid()
  );
$$;

revoke all on function public.gw_is_own_player(uuid) from public;
grant execute on function public.gw_is_own_player(uuid) to anon, authenticated;

drop policy if exists predictions_read on gw_predictions;
create policy predictions_read on gw_predictions
  for select
  using (
    gw_is_own_player(player_id)
    or not exists (
      select 1 from gw_dm_events e
      where e.id = gw_predictions.event_id
    )
    or exists (
      select 1 from gw_dm_events e
      where e.id = gw_predictions.event_id
        and e.kickoff_at is not null
        and now() >= e.kickoff_at - interval '30 minutes'
    )
  );
