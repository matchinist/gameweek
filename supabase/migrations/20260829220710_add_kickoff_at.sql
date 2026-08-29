-- Phase 1.2 — gw_dm_events.kickoff_at timestamptz (M-12).
--
-- Backfilled from the text `kickoff` column. The live census (2026-08-29,
-- 2,254 rows — scripts/kickoff-backfill/report.mjs) found exactly four
-- formats and zero unparseable rows:
--   1,513  ISO datetime with explicit Z / +00 offset  -> exact instant
--     431  zoneless YYYY-MM-DDTHH:MM (all PAST events) -> read as
--           Europe/London: operators typed UK wall-clock times; the UTC
--           reading would shift summer fixtures an hour. No behavioural
--           impact either way — these locks are long past.
--     310  date-only YYYY-MM-DD (all FUTURE events)   -> UTC midnight,
--           which is exactly how the embed's new Date() reads them today,
--           so behaviour is preserved; real times can be set in /data.
--
-- Every branch is timezone-explicit, so the result does not depend on the
-- session TimeZone. The text column stays authoritative until task 1.7
-- verifies parity; clients prefer kickoff_at when present.
-- Idempotent: only touches rows where kickoff_at is still null.

alter table gw_dm_events add column if not exists kickoff_at timestamptz;

update gw_dm_events set kickoff_at = case
  -- ISO datetime with explicit zone (Z or ±hh[:mm]), T or space separator
  when kickoff ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}(:?\d{2})?)$'
    then kickoff::timestamptz
  -- date only -> UTC midnight (matches the embed's current interpretation)
  when kickoff ~ '^\d{4}-\d{2}-\d{2}$'
    then (kickoff || ' 00:00:00+00')::timestamptz
  -- zoneless datetime -> Europe/London wall time (reviewed backfill policy)
  when kickoff ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?$'
    then replace(kickoff, 'T', ' ')::timestamp at time zone 'Europe/London'
  else null
end
where kickoff_at is null and kickoff is not null and btrim(kickoff) <> '';

-- Fail loudly rather than silently leaving rows behind: a kickoff that is
-- non-empty but unparseable must be fixed by hand, not ignored.
do $$
declare bad integer;
begin
  select count(*) into bad
  from gw_dm_events
  where kickoff is not null and btrim(kickoff) <> '' and kickoff_at is null;
  if bad > 0 then
    raise exception 'kickoff backfill: % unparseable kickoff row(s) - fix them in /data, then re-run', bad;
  end if;
end $$;

create index if not exists gw_dm_events_kickoff_at_idx on gw_dm_events (kickoff_at);
