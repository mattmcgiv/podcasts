/** Interval for open/visible feed auto-refresh (30 minutes). */
export const AUTO_REFRESH_INTERVAL_MS = 30 * 60 * 1000;
/** Retry sooner after a failed tick so a transient blip does not burn a full window. */
export const AUTO_REFRESH_RETRY_MS = 5 * 60 * 1000;

export interface AutoRefreshDeps {
  /**
   * Perform one feed refresh (API call + list signal).
   * MUST settle (resolve or reject) in bounded time — the scheduler will not
   * re-arm while this promise is pending. Production wires `refreshFeeds`,
   * which enforces its own AbortController timeout.
   */
  refresh: () => Promise<void>;
  /** True when the app is open/visible (e.g. !document.hidden). */
  isVisible: () => boolean;
  /** Subscribe to visibility changes; return unsubscribe. */
  onVisibilityChange: (cb: () => void) => () => void;
  /** Optional timer injection for tests; defaults to window timers. */
  setTimeout?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>;
  clearTimeout?: (id: ReturnType<typeof setTimeout>) => void;
  /**
   * Optional clock for remaining-interval math (tests).
   * Defaults to Date.now so Vitest fake timers advance it with setTimeout.
   */
  now?: () => number;
}

/**
 * Schedule feed refresh every {@link AUTO_REFRESH_INTERVAL_MS} only while
 * the app is open/visible. Does not fire on start. Hidden time does not
 * count toward the interval; remaining time resumes when visible again.
 * Returns a stop function that clears timers and unsubscribes.
 */
export function startAutoRefresh(deps: AutoRefreshDeps): () => void {
  const schedule = deps.setTimeout ?? ((fn, ms) => setTimeout(fn, ms));
  const cancel = deps.clearTimeout ?? ((id) => clearTimeout(id));
  const now = deps.now ?? (() => Date.now());

  let timer: ReturnType<typeof setTimeout> | null = null;
  let stopped = false;
  // Per-scheduler guard: skip re-entrant ticks while this instance awaits refresh().
  // Cross-caller POST coalescing lives in refreshFeeds(); both layers are intentional.
  let inFlight = false;
  /** ms remaining until the next fire while visible; full interval after each fire. */
  let remainingMs = AUTO_REFRESH_INTERVAL_MS;
  /** Wall time when the current visible countdown started (or last resumed). */
  let countdownStartedAt: number | null = null;

  function clearTimer() {
    if (timer != null) {
      cancel(timer);
      timer = null;
    }
  }

  function pauseCountdown() {
    if (countdownStartedAt != null) {
      const elapsed = Math.max(0, now() - countdownStartedAt);
      remainingMs = Math.max(0, remainingMs - elapsed);
      countdownStartedAt = null;
    }
    clearTimer();
  }

  function arm() {
    clearTimer();
    if (stopped || !deps.isVisible()) return;
    if (remainingMs <= 0) {
      void tick();
      return;
    }
    countdownStartedAt = now();
    const delay = remainingMs;
    timer = schedule(() => {
      timer = null;
      countdownStartedAt = null;
      // Countdown completed; if tick bails (hidden), remaining stays 0 so next
      // arm() fires immediately — the interval already elapsed.
      remainingMs = 0;
      void tick();
    }, delay);
  }

  async function tick() {
    if (stopped || !deps.isVisible() || inFlight) return;
    inFlight = true;
    try {
      await deps.refresh();
      remainingMs = AUTO_REFRESH_INTERVAL_MS;
    } catch (e) {
      // Transient failures retry sooner so a short blip does not burn a full window.
      console.warn("Auto-refresh failed", e);
      remainingMs = AUTO_REFRESH_RETRY_MS;
    } finally {
      inFlight = false;
      if (!stopped && deps.isVisible()) arm();
    }
  }

  function onVisibility() {
    if (stopped) return;
    if (deps.isVisible()) arm();
    else pauseCountdown();
  }

  const unsubVisibility = deps.onVisibilityChange(onVisibility);
  if (deps.isVisible()) arm();

  return () => {
    stopped = true;
    pauseCountdown();
    unsubVisibility();
  };
}
