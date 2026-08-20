import { assertEquals } from "jsr:@std/assert@1";
import { type DeleteAccountClient, performDeleteAccount } from "../delete-account/logic.ts";

class FakeDeleteAccountClient implements DeleteAccountClient {
  deletedUserIds: string[] = [];

  deleteUser(userId: string): Promise<void> {
    this.deletedUserIds.push(userId);
    return Promise.resolve();
  }
}

Deno.test("deletes exactly the acting user's own account", async () => {
  const client = new FakeDeleteAccountClient();

  const result = await performDeleteAccount(client, { actingUserId: "alice-id" });

  assertEquals(result, { ok: true });
  assertEquals(client.deletedUserIds, ["alice-id"]);
});

Deno.test("rejects an empty acting user id rather than calling deleteUser", async () => {
  const client = new FakeDeleteAccountClient();

  const result = await performDeleteAccount(client, { actingUserId: "" });

  assertEquals(result, { ok: false, error: "not authenticated", status: 401 });
  assertEquals(client.deletedUserIds, []);
});
