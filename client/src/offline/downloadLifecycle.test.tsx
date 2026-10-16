import { act, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { IDBFactory, IDBKeyRange } from "fake-indexeddb";
import { webcrypto } from "node:crypto";
import { RecentView } from "../views/RecentView";
import { allDownloads, readRecord, updateState, type Snapshot } from "./store";
import * as store from "./store";
import { localRequest, state, synchronize, validateSnapshot } from "./client";
import { configureDownloadRetriesForTests, downloadEpisode, prefetch, sweepStaleDownloads, DOWNLOAD_QUEUE_EVENT, listenForDownloadChanges, protectPlayingArtifact } from "./downloads";
import { localMedia } from "./media";
import { bootstrapOffline } from "./bootstrap";
import { savePreferences } from "./downloads";

vi.mock("../player", () => ({ usePlayer: () => ({ current: null, position: 0, duration: 0, playEpisode: vi.fn() }) }));

let library: Snapshot;
let stop: (() => void) | undefined;
const files = new Map<string, Uint8Array>();
beforeEach(async () => {
  vi.stubGlobal("indexedDB", new IDBFactory());
  vi.stubGlobal("IDBKeyRange", IDBKeyRange);
  vi.stubGlobal("crypto", webcrypto);
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  window.PODS_LOCAL_CLIENT = true;
  configureDownloadRetriesForTests([], 1000);
  files.clear();
  library = { version: 1, cursor: 0, replace: true, episodes: [], shows: [], settings: {}, versions: {} };
  for (const id of [1, 2, 3]) {
    const bytes = new Uint8Array(8).fill(id);
    const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map(b => b.toString(16).padStart(2, "0")).join("");
    files.set(hash, bytes);
    library.episodes.push({ id, podcast_id: 1, title: `Episode ${id}`, podcast_title: "Regression fixture", podcast_image: "", image_url: "", published_at: id,
      played_at: null, archived_at: null, position_secs: 0, duration_secs: 10, notes_html: "", show_notes: [], ad_markers: [],
      ad_removal_state: "ad-free", ad_removal_stage: "ready", ad_removal_action: null, ad_removal_blocking_reason: null,
      audio_url: `/_media/${hash}.m4a`, manifest: { version: 1, episode_id: id, hash, source_hash: hash, bytes: 8, chunk_size: 1024 ** 2, chunks: [hash], duration: 10, timeline: [] } });
  }
  await updateState(s => { s.snapshot = library; s.preferences = { limit: 24, count: 3 }; });
  vi.stubGlobal("fetch", vi.fn(async (url: string, init?: RequestInit) => {
    if (url.endsWith("/api/auth/status")) return Response.json({ session: true });
    if (url.endsWith("/api/sync")) return Response.json(library);
    if (url.endsWith("/api/sync/actions")) {
      const { actions } = JSON.parse(String(init?.body));
      for (const op of actions) {
        const ep = library.episodes.find(e => String(e.id) === op.entity);
        if (ep && op.field === "played") ep.played_at = op.value ? 1 : null;
      }
      return Response.json({ results: actions.map((op: { id: string }) => ({ id: op.id, status: "applied", revision: 1 })) });
    }
    const bytes = files.get(url.split("/").at(-1)!);
    if (!bytes) throw new Error(`Unexpected request ${url}`);
    return new Response(bytes.slice().buffer, { status: 206, headers: { "Content-Range": "bytes 0-7/8" } });
  }));
});
afterEach(async () => {
  stop?.(); stop = undefined;
  await prefetch();
  await synchronize().catch(() => {});
  delete window.PODS_LOCAL_CLIENT;
});

it("automatically refills after marking played and changing limits without a focus event or Sync tap", async () => {
  await updateState(s => { s.preferences = { limit: 8, count: 1 }; });
  vi.stubGlobal("navigator", { serviceWorker: { register: async () => ({}), ready: Promise.resolve({}) }, storage: { persist: async () => true } });
  stop = await bootstrapOffline();
  await waitFor(async () => { await expectSaved(1); });
  await localRequest("/episodes/1/played", { method: "POST" });
  await waitFor(async () => { await expectSaved(2); });
  expect(await readRecord("downloads", library.episodes[0].manifest!.hash)).toBeUndefined();
  await savePreferences({ limit: 100 * 1024 ** 2, count: 2 });
  await waitFor(async () => { await expectSaved(3); });
  await expectSaved(2);
});

it("replans when publications arrive while an automatic transfer is running", async () => {
  const third = library.episodes.pop()!;
  await updateState(s => { s.snapshot = library; });
  const original = vi.mocked(fetch).getMockImplementation()!;
  let release: () => void = () => {};
  const blocked = new Promise<void>(resolve => { release = resolve; });
  let started = false;
  vi.mocked(fetch).mockImplementation(async (...args) => {
    if (String(args[0]).endsWith(library.episodes[0].manifest!.hash)) { started = true; await blocked; }
    return original(...args);
  });
  const running = prefetch();
  await waitFor(() => expect(started).toBe(true));
  library.episodes.push(third);
  await synchronize();
  const overlapping = prefetch();
  release();
  await Promise.all([running, overlapping]);
  for (const id of [1, 2, 3]) await expectSaved(id);
});

it("shares the browser transfer lock across independent tab modules and rechecks the storage budget", async () => {
  await updateState(s => { s.preferences = { limit: 8, count: 1 }; });
  let lockTail = Promise.resolve();
  const request = vi.fn((_name: string, work: () => Promise<void>) => {
    const task = lockTail.then(work, work);
    lockTail = task.catch(() => {});
    return task;
  });
  vi.stubGlobal("navigator", { locks: { request } });
  vi.resetModules();
  const otherTab = await import("./downloads");
  const results = await Promise.allSettled([downloadEpisode(1), otherTab.downloadEpisode(2)]);
  expect(results.map(r => r.status)).toEqual(["fulfilled", "rejected"]);
  expect(request.mock.calls.map(([name]) => name)).toEqual(["pods-download", "pods-download"]);
  await expectSaved(1);
  expect(await readRecord("downloads", library.episodes[1].manifest!.hash)).toBeUndefined();
});

it("refreshes the list and automatic plan when another tab completes or removes a download", async () => {
  const stopListening = listenForDownloadChanges();
  const otherTab = new BroadcastChannel("pods-downloads");
  const refresh = vi.fn(), replan = vi.fn();
  window.addEventListener("pods-offline-changed", refresh);
  window.addEventListener(DOWNLOAD_QUEUE_EVENT, replan);
  try {
    otherTab.postMessage("changed");
    await waitFor(() => { expect(refresh).toHaveBeenCalledOnce(); expect(replan).toHaveBeenCalledOnce(); });
  } finally {
    otherTab.close(); stopListening();
    window.removeEventListener("pods-offline-changed", refresh);
    window.removeEventListener(DOWNLOAD_QUEUE_EVENT, replan);
  }
});

it("does not reclaim audio playing in another tab and releases it after playback closes", async () => {
  await downloadEpisode(1);
  const held = new Map<string, number>();
  vi.stubGlobal("navigator", { locks: { request: async (name: string, options: LockOptions, callback: LockGrantedCallback<unknown>) => {
    if (options.ifAvailable && held.get(name)) return callback(null);
    held.set(name, (held.get(name) ?? 0) + 1);
    await Promise.resolve();
    try { return await callback({ name, mode: options.mode ?? "exclusive" } as Lock); }
    finally { held.set(name, held.get(name)! - 1); }
  } } });
  // Rapid A -> B -> A changes may precede the lock callbacks.
  protectPlayingArtifact(library.episodes[0].manifest!.hash);
  protectPlayingArtifact(library.episodes[1].manifest!.hash);
  protectPlayingArtifact(library.episodes[0].manifest!.hash);
  vi.resetModules();
  const otherTab = await import("./downloads");
  try {
    await updateState(s => { s.snapshot!.episodes[0].played_at = 1; s.preferences.count = 0; });
    await otherTab.sweepStaleDownloads();
    await expectSaved(1);
  } finally { protectPlayingArtifact(null); }
  await otherTab.sweepStaleDownloads();
  expect(await readRecord("downloads", library.episodes[0].manifest!.hash)).toBeUndefined();
});

async function expectSaved(id: number) {
  const episode = library.episodes.find(e => e.id === id)!;
  expect(await localRequest(`/episodes/${id}`)).toMatchObject({ id, downloaded: true });
  const response = await localMedia(new Request(`https://pods.mcgiv.dev${episode.audio_url}`));
  expect(response.status).toBe(200);
  expect(new Uint8Array(await response.arrayBuffer())).toEqual(files.get(episode.manifest!.hash));
}

it("keeps the row above downloaded through the next two completions, sync and repeated automatic passes", async () => {
  await downloadEpisode(1);
  render(<RecentView />);
  await screen.findByRole("button", { name: /Episode 1/ });
  for (const id of [2, 3]) {
    await act(async () => { await downloadEpisode(id); await synchronize(); await prefetch(); });
    for (let saved = 1; saved <= id; saved++) {
      await expectSaved(saved);
      const row = screen.getByText(`Episode ${saved}`).closest("li")!;
      await waitFor(() => expect(within(row).queryByText("Not downloaded")).toBeNull());
      expect(within(row).getByRole("button", { name: new RegExp(`Episode ${saved}`) })).toBeEnabled();
    }
  }
  expect((await allDownloads()).filter(d => d.complete)).toHaveLength(3);
});

it("does not let delayed played cleanup delete an episode that is unplayed again", async () => {
  await downloadEpisode(1);
  await updateState(s => { s.snapshot!.episodes[0].played_at = 1; });
  const original = store.allDownloads;
  let release: () => void = () => {};
  const blocked = new Promise<void>(resolve => { release = resolve; });
  let selected = false;
  vi.spyOn(store, "allDownloads").mockImplementationOnce(async () => {
    const records = await original(); selected = true; await blocked; return records;
  });
  const sweep = sweepStaleDownloads();
  await waitFor(() => expect(selected).toBe(true));
  // The sweep chose episode 1 before the newer unplayed change and the next
  // episode's completion. It must recheck before deleting any bytes.
  await updateState(s => { s.snapshot!.episodes[0].played_at = null; });
  await downloadEpisode(2);
  release(); await sweep;
  await expectSaved(1);
  await expectSaved(2);
});

it("fills the automatic count with later fitting episodes when the oldest is too large", async () => {
  await updateState(s => { s.preferences = { limit: 16, count: 2 }; s.snapshot!.episodes[0].manifest!.bytes = 25; });
  await prefetch();
  await expectSaved(2);
  await expectSaved(3);
  expect(await readRecord("downloads", library.episodes[0].manifest!.hash)).toBeUndefined();
});

it("shows waiting automatic episodes without asking the user to press Download", async () => {
  render(<RecentView />);
  await screen.findByText("Episode 1");
  expect(screen.getAllByText("Waiting to download")).toHaveLength(3);
  expect(screen.queryByRole("button", { name: "Download" })).toBeNull();
  await act(async () => { await prefetch(); });
  await waitFor(() => expect(screen.queryByText("Waiting to download")).toBeNull());
  for (const id of [1, 2, 3]) await expectSaved(id);
  expect((await state()).outbox).toEqual([]);
});

it("rejects a mismatched or duplicate episode identity before replacing downloaded library data", async () => {
  await downloadEpisode(1);
  const invalid = structuredClone(library);
  invalid.episodes[1].manifest!.episode_id = 1;
  expect(() => validateSnapshot(invalid)).toThrow();
  invalid.episodes = [library.episodes[0], library.episodes[0]];
  expect(() => validateSnapshot(invalid)).toThrow();
  vi.mocked(fetch).mockImplementation(async url => String(url).endsWith("/api/sync") ? Response.json(invalid) : Response.json({ session: true }));
  await expect(synchronize()).rejects.toThrow();
  await expectSaved(1);
  // afterEach only drains existing work; do not start unsupported artifact requests.
  await updateState(s => { s.preferences.count = 0; });
});

it("upgrades existing downloads without data loss and prevents an older tab from evicting them", async () => {
  await downloadEpisode(1);
  const episode = library.episodes[0], hash = episode.manifest!.hash;
  const savedState = await state(), download = (await allDownloads())[0];
  vi.stubGlobal("indexedDB", new IDBFactory());
  const old = await new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open(store.DATABASE, 2);
    request.onupgradeneeded = () => { for (const name of ["meta", "downloads", "chunks", "voice"]) request.result.createObjectStore(name); };
    request.onerror = () => reject(request.error);
    request.onsuccess = () => resolve(request.result);
  });
  await new Promise<void>((resolve, reject) => {
    const tx = old.transaction(["meta", "downloads", "chunks"], "readwrite");
    tx.objectStore("meta").put(savedState, "state");
    tx.objectStore("meta").put(episode.manifest, `manifest:${hash}`);
    tx.objectStore("downloads").put(download, hash);
    tx.objectStore("chunks").put(files.get(hash)!.slice().buffer, `${hash}:0`);
    tx.oncomplete = () => resolve(); tx.onerror = () => reject(tx.error);
  });
  old.close();
  await expectSaved(1); // Opens the new version using the original data.
  const staleWriter = new Promise((resolve, reject) => {
    const request = indexedDB.open(store.DATABASE, 2);
    request.onsuccess = () => { request.result.close(); resolve(undefined); };
    request.onerror = () => reject(request.error);
  });
  await expect(staleWriter).rejects.toMatchObject({ name: "VersionError" });
  await downloadEpisode(2);
  await expectSaved(1); await expectSaved(2);
});
