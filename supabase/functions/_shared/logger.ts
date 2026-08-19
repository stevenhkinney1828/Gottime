// Structured logging across the categories called out in the spec (auth, push registration,
// incoming VoIP events, Twilio state, timer state, backend requests, teardown) with
// deliberate secret redaction. Never log passwords, access tokens, or secrets — enforced here
// by pattern-matching key names rather than trusting every call site to remember.

export type LogCategory =
  | "auth"
  | "push"
  | "twilio"
  | "call_state"
  | "timer"
  | "request"
  | "teardown";

const SECRET_KEY_PATTERN = /token|secret|password|api[-_]?key|authorization|auth_token/i;

export function redact(value: unknown): unknown {
  if (value === null || value === undefined || typeof value !== "object") {
    return value;
  }
  if (Array.isArray(value)) {
    return value.map(redact);
  }
  const result: Record<string, unknown> = {};
  for (const [key, val] of Object.entries(value as Record<string, unknown>)) {
    result[key] = SECRET_KEY_PATTERN.test(key) ? "[redacted]" : redact(val);
  }
  return result;
}

export function log(
  category: LogCategory,
  message: string,
  context: Record<string, unknown> = {},
): void {
  const entry = {
    ts: new Date().toISOString(),
    category,
    message,
    ...(redact(context) as Record<string, unknown>),
  };
  console.log(JSON.stringify(entry));
}
