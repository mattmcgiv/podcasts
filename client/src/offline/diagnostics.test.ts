import { beforeEach, describe, expect, it, vi } from "vitest";
import { IDBFactory, IDBKeyRange } from "fake-indexeddb";
import {
  clearDiagnostics,
  clearMediaDiagnostics,
  formatDiagnostics,
  logDiagnostic,
  logMediaDiagnostic,
  MEDIA_DIAGNOSTIC_CAP,
  PAGE_DIAGNOSTIC_CAP,
  readDiagnostics,
  readMediaDiagnostics,
} from "./diagnostics";
import * as store from "./store";

beforeEach(() => {
  vi.stubGlobal("indexedDB", new IDBFactory());
  vi.stubGlobal("IDBKeyRange", IDBKeyRange);
});

describe("page diagnostics ring", () => {
  it("keeps appended entries across reads", () => {
    logDiagnostic("playback-error", "episode_id=9 video=true");
    logDiagnostic("sync-error", "Mac unavailable. Downloaded episodes still play.");
    const entries = readDiagnostics();
    expect(entries).toHaveLength(2);
    expect(entries[0]).toMatchObject({ kind: "playback-error", detail: "episode_id=9 video=true" });
    expect(entries[1].kind).toBe("sync-error");
  });

  it("trims to the newest entries", () => {
    for (let i = 0; i < PAGE_DIAGNOSTIC_CAP + 5; i++) logDiagnostic("sync-error", `failure ${i}`);
    const entries = readDiagnostics();
    expect(entries).toHaveLength(PAGE_DIAGNOSTIC_CAP);
    expect(entries[0].detail).toBe("failure 5");
    expect(entries.at(-1)?.detail).toBe(`failure ${PAGE_DIAGNOSTIC_CAP + 4}`);
  });

  it("ignores malformed stored values", () => {
    window.localStorage.setItem("pods-diagnostics-v1", "not json");
    expect(readDiagnostics()).toEqual([]);
    window.localStorage.setItem("pods-diagnostics-v1", JSON.stringify({ kind: "sync-error" }));
    expect(readDiagnostics()).toEqual([]);
    window.localStorage.setItem("pods-diagnostics-v1", JSON.stringify([
      { at: 1, kind: "sync-error", detail: "kept" },
      { at: "now", kind: "sync-error", detail: "dropped" },
      null,
    ]));
    expect(readDiagnostics()).toEqual([{ at: 1, kind: "sync-error", detail: "kept" }]);
  });

  it("clears the ring", () => {
    logDiagnostic("sync-error", "failure");
    clearDiagnostics();
    expect(readDiagnostics()).toEqual([]);
  });

  it("never throws when storage is unavailable", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new Error("denied"); });
    expect(() => logDiagnostic("sync-error", "failure")).not.toThrow();
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => { throw new Error("denied"); });
    expect(readDiagnostics()).toEqual([]);
    vi.spyOn(Storage.prototype, "removeItem").mockImplementation(() => { throw new Error("denied"); });
    expect(() => clearDiagnostics()).not.toThrow();
  });
});

describe("media diagnostics ring", () => {
  it("keeps worker-side entries in IndexedDB", async () => {
    await logMediaDiagnostic({ at: 10, kind: "media-capped", detail: "ed636ab8 bytes 0-7/342" });
    await logMediaDiagnostic({ at: 11, kind: "media-evicted", detail: "ed636ab8 chunk 3" });
    const entries = await readMediaDiagnostics();
    expect(entries).toHaveLength(2);
    expect(entries[0]).toEqual({ at: 10, kind: "media-capped", detail: "ed636ab8 bytes 0-7/342" });
  });

  it("trims to the newest entries", async () => {
    for (let i = 0; i < MEDIA_DIAGNOSTIC_CAP + 2; i++) {
      await logMediaDiagnostic({ at: i, kind: "media-capped", detail: `range ${i}` });
    }
    const entries = await readMediaDiagnostics();
    expect(entries).toHaveLength(MEDIA_DIAGNOSTIC_CAP);
    expect(entries[0].detail).toBe("range 2");
  });

  it("clears the ring", async () => {
    await logMediaDiagnostic({ at: 1, kind: "media-capped", detail: "range" });
    await clearMediaDiagnostics();
    expect(await readMediaDiagnostics()).toEqual([]);
  });

  it("ignores malformed stored values and storage failures", async () => {
    await store.writeRecord("meta", "diagnostics:media", { kind: "media-capped" });
    expect(await readMediaDiagnostics()).toEqual([]);
    vi.spyOn(store, "readRecord").mockRejectedValue(new Error("denied"));
    expect(await readMediaDiagnostics()).toEqual([]);
    await expect(logMediaDiagnostic({ at: 1, kind: "media-capped", detail: "range" })).resolves.toBeUndefined();
    vi.spyOn(store, "writeRecord").mockRejectedValue(new Error("denied"));
    await expect(clearMediaDiagnostics()).resolves.toBeUndefined();
  });
});

describe("formatDiagnostics", () => {
  it("renders both sections with entries", () => {
    const text = formatDiagnostics(
      [{ at: 1_700_000_000_000, kind: "sync-error", detail: "Mac unavailable." }],
      [{ at: 1_700_000_001_000, kind: "media-capped", detail: "ed636ab8 bytes 0-7/342" }],
    );
    expect(text).toContain("## page (1)");
    expect(text).toContain("[sync-error] Mac unavailable.");
    expect(text).toContain("## media (1)");
    expect(text).toContain("[media-capped] ed636ab8 bytes 0-7/342");
    expect(text).toContain("agent: ");
  });

  it("renders empty sections explicitly", () => {
    const text = formatDiagnostics([], []);
    expect(text).toContain("## page (0)");
    expect(text).toContain("## media (0)");
    expect(text).toContain("(none)");
  });
});
