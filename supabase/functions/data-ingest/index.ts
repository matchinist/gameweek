// Gameweek data-ingest — the provider-agnostic sports-data feed worker.
//
// Providers (SportMonks today, others later) are configured dynamically in
// gw_providers — including their API tokens — from /data's Ingest page.
// pg_cron POSTs here every 5 minutes; each ENABLED provider with a token
// and an implemented adapter runs and logs its own gw_ingest_runs row, so
// the audit stays per-provider even when several run per iteration.
//
// Normalisation contract: every provider syncs into the same gw_dm_* layer
// and may ONLY touch rows an admin explicitly mapped via provider_ids
// (e.g. {"sportmonks": 123}) — unmapped rows are invisible to the feed,
// which is what keeps the hand-curated database safe. Results chain into
// score-round service-to-service, so feed results score automatically.
//
// Deploy: supabase functions deploy data-ingest

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";
// @ts-ignore — plain ESM module shared with the vitest suite
import { parseFixture, parseStandings } from "../_shared/sportmonks_adapter.mjs";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

const CRON_MIN_INTERVAL_MS = 4 * 60 * 1000; // dampen abuse of the public trigger

type LogLine = { level: string; msg: string };
type ProviderRow = { id: string; name: string; token: string | null; base_url: string | null; enabled: boolean; config: Record<string, unknown> | null };
type RunResult = { stats: Record<string, number>; log: LogLine[] };

// ── provider adapters ───────────────────────────────────────────────────────
// One entry per implemented provider; /data can register any provider row,
// but until an adapter exists here its runs report "no adapter implemented".

