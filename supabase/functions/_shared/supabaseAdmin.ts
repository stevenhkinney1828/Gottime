import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

/**
 * Service-role client: bypasses RLS entirely. Only for the privileged operations this
 * backend exists to perform (authorizing calls, writing status callbacks, registering
 * devices). Never exposed to the iOS app; the service role key lives only in Supabase's
 * Edge Function secret store.
 */
export function supabaseAdmin(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceRoleKey) {
    throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set");
  }
  return createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

/**
 * Request-scoped client: forwards the caller's own JWT, so RLS applies exactly as it would
 * for a direct client query. Use this for reads that should be limited to what the caller is
 * actually allowed to see, instead of reimplementing that check by hand.
 */
export function supabaseForRequest(req: Request): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anonKey) {
    throw new Error("SUPABASE_URL and SUPABASE_ANON_KEY must be set");
  }
  const authHeader = req.headers.get("Authorization") ?? "";
  return createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
