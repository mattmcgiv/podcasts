import { usePlayer } from "../player";
import { isArticle } from "../articles";
import { Artwork } from "./Artwork";

export function MiniPlayer() {
  const p = usePlayer();
  if (!p.current || p.expanded) return null;
  const awaiting = p.starting && !p.playing;
  return (
    <div className="miniplayer">
      <button className="mini-main" onClick={() => p.setExpanded(true)} aria-label="Open player">
        <Artwork src={p.current.image_url || p.current.podcast_image} size={40} article={isArticle(p.current)} />
        <span className="mini-title episode-title-full">
          {p.cast.output === "mac" && p.cast.connected ? (
            <span className="mini-cast" aria-label="Playing on Mac">
              Mac ·{" "}
            </span>
          ) : null}
          {p.current.title}
        </span>
      </button>
      <button
        className={`mini-toggle${awaiting ? " is-starting" : ""}`}
        onClick={p.toggle}
        aria-label={p.playing ? "Pause" : "Play"}
        aria-busy={awaiting}
      >
        {awaiting ? <SpinnerIcon /> : p.playing ? <PauseIcon /> : <PlayIcon />}
      </button>
    </div>
  );
}

export function PlayIcon({ size = 26 }: { size?: number }) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} aria-hidden>
      <path d="M8 5.5v13l11-6.5z" fill="currentColor" />
    </svg>
  );
}

export function PauseIcon({ size = 26 }: { size?: number }) {
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} aria-hidden>
      <path d="M7 5h3.4v14H7zM13.6 5H17v14h-3.4z" fill="currentColor" />
    </svg>
  );
}

/** Shown on a play button while the engine is starting but not yet audible. */
export function SpinnerIcon({ size = 26 }: { size?: number }) {
  return (
    <svg className="play-spinner" viewBox="0 0 24 24" width={size} height={size} aria-hidden>
      <circle
        cx="12"
        cy="12"
        r="9"
        fill="none"
        stroke="currentColor"
        strokeWidth="2.4"
        strokeLinecap="round"
        strokeDasharray="42.4 14.2"
      />
    </svg>
  );
}
