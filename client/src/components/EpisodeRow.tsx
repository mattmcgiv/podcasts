import { useEffect, useState } from "react";
import { Api } from "../api";
import { fmtDate, fmtRemaining, progressFraction } from "../lib";
import type { AdRemovalBlockingReason, AdRemovalStage, EpisodeItem } from "../types";
import { Artwork } from "./Artwork";

/** Bounded interval for polling an episode's ad-removal progress while nonterminal. */
export const AD_POLL_INTERVAL_MS = 8_000;

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
  const [adStage, setAdStage] = useState<AdRemovalStage | null>(item.ad_removal_stage);
  const [adBlocking, setAdBlocking] = useState<AdRemovalBlockingReason | null>(
    item.ad_removal_blocking_reason,
  );
  const [adAction, setAdAction] = useState(item.ad_removal_action);
  const [adBusy, setAdBusy] = useState(false);
  const [adError, setAdError] = useState<string | null>(null);

  useEffect(() => {
    setAdState(item.ad_removal_state);
    setAdStage(item.ad_removal_stage);
    setAdBlocking(item.ad_removal_blocking_reason);
    setAdAction(item.ad_removal_action);
  }, [
    item.ad_removal_action,
    item.ad_removal_state,
    item.ad_removal_stage,
    item.ad_removal_blocking_reason,
  ]);

  // While the row is in a nonterminal ad-removal stage, poll the existing
  // episode-detail API so backend stage/blocking/action changes appear without
  // navigation. Polling is single-flight: the next request is scheduled only
  // after the prior one settles, so at most one detail request is in flight per
  // row and an older response can never apply after a newer one. Any same-id
  // prop change (stage/blocking/action/state) re-runs this effect, which
  // invalidates the active generation so a stale in-flight poll cannot
  // overwrite newer props. Stop polling once terminal (ad-free, failed,
  // unfiltered) or the row unmounts. Transient poll errors never replace the
  // visible row state; they just reschedule.
  useEffect(() => {
    if (isTerminalAdState(adState)) return;
    let active = true;
    let generation = 0;
    let timer: number | undefined;
    const schedule = () => {
      if (!active) return;
      timer = window.setTimeout(tick, AD_POLL_INTERVAL_MS);
    };
    const tick = () => {
      const mine = ++generation;
      void Api.episode(item.id)
        .then((detail) => {
          if (!active || mine !== generation) return;
          setAdState(detail.ad_removal_state);
          setAdStage(detail.ad_removal_stage);
          setAdBlocking(detail.ad_removal_blocking_reason);
          setAdAction(detail.ad_removal_action);
          schedule();
        })
        .catch(() => {
          // Keep the last visible state; a transient poll error must not break the row.
          if (!active) return;
          schedule();
        });
    };
    schedule();
    return () => {
      active = false;
      if (timer !== undefined) window.clearTimeout(timer);
    };
    // Re-run on any same-id prop advance so a stale in-flight poll is invalidated.
  }, [
    adState,
    item.id,
    item.ad_removal_state,
    item.ad_removal_stage,
    item.ad_removal_blocking_reason,
    item.ad_removal_action,
  ]);

  async function runAdRemovalAction() {
    if (!adAction || adBusy) return;
    setAdBusy(true);
    setAdError(null);
    try {
      const result =
        adAction === "retry"
          ? await Api.retryAdRemoval(item.id)
          : await Api.prepareAdRemoval(item.id);
      // Use the returned stage immediately instead of collapsing to generic Preparing.
      setAdStage(result.stage as AdRemovalStage);
      setAdBlocking(null);
      setAdState(stageToCoarseState(result.stage as AdRemovalStage));
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
            {adStageLabel(adState, adStage, adBlocking)}
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
          className={`ad-removal-action${adAction === "retry" ? " ad-removal-retry" : ""}`}
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

function isTerminalAdState(state: EpisodeItem["ad_removal_state"]): boolean {
  return state === "ad-free" || state === "failed" || state === "unfiltered";
}

function stageToCoarseState(stage: AdRemovalStage): EpisodeItem["ad_removal_state"] {
  switch (stage) {
    case "ready":
      return "ad-free";
    case "failed":
      return "failed";
    // The backend cancelled job stage maps to the user-facing Unfiltered state.
    case "cancelled":
      return "unfiltered";
    default:
      return "preparing";
  }
}

function adStageLabel(
  state: EpisodeItem["ad_removal_state"],
  stage: AdRemovalStage | null,
  blocking: AdRemovalBlockingReason | null,
): string {
  // Terminal states always surface their own wording so Failed stays obvious.
  if (state === "failed" || stage === "failed") return "Failed";
  if (state === "ad-free" || stage === "ready") return "Ad-free";
  // A cancelled job stage is deliberately rendered as the Unfiltered state.
  if (state === "unfiltered" || stage === "cancelled") return "Unfiltered";

  // An active stage may be paused/waiting; the blocking reason overrides wording.
  if (blocking) {
    switch (blocking) {
      case "storage_limit":
        return "Paused · low storage";
      case "model_required":
        return "Waiting for model";
      case "low_power":
        return "Paused · low power";
      case "thermal_pressure":
        return "Paused · thermal";
      case "playback_active":
        return "Paused during playback";
    }
  }

  switch (stage) {
    case "queued":
      return "Queued";
    case "downloading":
      return "Downloading";
    case "downloaded":
      return "Downloaded";
    case "transcribing":
      return "Transcribing";
    case "classifying":
      return "Finding ads";
    default:
      // No granular stage reported; fall back to the coarse Preparing label.
      return "Preparing";
  }
}
