import { assertEquals } from "jsr:@std/assert@1";
import {
  type CallSessionRecord,
  requestCall,
  type RequestCallClient,
} from "../request-call/logic.ts";

class FakeRequestCallClient implements RequestCallClient {
  activeConnections = new Set<string>();
  created: Array<
    {
      callerId: string;
      recipientId: string;
      requestedDurationSeconds: number;
      topic: string | null;
    }
  > = [];

  private pairKey(a: string, b: string): string {
    return [a, b].sort().join("|");
  }

  connect(a: string, b: string) {
    this.activeConnections.add(this.pairKey(a, b));
  }

  hasActiveConnection(userA: string, userB: string): Promise<boolean> {
    return Promise.resolve(this.activeConnections.has(this.pairKey(userA, userB)));
  }

  createCallSession(
    params: {
      callerId: string;
      recipientId: string;
      requestedDurationSeconds: number;
      topic: string | null;
    },
  ): Promise<CallSessionRecord> {
    this.created.push(params);
    const now = new Date().toISOString();
    return Promise.resolve({
      id: "session-1",
      callUuid: "uuid-1",
      callerId: params.callerId,
      recipientId: params.recipientId,
      requestedDurationSeconds: params.requestedDurationSeconds,
      topic: params.topic,
      status: "created",
      initiatedAt: now,
      createdAt: now,
      updatedAt: now,
    });
  }
}

const ALICE = "alice-id";
const BOB = "bob-id";
const CAROL = "carol-id";

Deno.test("creates a call session for a valid connected pair and duration", async () => {
  const client = new FakeRequestCallClient();
  client.connect(ALICE, BOB);

  const result = await requestCall(client, {
    callerId: ALICE,
    recipientId: BOB,
    requestedDurationSeconds: 600,
  });

  if (!result.ok) throw new Error(`expected ok, got error: ${result.error}`);
  assertEquals(result.session.callerId, ALICE);
  assertEquals(result.session.recipientId, BOB);
  assertEquals(result.session.requestedDurationSeconds, 600);
  assertEquals(client.created.length, 1);
});

Deno.test("rejects when caller and recipient are not connected", async () => {
  const client = new FakeRequestCallClient();
  // Deliberately no connect() call — Alice and Carol are not connected.

  const result = await requestCall(client, {
    callerId: ALICE,
    recipientId: CAROL,
    requestedDurationSeconds: 600,
  });

  if (result.ok) throw new Error("expected rejection for unconnected pair");
  assertEquals(result.status, 403);
  assertEquals(client.created.length, 0);
});

Deno.test("rejects a caller trying to call themselves", async () => {
  const client = new FakeRequestCallClient();
  client.connect(ALICE, ALICE);

  const result = await requestCall(client, {
    callerId: ALICE,
    recipientId: ALICE,
    requestedDurationSeconds: 600,
  });

  if (result.ok) throw new Error("expected rejection for self-call");
  assertEquals(result.status, 400);
});

Deno.test("duration boundary matrix matches the 15s-3600s bound exactly", async () => {
  const client = new FakeRequestCallClient();
  client.connect(ALICE, BOB);

  // 15s (the floor, lowered from 60s for the owner's short presets), 60s (1 min), 3600s (60
  // min, the ceiling), and an arbitrary in-between value.
  const accepted = [15, 60, 3600, 300];
  for (const seconds of accepted) {
    const result = await requestCall(client, {
      callerId: ALICE,
      recipientId: BOB,
      requestedDurationSeconds: seconds,
    });
    if (!result.ok) throw new Error(`expected ${seconds}s to be accepted, got: ${result.error}`);
  }

  const rejected: unknown[] = [0, -1, 14, 3601, 7200, 1.5, "600", null, undefined, NaN];
  for (const value of rejected) {
    const result = await requestCall(client, {
      callerId: ALICE,
      recipientId: BOB,
      requestedDurationSeconds: value,
    });
    if (result.ok) throw new Error(`expected ${JSON.stringify(value)} to be rejected`);
    assertEquals(result.status, 400);
  }
});

Deno.test("rejects missing recipientId", async () => {
  const client = new FakeRequestCallClient();
  const result = await requestCall(client, {
    callerId: ALICE,
    recipientId: "",
    requestedDurationSeconds: 600,
  });
  if (result.ok) throw new Error("expected rejection for missing recipientId");
  assertEquals(result.status, 400);
});

Deno.test("connection check is symmetric regardless of who initiated it", async () => {
  const client = new FakeRequestCallClient();
  client.connect(BOB, ALICE); // stored as Bob-Alice, requested as Alice-Bob below

  const result = await requestCall(client, {
    callerId: ALICE,
    recipientId: BOB,
    requestedDurationSeconds: 600,
  });
  if (!result.ok) {
    throw new Error(`expected symmetric connection lookup to succeed: ${result.error}`);
  }
});

Deno.test("topic is trimmed and passed through when present", async () => {
  const client = new FakeRequestCallClient();
  client.connect(ALICE, BOB);

  const result = await requestCall(client, {
    callerId: ALICE,
    recipientId: BOB,
    requestedDurationSeconds: 600,
    topic: "  dinner tonight  ",
  });
  if (!result.ok) throw new Error(`expected ok, got error: ${result.error}`);
  assertEquals(result.session.topic, "dinner tonight");
});

Deno.test("a missing, blank, or non-string topic normalizes to null rather than rejecting the call", async () => {
  const client = new FakeRequestCallClient();
  client.connect(ALICE, BOB);

  for (const topic of [undefined, "", "   ", 42, null]) {
    const result = await requestCall(client, {
      callerId: ALICE,
      recipientId: BOB,
      requestedDurationSeconds: 600,
      topic,
    });
    if (!result.ok) {
      throw new Error(`expected ${JSON.stringify(topic)} to be accepted, got: ${result.error}`);
    }
    assertEquals(result.session.topic, null);
  }
});

Deno.test("an over-length topic is truncated rather than rejecting the call", async () => {
  const client = new FakeRequestCallClient();
  client.connect(ALICE, BOB);
  const longTopic = "a".repeat(200);

  const result = await requestCall(client, {
    callerId: ALICE,
    recipientId: BOB,
    requestedDurationSeconds: 600,
    topic: longTopic,
  });
  if (!result.ok) throw new Error(`expected ok, got error: ${result.error}`);
  assertEquals(result.session.topic?.length, 140);
});
