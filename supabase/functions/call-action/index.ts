import { handlePreflight, jsonResponse } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";
import { supabaseAdmin, supabaseForRequest } from "../_shared/supabaseAdmin.ts";
import { type CallActionClient, type CallSessionRow, performCallAction } from "./logic.ts";

/** Real Supabase-backed implementation of CallActionClient. Untested pending a live Supabase
 * project (Phase 2+) — the logic it wraps (performCallAction, in logic.ts) is fully tested. */
class SupabaseCallActionClient implements CallActionClient {
  async getCallSession(callSessionId: string): Promise<CallSessionRow | null> {
    const admin = supabaseAdmin();
    const { data, error } = await admin
      .from("call_sessions")
      .select("id, caller_id, recipient_id, status")
      .eq("id", callSessionId)
      .maybeSingle();
    if (error) throw error;
    if (!data) return null;
    return {
      id: data.id,
      callerId: data.caller_id,
      recipientId: data.recipient_id,
      status: data.status,
    };
  }

  async updateStatus(callSessionId: string, status: string): Promise<void> {
    const admin = supabaseAdmin();
    const { error } = await admin
      .from("call_sessions")
      .update({ status })
      .eq("id", callSessionId);
    if (error) throw error;
  }
}

export async function handler(req: Request): Promise<Response> {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "method not allowed" }, { status: 405 });
  }

  const requestClient = supabaseForRequest(req);
  const { data: userData, error: userError } = await requestClient.auth.getUser();
  if (userError || !userData?.user) {
    log("auth", "call-action: missing or invalid session");
    return jsonResponse({ error: "not authenticated" }, { status: 401 });
  }

  let body: { callSessionId?: string; action?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "invalid JSON body" }, { status: 400 });
  }

  const result = await performCallAction(new SupabaseCallActionClient(), {
    actingUserId: userData.user.id,
    callSessionId: body.callSessionId ?? "",
    action: body.action ?? "",
  });

  if (!result.ok) {
    log("call_state", "call-action rejected", { error: result.error, status: result.status });
    return jsonResponse({ error: result.error }, { status: result.status });
  }

  log("call_state", "call-action succeeded", { newStatus: result.newStatus });
  return jsonResponse({ status: result.newStatus }, { status: 200 });
}

if (import.meta.main) {
  Deno.serve(handler);
}
