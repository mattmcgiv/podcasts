import XCTest
import SQLite3
@testable import Pods

final class AdRemovalPersistenceTests: XCTestCase {
    private final class RecordingStageExecutor: AdRemovalStageExecuting {
        private let store: AdRemovalJobStore
        private(set) var executedStages: [AdRemovalJobStage] = []
        private(set) var durableStagesSeen: [AdRemovalJobStage] = []

        init(store: AdRemovalJobStore) {
            self.store = store
        }

        func execute(stage: AdRemovalJobStage, job: AdRemovalJob) async throws {
            executedStages.append(stage)
            durableStagesSeen.append(try XCTUnwrap(store.job(id: job.id)?.stage))
        }
    }

    private final class FailOnceStageExecutor: AdRemovalStageExecuting {
        private(set) var calls = 0

        func execute(stage: AdRemovalJobStage, job: AdRemovalJob) async throws {
            calls += 1
            if calls == 1 {
                throw NSError(domain: "AdRemovalTest", code: 17, userInfo: [
                    NSLocalizedDescriptionKey: "transient failure"
                ])
            }
        }
    }

    private actor ConcurrencyProbeExecutor: AdRemovalStageExecuting {
        private var activeCalls = 0
        private(set) var maximumConcurrentCalls = 0

        func execute(stage: AdRemovalJobStage, job: AdRemovalJob) async throws {
            activeCalls += 1
            maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)

            try await Task.sleep(nanoseconds: 100_000_000)

            activeCalls -= 1
        }
    }

    private final class PausingStageExecutor: AdRemovalStageExecuting {
        func execute(stage: AdRemovalJobStage, job: AdRemovalJob) async throws {
            throw AdRemovalPipelinePause(reason: .storageLimit)
        }
    }

    func testEnqueueAndStageTransitionsAreDurableIdempotentAndValidated() throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })

        let queued = try store.enqueue(episodeID: harness.episodeID)
        XCTAssertEqual(queued.stage, .queued)
        XCTAssertNil(queued.blockingReason)
        XCTAssertEqual(queued.attemptCount, 0)
        XCTAssertEqual(queued.enrolledAt, 1_000)

        let downloading = try store.transition(jobID: queued.id, to: .downloading)
        XCTAssertEqual(downloading.stage, .downloading)
        XCTAssertEqual(downloading.updatedAt, 1_000)

        let idempotent = try store.transition(jobID: queued.id, to: .downloading)
        XCTAssertEqual(idempotent, downloading)
        XCTAssertThrowsError(try store.transition(jobID: queued.id, to: .ready))

        let reopened = AdRemovalJobStore(database: harness.database, now: { 2_000 })
        XCTAssertEqual(try reopened.job(id: queued.id), downloading)
        XCTAssertEqual(try reopened.job(episodeID: harness.episodeID), downloading)
    }

    func testRunnableSelectionIsOldestUnplayedFirstAndHonorsBlockingReasons() throws {
        let harness = try makeHarness()
        let olderEpisodeID = try insertEpisode(
            database: harness.database,
            guid: "episode-older",
            publishedAt: 50
        )
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let newer = try store.enqueue(episodeID: harness.episodeID)
        let older = try store.enqueue(episodeID: olderEpisodeID)

        XCTAssertEqual(try store.nextRunnableJob()?.id, older.id)

        let blocked = try store.setBlockingReason(jobID: older.id, reason: .lowPower)
        XCTAssertEqual(blocked.stage, .queued)
        XCTAssertEqual(blocked.blockingReason, .lowPower)
        XCTAssertEqual(try store.nextRunnableJob()?.id, newer.id)

        try store.clearBlockingReasons([.lowPower])
        XCTAssertNil(try store.job(id: older.id)?.blockingReason)
        XCTAssertEqual(try store.nextRunnableJob()?.id, older.id)
    }

    func testAudioArtifactMetadataIsDurableAndRejectsUnauditedPaths() throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        let artifact = AdRemovalAudioArtifact(
            relativePath: "episodes/\(harness.episodeID)/audio.mp3",
            sha256: String(repeating: "a", count: 64),
            byteCount: 12_345
        )

        let recorded = try store.recordAudioArtifact(jobID: queued.id, artifact: artifact)
        XCTAssertEqual(recorded.audioArtifact, artifact)
        XCTAssertEqual(recorded.downloadedAt, 1_000)
        XCTAssertEqual(try AdRemovalJobStore(database: harness.database).job(id: queued.id)?.audioArtifact, artifact)

        XCTAssertThrowsError(try store.recordAudioArtifact(
            jobID: queued.id,
            artifact: AdRemovalAudioArtifact(
                relativePath: "/tmp/untrusted.mp3",
                sha256: artifact.sha256,
                byteCount: artifact.byteCount
            )
        ))
    }

    func testSchemaMigrationAddsAudioMetadataColumnsToExistingJobTable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE ad_removal_jobs (
            id TEXT PRIMARY KEY,
            episode_id INTEGER NOT NULL UNIQUE,
            podcast_id INTEGER NOT NULL,
            stage TEXT NOT NULL,
            blocking_reason TEXT,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            failed_stage TEXT,
            last_error_code TEXT,
            last_error_message TEXT,
            retry_eligible INTEGER NOT NULL DEFAULT 1,
            next_retry_at INTEGER,
            enrolled_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(handle, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let database = try PodsDatabase(url: databaseURL)
        let columns = try database.query("PRAGMA table_info(ad_removal_jobs)") { statement in
            sqliteString(statement, 1)
        }
        XCTAssertTrue(columns.contains("audio_relative_path"))
        XCTAssertTrue(columns.contains("audio_sha256"))
        XCTAssertTrue(columns.contains("audio_byte_count"))
        XCTAssertTrue(columns.contains("downloaded_at"))
    }

    func testFailuresRetryThreeTimesWithStableMetadataAndResumeFailedStage() throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(
            database: harness.database,
            now: { 1_000 },
            retryBackoff: { _ in 30 }
        )
        let queued = try store.enqueue(episodeID: harness.episodeID)
        _ = try store.transition(jobID: queued.id, to: .downloading)

        let first = try store.recordFailure(
            jobID: queued.id,
            errorCode: "network_timeout",
            message: "request timed out"
        )
        XCTAssertEqual(first.stage, .downloading)
        XCTAssertEqual(first.failedStage, .downloading)
        XCTAssertEqual(first.attemptCount, 1)
        XCTAssertEqual(first.lastErrorCode, "network_timeout")
        XCTAssertEqual(first.lastErrorMessage, "request timed out")
        XCTAssertTrue(first.retryEligible)
        XCTAssertEqual(first.nextRetryAt, 1_030)

        let second = try store.recordFailure(jobID: queued.id, errorCode: "network_timeout", message: "again")
        XCTAssertEqual(second.stage, .downloading)
        XCTAssertEqual(second.attemptCount, 2)
        XCTAssertTrue(second.retryEligible)

        let exhausted = try store.recordFailure(jobID: queued.id, errorCode: "network_timeout", message: "final")
        XCTAssertEqual(exhausted.stage, .failed)
        XCTAssertEqual(exhausted.failedStage, .downloading)
        XCTAssertEqual(exhausted.attemptCount, 3)
        XCTAssertFalse(exhausted.retryEligible)
        XCTAssertNil(exhausted.nextRetryAt)

        let retried = try store.retry(jobID: queued.id)
        XCTAssertEqual(retried.stage, .downloading)
        XCTAssertNil(retried.failedStage)
        XCTAssertEqual(retried.attemptCount, 0)
        XCTAssertNil(retried.lastErrorCode)
        XCTAssertNil(retried.lastErrorMessage)
        XCTAssertTrue(retried.retryEligible)
    }

    func testEpisodeCleanupDeletesArtifactsButPreservesPodcastCorrectionsUntilUnsubscribe() throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        _ = try store.enqueue(episodeID: harness.episodeID)
        let segments = [
            AdTranscriptSegment(
                id: "segment-0",
                index: 0,
                language: "en",
                startTime: 10,
                endTime: 20,
                text: "Buy this product"
            )
        ]
        try store.replaceTranscriptSegments(episodeID: harness.episodeID, segments: segments)
        let ranges = [
            AdSkipRange(
                id: "range-0",
                startSegmentID: "segment-0",
                endSegmentID: "segment-0",
                startTime: 10,
                endTime: 20,
                confidence: 0.97,
                reason: "host-read promotion",
                classifierVersion: "qwen-test",
                promptVersion: "prompt-1",
                createdAt: 1_000,
                disabled: false
            )
        ]
        try store.replaceSkipRanges(episodeID: harness.episodeID, ranges: ranges)
        try store.recordClassificationEvidence(AdClassificationEvidence(
            runID: "run-1",
            episodeID: harness.episodeID,
            windowIndex: 0,
            segmentIDs: ["segment-0"],
            correctionIDs: [],
            prompt: "classify segment-0",
            rawOutput: #"{"labels":[]}"#,
            schemaValid: true,
            validationError: nil,
            labels: [AdClassifierLabel(
                segmentID: "segment-0",
                classification: .advertisement,
                confidence: 0.97,
                reason: "host-read promotion"
            )],
            descriptor: AdClassifierDescriptor(
                modelID: "test/model",
                modelRevision: "revision-1",
                quantization: "4-bit",
                promptRevision: "prompt-1",
                maximumContextTokens: 8_192,
                maximumOutputTokens: 1_024,
                temperature: 0,
                topP: 1
            ),
            createdAt: 1_000
        ))
        let podcastID = try XCTUnwrap(harness.database.scalarInt64(
            "SELECT podcast_id FROM episodes WHERE id = ?",
            [.int(harness.episodeID)]
        ))
        let correction = try store.addCorrection(
            podcastID: podcastID,
            sourceEpisodeID: harness.episodeID,
            transcriptWindow: "This recurring segment is editorial content",
            classificationContext: "window-3",
            classifierVersion: "qwen-test",
            promptVersion: "prompt-1"
        )

        XCTAssertEqual(try store.transcriptSegments(episodeID: harness.episodeID), segments)
        XCTAssertEqual(try store.skipRanges(episodeID: harness.episodeID), ranges)
        XCTAssertEqual(try store.classificationEvidence(episodeID: harness.episodeID).count, 1)
        XCTAssertEqual(try store.corrections(podcastID: podcastID), [correction])

        try store.cleanupEpisode(episodeID: harness.episodeID)

        XCTAssertNil(try store.job(episodeID: harness.episodeID))
        XCTAssertTrue(try store.transcriptSegments(episodeID: harness.episodeID).isEmpty)
        XCTAssertTrue(try store.skipRanges(episodeID: harness.episodeID).isEmpty)
        XCTAssertTrue(try store.classificationEvidence(episodeID: harness.episodeID).isEmpty)
        XCTAssertEqual(try store.corrections(podcastID: podcastID), [correction])

        try store.cleanupPodcast(podcastID: podcastID)
        XCTAssertTrue(try store.corrections(podcastID: podcastID).isEmpty)
    }

    func testCoordinatorCommitsEachStageBeforeExecutingAndReachesReady() async throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        let executor = RecordingStageExecutor(store: store)
        let coordinator = AdRemovalCoordinator(store: store, executor: executor)

        let afterDownload = try await coordinator.runNextStage()
        let afterTranscription = try await coordinator.runNextStage()
        let afterClassification = try await coordinator.runNextStage()
        XCTAssertEqual(afterDownload?.stage, .downloaded)
        XCTAssertEqual(afterTranscription?.stage, .classifying)
        XCTAssertEqual(afterClassification?.stage, .ready)

        XCTAssertEqual(executor.executedStages, [.downloading, .transcribing, .classifying])
        XCTAssertEqual(executor.durableStagesSeen, [.downloading, .transcribing, .classifying])
        XCTAssertEqual(try store.job(id: queued.id)?.stage, .ready)
        XCTAssertNil(try store.nextRunnableJob())
    }

    func testCoordinatorDoesNotRunAStageBeforeItsRetryBackoffExpires() async throws {
        let harness = try makeHarness()
        var clock: Int64 = 1_000
        let store = AdRemovalJobStore(
            database: harness.database,
            now: { clock },
            retryBackoff: { _ in 30 }
        )
        let queued = try store.enqueue(episodeID: harness.episodeID)
        let executor = FailOnceStageExecutor()
        let coordinator = AdRemovalCoordinator(store: store, executor: executor)

        let failedAttempt = try await coordinator.runNextStage()
        XCTAssertEqual(failedAttempt?.stage, .downloading)
        XCTAssertEqual(failedAttempt?.attemptCount, 1)
        XCTAssertEqual(failedAttempt?.lastErrorCode, "AdRemovalTest.17")
        XCTAssertEqual(failedAttempt?.nextRetryAt, 1_030)

        let beforeBackoff = try await coordinator.runNextStage()
        XCTAssertNil(beforeBackoff)
        XCTAssertEqual(executor.calls, 1)

        clock = 1_030
        let retried = try await coordinator.runNextStage()
        XCTAssertEqual(retried?.stage, .downloaded)
        XCTAssertEqual(executor.calls, 2)
        let persistedRetry = try store.job(id: queued.id)
        XCTAssertEqual(persistedRetry?.attemptCount, 0)
        XCTAssertNil(persistedRetry?.failedStage)
        XCTAssertNil(persistedRetry?.lastErrorCode)
        XCTAssertNil(persistedRetry?.lastErrorMessage)
        XCTAssertNil(persistedRetry?.nextRetryAt)
    }

    func testCoordinatorRunsOnlyOneEpisodeStageAtATime() async throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        _ = try store.enqueue(episodeID: harness.episodeID)
        let executor = ConcurrencyProbeExecutor()
        let coordinator = AdRemovalCoordinator(store: store, executor: executor)

        async let first = coordinator.runNextStage()
        async let second = coordinator.runNextStage()
        _ = try await (first, second)

        let maximumConcurrentCalls = await executor.maximumConcurrentCalls
        XCTAssertEqual(maximumConcurrentCalls, 1)
    }

    func testCoordinatorRecordsPolicyPauseWithoutConsumingFailureRetry() async throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        let coordinator = AdRemovalCoordinator(store: store, executor: PausingStageExecutor())

        let paused = try await coordinator.runNextStage()

        XCTAssertEqual(paused?.stage, .downloading)
        XCTAssertEqual(paused?.blockingReason, .storageLimit)
        XCTAssertEqual(paused?.attemptCount, 0)
        XCTAssertNil(paused?.lastErrorCode)
        XCTAssertEqual(try store.job(id: queued.id), paused)
        XCTAssertNil(try store.nextRunnableJob())
    }

    func testSchedulingPolicyOnlyPausesComputeStagesForPowerThermalOrPlayback() {
        XCTAssertNil(AdRemovalSchedulingPolicy.blockingReason(
            for: .downloading,
            conditions: .init(lowPowerMode: true, seriousThermalPressure: true, playbackActive: true)
        ))
        XCTAssertEqual(AdRemovalSchedulingPolicy.blockingReason(
            for: .transcribing,
            conditions: .init(lowPowerMode: true, seriousThermalPressure: false, playbackActive: false)
        ), .lowPower)
        XCTAssertEqual(AdRemovalSchedulingPolicy.blockingReason(
            for: .classifying,
            conditions: .init(lowPowerMode: false, seriousThermalPressure: true, playbackActive: false)
        ), .thermalPressure)
        XCTAssertEqual(AdRemovalSchedulingPolicy.blockingReason(
            for: .classifying,
            conditions: .init(lowPowerMode: false, seriousThermalPressure: false, playbackActive: true)
        ), .playbackActive)
    }

    func testSchedulerDownloadsDuringLowPowerThenResumesComputeUntilReady() async throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        let executor = RecordingStageExecutor(store: store)
        let coordinator = AdRemovalCoordinator(store: store, executor: executor)
        var conditions = AdRemovalRuntimeConditions(
            lowPowerMode: true,
            seriousThermalPressure: false,
            playbackActive: false
        )
        let scheduler = AdRemovalPipelineScheduler(
            store: store,
            coordinator: coordinator,
            conditions: { conditions }
        )

        await scheduler.runUntilIdle()

        XCTAssertEqual(try store.job(id: queued.id)?.stage, .downloaded)
        XCTAssertEqual(try store.job(id: queued.id)?.blockingReason, .lowPower)
        XCTAssertEqual(executor.executedStages, [.downloading])

        conditions = .init(lowPowerMode: false, seriousThermalPressure: false, playbackActive: false)
        await scheduler.runUntilIdle()

        XCTAssertEqual(try store.job(id: queued.id)?.stage, .ready)
        XCTAssertNil(try store.job(id: queued.id)?.blockingReason)
        XCTAssertEqual(executor.executedStages, [.downloading, .transcribing, .classifying])
    }

    func testSchedulerDoesNoWorkWhileFeatureIsDisabled() async throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        let executor = RecordingStageExecutor(store: store)
        let scheduler = AdRemovalPipelineScheduler(
            store: store,
            coordinator: AdRemovalCoordinator(store: store, executor: executor),
            isEnabled: { false },
            conditions: {
                .init(lowPowerMode: false, seriousThermalPressure: false, playbackActive: false)
            }
        )

        await scheduler.runUntilIdle()

        XCTAssertEqual(try store.job(id: queued.id)?.stage, .queued)
        XCTAssertTrue(executor.executedStages.isEmpty)
    }

    private struct Harness {
        let database: PodsDatabase
        let episodeID: Int64
    }

    private func makeHarness() throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try PodsDatabase(url: directory.appendingPathComponent("test.sqlite"))
        try database.execute(
            "INSERT INTO podcasts (feed_url, title, created_at) VALUES (?, ?, ?)",
            [.text("https://example.com/feed"), .text("Example"), .int(1)]
        )
        let podcastID = database.lastInsertRowID()
        try database.execute(
            "INSERT INTO episodes (podcast_id, guid, title, audio_url, published_at) VALUES (?, ?, ?, ?, ?)",
            [
                .int(podcastID),
                .text("episode-1"),
                .text("Episode"),
                .text("https://example.com/episode.mp3"),
                .int(100)
            ]
        )
        return Harness(database: database, episodeID: database.lastInsertRowID())
    }


    private func insertEpisode(database: PodsDatabase, guid: String, publishedAt: Int64) throws -> Int64 {
        let podcastID = try XCTUnwrap(database.scalarInt64("SELECT id FROM podcasts LIMIT 1"))
        try database.execute(
            "INSERT INTO episodes (podcast_id, guid, title, audio_url, published_at) VALUES (?, ?, ?, ?, ?)",
            [
                .int(podcastID),
                .text(guid),
                .text(guid),
                .text("https://example.com/\(guid).mp3"),
                .int(publishedAt)
            ]
        )
        return database.lastInsertRowID()
    }
}
