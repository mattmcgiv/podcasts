import { Api } from "../api";
import { EpisodeRow } from "../components/EpisodeRow";
import { emitEpisodesChanged } from "../events";
import { useList } from "../hooks";
import { usePlayer } from "../player";
import type { EpisodeItem } from "../types";

export function PlayedView() {
  const list = useList<EpisodeItem>(Api.played);
  const player = usePlayer();

  function unmark(item: EpisodeItem) {
    list.removeById(item.id);
    void Api.unmarkPlayed(item.id)
      .then(() => emitEpisodesChanged())
      .catch(() => list.reload());
  }

  return (
    <section className="view">
      <header className="view-header">
        <h1>Played</h1>
      </header>
      {list.error && <p className="error">{list.error}</p>}
      {list.items == null && !list.error && <p className="muted">Loading…</p>}
      {list.items != null && list.items.length === 0 && (
        <p className="empty">Episodes you mark played end up here, so nothing is ever lost.</p>
      )}
      <ul className="episode-list">
        {list.items?.map((item) => (
          <EpisodeRow
            key={item.id}
            item={item}
            onPlay={(ep) => player.playEpisode(ep, "recent")}
            actionLabel="Mark unplayed"
            onAction={unmark}
            actionDone
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
