import { assertEquals } from "jsr:@std/assert@1";
import { redact } from "../_shared/logger.ts";

Deno.test("redact masks keys that look like secrets, at any nesting depth", () => {
  const input = {
    userId: "abc123",
    access_token: "super-secret",
    nested: { apiKey: "also-secret", ok: "fine" },
  };
  const result = redact(input) as Record<string, unknown>;
  assertEquals(result.userId, "abc123");
  assertEquals(result.access_token, "[redacted]");
  assertEquals((result.nested as Record<string, unknown>).apiKey, "[redacted]");
  assertEquals((result.nested as Record<string, unknown>).ok, "fine");
});

Deno.test("redact passes through primitives and recurses into arrays", () => {
  assertEquals(redact("hello"), "hello");
  assertEquals(redact(42), 42);
  assertEquals(redact(null), null);
  assertEquals(redact([{ token: "secret" }]), [{ token: "[redacted]" }]);
});
