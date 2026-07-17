import Foundation

enum AdRemovalCorpusFormat {
    static let schemaVersion = "pods-ad-removal-corpus-v1"
    static let minimumEpisodeCount = 10
    static let minimumSubscriptionCount = 5
}

struct AdRemovalCorpusIndex: Codable, Equatable {
    let schemaVersion: String
    let episodes: [AdRemovalCorpusIndexEpisode]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case episodes
    }
}

struct AdRemovalCorpusIndexEpisode: Codable, Equatable {
    let episodeID: String
    let subscriptionID: String
    let audioFile: String
    let labelsFile: String
    let transcriptFile: String
    let resultFile: String

    private enum CodingKeys: String, CodingKey {
        case episodeID = "episode_id"
        case subscriptionID = "subscription_id"
        case audioFile = "audio_file"
        case labelsFile = "labels_file"
        case transcriptFile = "transcript_file"
        case resultFile = "result_file"
    }
}

enum AdRemovalCorpusClassification: String, Codable, Equatable {
    case advertisement = "ad"
    case content
}

struct AdRemovalCorpusLabel: Codable, Equatable {
    let startTime: Double
    let endTime: Double
    let classification: AdRemovalCorpusClassification

    private enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case classification
    }
}

struct AdRemovalCorpusPrediction: Codable, Equatable {
    let startTime: Double
    let endTime: Double
    let sourceSegmentIDs: [String]
    let reversibleByUndo: Bool

    private enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case sourceSegmentIDs = "source_segment_ids"
        case reversibleByUndo = "reversible_by_undo"
    }
}

struct AdRemovalCorpusLabelsFile: Codable, Equatable {
    let schemaVersion: String
    let episodeID: String
    let durationSeconds: Double
    let ranges: [AdRemovalCorpusLabel]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case episodeID = "episode_id"
        case durationSeconds = "duration_seconds"
        case ranges
    }
}

struct AdRemovalCorpusTranscriptFile: Codable, Equatable {
    let schemaVersion: String
    let episodeID: String
    let segmentIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case episodeID = "episode_id"
        case segmentIDs = "segment_ids"
    }
}

struct AdRemovalCorpusResultFile: Codable, Equatable {
    let schemaVersion: String
    let episodeID: String
    let classifierVersion: String
    let promptVersion: String
    let ranges: [AdRemovalCorpusPrediction]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case episodeID = "episode_id"
        case classifierVersion = "classifier_version"
        case promptVersion = "prompt_version"
        case ranges
    }
}

struct AdRemovalCorpusEpisodeEvaluation: Equatable {
    let episodeID: String
    let subscriptionID: String
    let durationSeconds: Double
    let transcriptSegmentIDs: [String]
    let labels: [AdRemovalCorpusLabel]
    let predictedSkipRanges: [AdRemovalCorpusPrediction]
}

enum AdRemovalCorpusError: Error, Equatable {
    case unsupportedSchema(String)
    case insufficientEpisodes(Int)
    case insufficientSubscriptions(Int)
    case duplicateEpisodeID(String)
    case unsafeRelativePath(String)
    case missingFile(String)
    case mismatchedEpisodeID(String)
    case invalidDuration(String)
    case invalidRange(String)
    case overlappingLabels(String)
    case invalidTranscript(String)
}

extension AdRemovalCorpusError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported corpus schema: \(version)"
        case .insufficientEpisodes(let count):
            return "Corpus contains \(count) episodes; at least \(AdRemovalCorpusFormat.minimumEpisodeCount) are required"
        case .insufficientSubscriptions(let count):
            return "Corpus contains \(count) subscriptions; at least \(AdRemovalCorpusFormat.minimumSubscriptionCount) are required"
        case .duplicateEpisodeID(let episodeID):
            return "Corpus contains duplicate episode ID: \(episodeID)"
        case .unsafeRelativePath(let path):
            return "Corpus path escapes its local root: \(path)"
        case .missingFile(let path):
            return "Corpus file is missing: \(path)"
        case .mismatchedEpisodeID(let episodeID):
            return "Corpus file episode ID does not match index: \(episodeID)"
        case .invalidDuration(let episodeID):
            return "Corpus duration is invalid: \(episodeID)"
        case .invalidRange(let episodeID):
            return "Corpus time range is invalid: \(episodeID)"
        case .overlappingLabels(let episodeID):
            return "Corpus labels overlap: \(episodeID)"
        case .invalidTranscript(let episodeID):
            return "Corpus transcript segment IDs are invalid: \(episodeID)"
        }
    }
}

struct AdRemovalGoldenCorpusLoader {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load(indexURL: URL) throws -> [AdRemovalCorpusEpisodeEvaluation] {
        let index: AdRemovalCorpusIndex = try decode(indexURL)
        try requireSupportedSchema(index.schemaVersion)
        guard index.episodes.count >= AdRemovalCorpusFormat.minimumEpisodeCount else {
            throw AdRemovalCorpusError.insufficientEpisodes(index.episodes.count)
        }
        let subscriptionCount = Set(index.episodes.map(\.subscriptionID)).count
        guard subscriptionCount >= AdRemovalCorpusFormat.minimumSubscriptionCount else {
            throw AdRemovalCorpusError.insufficientSubscriptions(subscriptionCount)
        }
        var seenEpisodeIDs: Set<String> = []
        for episode in index.episodes where !seenEpisodeIDs.insert(episode.episodeID).inserted {
            throw AdRemovalCorpusError.duplicateEpisodeID(episode.episodeID)
        }

