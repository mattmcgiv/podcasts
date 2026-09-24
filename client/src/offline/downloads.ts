import { emitEpisodesChanged } from "../events";
import { applyOverlay, backendBase, state } from "./client";
import { logDiagnostic } from "./diagnostics";
import { currentDownloadProgress, setDownloadProgress } from "./progress";
import * as store from "./store";
import type { ArtifactManifest, Download, LocalState, Preferences } from "./store";

let activeHash: string | null = null;
let running: Promise<void> | null = null;
let error: string | null = null;
export const downloadError = () => error;
export function protectPlayingArtifact(hash: string | null): void { activeHash = hash; }
const changed = () => { emitEpisodesChanged(); window.dispatchEvent(new Event("pods-offline-changed")); };

export async function savePreferences(preferences: Preferences): Promise<void> {
  if (!Number.isFinite(preferences.limit) || preferences.limit < 100 * 1024 ** 2 || !Number.isInteger(preferences.count) || preferences.count < 0 || preferences.count > 1000) throw new Error("Invalid download limits.");
  await store.updateState(s => { s.preferences = { limit: preferences.limit, count: preferences.count }; });
  changed();
}

function downloadEligible(id: number, s: LocalState): boolean {
  if (!s.snapshot) return false;
  const episode = applyOverlay(s.snapshot, s.outbox).episodes.find(e => e.id === id);
  return episode != null && episode.played_at == null && episode.archived_at == null && episode.manifest != null;
}

/** Delete one episode's download record, chunks, and cached manifest. Idempotent. */
export async function cleanupPlayedDownload(id: number): Promise<void> {
  const hashes = new Set<string>();
  for (const download of await store.allDownloads()) {
    if (download.episode === id) hashes.add(download.hash);
  }
  const s = await state();
  const episode = (s.snapshot ? applyOverlay(s.snapshot, s.outbox).episodes.find(e => e.id === id) : undefined)
    ?? s.snapshot?.episodes.find(e => e.id === id);
  if (episode?.manifest?.hash) hashes.add(episode.manifest.hash);
  for (const hash of hashes) if (hash !== activeHash) await store.deleteDownload(hash);
  if (currentDownloadProgress()?.episode === id) setDownloadProgress(null);
  if (hashes.size) changed();
}

export async function sweepStaleDownloads(): Promise<void> {
  const s = await state();
  const episodes = s.snapshot ? applyOverlay(s.snapshot, s.outbox).episodes : [];
  const stale = new Set(episodes.filter(e => e.played_at != null || e.archived_at != null).map(e => e.id));
  const ids = new Set((await store.allDownloads()).filter(d => stale.has(d.episode)).map(d => d.episode));
  for (const id of ids) await cleanupPlayedDownload(id);
}

async function makeRoom(manifest: ArtifactManifest): Promise<void> {
  const s = await state();
  const downloads = await store.allDownloads();
  let used = downloads.filter(d => d.hash !== manifest.hash).reduce((total, d) => total + d.bytes, 0);
  const current = s.snapshot ? applyOverlay(s.snapshot, s.outbox).episodes : [];
  const candidates = downloads.filter(d => d.hash !== activeHash && d.hash !== manifest.hash);
  candidates.sort((a, b) => {
    const ae = current.find(e => e.id === a.episode), be = current.find(e => e.id === b.episode);
    return Number(be?.played_at != null) - Number(ae?.played_at != null) || (be?.published_at ?? Infinity) - (ae?.published_at ?? Infinity);
  });
  for (const download of candidates) {
    if (used + manifest.bytes <= s.preferences.limit) break;
    await store.deleteDownload(download.hash);
    used -= download.bytes;
  }
  if (used + manifest.bytes > s.preferences.limit) throw new Error("Download limit reached. Increase the storage limit.");
  const estimate = await navigator.storage?.estimate?.();
  if (estimate?.quota && estimate.usage != null && estimate.quota - estimate.usage < manifest.bytes + 20 * 1024 ** 2) throw new Error("Browser storage is full. Increase the storage limit or free space on this device.");
}

export function downloadEpisode(id: number): Promise<void> {
  if (running) return running.then(() => downloadEpisode(id));
  running = download(id).catch(caught => {
    error = caught instanceof Error ? caught.message : "Download interrupted.";
    logDiagnostic("download-error", `episode_id=${id} error=${error}`);
    throw caught;
  })
    .finally(() => { running = null; setDownloadProgress(null); changed(); });
  return running;
}

