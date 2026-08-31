// Gameweek provider-browse — admin-only proxy for the /data mapping UI.
//
// Provider API tokens live in gw_providers and never reach a browser; when
// an admin maps a tournament, /data asks THIS function to browse leagues or
// fixtures with the stored token. The 'fixtures' resource optionally takes
// the caller's events+teams snapshot and returns match suggestions computed
// by the shared fixture_match module — one implementation, server-side.
//
// Every call spends provider API quota, so this is strictly admin-gated
// (unlike data-ingest's open-but-rate-limited cron path).
//
// Deploy: supabase functions deploy provider-browse

import { createClient } from "npm:@supabase/supabase-js@2";
// @ts-ignore — plain ESM shared with the vitest suite
import { parseFixture, parseLeague, parseStandings } from "../_shared/sportmonks_adapter.mjs";
// @ts-ignore — plain ESM shared with the vitest suite
import { suggestFixtureLinks } from "../_shared/fixture_match.mjs";

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

async function smPaged(base: string, token: string, path: string, maxPages: number): Promise<unknown[]> {
  const out: unknown[] = [];
  for (let page = 1; page <= maxPages; page++) {
    const sep = path.includes("?") ? "&" : "?";
    const res = await fetch(`${base}${path}${sep}per_page=50&page=${page}`, { headers: { Authorization: token } });
    if (!res.ok) throw new Error(`SportMonks ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const payload = await res.json();
    out.push(...(payload.data || []));
    if (!payload.pagination?.has_more) break;
  }
  return out;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const service = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const asCaller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
  });
  const { data: userData } = await asCaller.auth.getUser();
  if (!userData?.user) return json(401, { error: "not signed in" });
  const { data: adminRow } = await service
    .from("gw_admins").select("id").eq("auth_id", userData.user.id).maybeSingle();
  if (!adminRow) return json(403, { error: "not a platform admin" });

  let body: { provider?: string; resource?: string; from?: string; to?: string; league_id?: number | string;
              events?: Array<{ id: string; homeId: string; awayId: string; kickoffAt: string | null }>;
              teams?: Record<string, { name: string }> };
  try { body = await req.json(); } catch { return json(400, { error: "invalid JSON body" }); }

  const { data: provider } = await service.from("gw_providers").select("*").eq("id", body.provider || "").maybeSingle();
  if (!provider) return json(404, { error: "provider not found" });
  if (!provider.token) return json(409, { error: "no API token configured for this provider" });
  if (provider.id !== "sportmonks") return json(400, { error: `no browse adapter implemented for provider '${provider.id}'` });

  const base = provider.base_url || "https://api.sportmonks.com/v3/football";
  try {
    if (body.resource === "leagues") {
      const rows = await smPaged(base, provider.token, "/leagues", 3);
      return json(200, { data: rows.map((l) => parseLeague(l)) });
    }
    if (body.resource === "fixtures") {
      if (!body.from || !body.to || !body.league_id) return json(400, { error: "from, to and league_id are required" });
      const rows = await smPaged(base, provider.token,
        `/fixtures/between/${body.from}/${body.to}?include=participants;scores;state&filters=fixtureLeagues:${body.league_id}`, 4);
      const fixtures = rows.map((f) => parseFixture(f));
      const suggestions = (body.events && body.teams)
        ? suggestFixtureLinks(fixtures, body.events, body.teams)
        : null;
      return json(200, { data: fixtures, suggestions });
    }
    if (body.resource === "standings") {
      if (!body.league_id) return json(400, { error: "league_id is required" });
      // league -> current season -> season standings (2 API calls)
      const lres = await fetch(`${base}/leagues/${body.league_id}?include=currentSeason`, { headers: { Authorization: provider.token } });
      if (!lres.ok) throw new Error(`SportMonks ${lres.status}: ${(await lres.text()).slice(0, 300)}`);
      const seasonId = (await lres.json()).data?.currentseason?.id;
      if (!seasonId) return json(404, { error: "no current season found for this league" });
      const rows = await smPaged(base, provider.token, `/standings/seasons/${seasonId}?include=participant;details.type`, 2);
      return json(200, { data: parseStandings(rows), season_id: seasonId });
    }
    return json(400, { error: "unknown resource" });
  } catch (e) {
    return json(502, { error: (e as Error).message });
  }
});
