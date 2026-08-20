import { handlePreflight, jsonResponse } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";
import { supabaseAdmin, supabaseForRequest } from "../_shared/supabaseAdmin.ts";
import { type DeleteAccountClient, performDeleteAccount } from "./logic.ts";

/** Real Supabase-backed implementation of DeleteAccountClient. Untested pending a live
 * Supabase project (Phase 2+) — the logic it wraps (performDeleteAccount, in logic.ts) is
 * fully tested. profiles and everything else cascades from this via the migrations' `on
 * delete cascade` foreign keys (0001-0005) — nothing else needs deleting here explicitly. */
class SupabaseDeleteAccountClient implements DeleteAccountClient {
  async deleteUser(userId: string): Promise<void> {
    const admin = supabaseAdmin();
    const { error } = await admin.auth.admin.deleteUser(userId);
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
    log("auth", "delete-account: missing or invalid session");
    return jsonResponse({ error: "not authenticated" }, { status: 401 });
  }

  const result = await performDeleteAccount(new SupabaseDeleteAccountClient(), {
    actingUserId: userData.user.id,
  });

  if (!result.ok) {
    log("auth", "delete-account rejected", { error: result.error, status: result.status });
    return jsonResponse({ error: result.error }, { status: result.status });
  }

  log("auth", "delete-account succeeded", { userId: userData.user.id });
  return jsonResponse({ deleted: true }, { status: 200 });
}

if (import.meta.main) {
  Deno.serve(handler);
}
