# Backend

There is no standalone backend service in this project — see
[ARCHITECTURE.md](../ARCHITECTURE.md) and [DECISIONS.md](../DECISIONS.md) for why. All
backend logic lives in [`supabase/functions/`](../supabase/functions/) as Supabase Edge
Functions (Deno/TypeScript).

This directory holds only:
- **`scripts/`** — small one-time or occasional scripts run locally against real credentials
  (e.g. `twilio-setup.ts`, created in Phase 4, which provisions the Twilio TwiML App and API
  Key once instead of doing it by hand through the Twilio console).

## Running the actual backend logic locally

```bash
cd supabase/functions
deno task test    # runs every *_test.ts file
deno task fmt      # format check
deno task lint     # lint
```

No Docker, no Supabase project, and no live credentials are required to run the test suite —
Twilio/Supabase clients are dependency-injected and faked in tests. See
[KNOWN_LIMITATIONS.md](../KNOWN_LIMITATIONS.md) for what this local testing does and doesn't
cover.
