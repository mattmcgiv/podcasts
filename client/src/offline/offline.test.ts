import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import { IDBFactory, IDBKeyRange } from "fake-indexeddb";
import { webcrypto } from "node:crypto";
import { allDownloads, deleteDownload, emptyState, readRecord, updateState, writeRecord, type ArtifactManifest, type LocalState, type Snapshot } from "./store";
import * as store from "./store";
import { LOCAL_OMLX_MODEL } from "../lib";
import { clearNotifications, applyOverlay, enqueue, hasLocalLibrary, localRequest, network, offlineEnabled, resolveConflict, state, synchronize, validateSnapshot } from "./client";
import { cleanupPlayedDownload, downloadEpisode, downloadError, prefetch, protectPlayingArtifact, savePreferences, sweepStaleDownloads, verifyChunk } from "./downloads";
import { byteRange, localMedia } from "./media";
import type { EpisodeDetail } from "../types";

const hash = "a".repeat(64);
const manifest: ArtifactManifest = { version: 1, episode_id: 1, hash, source_hash: "source", bytes: 8, duration: 10,
  chunk_size: 1024 ** 2, chunks: [hash], timeline: [{ original_start: 0, original_end: 10, processed_start: 0 }] };
function snapshot(): Snapshot {
  return { version: 1, cursor: 0, replace: true, settings: { speed: 1, autoplay: true }, versions: {},
    shows: [{ id: 1, feed_url: "https://example.org/feed", title: "Example", description: "", image_url: "", site_url: "", episode_count: 2, unplayed_count: 2 }],
    episodes: [1, 2].map(id => ({ id, podcast_id: 1, podcast_title: "Example", title: `Episode ${id}`, podcast_image: "", image_url: "", published_at: id,
      duration_secs: 10, position_secs: 0, played_at: null, archived_at: null, notes_html: "", show_notes: [{ id: "s0", title: "Opening", summary: "Introduction", start_time: 0 }],
      ad_markers: [], audio_url: `/_media/${id === 1 ? hash : "b".repeat(64)}.m4a`, ad_removal_state: "ad-free", ad_removal_stage: "ready", ad_removal_action: null, ad_removal_blocking_reason: null,
      manifest: { ...manifest, episode_id: id, hash: id === 1 ? hash : "b".repeat(64) } })) };
}
async function seed() { await updateState(s => { s.snapshot = snapshot(); }); }
beforeEach(() => {
  vi.stubGlobal("indexedDB", new IDBFactory()); vi.stubGlobal("IDBKeyRange", IDBKeyRange);
  vi.stubGlobal("crypto", webcrypto);
  vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("Mac unavailable")));
  window.PODS_LOCAL_CLIENT = true;
  window.PODS_API_BASE = "https://sync.pods.mcgiv.dev:8443";
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  protectPlayingArtifact(null);
});
afterEach(async () => {
  await synchronize().catch(() => {});
  delete window.PODS_LOCAL_CLIENT; delete window.PODS_API_BASE;
  vi.unstubAllGlobals();
});

