import { SPEEDS } from "../config";
import { fmtTime } from "../lib";
import { usePlayer } from "../player";
import { Artwork } from "./Artwork";
import { PauseIcon, PlayIcon } from "./MiniPlayer";

export function PlayerSheet() {
  const p = usePlayer();
  if (!p.current || !p.expanded) return null;
  const ep = p.current;

  return (
    <div className="player-sheet" role="dialog" aria-label="Player">
      <header className="sheet-header">
        <button className="icon-btn" onClick={() => p.setExpanded(false)} aria-label="Minimize player">
          <svg viewBox="0 0 24 24" width="26" height="26" aria-hidden>
            <path d="M5 9l7 7 7-7" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>
        <span className="sheet-show">{ep.podcast_title}</span>
        <span className="sheet-spacer" />
      </header>

      <div className="sheet-body">
        <div className="sheet-art">
          <Artwork src={ep.image_url || ep.podcast_image} size={224} />
        </div>
        <h2 className="sheet-title">{ep.title}</h2>

        <input
          className="scrubber"
          type="range"
          min={0}
          max={Math.max(p.duration, p.position, 1)}
          step={1}
          value={Math.floor(p.position)}
          onChange={(e) => p.seekTo(Number(e.target.value))}
          aria-label="Seek"
        />
        <div className="time-row">
          <span>{fmtTime(p.position)}</span>
          <span>{p.duration > 0 ? `-${fmtTime(Math.max(0, p.duration - p.position))}` : "--:--"}</span>
        </div>

        <div className="controls-row">
          <button className="icon-btn skip" onClick={p.skipBack} aria-label="Back 15 seconds">
            <svg viewBox="0 0 24 24" width="34" height="34" aria-hidden>
              <path d="M11 8V4l-5 5 5 5v-4c3.3 0 6 2.7 6 6h2a8 8 0 00-8-8z" fill="currentColor" />
            </svg>
            <span className="skip-label">15</span>
          </button>
          <button className="play-big" onClick={p.toggle} aria-label={p.playing ? "Pause" : "Play"}>
            {p.playing ? <PauseIcon size={38} /> : <PlayIcon size={38} />}
          </button>
          <button className="icon-btn skip" onClick={p.skipForward} aria-label="Forward 30 seconds">
            <svg viewBox="0 0 24 24" width="34" height="34" aria-hidden>
              <path d="M13 8V4l5 5-5 5v-4c-3.3 0-6 2.7-6 6H5a8 8 0 018-8z" fill="currentColor" />
            </svg>
            <span className="skip-label">30</span>
          </button>
        </div>

        <div className="speed-row" role="group" aria-label="Playback speed">
          {SPEEDS.map((s) => (
            <button
              key={s}
              className={`chip${p.speed === s ? " active" : ""}`}
              onClick={() => p.setSpeed(s)}
            >
              {s}×
            </button>
          ))}
        </div>

        <div className="player-options">
          <label className="switch-row">
            <span>Autoplay next</span>
            <input
              type="checkbox"
              role="switch"
              checked={p.autoplay}
              onChange={(e) => p.setAutoplay(e.target.checked)}
            />
          </label>
          <button className="ghost-btn" onClick={() => void p.markPlayedAndClose()}>
            Mark played
          </button>
        </div>

        {ep.notes_html && (
          <div className="notes" dangerouslySetInnerHTML={{ __html: ep.notes_html }} />
        )}
      </div>
    </div>
  );
}
