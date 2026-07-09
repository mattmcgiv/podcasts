import { Api } from "./api";

export type RefreshResult = { refreshed: number; errors: number };

/**
 * Bound how long a single refresh may hold the coalescing lock.
 * Generous for multi-feed sequential pulls; aborts hung POSTs so the lock
 * cannot stick forever if the backend or network stalls.
 */
export const REFRESH_TIMEOUT_MS = 120_000;

/**
 * Module-level coalescing for concurrent POST /api/refresh callers
 * (auto-refresh timer + Settings "Refresh all feeds").
 * Distinct from startAutoRefresh's per-scheduler `inFlight`, which only
 * prevents double-arming the timer while a tick awaits this promise.
 */
let inFlight: Promise<RefreshResult> | null = null;

/**
 * Test-only: clear shared lock between cases.
 * No-op in production builds (import.meta.env.PROD) so the symbol cannot
 * disable coalescing if a compromised dependency calls it.
 */
export function resetRefreshFeedsForTests(): void {
  if (import.meta.env.PROD) return;
  inFlight = null;
}

/**
 * Call the feed-refresh API once at a time. Concurrent callers await the
 * same promise instead of issuing parallel POSTs. A hung fetch is aborted
 * after {@link REFRESH_TIMEOUT_MS} so the lock can release cleanly.
 */
export function refreshFeeds(): Promise<RefreshResult> {
  if (inFlight) return inFlight;

  inFlight = (async () => {
    let timeoutId: ReturnType<typeof setTimeout> | undefined;
    let settled = false;
    try {
      const controller = new AbortController();
      return await new Promise<RefreshResult>((resolve, reject) => {
        timeoutId = setTimeout(() => {
          // If Api.refresh already won the race, settled is true and abort is a no-op.
          if (settled) return;
          settled = true;
          controller.abort();
          reject(new Error(`Refresh timed out after ${REFRESH_TIMEOUT_MS / 1000}s`));
        }, REFRESH_TIMEOUT_MS);
        void Api.refresh({ signal: controller.signal }).then(
          (value) => {
            if (settled) return;
            settled = true;
            resolve(value);
          },
          (err: unknown) => {
            // Timeout path already settled+rejected the outer promise before abort.
            if (settled) return;
            settled = true;
            reject(err);
          },
        );
      });
    } finally {
      if (timeoutId != null) clearTimeout(timeoutId);
      inFlight = null;
    }
  })();

  return inFlight;
}