        let rootURL = indexURL.deletingLastPathComponent()
        return try index.episodes.map { entry in
            let audioURL = try containedFileURL(entry.audioFile, rootURL: rootURL)
            let labelsURL = try containedFileURL(entry.labelsFile, rootURL: rootURL)
            let transcriptURL = try containedFileURL(entry.transcriptFile, rootURL: rootURL)
            let resultURL = try containedFileURL(entry.resultFile, rootURL: rootURL)
            for url in [audioURL, labelsURL, transcriptURL, resultURL]
                where !fileManager.fileExists(atPath: url.path) {
                throw AdRemovalCorpusError.missingFile(url.path)
            }

            let labels: AdRemovalCorpusLabelsFile = try decode(labelsURL)
            let transcript: AdRemovalCorpusTranscriptFile = try decode(transcriptURL)
            let result: AdRemovalCorpusResultFile = try decode(resultURL)
            try requireSupportedSchema(labels.schemaVersion)
            try requireSupportedSchema(transcript.schemaVersion)
            try requireSupportedSchema(result.schemaVersion)
            guard labels.episodeID == entry.episodeID,
                  transcript.episodeID == entry.episodeID,
                  result.episodeID == entry.episodeID else {
                throw AdRemovalCorpusError.mismatchedEpisodeID(entry.episodeID)
            }
            let loaded = AdRemovalCorpusEpisodeEvaluation(
                episodeID: entry.episodeID,
                subscriptionID: entry.subscriptionID,
                durationSeconds: labels.durationSeconds,
                transcriptSegmentIDs: transcript.segmentIDs,
                labels: labels.ranges,
                predictedSkipRanges: result.ranges
            )
            try AdRemovalGoldenCorpusEvaluator.validate(episode: loaded)
            return loaded
        }
    }

    private func decode<Value: Decodable>(_ url: URL) throws -> Value {
        let decoder = JSONDecoder()
        return try decoder.decode(Value.self, from: Data(contentsOf: url))
    }

    private func requireSupportedSchema(_ schemaVersion: String) throws {
        guard schemaVersion == AdRemovalCorpusFormat.schemaVersion else {
            throw AdRemovalCorpusError.unsupportedSchema(schemaVersion)
        }
    }

    private func containedFileURL(_ path: String, rootURL: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !(path as NSString).isAbsolutePath,
              !components.contains("..") else {
            throw AdRemovalCorpusError.unsafeRelativePath(path)
        }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = rootURL.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw AdRemovalCorpusError.unsafeRelativePath(path)
        }
        return candidate
    }
}

struct AdRemovalGoldenCorpusReport: Codable, Equatable {
    let schemaVersion: String
    let episodeCount: Int
    let subscriptionCount: Int
    let labeledAdSeconds: Double
    let skippedAdSeconds: Double
    let adSecondsRecall: Double
    let labeledContentSeconds: Double
    let incorrectlySkippedContentSeconds: Double
    let contentSecondsFalseSkipRate: Double
    let allRangesTraceable: Bool
    let allFalseSkipsReversible: Bool
    let corpusShapeValid: Bool
    let minimumAdSecondsRecall: Double
    let maximumContentSecondsFalseSkipRate: Double
    let passes: Bool
}

struct AdRemovalGoldenCorpusEvaluator {
    let minimumAdSecondsRecall: Double
    let maximumContentSecondsFalseSkipRate: Double

    init(
        minimumAdSecondsRecall: Double = 0.95,
        maximumContentSecondsFalseSkipRate: Double = 0.01
    ) {
        self.minimumAdSecondsRecall = minimumAdSecondsRecall
        self.maximumContentSecondsFalseSkipRate = maximumContentSecondsFalseSkipRate
    }

