import type { EpisodeDetail, ProcessingNotification, Show, RefreshStatus } from "../types";

export interface ArtifactManifest {
  version: number; episode_id: number; hash: string; source_hash: string; bytes: number;
  duration: number; chunk_size: number; chunks: string[];
  timeline: { original_start: number; original_end: number; processed_start: number }[];
}
export interface Snapshot {
  version: number; cursor: number; replace: boolean; episodes: EpisodeDetail[]; shows: Show[];
  settings: Record<string, unknown>; versions: Record<string, number>;
  refresh_status?: RefreshStatus;
  processing?: { pending: number; failed?: number; blocked?: number; storage: { used: number; limit: number; free: number; blocked: boolean } };
  notifications?: ProcessingNotification[];
}
export interface Operation {
  id: string; sequence: number; entity: string; field: string; value: unknown;
  base_revision: number; conflict?: number;
}
export interface Preferences { limit: number; count: number }
export interface LocalState {
  client_id: string; sequence: number; snapshot: Snapshot | null; outbox: Operation[];
  preferences: Preferences; lastSync: number | null;
  notificationsClearedThrough?: number;
}
export interface Download { hash: string; episode: number; bytes: number; complete: boolean; touched: number }
export const DATABASE = "pods-offline-v1";

export function snapshotNotifications(snapshot: Snapshot | null | undefined): ProcessingNotification[] {
  return snapshot?.notifications ?? [];
}

export function visibleNotifications(state: LocalState): ProcessingNotification[] {
  return snapshotNotifications(state.snapshot).filter(item => item.id > (state.notificationsClearedThrough ?? 0));
}

export function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () => {
      for (const name of ["meta", "chunks", "downloads"]) request.result.createObjectStore(name);
    };
    request.onerror = () => reject(request.error);
    request.onsuccess = () => resolve(request.result);
  });
}

export function emptyState(): LocalState {
  return { client_id: crypto.randomUUID(), sequence: 0, snapshot: null, outbox: [],
    preferences: { limit: 2 * 1024 ** 3, count: 10 }, lastSync: null };
}

/** Drop obsolete fields such as `pins` without touching library data. */
export function normalizeState(raw: LocalState | undefined | null): LocalState {
  const state = raw ?? emptyState();
  const preferences = state.preferences ?? emptyState().preferences;
  state.preferences = { limit: preferences.limit, count: preferences.count };
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

export async function deleteDownload(hash: string): Promise<void> {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(["downloads", "chunks", "meta"], "readwrite");
    tx.objectStore("downloads").delete(hash);
    tx.objectStore("chunks").delete(IDBKeyRange.bound(`${hash}:`, `${hash}:\uffff`));
    tx.objectStore("meta").delete(`manifest:${hash}`);
    tx.oncomplete = () => { db.close(); resolve(); };
    tx.onabort = tx.onerror = () => { db.close(); reject(tx.error); };
  });
}
