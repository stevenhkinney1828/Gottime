import { handlePreflight, jsonResponse } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";

// Phase 1 (Mocked UX) for decline/cancel/end-early against mock state; Phase 6 (Timer
// enforcement) for the real Twilio-backed end-early path. Ownership-checked: a caller can
// only act on a call_sessions row they're a participant in. Not yet implemented — see
// BUILD_STATUS.md.
export function handler(req: Request): Response {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  log("call_state", "call-action called", { method: req.method });
  return jsonResponse({ error: "not_implemented", phase: 1 }, { status: 501 });
}

if (import.meta.main) {
  Deno.serve(handler);
}
