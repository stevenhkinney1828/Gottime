// Pure, dependency-injected logic. Deleting an auth.users row is an admin-only operation
// (needs the service_role key), which is why this exists as an Edge Function at all rather
// than something the client could do directly even under RLS — but the client never supplies
// *which* account to delete. actingUserId always comes from the caller's own verified JWT
// (see index.ts), so this can only ever delete the account making the request.

export interface DeleteAccountClient {
  deleteUser(userId: string): Promise<void>;
}

export type DeleteAccountResult =
  | { ok: true }
  | { ok: false; error: string; status: number };

export async function performDeleteAccount(
  client: DeleteAccountClient,
  params: { actingUserId: string },
): Promise<DeleteAccountResult> {
  if (!params.actingUserId) {
    return { ok: false, error: "not authenticated", status: 401 };
  }
  await client.deleteUser(params.actingUserId);
  return { ok: true };
}
