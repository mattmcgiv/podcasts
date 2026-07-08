import { usePlayer } from "../player";
import { Artwork } from "./Artwork";

export function MiniPlayer() {
  const p = usePlayer();
  if (!p.current || p.expanded) return null;
  return (
    <div className="miniplayer">
      <button className="mini-main" onClick={() => p.setExpanded(true)} aria-label="Open player">
        <Artwork src={p.current.image_url || p.current.podcast_image} size={40} />
        <span className="mini-title">
          {p.cast.output === "mac" && p.cast.connected ? (
            <span className="mini-cast" aria-label="Playing on Mac">
              Mac ·{" "}
            </span>
          ) : null}
          {p.current.title}
        </span>
      </button>
      <button className="mini-toggle" onClick={p.toggle} aria-label={p.playing ? "Pause" : "Play"}>
        {p.playing ? <PauseIcon /> : <PlayIcon />}
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
