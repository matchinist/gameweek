-- Phase 1.8 — identity hardening (H-7).
--
-- 1) gw_players identity columns become immutable for players. No client code
--    path updates gw_players at all (verified 2026-08-29: embed/admin/data
--    only select and insert), so the permissive players_update_own policy was
--    pure attack surface — a player token could rewrite its own client_key or
--    username from devtools. A trigger freezes id / auth_id / client_key /
--    username; email (profile) stays editable. service_role (and postgres)
--    bypass the guard for future account tooling (GDPR rename/merge).
--
-- 2) gw_league_members membership becomes keyed by player_id (FK gw_players):
--    column added, backfilled from (league client_key, username), and the 0.3
--    join/leave policies are rewritten to require the caller's OWN player_id
--    AND the matching username (username stays for display, but can no longer
--    be spoofed). Legacy rows whose username matches no player keep a null
--    player_id — display-only ghosts; they cannot be re-created.

-- ── 1) identity guard ───────────────────────────────────────────────────────

create or replace function public.gw_players_identity_guard()
returns trigger
language plpgsql
as $$
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') then
    return new;
  end if;
  if new.id is distinct from old.id
     or new.auth_id is distinct from old.auth_id
     or new.client_key is distinct from old.client_key
     or new.username is distinct from old.username then
    raise exception 'identity_immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists gw_players_identity_guard on gw_players;
create trigger gw_players_identity_guard
  before update on gw_players
  for each row execute function public.gw_players_identity_guard();

-- ── 2) league membership by player_id ───────────────────────────────────────

alter table gw_league_members
  add column if not exists player_id uuid references gw_players(id) on delete cascade;

update gw_league_members m
set player_id = p.id
from gw_leagues l, gw_players p
where m.player_id is null
  and l.id = m.league_id
  and p.client_key = l.client_key
  and p.username = m.username;

do $$
declare ghosts integer;
begin
  select count(*) into ghosts from gw_league_members where player_id is null;
  if ghosts > 0 then
    raise notice 'gw_league_members: % legacy row(s) matched no player — left as display-only ghosts', ghosts;
  end if;
end $$;

create unique index if not exists gw_league_members_league_player_key
  on gw_league_members (league_id, player_id)
  where player_id is not null;

create index if not exists gw_league_members_player_id_idx
  on gw_league_members (player_id);

-- Join/leave now require the caller's own player row: player_id must be the
-- caller's for the league's tenant, and username must match that row (display
-- integrity). The insert path without player_id is closed.
drop policy if exists league_members_insert_self on gw_league_members;
create policy league_members_insert_self on gw_league_members
  for insert to authenticated
  with check (exists (
    select 1
    from gw_leagues l
    join gw_players p on p.client_key = l.client_key
    where l.id = gw_league_members.league_id
      and p.auth_id = auth.uid()
      and p.id = gw_league_members.player_id
      and p.username = gw_league_members.username
  ));

drop policy if exists league_members_delete_self on gw_league_members;
create policy league_members_delete_self on gw_league_members
  for delete to authenticated
  using (exists (
    select 1 from gw_players p
    where p.auth_id = auth.uid()
      and p.id = gw_league_members.player_id
  ));
