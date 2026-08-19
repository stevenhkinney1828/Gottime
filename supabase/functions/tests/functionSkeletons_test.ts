// Placeholder coverage for functions still pending their real phase. request-call and
// call-action graduated out of this file once they got real logic — see requestCall_test.ts
// and callAction_test.ts. Each remaining entry gets replaced the same way when its phase
// arrives — see BUILD_STATUS.md.
import { assertEquals } from "jsr:@std/assert@1";
import { handler as issueVoiceToken } from "../issue-voice-token/index.ts";
import { handler as twimlVoice } from "../twiml-voice/index.ts";
import { handler as twilioStatusCallback } from "../twilio-status-callback/index.ts";
import { handler as registerDevice } from "../register-device/index.ts";
import { handler as expireCallSweep } from "../expire-call-sweep/index.ts";

function req(): Request {
  return new Request("https://example.test/fn", { method: "POST" });
}

Deno.test("not-yet-implemented JSON functions return 501 with a phase marker", async () => {
  for (
    const fn of [issueVoiceToken, twilioStatusCallback, registerDevice, expireCallSweep]
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
