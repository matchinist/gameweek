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
import { parseFixture } from "../_shared/sportmonks_adapter.mjs";

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

async function runSportmonks(service: SupabaseClient, provider: ProviderRow): Promise<RunResult> {
  const log: LogLine[] = [];
  const base = provider.base_url || "https://api.sportmonks.com/v3/football";
  const since = new Date(Date.now() - 7 * 864e5).toISOString();
  const { data: mapped, error: mapErr } = await service.from("gw_dm_events")
    .select("id,provider_ids,kickoff_at,result,status")
    .not(`provider_ids->${provider.id}`, "is", null)
    .gte("kickoff_at", since)
    .limit(2000);
  if (mapErr) throw new Error(`mapped-events load failed: ${mapErr.message}`);
  const bySmId: Record<string, { id: string; kickoff_at: string | null; result: { h: number; a: number } | null }> = {};
  (mapped || []).forEach((e: { id: string; provider_ids: Record<string, number | string>; kickoff_at: string | null; result: { h: number; a: number } | null }) => {
    bySmId[String(e.provider_ids[provider.id])] = e;
  });
  const smIds = Object.keys(bySmId);
  const stats: Record<string, number> = {
    events_mapped: smIds.length, fixtures_checked: 0,
    results_updated: 0, kickoffs_updated: 0, rounds_scored: 0,
  };
  if (!smIds.length) {
    log.push({ level: "info", msg: "no mapped events in the sync window — map provider ids on events to activate syncing" });
    return { stats, log };
  }

  const updatedEventIds: string[] = [];
  for (let i = 0; i < smIds.length; i += 50) {
    const batch = smIds.slice(i, i + 50);
    const res = await fetch(`${base}/fixtures/multi/${batch.join(",")}?include=scores;state`, {
      headers: { Authorization: provider.token! },
    });
    if (!res.ok) throw new Error(`SportMonks ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const payload = await res.json();
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

  stats.rounds_scored = await scoreAffectedRounds(service, updatedEventIds, log);
  return { stats, log };
}

const ADAPTERS: Record<string, (service: SupabaseClient, provider: ProviderRow) => Promise<RunResult>> = {
  sportmonks: runSportmonks,
};

// After results land, every round containing an updated event re-scores
// through score-round (service-to-service; the audit shows service:ingest).
async function scoreAffectedRounds(service: SupabaseClient, updatedEventIds: string[], log: LogLine[]): Promise<number> {
  if (!updatedEventIds.length) return 0;
  const scopes: Array<{ client_key: string; competition_id: string; round_id: string }> = [];
  const { data: rounds } = await service.from("gw_rounds")
    .select("id,client_key,competition_id,event_ids")
    .overlaps("event_ids", updatedEventIds);
  (rounds || []).forEach((r: { id: string; client_key: string; competition_id: string }) =>
    scopes.push({ client_key: r.client_key, competition_id: r.competition_id, round_id: r.id }));
  const { data: lineupComps } = await service.from("gw_competitions")
    .select("id,client_key,lineup_config").eq("mode", "lineup").eq("status", "active");
  const { data: updatedEvents } = await service.from("gw_dm_events")
    .select("id,home_id,away_id").in("id", updatedEventIds);
  (lineupComps || []).forEach((c: { id: string; client_key: string; lineup_config?: { teamId?: string } }) => {
    const tid = c.lineup_config?.teamId;
    (updatedEvents || []).forEach((e: { id: string; home_id: string; away_id: string }) => {
      if (tid && (tid === e.home_id || tid === e.away_id))
        scopes.push({ client_key: c.client_key, competition_id: c.id, round_id: e.id });
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
    else log.push({ level: "error", msg: `score-round ${s.client_key}/${s.round_id}: HTTP ${r.status}` });
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
      const { stats, log } = await adapter(service, provider);
      await logRun({ ok: true, stats, log });
      results.push({ provider: provider.id, ok: true, ...stats });
    } catch (e) {
      await logRun({ ok: false, error: (e as Error).message });
      results.push({ provider: provider.id, error: (e as Error).message });
    }
  }

  return json(200, { ok: true, providers: results });
});
