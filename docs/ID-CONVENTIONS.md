# ID conventions

Adopted 2026-09-03 (owner decision), executed while the platform had no
active customers — the one moment a wholesale id change costs nothing.

## The standard

1. **Every entity id is a `uuid`**, generated client-side with
   `crypto.randomUUID()` (the bulk-save architecture depends on ids existing
   before the database sees the row). Applies to: teams, events, players,
   tournaments, season rounds, competitions, rounds, leagues, campaigns —
   and every future entity table.
2. **Natural keys stay `text`** and are never replaced by surrogates where
   the composite IS the identity: `client_key` (tenant slug — lives in URLs,
   localStorage keys, Sentry tags), `season_key` ('2026/27'), league `code`
   (user-facing join code), `comp_aliases` (human aliases for embed URLs —
   use these, not raw uuids, when handing operators a `?comp=` link),
   zone ids inside a season's standings.
3. **Polymorphic/log reference columns stay `text`** even though they now
   hold uuid *strings*: `gw_predictions.event_id` (can be
   `'<round uuid>_ranking'` — a composed key no uuid column can hold),
   `gw_predictions.round_id` / `competition_id`, the scope columns on
   `gw_leaderboards`, and the audit snapshots on `gw_score_runs` /
   `gw_ingest_runs` (history is never rewritten). SQL that compares these
   against uuid columns goes through `gw_try_uuid(text)` — never a bare
   cast (composed keys would throw) and never `id::text = …` (kills index
   use).

## How we got here

The seasons-blob decomposition left mixed text/uuid keys; a review weighed
uuid vs text vs bigint (benchmarked on PG17 with the live collation:
bigint 2.8µs, uuid 4.9µs, C-text 5.2µs, en_US-text 6.4µs per 1M-row index
probe). Migration `20260904000000_uuid_ids.sql` converted every entity id
and rewrote the full reference graph — relational columns, `event_ids[]`
arrays, jsonb (`lineup`, `scorers`, `lineup_config`, prediction picks),
composed prediction keys — in one transaction, keeping uuid-shaped ids
stable and dropping dangling array refs.

Deliberately NOT ids and NOT uuid: anything in rule 2. Deliberately text
forever: anything in rule 3. New high-volume internal tables may use
`bigint generated always as identity` when rows are never referenced from
URLs or jsonb — otherwise default to uuid.
