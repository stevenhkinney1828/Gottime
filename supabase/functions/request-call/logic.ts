// Pure, dependency-injected logic — no Deno.serve, no real Supabase client — so it's fully
// unit-testable without any live credentials. index.ts wires this to the real Supabase admin
// client. Validates caller/recipient/connection/duration server-side and never trusts a
// client-supplied value for the actual authorization decision (spec section 13).

export interface CallSessionRecord {
  id: string;
  callUuid: string;
  callerId: string;
  recipientId: string;
  requestedDurationSeconds: number;
  status: string;
  /** Optional caller-supplied context ("what's this about") — see sanitizeTopic below. */
  topic: string | null;
  /** ISO 8601 strings — the iOS client's CallSession requires all three non-optional; the
   * other lifecycle timestamps (ringingAt/connectedAt/endedAt/etc.) are correctly absent from
   * a freshly-created session and decode as nil client-side without needing to appear here. */
  initiatedAt: string;
  createdAt: string;
  updatedAt: string;
}

export interface RequestCallClient {
  hasActiveConnection(userA: string, userB: string): Promise<boolean>;
  createCallSession(
    params: {
      callerId: string;
      recipientId: string;
      requestedDurationSeconds: number;
      topic: string | null;
    },
  ): Promise<CallSessionRecord>;
}

export type RequestCallResult =
  | { ok: true; session: CallSessionRecord }
  | { ok: false; error: string; status: number };

const MIN_DURATION_SECONDS = 15;
const MAX_DURATION_SECONDS = 3600;

/** Matches GotTimeCore's DurationPolicy bounds exactly (15-3600 seconds -- lowered from the
 * original 60s/1-minute floor so the owner's requested 15s/30s presets are actually acceptable
 * server-side, not just selectable in the UI) — this is one of three independent
 * duration-enforcement layers described in DECISIONS.md; the others are the client-side policy
 * and the database CHECK constraint (0011_lower_duration_minimum.sql). */
function isValidDurationSeconds(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) &&
    value >= MIN_DURATION_SECONDS && value <= MAX_DURATION_SECONDS;
}

const MAX_TOPIC_LENGTH = 140;

/** Optional, caller-supplied context that shows up alongside their name during ring/connect —
 * "what's this about" (see DECISIONS.md, the owner's own request). Never required, never
 * validated as strictly as duration: a missing/blank/whitespace-only topic normalizes to null
 * (matches the intent: "nothing to add"), and an over-length one is truncated rather than
 * rejected, so a long caller-typed sentence can't fail an entire call request over something
 * this minor. Matches the DB's own length CHECK constraint (0012_add_call_topic.sql). */
function sanitizeTopic(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;
  return trimmed.length > MAX_TOPIC_LENGTH ? trimmed.slice(0, MAX_TOPIC_LENGTH) : trimmed;
}

export async function requestCall(
  client: RequestCallClient,
  params: {
    callerId: string;
    recipientId: string;
    requestedDurationSeconds: unknown;
    topic?: unknown;
  },
): Promise<RequestCallResult> {
  const { callerId, recipientId, requestedDurationSeconds } = params;

  if (!callerId || !recipientId) {
    return { ok: false, error: "callerId and recipientId are required", status: 400 };
  }

  if (callerId === recipientId) {
    return { ok: false, error: "cannot call yourself", status: 400 };
  }

  if (!isValidDurationSeconds(requestedDurationSeconds)) {
    return {
      ok: false,
      error: "requestedDurationSeconds must be a whole number of seconds between 60 and 3600",
      status: 400,
    };
  }

  const connected = await client.hasActiveConnection(callerId, recipientId);
  if (!connected) {
    return { ok: false, error: "no active connection between caller and recipient", status: 403 };
  }

  const session = await client.createCallSession({
    callerId,
    recipientId,
    requestedDurationSeconds,
    topic: sanitizeTopic(params.topic),
  });
  return { ok: true, session };
}
