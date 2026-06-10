import { useState } from "react";
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
  const [refreshing, setRefreshing] = useState(false);

  async function refresh() {
    if (refreshing) return;
    setRefreshing(true);
    try {
      await Api.refresh();
      emitEpisodesChanged();
    } catch {
      // surfaced on next manual attempt; lists stay as they were
    } finally {
      setRefreshing(false);
    }
  }

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
          className={`icon-btn${refreshing ? " spinning" : ""}`}
          onClick={() => void refresh()}
          aria-label="Refresh feeds"
        >
          <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden>
            <path
              d="M20 12a8 8 0 11-2.34-5.66M20 3v4h-4"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </button>
      </header>

      {list.error && <p className="error">{list.error}</p>}
      {list.items == null && !list.error && <p className="muted">Loading…</p>}
      {list.items != null && list.items.length === 0 && (
        <p className="empty">
          Nothing new. Subscribe to podcasts in the Search tab, or pull fresh episodes with the
          refresh button.
        </p>
      )}
      <ul className="episode-list">
        {list.items?.map((item) => (
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
