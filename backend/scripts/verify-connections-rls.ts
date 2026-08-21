// One-time (re-runnable) verification that Phase 3's connection/invite RLS policies and the
// redeem_connection_invite() function behave correctly against the REAL Supabase project, not
// just the local Postgres approximation sql-lint.yml checks against a fresh container. Creates
// three throwaway users via the Admin API (no real Apple ID needed, per the build plan), runs
// them through the actual invite/redeem/visibility/duplicate-prevention flow as real
// authenticated requests, and deletes all three afterward regardless of outcome.
//
// Run:
//   cd backend/scripts
//   SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_SERVICE_ROLE_KEY=... deno run --allow-net --allow-env verify-connections-rls.ts
// (values already in the repo root .env — see README.md in this directory)

const SUPABASE_URL = requireEnv("SUPABASE_URL");
const ANON_KEY = requireEnv("SUPABASE_ANON_KEY");
const SERVICE_ROLE_KEY = requireEnv("SUPABASE_SERVICE_ROLE_KEY");

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    console.error(`Missing required env var: ${name}`);
    Deno.exit(1);
  }
  return value;
}

const failures: string[] = [];

function check(label: string, condition: boolean, detail?: unknown) {
  if (condition) {
    console.log(`  ok   ${label}`);
  } else {
    console.log(
      `  FAIL ${label}${
        detail !== undefined ? ` — ${JSON.stringify(detail)}` : ""
      }`,
    );
    failures.push(label);
  }
}

function fatal(label: string, detail: unknown): never {
  console.error(`  FATAL ${label} — ${JSON.stringify(detail)}`);
  throw new Error(label);
}

interface TestUser {
  id: string;
  email: string;
  accessToken: string;
}

async function createAndSignIn(emailPrefix: string): Promise<TestUser> {
  const email =
    `${emailPrefix}-${crypto.randomUUID()}@gottime-rls-verify.invalid`;
  const password = crypto.randomUUID();

  const createRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      email,
      password,
      email_confirm: true,
      user_metadata: { first_name: emailPrefix },
    }),
  });
  if (!createRes.ok) {
    fatal(`create user ${emailPrefix}`, await createRes.text());
  }
  const created = await createRes.json();
  const id: string = created.id ?? created.user?.id;
  if (!id) fatal(`create user ${emailPrefix}: no id in response`, created);

  const signInRes = await fetch(
    `${SUPABASE_URL}/auth/v1/token?grant_type=password`,
    {
      method: "POST",
      headers: { apikey: ANON_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ email, password }),
    },
  );
  if (!signInRes.ok) fatal(`sign in as ${emailPrefix}`, await signInRes.text());
  const session = await signInRes.json();
  return { id, email, accessToken: session.access_token };
}

function authedHeaders(user: TestUser): Record<string, string> {
  return {
    apikey: ANON_KEY,
    Authorization: `Bearer ${user.accessToken}`,
    "Content-Type": "application/json",
  };
}

