import { useEffect, useState } from "react";
import { Api } from "../api";
import { assertPasskey } from "../passkey";
import { resolveConflict, state, synchronize, syncError } from "./client";
import { downloadError, prefetch, savePreferences } from "./downloads";
import { allDownloads, type Download, type LocalState } from "./store";

function counted(n: number, singular: string): string {
  return `${n} ${singular}${n === 1 ? "" : "s"}`;
}

export function OfflineSettings() {
  const [local, setLocal] = useState<LocalState | null>(null);
  const [downloads, setDownloads] = useState<Download[]>([]);
  const [status, setStatus] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let active = true;
    const refresh = () => { void Promise.all([state(), allDownloads()]).then(([s, d]) => { if (active) { setLocal(s); setDownloads(d); } }).catch(() => {}); };
    refresh(); window.addEventListener("pods-offline-changed", refresh);
    return () => { active = false; window.removeEventListener("pods-offline-changed", refresh); };
  }, []);
  async function run(action: () => Promise<void>, pending = "") {
    setBusy(true); setStatus(pending);
    try { await action(); setStatus("Done."); }
    catch (error) { setStatus(error instanceof Error ? error.message : "Mac unavailable."); }
    finally { setBusy(false); }
  }
  async function signIn() {
    const options = await Api.loginOptions();
    await Api.login(options.state_id, await assertPasskey(options.publicKey));
    await synchronize();
    await prefetch();
  }
  if (!local) return <section className="settings-section"><p>Loading offline library…</p></section>;
  return <section className="settings-section" aria-label="Offline library" aria-busy={busy}>
    <h2 className="section-title">Mac and downloads</h2>
    <p className="settings-detail">Sync on the same Wi-Fi as your Mac. Only episodes with completed ad removal appear here.</p>
    <p>{local.lastSync ? `Last sync: ${new Date(local.lastSync).toLocaleString()}` : "Not synchronized yet."} {local.outbox.length} pending changes.</p>
    {local.snapshot?.processing && <p className="settings-detail">At last sync: {counted(local.snapshot.processing.pending, "episode")} pending on Mac, {local.snapshot.processing.failed ?? 0} failed and retrying, {counted(local.snapshot.processing.blocked ?? 0, "episode")} could not be processed automatically.
      {local.snapshot.processing.storage.blocked ? " Mac processing paused: storage limit or low disk space." : ""}</p>}
    <button type="button" disabled={busy} onClick={() => void run(async () => { await synchronize(); await prefetch(); }, "Syncing…")}>Sync now</button>
    <button type="button" disabled={busy} onClick={() => void run(signIn, "Syncing…")}>Sign in to Mac</button>
    <label>Automatic episodes <input aria-label="Automatic episodes" type="number" min="0" max="1000" value={local.preferences.count}
      onChange={event => void run(() => savePreferences({ ...local.preferences, count: Number(event.target.value) }))} /></label>
    <label>Storage limit (GiB) <input aria-label="Storage limit (GiB)" type="number" min="0.1" step="0.1" value={local.preferences.limit / 1024 ** 3}
      onChange={event => void run(() => savePreferences({ ...local.preferences, limit: Number(event.target.value) * 1024 ** 3 }))} /></label>
    <p>{downloads.filter(d => d.complete).length} downloaded episodes · {(downloads.reduce((n, d) => n + d.bytes, 0) / 1024 ** 3).toFixed(2)} GiB reserved.</p>
    <p className="settings-detail">Keep Pods open to download automatically. Browser storage can be removed by iOS.</p>
    {(status || syncError() || downloadError()) && <p role="status">{status || syncError() || downloadError()}</p>}
    {local.outbox.filter(o => o.conflict != null).map(operation => <div key={operation.id}>
      <p>A {operation.field} change differs between the phone and Mac.</p>
      <button type="button" disabled={busy} onClick={() => void run(() => resolveConflict(operation.id, true))}>Keep phone</button>
      <button type="button" disabled={busy} onClick={() => void run(() => resolveConflict(operation.id, false))}>Use Mac</button>
    </div>)}
  </section>;
}
