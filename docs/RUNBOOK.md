# Runbook

## Database backups (Phase 1.9)

**What exists:** `.github/workflows/db-backup.yml` dumps the whole Supabase
Postgres every Monday 03:20 UTC (and on manual dispatch) with `pg_dump
--format=custom`, verifies the archive lists the core tables, and stores it as
a GitHub Actions artifact for 90 days. Artifacts on this public repo are
downloadable by collaborators only. This is the off-Supabase copy; Supabase's
own scheduled backups (dashboard → Database → Backups) are the first line.

**Prerequisite (one-time):** set the repository secret with the **Session
pooler** connection string from the dashboard's **"Connect" button** (top bar
of the project page) → Connection String tab:

```
postgresql://postgres.<ref>:<password>@aws-1-<region>.pooler.supabase.com:5432/postgres
```

Session pooler specifically: the "Direct connection" host is IPv6-only (no
IPv4 add-on) and GitHub Actions runners have no IPv6; the transaction pooler
(port 6543) doesn't suit `pg_dump`. The database password can be reset under
Settings → Database → Database password if unknown.

```bash
gh secret set SUPABASE_DB_URL
```

**Take a manual backup now:**

```bash
gh workflow run db-backup.yml && gh run watch
```

**Restore drill** (also the real restore procedure, pointed at a real target):

```bash
# 1. Fetch the newest backup artifact
gh run download $(gh run list --workflow=db-backup.yml --status=success --limit 1 --json databaseId -q '.[0].databaseId')

# 2. Disposable Postgres 17 matching the server version
docker run -d --rm --name gw-restore -e POSTGRES_PASSWORD=t -p 55443:5432 postgres:17-alpine
until docker exec gw-restore pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done

# 3. Restore (roles/extensions that only exist on Supabase are skipped;
#    --no-owner/--no-privileges keep it portable)
docker cp db-backup-*/gameweek-*.dump gw-restore:/tmp/b.dump
docker exec gw-restore pg_restore -U postgres -d postgres --no-owner --no-privileges /tmp/b.dump

# 4. Sanity: row counts for the irreplaceable tables
docker exec gw-restore psql -U postgres -c \
  "select 'teams', count(*) from gw_dm_teams union all \
   select 'events', count(*) from gw_dm_events union all \
   select 'players (squad)', count(*) from gw_dm_players union all \
   select 'predictions', count(*) from gw_predictions;"

docker stop gw-restore
```

A drill into vanilla Postgres reports rc=1 with warnings for platform-owned
objects a bare server lacks (the `authenticated`/`anon` roles behind some
policies, `supabase_vault`, the index-advisor extensions). That is expected —
verify the row counts, which are the point. A real restore into a fresh
Supabase project has all of those and completes fully.

Drill log:

| Date | Dump size | Restore runtime | Notes |
|---|---|---|---|
| 2026-08-29 | 442 KB | ~1 s | run 33279619278; all app tables complete (230 teams, 2,254 events, 771 squad players, 20 tournaments, 47 players, 145 predictions, 3 leagues); spot-checked the evening's newest prediction present; 71 warnings, all platform objects (roles/vault/advisor extensions), zero data errors |

## Cloudflare Pages (Phase 2.6)

Every gated `main` build dual-deploys: GitHub Pages (the `www` origin until
cutover) and the Cloudflare Pages project **gameweek-cloud**
(https://gameweek-cloud.pages.dev). Repo branches deploy previews at
`<branch>.gameweek-cloud.pages.dev` via `ci.yml`.

**Rollback (one click):** dashboard → Workers & Pages → gameweek-cloud →
Deployments → ⋯ menu on any previous deployment → *Rollback to this
deployment*. Instant, no rebuild. From the CLI:
`pnpm exec wrangler pages deployment list --project-name=gameweek-cloud`.

**Cutover plan (pending):** zone `gameweek.cloud` added to Cloudflare, then
nameservers switched at Namecheap (verify the Google MX + TXT records
imported first — email breaks otherwise); once the zone is active, attach
`www.gameweek.cloud` as a custom domain on the project and point the `www`
CNAME at `gameweek-cloud.pages.dev`. GitHub Pages stays warm; reverting is
one CNAME change back to `matchinist.github.io`.
