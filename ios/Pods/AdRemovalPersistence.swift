import Foundation
import SQLite3

enum AdRemovalJobStage: String, Codable, CaseIterable {
    case queued
    case downloading
    case downloaded
    case transcribing
    case classifying
    case ready
    case failed
    case cancelled
}

enum AdRemovalBlockingReason: String, Codable, CaseIterable {
    case modelRequired = "model_required"
    case storageLimit = "storage_limit"
    case lowPower = "low_power"
    case thermalPressure = "thermal_pressure"
    case playbackActive = "playback_active"
}

struct AdRemovalJob: Equatable {
    let id: String
    let episodeID: Int64
    let podcastID: Int64
    let stage: AdRemovalJobStage
    let blockingReason: AdRemovalBlockingReason?
    let attemptCount: Int
    let enrolledAt: Int64
    let updatedAt: Int64
    let failedStage: AdRemovalJobStage?
    let lastErrorCode: String?
    let lastErrorMessage: String?
    let retryEligible: Bool
    let nextRetryAt: Int64?
    let audioArtifact: AdRemovalAudioArtifact?
    let downloadedAt: Int64?
    let downloadResumeRelativePath: String?
    let transcriberVersion: String?
    let transcribedAt: Int64?
}

struct AdTranscriptSegment: Equatable, Codable {
    let id: String
    let index: Int
    let language: String
    let startTime: Double
    let endTime: Double
    let text: String
}

struct AdSkipRange: Equatable, Codable {
    let id: String
    let startSegmentID: String
    let endSegmentID: String
    let startTime: Double
    let endTime: Double
    let confidence: Double
    let reason: String
    let classifierVersion: String
    let promptVersion: String
    let createdAt: Int64
    let disabled: Bool
}

struct AdCorrection: Equatable, Codable {
    let id: String
    let podcastID: Int64
    let sourceEpisodeID: Int64
    let transcriptWindow: String
    let classificationContext: String
    let classifierVersion: String
    let promptVersion: String
    let createdAt: Int64
    let active: Bool
}

enum AdRemovalJobStoreError: Error, Equatable {
    case episodeNotFound
    case jobNotFound
    case corruptState(String)
    case invalidTransition(from: AdRemovalJobStage, to: AdRemovalJobStage)
}

final class AdRemovalJobStore {
    private let database: PodsDatabase
    private let now: () -> Int64
    private let retryBackoff: (Int) -> Int64

    init(
        database: PodsDatabase,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        retryBackoff: @escaping (Int) -> Int64 = { attempt in Int64(30 * (1 << max(0, attempt - 1))) }
    ) {
        self.database = database
        self.now = now
        self.retryBackoff = retryBackoff
    }

    func enqueue(episodeID: Int64) throws -> AdRemovalJob {
        if let existing = try job(episodeID: episodeID) {
            return existing
        }
        guard let podcastID = try database.scalarInt64(
            "SELECT podcast_id FROM episodes WHERE id = ?",
            [.int(episodeID)]
        ) else {
            throw AdRemovalJobStoreError.episodeNotFound
        }
        let timestamp = now()
        let id = UUID().uuidString.lowercased()
        try database.execute(
            """
            INSERT INTO ad_removal_jobs
                (id, episode_id, podcast_id, stage, attempt_count, enrolled_at, updated_at)
            VALUES (?, ?, ?, ?, 0, ?, ?)
            """,
            [
                .text(id),
                .int(episodeID),
                .int(podcastID),
                .text(AdRemovalJobStage.queued.rawValue),
                .int(timestamp),
                .int(timestamp)
            ]
        )
        return try requiredJob(id: id)
    }

    func job(id: String) throws -> AdRemovalJob? {
        try database.query(
            """
            SELECT id, episode_id, podcast_id, stage, blocking_reason,
                   attempt_count, enrolled_at, updated_at, failed_stage,
                   last_error_code, last_error_message, retry_eligible, next_retry_at,
                   audio_relative_path, audio_sha256, audio_byte_count, downloaded_at,
                   download_resume_relative_path, transcriber_version, transcribed_at
            FROM ad_removal_jobs WHERE id = ?
            """,
            [.text(id)],
            map: Self.mapJob
        ).first
    }

