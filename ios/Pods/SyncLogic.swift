import Foundation

/// Pure sync rules shared with the browser client (`client/src/offline/client.ts`).
enum SyncLogic {
    /// Processed-file seconds to original-recording seconds.
    static func originalTime(_ timeline: [TimelineSpan]?, processed seconds: Double) -> Double? {
        guard let timeline, !timeline.isEmpty else { return nil }
        for span in timeline where seconds < span.processed_start + span.original_end - span.original_start {
            return min(span.original_end, span.original_start + max(0, seconds - span.processed_start))
        }
        return timeline[timeline.count - 1].original_end
    }

    /// Original-recording seconds to processed-file seconds.
    static func processedTime(_ timeline: [TimelineSpan]?, original seconds: Double) -> Double? {
        guard let timeline, !timeline.isEmpty else { return nil }
        let span = timeline.first(where: { seconds < $0.original_end }) ?? timeline[timeline.count - 1]
        return span.processed_start + max(0, min(span.original_end, seconds) - span.original_start)
    }

    /// The library as this device should show it: the Mac's snapshot plus unsent local changes.
    static func applyOverlay(_ snapshot: Snapshot, outbox: [Operation]) -> Snapshot {
        guard !outbox.isEmpty else { return snapshot }
        var copy = snapshot
        var index: [String: Int] = [:]
        for (offset, episode) in copy.episodes.enumerated() { index[String(episode.id)] = offset }
        var removedShows = Set<Int>()
        for operation in outbox {
            if operation.entity == "settings" {
                if operation.field == "notifications_cleared_through" {
                    let current = copy.settings[operation.field]?.doubleValue ?? 0
                    copy.settings[operation.field] = .number(max(current, operation.value.doubleValue ?? 0))
                } else {
                    copy.settings[operation.field] = operation.value
                }
                continue
            }
            if operation.entity == "subscription" {
                if operation.value.boolValue == false, let show = copy.shows.first(where: { $0.feed_url == operation.field }) {
                    removedShows.insert(show.id)
                }
                continue
            }
            guard let offset = index[operation.entity] else { continue }
            if operation.field == "played" {
                copy.episodes[offset].played_at = operation.value.boolValue == true ? Double(operation.changed_at) / 1000 : nil
            } else if operation.field == "position" {
                let timeline = copy.episodes[offset].manifest?.timeline
                if let original = operation.value["original_seconds"]?.doubleValue,
                   let processed = processedTime(timeline, original: original) {
                    copy.episodes[offset].position_secs = processed
                } else if let seconds = operation.value["seconds"]?.doubleValue {
                    copy.episodes[offset].position_secs = seconds
                }
            }
        }
        if !removedShows.isEmpty {
            copy.shows.removeAll { removedShows.contains($0.id) }
            copy.episodes.removeAll { removedShows.contains($0.podcast_id) && $0.played_at == nil }
        }
        return copy
    }

    /// Keep only the newest unsent change per field. A sent operation is immutable:
    /// a lost response must retry the same identity.
    static func coalesce(_ outbox: [Operation]) -> [Operation] {
        var last: [String: String] = [:]
        for operation in outbox where operation.sent != true && operation.error == nil { last[operation.key] = operation.id }
        return outbox.filter { $0.sent == true || $0.error != nil || last[$0.key] == $0.id }
    }

    /// The next batch to send: at most one operation per field, skipping fields with a rejected change.
    static func nextBatch(_ outbox: [Operation], limit: Int = 100) -> [Operation] {
        let blocked = Set(outbox.filter { $0.error != nil }.map(\.key))
        var seen = Set<String>()
        var batch: [Operation] = []
        for operation in outbox where !blocked.contains(operation.key) && !seen.contains(operation.key) {
            seen.insert(operation.key)
            batch.append(operation)
            if batch.count == limit { break }
        }
        return batch
    }

    /// Snapshot versions this app reads: 1 is the browser's full form, 2 the compact form it asks for.
    static let snapshotVersions = [1, 2]

    static func validate(_ snapshot: Snapshot) throws {
        guard snapshotVersions.contains(snapshot.version), snapshot.replace else { throw SyncError.message("Unsupported Mac library format.") }
        var ids = Set<Int>()
        for episode in snapshot.episodes {
            guard ids.insert(episode.id).inserted, isPublished(episode, compact: snapshot.version == 2)
            else { throw SyncError.message("Mac supplied an unpublished episode.") }
        }
    }

    /// The browser's `validateSnapshot` rules for one episode. A summary is allowed only
    /// in a compact snapshot, only for a finished episode, and carries no chunk hashes.
    static func isPublished(_ episode: Episode, compact: Bool) -> Bool {
        guard episode.id > 0, episode.ad_removal_state == "ad-free", let manifest = episode.manifest,
              manifest.episode_id == episode.id, manifest.version == 1, manifest.bytes > 0,
              manifest.chunk_size == 1024 * 1024, isHash(manifest.hash),
              episode.audio_url == "/_media/\(manifest.hash).\(manifest.fileExtension)"
        else { return false }
        if episode.isSummary { return compact && !episode.isUnplayed && manifest.chunks.isEmpty }
        return manifest.chunks.count == (manifest.bytes + manifest.chunk_size - 1) / manifest.chunk_size
            && manifest.chunks.allSatisfy(isHash)
    }

    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// The episode autoplay moves to after `current`, matching the browser's `/next`.
    static func next(after current: Episode, in episodes: [Episode], sameShowOnly: Bool, isDownloaded: (Episode) -> Bool) -> Episode? {
        let candidates = episodes.filter {
            $0.isUnplayed && $0.id != current.id && isDownloaded($0) && (!sameShowOnly || $0.podcast_id == current.podcast_id)
        }
        guard let source = episodes.firstIndex(where: { $0.id == current.id }) else { return candidates.first }
        let later = Set(episodes[(source + 1)...].map(\.id))
        return candidates.first(where: { later.contains($0.id) }) ?? candidates.first
    }
}

enum SyncError: LocalizedError, Equatable {
    case message(String)
    case unauthorized
    case unreachable
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .unauthorized: return "This iPhone is not paired with the Mac."
        case .unreachable: return "Mac unavailable. Downloaded episodes still play."
        case .http(let status, let detail): return "Mac request failed (\(status))\(detail.isEmpty ? "" : ": \(detail)")."
        }
    }
}
