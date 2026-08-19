import { handlePreflight, jsonResponse } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";

// Phase 4 (Voice proof): Twilio status callback webhook. Records ringing_at/connected_at/
// ended_at as Twilio reports them — connected_at set here is what makes "the timer starts
// only on connection" authoritative rather than trusting the client's own clock alone. Not
// yet implemented — see BUILD_STATUS.md.
export function handler(req: Request): Response {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  log("twilio", "twilio-status-callback called", { method: req.method });
  return jsonResponse({ error: "not_implemented", phase: 4 }, { status: 501 });
}

if (import.meta.main) {
  Deno.serve(handler);
}