// Budget-aware sync. The Starter plan allows ~2000 API calls/month while
// the cron fires every 5 minutes, so the worker must decide when calling
// out is WORTH a request:
//   * LIVE window (every run): only events kicked off in the last 6 hours
//     and not yet completed — that is where results appear. No live events
//     -> zero API calls for that run.
//   * DAILY pass (~once per 20h, tracked in provider.config): refresh
//     upcoming kickoffs for mapped events, and auto-import new fixtures for
//     tournaments mapped with auto_import — creating events (and unseen
//     teams) with provider_ids, so a mapped tournament keeps itself fresh.
async function runSportmonks(service: SupabaseClient, provider: ProviderRow, manual: boolean): Promise<RunResult> {
  const log: LogLine[] = [];
  const base = provider.base_url || "https://api.sportmonks.com/v3/football";
  const now = Date.now();
  const stats: Record<string, number> = {
    api_calls: 0, live_events: 0, fixtures_checked: 0,
    results_updated: 0, kickoffs_updated: 0, fixtures_imported: 0, teams_created: 0, rounds_scored: 0,
  };
  const smFetch = async (path: string) => {
    stats.api_calls++;
    const res = await fetch(`${base}${path}`, { headers: { Authorization: provider.token! } });
    if (!res.ok) throw new Error(`SportMonks ${res.status}: ${(await res.text()).slice(0, 300)}`);
    return res.json();
  };

  // All mapped events once — the live filter, kickoff refresh and import
  // dedupe all read from this.
  const { data: mapped, error: mapErr } = await service.from("gw_dm_events")
    .select("id,provider_ids,kickoff_at,result,status")
    .not(`provider_ids->${provider.id}`, "is", null)
    .limit(5000);
  if (mapErr) throw new Error(`mapped-events load failed: ${mapErr.message}`);
  type MappedEv = { id: string; provider_ids: Record<string, number | string>; kickoff_at: string | null; result: { h: number; a: number } | null; status: string | null };
  const bySmId: Record<string, MappedEv> = {};
  (mapped || []).forEach((e: MappedEv) => { bySmId[String(e.provider_ids[provider.id])] = e; });

  const updatedEventIds: string[] = [];
  const syncByIds = async (smIds: string[]) => {
    for (let i = 0; i < smIds.length; i += 50) {
      const payload = await smFetch(`/fixtures/multi/${smIds.slice(i, i + 50).join(",")}?include=scores;state`);
      for (const fx of payload.data || []) {
        stats.fixtures_checked++;
        const p = parseFixture(fx);
        const ev = bySmId[String(p.smId)];
        if (!ev) continue;
        const patch: Record<string, unknown> = {};
        if (p.startingAt && (!ev.kickoff_at || Math.abs(new Date(p.startingAt).getTime() - new Date(ev.kickoff_at).getTime()) > 60_000)) {
          patch.kickoff_at = p.startingAt;
          stats.kickoffs_updated++;
          log.push({ level: "info", msg: `kickoff ${ev.id}: ${ev.kickoff_at || "unset"} -> ${p.startingAt}` });
        }
        if (p.finished && p.h != null && (!ev.result || ev.result.h !== p.h || ev.result.a !== p.a)) {
          patch.result = { ...(ev.result || {}), h: p.h, a: p.a };
          patch.status = "completed";
          stats.results_updated++;
          log.push({ level: "info", msg: `result ${ev.id}: ${p.h}-${p.a} (${p.state})` });
        }
        if (Object.keys(patch).length) {
          const { error: upErr } = await service.from("gw_dm_events").update(patch).eq("id", ev.id);
          if (upErr) { log.push({ level: "error", msg: `update ${ev.id} failed: ${upErr.message}` }); continue; }
          if (patch.result) updatedEventIds.push(ev.id);
        }
      }
    }
  };

  // ── live window ─────────────────────────────────────────────────────────
  const liveIds = Object.entries(bySmId)
    .filter(([, e]) => e.status !== "completed" && e.kickoff_at
      && new Date(e.kickoff_at).getTime() <= now + 10 * 60_000
      && new Date(e.kickoff_at).getTime() >= now - 6 * 3600_000)
    .map(([smId]) => smId);
  stats.live_events = liveIds.length;
  if (liveIds.length) await syncByIds(liveIds);

  // ── daily pass ──────────────────────────────────────────────────────────
  // A manual run ALWAYS gets the full pass — an admin clicking Run just
  // changed something (a new mapping, a correction) and wants the sync NOW;
  // the 20h throttle exists only to keep the unattended cron inside the
  // API budget.
  const cfg = (provider.config || {}) as Record<string, unknown>;
  const lastDaily = cfg.last_daily_sync ? Date.parse(String(cfg.last_daily_sync)) : 0;
  if (manual || now - lastDaily > 20 * 3600_000) {
    // upcoming kickoff refresh + recent-past events still missing results
    // (a mapped event older than the 6h live window would otherwise never
    // get its result — e.g. last week's round linked after the fact)
    // 60 days back: any mapped-but-unresulted event stays in this set until
    // its result lands (then status=completed removes it), so linking an
    // old round backfills its scores on the next pass. The cap only stops
    // abandoned fixtures from being polled forever.
    const liveSet = new Set(liveIds);
    const staleIds = Object.entries(bySmId)
      .filter(([smId, e]) => !liveSet.has(smId) && e.status !== "completed" && e.kickoff_at
        && new Date(e.kickoff_at).getTime() > now - 60 * 864e5
        && new Date(e.kickoff_at).getTime() < now + 14 * 864e5)
      .map(([smId]) => smId);
    if (staleIds.length) await syncByIds(staleIds);

    // auto-import new fixtures for mapped tournaments
    const { data: tournaments } = await service.from("gw_dm_tournaments")
      .select("id,name,provider_ids").not(`provider_ids->${provider.id}`, "is", null);
    const importTargets = (tournaments || []).filter((t: { provider_ids: Record<string, { league_id?: number; auto_import?: boolean }> }) =>
      t.provider_ids[provider.id]?.league_id && t.provider_ids[provider.id]?.auto_import);
    if (importTargets.length) {
      const { data: teamRows } = await service.from("gw_dm_teams")
        .select("id,provider_ids").not(`provider_ids->${provider.id}`, "is", null);
      const teamBySmId: Record<string, string> = {};
      (teamRows || []).forEach((t: { id: string; provider_ids: Record<string, number | string> }) => {
        teamBySmId[String(t.provider_ids[provider.id])] = t.id;
      });
      const d = (ms: number) => new Date(ms).toISOString().slice(0, 10);
      for (const t of importTargets) {
        const leagueId = t.provider_ids[provider.id].league_id;
        try {
          const payload = await smFetch(`/fixtures/between/${d(now)}/${d(now + 14 * 864e5)}?include=participants&filters=fixtureLeagues:${leagueId}&per_page=50`);
          for (const fx of payload.data || []) {
            const p = parseFixture(fx);
            if (bySmId[String(p.smId)]) continue; // already ours
            if (!p.homeSmId || !p.awaySmId) continue;
            // resolve teams, creating any this league hasn't shown us before
            const teamIdFor = async (smId: number, name: string | null, short: string | null, image: string | null) => {
              const known = teamBySmId[String(smId)];
              if (known) return known;
              const id = crypto.randomUUID();
              const { error } = await service.from("gw_dm_teams").insert({
                id, name: name || `Team ${smId}`, short: (short || (name || "").slice(0, 3)).toUpperCase().slice(0, 5),
                color: "#4F46E5", logo: image || "", sport: "football",
                provider_ids: { [provider.id]: smId },
              });
              if (error) throw new Error(`team create failed: ${error.message}`);
              teamBySmId[String(smId)] = id;
              stats.teams_created++;
              log.push({ level: "info", msg: `created team ${name} (${id})` });
              return id;
            };
            const homeId = await teamIdFor(p.homeSmId, p.homeName, p.homeShort, p.homeImage);
            const awayId = await teamIdFor(p.awaySmId, p.awayName, p.awayShort, p.awayImage);
            const evId = crypto.randomUUID();
            const { error: insErr } = await service.from("gw_dm_events").insert({
              id: evId, home_id: homeId, away_id: awayId,
              kickoff: p.startingAt || "", kickoff_at: p.startingAt, status: "upcoming", line: 2.5,
              provider_ids: { [provider.id]: p.smId },
            });
            if (insErr) { log.push({ level: "error", msg: `import ${p.homeName} vs ${p.awayName} failed: ${insErr.message}` }); continue; }
            bySmId[String(p.smId)] = { id: evId, provider_ids: { [provider.id]: p.smId }, kickoff_at: p.startingAt, result: null, status: "upcoming" };
            stats.fixtures_imported++;
            log.push({ level: "info", msg: `imported ${p.homeName} vs ${p.awayName} (${t.name}) ${p.startingAt || ""}` });
          }
        } catch (e) {
          log.push({ level: "error", msg: `auto-import ${t.name}: ${(e as Error).message}` });
        }
      }
    }
    // standings refresh — only worth API quota when results changed (the
    // table can't move otherwise) or when a human explicitly ran the sync.
    if (stats.results_updated > 0 || manual) {
      const { data: mappedTs } = await service.from("gw_dm_tournaments")
        .select("id,name,provider_ids").not(`provider_ids->${provider.id}`, "is", null);
      const { data: teamRows2 } = await service.from("gw_dm_teams")
        .select("id,name,provider_ids").not(`provider_ids->${provider.id}`, "is", null);
      const teamBySmId2: Record<string, { id: string; name: string }> = {};
      (teamRows2 || []).forEach((t: { id: string; name: string; provider_ids: Record<string, number | string> }) => {
        teamBySmId2[String(t.provider_ids[provider.id])] = { id: t.id, name: t.name };
      });
      for (const t of (mappedTs || [])) {
        const m = t.provider_ids[provider.id] as { league_id?: number; season_key?: string };
        if (!m?.league_id || !m?.season_key) continue;
        try {
          const lres = await smFetch(`/leagues/${m.league_id}?include=currentSeason`);
          const seasonId = lres.data?.currentseason?.id;
          if (!seasonId) { log.push({ level: "error", msg: `standings ${t.name}: no current season` }); continue; }
          const sres = await smFetch(`/standings/seasons/${seasonId}?include=participant;details.type&per_page=50`);
          const parsed = parseStandings(sres.data || []);
          if (!parsed.length) continue;
          // gw_dm_standings rows (redesign R1). Zone bands live in their own
          // table and describe table POSITIONS, so carry them over by rank.
          const { data: prevRows } = await service.from("gw_dm_standings")
            .select("rank,zone_id").eq("tournament_id", t.id).eq("season_key", m.season_key).is("round_id", null);
          const rankToZone: Record<number, string | null> = {};
          (prevRows || []).forEach((r: { rank: number; zone_id: string | null }) => { if (r.zone_id != null) rankToZone[r.rank] = r.zone_id; });
          const { error: delErr } = await service.from("gw_dm_standings").delete()
            .eq("tournament_id", t.id).eq("season_key", m.season_key).is("round_id", null);
          if (delErr) { log.push({ level: "error", msg: `standings clear ${t.name}: ${delErr.message}` }); continue; }
          const { error: insErr } = await service.from("gw_dm_standings").insert(
            parsed.map((r: { rank: number; participantId: number; name: string; played: number; w: number; d: number; l: number; gf: number; ga: number; diff: number; pts: number }) => {
              const team = teamBySmId2[String(r.participantId)] || null;
              return { tournament_id: t.id, season_key: m.season_key, round_id: null,
                rank: r.rank, team_id: team ? team.id : null, name: team ? team.name : r.name,
                played: r.played, w: r.w, d: r.d, l: r.l, gf: r.gf, ga: r.ga, diff: r.diff, pts: r.pts,
                zone_id: rankToZone[r.rank] ?? null };
            }));
          if (insErr) { log.push({ level: "error", msg: `standings write ${t.name}: ${insErr.message}` }); continue; }
          stats.standings_updated = (stats.standings_updated || 0) + 1;
          log.push({ level: "info", msg: `standings ${t.name}: ${parsed.length} rows (${m.season_key})` });
        } catch (e) {
          log.push({ level: "error", msg: `standings ${t.name}: ${(e as Error).message}` });
        }
      }
    }
    const { error: cfgErr } = await service.from("gw_providers")
      .update({ config: { ...cfg, last_daily_sync: new Date(now).toISOString() }, updated_at: new Date().toISOString() })
      .eq("id", provider.id);
    if (cfgErr) log.push({ level: "error", msg: `config update failed: ${cfgErr.message}` });
    (stats as Record<string, number>).daily_pass = 1;
  }

  stats.rounds_scored = await scoreAffectedRounds(service, updatedEventIds, log);
  if (!Object.keys(bySmId).length && !stats.fixtures_imported) {
    log.push({ level: "info", msg: "nothing mapped yet — map a tournament (or events) to activate syncing" });
  }
  return { stats, log };
}

