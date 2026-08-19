import { handlePreflight, jsonResponse } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";

// Phase 1 (Mocked UX): validate caller/recipient/connection/duration server-side and create
// the call_sessions row with a stable call_uuid. Never trusts client-supplied values for the
// actual authorization decision (spec section 13). Not yet implemented — see
// BUILD_STATUS.md.
export function handler(req: Request): Response {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  log("request", "request-call called", { method: req.method });
  return jsonResponse({ error: "not_implemented", phase: 1 }, { status: 501 });
}

if (import.meta.main) {
  Deno.serve(handler);
}
