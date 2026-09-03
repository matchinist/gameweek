-- DB redesign phase R2 (2026-09-03): season rounds move out of the
-- gw_dm_tournaments.seasons blob into their own table. One row per round;
-- event membership stays a text[] column — deliberately mirroring the
-- per-client gw_rounds table's design (same query patterns, e.g. the
-- worker's overlaps() lookups) rather than inventing a third shape.
-- Apps hydrate the in-memory seasons structure from this table at load,
-- so the (large) editing surface in /data keeps its existing code.
create table public.gw_dm_season_rounds (
  id            text        not null,  -- keeps the blob round ids ("r<uid>")
  tournament_id text        not null,
  season_key    text        not null,
  label         text        not null,
  deadline      text        not null default '',
  sort_order    integer     not null default 0,
  event_ids     text[]      not null default '{}',
  updated_at    timestamptz not null default now(),
  constraint gw_dm_season_rounds_pkey primary key (id)
);
create index gw_dm_season_rounds_scope_idx on public.gw_dm_season_rounds (tournament_id, season_key);

alter table public.gw_dm_season_rounds enable row level security;
create policy dm_season_rounds_read on public.gw_dm_season_rounds for select to public using (true);
create policy dm_season_rounds_write on public.gw_dm_season_rounds for all to public
  using (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()))
  with check (exists (select 1 from public.gw_admins a where a.auth_id = auth.uid()));
grant select on public.gw_dm_season_rounds to anon;
grant select, insert, update, delete on public.gw_dm_season_rounds to authenticated;
grant all on public.gw_dm_season_rounds to service_role;

-- ── backfill from the blobs, then strip them ───────────────────────────────
DO $$
DECLARE
  t record; s record; r record; i integer;
BEGIN
  FOR t IN SELECT id, seasons FROM public.gw_dm_tournaments WHERE seasons IS NOT NULL LOOP
    FOR s IN SELECT key, value FROM jsonb_each(t.seasons) LOOP
      CONTINUE WHEN s.value->'rounds' IS NULL;
      i := 0;
      FOR r IN SELECT * FROM jsonb_array_elements(coalesce(s.value->'rounds','[]'::jsonb)) AS e(v) LOOP
        INSERT INTO public.gw_dm_season_rounds (id, tournament_id, season_key, label, deadline, sort_order, event_ids)
        VALUES (
          coalesce(r.v->>'id', t.id || '_' || s.key || '_' || i),
          t.id, s.key,
          coalesce(r.v->>'label', 'Round ' || (i + 1)),
          coalesce(r.v->>'deadline', ''),
          i,
          coalesce(ARRAY(SELECT jsonb_array_elements_text(coalesce(r.v->'eventIds','[]'::jsonb))), '{}')
        )
        ON CONFLICT (id) DO NOTHING;
        i := i + 1;
      END LOOP;
    END LOOP;
    UPDATE public.gw_dm_tournaments
      SET seasons = (SELECT coalesce(jsonb_object_agg(e.key, e.value - 'rounds'), '{}'::jsonb)
                     FROM jsonb_each(gw_dm_tournaments.seasons) e)
      WHERE id = t.id;
  END LOOP;
END $$;
