import { useEffect, useRef, useState } from "react";
import { SPEEDS } from "../config";
import { offlineEnabled } from "../offline/client";
import { fmtTime } from "../lib";
import { usePlayer } from "../player";
import { Artwork } from "./Artwork";
import { PauseIcon, PlayIcon } from "./MiniPlayer";

let nextSpeedInteraction = 1;

function speedCorrelationID(): string {
  return `speed-${Date.now().toString(36)}-${nextSpeedInteraction++}`;
}

/** Distance from the playhead to a chapter start: "+45 secs", "+3 mins", "+1hr 5mins". */
function fmtChapterDelta(secs: number): string {
  const total = Math.max(0, Math.round(secs));
  if (total < 60) {
    return `+${total} ${total === 1 ? "sec" : "secs"}`;
  }
  const minutes = Math.round(total / 60);
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours > 0) {
    return `+${hours} ${hours === 1 ? "hr" : "hrs"} ${rest} ${rest === 1 ? "min" : "mins"}`;
  }
  return `+${minutes} ${minutes === 1 ? "min" : "mins"}`;
}

export function PlayerSheet() {
  const p = usePlayer();
  const pendingSpeedInteraction = useRef<string | null>(null);
  const [adSkipToast, setAdSkipToast] = useState<{
    notice: NonNullable<typeof p.pendingAdSkip>;
    phase: "visible" | "leaving";
  } | null>(null);
  useEffect(() => {
    if (!p.pendingAdSkip) {
      setAdSkipToast(null);
      return;
    }
    setAdSkipToast({ notice: p.pendingAdSkip, phase: "visible" });
    const leaveTimer = window.setTimeout(() => {
      setAdSkipToast((current) => current ? { ...current, phase: "leaving" } : null);
    }, 9_840);
    const removeTimer = window.setTimeout(() => setAdSkipToast(null), 10_000);
    return () => {
      window.clearTimeout(leaveTimer);
      window.clearTimeout(removeTimer);
    };
  }, [p.pendingAdSkip]);
  if (!p.current || !p.expanded) return null;
  const ep = p.current;
  const showNotes = (ep.show_notes ?? []).filter(
    (note) => Number.isFinite(note.start_time) && note.start_time >= 0,
  );
  const chapters = [
    ...showNotes.map((note) => ({ ...note, isAd: false })),
    ...(ep.ad_markers ?? [])
      .filter((marker) => Number.isFinite(marker.start_time) && marker.start_time >= 0)
      .map((marker) => ({
        ...marker,
        title: "Ads",
        summary: "",
        isAd: true,
      })),
  ]
    .sort((a, b) => a.start_time - b.start_time || a.id.localeCompare(b.id))
    .filter((chapter, index, sorted) => (
      !chapter.isAd || index === 0 || !sorted[index - 1].isAd
    ));
  const nextChapter = showNotes
    .filter((chapter) => chapter.start_time > p.position)
    .sort((a, b) => a.start_time - b.start_time || a.id.localeCompare(b.id))[0];

  return (
    <div className="player-sheet" role="dialog" aria-label="Player">
      {adSkipToast && (
        <div
          className={`top-confirmation ad-skip-toast is-${adSkipToast.phase}`}
          role="status"
          aria-label="Ad skip notification"
        >
          <span>Skipped {fmtTime(adSkipToast.notice.skippedDuration)}</span>
          <button type="button" onClick={p.undoAdSkip} aria-label="Undo skipped section">
            Undo
          </button>
        </div>
      )}
      <header className="sheet-header">
        <button className="icon-btn" onClick={() => p.setExpanded(false)} aria-label="Minimize player">
          <svg viewBox="0 0 24 24" width="26" height="26" aria-hidden>
            <path d="M5 9l7 7 7-7" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>
        <span className="sheet-show">{ep.podcast_title}</span>
        <span className="sheet-spacer" />
      </header>

      <div className="sheet-body sheet-scroll-region">
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

        {p.initializing && (
          <div className="stream-initializing" role="status" aria-label="Loading audio">
            <span className="stream-pulse" aria-hidden />
            <span>Loading audio</span>
          </div>
        )}

        {nextChapter && (
          <button
            type="button"
            className="next-chapter-link"
            onClick={() => p.seekTo(nextChapter.start_time)}
          >
            <span className="next-chapter-prefix">Next:</span>{" "}{nextChapter.title}{" "}
            <span className="next-chapter-time">({fmtChapterDelta(nextChapter.start_time - p.position)})</span>
          </button>
        )}

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
              type="button"
              className={`chip speed-chip${p.speed === s ? " active" : ""}`}
              onPointerDown={() => {
                const correlationID = speedCorrelationID();
                pendingSpeedInteraction.current = correlationID;
                console.log(`speed_pointer_received correlation_id=${correlationID} requested_rate=${s}`);
              }}
              onClick={() => {
                const correlationID = pendingSpeedInteraction.current ?? speedCorrelationID();
                pendingSpeedInteraction.current = null;
                console.log(`speed_click correlation_id=${correlationID} requested_rate=${s}`);
                p.setSpeed(s, correlationID);
              }}
            >
              {s}×
            </button>
          ))}
        </div>

        <div className="player-options">
          {!offlineEnabled() && <div className="cast-row" role="group" aria-label="Audio output">
            <span className="cast-label">Play on</span>
            <div className="cast-choices">
              <button
                type="button"
                className={`chip${p.cast.output !== "mac" ? " active" : ""}`}
                onClick={() => p.setCastOutput("local")}
              >
                iPhone
              </button>
              <button
                type="button"
                className={`chip${p.cast.output === "mac" ? " active" : ""}`}
                onClick={() => p.setCastOutput("mac")}
                disabled={!p.cast.available && !p.cast.connected}
                title={
                  p.cast.available || p.cast.connected
                    ? p.cast.name ?? "Mac"
                    : "Open Pods Speaker on your Mac (same Wi‑Fi)"
                }
              >
                {p.cast.connected || p.cast.output === "mac"
                  ? "Mac"
                  : p.cast.available
                    ? "Mac"
                    : "Mac (offline)"}
              </button>
            </div>
            {p.cast.error && p.cast.output === "mac" && (
              <p className="cast-error" role="status">
                {p.cast.error}
              </p>
            )}
            {p.cast.connected && p.cast.output === "mac" && (
              <p className="cast-hint" role="status">
                Playing through Mac · progress saves on this phone
              </p>
            )}
          </div>}
          <div className="player-action-row">
            <button
              type="button"
              className="chip mark-played-btn"
              onClick={() => void p.markPlayedAndClose()}
            >
              Mark played
            </button>
            <button
              type="button"
              className="autoplay-toggle"
              role="switch"
              aria-checked={p.autoplay}
              aria-label="Autoplay next"
              onClick={() => p.setAutoplay(!p.autoplay)}
            >
              <span>Autoplay next</span>
              <span className="autoplay-toggle-track" aria-hidden>
                <span className="autoplay-toggle-thumb" />
              </span>
            </button>
          </div>
        </div>

        {(chapters.length > 0 || p.showNotesGenerating || p.showNotesError) && (
          <section className="show-notes" aria-labelledby="show-notes-title">
            <h3 id="show-notes-title">Chapters</h3>
            {p.showNotesGenerating && (
              <p className="show-notes-status" role="status">Generating show notes…</p>
            )}
            {p.showNotesError && !p.showNotesGenerating && (
              <div className="show-notes-error" role="alert">
                <span>{p.showNotesError}</span>
                <button type="button" onClick={p.retryShowNotes}>Retry</button>
              </div>
            )}
            {chapters.map((chapter) => (
              <button
                key={`${chapter.isAd ? "ad" : "note"}-${chapter.id}`}
                type="button"
                className={`show-note${chapter.isAd ? " is-ad" : ""}`}
                aria-label={`${fmtTime(chapter.start_time)} ${chapter.title}`}
                onClick={() => p.seekTo(chapter.start_time)}
              >
                <span className="show-note-time">{fmtTime(chapter.start_time)}</span>
                <span className="show-note-copy">
                  <strong>{chapter.title}</strong>
                  {chapter.summary && <span>{chapter.summary}</span>}
                </span>
              </button>
            ))}
          </section>
        )}
      </div>
    </div>
  );
}