describe("durable local library", () => {
  const savedStatus = { is_refreshing: true, last_success_at: 123, last_attempt_at: 123, last_source: "manual" as const, last_refreshed: 32, last_errors: 0 };
  it("keeps cached refresh history offline and hides stale is_refreshing", async () => {
    await seed();
    await updateState(s => { s.snapshot!.refresh_status = savedStatus; });
    expect(await localRequest("/refresh-status")).toEqual({ ...savedStatus, is_refreshing: false });
    expect(vi.mocked(fetch)).not.toHaveBeenCalled();
  });
  it("returns idle refresh status for old snapshots that omit history", async () => {
    await seed();
    expect(await localRequest("/refresh-status")).toEqual({
      is_refreshing: false, last_success_at: null, last_attempt_at: null, last_source: null, last_refreshed: 0, last_errors: 0,
    });
    expect(vi.mocked(fetch)).not.toHaveBeenCalled();
  });
  it("preserves the long-running caller signal and does not substitute a timeout", async () => {
    await seed();
    const timeout = vi.spyOn(AbortSignal, "timeout");
    const controller = new AbortController();
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (String(url).endsWith("/refresh")) {
        expect(init?.signal).toBe(controller.signal);
        return new Response(JSON.stringify({ refreshed: 32, errors: 0 }));
      }
      return new Response(JSON.stringify({
        ...snapshot(),
        refresh_status: { is_refreshing: true, last_success_at: 456, last_attempt_at: 456, last_source: "manual", last_refreshed: 32, last_errors: 0 },
      }));
    });
    expect(await localRequest("/refresh", { method: "POST", signal: controller.signal })).toEqual({ refreshed: 32, errors: 0 });
    expect(timeout).toHaveBeenCalledWith(120_000);
    expect(await localRequest("/refresh-status")).toEqual({
      is_refreshing: false, last_success_at: 456, last_attempt_at: 456, last_source: "manual", last_refreshed: 32, last_errors: 0,
    });
  });
  it("gives direct refresh calls 120 seconds instead of the 15-second network default", async () => {
    await seed();
    const original = AbortSignal.timeout.bind(AbortSignal);
    const created = new Map<number, AbortSignal[]>();
    vi.spyOn(AbortSignal, "timeout").mockImplementation((ms: number) => {
      const signal = original(ms);
      const list = created.get(ms) ?? [];
      list.push(signal);
      created.set(ms, list);
      return signal;
    });
    let refreshSignal: AbortSignal | undefined;
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (String(url).endsWith("/refresh")) {
        refreshSignal = init?.signal as AbortSignal | undefined;
        return new Response(JSON.stringify({ refreshed: 1, errors: 0 }));
      }
      return new Response(JSON.stringify(snapshot()));
    });
    expect(await localRequest("/refresh", { method: "POST" })).toEqual({ refreshed: 1, errors: 0 });
    expect(created.get(120_000)).toContain(refreshSignal);
    expect(created.get(15_000) ?? []).not.toContain(refreshSignal);
  });
  it("rejects an already-aborted refresh without starting sync", async () => {
    await seed();
    const controller = new AbortController();
    controller.abort();
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (String(url).endsWith("/refresh")) {
        expect(init?.signal).toBe(controller.signal);
        expect(init?.signal?.aborted).toBe(true);
        throw new DOMException("Aborted", "AbortError");
      }
      return new Response(JSON.stringify(snapshot()));
    });
    await expect(localRequest("/refresh", { method: "POST", signal: controller.signal })).rejects.toThrow();
    expect(vi.mocked(fetch).mock.calls.map(([url]) => String(url))).toEqual(["https://sync.pods.mcgiv.dev:8443/api/refresh"]);
  });
  it("keeps previous refresh history when a later snapshot omits it", async () => {
    await seed();
    await updateState(s => { s.snapshot!.refresh_status = { ...savedStatus, is_refreshing: false }; });
    vi.mocked(fetch).mockImplementation(async (url) => {
      if (String(url).endsWith("/refresh")) return new Response(JSON.stringify({ refreshed: 32, errors: 0 }));
      return new Response(JSON.stringify(snapshot()));
    });
    expect(await localRequest("/refresh", { method: "POST" })).toEqual({ refreshed: 32, errors: 0 });
    expect(await localRequest("/refresh-status")).toMatchObject({ last_success_at: 123, is_refreshing: false });
  });
  it("reports the refresh outcome even when the follow-up sync conflicts", async () => {
    await seed();
    vi.mocked(fetch).mockImplementation(async (url) => {
      if (String(url).endsWith("/refresh")) return new Response(JSON.stringify({ refreshed: 2, errors: 1 }));
      throw new DOMException("Conflict", "409");
    });
    expect(await localRequest("/refresh", { method: "POST" })).toEqual({ refreshed: 2, errors: 1 });
  });
  it("initializes once and commits concurrent outbox changes without losing operations", async () => {
    expect(offlineEnabled()).toBe(true);
    expect(await hasLocalLibrary()).toBe(false);
    const first = await state();
    await seed();
    await Promise.all([enqueue("1", "played", true), enqueue("2", "played", true)]);
    const saved = await state();
    expect(saved.client_id).toBe(first.client_id);
    expect(saved.outbox.map(o => o.sequence)).toEqual([1, 2]);
    expect(await hasLocalLibrary()).toBe(true);
    expect((await localRequest<{ items: unknown[] }>("/recent")).items).toEqual([]);
    expect((await localRequest<{ items: unknown[] }>("/played")).items).toHaveLength(2);
  });
  it("queries snapshots, applies backward seeks, and keeps source snapshot unchanged", async () => {
    await seed();
    const original = snapshot();
    const overlay = applyOverlay(original, [{ id: "one", sequence: 1, entity: "1", field: "position", value: { seconds: 2 }, base_revision: 0 }]);
    expect(overlay.episodes[0].position_secs).toBe(2);
    expect(original.episodes[0].position_secs).toBe(0);
    const mapped = applyOverlay(original, [{ id: "old", sequence: 2, entity: "1", field: "position", value: { seconds: 6, original_seconds: 9 }, base_revision: 0 }]);
    expect(mapped.episodes[0].position_secs).toBe(9);
    expect(await localRequest("/shows")).toEqual(original.shows);
    expect((await localRequest<{ episodes: { items: unknown[] } }>("/shows/1")).episodes.items).toHaveLength(2);
    expect((await localRequest<{ items: unknown[] }>("/shows/1/search?q=2")).items).toHaveLength(1);
    expect(await localRequest("/episodes/1/show-notes", { method: "POST" })).toEqual(original.episodes[0].show_notes);
    expect((await localRequest<{ episodes: unknown[] }>("/search?q=Episode")).episodes).toHaveLength(2);
    expect(await localRequest("/next?after=1")).toBeNull();
    await writeRecord("downloads", "b".repeat(64), { hash: "b".repeat(64), episode: 2, complete: true, bytes: 8, touched: 0 });
    expect((await localRequest<EpisodeDetail>("/next?after=1&context=show")).id).toBe(2);
    await expect(localRequest("/episodes/999")).rejects.toThrow("not available");
    await expect(localRequest("/shows/999")).rejects.toThrow("unavailable");
    expect(await localRequest("/follows")).toEqual([]);
  });
  it("queues subscriptions and settings; exports and imports OPML while disconnected", async () => {
    await seed();
    const xml = await localRequest<string>("/opml", {}, true);
    expect(xml).toContain("https://example.org/feed");
    expect(await localRequest("/opml", { method: "POST", body: xml })).toEqual({ imported: 1, skipped: 0, failed: 0 });
    await localRequest("/shows", { method: "POST", body: JSON.stringify({ feed_url: "https://new.example/feed" }) });
    await localRequest("/settings", { method: "PUT", body: JSON.stringify({ speed: 2, autoplay: false }) });
    expect(await localRequest("/settings")).toEqual({ speed: 2, autoplay: false });
    await localRequest("/episodes/1/position", { method: "PUT", body: JSON.stringify({ seconds: 4 }) });
    expect((await localRequest<EpisodeDetail>("/episodes/1")).position_secs).toBe(4);
    await localRequest("/episodes/1/played", { method: "POST" });
    await localRequest("/episodes/1/played", { method: "DELETE" });
    expect((await localRequest<EpisodeDetail>("/episodes/1")).played_at).toBeNull();
    await localRequest("/shows/1", { method: "DELETE" });
    expect(await localRequest("/shows")).toEqual([]);
    expect(await localRequest("/ad-removal/settings")).toMatchObject({
      enabled: true,
      listen_requires_ready: true,
      classifier_available: true,
      classifier_unavailable_reason: null,
      model_repository: LOCAL_OMLX_MODEL,
    });
    expect(await localRequest("/ad-removal/settings")).not.toHaveProperty("deepseek_usage");
    expect(await localRequest("/ad-removal/statuses")).toMatchObject({ items: [] });
    expect(await localRequest("/refresh-status")).toHaveProperty("last_success_at");
    await expect(localRequest("/unsupported")).rejects.toThrow();
    await expect(localRequest("/refresh", { method: "POST" })).rejects.toThrow();
  });
});