    func evaluate(episodes: [AdRemovalCorpusEpisodeEvaluation]) throws -> AdRemovalGoldenCorpusReport {
        var labeledAdSeconds = 0.0
        var skippedAdSeconds = 0.0
        var labeledContentSeconds = 0.0
        var incorrectlySkippedContentSeconds = 0.0
        var allRangesTraceable = true
        var allFalseSkipsReversible = true

        for episode in episodes {
            try Self.validate(episode: episode)
            let adLabels = episode.labels.filter { $0.classification == .advertisement }
            let contentLabels = episode.labels.filter { $0.classification == .content }
            labeledAdSeconds += adLabels.reduce(0) { $0 + $1.endTime - $1.startTime }
            labeledContentSeconds += contentLabels.reduce(0) { $0 + $1.endTime - $1.startTime }

            let mergedPredictions = Self.mergedIntervals(
                episode.predictedSkipRanges.map { Interval(start: $0.startTime, end: $0.endTime) }
            )
            skippedAdSeconds += Self.overlapSeconds(mergedPredictions, labels: adLabels)
            incorrectlySkippedContentSeconds += Self.overlapSeconds(mergedPredictions, labels: contentLabels)

            let transcriptIDs = Set(episode.transcriptSegmentIDs)
            for prediction in episode.predictedSkipRanges {
                if prediction.sourceSegmentIDs.isEmpty ||
                    !prediction.sourceSegmentIDs.allSatisfy(transcriptIDs.contains) {
                    allRangesTraceable = false
                }
                let predictionInterval = [Interval(start: prediction.startTime, end: prediction.endTime)]
                if Self.overlapSeconds(predictionInterval, labels: contentLabels) > 0,
                   !prediction.reversibleByUndo {
                    allFalseSkipsReversible = false
                }
            }
        }

        let adRecall = labeledAdSeconds > 0 ? skippedAdSeconds / labeledAdSeconds : 0
        let contentFalseSkipRate = labeledContentSeconds > 0
            ? incorrectlySkippedContentSeconds / labeledContentSeconds
            : 1
        let subscriptionCount = Set(episodes.map(\.subscriptionID)).count
        let corpusShapeValid = episodes.count >= AdRemovalCorpusFormat.minimumEpisodeCount &&
            subscriptionCount >= AdRemovalCorpusFormat.minimumSubscriptionCount &&
            labeledAdSeconds > 0 && labeledContentSeconds > 0
        let epsilon = 0.000_000_001
        let passes = corpusShapeValid &&
            adRecall + epsilon >= minimumAdSecondsRecall &&
            contentFalseSkipRate <= maximumContentSecondsFalseSkipRate + epsilon &&
            allRangesTraceable &&
            allFalseSkipsReversible

        return AdRemovalGoldenCorpusReport(
            schemaVersion: AdRemovalCorpusFormat.schemaVersion,
            episodeCount: episodes.count,
            subscriptionCount: subscriptionCount,
            labeledAdSeconds: labeledAdSeconds,
            skippedAdSeconds: skippedAdSeconds,
            adSecondsRecall: adRecall,
            labeledContentSeconds: labeledContentSeconds,
            incorrectlySkippedContentSeconds: incorrectlySkippedContentSeconds,
            contentSecondsFalseSkipRate: contentFalseSkipRate,
            allRangesTraceable: allRangesTraceable,
            allFalseSkipsReversible: allFalseSkipsReversible,
            corpusShapeValid: corpusShapeValid,
            minimumAdSecondsRecall: minimumAdSecondsRecall,
            maximumContentSecondsFalseSkipRate: maximumContentSecondsFalseSkipRate,
            passes: passes
        )
    }

    fileprivate static func validate(episode: AdRemovalCorpusEpisodeEvaluation) throws {
        guard episode.durationSeconds.isFinite, episode.durationSeconds > 0 else {
            throw AdRemovalCorpusError.invalidDuration(episode.episodeID)
        }
        let transcriptIDs = episode.transcriptSegmentIDs
        guard !transcriptIDs.isEmpty,
              transcriptIDs.allSatisfy({ !$0.isEmpty }),
              Set(transcriptIDs).count == transcriptIDs.count else {
            throw AdRemovalCorpusError.invalidTranscript(episode.episodeID)
        }
        let labelIntervals = try episode.labels.map {
            try validatedInterval(start: $0.startTime, end: $0.endTime, episode: episode)
        }.sorted { $0.start < $1.start }
        for (previous, next) in zip(labelIntervals, labelIntervals.dropFirst())
            where next.start < previous.end {
            throw AdRemovalCorpusError.overlappingLabels(episode.episodeID)
        }
        for prediction in episode.predictedSkipRanges {
            _ = try validatedInterval(
                start: prediction.startTime,
                end: prediction.endTime,
                episode: episode
            )
        }
    }

    private struct Interval {
        var start: Double
        var end: Double
    }

    private static func validatedInterval(
        start: Double,
        end: Double,
        episode: AdRemovalCorpusEpisodeEvaluation
    ) throws -> Interval {
        guard start.isFinite, end.isFinite,
              start >= 0, end > start, end <= episode.durationSeconds else {
            throw AdRemovalCorpusError.invalidRange(episode.episodeID)
        }
        return Interval(start: start, end: end)
    }

    private static func mergedIntervals(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var merged: [Interval] = []
        for interval in sorted {
            if let lastIndex = merged.indices.last, interval.start <= merged[lastIndex].end {
                merged[lastIndex].end = max(merged[lastIndex].end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    private static func overlapSeconds(
        _ intervals: [Interval],
        labels: [AdRemovalCorpusLabel]
    ) -> Double {
        intervals.reduce(0) { total, interval in
            total + labels.reduce(0) { labelTotal, label in
                labelTotal + max(0, min(interval.end, label.endTime) - max(interval.start, label.startTime))
            }
        }
    }
}
