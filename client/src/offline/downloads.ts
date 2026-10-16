import { emitEpisodesChanged } from "../events";
import { applyOverlay, backendBase, state } from "./client";
import { logDiagnostic } from "./diagnostics";
import { currentDownloadProgress, setDownloadProgress } from "./progress";
import * as store from "./store";
import type { ArtifactManifest, Download, LocalState, Preferences } from "./store";

/** A chunk transfer is abandoned once no bytes have arrived for this long. A slow link that keeps delivering keeps going. */
let chunkStallMs = 20_000;
/** Waits before re-requesting one chunk after a dropped or stalled transfer. */
let chunkRetryDelays = [1_000, 3_000];

/** `device` failures (no Mac, no storage, page hidden) stop the queue; `episode` failures skip one episode. */
export class DownloadError extends Error {
  constructor(message: string, readonly scope: "episode" | "device") {
    super(message);
    this.name = "DownloadError";
  }
}

/** A dropped connection or a stalled body. Retried before it becomes a device-scope failure. */
class TransientError extends Error {}

const STALLED = "Download stalled. Check the connection, then retry.";
const UNREACHABLE = "Mac unavailable. Check Tailscale, then retry.";
const MAC_ERROR = "Mac unavailable. Reconnect to resume.";

let activeHash: string | null = null;
let tail: Promise<void> | null = null;
let automaticPass: Promise<void> | null = null;
let queueNotice: string | null = null;
export const downloadQueueNotice = () => queueNotice;
const pending = new Map<number, Promise<void>>();
let error: string | null = null;
const errors = new Map<number, string>();
export const downloadError = () => error;
/** The failure recorded for one episode's download, cleared when a new attempt starts. */
export const downloadErrorFor = (id: number): string | null => errors.get(id) ?? null;
export function protectPlayingArtifact(hash: string | null): void { activeHash = hash; }
const changed = () => { emitEpisodesChanged(); window.dispatchEvent(new Event("pods-offline-changed")); };

/** Test-only: shorten the stall window and retry delays. No-op in production builds. */
export function configureDownloadRetriesForTests(delays: number[], stallMs = chunkStallMs): void {
  if (import.meta.env.PROD) return;
  chunkRetryDelays = delays;
  chunkStallMs = stallMs;
  errors.clear();
  error = null;
  queueNotice = null;
}

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
  errors.delete(id);
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
  // Never evict an unplayed download to fetch another one: the next automatic
  // pass would fetch the evicted episode again and evict this one in return.
  const candidates = downloads.filter(d => {
    const episode = current.find(e => e.id === d.episode);
    return d.hash !== activeHash && d.hash !== manifest.hash
      && episode != null && (episode.played_at != null || episode.archived_at != null);
  });
  candidates.sort((a, b) => {
    const ae = current.find(e => e.id === a.episode), be = current.find(e => e.id === b.episode);
    return Number(be?.played_at != null) - Number(ae?.played_at != null) || (be?.published_at ?? Infinity) - (ae?.published_at ?? Infinity);
  });
  for (const download of candidates) {
    if (used + manifest.bytes <= s.preferences.limit) break;
    await store.deleteDownload(download.hash);
    used -= download.bytes;
  }
  if (used + manifest.bytes > s.preferences.limit) throw new DownloadError("Download limit reached. Increase the storage limit.", "device");
  const estimate = await navigator.storage?.estimate?.();
  const existing = downloads.find(d => d.hash === manifest.hash);
  const remaining = manifest.bytes - Math.min(existing?.received ?? 0, manifest.bytes);
  if (estimate?.quota && estimate.usage != null && estimate.quota - estimate.usage < remaining + 20 * 1024 ** 2) throw new DownloadError("Browser storage is full. Increase the storage limit or free space on this device.", "device");
}

/**
 * Transfers run one at a time. A second request for an episode that is already running or
 * queued shares that attempt instead of starting another pass over the same chunks.
 */