async function deleteUser(id: string): Promise<void> {
  await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${id}`, {
    method: "DELETE",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    },
  });
}

async function main() {
  console.log("Creating three throwaway users (Alice, Bob, Carol)...");
  const alice = await createAndSignIn("alice");
  const bob = await createAndSignIn("bob");
  const carol = await createAndSignIn("carol");

  try {
    console.log("\nAlice creates an invite...");
    const inviteRes = await fetch(
      `${SUPABASE_URL}/rest/v1/connection_invites`,
      {
        method: "POST",
        headers: { ...authedHeaders(alice), Prefer: "return=representation" },
        body: JSON.stringify({
          creator_id: alice.id,
          invite_code: `RLS${crypto.randomUUID().slice(0, 4).toUpperCase()}`,
        }),
      },
    );
    if (!inviteRes.ok) fatal("create invite as Alice", await inviteRes.text());
    const [invite] = await inviteRes.json();
    console.log(`  created invite ${invite.invite_code}`);

    console.log("\nBob redeems Alice's invite...");
    const redeemRes = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/redeem_connection_invite`,
      {
        method: "POST",
        headers: authedHeaders(bob),
        body: JSON.stringify({ p_invite_code: invite.invite_code }),
      },
    );
    if (!redeemRes.ok) {
      fatal("Bob redeem Alice's invite", await redeemRes.text());
    }
    const connection = await redeemRes.json();
    check(
      "redemption returns an active connection",
      connection.status === "active",
      connection,
    );

    console.log("\nChecking mutual visibility...");
    const aliceSeesBob = await fetch(
      `${SUPABASE_URL}/rest/v1/profiles?select=id&id=eq.${bob.id}`,
      { headers: authedHeaders(alice) },
    ).then((r) => r.json());
    check(
      "Alice can see Bob's profile after connecting",
      aliceSeesBob.length === 1,
      aliceSeesBob,
    );

    const bobSeesAlice = await fetch(
      `${SUPABASE_URL}/rest/v1/profiles?select=id&id=eq.${alice.id}`,
      { headers: authedHeaders(bob) },
    ).then((r) => r.json());
    check(
      "Bob can see Alice's profile after connecting",
      bobSeesAlice.length === 1,
      bobSeesAlice,
    );

    const aliceSeesConnection = await fetch(
      `${SUPABASE_URL}/rest/v1/connections?select=id&status=eq.active`,
      { headers: authedHeaders(alice) },
    ).then((r) => r.json());
    check(
      "Alice sees exactly one active connection",
      aliceSeesConnection.length === 1,
      aliceSeesConnection,
    );

    console.log("\nChecking Carol (unconnected) is denied...");
    const carolSeesAlice = await fetch(
      `${SUPABASE_URL}/rest/v1/profiles?select=id&id=eq.${alice.id}`,
      { headers: authedHeaders(carol) },
    ).then((r) => r.json());
    check(
      "Carol cannot see Alice's profile (not connected)",
      carolSeesAlice.length === 0,
      carolSeesAlice,
    );

    const carolSeesConnections = await fetch(
      `${SUPABASE_URL}/rest/v1/connections?select=id`,
      { headers: authedHeaders(carol) },
    ).then((r) => r.json());
    check(
      "Carol sees zero connections (not a participant in any)",
      carolSeesConnections.length === 0,
      carolSeesConnections,
    );

    console.log("\nChecking duplicate/self redemption are rejected...");
    const reRedeemRes = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/redeem_connection_invite`,
      {
        method: "POST",
        headers: authedHeaders(carol),
        body: JSON.stringify({ p_invite_code: invite.invite_code }),
      },
    );
    check(
      "redeeming an already-redeemed code fails",
      !reRedeemRes.ok,
      await reRedeemRes.clone().text(),
    );

    const selfInviteRes = await fetch(
      `${SUPABASE_URL}/rest/v1/connection_invites`,
      {
        method: "POST",
        headers: { ...authedHeaders(carol), Prefer: "return=representation" },
        body: JSON.stringify({
          creator_id: carol.id,
          invite_code: `RLS${crypto.randomUUID().slice(0, 4).toUpperCase()}`,
        }),
      },
    );
    if (!selfInviteRes.ok) {
      fatal("Carol creates her own invite", await selfInviteRes.text());
    }
    const [carolInvite] = await selfInviteRes.json();
    const selfRedeemRes = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/redeem_connection_invite`,
      {
        method: "POST",
        headers: authedHeaders(carol),
        body: JSON.stringify({ p_invite_code: carolInvite.invite_code }),
      },
    );
    check(
      "redeeming your own invite fails",
      !selfRedeemRes.ok,
      await selfRedeemRes.clone().text(),
    );
  } finally {
    console.log("\nCleaning up throwaway users...");
    await Promise.all([alice, bob, carol].map((u) => deleteUser(u.id)));
  }

  console.log(
    `\n${
      failures.length === 0
        ? "ALL CHECKS PASSED"
        : `${failures.length} CHECK(S) FAILED`
    }`,
  );
  if (failures.length > 0) {
    console.log(failures.map((f) => `  - ${f}`).join("\n"));
    Deno.exit(1);
  }
}

await main();
