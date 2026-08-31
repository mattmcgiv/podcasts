export type AdRemovalStage =
  | "queued"
  | "downloading"
  | "downloaded"
  | "transcribing"
  | "classifying"
  | "ready"
  | "failed"
  | "cancelled";

export type AdRemovalBlockingReason =
  | "storage_limit"
  | "model_required"
  | "low_power"
  | "thermal_pressure"
  | "playback_active";

export interface EpisodeItem {
  id: number;
  podcast_id: number;
  podcast_title: string;
  podcast_image: string;
  title: string;
  audio_url: string;
  duration_secs: number | null;
  published_at: number;
  image_url: string;
  position_secs: number;
  played_at: number | null;
  ad_removal_state: "preparing" | "ad-free" | "unfiltered" | "failed";
  ad_removal_action: "prepare" | "retry" | null;
  /** Granular pipeline stage. Null when the backend only reports the coarse state. */
  ad_removal_stage: AdRemovalStage | null;
  /** Why an active stage is paused/waiting. Null when not blocked. */
  ad_removal_blocking_reason: AdRemovalBlockingReason | null;
  ad_removal_completed_windows?: number | null;
  ad_removal_total_windows?: number | null;
}

export interface EpisodeDetail extends EpisodeItem {
  notes_html: string;
  archived_at: number | null;
  show_notes: EpisodeShowNote[];
  ad_markers: EpisodeAdMarker[];
}

export interface EpisodeAdMarker {
  id: string;
  start_time: number;
}

export interface EpisodeShowNote {
  /** Stable transcript segment identifier chosen by the on-device classifier and validated by Swift. */
  id: string;
  /** Authoritative playback time in seconds, resolved locally from the transcript. */
  start_time: number;
  title: string;
  summary: string;
}

export interface Show {
  id: number;
  feed_url: string;
  title: string;
  description: string;
  image_url: string;
  site_url: string;
  episode_count: number;
  unplayed_count: number;
}

export interface Page<T> {
  items: T[];
  next_offset: number | null;
}

export interface DirectoryPodcast {
  title: string;
  author: string;
  feed_url: string;
  image_url: string;
  description: string;
  subscribed: boolean;
}

export interface SearchResults {
  directory_configured: boolean;
  podcasts: DirectoryPodcast[];
  episodes: EpisodeItem[];
}

export interface Follow {
  id: number;
  name: string;
  aliases: string[];
  last_checked_at: number | null;
  pending_count: number;
  accepted_count: number;
}

export interface DirectoryAppearance {
  source_episode_key: string;
  feed_url: string;
  feed_title: string;
  feed_image_url: string;
  guid: string;
  title: string;
  description: string;
  audio_url: string;
  duration_secs: number | null;
  published_at: number;
  image_url: string;
  evidence: string;
  confidence: "high" | "review";
}

export interface FollowCandidate {
  id: number;
  follow_id: number;
  appearance: DirectoryAppearance;
}

export interface Settings {
  speed: number;
  autoplay: boolean;
}

export interface AdRemovalCorrectionCount {
  podcast_id: number;
  podcast_title: string;
  count: number;
}

export type ClassifierUnavailableReason =
  | "device_not_eligible"
  | "apple_intelligence_not_enabled"
  | "model_not_ready"
  | "unknown";

export interface AdRemovalSettings {
  enabled: boolean;
  enrollment_cutoff: number | null;
  cloud_classifier_configured: boolean;
  model_repository: string;
  model_revision: string;
  model_total_bytes: number;
  model_downloaded_bytes: number;
  model_download_state: string;
  /** Live SystemLanguageModel availability. False until Apple Intelligence can run. */
  classifier_available: boolean;
  classifier_unavailable_reason: ClassifierUnavailableReason | null;
  episode_storage_bytes: number;
  episode_storage_limit_bytes: number;
  device_available_bytes: number;
  /** Minimum free device bytes required to start new ad-removal work. */
  minimum_free_bytes: number;
  corrections: AdRemovalCorrectionCount[];
}

export interface RefreshStatus {
  last_attempt_at: number | null;
  last_success_at: number | null;
  last_source: "manual" | "foreground" | "background" | null;
  last_refreshed: number;
  last_errors: number;
  /** A native refresh has started but has not yet persisted its result. */
  is_refreshing?: boolean;
}

export interface ShowDetailResponse {
  show: Show;
  episodes: Page<EpisodeItem>;
}

export type PlayContext = "recent" | "show";

/** Lightweight ad-removal status record returned by the batch statuses poll. */
export interface AdRemovalStatusItem {
  id: number;
  ad_removal_state: EpisodeItem["ad_removal_state"];
  ad_removal_action: EpisodeItem["ad_removal_action"];
  ad_removal_stage: EpisodeItem["ad_removal_stage"];
  ad_removal_blocking_reason: EpisodeItem["ad_removal_blocking_reason"];
  ad_removal_completed_windows: number | null;
  ad_removal_total_windows: number | null;
}

export interface AdRemovalStatusesPayload {
  items: AdRemovalStatusItem[];
}