describe("synchronization", () => {
  it("rejects unprocessed snapshots before replacing local data", async () => {
    await seed();
    const invalid = snapshot(); invalid.episodes[0].audio_url = "https://publisher.example/original.mp3";
    expect(() => validateSnapshot(invalid)).toThrow("unpublished");
    expect(() => validateSnapshot({ ...invalid, version: 9 })).toThrow("Unsupported");
    expect(() => validateSnapshot(snapshot())).not.toThrow();
    const newestFirst = [
      { id: 3, episode_id: 1, category: "show_notes" as const, failed_stage: "show_notes", message: "Show-note generation failed.", outcome: "retry" as const, created_at: 30, episode_title: "C", podcast_title: "Example" },
      { id: 2, episode_id: 1, category: "ad_classification" as const, failed_stage: "classifying", message: "Ad classification failed.", outcome: "blocked" as const, created_at: 20, episode_title: "B", podcast_title: "Example" },
      { id: 1, episode_id: 2, category: "audio_download" as const, failed_stage: "downloading", message: "Audio download failed.", outcome: "retry" as const, created_at: 10, episode_title: "A", podcast_title: "Example" },
    ];
    expect(() => validateSnapshot({ ...snapshot(), notifications: newestFirst })).not.toThrow();
    expect(() => validateSnapshot({ ...snapshot(), notifications: [...newestFirst].reverse() })).toThrow("Unsupported");
    expect(() => validateSnapshot({ ...snapshot(), notifications: [{ ...newestFirst[0], category: "download" as never }] })).toThrow("Unsupported");
    expect(() => validateSnapshot({ ...snapshot(), notifications: [{ ...newestFirst[0], outcome: "pending" as never }] })).toThrow("Unsupported");
    await updateState(s => { s.snapshot = { ...snapshot(), notifications: newestFirst }; });
    expect((await state()).snapshot?.notifications?.map(n => n.id)).toEqual([3, 2, 1]);
    expect((await state()).snapshot?.notifications?.[0]).toMatchObject({ category: "show_notes", episode_title: "C" });
    vi.mocked(fetch).mockResolvedValue(new Response(JSON.stringify(invalid)));
    await expect(synchronize()).rejects.toThrow();
    expect((await state()).snapshot?.episodes[0].audio_url).toContain("/_media/");
  });
  it("acknowledges ordered changes, rebases subsequent changes, and retains conflicts", async () => {
    await seed();
    await updateState(s => {
      s.outbox = [
        { id: "op1", sequence: 1, entity: "1", field: "played", value: true, base_revision: 0 },
        { id: "op3", sequence: 3, entity: "2", field: "played", value: true, base_revision: 0 },
      ];
    });
    const posted: string[] = [];
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (String(url).endsWith("/sync/actions")) {
        const body = JSON.parse(String(init?.body));
        posted.push(...body.actions.map((action: { id: string }) => action.id));
        return new Response(JSON.stringify({ results: body.actions.map((action: { id: string }) => ({ id: action.id, status: action.id === "op3" ? "conflict" : "applied", revision: 1 })) }));
      }
      return new Response(JSON.stringify(snapshot()));
    });
    const promise = synchronize(); expect(synchronize()).toBe(promise);
    await promise;
    expect(posted).toEqual(["op1", "op3"]);
    expect((await state()).outbox).toHaveLength(1);
    expect((await state()).outbox[0].conflict).toBe(1);
    await resolveConflict("op3", false);
    expect((await state()).outbox).toHaveLength(0);
    expect((await state()).lastSync).not.toBeNull();
  });
  it("sends only the latest edit per field and drops a 409 item", async () => {
    await seed();
    await updateState(s => {
      s.outbox = [
        { id: "old", sequence: 1, entity: "1", field: "played", value: false, base_revision: 0 },
        { id: "stale", sequence: 2, entity: "1", field: "position", value: { seconds: 1, artifact_hash: "c".repeat(64) }, base_revision: 0 },
        { id: "last", sequence: 3, entity: "1", field: "played", value: true, base_revision: 0 },
        { id: "fresh", sequence: 4, entity: "2", field: "played", value: true, base_revision: 0 },
      ];
    });
    const posted: string[][] = [];
    vi.mocked(fetch).mockImplementation(async (url, init) => {
      if (String(url).endsWith("/sync/actions")) {
        const body = JSON.parse(String(init?.body));
        const ids = body.actions.map((action: { id: string }) => action.id);
        posted.push(ids);
        expect(body.actions[0]).not.toHaveProperty("conflict");
        if (ids.includes("stale") && ids.length > 1) return new Response(JSON.stringify({ error: "operation identity reused" }), { status: 409 });
        if (ids.length === 1 && ids[0] === "stale") return new Response(JSON.stringify({ error: "operation identity reused" }), { status: 409 });
        return new Response(JSON.stringify({ results: ids.filter((id: string) => id !== "stale").map((id: string) => ({ id, status: "applied", revision: 1 })) }));
      }
      return new Response(JSON.stringify(snapshot()));
    });
    await synchronize();
    expect(posted.flat()).toEqual(["stale", "last", "fresh", "stale", "last", "fresh"]);
    expect((await state()).outbox.map(o => o.id)).toEqual([]);
    expect((await state()).lastSync).not.toBeNull();
  });
  it("retains unauthenticated local changes and supports explicit conflict resolution", async () => {
    await seed();
    await updateState(s => { s.outbox = [{ id: "conflict", sequence: 1, entity: "1", field: "played", value: true, base_revision: 0, conflict: 3 }]; });
    vi.mocked(fetch).mockResolvedValue(new Response("", { status: 401 }));
    await expect(resolveConflict("conflict", true)).rejects.toThrow("Sign in");
    const pending = (await state()).outbox[0];
    expect(pending.base_revision).toBe(3); expect(pending.id).not.toBe("conflict");
    expect((await localRequest<{ items: unknown[] }>("/played")).items).toHaveLength(1);
    vi.mocked(fetch).mockResolvedValue(new Response(null, { status: 204 }));
    expect(await network("/test", { method: "POST", body: "{}" })).toBeUndefined();
  });
});

