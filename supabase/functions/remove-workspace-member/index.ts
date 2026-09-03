// Remove a workspace member — the only path that also disables their login.
//
// The client-admin "Team" page calls this (supabase.functions.invoke, which
// forwards the caller's JWT). We verify the caller owns a workspace, that the
// target is a member of THAT workspace, then delete the target's Supabase
// auth user. Deleting the auth user cascades gw_workspace_members (FK ON
// DELETE CASCADE), so the person can no longer sign in anywhere.
//
// Deploy: supabase functions deploy remove-workspace-member

import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const authHeader = req.headers.get("Authorization") || "";
  if (!authHeader) return json(401, { error: "missing_auth" });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(400, { error: "invalid_json" }); }
  const memberAuthId = typeof body.member_auth_id === "string" ? body.member_auth_id.trim() : "";
  if (!memberAuthId) return json(400, { error: "missing_member_auth_id" });

  // Who is calling?
  const asCaller = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userErr } = await asCaller.auth.getUser();
  const callerId = userData?.user?.id;
  if (userErr || !callerId) return json(401, { error: "not_authenticated" });

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  // Caller must own a workspace.
  const { data: op, error: opErr } = await admin
    .from("gw_operators")
    .select("client_key")
    .eq("auth_id", callerId)
    .maybeSingle();
  if (opErr) { console.error("remove-member: operator lookup:", opErr.message); return json(500, { error: "server_error" }); }
  if (!op?.client_key) return json(403, { error: "not_workspace_owner" });

  if (memberAuthId === callerId) return json(400, { error: "cannot_remove_self" });

  // Target must be a member of THIS workspace.
  const { data: member, error: memErr } = await admin
    .from("gw_workspace_members")
    .select("auth_id")
    .eq("client_key", op.client_key)
    .eq("auth_id", memberAuthId)
    .maybeSingle();
  if (memErr) { console.error("remove-member: member lookup:", memErr.message); return json(500, { error: "server_error" }); }
  if (!member) return json(404, { error: "not_a_member" });

  // Delete the auth user — this cascades the gw_workspace_members row.
  const { error: delErr } = await admin.auth.admin.deleteUser(memberAuthId);
  if (delErr) { console.error("remove-member: deleteUser:", delErr.message); return json(500, { error: "server_error" }); }

  // Belt-and-braces in case the cascade lagged.
  await admin.from("gw_workspace_members")
    .delete()
    .eq("client_key", op.client_key)
    .eq("auth_id", memberAuthId);

  return json(200, { removed: true });
});
