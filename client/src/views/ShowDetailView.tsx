import { useCallback, useEffect, useState } from "react";
import { Api } from "../api";
import { Artwork } from "../components/Artwork";
import { EpisodeRow } from "../components/EpisodeRow";
import { emitEpisodesChanged, onEpisodesChanged } from "../events";
import { usePlayer } from "../player";
import { navigate } from "../router";
import type { EpisodeItem, Show } from "../types";

type ListenConfirmation = {
  id: number;
  message: string;
  phase: "visible" | "leaving";
};

export function ShowDetailView({ showId }: { showId: number }) {
  const [show, setShow] = useState<Show | null>(null);
  const [episodes, setEpisodes] = useState<EpisodeItem[] | null>(null);
  const [nextOffset, setNextOffset] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [searchItems, setSearchItems] = useState<EpisodeItem[] | null>(null);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [listenConfirmation, setListenConfirmation] = useState<ListenConfirmation | null>(null);
  const player = usePlayer();
  const trimmedSearch = searchQuery.trim();
  const isSearching = trimmedSearch.length > 0;

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

  useEffect(() => {
    if (!trimmedSearch) {
      setSearchItems(null);
      setSearchError(null);
      return;
    }

    let active = true;
    setSearchItems(null);
    setSearchError(null);
    void Api.showSearch(showId, trimmedSearch)
      .then((page) => {
        if (active) setSearchItems(page.items);
      })
      .catch((e) => {
        if (active) setSearchError(e instanceof Error ? e.message : String(e));
      });
    return () => {
      active = false;
    };
  }, [showId, trimmedSearch]);

  useEffect(() => {
    if (!listenConfirmation) return;
    if (listenConfirmation.phase === "leaving") {
      const removeTimer = window.setTimeout(() => {
        setListenConfirmation((current) => (current?.id === listenConfirmation.id ? null : current));
      }, 180);
      return () => window.clearTimeout(removeTimer);
    }

    const exitTimer = window.setTimeout(() => {
      setListenConfirmation((current) =>
        current?.id === listenConfirmation.id ? { ...current, phase: "leaving" } : current,
      );
    }, 3000);
    return () => window.clearTimeout(exitTimer);
  }, [listenConfirmation]);

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

  function addToListen(item: EpisodeItem) {
    void Api.unmarkPlayed(item.id)
      .then(() => {
        setListenConfirmation((current) => ({
          id: (current?.id ?? 0) + 1,
          message: `${item.title} added to Listen`,
          phase: "visible",
        }));
        emitEpisodesChanged();
      })
      .catch((e) => setError(e instanceof Error ? e.message : String(e)));
  }

  const visibleEpisodes = isSearching ? searchItems : episodes;

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

      {listenConfirmation && (
        <div
          key={listenConfirmation.id}
          className={`top-confirmation is-${listenConfirmation.phase}`}
          role="status"
          aria-label="Add to Listen confirmation"
        >
          {listenConfirmation.message}
        </div>
      )}
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

      <form className="search-form show-search" onSubmit={(e) => e.preventDefault()}>
        <div className="search-input-wrap">
          <input
            type="search"
            aria-label="Search this show"
            placeholder="Search this show"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.currentTarget.value)}
          />
          {searchQuery && (
            <button
              className="search-clear"
              type="button"
              aria-label="Clear show search"
              onClick={() => setSearchQuery("")}
            >
              ×
            </button>
          )}
        </div>
      </form>

      {searchError && <p className="error">{searchError}</p>}
      {!isSearching && episodes == null && !error && <p className="muted">Loading…</p>}
      {isSearching && searchItems == null && !searchError && <p className="muted">Searching…</p>}
      {isSearching && searchItems != null && searchItems.length === 0 && <p className="empty">No episodes found.</p>}
      <ul className="episode-list">
        {visibleEpisodes?.map((item) => (
          <EpisodeRow
            key={item.id}
            item={item}
            showPodcast={false}
            onPlay={(ep) => player.playEpisode(ep, "show")}
            actionLabel="Add to Listen"
            onAction={addToListen}
            actionIcon="plus"
          />
        ))}
      </ul>
      {!isSearching && nextOffset != null && episodes != null && (
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