describe("verified downloads and local Range playback", () => {
  async function prepareAudio() {
    const bytes = new TextEncoder().encode("abcdefgh").buffer;
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    const digestHex = [...new Uint8Array(digest)].map(v => v.toString(16).padStart(2, "0")).join("");
    await seed();
    await updateState(s => { s.snapshot!.episodes[0].manifest!.chunks = [digestHex]; });
    vi.mocked(fetch).mockResolvedValue(new Response(bytes, { status: 206, headers: { "Content-Range": "bytes 0-7/8" } }));
    return bytes;
  }
  it("verifies chunks and serves complete, suffix, open, and invalid ranges", async () => {
    const bytes = await prepareAudio();
    expect(await verifyChunk(bytes, "wrong")).toBe(false);
    await downloadEpisode(1);
    expect((await allDownloads())[0].complete).toBe(true);
    const request = (range?: string, method = "GET") => new Request(`https://pods.mcgiv.dev/_media/${hash}.m4a`, { method, headers: range ? { Range: range } : {} });
    expect(await (await localMedia(request("bytes=2-5"))).text()).toBe("cdef");
    expect(await (await localMedia(request("bytes=-3"))).text()).toBe("fgh");
    expect(await (await localMedia(request("bytes=5-"))).text()).toBe("fgh");
    const whole = await localMedia(request()); expect(whole.status).toBe(200); expect(await whole.text()).toBe("abcdefgh");
    const head = await localMedia(request(undefined, "HEAD")); expect(await head.text()).toBe(""); expect(head.headers.get("content-length")).toBe("8");
    expect((await localMedia(request("bytes=99-"))).status).toBe(416);
    expect((await localMedia(new Request("https://pods.mcgiv.dev/_media/nope"))).status).toBe(404);
    expect(byteRange("bytes=-0", 8)).toBeNull(); expect(byteRange("bytes=3-1", 8)).toBeNull(); expect(byteRange("bytes=1-2,4-5", 8)).toBeNull();
    await downloadEpisode(1); // Verified stored chunks avoid a second transfer.
    expect(vi.mocked(fetch)).toHaveBeenCalledTimes(1);
  });
  it("detects eviction, prevents false ready state, and protects the playing file", async () => {
    await prepareAudio(); await downloadEpisode(1);
    expect(await readRecord("meta", `manifest:${hash}`)).toBeTruthy();
    protectPlayingArtifact(hash);
    await updateState(s => { s.preferences.limit = 10; });
    await expect(downloadEpisode(2)).rejects.toThrow("Increase the storage limit");
    expect((await allDownloads())[0].hash).toBe(hash);
    protectPlayingArtifact(null);
    await deleteDownload(hash);
    expect(await allDownloads()).toEqual([]);
    expect(await readRecord("meta", `manifest:${hash}`)).toBeUndefined();
    expect((await localMedia(new Request(`https://pods.mcgiv.dev/_media/${hash}.m4a`))).status).toBe(503);
    await writeRecord("meta", `manifest:${hash}`, manifest);
    await writeRecord("downloads", hash, { hash, episode: 1, bytes: 8, complete: true, touched: 0 });
    expect((await localMedia(new Request(`https://pods.mcgiv.dev/_media/${hash}.m4a`))).status).toBe(503);
    expect(await readRecord("downloads", hash)).toMatchObject({ complete: false });
  });
  it("does not publish corrupt or interrupted transfers and pauses hidden-page downloads", async () => {
    await prepareAudio();
    vi.mocked(fetch).mockResolvedValue(new Response("corrupt!", { status: 206, headers: { "Content-Range": "bytes 0-7/8" } }));
    await expect(downloadEpisode(1)).rejects.toThrow("verification");
    expect((await allDownloads())[0].complete).toBe(false);
    expect(downloadError()).toContain("verification");
    vi.mocked(fetch).mockResolvedValue(new Response("", { status: 401 }));
    await expect(downloadEpisode(1)).rejects.toThrow("Mac unavailable");
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });
    await expect(downloadEpisode(1)).rejects.toThrow("paused");
    await prefetch();
  });
  it("enforces limits and processes only the configured automatic queue", async () => {
    await prepareAudio();
    await expect(savePreferences({ limit: 0, count: 10 })).rejects.toThrow("Invalid");
    await savePreferences({ limit: 1024 ** 3, count: 1 });
    await prefetch();
    expect((await allDownloads()).map(d => d.episode)).toEqual([1]);
    await prefetch(); expect(vi.mocked(fetch)).toHaveBeenCalledTimes(1);
    await deleteDownload(hash); expect(await allDownloads()).toEqual([]);
    await updateState(s => { s.snapshot!.episodes[0].manifest!.bytes = 3 * 1024 ** 3; s.snapshot!.episodes[0].manifest!.chunks = Array(3072).fill(hash); });
    await expect(downloadEpisode(1)).rejects.toThrow("limit");
    expect(emptyState().preferences.count).toBe(10);
    expect(emptyState().preferences).not.toHaveProperty("pins");
  });
});

