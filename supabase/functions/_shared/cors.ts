// CORS handling for Edge Functions. The iOS app itself never makes browser CORS requests,
// but Supabase's local function-serving dashboard and any future web-based admin tooling do,
// so every function preflights consistently rather than each hand-rolling this.

const ALLOWED_HEADERS = "authorization, x-client-info, apikey, content-type";

export function corsHeaders(): HeadersInit {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": ALLOWED_HEADERS,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

/** Returns a preflight Response if this was an OPTIONS request, otherwise null. */
export function handlePreflight(req: Request): Response | null {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }
  return null;
}

export function jsonResponse(body: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
      ...init.headers,
    },
  });
}
