// Gameweek sportmonks-ingest — the sports-data feed worker.
//
// Runs inside Supabase (pg_cron POSTs here every 5 minutes; /data's Ingest
// page triggers it manually). Sync policy: the feed may ONLY touch
// gw_dm_events rows an admin explicitly mapped (provider_ids.sportmonks) —
// unmapped rows are invisible to it, which is what keeps the hand-curated
// database safe. It updates kickoff times and final results, then chains
// score-round (service-to-service) for every round an updated event sits in.
// Every iteration — cron or manual, success, failure, or skip — is logged to
// gw_ingest_runs for the /data audit page.
//
// Activation: supabase secrets set SPORTMONKS_API_KEY=...  (until then,
// cron runs no-op silently and manual runs log a "not configured" row).
//
// Deploy: supabase functions deploy sportmonks-ingest

import { createClient } from "npm:@supabase/supabase-js@2";
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

const SM_BASE = "https://api.sportmonks.com/v3/football";
const CRON_MIN_INTERVAL_MS = 4 * 60 * 1000; // dampen abuse of the public trigger

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const service = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // ── who is calling? admin = manual run; anyone else = the cron path ─────
  // The cron path is deliberately open to any anon-key caller: it can only
  // cause the same idempotent, rate-limited sync the schedule causes anyway.
  let triggerSource = "cron";
  let initiatedBy: string | null = null;
  const authHeader = req.headers.get("Authorization") || "";
  try {
    const asCaller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
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

  const apiKey = Deno.env.get("SPORTMONKS_API_KEY");
  const startedAt = Date.now();
  const log: Array<{ level: string; msg: string }> = [];
  const logRun = async (fields: Record<string, unknown>) => {
    const { error } = await service.from("gw_ingest_runs").insert({
      trigger_source: triggerSource, initiated_by: initiatedBy,
      duration_ms: Date.now() - startedAt, log, ...fields,
    });
    if (error) console.error("ingest log write failed:", error.message);
  };

  if (!apiKey) {
    // Cron churning every 5 minutes must not flood the audit table while
    // the integration is dormant; a human clicking Run deserves an answer.
    if (triggerSource === "manual") {
      await logRun({ ok: false, error: "SPORTMONKS_API_KEY not configured — set it with: supabase secrets set SPORTMONKS_API_KEY=..." });
      return json(409, { error: "SPORTMONKS_API_KEY not configured" });
    }
    return json(200, { skipped: "no api key" });
  }

  try {
    // ── mapped events in the sync window (recent past + near future) ──────
    const since = new Date(Date.now() - 7 * 864e5).toISOString();
    const { data: mapped, error: mapErr } = await service.from("gw_dm_events")
      .select("id,provider_ids,kickoff_at,result,status")
      .not("provider_ids->sportmonks", "is", null)
      .gte("kickoff_at", since)
      .limit(2000);
    if (mapErr) throw new Error(`mapped-events load failed: ${mapErr.message}`);
    const bySmId: Record<string, { id: string; kickoff_at: string | null; result: { h: number; a: number } | null }> = {};
    (mapped || []).forEach((e: { id: string; provider_ids: { sportmonks?: number | string }; kickoff_at: string | null; result: { h: number; a: number } | null }) => {
      bySmId[String(e.provider_ids.sportmonks)] = e;
    });
    const smIds = Object.keys(bySmId);
    const stats: Record<string, number> = {
      events_mapped: smIds.length, fixtures_checked: 0,
      results_updated: 0, kickoffs_updated: 0, rounds_scored: 0,
    };

    if (!smIds.length) {
      log.push({ level: "info", msg: "no mapped events in the sync window — map provider ids on events to activate syncing" });
      await logRun({ ok: true, stats });
      return json(200, { ok: true, ...stats });
    }

    // ── fetch fixtures from SportMonks in id batches ──────────────────────
    const updatedEventIds: string[] = [];
    for (let i = 0; i < smIds.length; i += 50) {
      const batch = smIds.slice(i, i + 50);
      const res = await fetch(`${SM_BASE}/fixtures/multi/${batch.join(",")}?include=scores;state`, {
        headers: { Authorization: apiKey },
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

    // ── chain scoring for every round an updated event sits in ────────────
    if (updatedEventIds.length) {
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
      const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
      for (const s of scopes) {
        const r = await fetch(`${url}/functions/v1/score-round`, {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${serviceKey}` },
          body: JSON.stringify(s),
        });
        if (r.ok) stats.rounds_scored++;
        else log.push({ level: "error", msg: `score-round ${s.client_key}/${s.round_id}: HTTP ${r.status}` });
      }
    }

    await logRun({ ok: true, stats });
    return json(200, { ok: true, ...stats });
  } catch (e) {
    log.push({ level: "error", msg: (e as Error).message });
    await logRun({ ok: false, error: (e as Error).message });
    return json(500, { error: (e as Error).message });
  }
});
