import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { buildDialTwiml, isRequestFromCaller, REJECT_TWIML } from "../twiml-voice/logic.ts";

Deno.test("builds a Dial/Client with the exact documented attribute placement", () => {
  const twiml = buildDialTwiml(
    {
      id: "session-1",
      callerId: "alice-id",
      recipientIdentity: "bob-id",
      requestedDurationSeconds: 300,
    },
    "https://example.supabase.co/functions/v1/twilio-status-callback",
  );

  assertStringIncludes(twiml, '<Dial timeLimit="300" timeout="20">');
  assertStringIncludes(
    twiml,
    '<Client statusCallbackEvent="ringing answered completed" ' +
      'statusCallback="https://example.supabase.co/functions/v1/twilio-status-callback' +
      '?call_session_id=session-1" statusCallbackMethod="POST">',
  );
  // Parameter is self-closing; identity is the element's own text content immediately after
  // it, not a replacement for it.
  assertStringIncludes(twiml, '<Parameter name="callSessionId" value="session-1"/>bob-id</Client>');
});

Deno.test("escapes XML special characters in the identity and session id", () => {
  const twiml = buildDialTwiml(
    {
      id: 'weird"id&<>',
      callerId: "alice-id",
      recipientIdentity: 'bob&<>"id',
      requestedDurationSeconds: 60,
    },
    "https://example.supabase.co/functions/v1/twilio-status-callback",
  );
  assertStringIncludes(twiml, "bob&amp;&lt;&gt;&quot;id</Client>");
  assertStringIncludes(twiml, "weird&quot;id&amp;&lt;&gt;");
});

Deno.test("REJECT_TWIML is a minimal valid TwiML document", () => {
  assertEquals(
    REJECT_TWIML,
    '<?xml version="1.0" encoding="UTF-8"?><Response><Reject/></Response>',
  );
});

Deno.test("isRequestFromCaller matches Twilio's client:<identity> From format exactly", () => {
  assertEquals(isRequestFromCaller("client:alice-id", "alice-id"), true);
});

Deno.test("isRequestFromCaller rejects a mismatched identity", () => {
  assertEquals(isRequestFromCaller("client:mallory-id", "alice-id"), false);
});

Deno.test("isRequestFromCaller rejects a phone-number From (not app-to-app)", () => {
  assertEquals(isRequestFromCaller("+15551234567", "alice-id"), false);
});

Deno.test("isRequestFromCaller rejects a missing From header", () => {
  assertEquals(isRequestFromCaller(null, "alice-id"), false);
});