async function persistDownload(manifest: ArtifactManifest, id: number, received: number, complete: boolean): Promise<void> {
  await store.writeRecord("downloads", manifest.hash, {
    hash: manifest.hash, episode: id, bytes: manifest.bytes, received, complete, touched: Date.now(),
  } satisfies Download);
  if (complete) setDownloadProgress(null);
  else setDownloadProgress({ episode: id, received, total: manifest.bytes });
}

async function download(id: number): Promise<void> {
  const s = await state();
  if (!downloadEligible(id, s)) return;
  const manifest = s.snapshot?.episodes.find(e => e.id === id)?.manifest;
  if (!manifest) throw new Error("Processed episode unavailable.");
  if (manifest.chunk_size !== 1024 ** 2 || manifest.chunks.length !== Math.ceil(manifest.bytes / manifest.chunk_size)) throw new Error("Invalid audio manifest.");
  await makeRoom(manifest);
  await store.writeRecord("meta", `manifest:${manifest.hash}`, manifest);
  await persistDownload(manifest, id, 0, false);
  changed();
  let received = 0;
  for (let index = 0; index < manifest.chunks.length; index++) {
    if (!downloadEligible(id, await state())) {
      await store.deleteDownload(manifest.hash);
      if (currentDownloadProgress()?.episode === id) setDownloadProgress(null);
      return;
    }
    if (document.visibilityState === "hidden") throw new Error("Download paused. Open Pods to resume.");
    const key = `${manifest.hash}:${index}`;
    const cached = await store.readRecord<ArrayBuffer>("chunks", key);
    if (cached && await verifyChunk(cached, manifest.chunks[index])) {
      received += cached.byteLength;
      await persistDownload(manifest, id, received, false);
      continue;
    }
    const start = index * manifest.chunk_size, end = Math.min(manifest.bytes, start + manifest.chunk_size) - 1;
    const response = await fetch(`${backendBase()}/api/artifacts/${manifest.hash}`, {
      credentials: "include", headers: { Range: `bytes=${start}-${end}`, "If-Range": `"${manifest.hash}"` }, signal: AbortSignal.timeout(15000) });
    if (response.status !== 206 || response.headers.get("content-range") !== `bytes ${start}-${end}/${manifest.bytes}`) throw new Error("Mac unavailable or audio changed. Reconnect to resume.");
    const bytes = await response.arrayBuffer();
    if (bytes.byteLength !== end - start + 1 || !await verifyChunk(bytes, manifest.chunks[index])) throw new Error("Audio verification failed. Retry the download.");
    await store.writeRecord("chunks", key, bytes);
    received += bytes.byteLength;
    await persistDownload(manifest, id, received, false);
  }
  if (!downloadEligible(id, await state())) {
    await store.deleteDownload(manifest.hash);
    if (currentDownloadProgress()?.episode === id) setDownloadProgress(null);
    return;
  }
  await persistDownload(manifest, id, manifest.bytes, true);
  error = null;
}

export async function verifyChunk(bytes: ArrayBuffer, expected: string): Promise<boolean> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map(v => v.toString(16).padStart(2, "0")).join("") === expected;
}

export async function prefetch(): Promise<void> {
  try { await sweepStaleDownloads(); } catch { /* A later bootstrap/sync pass retries. */ }
  if (document.visibilityState === "hidden") return;
  const s = await state();
  const episodes = (s.snapshot ? applyOverlay(s.snapshot, s.outbox).episodes : []).filter(e => e.played_at == null && e.archived_at == null);
  let planned = 0;
  const last = Number((s.snapshot ? applyOverlay(s.snapshot, s.outbox).settings.last_listened : 0));
  const queue = episodes.slice().sort((a, b) => Number(b.id === last) - Number(a.id === last)).slice(0, s.preferences.count);
  for (const episode of queue) {
    if (!downloadEligible(episode.id, await state())) continue;
    planned += episode.manifest?.bytes ?? 0;
    if (planned > s.preferences.limit) break;
    const downloaded = episode.manifest && await store.readRecord<Download>("downloads", episode.manifest.hash);
    if (downloaded?.complete) continue;
    try { await downloadEpisode(episode.id); } catch { break; }
  }
}