    func job(episodeID: Int64) throws -> AdRemovalJob? {
        try database.query(
            """
            SELECT id, episode_id, podcast_id, stage, blocking_reason,
                   attempt_count, enrolled_at, updated_at, failed_stage,
                   last_error_code, last_error_message, retry_eligible, next_retry_at,
                   audio_relative_path, audio_sha256, audio_byte_count, downloaded_at,
                   download_resume_relative_path, transcriber_version, transcribed_at
            FROM ad_removal_jobs WHERE episode_id = ?
            """,
            [.int(episodeID)],
            map: Self.mapJob
        ).first
    }

    func transition(jobID: String, to nextStage: AdRemovalJobStage) throws -> AdRemovalJob {
        try database.withTransaction {
            let current = try requiredJob(id: jobID)
            if current.stage == nextStage {
                return current
            }
            guard Self.allowedTransitions[current.stage, default: []].contains(nextStage) else {
                throw AdRemovalJobStoreError.invalidTransition(from: current.stage, to: nextStage)
            }
            try database.execute(
                """
                UPDATE ad_removal_jobs
                SET stage = ?, blocking_reason = NULL, attempt_count = 0,
                    failed_stage = NULL, last_error_code = NULL, last_error_message = NULL,
                    retry_eligible = 1, next_retry_at = NULL, updated_at = ?
                WHERE id = ?
                """,
                [.text(nextStage.rawValue), .int(now()), .text(jobID)]
            )
            return try requiredJob(id: jobID)
        }
    }

    func setBlockingReason(
        jobID: String,
        reason: AdRemovalBlockingReason?
    ) throws -> AdRemovalJob {
        try database.withTransaction {
            _ = try requiredJob(id: jobID)
            try database.execute(
                "UPDATE ad_removal_jobs SET blocking_reason = ?, updated_at = ? WHERE id = ?",
                [
                    reason.map { .text($0.rawValue) } ?? .null,
                    .int(now()),
                    .text(jobID)
                ]
            )
            return try requiredJob(id: jobID)
        }
    }

