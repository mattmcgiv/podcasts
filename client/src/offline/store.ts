import type { EpisodeDetail, FeedbackStatus, ProcessingNotification, Show, RefreshStatus } from "../types";

export interface ArtifactManifest {
  version: number; episode_id: number; hash: string; source_hash: string; bytes: number;
  duration: number; chunk_size: number; chunks: string[];
  timeline: { original_start: number; original_end: number; processed_start: number }[];
  /** Present for YouTube publications. Absent publications are audio. */
  media?: "video" | "audio" | "";
  width?: number;
  height?: number;
}
export interface PipelineItem {
  id: string; episodeId: number; title: string; podcastTitle: string;
  stage: string; state: string; statusLabel: string; message: string | null;
  attempts: number; nextRetryAt: number | null; updatedAt: number; canRetry: boolean;
  completedUnits?: number | null; totalUnits?: number | null; stalled?: boolean;
}
export interface PipelineStatus {
  observedAt: number; items: PipelineItem[]; workerError?: string | null;
  recent: { id: string; episodeId: number; title: string; published: boolean }[];
}
export interface Snapshot {
  version: number; cursor: number; replace: boolean; episodes: EpisodeDetail[]; shows: Show[];
  settings: Record<string, unknown>; versions: Record<string, number>;
  writers?: Record<string, { device: string; updated_at: number }>;
  refresh_status?: RefreshStatus;
  processing?: { pending: number; failed?: number; blocked?: number; storage: { used: number; limit: number; free: number; blocked: boolean } };
  pipeline?: PipelineStatus;
  notifications?: ProcessingNotification[];
  feedback?: FeedbackStatus[];
}
export interface Operation {
  id: string; sequence: number; entity: string; field: string; value: unknown;
  changed_at?: number;
  base_revision: number; conflict?: number; sent?: boolean; error?: string;
}
export interface Preferences { limit: number; count: number }
export interface LocalState {
  lastChangeAt?: number;
  device_name?: string; client_id: string; sequence: number; snapshot: Snapshot | null; outbox: Operation[];
  preferences: Preferences; lastSync: number | null;
  notificationsClearedThrough?: number;
  /** Set after the automatic-episode default is raised from 10 to 50. */
  automaticEpisodesV2?: boolean;
  sharedPreferencesV1?: boolean;
}
export interface Download {
  hash: string;
  episode: number;
  bytes: number;
  /** Bytes verified so far. Absent on records written before progress tracking. */
  received?: number;
  complete: boolean;
  touched: number;
}
export const DATABASE = "pods-offline-v1";

export function snapshotNotifications(snapshot: Snapshot | null | undefined): ProcessingNotification[] {
  return snapshot?.notifications ?? [];
}

export function visibleNotifications(state: LocalState): ProcessingNotification[] {
  return snapshotNotifications(state.snapshot).filter(item => item.id > (Math.max(state.notificationsClearedThrough ?? 0, Number(state.snapshot?.settings.notifications_cleared_through ?? 0), ...state.outbox.filter(o => o.entity === "settings" && o.field === "notifications_cleared_through").map(o => Number(o.value)))));
}

// Preserve all stores/data, but fence old open tabs that still run the eviction
// code. Their explicit version-2 opens fail instead of deleting saved episodes.
const DATABASE_VERSION = 3;

export function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, DATABASE_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      for (const name of ["meta", "chunks", "downloads", "voice"]) {
        if (!db.objectStoreNames.contains(name)) db.createObjectStore(name);
      }
    };
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      request.result.onversionchange = () => request.result.close();
      resolve(request.result);
    };
  });
}

export function emptyState(): LocalState {
  return { client_id: crypto.randomUUID(), sequence: 0, snapshot: null, outbox: [],
    preferences: { limit: 2 * 1024 ** 3, count: 50 }, lastSync: null, automaticEpisodesV2: true, sharedPreferencesV1: true };
}

/** Drop obsolete fields such as `pins` without touching library data. */
export function normalizeState(raw: LocalState | undefined | null): LocalState {
  const state = raw ?? emptyState();
  const preferences = state.preferences ?? emptyState().preferences;
  state.preferences = { limit: preferences.limit, count: preferences.count };
  if (!state.automaticEpisodesV2) {
    if (state.preferences.count === 10) state.preferences.count = 50;
    state.automaticEpisodesV2 = true;
  }
  return state;
}

export async function readRecord<T>(store: string, key: IDBValidKey): Promise<T | undefined> {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, "readonly");
    const request = tx.objectStore(store).get(key);
    tx.oncomplete = () => { db.close(); resolve(request.result as T | undefined); };
    tx.onabort = tx.onerror = () => { db.close(); reject(tx.error); };
  });
}

export async function writeRecord(store: string, key: IDBValidKey, value: unknown): Promise<void> {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, "readwrite");
    tx.objectStore(store).put(value, key);
    tx.oncomplete = () => { db.close(); resolve(); };
    tx.onabort = tx.onerror = () => { db.close(); reject(tx.error); };
  });
}

/** All metadata mutations share one transaction, including outbox acknowledgments. */
export async function updateState(change: (state: LocalState) => void): Promise<LocalState> {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const tx = db.transaction("meta", "readwrite");
    const request = tx.objectStore("meta").get("state");
    let state: LocalState;
    request.onsuccess = () => {
      state = normalizeState(request.result);
      try { change(state); tx.objectStore("meta").put(state, "state"); }
      catch (error) { tx.abort(); reject(error); }
    };
    tx.oncomplete = () => { db.close(); resolve(state); };
    tx.onabort = tx.onerror = () => { db.close(); reject(tx.error ?? new Error("Storage operation aborted")); };
  });
}

export async function allDownloads(): Promise<Download[]> {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const tx = db.transaction("downloads");
    const request = tx.objectStore("downloads").getAll();
    tx.oncomplete = () => { db.close(); resolve(request.result); };
    tx.onabort = tx.onerror = () => { db.close(); reject(tx.error); };
  });
}

export async function deleteDownload(hash: string, eligible?: (state: LocalState, download: Download | undefined) => boolean): Promise<boolean> {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(["downloads", "chunks", "meta"], "readwrite");
    let removed = false;
    const remove = () => {
      tx.objectStore("downloads").delete(hash);
      tx.objectStore("chunks").delete(IDBKeyRange.bound(`${hash}:`, `${hash}:\uffff`));
      tx.objectStore("meta").delete(`manifest:${hash}`);
      removed = true;
    };
    if (eligible) {
      // Eligibility and deletion must see the same state, even when another tab
      // unmarks an episode while a sweep is waiting for IndexedDB.
      const state = tx.objectStore("meta").get("state");
      const download = tx.objectStore("downloads").get(hash);
      download.onsuccess = () => { if (eligible(normalizeState(state.result), download.result)) remove(); };
    } else remove();
    tx.oncomplete = () => { db.close(); resolve(removed); };
    tx.onabort = tx.onerror = () => { db.close(); reject(tx.error); };
  });
}
