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

struct DirectoryPodcast: Codable, Equatable {
    let title: String
    let author: String
    let feed_url: String
    let image_url: String
    let description: String
    let subscribed: Bool
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

struct OPMLImportResult: Codable, Equatable {
    let imported: Int
    let skipped: Int
    let failed: Int
}

enum PodsBackendError: Error, CustomStringConvertible {
    case invalid(String)
    case notFound
    case conflict(String)
    case database(String)
    case upstream(String)

    var description: String {
        switch self {
        case .invalid(let message), .conflict(let message), .database(let message), .upstream(let message):
            return message
        case .notFound:
            return "not found"
        }
    }

    var statusCode: Int {
        switch self {
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

