import { emitEpisodesChanged } from "../events";
import { LOCAL_OMLX_MODEL } from "../lib";
import type { EpisodeDetail, ProcessingNotification, RefreshStatus, Settings } from "../types";
import { cleanupPlayedDownload, prefetch, sweepStaleDownloads } from "./downloads";
import { allDownloads, readRecord, updateState, type ArtifactManifest, type LocalState, type Operation, type Snapshot } from "./store";

declare global { interface Window { PODS_LOCAL_CLIENT?: boolean } }
export const offlineEnabled = () => window.PODS_LOCAL_CLIENT ?? import.meta.env.PROD;
export const backendBase = () => window.PODS_API_BASE ?? import.meta.env.VITE_API_BASE ?? "https://sync.pods.mcgiv.dev:8443";
let syncing: Promise<void> | null = null;
let lastError: string | null = null;
export const syncError = () => lastError;

export async function state(): Promise<LocalState> {
  const raw = await readRecord<LocalState>("meta", "state");
  if (!raw) return await updateState(() => {});
  if (raw.preferences && "pins" in raw.preferences) return await updateState(() => {});
  return raw;
}
export async function hasLocalLibrary(): Promise<boolean> { return (await state()).snapshot != null; }

const NETWORK_TIMEOUT_MS = 15_000;
const REFRESH_TIMEOUT_MS = 120_000;

export async function network<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body) headers.set("content-type", "application/json");
  const response = await fetch(`${backendBase()}/api${path}`, { ...init, headers, credentials: "include",
    signal: init.signal ?? AbortSignal.timeout(NETWORK_TIMEOUT_MS) });
  if (!response.ok) {
    if (response.status === 401) window.dispatchEvent(new Event("pods-auth-required"));
    throw new Error(response.status === 401 ? "Sign in when the Mac is available to synchronize." : `Mac request failed (${response.status}).`);
  }
  return response.status === 204 ? undefined as T : response.json() as Promise<T>;
}

export function applyOverlay(snapshot: Snapshot, outbox: Operation[]): Snapshot {
  const copy = structuredClone(snapshot);
  for (const operation of outbox) {
    if (operation.entity === "settings") { copy.settings[operation.field] = operation.value; continue; }
    if (operation.entity === "subscription") {
      if (!operation.value) {
        const removed = copy.shows.find(s => s.feed_url === operation.field);
        copy.shows = copy.shows.filter(s => s.feed_url !== operation.field);
        copy.episodes = copy.episodes.filter(e => e.podcast_id !== removed?.id || e.played_at != null);
      }
      continue;
    }
    const episode = copy.episodes.find(e => String(e.id) === operation.entity);
    if (!episode) continue;
    if (operation.field === "played") episode.played_at = operation.value ? 1 : null;
    if (operation.field === "position") {
      const position = operation.value as { seconds: number; original_seconds?: number };
      const timeline = episode.manifest?.timeline;
      if (position.original_seconds != null && timeline?.length) {
        const span = timeline.find(s => position.original_seconds! < s.original_end) ?? timeline[timeline.length - 1];
        episode.position_secs = span.processed_start + Math.max(0, Math.min(span.original_end, position.original_seconds) - span.original_start);
      } else episode.position_secs = position.seconds;
    }
  }
  return copy;
}

export async function enqueue(entity: string, field: string, value: unknown): Promise<void> {
  await updateState(s => {
    s.outbox.push({ id: crypto.randomUUID(), sequence: ++s.sequence, entity, field, value,
      base_revision: s.snapshot?.versions[`${entity}:${field}`] ?? 0 });
  });
  emitEpisodesChanged();
  window.dispatchEvent(new Event("pods-offline-changed"));
  void synchronize().catch(() => {});
}

export function synchronize(): Promise<void> {
  if (syncing) return syncing;
  syncing = synchronizeOnce().finally(() => { syncing = null; window.dispatchEvent(new Event("pods-offline-changed")); });
  return syncing;
}

