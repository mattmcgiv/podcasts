import Foundation

let podsPageSize: Int64 = 50

struct EpisodeItem: Codable, Equatable {
    let id: Int64
    let podcast_id: Int64
    let podcast_title: String
    let podcast_image: String
    let title: String
    let audio_url: String
    let duration_secs: Int64?
    let published_at: Int64
    let image_url: String
    let position_secs: Double
    let played_at: Int64?
    let ad_removal_state: String
    let ad_removal_action: String?
    let ad_removal_stage: String?
    let ad_removal_blocking_reason: String?
}

struct EpisodeDetail: Codable, Equatable {
    let id: Int64
    let podcast_id: Int64
    let podcast_title: String
    let podcast_image: String
    let title: String
    let audio_url: String
    let duration_secs: Int64?
    let published_at: Int64
    let image_url: String
    let position_secs: Double
    let played_at: Int64?
    let notes_html: String
    let archived_at: Int64?
    let ad_removal_state: String
    let ad_removal_action: String?
    let ad_removal_stage: String?
    let ad_removal_blocking_reason: String?
    var show_notes: [EpisodeShowNote] = []
    var ad_markers: [EpisodeAdMarker] = []
}

struct EpisodeAdMarker: Codable, Equatable {
    let id: String
    let start_time: Double
}

struct Show: Codable, Equatable {
    let id: Int64
    let feed_url: String
    let title: String
    let description: String
    let image_url: String
    let site_url: String
    let episode_count: Int64
    let unplayed_count: Int64
}

struct Page<T: Codable>: Codable {
    let items: [T]
    let next_offset: Int64?
}

struct ShowDetail: Codable {
    let show: Show
    let episodes: Page<EpisodeItem>
}

struct SettingsPayload: Codable, Equatable {
    let speed: Double
    let autoplay: Bool
}

/// Snapshot for the Settings car-Bluetooth enrollment control.
/// `enrolled` means a stable key is persisted; `current_enrolled` is that key
/// matching the connected output. Pairing is not enrollment.
struct CarBluetoothSettingsPayload: Codable, Equatable {
    let enrolled: Bool
    let enrollable: Bool
    let current_enrolled: Bool
    let current_device_name: String?
    let current_device_key: String?
}

/// Lightweight ad-removal status for a single episode, with no notes_html or
/// other heavy fields. Used by the batch `/api/ad-removal/statuses` endpoint so
/// the Listen view can poll many active rows with one bounded request instead
/// of one full episode-detail request per row.
struct AdRemovalStatusItem: Codable, Equatable {
    let id: Int64
    let ad_removal_state: String
    let ad_removal_action: String?
    let ad_removal_stage: String?
    let ad_removal_blocking_reason: String?
    let ad_removal_completed_windows: Int64?
    let ad_removal_total_windows: Int64?
}

struct AdRemovalStatusesPayload: Codable, Equatable {
    let items: [AdRemovalStatusItem]
}

struct AdRemovalCorrectionCountPayload: Codable, Equatable {
    let podcast_id: Int64
    let podcast_title: String
    let count: Int64
}

struct AdRemovalSettingsPayload: Codable, Equatable {
    let enabled: Bool
    let enrollment_cutoff: Int64?
    let cloud_classifier_configured: Bool
    let model_repository: String
    let model_revision: String
    let model_total_bytes: Int64
    let model_downloaded_bytes: Int64
    let model_download_state: String
    let classifier_available: Bool
    let classifier_unavailable_reason: String?
    let episode_storage_bytes: Int64
    let episode_storage_limit_bytes: Int64
    let minimum_free_bytes: Int64
    let device_available_bytes: Int64
    let corrections: [AdRemovalCorrectionCountPayload]
}

struct FeedPreviewEpisode: Codable, Equatable {
    let guid: String
    let title: String
    let published_at: Int64
    let duration_secs: Int64?
    let image_url: String
}

struct FeedPreview: Codable, Equatable {
    let feed_url: String
    let title: String
    let image_url: String
    let episodes: [FeedPreviewEpisode]
}

struct DirectoryPodcast: Codable, Equatable {
    let title: String
    let author: String
    let feed_url: String
    let image_url: String
    let description: String
    let subscribed: Bool
}

/// A possible full-length appearance returned by a directory. Candidates are
/// deliberately kept out of Listen until Pods has either high-confidence
/// evidence or the owner accepts them in review.
struct DirectoryAppearance: Codable, Equatable {
    let source_episode_key: String
    let feed_url: String
    let feed_title: String
    let feed_image_url: String
    let guid: String
    let title: String
    let description: String
    let audio_url: String
    let duration_secs: Int64?
    let published_at: Int64
    let image_url: String
    let evidence: String
    let confidence: String
}

struct Follow: Codable, Equatable {
    let id: Int64
    let name: String
    let aliases: [String]
    let last_checked_at: Int64?
    let pending_count: Int64
    let accepted_count: Int64
}

struct FollowCandidate: Codable, Equatable {
    let id: Int64
    let follow_id: Int64
    let appearance: DirectoryAppearance
}

struct SearchResults: Codable {
    let directory_configured: Bool
    let podcasts: [DirectoryPodcast]
    let episodes: [EpisodeItem]
}

struct RefreshResult: Codable, Equatable {
    let refreshed: Int
    let errors: Int
}

struct RefreshStatus: Codable, Equatable {
    let last_attempt_at: Int64?
    let last_success_at: Int64?
    let last_source: String?
    let last_refreshed: Int
    let last_errors: Int
    let is_refreshing: Bool

    static let empty = RefreshStatus(
        last_attempt_at: nil,
        last_success_at: nil,
        last_source: nil,
        last_refreshed: 0,
        last_errors: 0,
        is_refreshing: false
    )
}

struct OPMLImportResult: Codable, Equatable {
    let imported: Int
    let skipped: Int
    let failed: Int
}

enum PodsBackendError: Error, CustomStringConvertible {
    case invalid(String)
    case forbidden(String)
    case notFound
    case conflict(String)
    case database(String)
    case upstream(String)

    var description: String {
        switch self {
        case .invalid(let message), .forbidden(let message), .conflict(let message), .database(let message), .upstream(let message):
            return message
        case .notFound:
            return "not found"
        }
    }

    var statusCode: Int {
        switch self {
        case .forbidden:
            return 403
        case .invalid:
            return 422
        case .notFound:
            return 404
        case .conflict:
            return 409
        case .database, .upstream:
            return 500
        }
    }
}

func nowUnix() -> Int64 {
    Int64(Date().timeIntervalSince1970)
}
