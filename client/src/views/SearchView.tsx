import { useRef, useState, type FormEvent } from "react";
import { Api } from "../api";
import { Artwork } from "../components/Artwork";
import { EpisodeRow } from "../components/EpisodeRow";
import { emitEpisodesChanged } from "../events";
import { usePlayer } from "../player";
import type { DirectoryPodcast, SearchResults } from "../types";

export function SearchView() {
  const [q, setQ] = useState("");
  const [results, setResults] = useState<SearchResults | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const player = usePlayer();

  async function submit(e: FormEvent) {
    e.preventDefault();
    const query = q.trim();
    if (!query || busy) return;
    setBusy(true);
    setError(null);
    try {
      setResults(await Api.search(query));
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="view">
      <header className="view-header">
        <h1>Search</h1>
      </header>
      <form className="search-form" onSubmit={(e) => void submit(e)}>
        <div className="search-input-wrap">
          <input
            ref={inputRef}
            type="search"
            placeholder="Podcasts and your episodes"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            aria-label="Search"
          />
          {q !== "" && (
            <button
              type="button"
              className="search-clear"
              aria-label="Clear search"
              onClick={() => {
                setQ("");
                inputRef.current?.focus();
              }}
            >
              <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden>
                <circle cx="12" cy="12" r="10" fill="currentColor" opacity="0.22" />
                <path
                  d="M8.6 8.6l6.8 6.8M15.4 8.6l-6.8 6.8"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  fill="none"
                />
              </svg>
            </button>
          )}
        </div>
        <button type="submit" disabled={busy || !q.trim()}>
          {busy ? "…" : "Search"}
        </button>
      </form>
      {error && <p className="error">{error}</p>}

      {results && (
        <>
          <h2 className="section-title">Podcasts</h2>
          {!results.directory_configured && (
            <p className="muted">
              Directory search is off — add Podcast Index keys to the server, or paste an RSS URL
              in Shows → settings.
            </p>
          )}
          {results.directory_configured && results.podcasts.length === 0 && (
            <p className="muted">No podcasts found.</p>
          )}
          <ul className="podcast-results">
            {results.podcasts.map((p) => (
              <DirectoryRow key={p.feed_url} podcast={p} />
            ))}
          </ul>

          <h2 className="section-title">Your episodes</h2>
          {results.episodes.length === 0 && <p className="muted">No matches in your library.</p>}
          <ul className="episode-list">
            {results.episodes.map((item) => (
              <EpisodeRow
                key={item.id}
                item={item}
                onPlay={(ep) => player.playEpisode(ep, "recent")}
                actionLabel={item.played_at ? "Mark unplayed" : "Mark played"}
                onAction={(ep) =>
                  void (item.played_at ? Api.unmarkPlayed(ep.id) : Api.markPlayed(ep.id))
                    .then(emitEpisodesChanged)
                    .catch(() => {})
                }
                actionDone={item.played_at != null}
              />
            ))}
          </ul>
        </>
      )}
    </section>
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
    } catch (err) {
      setState("idle");
      setError(err instanceof Error ? err.message : String(err));
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
      <button
        className={`subscribe-btn${state === "done" ? " done" : ""}`}
        disabled={state !== "idle"}
        onClick={() => void subscribe()}
      >
        {state === "done" ? "Subscribed" : state === "busy" ? "…" : "Subscribe"}
      </button>
    </li>
  );
}
