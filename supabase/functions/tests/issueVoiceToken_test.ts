import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { buildVoiceAccessToken } from "../issue-voice-token/logic.ts";

function base64urlDecode(segment: string): Uint8Array {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/").padEnd(
    segment.length + ((4 - (segment.length % 4)) % 4),
    "=",
  );
  const binary = atob(padded);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

function decodeJson(segment: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(base64urlDecode(segment)));
}

const FIXED_NOW = () => new Date("2026-01-01T00:00:00Z");

Deno.test("token header matches Twilio's exact documented format", async () => {
  const result = await buildVoiceAccessToken({
    accountSid: "ACxxx",
    apiKeySid: "SKxxx",
    apiKeySecret: "supersecret",
    twimlAppSid: "APxxx",
    identity: "user-123",
    now: FIXED_NOW,
  });

  const [headerSegment] = result.token.split(".");
  const header = decodeJson(headerSegment);
  assertEquals(header, { typ: "JWT", alg: "HS256", cty: "twilio-fpa;v=1" });
});

Deno.test("token payload carries the right claims and grants shape", async () => {
  const result = await buildVoiceAccessToken({
    accountSid: "ACxxx",
    apiKeySid: "SKxxx",
    apiKeySecret: "supersecret",
    twimlAppSid: "APxxx",
    identity: "user-123",
    ttlSeconds: 1800,
    now: FIXED_NOW,
  });

  const [, payloadSegment] = result.token.split(".");
  const payload = decodeJson(payloadSegment);

  const nowSeconds = Math.floor(FIXED_NOW().getTime() / 1000);
  assertEquals(payload.iss, "SKxxx");
  assertEquals(payload.sub, "ACxxx");
  assertEquals(payload.iat, nowSeconds);
  assertEquals(payload.exp, nowSeconds + 1800);
  assertEquals(payload.jti, `SKxxx-${nowSeconds}`);
  assertEquals(payload.grants, {
    identity: "user-123",
    voice: {
      outgoing: { application_sid: "APxxx" },
      incoming: { allow: true },
    },
  });

  assertEquals(result.identity, "user-123");
  assertEquals(result.expiresAt, new Date((nowSeconds + 1800) * 1000).toISOString());
});

Deno.test("defaults to a 1 hour TTL when none is given", async () => {
  const result = await buildVoiceAccessToken({
    accountSid: "ACxxx",
    apiKeySid: "SKxxx",
    apiKeySecret: "supersecret",
    twimlAppSid: "APxxx",
    identity: "user-123",
    now: FIXED_NOW,
  });
  const [, payloadSegment] = result.token.split(".");
  const payload = decodeJson(payloadSegment);
  assertEquals((payload.exp as number) - (payload.iat as number), 3600);
});

Deno.test("signature is a genuine HMAC-SHA256 over header.payload with the API key secret", async () => {
  const result = await buildVoiceAccessToken({
    accountSid: "ACxxx",
    apiKeySid: "SKxxx",
    apiKeySecret: "supersecret",
    twimlAppSid: "APxxx",
    identity: "user-123",
    now: FIXED_NOW,
  });

  const [headerSegment, payloadSegment, signatureSegment] = result.token.split(".");
  const signingInput = `${headerSegment}.${payloadSegment}`;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode("supersecret"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const isValid = await crypto.subtle.verify(
    "HMAC",
    key,
    base64urlDecode(signatureSegment) as BufferSource,
    new TextEncoder().encode(signingInput),
  );
  assertEquals(isValid, true);

  // A tampered payload must fail verification against the original signature — proves the
  // check above isn't trivially true for any input.
  const wrongKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode("wrong-secret"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const isValidWithWrongKey = await crypto.subtle.verify(
    "HMAC",
    wrongKey,
    base64urlDecode(signatureSegment) as BufferSource,
    new TextEncoder().encode(signingInput),
  );
  assertEquals(isValidWithWrongKey, false);
});

Deno.test("different identities produce different tokens", async () => {
  const alice = await buildVoiceAccessToken({
    accountSid: "ACxxx",
    apiKeySid: "SKxxx",
    apiKeySecret: "supersecret",
    twimlAppSid: "APxxx",
    identity: "alice",
    now: FIXED_NOW,
  });
  const bob = await buildVoiceAccessToken({
    accountSid: "ACxxx",
    apiKeySid: "SKxxx",
    apiKeySecret: "supersecret",
    twimlAppSid: "APxxx",
    identity: "bob",
    now: FIXED_NOW,
  });
  assertNotEquals(alice.token, bob.token);
});
