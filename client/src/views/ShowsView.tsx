import { useEffect, useRef, useState } from "react";
import { Api } from "../api";
import { Artwork } from "../components/Artwork";
import { EpisodeRow } from "../components/EpisodeRow";
import { emitEpisodesChanged, onEpisodesChanged } from "../events";
import { usePlayer } from "../player";
import { navigate } from "../router";
import type { AdRemovalSettings, DirectoryPodcast, SearchResults, Show } from "../types";

export const SHOW_SEARCH_DEBOUNCE_MS = 300;

export function ShowsView() {
  const [shows, setShows] = useState<Show[] | null>(null);
  const [showsError, setShowsError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResults | null>(null);
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [adSettings, setAdSettings] = useState<AdRemovalSettings | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const searchQuery = query.trim();
  const searchActive = searchQuery.length >= 3;

  useEffect(() => {
    let live = true;
    const load = () =>
      Api.shows()
        .then((nextShows) => live && setShows(nextShows))
        .catch((error) => live && setShowsError(error instanceof Error ? error.message : String(error)));
    void load();
    void Api.adRemovalSettings()
      .then((next) => live && setAdSettings(next))
      .catch(() => {});
    const off = onEpisodesChanged(() => void load());
    return () => {
      live = false;
      off();
    };
  }, []);

  useEffect(() => {
    if (!searchActive) {
      setResults(null);
      setSearchError(null);
      setSearching(false);
      return;
    }

    let live = true;
    setSearching(true);
    setSearchError(null);
    const timer = window.setTimeout(() => {
      void Api.search(searchQuery)
        .then((nextResults) => {
          if (live) setResults(nextResults);
        })
        .catch((error) => {
          if (live) setSearchError(error instanceof Error ? error.message : String(error));
        })
        .finally(() => {
          if (live) setSearching(false);
        });
    }, SHOW_SEARCH_DEBOUNCE_MS);

    return () => {
      live = false;
      window.clearTimeout(timer);
    };
  }, [searchActive, searchQuery]);

  function clearSearch() {
    setQuery("");
    inputRef.current?.focus();
  }

  return (
    <section className="view">
      <header className="view-header">
        <h1>Shows</h1>
      </header>

      <div className="shows-search search-input-wrap">
        <input
          ref={inputRef}
          type="search"
          placeholder="Search podcasts and your episodes"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          aria-label="Search podcasts and your episodes"
        />
        {query !== "" && (
          <button type="button" className="search-clear" aria-label="Clear search" onClick={clearSearch}>
            <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden>
              <circle cx="12" cy="12" r="10" fill="currentColor" opacity="0.22" />
              <path d="M8.6 8.6l6.8 6.8M15.4 8.6l-6.8 6.8" stroke="currentColor" strokeWidth="2" strokeLinecap="round" fill="none" />
            </svg>
          </button>
        )}
      </div>

      {searchActive ? (
        <SearchResultsView
          results={results}
          searching={searching}
          error={searchError}
          playRequiresAdFree={adSettings?.listen_requires_ready === true}
        />
      ) : (
        <>
          <p className="shows-intro">You've subscribed to these feeds.</p>
          {showsError && <p className="error">{showsError}</p>}
          {shows == null && !showsError && <p className="muted">Loading…</p>}
          {shows != null && shows.length === 0 && (
            <p className="empty">No subscriptions yet. Search for podcasts above or import an OPML in Settings.</p>
          )}
          <ul className="show-list">
            {shows?.map((show) => (
              <li key={show.id}>
                <button className="show-row" onClick={() => navigate(`#/shows/${show.id}`)}>
                  <Artwork src={show.image_url} size={56} />
                  <span className="row-text">
                    <span className="row-title">{show.title}</span>
                    <span className="row-sub">
                      {show.unplayed_count > 0 ? `${show.unplayed_count} unplayed` : "all played"} · {show.episode_count} episodes
                    </span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  );
}

function SearchResultsView({
  results,
  searching,
  error,
  playRequiresAdFree,
}: {
  results: SearchResults | null;
  searching: boolean;
  error: string | null;
  playRequiresAdFree: boolean;
}) {
  const player = usePlayer();
  if (searching && results == null) return <p className="muted">Searching podcasts and episodes…</p>;
  if (error) return <p className="error">{error}</p>;
  if (!results) return null;

  return (
    <div className="shows-search-results">
      <h2 className="section-title">Podcasts</h2>
      {!results.directory_configured && (
        <p className="muted">Directory search is off — add Podcast Index keys and reinstall the app, or paste an RSS URL in Settings.</p>
      )}
      {results.directory_configured && results.podcasts.length === 0 && <p className="muted">No podcasts found.</p>}
      <ul className="podcast-results">
        {results.podcasts.map((podcast) => <DirectoryRow key={podcast.feed_url} podcast={podcast} />)}
      </ul>

      <h2 className="section-title">Your episodes</h2>
      {results.episodes.length === 0 && <p className="muted">No matches in your library.</p>}
      <ul className="episode-list">
        {results.episodes.map((item) => (
          <EpisodeRow
            key={item.id}
            item={item}
            onPlay={(episode) => player.playEpisode(episode, "recent")}
            playRequiresAdFree={playRequiresAdFree}
            actionLabel={item.played_at ? "Mark unplayed" : "Mark played"}
            onAction={(episode) =>
              void (item.played_at ? Api.unmarkPlayed(episode.id) : Api.markPlayed(episode.id))
                .then(emitEpisodesChanged)
                .catch(() => {})
            }
            actionDone={item.played_at != null}
          />
        ))}
      </ul>
    </div>
  );
}

function DirectoryRow({ podcast }: { podcast: DirectoryPodcast }) {
  const [state, setState] = useState<"idle" | "busy" | "done">(podcast.subscribed ? "done" : "idle");
  const [error, setError] = useState<string | null>(null);

  async function subscribe() {
    if (state !== "idle") return;
    setState("busy");
    setError(null);
    try {
      await Api.subscribe(podcast.feed_url);
      setState("done");
      emitEpisodesChanged();
    } catch (nextError) {
      setState("idle");
      setError(nextError instanceof Error ? nextError.message : String(nextError));
    }
  }

  return (
    <li className="podcast-row">
      <Artwork src={podcast.image_url} size={56} />
      <span className="row-text">
        <span className="row-title">{podcast.title}</span>
        <span className="row-sub">{podcast.author}</span>
        {error && <span className="error small">{error}</span>}
      </span>
      <button className={`subscribe-btn${state === "done" ? " done" : ""}`} disabled={state !== "idle"} onClick={() => void subscribe()}>
        {state === "done" ? "Subscribed" : state === "busy" ? "…" : "Subscribe"}
      </button>
    </li>
  );
}
