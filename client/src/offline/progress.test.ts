import { afterEach, describe, expect, it } from "vitest";
import {
  currentDownloadProgress,
  onDownloadProgress,
  resetDownloadProgressForTests,
  setDownloadProgress,
} from "./progress";

afterEach(() => {
  resetDownloadProgressForTests();
});

describe("download progress", () => {
  it("publishes the current transfer and notifies subscribers", () => {
    const seen: Array<{ episode: number; received: number; total: number } | null> = [];
    const stop = onDownloadProgress(next => { seen.push(next); });
    setDownloadProgress({ episode: 3, received: 10, total: 20 });
    expect(currentDownloadProgress()).toEqual({ episode: 3, received: 10, total: 20 });
    setDownloadProgress(null);
    expect(currentDownloadProgress()).toBeNull();
    expect(seen).toEqual([{ episode: 3, received: 10, total: 20 }, null]);
    stop();
    setDownloadProgress({ episode: 3, received: 20, total: 20 });
    expect(seen).toHaveLength(2);
  });

  it("treats a missing event detail as idle", () => {
    const seen: Array<{ episode: number; received: number; total: number } | null> = [];
    const stop = onDownloadProgress(next => { seen.push(next); });
    window.dispatchEvent(new Event("pods-download-progress"));
    expect(seen).toEqual([null]);
    stop();
  });

  it("clears in-memory progress between tests without dispatching", () => {
    const seen: unknown[] = [];
    const stop = onDownloadProgress(next => { seen.push(next); });
    setDownloadProgress({ episode: 1, received: 1, total: 2 });
    resetDownloadProgressForTests();
    expect(currentDownloadProgress()).toBeNull();
    expect(seen).toEqual([{ episode: 1, received: 1, total: 2 }]);
    stop();
  });
});
