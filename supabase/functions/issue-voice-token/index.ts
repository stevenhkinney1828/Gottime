import { handlePreflight, jsonResponse } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";

// Phase 4 (Voice proof): mint a short-lived Twilio Voice Access Token for the authenticated
// caller, scoped to their Twilio Voice SDK identity. Not yet implemented — see
// BUILD_STATUS.md.
export function handler(req: Request): Response {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  log("request", "issue-voice-token called", { method: req.method });
  return jsonResponse({ error: "not_implemented", phase: 4 }, { status: 501 });
}

if (import.meta.main) {
  Deno.serve(handler);
}
