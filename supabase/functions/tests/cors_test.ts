import { assertEquals } from "jsr:@std/assert@1";
import { handlePreflight, jsonResponse } from "../_shared/cors.ts";

Deno.test("handlePreflight responds to OPTIONS and ignores other methods", () => {
  const optionsReq = new Request("https://example.test/fn", { method: "OPTIONS" });
  const response = handlePreflight(optionsReq);
  assertEquals(response?.status, 200);

  const postReq = new Request("https://example.test/fn", { method: "POST" });
  assertEquals(handlePreflight(postReq), null);
});

Deno.test("jsonResponse sets JSON content type, CORS headers, and status", async () => {
  const response = jsonResponse({ ok: true }, { status: 201 });
  assertEquals(response.status, 201);
  assertEquals(response.headers.get("Content-Type"), "application/json");
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "*");
  const body = await response.json();
  assertEquals(body, { ok: true });
});
