import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Api } from "../api";
import { EpisodeRow } from "../components/EpisodeRow";
import { APP_NAME } from "../config";
import { emitEpisodesChanged, onEpisodesChanged } from "../events";
import { useList } from "../hooks";
import { usePlayer } from "../player";
import { onDeviceClassifierCopy } from "../lib";
import { refreshFeeds } from "../refreshFeeds";
import type { AdRemovalSettings, AdRemovalStage, EpisodeItem, RefreshStatus } from "../types";
import type { AdRemovalStatusItem } from "../types";

function formatGB(bytes: number): string {
  const gb = Math.max(0, bytes) / 1_000_000_000;
  return `${gb.toFixed(2).replace(/\.?0+$/, "")} GB`;
}

function formatLatestRefresh(status: RefreshStatus | null): string {
  if (status?.is_refreshing && status.last_success_at == null) return "Refreshing feeds…";
  if (status?.last_success_at == null) return "Latest feed refresh: Not yet";
  const when = new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(status.last_success_at * 1000));
  if (status.is_refreshing) return `Refreshing feeds · Latest feed refresh: ${when}`;
  return `Latest feed refresh: ${when}`;
}

/** Bounded interval for polling ad-removal settings so the banner can recover. */
export const AD_SETTINGS_POLL_INTERVAL_MS = 15_000;

/** Bounded interval for the lightweight batch ad-removal status poll that
 * replaces per-row full-detail polling. One cycle covers every active row. */
export const AD_STATUS_POLL_INTERVAL_MS = 8_000;

/** Keep a removed row from exposing a different episode to the tail of the
 * same rapid tap/double-tap interaction. */
export const MARK_PLAYED_REFLOW_GUARD_MS = 1_000;

/** Backend caps batch statuses at 50 episode ids per request. */
const AD_STATUS_BATCH_MAX = 50;

function isTerminalAdState(state: EpisodeItem["ad_removal_state"]): boolean {
  return state === "ad-free" || state === "failed" || state === "unfiltered";
}

function stageToCoarseState(stage: AdRemovalStage): EpisodeItem["ad_removal_state"] {
  switch (stage) {
    case "ready":
      return "ad-free";
    case "failed":
      return "failed";
    // The backend cancelled job stage maps to the user-facing Unfiltered state.
    case "cancelled":
      return "unfiltered";
    default:
      return "preparing";
  }
}

/** Apply a lightweight status over the current backing EpisodeItem, preserving
 * all non-status fields (title, audio URL, position, …) from the backing row. */
function applyStatus(item: EpisodeItem, status: AdRemovalStatusItem): EpisodeItem {
  return {
    ...item,
    ad_removal_state: status.ad_removal_state,
    ad_removal_action: status.ad_removal_action,
    ad_removal_stage: status.ad_removal_stage,
    ad_removal_blocking_reason: status.ad_removal_blocking_reason,
    ad_removal_completed_windows: status.ad_removal_completed_windows,
    ad_removal_total_windows: status.ad_removal_total_windows,
  };
}

/** Generation-scoped status overlay. Statuses are only applied when the backing
 * `items` object they were written against is still the current backing list
 * (`sourceItems === items`). When the backing list is replaced (reload,
 * pagination, mark-played), any retained patch becomes inert immediately — no
 * setState during render is needed — so a fresh generation (including a
 * terminal-to-active same-id reload) is never masked by old status patches. */
interface StatusPatch {
  sourceItems: EpisodeItem[] | null;
  statuses: Map<number, AdRemovalStatusItem>;
}

const EMPTY_PATCH: StatusPatch = { sourceItems: null, statuses: new Map() };

