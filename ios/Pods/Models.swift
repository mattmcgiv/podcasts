import Foundation

/// Arbitrary JSON carried through sync untouched (setting values, action payloads).
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers go out as integers; the Mac parses ids and watermarks with as_i64.
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { try container.encode(Int64(value)) }
            else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var doubleValue: Double? { if case .number(let value) = self { return value }; return nil }
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    subscript(key: String) -> JSONValue? { if case .object(let value) = self { return value[key] }; return nil }
}

struct TimelineSpan: Codable, Equatable {
    var original_start: Double
    var original_end: Double
    var processed_start: Double
}

struct Manifest: Codable, Equatable {
    var version: Int
    var episode_id: Int
    var hash: String
    var source_hash: String?
    var bytes: Int
    var duration: Double?
    var chunk_size: Int
    var chunks: [String]
    var timeline: [TimelineSpan]?
    var media: String?

    var isVideo: Bool { media == "video" }
    var fileExtension: String { isVideo ? "mp4" : "m4a" }
}

struct ShowNote: Codable, Equatable, Identifiable {
    var id: String
    var start_time: Double
    var title: String
    var summary: String
}

struct Episode: Codable, Equatable, Identifiable {
    var id: Int
    var podcast_id: Int
    var podcast_title: String
    var podcast_image: String
    var title: String
    var audio_url: String
    var article_url: String?
    var duration_secs: Double?
    var published_at: Double
    var image_url: String
    var position_secs: Double
    var played_at: Double?
    var archived_at: Double?
    var notes_html: String?
    var show_notes: [ShowNote]?
    var manifest: Manifest?
    var ad_removal_state: String?
    /// A compact snapshot lists finished episodes without notes or chunk hashes.
    /// `Library.loadFull` fetches the rest when one is needed again.
    var summary: Bool?
    /// Set on this device only, when `Library.loadFull` filled in a summary; such detail is
    /// kept through later pulls. The Mac never sends it.
    var local_detail: Bool?

    var isSummary: Bool { summary == true }
    var isUnplayed: Bool { played_at == nil && archived_at == nil }
    var artworkURL: URL? { URL(string: image_url.isEmpty ? podcast_image : image_url) }
    var duration: Double { manifest?.duration ?? duration_secs ?? 0 }
}

struct Show: Codable, Equatable, Identifiable {
    var id: Int
    var feed_url: String
    var title: String
    var description: String?
    var image_url: String?
    var site_url: String?
    var episode_count: Int?
    var unplayed_count: Int?
    var pending_count: Int?
}

/// The Mac's published library. Fields this app does not show are not kept.
struct Snapshot: Codable, Equatable {
    var version: Int
    var cursor: Int?
    var replace: Bool
    var episodes: [Episode]
    var shows: [Show]
    var settings: [String: JSONValue]
    var versions: [String: Int]
}

/// One local change waiting for the Mac, in the same shape the browser client sends.
struct Operation: Codable, Equatable, Identifiable {
    var id: String
    var sequence: Int
    var entity: String
    var field: String
    var value: JSONValue
    var changed_at: Int64
    var base_revision: Int
    var sent: Bool?
    var error: String?

    var key: String { "\(entity):\(field)" }
}

struct DownloadPreferences: Codable, Equatable {
    var limit: Int = 2 * 1024 * 1024 * 1024
    var count: Int = 50
    var automatic: Bool = true
}

/// Small, frequently rewritten device state. The snapshot is stored separately.
struct DeviceState: Codable, Equatable {
    var client_id: String = UUID().uuidString.lowercased()
    var sequence: Int = 0
    var lastChangeAt: Int64 = 0
    var outbox: [Operation] = []
    var preferences = DownloadPreferences()
    var lastSync: Double?
}

struct ActionResult: Codable {
    var id: String
    var status: String
    var revision: Int?
    var error: String?
}
