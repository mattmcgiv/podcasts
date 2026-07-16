import { useEffect, useState } from "react";
import { Api } from "../api";
import { fmtDate, fmtRemaining, progressFraction } from "../lib";
import type { EpisodeItem } from "../types";
import { Artwork } from "./Artwork";

interface Props {
  item: EpisodeItem;
  onPlay: (item: EpisodeItem) => void;
  /** The right-side action: mark played (Listen), unmark (Played), or add to Listen (Show). */
  actionLabel: string;
  onAction: (item: EpisodeItem) => void;
  actionDone?: boolean;
  actionIcon?: "check" | "plus";
  showPodcast?: boolean;
}

export function EpisodeRow({
  item,
  onPlay,
  actionLabel,
  onAction,
  actionDone,
  actionIcon = "check",
  showPodcast = true,
}: Props) {
  const progress = progressFraction(item);
  const [adState, setAdState] = useState(item.ad_removal_state);
  const [adAction, setAdAction] = useState(item.ad_removal_action);
  const [adBusy, setAdBusy] = useState(false);
  const [adError, setAdError] = useState<string | null>(null);

  useEffect(() => {
    setAdState(item.ad_removal_state);
    setAdAction(item.ad_removal_action);
  }, [item.ad_removal_action, item.ad_removal_state]);

  async function runAdRemovalAction() {
    if (!adAction || adBusy) return;
    setAdBusy(true);
    setAdError(null);
    try {
      if (adAction === "retry") await Api.retryAdRemoval(item.id);
      else await Api.prepareAdRemoval(item.id);
      setAdState("preparing");
      setAdAction(null);
    } catch (error) {
      setAdError(error instanceof Error ? error.message : String(error));
    } finally {
      setAdBusy(false);
    }
  }

  return (
    <li className={`episode-row${item.played_at ? " is-played" : ""}`}>
      <button className="row-main" onClick={() => onPlay(item)}>
        <Artwork src={item.image_url || item.podcast_image} size={56} />
        <span className="row-text">
          <span className="row-title">{item.title}</span>
          {showPodcast && <span className="row-sub">{item.podcast_title}</span>}
          <span className="row-meta">
            {fmtDate(item.published_at)}
            {fmtRemaining(item) && <> · {fmtRemaining(item)}</>}
          </span>
          <span className={`ad-removal-state is-${adState}`}>
            {adStateLabel(adState)}
          </span>
          {adError && <span className="ad-removal-error">{adError}</span>}
          {progress > 0 && !item.played_at && (
            <span className="row-progress" role="progressbar" aria-valuenow={Math.round(progress * 100)}>
              <span style={{ width: `${progress * 100}%` }} />
            </span>
          )}
        </span>
      </button>
      {adAction && (
        <button
          type="button"
          className="ad-removal-action"
          aria-label={adAction === "retry" ? "Retry ad-free preparation" : "Prepare ad-free"}
          title={adAction === "retry" ? "Retry ad-free preparation" : "Prepare ad-free"}
          disabled={adBusy}
          onClick={() => void runAdRemovalAction()}
        >
          {adBusy ? "…" : adAction === "retry" ? "Retry" : "Prepare"}
        </button>
      )}
      <button
        className={`row-action${actionDone ? " done" : ""}`}
        aria-label={actionLabel}
        title={actionLabel}
        onClick={() => onAction(item)}
      >
        <svg viewBox="0 0 24 24" width="26" height="26" aria-hidden>
          <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" strokeWidth="1.8" />
          {actionIcon === "plus" ? (
            <>
              <path d="M12 7v10" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
              <path d="M7 12h10" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
            </>
          ) : (
            <path d="M7.5 12.5l3 3 6-6.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
          )}
        </svg>
      </button>
    </li>
  );
}

function adStateLabel(state: EpisodeItem["ad_removal_state"]): string {
  switch (state) {
    case "preparing": return "Preparing";
    case "ad-free": return "Ad-free";
    case "failed": return "Failed";
    case "unfiltered": return "Unfiltered";
  }
}
