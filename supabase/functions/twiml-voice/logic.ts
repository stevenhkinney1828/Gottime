// Pure TwiML-construction and request-validation logic for the app-to-app <Dial><Client>
// webhook. Every attribute name/placement here (statusCallbackEvent's exact vocabulary,
// statusCallback going on <Client> rather than <Dial>, <Parameter> as identity's sibling
// rather than a replacement for it, timeLimit on <Dial>, the "client:identity" From format)
// was checked against Twilio's current TwiML docs before writing this — see DECISIONS.md.

export interface CallSessionForTwiml {
  id: string;
  callerId: string;
  recipientIdentity: string;
  requestedDurationSeconds: number;
}

function xmlEscape(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** `statusCallbackBaseUrl` is this project's own twilio-status-callback function URL; the
 * call_session_id query parameter on it is how that webhook — which Twilio delivers as plain
 * form fields with no way to carry our own custom parameters (`<Parameter>` only reaches the
 * Voice SDK client, never a server webhook) — learns which row to update. */
export function buildDialTwiml(
  session: CallSessionForTwiml,
  statusCallbackBaseUrl: string,
): string {
  const statusCallbackUrl = `${statusCallbackBaseUrl}?call_session_id=${
    encodeURIComponent(session.id)
  }`;
  return '<?xml version="1.0" encoding="UTF-8"?>' +
    `<Response><Dial timeLimit="${session.requestedDurationSeconds}">` +
    `<Client statusCallbackEvent="ringing answered completed" ` +
    `statusCallback="${xmlEscape(statusCallbackUrl)}" statusCallbackMethod="POST">` +
    `<Parameter name="callSessionId" value="${xmlEscape(session.id)}"/>` +
    `${xmlEscape(session.recipientIdentity)}</Client></Dial></Response>`;
}

export const REJECT_TWIML = '<?xml version="1.0" encoding="UTF-8"?><Response><Reject/></Response>';

/** Twilio Voice SDK calls always present the caller's own identity as `From: client:<identity>`
 * (never a phone number, for an app-to-app call) — the one fact this webhook can check for
 * free to confirm the `callSessionId` the caller's app supplied actually belongs to them,
 * rather than trusting an arbitrary client-supplied UUID at face value. */
export function isRequestFromCaller(fromParam: string | null, callerId: string): boolean {
  return fromParam === `client:${callerId}`;
}
