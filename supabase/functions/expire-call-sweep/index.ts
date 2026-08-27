import { handlePreflight, jsonResponse } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";
import { supabaseAdmin } from "../_shared/supabaseAdmin.ts";
import {
  type ExpireCallSweepClient,
  runSweep,
  type StaleSessionCandidate,
  type SweepUpdate,
} from "./logic.ts";

// Invoked on a schedule by pg_cron + pg_net (see migration 0013_expire_call_sweep_cron.sql),
// authenticated with a service-role JWT stored in Supabase Vault — never a signed-in user's own
// token, since this sweeps every user's stale sessions, not just one. Uses supabaseAdmin (bypasses
// RLS) for exactly that reason.
class SupabaseExpireCallSweepClient implements ExpireCallSweepClient {
  async fetchCandidates(): Promise<StaleSessionCandidate[]> {
    const admin = supabaseAdmin();
    const { data, error } = await admin
      .from("call_sessions")
      .select("id, status, initiated_at, connected_at, requested_duration_seconds")
      .in("status", ["created", "outgoing", "ringing", "connected", "timed_out"]);
    if (error) throw error;
    return (data ?? []).map((row) => ({
      id: row.id,
      status: row.status,
      initiatedAt: row.initiated_at,
      connectedAt: row.connected_at,
      requestedDurationSeconds: row.requested_duration_seconds,
    }));
  }

  async applyUpdate(update: SweepUpdate): Promise<boolean> {
    const admin = supabaseAdmin();
    const now = new Date().toISOString();
    const { data, error } = await admin
      .from("call_sessions")
      .update({
        status: update.toStatus,
        ended_at: now,
        updated_at: now,
        actual_duration_seconds: update.actualDurationSeconds,
      })
      .eq("id", update.id)
      // Guards against a race where the session resolved normally between fetchCandidates and
      // this update -- idempotent by construction, matching twilio-status-callback's own
      // established pattern, not an extra check bolted on.
      .eq("status", update.fromStatus)
      .select("id");
    if (error) throw error;
    return (data?.length ?? 0) > 0;
  }
}

export async function handler(req: Request): Promise<Response> {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const result = await runSweep(new SupabaseExpireCallSweepClient(), new Date());
  log("timer", "expire-call-sweep invoked", {
    candidateCount: result.candidateCount,
    appliedCount: result.appliedCount,
  });
  return jsonResponse(result, { status: 200 });
}

if (import.meta.main) {
  Deno.serve(handler);
}
