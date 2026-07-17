import Foundation
import SQLite3

struct AdRemovalSkipDecision: Equatable {
    let rangeID: String
    let rangeStart: Double
    let rangeEnd: Double

    var targetPosition: Double { rangeEnd }
    var skippedDuration: Double { rangeEnd - rangeStart }
}

enum AdRemovalSkipPolicy {
    static func decision(position: Double, ranges: [AdSkipRange]) -> AdRemovalSkipDecision? {
        guard position.isFinite, position >= 0 else { return nil }
        guard let range = ranges.first(where: {
            !$0.disabled && position >= $0.startTime && position < $0.endTime
        }) else {
            return nil
        }
        return AdRemovalSkipDecision(
            rangeID: range.id,
            rangeStart: range.startTime,
            rangeEnd: range.endTime
        )
    }
}

struct AdRemovalSkipSession {
    private(set) var ranges: [AdSkipRange]
    private(set) var pending: AdRemovalSkipDecision?

    init(ranges: [AdSkipRange] = []) {
        self.ranges = ranges
    }

    mutating func replaceRanges(_ ranges: [AdSkipRange]) {
        self.ranges = ranges
        if let pending, ranges.first(where: { $0.id == pending.rangeID })?.disabled != false {
            self.pending = nil
        }
    }

    @discardableResult
    mutating func enter(position: Double) -> AdRemovalSkipDecision? {
        let decision = AdRemovalSkipPolicy.decision(position: position, ranges: ranges)
        if let decision {
            pending = decision
        }
        return decision
    }

    mutating func didUndo(rangeID: String) {
        ranges = ranges.map { range in
            guard range.id == rangeID else { return range }
            return AdSkipRange(
                id: range.id,
                startSegmentID: range.startSegmentID,
                endSegmentID: range.endSegmentID,
                startTime: range.startTime,
                endTime: range.endTime,
                confidence: range.confidence,
                reason: range.reason,
                classifierVersion: range.classifierVersion,
                promptVersion: range.promptVersion,
                createdAt: range.createdAt,
                disabled: true
            )
        }
        if pending?.rangeID == rangeID {
            pending = nil
        }
    }

    mutating func clear() {
        ranges = []
        pending = nil
    }
}

struct AdRemovalDownloadedEpisode: Equatable {
    let episodeID: Int64
    let podcastID: Int64
    let audioURL: URL
    let originalDuration: Double?
    let ranges: [AdSkipRange]
    let manifestReady: Bool
}

enum AdRemovalPlaybackSourcePolicy {
    static func localSource(publisher: URL, downloaded: AdRemovalDownloadedEpisode?) -> URL {
        downloaded?.audioURL ?? publisher
    }

    static func macSource(
        publisher: URL,
        downloaded: AdRemovalDownloadedEpisode?,
        authenticatedStream: URL?
    ) -> URL? {
        downloaded == nil ? publisher : authenticatedStream
    }
}

struct AdRemovalUndoResult: Equatable {
    let disabledRangeID: String
    let seekPosition: Double
    let correction: AdCorrection
}

protocol AdRemovalPlaybackProviding: AnyObject {
    func downloadedEpisode(episodeID: Int64) throws -> AdRemovalDownloadedEpisode?
    func undoSkip(episodeID: Int64, rangeID: String) throws -> AdRemovalUndoResult
}

final class AdRemovalPlaybackStore: AdRemovalPlaybackProviding {
    private let database: PodsDatabase
    private let jobStore: AdRemovalJobStore
    private let artifactStore: AdRemovalArtifactStore

    init(
        database: PodsDatabase,
        jobStore: AdRemovalJobStore,
        artifactStore: AdRemovalArtifactStore
    ) {
        self.database = database
        self.jobStore = jobStore
        self.artifactStore = artifactStore
    }

    func downloadedEpisode(episodeID: Int64) throws -> AdRemovalDownloadedEpisode? {
        guard let job = try jobStore.job(episodeID: episodeID),
              let artifact = job.audioArtifact,
              try artifactStore.validate(artifact) else {
            return nil
        }
        let originalDuration = try database.query(
            "SELECT duration_secs FROM episodes WHERE id = ?",
            [.int(episodeID)]
        ) { statement -> Double? in
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            let value = sqlite3_column_double(statement, 0)
            return value.isFinite && value > 0 ? value : nil
        }.first ?? nil
        let manifestReady = job.stage == .ready
        return AdRemovalDownloadedEpisode(
            episodeID: episodeID,
            podcastID: job.podcastID,
            audioURL: try artifactStore.url(for: artifact.relativePath),
            originalDuration: originalDuration,
            ranges: manifestReady ? try jobStore.skipRanges(episodeID: episodeID) : [],
            manifestReady: manifestReady
        )
    }

    func undoSkip(episodeID: Int64, rangeID: String) throws -> AdRemovalUndoResult {
        try jobStore.disableRangeAndAddCorrection(episodeID: episodeID, rangeID: rangeID)
    }
}