describe("automatic Listen downloads", () => {
  const other = "b".repeat(64);

  async function seedComplete(episodeId: number, episodeHash: string, complete = true) {
    await writeRecord("meta", `manifest:${episodeHash}`, { ...manifest, episode_id: episodeId, hash: episodeHash });
    await writeRecord("chunks", `${episodeHash}:0`, new TextEncoder().encode("abcdefgh").buffer);
    await writeRecord("downloads", episodeHash, { hash: episodeHash, episode: episodeId, bytes: 8, complete, touched: 0 });
  }

  it("lists only fully downloaded unplayed episodes on /recent", async () => {
    await seed();
    expect((await localRequest<{ items: unknown[] }>("/recent")).items).toEqual([]);
    await seedComplete(1, hash, false);
    expect((await localRequest<{ items: unknown[] }>("/recent")).items).toEqual([]);
    await seedComplete(1, hash, true);
    expect((await localRequest<{ items: { id: number }[] }>("/recent")).items.map(e => e.id)).toEqual([1]);
    await seedComplete(2, other, true);
    expect((await localRequest<{ items: { id: number }[] }>("/recent")).items.map(e => e.id)).toEqual([1, 2]);
  });

  it("normalizes legacy pins without clearing snapshot, outbox, or downloads", async () => {
    await seed();
    await updateState(s => {
      s.outbox = [{ id: "op1", sequence: 1, entity: "1", field: "position", value: { seconds: 3 }, base_revision: 0 }];
    });
    await seedComplete(1, hash, true);
    const raw = await readRecord<LocalState>("meta", "state");
    await writeRecord("meta", "state", { ...raw, preferences: { ...raw!.preferences, pins: [1, 2] } });
    const loaded = await state();
    expect(loaded.preferences).toEqual({ limit: 2 * 1024 ** 3, count: 10 });
    expect(loaded.preferences).not.toHaveProperty("pins");
    expect(loaded.snapshot?.episodes).toHaveLength(2);
    expect(loaded.outbox).toHaveLength(1);
    expect(await readRecord("downloads", hash)).toMatchObject({ complete: true });
    const persisted = await readRecord<LocalState>("meta", "state");
    expect(persisted?.preferences).not.toHaveProperty("pins");
    expect(persisted?.outbox).toHaveLength(1);
    expect(persisted?.snapshot?.shows).toHaveLength(1);
  });

  it("marks played durably and deletes only that episode's audio cache", async () => {
    await seed();
    await seedComplete(1, hash, true);
    await seedComplete(2, other, true);
    await writeRecord("meta", "unrelated", { keep: true });
    await localRequest("/episodes/1/played", { method: "POST" });
    const saved = await state();
    expect(saved.outbox.some(o => o.entity === "1" && o.field === "played" && o.value === true)).toBe(true);
    expect(await allDownloads()).toEqual([expect.objectContaining({ hash: other, episode: 2, complete: true })]);
    expect(await readRecord("meta", `manifest:${hash}`)).toBeUndefined();
    expect(await readRecord("chunks", `${hash}:0`)).toBeUndefined();
    expect(await readRecord("downloads", hash)).toBeUndefined();
    expect(await readRecord("meta", `manifest:${other}`)).toBeTruthy();
    expect(await readRecord("chunks", `${other}:0`)).toBeTruthy();
    expect(await readRecord("meta", "unrelated")).toEqual({ keep: true });
    expect((await localRequest<{ items: { id: number }[] }>("/played")).items.map(e => e.id)).toEqual([1]);
    expect((await localRequest<{ items: { id: number }[] }>("/recent")).items.map(e => e.id)).toEqual([2]);
  });

  it("is idempotent and leaves unrelated downloads and metadata in place", async () => {
    await seed();
    await seedComplete(1, hash, true);
    await seedComplete(2, other, true);
    await writeRecord("meta", "unrelated", { keep: true });
    await cleanupPlayedDownload(1);
    await cleanupPlayedDownload(1);
    expect(await allDownloads()).toEqual([expect.objectContaining({ hash: other, episode: 2 })]);
    expect(await readRecord("meta", `manifest:${hash}`)).toBeUndefined();
    expect(await readRecord("chunks", `${hash}:0`)).toBeUndefined();
    expect(await readRecord("meta", `manifest:${other}`)).toBeTruthy();
    expect(await readRecord("meta", "unrelated")).toEqual({ keep: true });
    expect((await state()).snapshot?.episodes).toHaveLength(2);
  });

  it("keeps the played operation when cleanup fails, then a later sweep succeeds", async () => {
    await seed();
    await seedComplete(1, hash, true);
    const spy = vi.spyOn(store, "deleteDownload").mockRejectedValueOnce(new Error("idb full"));
    await localRequest("/episodes/1/played", { method: "POST" });
    const saved = await state();
    expect(saved.outbox.some(o => o.entity === "1" && o.field === "played" && o.value === true)).toBe(true);
    expect((await localRequest<{ items: { id: number }[] }>("/played")).items.map(e => e.id)).toEqual([1]);
    expect(await readRecord("downloads", hash)).toMatchObject({ episode: 1 });
    spy.mockRestore();
    await sweepStaleDownloads();
    expect(await allDownloads()).toEqual([]);
    expect(await readRecord("meta", `manifest:${hash}`)).toBeUndefined();
    expect(await readRecord("chunks", `${hash}:0`)).toBeUndefined();
    expect((await localRequest<{ items: { id: number }[] }>("/played")).items.map(e => e.id)).toEqual([1]);
  });

  it("does not download played or archived episodes and sweeps their stale audio", async () => {
    const bytes = new TextEncoder().encode("abcdefgh").buffer;
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    const digestHex = [...new Uint8Array(digest)].map(v => v.toString(16).padStart(2, "0")).join("");
    await seed();
    await updateState(s => { s.snapshot!.episodes[0].manifest!.chunks = [digestHex]; });
    vi.mocked(fetch).mockResolvedValue(new Response(bytes, { status: 206, headers: { "Content-Range": "bytes 0-7/8" } }));
    await downloadEpisode(1);
    await enqueue("1", "played", true);
    const episodeFetches = (episodeHash: string) => vi.mocked(fetch).mock.calls.filter(([url]) => String(url).includes(`/artifacts/${episodeHash}`)).length;
    const afterMark = episodeFetches(hash);
    await prefetch();
    expect((await allDownloads()).some(d => d.episode === 1)).toBe(false);
    expect(episodeFetches(hash)).toBe(afterMark);
    await updateState(s => { s.outbox = []; s.snapshot!.episodes[0].played_at = null; s.snapshot!.episodes[0].archived_at = 1; });
    await seedComplete(1, hash, true);
    const afterArchive = episodeFetches(hash);
    await prefetch();
    expect((await allDownloads()).some(d => d.episode === 1)).toBe(false);
    expect(episodeFetches(hash)).toBe(afterArchive);
  });

  it("does not return an unmarked episode to Listen until download completes", async () => {
    const bytes = new TextEncoder().encode("abcdefgh").buffer;
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    const digestHex = [...new Uint8Array(digest)].map(v => v.toString(16).padStart(2, "0")).join("");
    await seed();
    await updateState(s => { s.snapshot!.episodes[0].manifest!.chunks = [digestHex]; });
    vi.mocked(fetch).mockResolvedValue(new Response(bytes, { status: 206, headers: { "Content-Range": "bytes 0-7/8" } }));
    await downloadEpisode(1);
    expect((await localRequest<{ items: { id: number }[] }>("/recent")).items.map(e => e.id)).toEqual([1]);
    await localRequest("/episodes/1/played", { method: "POST" });
    expect((await localRequest<{ items: unknown[] }>("/recent")).items).toEqual([]);
    expect((await localRequest<{ items: { id: number }[] }>("/played")).items.map(e => e.id)).toEqual([1]);
    vi.mocked(fetch).mockRejectedValue(new Error("Mac unavailable"));
    await localRequest("/episodes/1/played", { method: "DELETE" });
    expect((await localRequest<{ items: unknown[] }>("/recent")).items).toEqual([]);
    expect((await localRequest<{ items: unknown[] }>("/played")).items).toEqual([]);
    vi.mocked(fetch).mockResolvedValue(new Response(bytes, { status: 206, headers: { "Content-Range": "bytes 0-7/8" } }));
    await prefetch();
    expect((await localRequest<{ items: { id: number }[] }>("/recent")).items.map(e => e.id)).toEqual([1]);
  });
});


