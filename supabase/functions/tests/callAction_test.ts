import { assertEquals } from "jsr:@std/assert@1";
import {
  type CallActionClient,
  type CallSessionRow,
  performCallAction,
} from "../call-action/logic.ts";

class FakeCallActionClient implements CallActionClient {
  sessions = new Map<string, CallSessionRow>();
  updates: Array<{ id: string; status: string }> = [];

  seed(session: CallSessionRow) {
    this.sessions.set(session.id, session);
  }

  getCallSession(callSessionId: string): Promise<CallSessionRow | null> {
    return Promise.resolve(this.sessions.get(callSessionId) ?? null);
  }

  updateStatus(callSessionId: string, status: string): Promise<void> {
    this.updates.push({ id: callSessionId, status });
    const existing = this.sessions.get(callSessionId);
    if (existing) this.sessions.set(callSessionId, { ...existing, status });
    return Promise.resolve();
  }
}

const ALICE = "alice-id";
const BOB = "bob-id";
const CAROL = "carol-id";

function ringingCall(): CallSessionRow {
  return { id: "call-1", callerId: ALICE, recipientId: BOB, status: "ringing" };
}

Deno.test("recipient can decline a ringing call", async () => {
  const client = new FakeCallActionClient();
  client.seed(ringingCall());

  const result = await performCallAction(client, {
    actingUserId: BOB,
    callSessionId: "call-1",
    action: "decline",
  });

  if (!result.ok) throw new Error(`expected ok, got: ${result.error}`);
  assertEquals(result.newStatus, "declined");
  assertEquals(client.updates, [{ id: "call-1", status: "declined" }]);
});

Deno.test("caller cannot decline their own outgoing call (only recipient can decline)", async () => {
  const client = new FakeCallActionClient();
  client.seed(ringingCall());

  const result = await performCallAction(client, {
    actingUserId: ALICE,
    callSessionId: "call-1",
    action: "decline",
  });

  if (result.ok) throw new Error("expected rejection: caller cannot decline");
  assertEquals(result.status, 403);
  assertEquals(client.updates.length, 0);
});

Deno.test("caller can cancel while outgoing or ringing", async () => {
  for (const status of ["outgoing", "ringing"]) {
    const client = new FakeCallActionClient();
    client.seed({ id: "call-1", callerId: ALICE, recipientId: BOB, status });

    const result = await performCallAction(client, {
      actingUserId: ALICE,
      callSessionId: "call-1",
      action: "cancel",
    });

    if (!result.ok) throw new Error(`expected cancel from ${status} to succeed: ${result.error}`);
    assertEquals(result.newStatus, "canceled");
  }
});

Deno.test("recipient cannot cancel (only the caller can)", async () => {
  const client = new FakeCallActionClient();
  client.seed(ringingCall());

  const result = await performCallAction(client, {
    actingUserId: BOB,
    callSessionId: "call-1",
    action: "cancel",
  });

  if (result.ok) throw new Error("expected rejection: recipient cannot cancel");
  assertEquals(result.status, 403);
});

Deno.test("either participant can end a connected call early", async () => {
  for (const actingUserId of [ALICE, BOB]) {
    const client = new FakeCallActionClient();
    client.seed({ id: "call-1", callerId: ALICE, recipientId: BOB, status: "connected" });

    const result = await performCallAction(client, {
      actingUserId,
      callSessionId: "call-1",
      action: "end_early",
    });

    if (!result.ok) {
      throw new Error(`expected end_early by ${actingUserId} to succeed: ${result.error}`);
    }
    assertEquals(result.newStatus, "ended_early");
  }
});

Deno.test("cannot end_early a call that never connected", async () => {
  const client = new FakeCallActionClient();
  client.seed(ringingCall()); // status: ringing, never reached connected

  const result = await performCallAction(client, {
    actingUserId: ALICE,
    callSessionId: "call-1",
    action: "end_early",
  });

  if (result.ok) throw new Error("expected rejection: cannot end_early before connecting");
  assertEquals(result.status, 409);
});

Deno.test("cannot decline an already-connected call", async () => {
  const client = new FakeCallActionClient();
  client.seed({ id: "call-1", callerId: ALICE, recipientId: BOB, status: "connected" });

  const result = await performCallAction(client, {
    actingUserId: BOB,
    callSessionId: "call-1",
    action: "decline",
  });

  if (result.ok) throw new Error("expected rejection: cannot decline a connected call");
  assertEquals(result.status, 409);
});

Deno.test("an unrelated user gets 'not found', not 'forbidden' (no enumeration)", async () => {
  const client = new FakeCallActionClient();
  client.seed(ringingCall());

  const result = await performCallAction(client, {
    actingUserId: CAROL,
    callSessionId: "call-1",
    action: "decline",
  });

  if (result.ok) throw new Error("expected rejection for unrelated user");
  assertEquals(result.status, 404);
  assertEquals(result.error, "call session not found");
});

Deno.test("nonexistent call session returns 404", async () => {
  const client = new FakeCallActionClient();

  const result = await performCallAction(client, {
    actingUserId: ALICE,
    callSessionId: "does-not-exist",
    action: "cancel",
  });

  if (result.ok) throw new Error("expected 404 for nonexistent session");
  assertEquals(result.status, 404);
});

Deno.test("unknown action is rejected with 400", async () => {
  const client = new FakeCallActionClient();
  client.seed(ringingCall());

  const result = await performCallAction(client, {
    actingUserId: ALICE,
    callSessionId: "call-1",
    action: "extend", // there is no extend action anywhere in this system, by design
  });

  if (result.ok) throw new Error("expected rejection for unknown action");
  assertEquals(result.status, 400);
});

Deno.test("there is no path from connected back to ringing or outgoing (no re-ringing an active call)", async () => {
  // Regression-proofs "no extend" at the call-action layer specifically: none of the three
  // actions this endpoint exposes can ever move a call backwards in its lifecycle. Each
  // action is attempted by the actor who *would* be authorized for it in general (recipient
  // for decline, caller for cancel), so the rejection below is provably the status check
  // (409) firing, not an incidental role-check rejection (403) masking the real assertion.
  const client = new FakeCallActionClient();
  client.seed({ id: "call-1", callerId: ALICE, recipientId: BOB, status: "connected" });

  const attempts: Array<{ action: "decline" | "cancel"; actingUserId: string }> = [
    { action: "decline", actingUserId: BOB },
    { action: "cancel", actingUserId: ALICE },
  ];
  for (const { action, actingUserId } of attempts) {
    const result = await performCallAction(client, {
      actingUserId,
      callSessionId: "call-1",
      action,
    });
    if (result.ok) throw new Error(`${action} must not be applicable to a connected call`);
    assertEquals(
      result.status,
      409,
      `${action} by the correctly-authorized actor should fail on status, not role`,
    );
  }
});
