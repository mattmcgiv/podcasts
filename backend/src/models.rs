use serde::{Deserialize, Serialize};

pub const PAGE_SIZE: i64 = 50;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct EpisodeItem {
    pub id: i64,
    pub podcast_id: i64,
    pub podcast_title: String,
    pub podcast_image: String,
    pub title: String,
    pub audio_url: String,
    pub duration_secs: Option<i64>,
    pub published_at: i64,
    pub image_url: String,
    pub position_secs: f64,
    pub played_at: Option<i64>,
    pub ad_removal_state: String,
    pub ad_removal_action: Option<String>,
    pub ad_removal_stage: Option<String>,
    pub ad_removal_blocking_reason: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct EpisodeDetail {
    pub id: i64,
    pub podcast_id: i64,
    pub podcast_title: String,
    pub podcast_image: String,
    pub title: String,
    pub audio_url: String,
    pub duration_secs: Option<i64>,
    pub published_at: i64,
    pub image_url: String,
    pub position_secs: f64,
    pub played_at: Option<i64>,
    pub notes_html: String,
    pub archived_at: Option<i64>,
    pub ad_removal_state: String,
    pub ad_removal_action: Option<String>,
    pub ad_removal_stage: Option<String>,
    pub ad_removal_blocking_reason: Option<String>,
    #[serde(default)]
    pub show_notes: Vec<EpisodeShowNote>,
    #[serde(default)]
    pub ad_markers: Vec<EpisodeAdMarker>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct EpisodeAdMarker {
    pub id: String,
    pub start_time: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct EpisodeShowNote {
    pub id: String,
    pub start_time: f64,
    pub title: String,
    pub summary: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Show {
    pub id: i64,
    pub feed_url: String,
    pub title: String,
    pub description: String,
    pub image_url: String,
    pub site_url: String,
    pub episode_count: i64,
    pub unplayed_count: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Page<T> {
    pub items: Vec<T>,
    pub next_offset: Option<i64>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ShowDetail {
    pub show: Show,
    pub episodes: Page<EpisodeItem>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SettingsPayload {
    pub speed: f64,
    pub autoplay: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CarBluetoothSettingsPayload {
    pub enrolled: bool,
    pub enrollable: bool,
    pub current_enrolled: bool,
    pub current_device_name: Option<String>,
    pub current_device_key: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AdRemovalStatusItem {
    pub id: i64,
    pub ad_removal_state: String,
    pub ad_removal_action: Option<String>,
    pub ad_removal_stage: Option<String>,
    pub ad_removal_blocking_reason: Option<String>,
    pub ad_removal_completed_windows: Option<i64>,
    pub ad_removal_total_windows: Option<i64>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AdRemovalStatusesPayload {
    pub items: Vec<AdRemovalStatusItem>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AdRemovalCorrectionCountPayload {
    pub podcast_id: i64,
    pub podcast_title: String,
    pub count: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct DeepSeekUsageMetricsPayload {
    pub total_cost_usd: f64,
    pub average_cost_per_episode_usd: Option<f64>,
    pub average_cost_per_podcast_minute_usd: Option<f64>,
    pub ad_detection_cost_usd: f64,
    pub show_notes_cost_usd: f64,
    pub telemetry_complete: bool,
}

impl DeepSeekUsageMetricsPayload {
    pub fn empty(complete: bool) -> Self {
        Self {
            total_cost_usd: 0.0,
            average_cost_per_episode_usd: None,
            average_cost_per_podcast_minute_usd: None,
            ad_detection_cost_usd: 0.0,
            show_notes_cost_usd: 0.0,
            telemetry_complete: complete,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AdRemovalSettingsPayload {
    pub enabled: bool,
    pub enrollment_cutoff: Option<i64>,
    pub cloud_classifier_configured: bool,
    pub model_repository: String,
    pub model_revision: String,
    pub model_total_bytes: i64,
    pub model_downloaded_bytes: i64,
    pub model_download_state: String,
    pub classifier_available: bool,
    pub classifier_unavailable_reason: Option<String>,
    pub episode_storage_bytes: i64,
    pub episode_storage_limit_bytes: i64,
    pub minimum_free_bytes: i64,
    pub device_available_bytes: i64,
    pub corrections: Vec<AdRemovalCorrectionCountPayload>,
    pub deepseek_usage: DeepSeekUsageMetricsPayload,
    #[serde(default)]
    pub preparing_count: i64,
    #[serde(default)]
    pub failed_count: i64,
    /// When true, Listen hides non-ready episodes and Play requires `ad-free`.
    #[serde(default)]
    pub listen_requires_ready: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FeedPreviewEpisode {
    pub guid: String,
    pub title: String,
    pub published_at: i64,
    pub duration_secs: Option<i64>,
    pub image_url: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FeedPreview {
    pub feed_url: String,
    pub title: String,
    pub image_url: String,
    pub episodes: Vec<FeedPreviewEpisode>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct DirectoryPodcast {
    pub title: String,
    pub author: String,
    pub feed_url: String,
    pub image_url: String,
    pub description: String,
    pub subscribed: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct DirectoryAppearance {
    pub source_episode_key: String,
    pub feed_url: String,
    pub feed_title: String,
    pub feed_image_url: String,
    pub guid: String,
    pub title: String,
    pub description: String,
    pub audio_url: String,
    pub duration_secs: Option<i64>,
    pub published_at: i64,
    pub image_url: String,
    pub evidence: String,
    pub confidence: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Follow {
    pub id: i64,
    pub name: String,
    pub aliases: Vec<String>,
    pub last_checked_at: Option<i64>,
    pub pending_count: i64,
    pub accepted_count: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FollowCandidate {
    pub id: i64,
    pub follow_id: i64,
    pub appearance: DirectoryAppearance,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SearchResults {
    pub directory_configured: bool,
    pub podcasts: Vec<DirectoryPodcast>,
    pub episodes: Vec<EpisodeItem>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct RefreshResult {
    pub refreshed: i64,
    pub errors: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Default)]
pub struct RefreshStatus {
    pub last_attempt_at: Option<i64>,
    pub last_success_at: Option<i64>,
    pub last_source: Option<String>,
    pub last_refreshed: i64,
    pub last_errors: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_refreshing: Option<bool>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct OpmlImportResult {
    pub imported: i64,
    pub skipped: i64,
    pub failed: i64,
}
