import { emitEpisodesChanged } from "../events";
import { applyThemePreference, currentThemePreference, THEME_PREFERENCE_KEY } from "../theme";
import { LOCAL_OMLX_MODEL } from "../lib";
import type { EpisodeDetail, ProcessingNotification, RefreshStatus, Settings } from "../types";
import { cleanupPlayedDownload, prefetch, sweepStaleDownloads } from "./downloads";
import { currentDownloadProgress } from "./progress";
import { allDownloads, readRecord, updateState, type ArtifactManifest, type Download, type LocalState, type Operation, type Snapshot } from "./store";

declare global { interface Window { PODS_LOCAL_CLIENT?: boolean } }
export const offlineEnabled = () => window.PODS_LOCAL_CLIENT ?? import.meta.env.PROD;
export const backendBase = () => window.PODS_API_BASE ?? import.meta.env.VITE_API_BASE ?? "https://sync.pods.mcgiv.dev:8443";
export const MAC_OFFLINE_MESSAGE = "Mac unavailable. Downloaded episodes still play.";
export const PROBE_TIMEOUT_MS = 3_000;
let syncing: Promise<void> | null = null;
let refreshRequested = false;
let syncAgain = false;
const playbackBases = new Map<string, number>();
export function beginPlaybackSession(id: number, revision?: number): void {
  if (revision != null) playbackBases.set(String(id), revision);
}
export function endPlaybackSession(id: number): void { playbackBases.delete(String(id)); }

let lastError: string | null = null;
export const syncError = () => lastError;

/** True when the Mac answered a cheap probe. Any HTTP status means it is up. */
export async function probeMac(): Promise<boolean> {
  try {
    await fetch(`${backendBase()}/api/auth/status`, {
      credentials: "include",
      signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
    });
    return true;
  } catch {
    return false;
  }
}

function friendlyNetworkError(error: unknown, init: RequestInit): Error {
  if (error instanceof DOMException && error.name === "AbortError" && init.signal?.aborted) return error;
  if (error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError")) {
    return new Error("Mac did not answer in time. Check Tailscale and keep Pods open.");
  }
  const message = error instanceof Error ? error.message : "";
  if (error instanceof TypeError || /Failed to fetch|NetworkError|Load failed|Network request failed/i.test(message)) {
    return new Error(MAC_OFFLINE_MESSAGE);
  }
  return error instanceof Error ? error : new Error(MAC_OFFLINE_MESSAGE);
}

function friendlySyncError(message: string): string {
  if (/Sign in/.test(message)) return message;
  if (/Failed to fetch|NetworkError|Load failed|Network request failed|Mac is off|Mac did not answer|Mac request failed|Mac unavailable/i.test(message)) {
    return MAC_OFFLINE_MESSAGE;
  }
  return message;
}

export async function state(): Promise<LocalState> {
  const raw = await readRecord<LocalState>("meta", "state");
  if (!raw) return await updateState(() => {});
  if ((raw.preferences && "pins" in raw.preferences) || !raw.automaticEpisodesV2) return await updateState(() => {});
  return raw;
}
/** Dismiss only the entries displayed when Clear all was tapped, even if a sync races it. */
export async function clearNotifications(throughId: number): Promise<void> {
  await updateState(s => {
    s.notificationsClearedThrough = Math.max(s.notificationsClearedThrough ?? 0, throughId);
  });
  await enqueue("settings", "notifications_cleared_through", throughId);
}

export async function hasLocalLibrary(): Promise<boolean> { return (await state()).snapshot != null; }

const NETWORK_TIMEOUT_MS = 15_000;
const SYNC_TIMEOUT_MS = 120_000;
const REFRESH_TIMEOUT_MS = 120_000;
const ACTION_BATCH = 100;

export async function network<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body) headers.set("content-type", "application/json");
  const timeoutMs = path === "/sync" || path.startsWith("/sync/") ? SYNC_TIMEOUT_MS : NETWORK_TIMEOUT_MS;
  let response: Response;
  try {
    response = await fetch(`${backendBase()}/api${path}`, { ...init, headers, credentials: "include",
      signal: init.signal ?? AbortSignal.timeout(timeoutMs) });
  } catch (error) {
    throw friendlyNetworkError(error, init);
  }
  if (!response.ok) {
    if (response.status === 401) window.dispatchEvent(new Event("pods-auth-required"));
    let detail = "";
    try {
      const body = await response.json() as { error?: string };
      if (body.error) detail = `: ${body.error}`;
    } catch { /* Status is enough when the Mac omits a body. */ }
    throw new Error(response.status === 401 ? "Sign in when the Mac is available to synchronize." : `Mac request failed (${response.status})${detail}.`);
  }
  return response.status === 204 ? undefined as T : response.json() as Promise<T>;
}

