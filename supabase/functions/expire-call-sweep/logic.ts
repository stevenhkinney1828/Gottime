// Pure sweep-planning logic — no Deno.serve, no real Supabase client — fully unit-testable.
// index.ts wires this to the real Supabase admin client, invoked periodically by pg_cron (see
// migration 0013_expire_call_sweep_cron.sql). This is the third and final layer of Phase 6's
// duration enforcement (client-side disconnect-at-zero, built in build 24, is the primary
// layer); real evidence this is a genuine, not hypothetical, gap: direct database queries
// during real-device testing found call_sessions rows stuck in "ringing"/"created"/"outgoing"
// for hours — sometimes over a day — with nothing to ever resolve them, because the only thing
// that had ever driven a resolution was the caller's own device, which a killed app, a dropped
// network, or abandoned testing can silently prevent from ever reporting back. See DECISIONS.md.

export interface StaleSessionCandidate {
  id: string;
  status: string;
  initiatedAt: string; // ISO 8601
  connectedAt: string | null;
  requestedDurationSeconds: number;
}

export type SweepStatus = "failed" | "missed" | "completed";

export interface SweepUpdate {
  id: string;
  fromStatus: string;
  toStatus: SweepStatus;
  /** Computed here, not left as a raw SQL expression for the update itself to evaluate --
   * PostgREST's update endpoint takes literal values, not expressions referencing another
   * column, so this must already be a plain number by the time index.ts sends it. */
  actualDurationSeconds: number | null;
}

/** Never-connected calls get this long to resolve naturally (ring, then answer/decline/give up)
 * before being swept — generous relative to any realistic ring duration (Twilio/carrier ring
 * timeouts run well under a minute), so this can never race a real, still-in-progress call. */
export const NEVER_CONNECTED_GRACE_SECONDS = 5 * 60;

/** A connected call gets its own requested duration plus this much slack past `connectedAt`
 * before being swept — covers the case the client-side disconnect-at-zero somehow never fires
 * (the scenario this backstop specifically exists for), without cutting off a real conversation
 * merely running a little behind wall-clock time due to clock skew or a delayed signal. */
export const CONNECTED_GRACE_SECONDS = 2 * 60;

/** Decides which candidates are actually stale enough to sweep, and what each should become.
 * Branches only on whether `connectedAt` is set, not on the exact current status — a session
 * with a `connectedAt` (whether still `connected` or already `timed_out` but never advanced to
 * `completed`) is handled identically; the same is true for every flavor of "never connected."
 * `missed` vs `failed` for the never-connected case mirrors `TwilioVoiceAdapter.
 * callDidDisconnect`'s own existing convention: a session that at least reached `ringing` reads
 * as "never answered in time" to the recipient regardless of *why* it was never resolved, while
 * one that never got that far reads as a plain failure. */
export function planSweep(candidates: StaleSessionCandidate[], now: Date): SweepUpdate[] {
  const updates: SweepUpdate[] = [];
  for (const candidate of candidates) {
    if (candidate.connectedAt) {
      const connectedAt = new Date(candidate.connectedAt);
      const expiresAt = new Date(
        connectedAt.getTime() +
          (candidate.requestedDurationSeconds + CONNECTED_GRACE_SECONDS) * 1000,
      );
      if (now >= expiresAt) {
        // Mirrors CallStateMachine.apply's own formula exactly (GotTimeCore, client-side) --
        // uncapped, since the whole point here is a session that ran past what was requested.
        const actualDurationSeconds = Math.max(
          0,
          Math.floor((now.getTime() - connectedAt.getTime()) / 1000),
        );
        updates.push({
          id: candidate.id,
          fromStatus: candidate.status,
          toStatus: "completed",
          actualDurationSeconds,
        });
      }
    } else {
      const initiatedAt = new Date(candidate.initiatedAt);
      const expiresAt = new Date(initiatedAt.getTime() + NEVER_CONNECTED_GRACE_SECONDS * 1000);
      if (now >= expiresAt) {
        const toStatus = candidate.status === "ringing" ? "missed" : "failed";
        updates.push({
          id: candidate.id,
          fromStatus: candidate.status,
          toStatus,
          actualDurationSeconds: null,
        });
      }
    }
  }
  return updates;
}

export interface ExpireCallSweepClient {
  fetchCandidates(): Promise<StaleSessionCandidate[]>;
  applyUpdate(update: SweepUpdate): Promise<boolean>;
}

export interface SweepResult {
  candidateCount: number;
  appliedCount: number;
}

export async function runSweep(client: ExpireCallSweepClient, now: Date): Promise<SweepResult> {
  const candidates = await client.fetchCandidates();
  const updates = planSweep(candidates, now);
  let appliedCount = 0;
  for (const update of updates) {
    if (await client.applyUpdate(update)) appliedCount++;
  }
  return { candidateCount: candidates.length, appliedCount };
}
