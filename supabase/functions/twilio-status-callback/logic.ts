// Pure mapping from the <Client> noun's own statusCallbackEvent vocabulary (see twiml-voice/
// logic.ts and DECISIONS.md for why this is a narrower, different vocabulary than the general
// Call resource's own status callbacks: initiated/ringing/in-progress/completed only, no
// busy/failed/no-answer/canceled at this level) to the transition this backend should attempt.
//
// The "answered" event this originally assumed never actually exists -- confirmed directly from
// Twilio's own call Events API on a real, successfully-bridged call: it posts "in-progress" for
// this exact milestone, not "answered". That meant connected_at had never been set, ever, for
// any call in this project (silently no-op'd by the "no matching case" branch below, which
// looked identical to the deliberate initiated/completed no-ops) -- caught only once the UUID-
// mismatch fix (see DECISIONS.md) finally let a call bridge for real and connected_at was still
// null despite a real, successful, hung-up call. See DECISIONS.md.
//
// Deliberately does not attempt to interpret "completed" here. Distinguishing "the participant
// hung up early" from "the timer reached zero on schedule" needs the full duration-enforcement
// design (Phase 6's three independent layers: client-side disconnect, backend timeLimit
// tightening, cron sweep backstop) — a single terminal event from Twilio can't carry that
// distinction on its own, and guessing at it here would risk silently mislabeling history
// entries. call-action's endActiveCall (client-initiated, already built) is what records
// ended_early today; Phase 6 is where "completed" gets handled properly.

export type ClientCallStatus = "initiated" | "ringing" | "in-progress" | "completed";

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
    case "in-progress":
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
