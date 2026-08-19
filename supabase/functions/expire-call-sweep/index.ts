import { handlePreflight, jsonResponse } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";

// Phase 6 (Timer enforcement): cron-invoked backstop (via pg_cron + pg_net). Force-completes
// any call_sessions row past its computed expiry that Twilio hasn't already closed out — the
// third and final layer of duration enforcement described in DECISIONS.md. Not yet
// implemented — see BUILD_STATUS.md.
export function handler(req: Request): Response {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  log("timer", "expire-call-sweep invoked", { method: req.method });
  return jsonResponse({ error: "not_implemented", phase: 6 }, { status: 501 });
}

if (import.meta.main) {
  Deno.serve(handler);
}
