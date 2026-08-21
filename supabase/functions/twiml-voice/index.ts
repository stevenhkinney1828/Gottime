import { handlePreflight } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";
import { supabaseAdmin } from "../_shared/supabaseAdmin.ts";
import { buildDialTwiml, isRequestFromCaller, REJECT_TWIML } from "./logic.ts";

function xmlResponse(xml: string): Response {
  return new Response(xml, { status: 200, headers: { "Content-Type": "text/xml" } });
}

// Twilio webhook — fires when the caller's Voice SDK connects(), having passed callSessionId
// as a custom outgoing param (TVOConnectOptions.params on iOS), which Twilio forwards here as
// a plain form field (never JSON — this is a Twilio-to-us request, not app-to-us). Responds
// with <Dial><Client> TwiML routing to the recipient's Twilio Voice identity (their Supabase
// user id) with the requested duration as the Dial's own timeLimit. <Response><Reject/></Response>
// on any failure — a webhook this deep in a call setup has no user-facing surface to report an
// error to; the call simply fails to connect, which the client-side call flow already handles
// (request-call's own validation is what should catch most bad-input cases well before this).
export async function handler(req: Request): Promise<Response> {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const form = await req.formData();
  const callSessionId = form.get("callSessionId")?.toString();
  const from = form.get("From")?.toString() ?? null;
  if (!callSessionId) {
    log("twilio", "twiml-voice: missing callSessionId param");
    return xmlResponse(REJECT_TWIML);
  }

  const admin = supabaseAdmin();
  const { data: session, error } = await admin
    .from("call_sessions")
    .select("id, caller_id, recipient_id, requested_duration_seconds")
    .eq("id", callSessionId)
    .maybeSingle();

  if (error || !session) {
    log("twilio", "twiml-voice: call session not found", { callSessionId });
    return xmlResponse(REJECT_TWIML);
  }

  if (!isRequestFromCaller(from, session.caller_id)) {
    log("twilio", "twiml-voice: From identity did not match the session's caller", {
      callSessionId,
      from,
    });
    return xmlResponse(REJECT_TWIML);
  }

  const statusCallbackBaseUrl = `${
    Deno.env.get("SUPABASE_URL")
  }/functions/v1/twilio-status-callback`;
  const twiml = buildDialTwiml(
    {
      id: session.id,
      callerId: session.caller_id,
      recipientIdentity: session.recipient_id,
      requestedDurationSeconds: session.requested_duration_seconds,
    },
    statusCallbackBaseUrl,
  );

  log("twilio", "twiml-voice: routing call", { callSessionId, recipient: session.recipient_id });
  return xmlResponse(twiml);
}

if (import.meta.main) {
  Deno.serve(handler);
}
