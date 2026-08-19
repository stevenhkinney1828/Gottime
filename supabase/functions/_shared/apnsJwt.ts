// Builds an ES256 provider-authentication JWT for Apple Push Notification service (APNs),
// per Apple's token-based provider connection format. Signed with the VoIP Auth Key (.p8,
// PKCS8 EC private key) obtained from the Apple Developer portal (Phase 5+).
// https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns

export interface ApnsJwtParams {
  teamId: string;
  keyId: string;
  /** PEM-encoded EC private key contents (the .p8 file), header/footer lines included. */
  privateKeyPem: string;
}

/** Decodes a base64 string into a Uint8Array backed by a plain ArrayBuffer (not
 * ArrayBufferLike/SharedArrayBuffer), which is what WebCrypto's BufferSource-typed
 * parameters require under TypeScript 5.7+'s stricter typed-array generics. */
function base64Decode(input: string): Uint8Array {
  const binary = atob(input);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function importApnsKey(pem: string): Promise<CryptoKey> {
  const stripped = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const raw = base64Decode(stripped);
  return crypto.subtle.importKey(
    "pkcs8",
    // Deno's lib types Uint8Array's buffer as ArrayBufferLike (which includes
    // SharedArrayBuffer) even for a freshly constructed, definitely-non-shared buffer,
    // so WebCrypto's stricter BufferSource<ArrayBuffer> parameter type needs this
    // assertion. The runtime value is always a plain ArrayBuffer-backed view.
    raw as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

function base64url(data: ArrayBuffer | Uint8Array): string {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * APNs provider tokens are short-lived by Apple's own recommendation (reused for up to ~55
 * minutes); callers should cache the returned token rather than calling this per push.
 */
export async function buildApnsProviderJwt(params: ApnsJwtParams): Promise<string> {
  const header = { alg: "ES256", kid: params.keyId };
  const claims = { iss: params.teamId, iat: Math.floor(Date.now() / 1000) };
  const encodedHeader = base64url(new TextEncoder().encode(JSON.stringify(header)));
  const encodedClaims = base64url(new TextEncoder().encode(JSON.stringify(claims)));
  const signingInput = `${encodedHeader}.${encodedClaims}`;

  const key = await importApnsKey(params.privateKeyPem);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );

  return `${signingInput}.${base64url(signature)}`;
}
