// Pure mapping from the <Client> noun's own statusCallbackEvent vocabulary (see twiml-voice/
// logic.ts and DECISIONS.md for why this is a narrower, different vocabulary than the general
// Call resource's own status callbacks: initiated/ringing/answered/completed only, no
// busy/failed/no-answer/canceled at this level) to the transition this backend should attempt.
//
// Deliberately does not attempt to interpret "completed" here. Distinguishing "the participant
// hung up early" from "the timer reached zero on schedule" needs the full duration-enforcement
// design (Phase 6's three independent layers: client-side disconnect, backend timeLimit
// tightening, cron sweep backstop) — a single terminal event from Twilio can't carry that
// distinction on its own, and guessing at it here would risk silently mislabeling history
// entries. call-action's endActiveCall (client-initiated, already built) is what records
// ended_early today; Phase 6 is where "completed" gets handled properly.

export type ClientCallStatus = "initiated" | "ringing" | "answered" | "completed";

export interface StatusTransition {
  newStatus: "ringing" | "connected";
  timestampField: "ringing_at" | "connected_at";
  /** The update is only applied `WHERE status IN (...)`  these — a late or duplicate webhook
   * (Twilio retries webhooks that don't respond quickly) simply matches zero rows once the
   * session has already moved past this point, which is the correct idempotent outcome, not
   * an error. */
  requiredCurrentStatuses: string[];
}

export function planStatusTransition(clientCallStatus: ClientCallStatus): StatusTransition | null {
  switch (clientCallStatus) {
    case "ringing":
      return {
        newStatus: "ringing",
        timestampField: "ringing_at",
        requiredCurrentStatuses: ["outgoing"],
      };
    case "answered":
      // Also accepts "outgoing" as a starting point, not just "ringing" — a lost or delayed
      // ringing webhook shouldn't block recording that the call was genuinely answered.
      return {
        newStatus: "connected",
        timestampField: "connected_at",
        requiredCurrentStatuses: ["outgoing", "ringing"],
      };
    case "initiated":
    case "completed":
      return null;
  }
}
