import { handlePreflight, jsonResponse } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";
import { supabaseAdmin, supabaseForRequest } from "../_shared/supabaseAdmin.ts";
import { type CallSessionRecord, requestCall, type RequestCallClient } from "./logic.ts";

/** Real Supabase-backed implementation of RequestCallClient. Untested pending a live
 * Supabase project (Phase 2+) — the logic it wraps (requestCall, in logic.ts) is fully
 * tested; this adapter is deliberately thin, and `deno check` at least verifies its calls
 * match supabase-js's real type signatures even without a live project to run against. */
class SupabaseRequestCallClient implements RequestCallClient {
  async hasActiveConnection(userA: string, userB: string): Promise<boolean> {
    const admin = supabaseAdmin();
    const { data, error } = await admin
      .from("connections")
      .select("id")
      .eq("status", "active")
      .or(
        `and(user_a_id.eq.${userA},user_b_id.eq.${userB}),and(user_a_id.eq.${userB},user_b_id.eq.${userA})`,
      )
      .limit(1);
    if (error) throw error;
    return (data?.length ?? 0) > 0;
  }

  async createCallSession(
    params: { callerId: string; recipientId: string; requestedDurationSeconds: number },
  ): Promise<CallSessionRecord> {
    const admin = supabaseAdmin();
    const { data, error } = await admin
      .from("call_sessions")
      .insert({
        caller_id: params.callerId,
        recipient_id: params.recipientId,
        requested_duration_seconds: params.requestedDurationSeconds,
        status: "created",
      })
      .select("id, call_uuid, caller_id, recipient_id, requested_duration_seconds, status")
      .single();
    if (error) throw error;
    return {
      id: data.id,
      callUuid: data.call_uuid,
      callerId: data.caller_id,
      recipientId: data.recipient_id,
      requestedDurationSeconds: data.requested_duration_seconds,
      status: data.status,
    };
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
    log("auth", "request-call: missing or invalid session");
    return jsonResponse({ error: "not authenticated" }, { status: 401 });
  }
  const callerId = userData.user.id;

  let body: { recipientId?: string; requestedDurationSeconds?: unknown };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "invalid JSON body" }, { status: 400 });
  }

  const result = await requestCall(new SupabaseRequestCallClient(), {
    callerId,
    recipientId: body.recipientId ?? "",
    requestedDurationSeconds: body.requestedDurationSeconds,
  });

  if (!result.ok) {
    log("request", "request-call rejected", { error: result.error, status: result.status });
    return jsonResponse({ error: result.error }, { status: result.status });
  }

  log("request", "request-call succeeded", { callUuid: result.session.callUuid });
  return jsonResponse({ session: result.session }, { status: 201 });
}

if (import.meta.main) {
  Deno.serve(handler);
}
