import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  type TwilioCredentials,
  twilioCredentialsFromEnv,
  twilioRequest,
} from "../_shared/twilioClient.ts";

Deno.test("twilioCredentialsFromEnv throws when env vars are missing", () => {
  Deno.env.delete("TWILIO_ACCOUNT_SID");
  Deno.env.delete("TWILIO_API_KEY_SID");
  Deno.env.delete("TWILIO_API_KEY_SECRET");
  assertThrows(() => twilioCredentialsFromEnv());
});

Deno.test("twilioCredentialsFromEnv reads all three values when present", () => {
  Deno.env.set("TWILIO_ACCOUNT_SID", "ACxxxx");
  Deno.env.set("TWILIO_API_KEY_SID", "SKxxxx");
  Deno.env.set("TWILIO_API_KEY_SECRET", "shh");
  const creds = twilioCredentialsFromEnv();
  assertEquals(creds, { accountSid: "ACxxxx", apiKeySid: "SKxxxx", apiKeySecret: "shh" });
  Deno.env.delete("TWILIO_ACCOUNT_SID");
  Deno.env.delete("TWILIO_API_KEY_SID");
  Deno.env.delete("TWILIO_API_KEY_SECRET");
});

Deno.test("twilioRequest builds the correct URL and Basic Auth header", async () => {
  const credentials: TwilioCredentials = {
    accountSid: "ACxxxx",
    apiKeySid: "SKxxxx",
    apiKeySecret: "shh",
  };
  const originalFetch = globalThis.fetch;
  let capturedUrl = "";
  let capturedAuth = "";
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    capturedUrl = String(input);
    capturedAuth = new Headers(init?.headers).get("Authorization") ?? "";
    return Promise.resolve(new Response("ok"));
  }) as typeof fetch;

  try {
    await twilioRequest(credentials, "/Calls.json", { method: "POST" });
  } finally {
    globalThis.fetch = originalFetch;
  }

  assertEquals(capturedUrl, "https://api.twilio.com/2010-04-01/Accounts/ACxxxx/Calls.json");
  assertEquals(capturedAuth, `Basic ${btoa("SKxxxx:shh")}`);
});
