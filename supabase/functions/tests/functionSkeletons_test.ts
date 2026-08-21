// Placeholder coverage for functions still pending their real phase. request-call and
// call-action graduated out of this file once they got real logic — see requestCall_test.ts
// and callAction_test.ts; issue-voice-token, twiml-voice, and twilio-status-callback graduated
// the same way in Phase 4 — see issueVoiceToken_test.ts, twimlVoice_test.ts, and
// twilioStatusCallback_test.ts. Each remaining entry gets replaced the same way when its phase
// arrives — see BUILD_STATUS.md.
import { assertEquals } from "jsr:@std/assert@1";
import { handler as registerDevice } from "../register-device/index.ts";
import { handler as expireCallSweep } from "../expire-call-sweep/index.ts";

function req(): Request {
  return new Request("https://example.test/fn", { method: "POST" });
}

Deno.test("not-yet-implemented JSON functions return 501 with a phase marker", async () => {
  for (const fn of [registerDevice, expireCallSweep]) {
    const response = await fn(req());
    assertEquals(response.status, 501);
    const body = await response.json();
    assertEquals(body.error, "not_implemented");
    assertEquals(typeof body.phase, "number");
  }
});
