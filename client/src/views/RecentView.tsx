import { useEffect, useMemo, useState } from "react";
import { Api } from "../api";
import { EpisodeRow } from "../components/EpisodeRow";
import { APP_NAME } from "../config";
import { emitEpisodesChanged } from "../events";
import { useList } from "../hooks";
import { usePlayer } from "../player";
import type { AdRemovalSettings, EpisodeItem } from "../types";

function formatGB(bytes: number): string {
  const gb = Math.max(0, bytes) / 1_000_000_000;
  return `${gb.toFixed(2).replace(/\.?0+$/, "")} GB`;
}

/** Bounded interval for polling ad-removal settings so the banner can recover. */
export const AD_SETTINGS_POLL_INTERVAL_MS = 15_000;

export function RecentView() {
  const list = useList<EpisodeItem>(Api.recent);
  const player = usePlayer();
  const [sortAscending, setSortAscending] = useState(true);
  const [adSettings, setAdSettings] = useState<AdRemovalSettings | null>(null);

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

  const lowStorageBanner = useMemo(() => {
    if (!adSettings || !adSettings.enabled) return null;
    if (adSettings.device_available_bytes >= adSettings.minimum_free_bytes) return null;
    return adSettings;
  }, [adSettings]);

  const sortedItems = useMemo(
    () => list.items?.slice().sort((a, b) => compareByReleaseDate(a, b, sortAscending)) ?? null,
    [list.items, sortAscending],
  );

  function markPlayed(item: EpisodeItem) {
    list.removeById(item.id);
    void Api.markPlayed(item.id)
      .then(() => emitEpisodesChanged())
      .catch(() => list.reload());
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
      </header>

      {lowStorageBanner && (
        <p className="low-storage-banner" role="alert">
          Ad removal paused · {formatGB(lowStorageBanner.device_available_bytes)} free ·{" "}
          {formatGB(lowStorageBanner.minimum_free_bytes)} required
        </p>
      )}

      {list.error && <p className="error">{list.error}</p>}
      {list.items == null && !list.error && <p className="muted">Loading…</p>}
      {list.items != null && list.items.length === 0 && (
        <p className="empty">
          Nothing new. Subscribe to podcasts in the Search tab. Feeds refresh
          automatically while Pods is open, or use Refresh all feeds in Settings.
        </p>
      )}
      <ul className="episode-list">
        {sortedItems?.map((item) => (
          <EpisodeRow
            key={item.id}
            item={item}
            onPlay={(ep) => player.playEpisode(ep, "recent")}
            actionLabel="Mark played"
            onAction={markPlayed}
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