export function RecentView() {
  const list = useList<EpisodeItem>(Api.recent);
  const player = usePlayer();
  const [sortAscending, setSortAscending] = useState(true);
  const [adSettings, setAdSettings] = useState<AdRemovalSettings | null>(null);
  const [refreshStatus, setRefreshStatus] = useState<RefreshStatus | null>(null);
  const [checkingForEpisodes, setCheckingForEpisodes] = useState(false);
  const [checkStatus, setCheckStatus] = useState<string | null>(null);
  const markPlayedGuardUntilRef = useRef(0);

  const items = list.items;

  // Ref to the current backing items, updated during render. Deferred poll
  // responses check this ref against the exact `expectedItems` object captured
  // when their cycle started, so a backing-list replacement invalidates an
  // in-flight response immediately — without waiting for a follow-up render.
  const itemsRef = useRef(items);
  itemsRef.current = items;

  // Lightweight, generation-scoped ad-removal status overlay keyed by episode
  // id. Only status fields are stored; non-status fields always come from the
  // current backing EpisodeItem.
  const [statusPatch, setStatusPatch] = useState<StatusPatch>(EMPTY_PATCH);

  const mergePatch = useCallback((entries: Iterable<AdRemovalStatusItem>) => {
    setStatusPatch((prev) => {
      // If the backing list changed since this patch was last written, discard
      // all old-generation statuses and start from a clean map.
      const base =
        itemsRef.current === prev.sourceItems
          ? prev.statuses
          : new Map<number, AdRemovalStatusItem>();
      let next = base;
      for (const status of entries) {
        if (next === base) next = new Map(base);
        next.set(status.id, status);
      }
      if (next === base && itemsRef.current === prev.sourceItems) return prev;
      return { sourceItems: itemsRef.current, statuses: next };
    });
  }, []);

  const enrichedItems = useMemo<EpisodeItem[] | null>(() => {
    if (items == null) return null;
    // Only apply the overlay when it was written against the exact current
    // backing list; otherwise the patch is inert and fresh backing fields win.
    if (statusPatch.sourceItems !== items || statusPatch.statuses.size === 0) return items;
    return items.map((item) => {
      const status = statusPatch.statuses.get(item.id);
      return status ? applyStatus(item, status) : item;
    });
  }, [items, statusPatch]);

  const displayItems = useMemo<EpisodeItem[] | null>(() => {
    if (enrichedItems == null || player.current == null) return enrichedItems;
    return enrichedItems.map((item) =>
      item.id === player.current?.id
        ? {
            ...item,
            position_secs: player.position,
            duration_secs: player.duration > 0 ? player.duration : item.duration_secs,
          }
        : item,
    );
  }, [enrichedItems, player.current, player.position, player.duration]);

  const sortedItems = useMemo(
    () => displayItems?.slice().sort((a, b) => compareByReleaseDate(a, b, sortAscending)) ?? null,
    [displayItems, sortAscending],
  );

  // Native foreground refreshes emit the same episode-change event used by
  // manual refreshes, keeping this informational timestamp current without a
  // separate polling loop. Status failures never block the Listen view.
  useEffect(() => {
    let active = true;
    const load = () => {
      void Api.refreshStatus()
        .then((status) => {
          if (active) setRefreshStatus(status);
        })
        .catch(() => {});
    };
    load();
    const unsubscribe = onEpisodesChanged(load);
    return () => {
      active = false;
      unsubscribe();
    };
  }, []);

  // Fetch ad-removal settings on mount and poll on a bounded, single-flight
  // schedule so the low-storage banner can recover without a reload. The next
  // request is scheduled only after the prior one settles, so settings requests
  // never overlap and a stale/unmounted response cannot apply. Optional
  // failures must never break Listen; they reschedule and keep last-known state.
  useEffect(() => {
    let active = true;
    let timer: number | undefined;
    const schedule = () => {
      if (!active) return;
      timer = window.setTimeout(load, AD_SETTINGS_POLL_INTERVAL_MS);
    };
    const load = () => {
      void Api.adRemovalSettings()
        .then((next) => {
          if (!active) return;
          setAdSettings(next);
          schedule();
        })
        .catch(() => {
          // Keep the last known settings so a transient failure does not flip the banner.
          if (!active) return;
          schedule();
        });
    };
    load();
    return () => {
      active = false;
      if (timer !== undefined) window.clearTimeout(timer);
    };
  }, []);

  const activeIds = useMemo(
    () =>
      (enrichedItems ?? [])
        .filter((item) => !isTerminalAdState(item.ad_removal_state))
        .map((item) => item.id),
    [enrichedItems],
  );
  const activeKey = activeIds.join(",");

  // Refs to the latest enriched items and active id set so the polling effect
  // can read current state at apply time without re-running on every merge.
  const enrichedRef = useRef(enrichedItems);
  enrichedRef.current = enrichedItems;
  const activeIdsRef = useRef(activeIds);
  activeIdsRef.current = activeIds;

  // One bounded, lightweight batch status poll cycle for every visible active
  // row. The effect depends directly on `items` so React runs cleanup on the
  // replacement commit (cancelling any pending/in-flight poll), and on
  // `activeKey` so a status change that alters the active set restarts it. The
  // effect captures the exact backing `items` object as `expectedItems`; every
  // deferred response checks `itemsRef.current === expectedItems` before
  // applying, so a same-id active-to-active replacement invalidates an older
  // response immediately (in the same flush), not via a later generation bump.
  // Within a cycle, active ids are split into <=50-id batches sent sequentially
  // (never overlapping); after the cycle settles, the next cycle is scheduled 8s
  // out. Transient errors preserve visible state and reschedule without overlap.
  useEffect(() => {
    if (activeIdsRef.current.length === 0) return; // nothing active; stop polling
    const expectedItems = items;
    let active = true;
    let timer: number | undefined;

    const scheduleNextCycle = () => {
      if (!active) return;
      timer = window.setTimeout(runCycle, AD_STATUS_POLL_INTERVAL_MS);
    };

    const isCurrent = () =>
      active && itemsRef.current === expectedItems;

    // Process bounded chunks sequentially via recursion so at most one status
    // request is in flight at a time (no overlapping requests, no await-in-loop).
    const runCycle = (): Promise<void> => {
      const ids = activeIdsRef.current.slice();
      const step = (i: number): Promise<void> => {
        if (!isCurrent()) return Promise.resolve();
        if (i >= ids.length) return Promise.resolve();
        const chunk = ids.slice(i, i + AD_STATUS_BATCH_MAX);
        return Api.adRemovalStatuses(chunk)
          .then((payload) => {
            if (!isCurrent()) return;
            // Apply only statuses for ids still active in the current state.
            const stillActive = new Set(activeIdsRef.current);
            const currentItems = enrichedRef.current ?? [];
            const byId = new Map(currentItems.map((it) => [it.id, it] as const));
            const entries: AdRemovalStatusItem[] = [];
            for (const status of payload.items) {
              if (!stillActive.has(status.id)) continue;
              if (!byId.has(status.id)) continue;
              entries.push(status);
            }
            if (entries.length > 0) mergePatch(entries);
            return step(i + AD_STATUS_BATCH_MAX);
          })
          .catch(() => {
            // Preserve visible state; abort the cycle. The next completion-
            // scheduled cycle will retry.
            if (!active) return;
          });
      };
      return step(0).finally(() => {
        if (isCurrent()) scheduleNextCycle();
      });
    };

    scheduleNextCycle();
    return () => {
      active = false;
      if (timer !== undefined) window.clearTimeout(timer);
    };
  }, [items, activeKey, mergePatch]);

  // When a user taps Prepare/Retry, merge the backend's returned stage into the
  // row immediately so the UI advances without waiting for the next batch poll.
  const onAdRemovalStage = useCallback(
    (id: number, stage: AdRemovalStage) => {
      const current = (enrichedItems ?? []).find((i) => i.id === id);
      if (!current) return;
      mergePatch([
        {
          id,
          ad_removal_state: stageToCoarseState(stage),
          ad_removal_stage: stage,
          ad_removal_action: null,
          ad_removal_blocking_reason: null,
          ad_removal_completed_windows: null,
          ad_removal_total_windows: null,
        },
      ]);
    },
    [enrichedItems, mergePatch],
  );

  const lowStorageBanner = useMemo(() => {
    if (!adSettings || !adSettings.enabled) return null;
    if (adSettings.device_available_bytes >= adSettings.minimum_free_bytes) return null;
    return adSettings;
  }, [adSettings]);

  const classifierPause = useMemo(() => {
    if (!adSettings || !adSettings.enabled || adSettings.classifier_available) return null;
    return onDeviceClassifierCopy(adSettings);
  }, [adSettings]);

  function markPlayed(item: EpisodeItem) {
    const now = Date.now();
    if (now < markPlayedGuardUntilRef.current) return;
    markPlayedGuardUntilRef.current = now + MARK_PLAYED_REFLOW_GUARD_MS;
    list.removeById(item.id);
    void Api.markPlayed(item.id)
      .then(() => emitEpisodesChanged())
      .catch(() => list.reload());
  }

  function checkForNewEpisodes() {
    if (checkingForEpisodes) return;
    setCheckingForEpisodes(true);
    setCheckStatus(null);
    void refreshFeeds()
      .then(async (result) => {
        emitEpisodesChanged();
        try {
          setRefreshStatus(await Api.refreshStatus());
        } catch {
          // The completed refresh remains useful even when its audit status is unavailable.
        }
        setCheckStatus(
          result.errors
            ? `Checked ${result.refreshed} feeds · ${result.errors} failed`
            : `Checked ${result.refreshed} feeds`,
        );
      })
      .catch((error) => setCheckStatus(error instanceof Error ? error.message : String(error)))
      .finally(() => setCheckingForEpisodes(false));
  }

  return (
    <section className="view">
      <header className="view-header">
        <h1>{APP_NAME}</h1>
        <button
          type="button"
          className="sort-toggle"
          role="switch"
          aria-checked={sortAscending}
          aria-label="Oldest first Newest"
          title={sortAscending ? "Oldest first" : "Newest"}
          onClick={() => setSortAscending((current) => !current)}
        >
          <span className={`sort-toggle-label${sortAscending ? " is-active" : ""}`}>
            Oldest first
          </span>
          <span className="sort-toggle-track" aria-hidden>
            <span className="sort-toggle-thumb" />
          </span>
          <span className={`sort-toggle-label${!sortAscending ? " is-active" : ""}`}>
            Newest
          </span>
        </button>
        <p className="feed-refresh-status">{formatLatestRefresh(refreshStatus)}</p>
      </header>

      {lowStorageBanner && (
        <p className="low-storage-banner" role="alert">
          Ad removal paused · {formatGB(lowStorageBanner.device_available_bytes)} free ·{" "}
          {formatGB(lowStorageBanner.minimum_free_bytes)} required
        </p>
      )}

      {classifierPause && (
        <p className="low-storage-banner" role="status">
          Ad finding paused · {classifierPause.status}
          {classifierPause.recovery ? ` ${classifierPause.recovery}` : ""}
        </p>
      )}

      {list.error && <p className="error">{list.error}</p>}
      {list.items == null && !list.error && <p className="muted">Loading…</p>}
      {list.items != null && list.items.length === 0 && (
        <div className="empty listen-empty-state">
          <p>Nothing new. Subscribe to podcasts in the Search tab, or check your feeds now.</p>
          <button
            className={`primary-action refresh-action${checkingForEpisodes ? " is-refreshing" : ""}`}
            onClick={checkForNewEpisodes}
            disabled={checkingForEpisodes}
          >
            {checkingForEpisodes ? (
              <>
                <span>Checking feeds</span>
                <span className="refresh-progress" role="progressbar" aria-label="Checking feeds" aria-valuetext="Checking feeds" />
              </>
            ) : "Check for new episodes"}
          </button>
          {checkStatus && <p className="status" role="status">{checkStatus}</p>}
        </div>
      )}
      <ul className="episode-list">
        {sortedItems?.map((item) => (
          <EpisodeRow
            key={item.id}
            item={item}
            onPlay={(ep) => player.playEpisode(ep, "recent")}
            actionLabel="Mark played"
            onAction={markPlayed}
            onAdRemovalStage={onAdRemovalStage}
          />
        ))}
      </ul>
      {list.hasMore && list.items != null && (
        <button className="load-more" onClick={list.loadMore} disabled={list.loading}>
          {list.loading ? "Loading…" : "Load more"}
        </button>
      )}
    </section>
  );
}

function compareByReleaseDate(a: EpisodeItem, b: EpisodeItem, ascending: boolean): number {
  const direction = ascending ? 1 : -1;
  return (a.published_at - b.published_at || a.id - b.id) * direction;
}
