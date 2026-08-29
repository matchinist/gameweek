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

Drill log:

| Date | Dump size | Restore runtime | Notes |
|---|---|---|---|
| _pending first run_ | | | |