const ADAPTERS: Record<string, (service: SupabaseClient, provider: ProviderRow, manual: boolean) => Promise<RunResult>> = {
  sportmonks: runSportmonks,
};

// After results land, every round containing an updated event re-scores
// through score-round (service-to-service; the audit shows service:ingest).
async function scoreAffectedRounds(service: SupabaseClient, updatedEventIds: string[], log: LogLine[]): Promise<number> {
  if (!updatedEventIds.length) return 0;
  const scopes: Array<{ client_id: string; competition_id: string; round_id: string }> = [];
  const { data: rounds } = await service.from("gw_rounds")
    .select("id,client_id,competition_id,event_ids")
    .overlaps("event_ids", updatedEventIds);
  (rounds || []).forEach((r: { id: string; client_id: string; competition_id: string }) =>
    scopes.push({ client_id: r.client_id, competition_id: r.competition_id, round_id: r.id }));
  const { data: lineupComps } = await service.from("gw_competitions")
    .select("id,client_id,lineup_config").eq("mode", "lineup").eq("status", "active");
  const { data: updatedEvents } = await service.from("gw_dm_events")
    .select("id,home_id,away_id").in("id", updatedEventIds);
  (lineupComps || []).forEach((c: { id: string; client_id: string; lineup_config?: { teamId?: string } }) => {
    const tid = c.lineup_config?.teamId;
    (updatedEvents || []).forEach((e: { id: string; home_id: string; away_id: string }) => {
      if (tid && (tid === e.home_id || tid === e.away_id))
        scopes.push({ client_id: c.client_id, competition_id: c.id, round_id: e.id });
    });
  });
  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  let scored = 0;
  for (const s of scopes) {
    const r = await fetch(`${url}/functions/v1/score-round`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${serviceKey}` },
      body: JSON.stringify(s),
    });
    if (r.ok) scored++;
    else log.push({ level: "error", msg: `score-round ${s.client_id}/${s.round_id}: HTTP ${r.status}` });
  }
  return scored;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const service = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // admin JWT = manual run; anything else = the cron path (open on purpose:
  // it can only cause the same idempotent, rate-limited sync).
  let triggerSource = "cron";
  let initiatedBy: string | null = null;
  try {
    const asCaller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
    });
    const { data: userData } = await asCaller.auth.getUser();
    if (userData?.user) {
      const { data: adminRow } = await service
        .from("gw_admins").select("id").eq("auth_id", userData.user.id).maybeSingle();
      if (adminRow) { triggerSource = "manual"; initiatedBy = userData.user.email || userData.user.id; }
    }
  } catch (_e) { /* fall through as cron */ }

  if (triggerSource === "cron") {
    const { data: last } = await service.from("gw_ingest_runs")
      .select("run_at").order("run_at", { ascending: false }).limit(1).maybeSingle();
    if (last && Date.now() - new Date(last.run_at).getTime() < CRON_MIN_INTERVAL_MS) {
      return json(429, { skipped: "rate limited" });
    }
  }

  let body: { provider?: string } = {};
  try { body = await req.json(); } catch { /* empty body is fine */ }

  const { data: providers, error: provErr } = await service
    .from("gw_providers").select("*").eq("enabled", true).order("id");
  if (provErr) return json(500, { error: provErr.message });
  const targets = (providers || []).filter((p: ProviderRow) => !body.provider || p.id === body.provider);

  if (!targets.length) {
    // The dormant state must not flood the audit with cron rows, but a
    // human clicking Run deserves an explanation.
    if (triggerSource === "manual") {
      await service.from("gw_ingest_runs").insert({
        trigger_source: triggerSource, initiated_by: initiatedBy, provider: body.provider || null,
        ok: false, duration_ms: 0, error: body.provider ? `provider ${body.provider} is not enabled` : "no enabled providers — add one on the Ingest page",
      });
      return json(409, { error: "no enabled providers" });
    }
    return json(200, { skipped: "no enabled providers" });
  }

  const results: Record<string, unknown>[] = [];
  for (const provider of targets as ProviderRow[]) {
    const startedAt = Date.now();
    const logRun = async (fields: Record<string, unknown>) => {
      const { error } = await service.from("gw_ingest_runs").insert({
        trigger_source: triggerSource, initiated_by: initiatedBy, provider: provider.id,
        duration_ms: Date.now() - startedAt, ...fields,
      });
      if (error) console.error("ingest log write failed:", error.message);
    };
    if (!provider.token) {
      if (triggerSource === "manual") await logRun({ ok: false, error: "no API token configured for this provider" });
      results.push({ provider: provider.id, error: "no token" });
      continue;
    }
    const adapter = ADAPTERS[provider.id];
    if (!adapter) {
      if (triggerSource === "manual") await logRun({ ok: false, error: `no adapter implemented for provider '${provider.id}'` });
      results.push({ provider: provider.id, error: "no adapter" });
      continue;
    }
    try {
      const { stats, log } = await adapter(service, provider, triggerSource === "manual");
      // A cron tick that spent no API quota and changed nothing is the
      // steady idle state — logging 288 of those a day would bury the
      // signal. Manual runs always log (a human wants the answer).
      if (triggerSource === "cron" && !stats.api_calls && !stats.results_updated && !stats.fixtures_imported) {
        results.push({ provider: provider.id, ok: true, idle: true });
        continue;
      }
      await logRun({ ok: true, stats, log });
      results.push({ provider: provider.id, ok: true, ...stats });
    } catch (e) {
      await logRun({ ok: false, error: (e as Error).message });
      results.push({ provider: provider.id, error: (e as Error).message });
    }
  }

  return json(200, { ok: true, providers: results });
});
