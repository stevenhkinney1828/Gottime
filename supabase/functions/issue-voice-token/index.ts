import { handlePreflight, jsonResponse } from "../_shared/cors.ts";
import { log } from "../_shared/logger.ts";
import { supabaseForRequest } from "../_shared/supabaseAdmin.ts";
import { buildVoiceAccessToken } from "./logic.ts";

// Mints a short-lived Twilio Voice Access Token for the authenticated caller, scoped to their
// own Twilio Voice SDK identity (their Supabase user id — collision-free, no separate identity
// mapping needed). Requires TWILIO_TWIML_APP_SID, which only exists once the one-time
// backend/scripts/twilio-setup.ts run (Phase 4 owner gate) has created the real TwiML
// Application — until then this returns 503, not the generic 501 the still-unimplemented
// stubs use, since the logic itself *is* implemented; only the configuration is missing.
export async function handler(req: Request): Promise<Response> {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "method not allowed" }, { status: 405 });
  }

  const requestClient = supabaseForRequest(req);
  const { data: userData, error: userError } = await requestClient.auth.getUser();
  if (userError || !userData?.user) {
    log("auth", "issue-voice-token: missing or invalid session");
    return jsonResponse({ error: "not authenticated" }, { status: 401 });
  }

  const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID");
  const apiKeySid = Deno.env.get("TWILIO_API_KEY_SID");
  const apiKeySecret = Deno.env.get("TWILIO_API_KEY_SECRET");
  const twimlAppSid = Deno.env.get("TWILIO_TWIML_APP_SID");
  // Not required alongside the other four: without it, tokens still mint fine for outgoing
  // calls, they just can't receive a push (register() has nothing to bind to). Missing this
  // is a real incoming-call bug, not a 503-worthy misconfiguration -- see DECISIONS.md.
  const pushCredentialSid = Deno.env.get("TWILIO_PUSH_CREDENTIAL_SID") ?? undefined;
  if (!accountSid || !apiKeySid || !apiKeySecret || !twimlAppSid) {
    log("twilio", "issue-voice-token: Twilio is not configured yet");
    return jsonResponse({ error: "voice calling is not configured yet" }, { status: 503 });
  }

  const result = await buildVoiceAccessToken({
    accountSid,
    apiKeySid,
    apiKeySecret,
    twimlAppSid,
    pushCredentialSid,
    identity: userData.user.id,
  });

  log("request", "issue-voice-token succeeded", { identity: result.identity });
  return jsonResponse({
    token: result.token,
    identity: result.identity,
    expiresAt: result.expiresAt,
  });
}

if (import.meta.main) {
  Deno.serve(handler);
}