export function downloadEpisode(id: number): Promise<void> {
  const queued = pending.get(id);
  if (queued) return queued;
  errors.delete(id);
  const previous = tail ?? Promise.resolve();
  const task = previous
    .then(() => download(id), caught => {
      // Nothing behind a device-wide failure can succeed right now; episode failures only skip one episode.
      if (caught instanceof DownloadError && caught.scope === "device") throw caught;
      return download(id);
    })
    .catch(caught => {
      error = caught instanceof Error ? caught.message : "Download interrupted.";
      errors.set(id, error);
      logDiagnostic("download-error", `episode_id=${id} error=${error}`);
      throw caught;
    })
    .finally(() => {
      pending.delete(id);
      if (tail === task) tail = null;
      if (currentDownloadProgress()?.episode === id) setDownloadProgress(null);
      changed();
    });
  pending.set(id, task);
  tail = task;
  return task;
}

async function persistDownload(manifest: ArtifactManifest, id: number, received: number, complete: boolean): Promise<void> {
  await store.writeRecord("downloads", manifest.hash, {
    hash: manifest.hash, episode: id, bytes: manifest.bytes, received, complete, touched: Date.now(),
  } satisfies Download);
  if (complete) setDownloadProgress(null);
  else setDownloadProgress({ episode: id, received, total: manifest.bytes });
}

async function abandon(manifest: ArtifactManifest, id: number): Promise<void> {
  await store.deleteDownload(manifest.hash);
  if (currentDownloadProgress()?.episode === id) setDownloadProgress(null);
}

async function download(id: number): Promise<void> {
  const s = await state();
  if (!downloadEligible(id, s)) return;
  const manifest = s.snapshot?.episodes.find(e => e.id === id)?.manifest;
  if (!manifest) throw new DownloadError("Processed episode unavailable.", "episode");
  if (manifest.chunk_size !== 1024 ** 2 || manifest.chunks.length !== Math.ceil(manifest.bytes / manifest.chunk_size)) throw new DownloadError("Invalid audio manifest.", "episode");
  const existing = await store.readRecord<Download>("downloads", manifest.hash);
  if (existing?.complete) return;
  await makeRoom(manifest);
  await store.writeRecord("meta", `manifest:${manifest.hash}`, manifest);
  // A resumed download keeps showing the bytes it already holds while stored chunks are re-verified.
  let shown = Math.min(existing?.received ?? 0, manifest.bytes);
  await persistDownload(manifest, id, shown, false);
  changed();
  let received = 0;
  for (let index = 0; index < manifest.chunks.length; index++) {
    if (!downloadEligible(id, await state())) return abandon(manifest, id);
    if (document.visibilityState === "hidden") throw new DownloadError("Download paused. Open Pods to resume.", "device");
    const key = `${manifest.hash}:${index}`;
    const cached = await store.readRecord<ArrayBuffer>("chunks", key);
    if (cached && await verifyChunk(cached, manifest.chunks[index])) {
      received += cached.byteLength;
      if (received > shown) { shown = received; await persistDownload(manifest, id, shown, false); }
      continue;
    }
    const start = index * manifest.chunk_size, end = Math.min(manifest.bytes, start + manifest.chunk_size) - 1;
    const bytes = await fetchChunk(manifest, start, end);
    if (bytes.byteLength !== end - start + 1 || !await verifyChunk(bytes, manifest.chunks[index])) throw new DownloadError("Audio verification failed. Retry the download.", "episode");
    await store.writeRecord("chunks", key, bytes);
    received += bytes.byteLength;
    shown = received;
    await persistDownload(manifest, id, received, false);
  }
  if (!downloadEligible(id, await state())) return abandon(manifest, id);
  await persistDownload(manifest, id, manifest.bytes, true);
  error = null;
}

/** One chunk, retried through dropped connections and stalls while the page stays visible. */
async function fetchChunk(manifest: ArtifactManifest, start: number, end: number): Promise<ArrayBuffer> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await fetchRange(manifest, start, end);
    } catch (caught) {
      if (!(caught instanceof TransientError)) throw caught;
      const delay = chunkRetryDelays[attempt];
      if (delay == null || document.visibilityState === "hidden") throw new DownloadError(caught.message, "device");
      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }
}