describe("notification dismissal", () => {
  const notice = (id: number) => ({ id, episode_id: 1, category: "ad_classification" as const,
    failed_stage: "classifying", message: "Ad classification failed.", outcome: "retry" as const,
    created_at: id, episode_title: "Episode", podcast_title: "Example" });

  it("persists offline dismissal across rereads and repeated sync snapshots while allowing new failures", async () => {
    const incoming = { ...snapshot(), notifications: [notice(3), notice(2), notice(1)] };
    await updateState(s => { s.snapshot = incoming; });
    expect(store.visibleNotifications(await state())).toHaveLength(3);
    await clearNotifications(3);
    expect(fetch).not.toHaveBeenCalled();
    expect(store.visibleNotifications(await state())).toEqual([]);
    vi.mocked(fetch).mockImplementation(async () => new Response(JSON.stringify(incoming)));
    await synchronize();
    expect(store.visibleNotifications(await state())).toEqual([]);
    incoming.notifications.unshift(notice(4));
    await synchronize();
    expect(store.visibleNotifications(await state()).map(n => n.id)).toEqual([4]);
    expect((await state()).snapshot?.episodes).toEqual(incoming.episodes);
    expect((await state()).outbox).toEqual([]);
  });

  it("retains notices arriving during clear and never lowers the marker on stale clears", async () => {
    await updateState(s => { s.snapshot = { ...snapshot(), notifications: [notice(5), notice(4), notice(3)] }; });
    await Promise.all([clearNotifications(4), clearNotifications(3)]);
    expect(store.visibleNotifications(await state()).map(n => n.id)).toEqual([5]);
    await clearNotifications(5);
    await clearNotifications(3);
    expect(store.visibleNotifications(await state())).toEqual([]);
  });
});
