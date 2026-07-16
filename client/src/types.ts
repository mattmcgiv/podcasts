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
}

export interface EpisodeDetail extends EpisodeItem {
  notes_html: string;
  archived_at: number | null;
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

export interface Settings {
  speed: number;
  autoplay: boolean;
}

export interface AdRemovalCorrectionCount {
  podcast_id: number;
  podcast_title: string;
  count: number;
}

export interface AdRemovalSettings {
  enabled: boolean;
  enrollment_cutoff: number | null;
  model_repository: string;
  model_revision: string;
  model_total_bytes: number;
  model_downloaded_bytes: number;
  model_download_state: string;
  episode_storage_bytes: number;
  episode_storage_limit_bytes: number;
  device_available_bytes: number;
  corrections: AdRemovalCorrectionCount[];
}

export interface RefreshStatus {
  last_attempt_at: number | null;
  last_success_at: number | null;
  last_source: "manual" | "foreground" | "background" | null;
  last_refreshed: number;
  last_errors: number;
}

export interface ShowDetailResponse {
  show: Show;
  episodes: Page<EpisodeItem>;
}

export type PlayContext = "recent" | "show";
