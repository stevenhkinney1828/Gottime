// Placeholder coverage for Phase 0: proves every function's module loads, its handler runs
// standalone (no live server needed, thanks to the `if (import.meta.main)` guard in each
// index.ts), and it returns the expected not-implemented stub response. Each of these tests
// gets replaced by real behavioral tests in the phase noted in its own file's comment.
import { assertEquals } from "jsr:@std/assert@1";
import { handler as issueVoiceToken } from "../issue-voice-token/index.ts";
import { handler as requestCall } from "../request-call/index.ts";
import { handler as twimlVoice } from "../twiml-voice/index.ts";
import { handler as twilioStatusCallback } from "../twilio-status-callback/index.ts";
import { handler as callAction } from "../call-action/index.ts";
import { handler as registerDevice } from "../register-device/index.ts";
import { handler as expireCallSweep } from "../expire-call-sweep/index.ts";

function req(): Request {
  return new Request("https://example.test/fn", { method: "POST" });
}

Deno.test("not-yet-implemented JSON functions return 501 with a phase marker", async () => {
  for (
    const fn of [
      issueVoiceToken,
      requestCall,
      twilioStatusCallback,
      callAction,
      registerDevice,
      expireCallSweep,
    ]
  ) {
    const response = await fn(req());
    assertEquals(response.status, 501);
    const body = await response.json();
    assertEquals(body.error, "not_implemented");
    assertEquals(typeof body.phase, "number");
  }
});

Deno.test("twiml-voice returns valid-shaped empty TwiML while not yet implemented", async () => {
  const response = await twimlVoice(req());
  assertEquals(response.status, 200);
  assertEquals(response.headers.get("Content-Type"), "text/xml");
  assertEquals(await response.text(), "<Response></Response>");
});
