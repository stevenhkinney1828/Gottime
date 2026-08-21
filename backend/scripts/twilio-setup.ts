// One-time script that provisions the Twilio TwiML Application this app's Voice calling
// depends on — done via Twilio's REST API rather than clicking through the console, so it's
// reproducible and not an easy-to-fat-finger manual walkthrough. Idempotent: if an Application
// with the same FriendlyName already exists, reuses it instead of creating a duplicate.
//
// Run:
//   cd backend/scripts
//   set -a; source ../../.env; set +a
//   deno run --allow-net --allow-env twilio-setup.ts

import { twilioCredentialsFromEnv, twilioRequest } from "../../supabase/functions/_shared/twilioClient.ts";

const FRIENDLY_NAME = "GotTime";

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    console.error(`Missing required env var: ${name}`);
    Deno.exit(1);
  }
  return value;
}

const supabaseUrl = requireEnv("SUPABASE_URL");
const credentials = twilioCredentialsFromEnv();
const voiceUrl = `${supabaseUrl}/functions/v1/twiml-voice`;

interface TwilioApplication {
  sid: string;
  friendly_name: string;
  voice_url: string;
}

const listResponse = await twilioRequest(credentials, "/Applications.json?PageSize=100");
if (!listResponse.ok) {
  console.error("Failed to list existing TwiML Applications:", await listResponse.text());
  Deno.exit(1);
}
const { applications } = await listResponse.json() as { applications: TwilioApplication[] };
const existing = applications.find((app) => app.friendly_name === FRIENDLY_NAME);

if (existing) {
  console.log(`Found existing TwiML Application "${FRIENDLY_NAME}" — reusing it, not creating a duplicate.`);
  if (existing.voice_url !== voiceUrl) {
    console.log(`Its Voice URL (${existing.voice_url}) doesn't match the current one (${voiceUrl}) — updating it.`);
    const updateResponse = await twilioRequest(credentials, `/Applications/${existing.sid}.json`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ VoiceUrl: voiceUrl, VoiceMethod: "POST" }).toString(),
    });
    if (!updateResponse.ok) {
      console.error("Failed to update the existing Application's Voice URL:", await updateResponse.text());
      Deno.exit(1);
    }
  }
  console.log(`\nTWILIO_TWIML_APP_SID=${existing.sid}`);
  Deno.exit(0);
}

const createResponse = await twilioRequest(credentials, "/Applications.json", {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({
    FriendlyName: FRIENDLY_NAME,
    VoiceUrl: voiceUrl,
    VoiceMethod: "POST",
  }).toString(),
});

if (!createResponse.ok) {
  console.error("Failed to create the TwiML Application:", await createResponse.text());
  Deno.exit(1);
}

const created = await createResponse.json() as TwilioApplication;
console.log(`Created TwiML Application: ${created.sid}`);
console.log(`Voice URL: ${created.voice_url}`);
console.log(`\nTWILIO_TWIML_APP_SID=${created.sid}`);
