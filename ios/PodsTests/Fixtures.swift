import Foundation
@testable import Pods

enum Fixture {
    static func hash(_ seed: Int) -> String { String(repeating: String(format: "%02x", seed % 256), count: 32) }

    static func manifest(id: Int, bytes: Int = 3 * 1024 * 1024 + 10, timeline: [TimelineSpan]? = nil) -> Manifest {
        let chunks = (bytes + 1024 * 1024 - 1) / (1024 * 1024)
        return Manifest(version: 1, episode_id: id, hash: hash(id), source_hash: nil, bytes: bytes, duration: 600,
                        chunk_size: 1024 * 1024, chunks: (0..<chunks).map { hash(id * 10 + $0) }, timeline: timeline, media: "audio")
    }

    static func episode(_ id: Int, show: Int = 1, played: Bool = false, bytes: Int = 3 * 1024 * 1024 + 10,
                        timeline: [TimelineSpan]? = nil) -> Episode {
        Episode(id: id, podcast_id: show, podcast_title: "Show \(show)", podcast_image: "", title: "Episode \(id)",
                audio_url: "/_media/\(hash(id)).m4a", article_url: nil, duration_secs: 600, published_at: Double(1_700_000_000 + id),
                image_url: "", position_secs: 0, played_at: played ? 1_700_000_100 : nil, archived_at: nil,
                notes_html: nil, show_notes: nil, manifest: manifest(id: id, bytes: bytes, timeline: timeline),
                ad_removal_state: "ad-free")
    }

    static func show(_ id: Int) -> Show {
        Show(id: id, feed_url: "https://example.com/\(id).xml", title: "Show \(id)", description: nil, image_url: nil,
             site_url: nil, episode_count: nil, unplayed_count: nil, pending_count: nil)
    }

    static func snapshot(_ episodes: [Episode], shows: [Show] = [show(1), show(2)]) -> Snapshot {
        Snapshot(version: 1, cursor: nil, replace: true, episodes: episodes, shows: shows,
                 settings: ["speed": .number(1.5), "notifications_cleared_through": .number(10)], versions: [:])
    }

    static func op(_ entity: String, _ field: String, _ value: JSONValue, id: String = UUID().uuidString,
                   sent: Bool? = nil, error: String? = nil, at: Int64 = 1_700_000_000_000) -> Pods.Operation {
        Pods.Operation(id: id, sequence: 1, entity: entity, field: field, value: value, changed_at: at,
                       base_revision: 0, sent: sent, error: error)
    }

    /// An ad cut from 100 s to 160 s of the original recording.
    static let adCut = [TimelineSpan(original_start: 0, original_end: 100, processed_start: 0),
                        TimelineSpan(original_start: 160, original_end: 300, processed_start: 100)]
}