    func recordAudioArtifact(jobID: String, artifact: AdRemovalAudioArtifact) throws -> AdRemovalJob {
        guard AdRemovalArtifactStore.isValid(relativePath: artifact.relativePath),
              artifact.byteCount >= 0,
              artifact.sha256.count == 64,
              artifact.sha256.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw AdRemovalJobStoreError.corruptState("invalid audio artifact metadata")
        }
        return try database.withTransaction {
            _ = try requiredJob(id: jobID)
            let timestamp = now()
            try database.execute(
                """
                UPDATE ad_removal_jobs
                SET audio_relative_path = ?, audio_sha256 = ?, audio_byte_count = ?,
                    downloaded_at = ?, updated_at = ?
                WHERE id = ?
                """,
                [
                    .text(artifact.relativePath),
                    .text(artifact.sha256),
                    .int(artifact.byteCount),
                    .int(timestamp),
                    .int(timestamp),
                    .text(jobID)
                ]
            )
            return try requiredJob(id: jobID)
        }
    }

    func recordDownloadResumePath(jobID: String, relativePath: String?) throws -> AdRemovalJob {
        if let relativePath,
           (!AdRemovalArtifactStore.isValid(relativePath: relativePath) || !relativePath.hasPrefix("resume/")) {
            throw AdRemovalJobStoreError.corruptState("invalid resume-data path")
        }
        return try database.withTransaction {
            _ = try requiredJob(id: jobID)
            try database.execute(
                "UPDATE ad_removal_jobs SET download_resume_relative_path = ?, updated_at = ? WHERE id = ?",
                [
                    relativePath.map(SQLiteValue.text) ?? .null,
                    .int(now()),
                    .text(jobID)
                ]
            )
            return try requiredJob(id: jobID)
        }
    }

    func nextRunnableJob() throws -> AdRemovalJob? {
        let activeStages = [
            AdRemovalJobStage.queued,
            .downloading,
            .downloaded,
            .transcribing,
            .classifying
        ]
        return try database.query(
            """
            SELECT j.id, j.episode_id, j.podcast_id, j.stage, j.blocking_reason,
                   j.attempt_count, j.enrolled_at, j.updated_at, j.failed_stage,
                   j.last_error_code, j.last_error_message, j.retry_eligible, j.next_retry_at,
                   j.audio_relative_path, j.audio_sha256, j.audio_byte_count, j.downloaded_at,
                   j.download_resume_relative_path, j.transcriber_version, j.transcribed_at
            FROM ad_removal_jobs j
            JOIN episodes e ON e.id = j.episode_id
            LEFT JOIN episode_state s ON s.episode_id = e.id
            WHERE j.blocking_reason IS NULL
              AND j.stage IN (?, ?, ?, ?, ?)
              AND (j.next_retry_at IS NULL OR j.next_retry_at <= ?)
              AND s.played_at IS NULL
            ORDER BY e.published_at ASC, e.id ASC
            LIMIT 1
            """,
            activeStages.map { .text($0.rawValue) } + [.int(now())],
            map: Self.mapJob
        ).first
    }

    func recordFailure(jobID: String, errorCode: String, message: String) throws -> AdRemovalJob {
        try database.withTransaction {
            let current = try requiredJob(id: jobID)
            guard current.stage != .failed,
                  current.stage != .cancelled,
                  current.stage != .ready else {
                throw AdRemovalJobStoreError.invalidTransition(from: current.stage, to: .failed)
            }
            let attempt = current.attemptCount + 1
            let exhausted = attempt >= 3
            let timestamp = now()
            try database.execute(
                """
                UPDATE ad_removal_jobs
                SET stage = ?, failed_stage = ?, attempt_count = ?,
                    last_error_code = ?, last_error_message = ?, retry_eligible = ?,
                    next_retry_at = ?, blocking_reason = NULL, updated_at = ?
                WHERE id = ?
                """,
                [
                    .text(exhausted ? AdRemovalJobStage.failed.rawValue : current.stage.rawValue),
                    .text(current.stage.rawValue),
                    .int(Int64(attempt)),
                    .text(errorCode),
                    .text(message),
                    .int(exhausted ? 0 : 1),
                    exhausted ? .null : .int(timestamp + retryBackoff(attempt)),
                    .int(timestamp),
                    .text(jobID)
                ]
            )
            return try requiredJob(id: jobID)
        }
    }

    func retry(jobID: String) throws -> AdRemovalJob {
        try database.withTransaction {
            let current = try requiredJob(id: jobID)
            guard current.stage == .failed, let resumeStage = current.failedStage else {
                throw AdRemovalJobStoreError.invalidTransition(from: current.stage, to: current.stage)
            }
            try database.execute(
                """
                UPDATE ad_removal_jobs
                SET stage = ?, failed_stage = NULL, attempt_count = 0,
                    last_error_code = NULL, last_error_message = NULL,
                    retry_eligible = 1, next_retry_at = NULL,
                    blocking_reason = NULL, updated_at = ?
                WHERE id = ?
                """,
                [.text(resumeStage.rawValue), .int(now()), .text(jobID)]
            )
            return try requiredJob(id: jobID)
        }
    }

    func replaceTranscriptSegments(episodeID: Int64, segments: [AdTranscriptSegment]) throws {
        try database.withTransaction {
            try Self.replaceTranscriptSegments(in: database, episodeID: episodeID, segments: segments)
        }
    }

    func recordTranscript(
        jobID: String,
        segments: [AdTranscriptSegment],
        transcriberVersion: String
    ) throws -> AdRemovalJob {
        guard !transcriberVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AdRemovalJobStoreError.corruptState("missing transcriber version")
        }
        return try database.withTransaction {
            let job = try requiredJob(id: jobID)
            try Self.replaceTranscriptSegments(
                in: database,
                episodeID: job.episodeID,
                segments: segments
            )
            let timestamp = now()
            try database.execute(
                """
                UPDATE ad_removal_jobs
                SET transcriber_version = ?, transcribed_at = ?, updated_at = ?
                WHERE id = ?
                """,
                [.text(transcriberVersion), .int(timestamp), .int(timestamp), .text(jobID)]
            )
            return try requiredJob(id: jobID)
        }
    }

    func transcriptSegments(episodeID: Int64) throws -> [AdTranscriptSegment] {
        try database.query(
            """
            SELECT segment_id, segment_index, language, start_time, end_time, text
            FROM ad_transcript_segments WHERE episode_id = ?
            ORDER BY segment_index
            """,
            [.int(episodeID)]
        ) { statement in
            AdTranscriptSegment(
                id: sqliteString(statement, 0),
                index: Int(sqlite3_column_int64(statement, 1)),
                language: sqliteString(statement, 2),
                startTime: sqlite3_column_double(statement, 3),
                endTime: sqlite3_column_double(statement, 4),
                text: sqliteString(statement, 5)
            )
        }
    }

    private static func replaceTranscriptSegments(
        in database: PodsDatabase,
        episodeID: Int64,
        segments: [AdTranscriptSegment]
    ) throws {
        guard !segments.isEmpty else {
            throw AdRemovalJobStoreError.corruptState("transcript has no finalized segments")
        }
        var priorEnd = -Double.infinity
        for (expectedIndex, segment) in segments.enumerated() {
            guard segment.index == expectedIndex,
                  !segment.id.isEmpty,
                  !segment.language.isEmpty,
                  segment.startTime.isFinite,
                  segment.endTime.isFinite,
                  segment.startTime >= 0,
                  segment.endTime > segment.startTime,
                  segment.startTime >= priorEnd,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AdRemovalJobStoreError.corruptState("invalid transcript segment sequence")
            }
            priorEnd = segment.endTime
        }
        try database.execute(
            "DELETE FROM ad_transcript_segments WHERE episode_id = ?",
            [.int(episodeID)]
        )
        for segment in segments {
            try database.execute(
                """
                INSERT INTO ad_transcript_segments
                    (episode_id, segment_id, segment_index, language, start_time, end_time, text)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .int(episodeID),
                    .text(segment.id),
                    .int(Int64(segment.index)),
                    .text(segment.language),
                    .double(segment.startTime),
                    .double(segment.endTime),
                    .text(segment.text)
                ]
            )
        }
    }

    func replaceSkipRanges(episodeID: Int64, ranges: [AdSkipRange]) throws {
        try database.withTransaction {
            try database.execute("DELETE FROM ad_skip_ranges WHERE episode_id = ?", [.int(episodeID)])
            for range in ranges {
                try database.execute(
                    """
                    INSERT INTO ad_skip_ranges
                        (id, episode_id, start_segment_id, end_segment_id, start_time, end_time,
                         confidence, reason, classifier_version, prompt_version, created_at, disabled)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(range.id),
                        .int(episodeID),
                        .text(range.startSegmentID),
                        .text(range.endSegmentID),
                        .double(range.startTime),
                        .double(range.endTime),
                        .double(range.confidence),
                        .text(range.reason),
                        .text(range.classifierVersion),
                        .text(range.promptVersion),
                        .int(range.createdAt),
                        .int(range.disabled ? 1 : 0)
                    ]
                )
            }
        }
    }

    func skipRanges(episodeID: Int64) throws -> [AdSkipRange] {
        try database.query(
            """
            SELECT id, start_segment_id, end_segment_id, start_time, end_time,
                   confidence, reason, classifier_version, prompt_version, created_at, disabled
            FROM ad_skip_ranges WHERE episode_id = ?
            ORDER BY start_time, end_time, id
            """,
            [.int(episodeID)]
        ) { statement in
            AdSkipRange(
                id: sqliteString(statement, 0),
                startSegmentID: sqliteString(statement, 1),
                endSegmentID: sqliteString(statement, 2),
                startTime: sqlite3_column_double(statement, 3),
                endTime: sqlite3_column_double(statement, 4),
                confidence: sqlite3_column_double(statement, 5),
                reason: sqliteString(statement, 6),
                classifierVersion: sqliteString(statement, 7),
                promptVersion: sqliteString(statement, 8),
                createdAt: sqlite3_column_int64(statement, 9),
                disabled: sqlite3_column_int64(statement, 10) != 0
            )
        }
    }

    func addCorrection(
        podcastID: Int64,
        sourceEpisodeID: Int64,
        transcriptWindow: String,
        classificationContext: String,
        classifierVersion: String,
        promptVersion: String
    ) throws -> AdCorrection {
        let correction = AdCorrection(
            id: UUID().uuidString.lowercased(),
            podcastID: podcastID,
            sourceEpisodeID: sourceEpisodeID,
            transcriptWindow: transcriptWindow,
            classificationContext: classificationContext,
            classifierVersion: classifierVersion,
            promptVersion: promptVersion,
            createdAt: now(),
            active: true
        )
        try database.execute(
            """
            INSERT INTO ad_corrections
                (id, podcast_id, source_episode_id, transcript_window, classification_context,
                 classifier_version, prompt_version, created_at, active)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(correction.id),
                .int(correction.podcastID),
                .int(correction.sourceEpisodeID),
                .text(correction.transcriptWindow),
                .text(correction.classificationContext),
                .text(correction.classifierVersion),
                .text(correction.promptVersion),
                .int(correction.createdAt),
                .int(correction.active ? 1 : 0)
            ]
        )
        return correction
    }

    func corrections(podcastID: Int64) throws -> [AdCorrection] {
        try database.query(
            """
            SELECT id, podcast_id, source_episode_id, transcript_window, classification_context,
                   classifier_version, prompt_version, created_at, active
            FROM ad_corrections WHERE podcast_id = ? AND active = 1
            ORDER BY created_at, id
            """,
            [.int(podcastID)]
        ) { statement in
            AdCorrection(
                id: sqliteString(statement, 0),
                podcastID: sqlite3_column_int64(statement, 1),
                sourceEpisodeID: sqlite3_column_int64(statement, 2),
                transcriptWindow: sqliteString(statement, 3),
                classificationContext: sqliteString(statement, 4),
                classifierVersion: sqliteString(statement, 5),
                promptVersion: sqliteString(statement, 6),
                createdAt: sqlite3_column_int64(statement, 7),
                active: sqlite3_column_int64(statement, 8) != 0
            )
        }
    }

    func cleanupEpisode(episodeID: Int64) throws {
        try database.withTransaction {
            try Self.cleanupEpisodeMetadata(in: database, episodeID: episodeID, now: now())
        }
    }

    static func cleanupEpisodeMetadata(
        in database: PodsDatabase,
        episodeID: Int64,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws {
        let paths = try database.query(
            "SELECT audio_relative_path, download_resume_relative_path FROM ad_removal_jobs WHERE episode_id = ?",
            [.int(episodeID)]
        ) { statement in
            [sqliteOptionalString(statement, 0), sqliteOptionalString(statement, 1)].compactMap { $0 }
        }.flatMap { $0 }
        try enqueueArtifactCleanup(paths: paths, reason: "episode_cleanup", now: now, database: database)
        try database.execute("DELETE FROM ad_skip_ranges WHERE episode_id = ?", [.int(episodeID)])
        try database.execute("DELETE FROM ad_transcript_segments WHERE episode_id = ?", [.int(episodeID)])
        try database.execute("DELETE FROM ad_removal_jobs WHERE episode_id = ?", [.int(episodeID)])
    }

    func cleanupPodcast(podcastID: Int64) throws {
        try database.withTransaction {
            try Self.enqueuePodcastArtifactCleanup(
                in: database,
                podcastID: podcastID,
                now: now()
            )
            try database.execute("DELETE FROM ad_corrections WHERE podcast_id = ?", [.int(podcastID)])
            try database.execute(
                "DELETE FROM ad_skip_ranges WHERE episode_id IN (SELECT id FROM episodes WHERE podcast_id = ?)",
                [.int(podcastID)]
            )
            try database.execute(
                "DELETE FROM ad_transcript_segments WHERE episode_id IN (SELECT id FROM episodes WHERE podcast_id = ?)",
                [.int(podcastID)]
            )
            try database.execute("DELETE FROM ad_removal_jobs WHERE podcast_id = ?", [.int(podcastID)])
        }
    }

    static func enqueuePodcastArtifactCleanup(
        in database: PodsDatabase,
        podcastID: Int64,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws {
        let paths = try database.query(
            "SELECT audio_relative_path, download_resume_relative_path FROM ad_removal_jobs WHERE podcast_id = ?",
            [.int(podcastID)]
        ) { statement in
            [sqliteOptionalString(statement, 0), sqliteOptionalString(statement, 1)].compactMap { $0 }
        }.flatMap { $0 }
        try enqueueArtifactCleanup(paths: paths, reason: "podcast_cleanup", now: now, database: database)
    }

    private static func enqueueArtifactCleanup(
        paths: [String],
        reason: String,
        now: Int64,
        database: PodsDatabase
    ) throws {
        for path in paths where AdRemovalArtifactStore.isValid(relativePath: path) {
            try database.execute(
                """
                INSERT INTO ad_artifact_cleanup (relative_path, reason, created_at)
                VALUES (?, ?, ?)
                ON CONFLICT(relative_path) DO NOTHING
                """,
                [.text(path), .text(reason), .int(now)]
            )
        }
    }

    private func requiredJob(id: String) throws -> AdRemovalJob {
        guard let job = try job(id: id) else { throw AdRemovalJobStoreError.jobNotFound }
        return job
    }

    private static func mapJob(_ statement: OpaquePointer?) throws -> AdRemovalJob {
        let stageValue = sqliteString(statement, 3)
        guard let stage = AdRemovalJobStage(rawValue: stageValue) else {
            throw AdRemovalJobStoreError.corruptState("unknown stage \(stageValue)")
        }
        let blockingReason: AdRemovalBlockingReason?
        if let value = sqliteOptionalString(statement, 4) {
            guard let decoded = AdRemovalBlockingReason(rawValue: value) else {
                throw AdRemovalJobStoreError.corruptState("unknown blocking reason \(value)")
            }
            blockingReason = decoded
        } else {
            blockingReason = nil
        }
        let failedStage: AdRemovalJobStage?
        if let value = sqliteOptionalString(statement, 8) {
            guard let decoded = AdRemovalJobStage(rawValue: value) else {
                throw AdRemovalJobStoreError.corruptState("unknown failed stage \(value)")
            }
            failedStage = decoded
        } else {
            failedStage = nil
        }
        let audioArtifact: AdRemovalAudioArtifact?
        let audioPath = sqliteOptionalString(statement, 13)
        let audioChecksum = sqliteOptionalString(statement, 14)
        let audioByteCount = sqliteOptionalInt64(statement, 15)
        if audioPath == nil, audioChecksum == nil, audioByteCount == nil {
            audioArtifact = nil
        } else if let audioPath, let audioChecksum, let audioByteCount,
                  AdRemovalArtifactStore.isValid(relativePath: audioPath),
                  audioByteCount >= 0 {
            audioArtifact = AdRemovalAudioArtifact(
                relativePath: audioPath,
                sha256: audioChecksum,
                byteCount: audioByteCount
            )
        } else {
            throw AdRemovalJobStoreError.corruptState("partial audio artifact metadata")
        }
        return AdRemovalJob(
            id: sqliteString(statement, 0),
            episodeID: sqlite3_column_int64(statement, 1),
            podcastID: sqlite3_column_int64(statement, 2),
            stage: stage,
            blockingReason: blockingReason,
            attemptCount: Int(sqlite3_column_int64(statement, 5)),
            enrolledAt: sqlite3_column_int64(statement, 6),
            updatedAt: sqlite3_column_int64(statement, 7),
            failedStage: failedStage,
            lastErrorCode: sqliteOptionalString(statement, 9),
            lastErrorMessage: sqliteOptionalString(statement, 10),
            retryEligible: sqlite3_column_int64(statement, 11) != 0,
            nextRetryAt: sqliteOptionalInt64(statement, 12),
            audioArtifact: audioArtifact,
            downloadedAt: sqliteOptionalInt64(statement, 16),
            downloadResumeRelativePath: sqliteOptionalString(statement, 17),
            transcriberVersion: sqliteOptionalString(statement, 18),
            transcribedAt: sqliteOptionalInt64(statement, 19)
        )
    }

    private static let allowedTransitions: [AdRemovalJobStage: Set<AdRemovalJobStage>] = [
        .queued: [.downloading, .cancelled],
        .downloading: [.downloaded, .failed, .cancelled],
        .downloaded: [.transcribing, .failed, .cancelled],
        .transcribing: [.classifying, .failed, .cancelled],
        .classifying: [.ready, .failed, .cancelled],
        .ready: [.cancelled],
        .failed: [.queued, .downloading, .downloaded, .transcribing, .classifying, .cancelled],
        .cancelled: []
    ]
}

protocol AdRemovalStageExecuting: AnyObject {
    func execute(stage: AdRemovalJobStage, job: AdRemovalJob) async throws
}

struct AdRemovalPipelinePause: Error, Equatable {
    let reason: AdRemovalBlockingReason
}

actor AdRemovalCoordinator {
    private let store: AdRemovalJobStore
    private let executor: AdRemovalStageExecuting
    private let diagnostics: AdRemovalDiagnostics?
    private var stageRunInProgress = false

    init(
        store: AdRemovalJobStore,
        executor: AdRemovalStageExecuting,
        diagnostics: AdRemovalDiagnostics? = nil
    ) {
        self.store = store
        self.executor = executor
        self.diagnostics = diagnostics
    }

    @discardableResult
    func runNextStage() async throws -> AdRemovalJob? {
        guard !stageRunInProgress else { return nil }
        stageRunInProgress = true
        defer { stageRunInProgress = false }

        guard var job = try store.nextRunnableJob() else { return nil }
        let executingStage: AdRemovalJobStage
        let completionStage: AdRemovalJobStage
        switch job.stage {
        case .queued:
            executingStage = .downloading
            completionStage = .downloaded
            job = try store.transition(jobID: job.id, to: executingStage)
        case .downloading:
            executingStage = .downloading
            completionStage = .downloaded
        case .downloaded:
            executingStage = .transcribing
            completionStage = .classifying
            job = try store.transition(jobID: job.id, to: executingStage)
        case .transcribing:
            executingStage = .transcribing
            completionStage = .classifying
        case .classifying:
            executingStage = .classifying
            completionStage = .ready
        case .ready, .failed, .cancelled:
            return nil
        }

        record(eventName: "scheduler_stage_submission", severity: .info, job: job)
        do {
            try await executor.execute(stage: executingStage, job: job)
            let completed = try store.transition(jobID: job.id, to: completionStage)
            record(eventName: "job_state_transition", severity: .notice, job: completed)
            return completed
        } catch is CancellationError {
            record(eventName: "job_stage_cancelled_at_safe_boundary", severity: .notice, job: job)
            throw CancellationError()
        } catch let pause as AdRemovalPipelinePause {
            let blocked = try store.setBlockingReason(jobID: job.id, reason: pause.reason)
            record(
                eventName: "scheduler_policy_pause",
                severity: .notice,
                job: blocked,
                fields: ["blocking_reason": pause.reason.rawValue]
            )
            return blocked
        } catch {
            let nsError = error as NSError
            let failed = try store.recordFailure(
                jobID: job.id,
                errorCode: "\(nsError.domain).\(nsError.code)",
                message: nsError.localizedDescription
            )
            record(
                eventName: "job_stage_failure",
                severity: .error,
                job: failed,
                fields: ["error_domain": nsError.domain, "error_code": "\(nsError.code)"]
            )
            return failed
        }
    }

    private func record(
        eventName: String,
        severity: AdRemovalDiagnosticSeverity,
        job: AdRemovalJob,
        fields: [String: String] = [:]
    ) {
        try? diagnostics?.record(
            eventName: eventName,
            severity: severity,
            context: .init(
                jobID: job.id,
                episodeID: job.episodeID,
                podcastID: job.podcastID,
                stage: job.stage.rawValue,
                attempt: job.attemptCount
            ),
            fields: fields
        )
    }
}
