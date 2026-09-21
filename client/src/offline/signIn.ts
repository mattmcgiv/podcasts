import { Api } from "../api";
import { assertPasskey } from "../passkey";
import { synchronize } from "./client";
import { prefetch } from "./downloads";

export async function signInAndSync(): Promise<void> {
  const options = await Api.loginOptions();
  await Api.login(options.state_id, await assertPasskey(options.publicKey));
  window.dispatchEvent(new Event("pods-authenticated"));
  await synchronize();
  await prefetch();
}