export function applyOverlay(snapshot: Snapshot, outbox: Operation[]): Snapshot {
  const copy = structuredClone(snapshot);
  for (const operation of outbox) {
    if (operation.entity === "settings") {
      copy.settings[operation.field] = operation.field === "notifications_cleared_through"
        ? Math.max(Number(copy.settings[operation.field]) || 0, Number(operation.value) || 0) : operation.value;
      continue;
    }
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

function coalesceOutbox(outbox: Operation[]): Operation[] {
  const last = new Map<string, Operation>();
  for (const operation of outbox) {
    if (operation.conflict != null || operation.sent || operation.error) continue;
    last.set(`${operation.entity}:${operation.field}`, operation);
  }
  return outbox.filter(operation => operation.conflict != null || operation.sent || operation.error || last.get(`${operation.entity}:${operation.field}`) === operation);
}

type SyncAction = { id: string; sequence: number; entity: string; field: string; value: unknown; base_revision: number };
type ActionResult = { id: string; status: string; revision: number; error?: string };

async function postActions(clientId: string, actions: SyncAction[]): Promise<ActionResult[]> {
  if (actions.length === 0) return [];
  try {
    const response = await network<{ results: ActionResult[] }>("/sync/actions", {
      method: "POST", body: JSON.stringify({ client_id: clientId, device_name: (await state()).device_name ?? defaultDeviceName(), actions }) });
    if (!Array.isArray(response.results)) throw new Error("Mac acknowledgement is incomplete. Pending changes are saved.");
    return response.results;
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    if (!/\((400|409|422)\)/.test(message)) throw error;
    if (actions.length === 1) return [{ id: actions[0].id, status: "rejected", revision: 0, error: "The server rejected this change. Export a backup before troubleshooting." }];
    const results: ActionResult[] = [];
    for (const action of actions) results.push(...await postActions(clientId, [action]));
    return results;
  }
}

export async function enqueue(entity: string, field: string, value: unknown): Promise<void> {
  try {
  await updateState(s => {
    s.outbox.push({ id: crypto.randomUUID(), sequence: ++s.sequence, entity, field, value,
      base_revision: (field === "position" ? playbackBases.get(entity) : undefined) ?? s.snapshot?.versions[`${entity}:${field}`] ?? 0 });
  });
  } catch (error) {
    lastError = "Could not save this change on this device. Check browser storage.";
    window.dispatchEvent(new Event("pods-offline-changed"));
    throw error;
  }
  emitEpisodesChanged();
  window.dispatchEvent(new Event("pods-offline-changed"));
  void synchronize(false).catch(() => {});
}

export function defaultDeviceName(): string {
  return /iPad/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
    ? "iPad" : /iPhone/.test(navigator.userAgent) ? "iPhone" : "Browser";
}

export function syncInFlight(): boolean {
  return syncing != null;
}

export function synchronize(refresh = true): Promise<void> {
  refreshRequested ||= refresh;
  syncAgain = true;
  if (syncing) return syncing;
  syncing = (async () => {
    do {
      syncAgain = false;
      const pull = refreshRequested;
      refreshRequested = false;
      await synchronizeOnce(pull);
    } while (syncAgain);
  })().finally(() => { syncing = null; window.dispatchEvent(new Event("pods-offline-changed")); });
  return syncing;
}

/** Bound resume latency while the durable sync continues in the background. */
export async function syncBeforePlayback(): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([synchronize().catch(() => {}), new Promise<void>(resolve => { timer = setTimeout(resolve, 2500); })]);
  } finally { clearTimeout(timer); }
}

async function receiveSnapshot(): Promise<void> {
  const snapshot = await network<Snapshot>("/sync");
  validateSnapshot(snapshot);
  const local = await updateState(s => { s.snapshot = adoptSnapshot(s.snapshot, snapshot); });
  const theme = applyOverlay(snapshot, local.outbox).settings.theme;
  if (theme === "system" || theme === "light" || theme === "dark") applyThemePreference(theme);
  window.dispatchEvent(new Event("pods-shared-settings"));
}