async function fetchRange(manifest: ArtifactManifest, start: number, end: number): Promise<ArrayBuffer> {
  const controller = new AbortController();
  let stallTimer = 0;
  let stallReject: (reason: Error) => void = () => {};
  const stalled = new Promise<never>((_, reject) => { stallReject = reject; });
  stalled.catch(() => { /* Only raced against reads. */ });
  const arm = () => {
    window.clearTimeout(stallTimer);
    stallTimer = window.setTimeout(() => { controller.abort(); stallReject(new TransientError(STALLED)); }, chunkStallMs);
  };
  arm();
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  try {
    let response: Response;
    try {
      response = await Promise.race([fetch(`${backendBase()}/api/artifacts/${manifest.hash}`, {
        credentials: "include", headers: { Range: `bytes=${start}-${end}`, "If-Range": `"${manifest.hash}"` }, signal: controller.signal }), stalled]);
    } catch (caught) {
      throw caught instanceof TransientError ? caught : new TransientError(UNREACHABLE);
    }
    if (response.status >= 500) throw new TransientError(MAC_ERROR);
    if (response.status !== 206 || response.headers.get("content-range") !== `bytes ${start}-${end}/${manifest.bytes}`) {
      throw new DownloadError("Mac unavailable or audio changed. Reconnect to resume.", response.status === 401 || response.status === 403 ? "device" : "episode");
    }
    arm();
    const expected = end - start + 1;
    reader = response.body?.getReader();
    if (!reader) return await response.arrayBuffer();
    const buffer = new Uint8Array(expected);
    let offset = 0;
    for (;;) {
      let next: ReadableStreamReadResult<Uint8Array>;
      try {
        next = await Promise.race([reader.read(), stalled]);
      } catch (caught) {
        throw caught instanceof TransientError ? caught : new TransientError(UNREACHABLE);
      }
      if (next.done) break;
      arm();
      if (offset + next.value.byteLength > expected) throw new DownloadError("Audio verification failed. Retry the download.", "episode");
      buffer.set(next.value, offset);
      offset += next.value.byteLength;
    }
    return buffer.buffer.slice(0, offset);
  } finally {
    window.clearTimeout(stallTimer);
    void reader?.cancel().catch(() => {});
  }
}

export async function verifyChunk(bytes: ArrayBuffer, expected: string): Promise<boolean> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map(v => v.toString(16).padStart(2, "0")).join("") === expected;
}

export function prefetch(): Promise<void> {
  if (automaticPass) return automaticPass;
  automaticPass = runPrefetch().finally(() => { automaticPass = null; });
  return automaticPass;
}

async function runPrefetch(): Promise<void> {
  try { await sweepStaleDownloads(); } catch { /* A later bootstrap/sync pass retries. */ }
  if (document.visibilityState === "hidden") return;
  const s = await state();
  const episodes = (s.snapshot ? applyOverlay(s.snapshot, s.outbox).episodes : []).filter(e => e.played_at == null && e.archived_at == null);
  let limited = false;
  const last = Number((s.snapshot ? applyOverlay(s.snapshot, s.outbox).settings.last_listened : 0));
  const queue = episodes.slice().sort((a, b) => Number(b.id === last) - Number(a.id === last)).slice(0, s.preferences.count);
  for (const episode of queue) {
    if (!downloadEligible(episode.id, await state())) continue;
    // Budget against what is actually retained, including manual and partial
    // downloads outside this automatic selection. Partial files reserve their full size.
    const downloads = await store.allDownloads();
    const downloaded = downloads.find(d => d.hash === episode.manifest?.hash);
    const used = downloads.filter(d => d.hash !== episode.manifest?.hash).reduce((n, d) => n + d.bytes, 0);
    const bytes = episode.manifest?.bytes ?? 0;
    if (used + bytes > (await state()).preferences.limit) { limited = true; continue; }
    if (downloaded?.complete) continue;
    try { await downloadEpisode(episode.id); }
    catch (caught) {
      // One broken episode no longer blocks the rest of the queue; a device-wide failure still does.
      if (!(caught instanceof DownloadError) || caught.scope === "device") break;
    }
  }
  const nextNotice = limited ? "Automatic downloads reached the storage limit. Saved episodes are kept. Increase the storage limit in Settings or mark episodes played to make room." : null;
  if (queueNotice !== nextNotice) { queueNotice = nextNotice; changed(); }
}