async function synchronizeOnce(): Promise<void> {
  try {
    // Receive current versions without discarding pending local edits.
    const snapshot = await network<Snapshot>("/sync");
    validateSnapshot(snapshot);
    await updateState(s => { s.snapshot = adoptSnapshot(s.snapshot, snapshot); });
    const initial = await state();
    for (const scheduled of initial.outbox) {
      const current = await state();
      const operation = current.outbox.find(o => o.id === scheduled.id);
      if (!operation) continue;
      if (operation.conflict != null) continue;
      const response = await network<{ results: { id: string; status: string; revision: number }[] }>("/sync/actions", {
        method: "POST", body: JSON.stringify({ client_id: current.client_id, actions: [operation] }) });
      const result = response.results.find(r => r.id === operation.id);
      if (!result) throw new Error("Mac did not acknowledge an operation.");
      await updateState(s => {
        if (result.status === "applied") {
          // Include the acknowledged change in the snapshot before removing its optimistic overlay.
          if (s.snapshot) {
            s.snapshot = applyOverlay(s.snapshot, [operation]);
            s.snapshot.versions[`${operation.entity}:${operation.field}`] = result.revision;
          }
          s.outbox = s.outbox.filter(o => o.id !== operation.id);
          for (const queued of s.outbox) {
            if (queued.entity === operation.entity && queued.field === operation.field && queued.conflict == null) queued.base_revision = result.revision;
          }
        } else {
          const pending = s.outbox.find(o => o.id === operation.id);
          if (pending) pending.conflict = result.revision;
        }
      });
    }
    const latest = await network<Snapshot>("/sync");
    validateSnapshot(latest);
    await updateState(s => { s.snapshot = adoptSnapshot(s.snapshot, latest); s.lastSync = Date.now(); });
    lastError = null;
    emitEpisodesChanged();
    try { await sweepStaleDownloads(); } catch { /* Prefetch and the next sync retry. */ }
  } catch (error) {
    lastError = error instanceof Error ? error.message : "Mac unavailable. Downloaded episodes are still available.";
    throw error;
  }
}

const NOTIFICATION_CATEGORIES = new Set(["audio_download", "speech_to_text", "ad_classification", "show_notes"]);
const NOTIFICATION_OUTCOMES = new Set(["retry", "blocked"]);

function isProcessingNotification(value: unknown): value is ProcessingNotification {
  if (value == null || typeof value !== "object") return false;
  const item = value as Record<string, unknown>;
  return Number.isInteger(item.id) && (item.id as number) > 0
    && Number.isInteger(item.episode_id)
    && typeof item.category === "string" && NOTIFICATION_CATEGORIES.has(item.category)
    && typeof item.failed_stage === "string" && item.failed_stage.length > 0
    && typeof item.message === "string"
    && typeof item.outcome === "string" && NOTIFICATION_OUTCOMES.has(item.outcome)
    && typeof item.created_at === "number" && Number.isFinite(item.created_at)
    && typeof item.episode_title === "string"
    && typeof item.podcast_title === "string";
}

export function validateSnapshot(snapshot: Snapshot): void {
  if (snapshot.version !== 1 || !snapshot.replace || !Array.isArray(snapshot.episodes) || !Array.isArray(snapshot.shows)) throw new Error("Unsupported Mac library format.");
  if (snapshot.episodes.some(e => e.ad_removal_state !== "ad-free" || !e.manifest || !/^[a-f0-9]{64}$/.test(e.manifest.hash)
    || e.audio_url !== `/_media/${e.manifest.hash}.m4a`)) throw new Error("Mac supplied an unpublished episode.");
  if (snapshot.notifications === undefined) return;
  if (!Array.isArray(snapshot.notifications)) throw new Error("Unsupported Mac library format.");
  let previousId = Number.POSITIVE_INFINITY;
  for (const item of snapshot.notifications) {
    if (!isProcessingNotification(item) || item.id >= previousId) throw new Error("Unsupported Mac library format.");
    previousId = item.id;
  }
}

