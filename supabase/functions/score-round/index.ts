// Gameweek score-round — Phase 3.2 of the rearchitecture.
//
// Scores one round of one competition server-side and stores the outcome:
//   * gw_predictions.points per prediction (null = still unscorable)
//   * gw_leaderboards rows for the round scope AND the overall scope
// The computation itself lives in ../_shared/score_round_compute.mjs (pure,
// vitest-covered); this file is authentication + I/O only.
//
// Idempotent by construction: every call recomputes from the current
// predictions + results, so re-running after a result correction simply
// overwrites — that is the "re-score round" button's whole implementation.
//
// Caller must be a platform admin (gw_admins row for the JWT's auth uid).
// Later phases widen this to the competition's own operator.
//
// Deploy: supabase functions deploy score-round
// (JWT verification stays ON — /data calls this through
// supabase.functions.invoke with the admin's session token attached.)

import { createClient } from "npm:@supabase/supabase-js@2";
// @ts-ignore — plain ESM module shared with the vitest suite
import { computeCompScores } from "../_shared/score_round_compute.mjs";

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

const SCOREABLE_MODES = ["score", "betting", "ranking", "lineup"];

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const service = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // ── caller must be a platform admin ─────────────────────────────────────
  const authHeader = req.headers.get("Authorization") || "";
  const asCaller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await asCaller.auth.getUser();
  if (userErr || !userData?.user) return json(401, { error: "not signed in" });
  const { data: adminRow } = await service
    .from("gw_admins").select("id").eq("auth_id", userData.user.id).maybeSingle();
  if (!adminRow) return json(403, { error: "not a platform admin" });

  // ── input ───────────────────────────────────────────────────────────────
  let body: { client_key?: string; competition_id?: string; round_id?: string };
  try { body = await req.json(); } catch { return json(400, { error: "invalid JSON body" }); }
  const { client_key, competition_id, round_id } = body;
  if (!client_key || !competition_id || !round_id) {
    return json(400, { error: "client_key, competition_id and round_id are required" });
  }

  // ── load ────────────────────────────────────────────────────────────────
  const [{ data: comp }, { data: rounds }, { data: predictions }] = await Promise.all([
    service.from("gw_competitions").select("*").eq("client_key", client_key).eq("id", competition_id).maybeSingle(),
    service.from("gw_rounds").select("*").eq("client_key", client_key).eq("competition_id", competition_id),
    service.from("gw_predictions").select("id,player_id,username,round_id,event_id,prediction,points")
      .eq("client_key", client_key).eq("competition_id", competition_id).limit(100000),
  ]);
  if (!comp) return json(404, { error: "competition not found" });
  if (!SCOREABLE_MODES.includes(comp.mode)) return json(400, { error: `mode ${comp.mode} is not scoreable` });

  // A lineup "round" is the tracked team's fixture — round_id IS the event
  // id and there is no gw_rounds row to find.
  const targetRound = (rounds || []).find((r: { id: string }) => r.id === round_id) || null;
  if (comp.mode !== "lineup" && !targetRound) return json(404, { error: "round not found" });

  const eventIds = new Set<string>();
  (rounds || []).forEach((r: { event_ids?: string[] }) => (r.event_ids || []).forEach((id) => eventIds.add(id)));
  if (comp.mode === "lineup") (predictions || []).forEach((p: { round_id: string }) => eventIds.add(p.round_id));
  const { data: evRows } = eventIds.size
    ? await service.from("gw_dm_events").select("id,home_id,away_id,result,lineup,scorers").in("id", [...eventIds])
    : { data: [] };
  const events: Record<string, unknown> = {};
  (evRows || []).forEach((e: { id: string }) => { events[e.id] = e; });

  const teamIds = new Set<string>();
  (evRows || []).forEach((e: { home_id?: string; away_id?: string }) => {
    if (e.home_id) teamIds.add(e.home_id);
    if (e.away_id) teamIds.add(e.away_id);
  });
  const { data: teamRows } = teamIds.size
    ? await service.from("gw_dm_teams").select("id,name").in("id", [...teamIds])
    : { data: [] };
  const teamNames: Record<string, string> = {};
  (teamRows || []).forEach((t: { id: string; name: string }) => { teamNames[t.id] = t.name; });

  // ── compute ─────────────────────────────────────────────────────────────
  const { predictionPoints, roundRows, overallRows } = computeCompScores({
    comp, rounds: rounds || [], events, teamNames, predictions: predictions || [], targetRoundId: round_id,
  });

  // ── write: per-prediction points (only the ones that changed) ───────────
  const stored: Record<string, number | null> = {};
  (predictions || []).forEach((p: { id: string; points: number | null }) => { stored[p.id] = p.points; });
  const changed = predictionPoints.filter((pp: { id: string; points: number | null }) => stored[pp.id] !== pp.points);
  for (let i = 0; i < changed.length; i += 20) {
    const chunk = changed.slice(i, i + 20);
    const results = await Promise.all(chunk.map((pp: { id: string; points: number | null }) =>
      service.from("gw_predictions").update({ points: pp.points }).eq("id", pp.id)));
    const failed = results.find((r) => r.error);
    if (failed?.error) return json(500, { error: `points write failed: ${failed.error.message}` });
  }

  // ── write: leaderboard scopes (upsert current, delete departed) ─────────
  const scope = { client_key, competition_id };
  const writeScope = async (rows: Array<Record<string, unknown>>, roundIdOrNull: string | null) => {
    const payload = rows.map((r) => ({ ...scope, round_id: roundIdOrNull, ...r, updated_at: new Date().toISOString() }));
    if (payload.length) {
      const { error } = await service.from("gw_leaderboards")
        .upsert(payload, { onConflict: "client_key,competition_id,round_id,player_id" });
      if (error) throw new Error(`leaderboard upsert failed: ${error.message}`);
    }
    // players who no longer have predictions in this scope (deleted rows)
    let del = service.from("gw_leaderboards").delete()
      .eq("client_key", client_key).eq("competition_id", competition_id);
    del = roundIdOrNull === null ? del.is("round_id", null) : del.eq("round_id", roundIdOrNull);
    if (payload.length) del = del.not("player_id", "in", `(${rows.map((r) => `"${r.player_id}"`).join(",")})`);
    const { error: delErr } = await del;
    if (delErr) throw new Error(`leaderboard cleanup failed: ${delErr.message}`);
  };
  try {
    await writeScope(roundRows, round_id);
    await writeScope(overallRows, null);
  } catch (e) {
    return json(500, { error: (e as Error).message });
  }

  return json(200, {
    ok: true,
    mode: comp.mode,
    round_id,
    predictions_scored: predictionPoints.length,
    predictions_updated: changed.length,
    round_rows: roundRows.length,
    overall_rows: overallRows.length,
  });
});
