import { handlePreflight, jsonResponse } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";

// Phase 5 (CallKit/PushKit): upsert a device_registrations row for the authenticated user's
// VoIP push token, validating token format and resolving the push environment
// (sandbox/production) server-side. Not yet implemented — see BUILD_STATUS.md.
export function handler(req: Request): Response {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  log("push", "register-device called", { method: req.method });
  return jsonResponse({ error: "not_implemented", phase: 5 }, { status: 501 });
}

if (import.meta.main) {
  Deno.serve(handler);
}
