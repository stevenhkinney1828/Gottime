import { handlePreflight } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";

// Phase 4 (Voice proof): Twilio webhook — responds to an incoming app-to-app call attempt
// with <Dial><Client> TwiML routing to the recipient's Twilio Voice identity, including the
// server-side timeLimit. Twilio expects TwiML (XML), not JSON, so even this not-yet-
// implemented stub returns a minimal valid empty response rather than an error body. Not yet
// implemented — see BUILD_STATUS.md.
export function handler(req: Request): Response {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  log("twilio", "twiml-voice called", { method: req.method });
  return new Response("<Response></Response>", {
    status: 200,
    headers: { "Content-Type": "text/xml" },
  });
}

if (import.meta.main) {
  Deno.serve(handler);
}
