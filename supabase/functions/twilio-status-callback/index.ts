import { handlePreflight } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";
import { supabaseAdmin } from "../_shared/supabaseAdmin.ts";
import { type ClientCallStatus, planStatusTransition } from "./logic.ts";

// Twilio status callback webhook, registered via the statusCallback attribute twiml-voice puts
// on the <Client> noun (see that function's logic.ts) — the call_session_id query parameter is
// how this learns which row to update, since Twilio delivers no custom application data to a
// server webhook (only to the Voice SDK client itself). Records ringing_at/connected_at as
// Twilio itself reports them — connected_at set here, not just trusted from the client's own
// clock, is what makes "the timer starts only on connection" (spec section 7) authoritative.
// Always responds 204 regardless of outcome: Twilio only checks the status code to decide
// whether to retry, and doesn't parse a body for this kind of webhook the way it does for
// twiml-voice's TwiML response.
export async function handler(req: Request): Promise<Response> {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const callSessionId = new URL(req.url).searchParams.get("call_session_id");
  const form = await req.formData();
  const clientCallStatus = form.get("CallStatus")?.toString() as ClientCallStatus | undefined;

  if (!callSessionId || !clientCallStatus) {
    log("twilio", "twilio-status-callback: missing call_session_id or CallStatus");
    return new Response(null, { status: 204 });
  }

  const transition = planStatusTransition(clientCallStatus);
  if (!transition) {
    log("twilio", "twilio-status-callback: no-op event", { callSessionId, clientCallStatus });
    return new Response(null, { status: 204 });
  }

  const admin = supabaseAdmin();
  const { error } = await admin
    .from("call_sessions")
    .update({
      status: transition.newStatus,
      [transition.timestampField]: new Date().toISOString(),
    })
    .eq("id", callSessionId)
    .in("status", transition.requiredCurrentStatuses);

  if (error) {
    log("twilio", "twilio-status-callback: update failed", {
      callSessionId,
      error: error.message,
    });
  } else {
    log("call_state", "twilio-status-callback: applied transition", {
      callSessionId,
      newStatus: transition.newStatus,
    });
  }

  return new Response(null, { status: 204 });
}

if (import.meta.main) {
  Deno.serve(handler);
}
