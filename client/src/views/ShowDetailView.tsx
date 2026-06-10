import { useCallback, useEffect, useState } from "react";
import { Api } from "../api";
import { Artwork } from "../components/Artwork";
import { EpisodeRow } from "../components/EpisodeRow";
import { emitEpisodesChanged, onEpisodesChanged } from "../events";
import { usePlayer } from "../player";
import { navigate } from "../router";
import type { EpisodeItem, Show } from "../types";

export function ShowDetailView({ showId }: { showId: number }) {
  const [show, setShow] = useState<Show | null>(null);
  const [episodes, setEpisodes] = useState<EpisodeItem[] | null>(null);
  const [nextOffset, setNextOffset] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const player = usePlayer();

  const load = useCallback(
    async (offset: number) => {
      try {
        const r = await Api.show(showId, offset);
        setShow(r.show);
        setNextOffset(r.episodes.next_offset);
        setEpisodes((prev) =>
          offset === 0 || prev == null ? r.episodes.items : [...prev, ...r.episodes.items],
        );
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      }
    },
    [showId],
  );

  useEffect(() => {
    setEpisodes(null);
    setShow(null);
    void load(0);
    return onEpisodesChanged(() => void load(0));
  }, [load]);

  async function unsubscribe() {
    if (!show) return;
    if (!window.confirm(`Unsubscribe from “${show.title}”? Its episodes disappear from Pods.`)) return;
    try {
      await Api.unsubscribe(show.id);
      emitEpisodesChanged();
      navigate("#/shows");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  function togglePlayed(item: EpisodeItem) {
    const call = item.played_at ? Api.unmarkPlayed(item.id) : Api.markPlayed(item.id);
    void call.then(emitEpisodesChanged).catch(() => {});
  }

  return (
    <section className="view">
      <header className="view-header">
        <button className="icon-btn" onClick={() => navigate("#/shows")} aria-label="Back to shows">
          <svg viewBox="0 0 24 24" width="24" height="24" aria-hidden>
            <path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>
        <h1 className="ellipsis">{show?.title ?? "…"}</h1>
      </header>

      {error && <p className="error">{error}</p>}

      {show && (
        <div className="show-hero">
          <Artwork src={show.image_url} size={88} />
          <div className="show-hero-text">
            <p className="row-sub">
              {show.episode_count} episodes · {show.unplayed_count} unplayed
            </p>
            <button className="ghost-btn danger small" onClick={() => void unsubscribe()}>
              Unsubscribe
            </button>
          </div>
        </div>
      )}
      {show?.description && <p className="show-desc">{stripHtml(show.description)}</p>}

      {episodes == null && !error && <p className="muted">Loading…</p>}
      <ul className="episode-list">
        {episodes?.map((item) => (
          <EpisodeRow
            key={item.id}
            item={item}
            showPodcast={false}
            onPlay={(ep) => player.playEpisode(ep, "show")}
            actionLabel={item.played_at ? "Mark unplayed" : "Mark played"}
            onAction={togglePlayed}
            actionDone={item.played_at != null}
          />
        ))}
      </ul>
      {nextOffset != null && episodes != null && (
        <button className="load-more" onClick={() => void load(nextOffset)}>
          Load more
        </button>
      )}
    </section>
  );
}

function stripHtml(html: string): string {
  const div = document.createElement("div");
  div.innerHTML = html;
  return div.textContent ?? "";
}
