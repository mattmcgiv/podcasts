import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Api } from "./api";
import { REFRESH_TIMEOUT_MS, refreshFeeds, resetRefreshFeedsForTests } from "./refreshFeeds";

describe("refreshFeeds", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    resetRefreshFeedsForTests();
  });

  afterEach(() => {
    resetRefreshFeedsForTests();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("delegates to Api.refresh", async () => {
    const spy = vi.spyOn(Api, "refresh").mockResolvedValue({ refreshed: 2, errors: 0 });
    await expect(refreshFeeds()).resolves.toEqual({ refreshed: 2, errors: 0 });
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it("coalesces concurrent callers onto a single Api.refresh", async () => {
    let resolve!: (v: { refreshed: number; errors: number }) => void;
    const pending = new Promise<{ refreshed: number; errors: number }>((r) => {
      resolve = r;
    });
    const spy = vi.spyOn(Api, "refresh").mockReturnValue(pending);

    const a = refreshFeeds();
    const b = refreshFeeds();
    expect(spy).toHaveBeenCalledTimes(1);

    resolve({ refreshed: 1, errors: 0 });
    await expect(a).resolves.toEqual({ refreshed: 1, errors: 0 });
    await expect(b).resolves.toEqual({ refreshed: 1, errors: 0 });
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it("allows a new call after the previous one settles", async () => {
    const spy = vi
      .spyOn(Api, "refresh")
      .mockResolvedValueOnce({ refreshed: 1, errors: 0 })
      .mockResolvedValueOnce({ refreshed: 2, errors: 0 });

    await refreshFeeds();
    await refreshFeeds();
    expect(spy).toHaveBeenCalledTimes(2);
  });

  it("propagates a plain API rejection and releases the lock", async () => {
    const spy = vi
      .spyOn(Api, "refresh")
      .mockRejectedValueOnce(new Error("boom"))
      .mockResolvedValueOnce({ refreshed: 1, errors: 0 });

    await expect(refreshFeeds()).rejects.toThrow("boom");
    await expect(refreshFeeds()).resolves.toEqual({ refreshed: 1, errors: 0 });
    expect(spy).toHaveBeenCalledTimes(2);
  });

  it("releases the lock after a hung refresh times out so a later call can run", async () => {
    const spy = vi
      .spyOn(Api, "refresh")
      .mockImplementationOnce(
        (init) =>
          new Promise((_resolve, reject) => {
            init?.signal?.addEventListener("abort", () => {
              reject(new DOMException("Aborted", "AbortError"));
            });
          }),
      )
      .mockResolvedValueOnce({ refreshed: 3, errors: 0 });

    const first = refreshFeeds();
    // Attach handler before advancing so the timeout rejection is not unhandled.
    const firstOutcome = first.then(
      (value) => ({ ok: true as const, value }),
      (error: unknown) => ({ ok: false as const, error }),
    );

    await vi.advanceTimersByTimeAsync(REFRESH_TIMEOUT_MS);
    const timedOut = await firstOutcome;
    expect(timedOut.ok).toBe(false);
    if (!timedOut.ok) {
      expect(String(timedOut.error)).toMatch(/timed out/i);
    }

    await expect(refreshFeeds()).resolves.toEqual({ refreshed: 3, errors: 0 });
    expect(spy).toHaveBeenCalledTimes(2);
    expect(spy.mock.calls[0][0]?.signal).toBeInstanceOf(AbortSignal);
  });
});
