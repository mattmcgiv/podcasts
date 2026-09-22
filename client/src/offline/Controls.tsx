import { useEffect, useState } from "react";
import { defaultDeviceName, resolveConflict, state, synchronize, syncError } from "./client";
import { downloadError, prefetch, savePreferences } from "./downloads";
import { signInAndSync } from "./signIn";
import { allDownloads, updateState, type Download, type LocalState } from "./store";
import { fmtTime } from "../lib";

export function changeDescription(local: LocalState, _entity: string, field: string, value: unknown): string {
  if (field === "position") return fmtTime(Number((value as {seconds?: number})?.seconds ?? 0));
  if (field === "played") return value ? "Played" : "Unplayed";
  if (field === "last_listened") return local.snapshot?.episodes.find(e => e.id === Number(value))?.title ?? "Last-listened episode";
  return String(value);
}

export async function exportSyncBackup(): Promise<void> {
  const data = { format: "pods-state-backup-v1", exported_at: new Date().toISOString(), state: await state() };
  const url = URL.createObjectURL(new Blob([JSON.stringify(data)], { type: "application/json" }));
  const link = document.createElement("a"); link.href = url; link.download = "pods-state-backup.json"; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function counted(n: number, singular: string): string {
  return `${n} ${singular}${n === 1 ? "" : "s"}`;
}

export function OfflineSettings() {
  const [local, setLocal] = useState<LocalState | null>(null);
  const [downloads, setDownloads] = useState<Download[]>([]);
  const [status, setStatus] = useState("");
  const [busy, setBusy] = useState(false);
  const [action, setAction] = useState<"sync" | "sign-in" | "backup" | null>(null);
  useEffect(() => {
    let active = true;
    const refresh = () => { void Promise.all([state(), allDownloads()]).then(([s, d]) => { if (active) { setLocal(s); setDownloads(d); } }).catch(() => {}); };
    refresh(); window.addEventListener("pods-offline-changed", refresh);
    return () => { active = false; window.removeEventListener("pods-offline-changed", refresh); };
  }, []);
  async function run(work: () => Promise<void>, name: "sync" | "sign-in" | "backup" | null = null, pending = "") {
    setBusy(true); setAction(name); setStatus(pending);
    try { await work(); setStatus("Done."); }
    catch (error) { setStatus(error instanceof Error ? error.message : "Mac unavailable."); }
    finally { setBusy(false); setAction(null); }
  }
  if (!local) return <section className="settings-section"><p>Loading offline library…</p></section>;
  return <section className="settings-section" aria-label="Offline library" aria-busy={busy}>
    <h2 className="section-title">Mac and downloads</h2>
    <p className="settings-detail">Connect this device and your Mac to Tailscale to synchronize. Downloads work while the Mac is unavailable.</p>
    <label>Device name <input aria-label="Device name" maxLength={80} defaultValue={local.device_name ?? defaultDeviceName()}
      onBlur={event => void run(async () => { const name = event.target.value.trim() || defaultDeviceName(); await updateState(s => { s.device_name = name; }); })} /></label>
    <p>{local.lastSync ? `Last sync: ${new Date(local.lastSync).toLocaleString()}` : "Not synchronized yet."} {local.outbox.length} pending changes.</p>
    {local.snapshot?.processing && <p className="settings-detail">At last sync: {counted(local.snapshot.processing.pending, "episode")} pending on Mac, {local.snapshot.processing.failed ?? 0} failed and retrying, {counted(local.snapshot.processing.blocked ?? 0, "episode")} could not be processed automatically.
      {local.snapshot.processing.storage.blocked ? " Mac processing paused: storage limit or low disk space." : ""}</p>}
    <div className="settings-action-list">
      <button type="button" className={`settings-btn primary${action === "sync" ? " is-busy" : ""}`} disabled={busy} aria-busy={action === "sync"} onClick={() => void run(async () => { await synchronize(); await prefetch(); }, "sync", "Syncing…")}>{action === "sync" ? "Syncing…" : "Sync now"}</button>
      <button type="button" className={`settings-btn primary${action === "sign-in" ? " is-busy" : ""}`} disabled={busy} aria-busy={action === "sign-in"} onClick={() => void run(signInAndSync, "sign-in", "Signing in…")}>{action === "sign-in" ? "Signing in…" : "Sign in to Mac"}</button>
      <button type="button" className={`settings-btn${action === "backup" ? " is-busy" : ""}`} disabled={busy} aria-busy={action === "backup"} onClick={() => void run(exportSyncBackup, "backup", "Exporting…")}>{action === "backup" ? "Exporting…" : "Export state backup"}</button>
    </div>
    <label>Automatic episodes <input aria-label="Automatic episodes" type="number" min="0" max="1000" value={local.preferences.count}
      onChange={event => void run(() => savePreferences({ ...local.preferences, count: Number(event.target.value) }))} /></label>
    <label>Storage limit (GiB) <input aria-label="Storage limit (GiB)" type="number" min="0.1" step="0.1" value={local.preferences.limit / 1024 ** 3}
      onChange={event => void run(() => savePreferences({ ...local.preferences, limit: Number(event.target.value) * 1024 ** 3 }))} /></label>
    <p>{downloads.filter(d => d.complete).length} downloaded episodes · {(downloads.reduce((n, d) => n + d.bytes, 0) / 1024 ** 3).toFixed(2)} GiB reserved.</p>
    <p className="settings-detail">Keep Pods open to download automatically. Browser storage can be removed by iOS.</p>
    {(status || syncError() || downloadError()) && <p role="status">{status || syncError() || downloadError()}</p>}
    {local.outbox.filter(o => o.conflict != null).map(operation => <div key={operation.id}>
      <p>{local.snapshot?.episodes.find(e => String(e.id) === operation.entity)?.title ?? operation.field}: this device and the shared library both changed this.</p>
      <p>{local.device_name ?? defaultDeviceName()}: {changeDescription(local, operation.entity, operation.field, local.outbox.filter(o => o.entity === operation.entity && o.field === operation.field).at(-1)?.value)}</p>
      <p>{local.snapshot?.writers?.[`${operation.entity}:${operation.field}`]?.device ?? "Shared library"}: {changeDescription(local, operation.entity, operation.field,
        operation.entity === "settings" ? local.snapshot?.settings[operation.field] : operation.field === "position" ? {seconds:local.snapshot?.episodes.find(e => String(e.id) === operation.entity)?.position_secs} : operation.field === "played" ? local.snapshot?.episodes.find(e => String(e.id) === operation.entity)?.played_at != null : "Subscription")}</p>
      <button type="button" className="settings-btn" disabled={busy} onClick={() => void run(() => resolveConflict(operation.id, true))}>Keep this device’s change</button>
      <button type="button" className="settings-btn" disabled={busy} onClick={() => void run(() => resolveConflict(operation.id, false))}>Use the shared change</button>
    </div>)}
    {local.outbox.filter(o => o.error).map(o => <div key={o.id}>
      <p role="alert">{o.error} The change is still saved on this device.</p>
      <button type="button" className="settings-btn" disabled={busy} onClick={() => void run(() => resolveConflict(o.id, true))}>Try again</button>
      <button type="button" className="settings-btn" disabled={busy} onClick={() => void run(() => resolveConflict(o.id, false))}>Discard this change</button>
    </div>)}
  </section>;
}
