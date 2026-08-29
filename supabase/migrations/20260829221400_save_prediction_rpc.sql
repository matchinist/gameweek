-- Phase 1.3 — save_prediction() RPC (TARGET-ARCHITECTURE §4.1).
--
-- The single legitimate write path for predictions. The prediction deadline
-- is enforced HERE, by database time, so no client clock or devtools call can
-- write a late prediction once 1.5 revokes direct table writes.
--
-- Contract:
--   * security definer, owned by postgres; EXECUTE granted to authenticated
--     only (anon gets permission denied).
--   * Resolves the caller's player row for (auth.uid(), p_client_key);
--     missing -> raises 'not_registered'.
--   * Deadline: an event locks at kickoff_at - 30 minutes, inclusive
--     (now() >= boundary -> raises 'locked').
--   * An event id with NO gw_dm_events row is not locked: lineup and ranking
--     modes store the ROUND id in event_id (savePred(roundId, ...) in the
--     embed), so the kickoff lookup legitimately misses. Same rule as the
--     client: an unknown kickoff is treated as not-yet-passed, never as
--     already-happened. A null kickoff_at behaves the same.
--   * username is copied from gw_players — there is deliberately no username
--     parameter, so a caller can never write another display identity.
--   * Upsert on (player_id, competition_id, event_id), matching the client's
--     current onConflict.

create or replace function public.save_prediction(
  p_client_key     text,
  p_competition_id text,
  p_round_id       text,
  p_event_id       text,
  p_prediction     jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid;
  v_username  text;
  v_kickoff   timestamptz;
begin
  select id, username into v_player_id, v_username
  from gw_players
  where auth_id = auth.uid() and client_key = p_client_key;
  if v_player_id is null then
    raise exception 'not_registered';
  end if;

  select kickoff_at into v_kickoff
  from gw_dm_events
  where id = p_event_id;
  if v_kickoff is not null and now() >= v_kickoff - interval '30 minutes' then
    raise exception 'locked';
  end if;

  insert into gw_predictions
    (client_key, player_id, username, competition_id, round_id, event_id, prediction)
  values
    (p_client_key, v_player_id, v_username, p_competition_id, p_round_id, p_event_id, p_prediction)
  on conflict (player_id, competition_id, event_id)
  do update set
    prediction   = excluded.prediction,
    round_id     = excluded.round_id,
    username     = excluded.username,
    submitted_at = now();
end;
$$;

revoke all on function public.save_prediction(text, text, text, text, jsonb) from public;
revoke all on function public.save_prediction(text, text, text, text, jsonb) from anon;
grant execute on function public.save_prediction(text, text, text, text, jsonb) to authenticated;
