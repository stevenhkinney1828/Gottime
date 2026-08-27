import { assertEquals } from "jsr:@std/assert@1";
import {
  CONNECTED_GRACE_SECONDS,
  type ExpireCallSweepClient,
  NEVER_CONNECTED_GRACE_SECONDS,
  planSweep,
  runSweep,
  type StaleSessionCandidate,
  type SweepUpdate,
} from "../expire-call-sweep/logic.ts";

const NOW = new Date("2026-08-27T00:00:00.000Z");

function isoSecondsAgo(seconds: number): string {
  return new Date(NOW.getTime() - seconds * 1000).toISOString();
}

function neverConnected(overrides: Partial<StaleSessionCandidate> = {}): StaleSessionCandidate {
  return {
    id: "session-1",
    status: "ringing",
    initiatedAt: isoSecondsAgo(NEVER_CONNECTED_GRACE_SECONDS + 1),
    connectedAt: null,
    requestedDurationSeconds: 300,
    ...overrides,
  };
}

Deno.test("a never-connected session past its grace period is swept", () => {
  const updates = planSweep([neverConnected()], NOW);
  assertEquals(updates.length, 1);
  assertEquals(updates[0].toStatus, "missed");
});

Deno.test("a never-connected session still within its grace period is left alone", () => {
  const updates = planSweep(
    [neverConnected({ initiatedAt: isoSecondsAgo(NEVER_CONNECTED_GRACE_SECONDS - 1) })],
    NOW,
  );
  assertEquals(updates.length, 0);
});

Deno.test("a never-connected session that never reached ringing sweeps to failed, not missed", () => {
  for (const status of ["created", "outgoing"]) {
    const updates = planSweep([neverConnected({ status })], NOW);
    assertEquals(updates.length, 1);
    assertEquals(updates[0].toStatus, "failed");
  }
});

Deno.test("a connected session past requestedDuration + grace is swept to completed", () => {
  const requestedDurationSeconds = 60;
  const candidate: StaleSessionCandidate = {
    id: "session-2",
    status: "connected",
    initiatedAt: isoSecondsAgo(requestedDurationSeconds + CONNECTED_GRACE_SECONDS + 10),
    connectedAt: isoSecondsAgo(requestedDurationSeconds + CONNECTED_GRACE_SECONDS + 1),
    requestedDurationSeconds,
  };
  const updates = planSweep([candidate], NOW);
  assertEquals(updates.length, 1);
  assertEquals(updates[0].toStatus, "completed");
});

Deno.test("a connected session still within its requested duration + grace is left alone", () => {
  const requestedDurationSeconds = 300;
  const candidate: StaleSessionCandidate = {
    id: "session-3",
    status: "connected",
    initiatedAt: isoSecondsAgo(60),
    connectedAt: isoSecondsAgo(60),
    requestedDurationSeconds,
  };
  const updates = planSweep([candidate], NOW);
  assertEquals(updates.length, 0);
});

Deno.test("a timed_out session with connectedAt set is treated the same as connected", () => {
  const requestedDurationSeconds = 30;
  const candidate: StaleSessionCandidate = {
    id: "session-4",
    status: "timed_out",
    initiatedAt: isoSecondsAgo(requestedDurationSeconds + CONNECTED_GRACE_SECONDS + 30),
    connectedAt: isoSecondsAgo(requestedDurationSeconds + CONNECTED_GRACE_SECONDS + 1),
    requestedDurationSeconds,
  };
  const updates = planSweep([candidate], NOW);
  assertEquals(updates.length, 1);
  assertEquals(updates[0].toStatus, "completed");
});

Deno.test("runSweep fetches candidates, applies each update, and reports counts", async () => {
  const applied: SweepUpdate[] = [];
  const client: ExpireCallSweepClient = {
    fetchCandidates: () =>
      Promise.resolve([
        neverConnected({ id: "a" }),
        neverConnected({ id: "b", initiatedAt: isoSecondsAgo(1) }), // not stale, no-op
      ]),
    applyUpdate: (update) => {
      applied.push(update);
      return Promise.resolve(true);
    },
  };

  const result = await runSweep(client, NOW);
  assertEquals(result.candidateCount, 2);
  assertEquals(result.appliedCount, 1);
  assertEquals(applied.length, 1);
  assertEquals(applied[0].id, "a");
});

Deno.test("runSweep does not count an update the client reports as a no-op race", async () => {
  const client: ExpireCallSweepClient = {
    fetchCandidates: () => Promise.resolve([neverConnected()]),
    // Simulates the WHERE-guard matching zero rows because the session resolved normally
    // between fetchCandidates and applyUpdate — idempotent by construction, not by an extra
    // check, matching twilio-status-callback's own established pattern.
    applyUpdate: () => Promise.resolve(false),
  };

  const result = await runSweep(client, NOW);
  assertEquals(result.candidateCount, 1);
  assertEquals(result.appliedCount, 0);
});