/** Import existing browser-only preferences once, without resetting the library or outbox. */
async function migrateSharedPreferences(): Promise<void> {
  if ((await state()).sharedPreferencesV1) return;
  const theme = window.localStorage.getItem(THEME_PREFERENCE_KEY) ? currentThemePreference() : undefined;
  await updateState(s => {
    if (s.sharedPreferencesV1) return;
    const queue = (field: string, value: unknown) => {
      if (!s.outbox.some(o => o.entity === "settings" && o.field === field)) s.outbox.push({
        id: crypto.randomUUID(), sequence: ++s.sequence, entity: "settings", field, value,
        base_revision: s.snapshot?.versions[`settings:${field}`] ?? 0,
      });
    };
    if (s.snapshot && theme) queue("theme", theme);
    if (s.notificationsClearedThrough) queue("notifications_cleared_through", s.notificationsClearedThrough);
    s.sharedPreferencesV1 = true;
  });
}

async function synchronizeOnce(refresh: boolean): Promise<void> {
  try {
    await migrateSharedPreferences();
    if (!(await probeMac())) throw new Error(MAC_OFFLINE_MESSAGE);
    if (refresh || !(await state()).snapshot) await receiveSnapshot();
    while (true) {
      // A sent operation is immutable: a lost response must retry the same identity.
      const current = await updateState(s => { s.outbox = coalesceOutbox(s.outbox); });
      const blocked = new Set(current.outbox.filter(o => o.conflict != null || o.error).map(o => `${o.entity}:${o.field}`));
      const keys = new Set<string>();
      const chunk = current.outbox.filter(o => {
        const key = `${o.entity}:${o.field}`;
        if (blocked.has(key) || keys.has(key)) return false;
        keys.add(key); return true;
      }).slice(0, ACTION_BATCH);
      if (!chunk.length) break;
      await updateState(s => { for (const op of s.outbox) if (chunk.some(c => c.id === op.id)) op.sent = true; });
      const results = await postActions(current.client_id, chunk.map(({id,sequence,entity,field,value,base_revision}) => ({id,sequence,entity,field,value,base_revision})));
      let missing = false;
      for (const operation of chunk) {
        const result = results.find(r => r.id === operation.id);
        if (!result) { missing = true; continue; }
        await updateState(s => {
          if (result.status === "applied") {
            if (s.snapshot && (s.snapshot.versions[`${operation.entity}:${operation.field}`] ?? 0) <= result.revision) {
              s.snapshot = applyOverlay(s.snapshot, [operation]);
              s.snapshot.versions[`${operation.entity}:${operation.field}`] = result.revision;
            }
            s.outbox = s.outbox.filter(o => o.id !== operation.id);
            for (const queued of s.outbox) {
              if (queued.entity === operation.entity && queued.field === operation.field && !queued.sent && queued.conflict == null && queued.base_revision === operation.base_revision) queued.base_revision = result.revision;
            }
            if (operation.field === "position" && playbackBases.get(operation.entity) === operation.base_revision) playbackBases.set(operation.entity, result.revision);
          } else {
            const pending = s.outbox.find(o => o.id === operation.id);
            if (pending && result.status === "conflict") pending.conflict = result.revision;
            else if (pending) pending.error = result.error ?? "Change not acknowledged by the Mac.";
          }
        });
      }
      if (missing) throw new Error("Mac did not acknowledge every change. Pending changes are saved and will retry.");
    }
    if (refresh) await receiveSnapshot();
    await updateState(s => { s.lastSync = Date.now(); });
    lastError = null;
    emitEpisodesChanged();
    try { await sweepStaleDownloads(); } catch { /* Next sync retries cleanup. */ }
  } catch (error) {
    lastError = error instanceof Error ? friendlySyncError(error.message) : MAC_OFFLINE_MESSAGE;
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
  if (snapshot.episodes.some(e => {
    const extension = e.manifest?.media === "video" ? "mp4" : "m4a";
    return e.ad_removal_state !== "ad-free" || !e.manifest || !/^[a-f0-9]{64}$/.test(e.manifest.hash)
      || e.audio_url !== `/_media/${e.manifest.hash}.${extension}`;
  })) throw new Error("Mac supplied an unpublished episode.");
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
    const sameField = s.outbox.filter(o => o.entity === operation.entity && o.field === operation.field);
    const latest = sameField.at(-1) ?? operation;
    s.outbox = s.outbox.filter(o => o.entity !== operation.entity || o.field !== operation.field);
    playbackBases.delete(operation.entity);
    if (keepPhone) s.outbox.push({ ...latest, sent: false, error: undefined, id: crypto.randomUUID(), sequence: ++s.sequence,
      base_revision: operation.conflict ?? operation.base_revision, conflict: undefined });
  });
  emitEpisodesChanged();
  await synchronize();
}

