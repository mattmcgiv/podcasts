import { useEffect, useState } from "react";
import { Api } from "../api";
import { Artwork } from "../components/Artwork";
import { onEpisodesChanged } from "../events";
import { navigate } from "../router";
import type { Show } from "../types";
import { SettingsSheet } from "./SettingsSheet";

export function ShowsView() {
  const [shows, setShows] = useState<Show[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(false);

  useEffect(() => {
    let live = true;
    const load = () =>
      Api.shows()
        .then((s) => live && setShows(s))
        .catch((e) => live && setError(e instanceof Error ? e.message : String(e)));
    void load();
    const off = onEpisodesChanged(() => void load());
    return () => {
      live = false;
      off();
    };
  }, []);

  return (
    <section className="view">
      <header className="view-header">
        <h1>Shows</h1>
        <button className="icon-btn" onClick={() => setSettingsOpen(true)} aria-label="Settings">
          <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden>
            <circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" strokeWidth="2" />
            <path
              d="M19 12a7 7 0 00-.1-1.2l2-1.5-2-3.4-2.3 1a7 7 0 00-2-1.2L14.2 3H9.8l-.4 2.7a7 7 0 00-2 1.2l-2.3-1-2 3.4 2 1.5A7 7 0 005 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.4 2.3-1a7 7 0 002 1.2l.4 2.7h4.4l.4-2.7a7 7 0 002-1.2l2.3 1 2-3.4-2-1.5c.1-.4.1-.8.1-1.2z"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.6"
            />
          </svg>
        </button>
      </header>

      {error && <p className="error">{error}</p>}
      {shows == null && !error && <p className="muted">Loading…</p>}
      {shows != null && shows.length === 0 && (
        <p className="empty">No subscriptions yet. Find podcasts in the Search tab or import an OPML in settings.</p>
      )}
      <ul className="show-list">
        {shows?.map((s) => (
          <li key={s.id}>
            <button className="show-row" onClick={() => navigate(`#/shows/${s.id}`)}>
              <Artwork src={s.image_url} size={56} />
              <span className="row-text">
                <span className="row-title">{s.title}</span>
                <span className="row-sub">
                  {s.unplayed_count > 0 ? `${s.unplayed_count} unplayed` : "all played"} ·{" "}
                  {s.episode_count} episodes
                </span>
              </span>
            </button>
          </li>
        ))}
      </ul>

      {settingsOpen && <SettingsSheet onClose={() => setSettingsOpen(false)} />}
    </section>
  );
}
