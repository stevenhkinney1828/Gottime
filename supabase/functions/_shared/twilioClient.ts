// Minimal Twilio REST wrapper using plain fetch + API Key Basic Auth. Twilio doesn't publish
// a Deno SDK, and the full Node SDK pulls in a lot of machinery we don't need for the small
// set of REST calls this backend makes (creating/updating a Call resource, and — in
// issue-voice-token — minting Voice Access Tokens, which is JWT construction, not a REST
// call, and lives in that function once implemented in Phase 4).

export interface TwilioCredentials {
  accountSid: string;
  apiKeySid: string;
  apiKeySecret: string;
}

export function twilioCredentialsFromEnv(): TwilioCredentials {
  const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID");
  const apiKeySid = Deno.env.get("TWILIO_API_KEY_SID");
  const apiKeySecret = Deno.env.get("TWILIO_API_KEY_SECRET");
  if (!accountSid || !apiKeySid || !apiKeySecret) {
    throw new Error(
      "TWILIO_ACCOUNT_SID, TWILIO_API_KEY_SID, TWILIO_API_KEY_SECRET must be set",
    );
  }
  return { accountSid, apiKeySid, apiKeySecret };
}

/** Issues an authenticated request against the Twilio REST API (2010-04-01). */
export function twilioRequest(
  credentials: TwilioCredentials,
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  const basicAuth = btoa(`${credentials.apiKeySid}:${credentials.apiKeySecret}`);
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Basic ${basicAuth}`);
  return fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${credentials.accountSid}${path}`,
    { ...init, headers },
  );
}