const defaultSettings: Settings = { speed: 1, autoplay: true };

function withClientDownload<T extends EpisodeDetail>(episode: T, downloads: Download[]): T & {
  downloaded: boolean;
  download_received?: number;
  download_total?: number;
} {
  const download = episode.manifest ? downloads.find(d => d.hash === episode.manifest!.hash) : undefined;
  const live = currentDownloadProgress();
  const liveMatch = live != null && live.episode === episode.id;
  const complete = download?.complete === true;
  const inProgress = !complete && ((download != null && !download.complete) || liveMatch);
  return {
    ...episode,
    downloaded: complete,
    ...(inProgress
      ? {
          download_received: liveMatch && live ? live.received : (download?.received ?? 0),
          download_total: liveMatch && live ? live.total : (download?.bytes ?? episode.manifest?.bytes ?? 0),
        }
      : {}),
  };
}

export async function localRequest<T>(path: string, init: RequestInit = {}, raw = false): Promise<T> {
  const s = await state();
  const snapshot = s.snapshot ? applyOverlay(s.snapshot, s.outbox) : { episodes: [], shows: [], settings: {}, processing: undefined, refresh_status: undefined };
  const downloads = await allDownloads();
  const episodes = snapshot.episodes.map(e => withClientDownload({ ...e, position_revision: s.outbox.find(o => o.entity === String(e.id) && o.field === "position")?.base_revision ?? s.snapshot?.versions[`${e.id}:position`] ?? 0 }, downloads));
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
  } else if (route === "/recent") result = page(episodes.filter(e => e.played_at == null && e.archived_at == null && (e.downloaded || e.download_total != null)));
  else if (route === "/played") result = page(episodes.filter(e => e.played_at != null).sort((a, b) => (b.played_at ?? 0) - (a.played_at ?? 0)));
  else if (route === "/shows" && method === "GET") result = snapshot.shows;
  else if (route === "/youtube/videos" && method === "POST") {
    const url = String(body.url ?? "");
    await enqueue("listen", url, true);
    result = { id: 0, podcast_id: 0, podcast_title: "YouTube", podcast_image: "", title: url, audio_url: url, duration_secs: null, published_at: 0, image_url: "", position_secs: 0, played_at: null, ad_removal_state: "preparing", ad_removal_action: null, ad_removal_stage: "queued", ad_removal_blocking_reason: null };
  } else if (route === "/shows" && method === "POST") {
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
    if (!(await probeMac())) throw new Error(MAC_OFFLINE_MESSAGE);
    result = await network("/refresh", { method: "POST", signal: init.signal ?? AbortSignal.timeout(REFRESH_TIMEOUT_MS) });
    // Await the sync so the snapshot advances, but its conflicts surface via the conflict UI, not as the refresh result.
    try { await synchronize(); } catch { /* refresh outcome already returned */ }
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
    if (await probeMac()) {
      try { directory = await network(path); } catch { /* Local search remains usable. */ }
    }
    result = { directory_configured: directory.directory_configured ?? false, podcasts: directory.podcasts ?? [], episodes: episodes.filter(e => e.title.toLowerCase().includes(query)) };
  } else if (route === "/opml" && method === "GET") {
    const escape = (text: string) => text.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" })[c]!);
    result = `<?xml version="1.0"?><opml version="2.0"><body>${snapshot.shows.filter(show => !/youtube\.com|youtu\.be/i.test(show.feed_url)).map(show => `<outline text="${escape(show.title)}" xmlUrl="${escape(show.feed_url)}" type="rss"/>`).join("")}</body></opml>`;
  } else if (route === "/opml" && method === "POST") {
    const xml = new DOMParser().parseFromString(String(init.body), "text/xml");
    const feeds = [...xml.querySelectorAll("outline[xmlUrl]")];
    for (const feed of feeds) await enqueue("subscription", feed.getAttribute("xmlUrl")!, true);
    result = { imported: feeds.length, skipped: 0, failed: 0 };
  } else if (route === "/follows" || route === "/follow-candidates") result = [];
  else throw new Error("Connect this device and your Mac to Tailscale to use this feature.");
  return result as T;
}
