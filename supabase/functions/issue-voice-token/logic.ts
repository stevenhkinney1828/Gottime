// Twilio Voice Access Token construction: a JWT in Twilio's "twilio-fpa" format (HS256,
// signed with the API Key Secret directly -- not RSA/ES256 like the Apple-facing JWTs
// elsewhere in this backend). Every field name and the header's exact `cty` value were
// checked against Twilio's current Access Tokens documentation before writing this, not
// recalled from memory -- see DECISIONS.md.
//
// Pure and testable: no Deno.env reads, no network calls. index.ts supplies real credentials
// and identity; tests supply fake ones and decode+verify the resulting token directly.

export interface VoiceTokenParams {
  accountSid: string;
  apiKeySid: string;
  apiKeySecret: string;
  twimlAppSid: string;
  identity: string;
  /** Twilio allows up to 24h (86400s); defaults to 1h, matching Twilio's own "shortest
   * feasible" best-practice guidance. */
  ttlSeconds?: number;
  now?: () => Date;
}

export interface VoiceToken {
  token: string;
  identity: string;
  expiresAt: string;
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function buildVoiceAccessToken(params: VoiceTokenParams): Promise<VoiceToken> {
  const now = (params.now ?? (() => new Date()))();
  const nowSeconds = Math.floor(now.getTime() / 1000);
  const ttlSeconds = params.ttlSeconds ?? 3600;
  const exp = nowSeconds + ttlSeconds;

  const header = { typ: "JWT", alg: "HS256", cty: "twilio-fpa;v=1" };
  const payload = {
    jti: `${params.apiKeySid}-${nowSeconds}`,
    iss: params.apiKeySid,
    sub: params.accountSid,
    iat: nowSeconds,
    exp,
    grants: {
      identity: params.identity,
      voice: {
        outgoing: { application_sid: params.twimlAppSid },
        incoming: { allow: true },
      },
    },
  };

  const encodedHeader = base64url(new TextEncoder().encode(JSON.stringify(header)));
  const encodedPayload = base64url(new TextEncoder().encode(JSON.stringify(payload)));
  const signingInput = `${encodedHeader}.${encodedPayload}`;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(params.apiKeySecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(signingInput),
  );

  const token = `${signingInput}.${base64url(new Uint8Array(signature))}`;
  return { token, identity: params.identity, expiresAt: new Date(exp * 1000).toISOString() };
}
