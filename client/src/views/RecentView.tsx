import { useMemo, useState } from "react";
import { Api } from "../api";
import { EpisodeRow } from "../components/EpisodeRow";
import { APP_NAME } from "../config";
import { emitEpisodesChanged } from "../events";
import { useList } from "../hooks";
import { usePlayer } from "../player";
import type { EpisodeItem } from "../types";

export function RecentView() {
  const list = useList<EpisodeItem>(Api.recent);
  const player = usePlayer();
  const [sortAscending, setSortAscending] = useState(true);
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
