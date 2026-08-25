import { assertEquals } from "jsr:@std/assert@1";
import { planStatusTransition } from "../twilio-status-callback/logic.ts";

Deno.test("ringing transitions from outgoing only, stamping ringing_at", () => {
  assertEquals(planStatusTransition("ringing"), {
    newStatus: "ringing",
    timestampField: "ringing_at",
    requiredCurrentStatuses: ["outgoing"],
  });
});

Deno.test("in-progress transitions from outgoing or ringing, stamping connected_at", () => {
  const transition = planStatusTransition("in-progress");
  assertEquals(transition?.newStatus, "connected");
  assertEquals(transition?.timestampField, "connected_at");
  assertEquals(transition?.requiredCurrentStatuses, ["outgoing", "ringing"]);
});

Deno.test("initiated is a deliberate no-op (already covered by request-call's own 'outgoing')", () => {
  assertEquals(planStatusTransition("initiated"), null);
});

Deno.test("completed is a deliberate no-op (Phase 6's job, not this webhook's)", () => {
  assertEquals(planStatusTransition("completed"), null);
});
