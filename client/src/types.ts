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
