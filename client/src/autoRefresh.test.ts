import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AUTO_REFRESH_INTERVAL_MS, AUTO_REFRESH_RETRY_MS, startAutoRefresh } from "./autoRefresh";

describe("startAutoRefresh", () => {
  beforeEach(() => {
    // shouldAdvanceTime keeps Date.now in lockstep with setTimeout under Vitest.
    vi.useFakeTimers({ shouldAdvanceTime: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  function harness(opts: { visible?: boolean } = {}) {
    let visible = opts.visible ?? true;
    const refresh = vi.fn(async () => {});
    const visibilityListeners = new Set<() => void>();
    // Use production defaults for timers/now; Vitest fake timers patch globals.
    const stop = startAutoRefresh({
      refresh,
      isVisible: () => visible,
      onVisibilityChange: (cb) => {
        visibilityListeners.add(cb);
        return () => visibilityListeners.delete(cb);
      },
    });
    return {
      refresh,
      stop,
      setVisible(next: boolean) {
        visible = next;
        for (const cb of visibilityListeners) cb();
      },
    };
  }

  it("does not refresh on start; fires after 30 minutes while visible", async () => {
    const { refresh, stop } = harness({ visible: true });

    expect(refresh).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS - 1);
    expect(refresh).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1);
    expect(refresh).toHaveBeenCalledTimes(1);

    stop();
  });

  it("schedules the next refresh 30 minutes after a successful tick while still visible", async () => {
    const { refresh, stop } = harness({ visible: true });

    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    expect(refresh).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    expect(refresh).toHaveBeenCalledTimes(2);

    stop();
  });

  it("does not call refresh when time advances while document/app is hidden", async () => {
    const { refresh, setVisible, stop } = harness({ visible: true });

    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS / 2);
    setVisible(false);

    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS * 2);
    expect(refresh).not.toHaveBeenCalled();

    stop();
  });

  it("resumes remaining interval after becoming visible again without firing immediately", async () => {
    const { refresh, setVisible, stop } = harness({ visible: true });

    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS / 2);
    setVisible(false);
    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    expect(refresh).not.toHaveBeenCalled();

    setVisible(true);
    expect(refresh).not.toHaveBeenCalled();

    // Half the interval already elapsed while visible; remaining half should fire.
    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS / 2 - 1);
    expect(refresh).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(refresh).toHaveBeenCalledTimes(1);

    stop();
  });

  it("fires immediately on restore when remaining interval is already zero", async () => {
    // Custom now: jump wall clock past the full interval without the timer
    // firing, then hide so pauseCountdown drains remaining to 0.
    let visible = true;
    let clock = 0;
    const refresh = vi.fn(async () => {});
    const listeners = new Set<() => void>();
    const stop = startAutoRefresh({
      refresh,
      isVisible: () => visible,
      onVisibilityChange: (cb) => {
        listeners.add(cb);
        return () => listeners.delete(cb);
      },
      now: () => clock,
      setTimeout: (fn, ms) => setTimeout(fn, ms),
      clearTimeout: (id) => clearTimeout(id),
    });

    clock = AUTO_REFRESH_INTERVAL_MS;
    visible = false;
    for (const cb of listeners) cb();
    expect(refresh).not.toHaveBeenCalled();

    visible = true;
    for (const cb of listeners) cb();
    await Promise.resolve();
    expect(refresh).toHaveBeenCalledTimes(1);

    stop();
  });

  it("stops scheduling after stop() and ignores later timer advances", async () => {
    const { refresh, stop } = harness({ visible: true });

    stop();
    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS * 2);
    expect(refresh).not.toHaveBeenCalled();
  });

  it("does not start a timer when initially hidden", async () => {
    const { refresh, setVisible, stop } = harness({ visible: false });

    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS * 2);
    expect(refresh).not.toHaveBeenCalled();

    setVisible(true);
    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    expect(refresh).toHaveBeenCalledTimes(1);

    stop();
  });

  it("re-arms after a rejected refresh and does not throw", async () => {
    const refresh = vi
      .fn()
      .mockRejectedValueOnce(new Error("network down"))
      .mockResolvedValueOnce(undefined);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const stop = startAutoRefresh({
      refresh,
      isVisible: () => true,
      onVisibilityChange: () => () => {},
    });

    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(warn).toHaveBeenCalled();

    // Failures re-arm with a shorter retry, not the full interval.
    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_RETRY_MS);
    expect(refresh).toHaveBeenCalledTimes(2);

    stop();
    warn.mockRestore();
  });

  it("skips a second tick while a refresh is still in flight", async () => {
    let resolveRefresh!: () => void;
    const refresh = vi.fn(
      () =>
        new Promise<void>((r) => {
          resolveRefresh = r;
        }),
    );
    const stop = startAutoRefresh({
      refresh,
      isVisible: () => true,
      onVisibilityChange: () => () => {},
    });

    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    expect(refresh).toHaveBeenCalledTimes(1);

    // Timer would not re-arm until the first refresh settles; advancing does nothing.
    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    expect(refresh).toHaveBeenCalledTimes(1);

    resolveRefresh();
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(AUTO_REFRESH_INTERVAL_MS);
    expect(refresh).toHaveBeenCalledTimes(2);

    stop();
  });
});
