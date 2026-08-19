// Pure, dependency-injected logic. Mirrors the relevant slice of GotTimeCore's
// CallStateMachine (Swift) — kept in sync by convention and tests on both sides, not by
// shared code, since there's no practical Swift<->TypeScript shared-logic mechanism at this
// project's scale. Ownership-checked: only the right participant can perform each action,
// only from the right current status.

export type CallAction = "decline" | "cancel" | "end_early";

export interface CallSessionRow {
  id: string;
  callerId: string;
  recipientId: string;
  status: string;
}

export interface CallActionClient {
  getCallSession(callSessionId: string): Promise<CallSessionRow | null>;
  updateStatus(callSessionId: string, status: string): Promise<void>;
}

export type CallActionResult =
  | { ok: true; newStatus: string }
  | { ok: false; error: string; status: number };

interface ActionRule {
  fromStatuses: string[];
  actingParticipant: "caller" | "recipient" | "either";
  newStatus: string;
}

const RULES: Record<CallAction, ActionRule> = {
  // Recipient rejects before answering.
  decline: { fromStatuses: ["ringing"], actingParticipant: "recipient", newStatus: "declined" },
  // Caller backs out before the recipient answers — reachable from either outgoing (before
  // ringing is confirmed) or ringing.
  cancel: {
    fromStatuses: ["outgoing", "ringing"],
    actingParticipant: "caller",
    newStatus: "canceled",
  },
  // Either participant hangs up before the timer reaches zero. No "extend" action exists
  // anywhere in this table — spec section 2: "the current call cannot be extended."
  end_early: {
    fromStatuses: ["connected"],
    actingParticipant: "either",
    newStatus: "ended_early",
  },
};

export async function performCallAction(
  client: CallActionClient,
  params: { actingUserId: string; callSessionId: string; action: string },
): Promise<CallActionResult> {
  const rule = RULES[params.action as CallAction];
  if (!rule) {
    return { ok: false, error: `unknown action: ${params.action}`, status: 400 };
  }

  const session = await client.getCallSession(params.callSessionId);
  if (!session) {
    return { ok: false, error: "call session not found", status: 404 };
  }

  const isCaller = session.callerId === params.actingUserId;
  const isRecipient = session.recipientId === params.actingUserId;
  if (!isCaller && !isRecipient) {
    // Deliberately the same "not found" framing as a missing row, not a distinct "forbidden"
    // message — an unrelated user shouldn't be able to tell a real call session apart from a
    // nonexistent one by probing this endpoint (spec section 12: no arbitrary enumeration).
    return { ok: false, error: "call session not found", status: 404 };
  }

  if (rule.actingParticipant === "caller" && !isCaller) {
    return { ok: false, error: `only the caller can ${params.action}`, status: 403 };
  }
  if (rule.actingParticipant === "recipient" && !isRecipient) {
    return { ok: false, error: `only the recipient can ${params.action}`, status: 403 };
  }

  if (!rule.fromStatuses.includes(session.status)) {
    return {
      ok: false,
      error: `cannot ${params.action} a call in status "${session.status}"`,
      status: 409,
    };
  }

  await client.updateStatus(params.callSessionId, rule.newStatus);
  return { ok: true, newStatus: rule.newStatus };
}
