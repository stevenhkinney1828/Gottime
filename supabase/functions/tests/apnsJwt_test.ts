import { assert, assertEquals } from "jsr:@std/assert@1";
import { buildApnsProviderJwt } from "../_shared/apnsJwt.ts";

function toPem(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  const b64 = btoa(binary);
  const lines = b64.match(/.{1,64}/g) ?? [];
  return `-----BEGIN PRIVATE KEY-----\n${lines.join("\n")}\n-----END PRIVATE KEY-----\n`;
}

function base64urlDecode(input: string): Uint8Array {
  const padded = input.replace(/-/g, "+").replace(/_/g, "/");
  const pad = padded.length % 4 === 0 ? "" : "=".repeat(4 - (padded.length % 4));
  const binary = atob(padded + pad);
  // A manual loop (rather than Uint8Array.from) guarantees a plain ArrayBuffer-backed
  // result, which is what WebCrypto's BufferSource-typed parameters require under
  // TypeScript 5.7+'s stricter typed-array generics.
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

Deno.test("buildApnsProviderJwt produces a structurally correct, verifiably signed ES256 JWT", async () => {
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", keyPair.privateKey);
  const pem = toPem(pkcs8);

  const jwt = await buildApnsProviderJwt({
    teamId: "TEAM123456",
    keyId: "KEY1234567",
    privateKeyPem: pem,
  });

  const parts = jwt.split(".");
  assertEquals(parts.length, 3);

  const header = JSON.parse(new TextDecoder().decode(base64urlDecode(parts[0])));
  assertEquals(header.alg, "ES256");
  assertEquals(header.kid, "KEY1234567");

  const claims = JSON.parse(new TextDecoder().decode(base64urlDecode(parts[1])));
  assertEquals(claims.iss, "TEAM123456");
  assert(typeof claims.iat === "number");
  assert(Math.abs(Date.now() / 1000 - claims.iat) < 10);

  const signingInput = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const signature = base64urlDecode(parts[2]);
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    keyPair.publicKey,
    // See the matching comment in _shared/apnsJwt.ts — Deno's lib types a freshly
    // constructed Uint8Array's buffer as ArrayBufferLike, so WebCrypto's stricter
    // BufferSource<ArrayBuffer> parameter needs this assertion.
    signature as BufferSource,
    signingInput,
  );
  assert(valid, "JWT signature must verify against the signing key's public key");
});