function idleRefreshStatus(): RefreshStatus {
  return { is_refreshing: false, last_success_at: null, last_attempt_at: null, last_source: null, last_refreshed: 0, last_errors: 0 };
}

function cachedRefreshStatus(status: RefreshStatus | undefined): RefreshStatus {
  return status ? { ...status, is_refreshing: false } : idleRefreshStatus();
}

function adoptSnapshot(current: Snapshot | null, incoming: Snapshot): Snapshot {
  const refresh_status = incoming.refresh_status ?? current?.refresh_status;
  return { ...incoming, refresh_status: refresh_status ? { ...refresh_status, is_refreshing: false } : undefined };
}

export async function resolveConflict(id: string, keepPhone: boolean): Promise<void> {
  await updateState(s => {
    const operation = s.outbox.find(o => o.id === id);
    if (!operation) return;
    s.outbox = s.outbox.filter(o => o.id !== id);
    if (keepPhone) s.outbox.push({ ...operation, id: crypto.randomUUID(), sequence: ++s.sequence,
      base_revision: operation.conflict ?? operation.base_revision, conflict: undefined });
  });
  emitEpisodesChanged();
  await synchronize();
}

const defaultSettings: Settings = { speed: 1, autoplay: true };
export async function localRequest<T>(path: string, init: RequestInit = {}, raw = false): Promise<T> {
  const s = await state();
  const snapshot = s.snapshot ? applyOverlay(s.snapshot, s.outbox) : { episodes: [], shows: [], settings: {}, processing: undefined, refresh_status: undefined };
  const downloads = await allDownloads();
  const episodes = snapshot.episodes.map(e => ({ ...e, downloaded: downloads.some(d => d.hash === e.manifest?.hash && d.complete) }));
  const url = new URL(path, "https://pods.invalid");
  const route = url.pathname;
  const method = init.method ?? "GET";
  const body = init.body && typeof init.body === "string" && !raw && !init.body.trim().startsWith("<") ? JSON.parse(init.body) as Record<string, unknown> : {};
  const offset = Number(url.searchParams.get("offset") ?? 0);
  const page = (items: EpisodeDetail[]) => ({ items: items.slice(offset, offset + 50), next_offset: items.length > offset + 50 ? offset + 50 : null });
  let result: unknown;
  const match = route.match(/^\/episodes\/(\d+)(?:\/(.*))?$/);
  if (match) {
    const episode = episodes.find(e => e.id === Number(match[1]));
    if (!episode) throw new Error("Episode is not available in the processed library.");
    if (method === "GET") result = episode;
    else if (match[2] === "played") {
      const markedPlayed = method === "POST";
      await enqueue(String(episode.id), "played", markedPlayed);
      if (markedPlayed) {
        window.dispatchEvent(new CustomEvent("pods-close-episode", { detail: { id: episode.id } }));
        try { await cleanupPlayedDownload(episode.id); } catch { /* Sweep on bootstrap/prefetch/sync. */ }
      } else void prefetch().catch(() => {});
    }
    else if (match[2] === "position") {
      const hash = String(body.artifact_hash ?? episode.manifest?.hash);
      const manifest = hash === episode.manifest?.hash ? episode.manifest : await readRecord<ArtifactManifest>("meta", `manifest:${hash}`);
      const seconds = Number(body.seconds);
      const timeline = manifest?.timeline;
      const span = timeline?.find(s => seconds < s.processed_start + s.original_end - s.original_start) ?? timeline?.at(-1);
      const original_seconds = span ? Math.min(span.original_end, span.original_start + Math.max(0, seconds - span.processed_start)) : undefined;
      await enqueue(String(episode.id), "position", { seconds, artifact_hash: hash, original_seconds });
    }
    else if (match[2] === "show-notes") result = episode.show_notes;
    else throw new Error("This episode is already processed.");
  } else if (route === "/recent") result = page(episodes.filter(e => e.played_at == null && e.archived_at == null && e.downloaded));
  else if (route === "/played") result = page(episodes.filter(e => e.played_at != null).sort((a, b) => (b.played_at ?? 0) - (a.played_at ?? 0)));
  else if (route === "/shows" && method === "GET") result = snapshot.shows;
  else if (route === "/shows" && method === "POST") {
    await enqueue("subscription", String(body.feed_url), true);
    result = { id: 0, title: String(body.feed_url), feed_url: body.feed_url };
  } else if (/^\/shows\/\d+/.test(route)) {
    const show = snapshot.shows.find(s => s.id === Number(route.split("/")[2]));
    if (!show) throw new Error("Show unavailable.");
    if (method === "DELETE") await enqueue("subscription", show.feed_url, false);
    else {
      const query = (url.searchParams.get("q") ?? "").toLowerCase();
      const items = episodes.filter(e => e.podcast_id === show.id && e.title.toLowerCase().includes(query));
      result = route.endsWith("/search") ? page(items) : { show, episodes: page(items) };
    }
  } else if (route === "/next") {
    const after = Number(url.searchParams.get("after"));
    const current = episodes.find(e => e.id === after);
    const list = episodes.filter(e => e.played_at == null && e.archived_at == null && e.downloaded
      && (url.searchParams.get("context") !== "show" || e.podcast_id === current?.podcast_id));
    const source = episodes.findIndex(e => e.id === after);
    result = list.find(e => episodes.indexOf(e) > source) ?? list.find(e => e.id !== after) ?? null;
  } else if (route === "/settings") {
    if (method === "PUT") {
      const previous = { ...defaultSettings, ...snapshot.settings } as Record<string, unknown>;
      for (const field of ["speed", "autoplay"]) if (body[field] != null && body[field] !== previous[field]) await enqueue("settings", field, body[field]);
    }
    else result = { ...defaultSettings, ...snapshot.settings };
  } else if (route === "/refresh") {
    result = await network("/refresh", { method: "POST", signal: init.signal ?? AbortSignal.timeout(REFRESH_TIMEOUT_MS) });
    await synchronize();
  }
  else if (route === "/refresh-status") result = cachedRefreshStatus(snapshot.refresh_status);
  else if (route === "/ad-removal/settings") result = { enabled: true, listen_requires_ready: true, classifier_available: true,
    classifier_unavailable_reason: null, device_available_bytes: 0, minimum_free_bytes: 0,
    cloud_classifier_configured: true, model_repository: LOCAL_OMLX_MODEL, corrections: [],
    failed_count: snapshot.processing?.failed ?? 0, preparing_count: snapshot.processing?.pending ?? 0 };
  else if (route === "/ad-removal/statuses") result = { items: episodes };
  else if (route === "/search") {
    const query = (url.searchParams.get("q") ?? "").toLowerCase();
    let directory: { directory_configured?: boolean; podcasts?: unknown[] } = {};
    try { directory = await network(path); } catch { /* Local search remains usable. */ }
    result = { directory_configured: directory.directory_configured ?? false, podcasts: directory.podcasts ?? [], episodes: episodes.filter(e => e.title.toLowerCase().includes(query)) };
  } else if (route === "/opml" && method === "GET") {
    const escape = (text: string) => text.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" })[c]!);
    result = `<?xml version="1.0"?><opml version="2.0"><body>${snapshot.shows.map(show => `<outline text="${escape(show.title)}" xmlUrl="${escape(show.feed_url)}" type="rss"/>`).join("")}</body></opml>`;
  } else if (route === "/opml" && method === "POST") {
    const xml = new DOMParser().parseFromString(String(init.body), "text/xml");
    const feeds = [...xml.querySelectorAll("outline[xmlUrl]")];
    for (const feed of feeds) await enqueue("subscription", feed.getAttribute("xmlUrl")!, true);
    result = { imported: feeds.length, skipped: 0, failed: 0 };
  } else if (route === "/follows" || route === "/follow-candidates") result = [];
  else throw new Error("This action requires a supported Mac connection.");
  return result as T;
}
