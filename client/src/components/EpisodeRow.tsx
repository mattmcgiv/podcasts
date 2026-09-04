import { useEffect, useState } from "react";
import { Api } from "../api";
import { fmtDate, fmtRemaining, progressFraction } from "../lib";
import type { AdRemovalBlockingReason, AdRemovalStage, EpisodeItem } from "../types";
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
  /** Notified after a user-initiated prepare/retry succeeds with the backend's
   * returned stage, so the owning view can merge it into row state immediately
   * and invalidate any in-flight batch status poll. */
  onAdRemovalStage?: (id: number, stage: AdRemovalStage) => void;
  /** When true, Play is disabled until the episode is ad-free. */
  playRequiresAdFree?: boolean;
}

/** Small optimistic overlay derived from a returned prepare/retry stage. Used
 * only by non-Listen owners that do not pass `onAdRemovalStage`; it carries no
 * requests and is reset whenever authoritative ad-removal props change. */
interface LocalAdStatus {
  state: EpisodeItem["ad_removal_state"];
  stage: AdRemovalStage | null;
  blocking: AdRemovalBlockingReason | null;
  action: EpisodeItem["ad_removal_action"];
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

export function EpisodeRow({
  item,
  onPlay,
  actionLabel,
  onAction,
  actionDone,
  actionIcon = "check",
  showPodcast = true,
  onAdRemovalStage,
  playRequiresAdFree = false,
}: Props) {
  const progress = progressFraction(item);
  const [adBusy, setAdBusy] = useState(false);
  const [adError, setAdError] = useState<string | null>(null);
  // Local fallback overlay for non-Listen owners (no onAdRemovalStage). It is
  // reset to null whenever authoritative ad-removal props change so a parent
  // refresh always wins and stale optimistic data cannot linger.
  const [localAd, setLocalAd] = useState<LocalAdStatus | null>(null);
  useEffect(() => {
    setLocalAd(null);
  }, [
    item.ad_removal_state,
    item.ad_removal_stage,
    item.ad_removal_action,
    item.ad_removal_blocking_reason,
  ]);

  // When the owner delegates (Listen), authoritative props drive the display.
  // When the owner does not delegate, a local optimistic overlay from a returned
  // prepare/retry stage drives the display until authoritative props change.
  const effectiveState = localAd ? localAd.state : item.ad_removal_state;
  const effectiveStage = localAd ? localAd.stage : item.ad_removal_stage;
  const effectiveBlocking = localAd ? localAd.blocking : item.ad_removal_blocking_reason;
  const effectiveAction = localAd ? localAd.action : item.ad_removal_action;
  const playLocked = playRequiresAdFree && effectiveState !== "ad-free";
  const adWindowProgress =
    effectiveStage === "classifying" &&
    item.ad_removal_total_windows != null &&
    item.ad_removal_total_windows > 0
      ? Math.min(1, (item.ad_removal_completed_windows ?? 0) / item.ad_removal_total_windows)
      : null;

  async function runAdRemovalAction() {
    const action = effectiveAction;
    if (!action || adBusy) return;
    setAdBusy(true);
    setAdError(null);
    try {
      const result =
        action === "retry"
          ? await Api.retryAdRemoval(item.id)
          : await Api.prepareAdRemoval(item.id);
      if (onAdRemovalStage) {
        // Listen owner owns status merging; delegate the returned stage.
        onAdRemovalStage(item.id, result.stage as AdRemovalStage);
      } else {
        // Non-Listen owner: apply a small local optimistic overlay derived from
        // the returned stage (granular label, matching coarse state, null action
        // and blocking reason) so the row updates and the action button disappears.
        setLocalAd({
          state: stageToCoarseState(result.stage as AdRemovalStage),
          stage: result.stage as AdRemovalStage,
          blocking: null,
          action: null,
        });
      }
    } catch (error) {
      setAdError(error instanceof Error ? error.message : String(error));
    } finally {
      setAdBusy(false);
    }
  }

  return (
    <li className={`episode-row${item.played_at ? " is-played" : ""}${playLocked ? " is-play-locked" : ""}`}>
      <button
        className="row-main"
        disabled={playLocked}
        title={playLocked ? "Waiting for ad removal" : undefined}
        onClick={() => {
          if (playLocked) return;
          onPlay(item);
        }}
      >
        <Artwork src={item.image_url || item.podcast_image} size={56} />
        <span className="row-text">
          <span className="row-title episode-title-full">{item.title}</span>
          {showPodcast && <span className="row-sub">{item.podcast_title}</span>}
          <span className="row-meta">
            {fmtDate(item.published_at)}
            {fmtRemaining(item) && <> · {fmtRemaining(item)}</>}
          </span>
          <span
            className={`ad-removal-state is-${effectiveState}`}
            style={effectiveState === "ad-free" ? { color: "var(--text-dim)" } : undefined}
          >
            {adStageLabel(effectiveState, effectiveStage, effectiveBlocking)}
          </span>
          {adWindowProgress != null && (
            <span
              className="ad-classification-progress"
              role="progressbar"
              aria-label="Finding ads progress"
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={Math.round(adWindowProgress * 100)}
            >
              <span style={{ width: `${Math.max(4, adWindowProgress * 100)}%` }} />
            </span>
          )}
          {adError && <span className="ad-removal-error">{adError}</span>}
          {progress > 0 && !item.played_at && (
            <span className="row-progress" role="progressbar" aria-valuenow={Math.round(progress * 100)}>
              <span style={{ width: `${progress * 100}%` }} />
            </span>
          )}
        </span>
      </button>
      {effectiveAction && (
        <button
          type="button"
          className={`ad-removal-action${effectiveAction === "retry" ? " ad-removal-retry" : ""}`}
          aria-label={effectiveAction === "retry" ? "Retry ad-free preparation" : "Prepare ad-free"}
          title={effectiveAction === "retry" ? "Retry ad-free preparation" : "Prepare ad-free"}
          disabled={adBusy}
          onClick={() => void runAdRemovalAction()}
        >
          {adBusy ? "…" : effectiveAction === "retry" ? "Retry" : "Prepare"}
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
        return "Waiting for DeepSeek API key";
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
