import XCTest
import SQLite3
@testable import Pods

final class AdRemovalPersistenceTests: XCTestCase {
    private final class RecordingShowNotesGenerator: EpisodeShowNotesGenerating {
        let modelID = "test/show-notes"
        let promptVersion = "show-notes-prompt-v1"
        private let drafts: [EpisodeShowNoteDraft]
        private(set) var receivedSegments: [AdTranscriptSegment] = []

        init(drafts: [EpisodeShowNoteDraft]) {
            self.drafts = drafts
        }

        func generate(segments: [AdTranscriptSegment]) async throws -> [EpisodeShowNoteDraft] {
            receivedSegments = segments
            return drafts
        }
    }

    private actor SuspendedShowNotesGenerator: EpisodeShowNotesGenerating {
        nonisolated let modelID = "test/show-notes"
        nonisolated let promptVersion = "show-notes-prompt-v1"
        private let drafts: [EpisodeShowNoteDraft]
        private var entered = false
        private var released = false
        private var callCount = 0
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        init(drafts: [EpisodeShowNoteDraft]) {
            self.drafts = drafts
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }

        func calls() -> Int {
            callCount
        }

        func generate(segments: [AdTranscriptSegment]) async throws -> [EpisodeShowNoteDraft] {
            callCount += 1
            entered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters.removeAll()
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            return drafts
        }
    }

    private actor CancellationHoldingShowNotesGenerator: EpisodeShowNotesGenerating {
        nonisolated let modelID = "test/show-notes"
        nonisolated let promptVersion = "show-notes-prompt-v1"
        private let drafts: [EpisodeShowNoteDraft]
        private var callCount = 0
        private var cancellationCount = 0
        private var releasedCancelledCall = false
        private var releasedSecondCall = false
        private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var cancellationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var cancelledReleaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var secondReleaseWaiters: [CheckedContinuation<Void, Never>] = []

        init(drafts: [EpisodeShowNoteDraft]) {
            self.drafts = drafts
        }

        func waitUntilCalls(_ expectedCount: Int) async {
            if callCount >= expectedCount { return }
            await withCheckedContinuation { continuation in
                callWaiters.append((expectedCount, continuation))
            }
        }

        func waitUntilCancellations(_ expectedCount: Int) async {
            if cancellationCount >= expectedCount { return }
            await withCheckedContinuation { continuation in
                cancellationWaiters.append((expectedCount, continuation))
            }
        }

        func calls() -> Int { callCount }

        func releaseCancelledCall() {
            releasedCancelledCall = true
            cancelledReleaseWaiters.forEach { $0.resume() }
            cancelledReleaseWaiters.removeAll()
        }

        func releaseSecondCall() {
            releasedSecondCall = true
            secondReleaseWaiters.forEach { $0.resume() }
            secondReleaseWaiters.removeAll()
        }

        func generate(segments: [AdTranscriptSegment]) async throws -> [EpisodeShowNoteDraft] {
            callCount += 1
            let call = callCount
            let readyCallWaiters = callWaiters.filter { callCount >= $0.count }
            callWaiters.removeAll { callCount >= $0.count }
            readyCallWaiters.forEach { $0.continuation.resume() }

            if call == 1 {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    XCTFail("Expected the first show-notes generation to be cancelled")
                } catch is CancellationError {
                    cancellationCount += 1
                    let readyCancellationWaiters = cancellationWaiters.filter { cancellationCount >= $0.count }
                    cancellationWaiters.removeAll { cancellationCount >= $0.count }
                    readyCancellationWaiters.forEach { $0.continuation.resume() }
                    if !releasedCancelledCall {
                        await withCheckedContinuation { cancelledReleaseWaiters.append($0) }
                    }
                    throw CancellationError()
                }
            }

            if !releasedSecondCall {
                await withCheckedContinuation { secondReleaseWaiters.append($0) }
            }
            return drafts
        }
    }

    private actor AsyncCompletionProbe {
        private var completed = false

        func markCompleted() { completed = true }
        func isCompleted() -> Bool { completed }
    }

    private actor ReadyEpisodeProbe {
        private var episodeIDs: [Int64] = []
        func record(_ episodeID: Int64) { episodeIDs.append(episodeID) }
        func recordedEpisodeIDs() -> [Int64] { episodeIDs }
    }

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

    /// Holds the first stage execute until `release()` so a concurrent scheduler
    /// call can observe ownership contention.
    private actor ControllableStageExecutor: AdRemovalStageExecuting {
        private var isHeld = true
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var didEnter = false

        func waitUntilEntered() async {
            if didEnter { return }
            await withCheckedContinuation { continuation in
                if didEnter {
                    continuation.resume()
                } else {
                    enteredContinuation = continuation
                }
            }
        }

        func release() {
            isHeld = false
        }

        func execute(stage: AdRemovalJobStage, job: AdRemovalJob) async throws {
            if !didEnter {
                didEnter = true
                enteredContinuation?.resume()
                enteredContinuation = nil
            }
            while isHeld {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
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

    func testDailyClassificationBudgetCapsDistinctEpisodesAtTwenty() throws {
        let harness = try makeHarness()
        let additionalEpisodeIDs = try (1...20).map { index in
            try insertEpisode(
                database: harness.database,
                guid: "daily-budget-\(index)",
                publishedAt: Int64(index)
            )
        }
        var timestamp: Int64 = 1_752_500_000
        let store = AdRemovalJobStore(database: harness.database, now: { timestamp })

        XCTAssertTrue(try store.reserveDailyClassificationSlot(episodeID: harness.episodeID))
        XCTAssertTrue(try store.reserveDailyClassificationSlot(episodeID: harness.episodeID))
        for episodeID in additionalEpisodeIDs.prefix(19) {
            XCTAssertTrue(try store.reserveDailyClassificationSlot(episodeID: episodeID))
        }
        XCTAssertFalse(try store.reserveDailyClassificationSlot(episodeID: additionalEpisodeIDs[19]))

        timestamp += 86_400
        XCTAssertTrue(try store.reserveDailyClassificationSlot(episodeID: additionalEpisodeIDs[19]))
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

        try harness.database.execute(
            "INSERT INTO episode_state (episode_id, archived_at, updated_at) VALUES (?, ?, ?)",
            [.int(olderEpisodeID), .int(1_000), .int(1_000)]
        )
        XCTAssertEqual(try store.nextRunnableJob()?.id, newer.id)
    }

    func testArchivedEpisodeCannotBeEnqueued() throws {
        let harness = try makeHarness()
        try harness.database.execute(
            "INSERT INTO episode_state (episode_id, archived_at, updated_at) VALUES (?, ?, ?)",
            [.int(harness.episodeID), .int(1_000), .int(1_000)]
        )

        XCTAssertThrowsError(try AdRemovalJobStore(database: harness.database).enqueue(episodeID: harness.episodeID)) {
            XCTAssertEqual($0 as? AdRemovalJobStoreError, .episodeArchived)
        }
    }

    func testAudioArtifactMetadataIsDurableAndRejectsUnauditedPaths() throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        _ = try store.transition(jobID: queued.id, to: .downloading)
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

    func testCancelledJobsRejectAllLatePipelinePersistence() throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })

        let downloadJob = try store.enqueue(episodeID: harness.episodeID)
        _ = try store.transition(jobID: downloadJob.id, to: .downloading)
        _ = try store.transition(jobID: downloadJob.id, to: .cancelled)
        XCTAssertThrowsError(try store.recordAudioArtifact(
            jobID: downloadJob.id,
            artifact: AdRemovalAudioArtifact(
                relativePath: "episodes/\(harness.episodeID)/audio.mp3",
                sha256: String(repeating: "a", count: 64),
                byteCount: 10
            )
        ))
        XCTAssertNil(try store.job(id: downloadJob.id)?.audioArtifact)

        let transcriptEpisodeID = try insertEpisode(
            database: harness.database,
            guid: "cancelled-transcript",
            publishedAt: 200
        )
        let transcriptJob = try store.enqueue(episodeID: transcriptEpisodeID)
        for stage in [
            AdRemovalJobStage.downloading,
            .downloaded,
            .transcribing,
            .cancelled
        ] {
            _ = try store.transition(jobID: transcriptJob.id, to: stage)
        }
        XCTAssertThrowsError(try store.recordTranscript(
            jobID: transcriptJob.id,
            segments: [AdTranscriptSegment(
                id: "segment-0",
                index: 0,
                language: "en",
                startTime: 0,
                endTime: 10,
                text: "Late transcript"
            )],
            transcriberVersion: "test-v1"
        ))
        XCTAssertTrue(try store.transcriptSegments(episodeID: transcriptEpisodeID).isEmpty)

        let classificationEpisodeID = try insertEpisode(
            database: harness.database,
            guid: "cancelled-classification",
            publishedAt: 300
        )
        let classificationJob = try store.enqueue(episodeID: classificationEpisodeID)
        for stage in [
            AdRemovalJobStage.downloading,
            .downloaded,
            .transcribing,
            .classifying,
            .cancelled
        ] {
            _ = try store.transition(jobID: classificationJob.id, to: stage)
        }
        let evidence = AdClassificationEvidence(
            runID: "late-run",
            episodeID: classificationEpisodeID,
            windowIndex: 0,
            segmentIDs: ["segment-0"],
            correctionIDs: [],
            prompt: "classify segment-0",
            rawOutput: #"{"labels":[]}"#,
            schemaValid: true,
            validationError: nil,
            labels: [],
            descriptor: AdClassifierDescriptor(
                modelID: "test/model",
                modelRevision: "revision-1",
                quantization: "cloud",
                promptRevision: "prompt-1",
                maximumContextTokens: 8_192,
                maximumOutputTokens: 1_024,
                temperature: 0,
                topP: 1
            ),
            createdAt: 1_000
        )
        XCTAssertThrowsError(try store.recordClassificationEvidence(
            evidence,
            jobID: classificationJob.id
        ))
        XCTAssertThrowsError(try store.completeClassification(
            jobID: classificationJob.id,
            runID: evidence.runID,
            descriptor: evidence.descriptor,
            ranges: []
        ))
        XCTAssertTrue(try store.classificationEvidence(episodeID: classificationEpisodeID).isEmpty)
        XCTAssertTrue(try store.skipRanges(episodeID: classificationEpisodeID).isEmpty)
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

    func testFailuresRetryFourTimesWithStableMetadataAndResumeFailedStage() throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(
            database: harness.database,
            now: { 1_000 }
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
        XCTAssertEqual(first.nextRetryAt, 1_002)

        let second = try store.recordFailure(jobID: queued.id, errorCode: "network_timeout", message: "again")
        XCTAssertEqual(second.stage, .downloading)
        XCTAssertEqual(second.attemptCount, 2)
        XCTAssertTrue(second.retryEligible)
        XCTAssertEqual(second.nextRetryAt, 1_005)

        let third = try store.recordFailure(jobID: queued.id, errorCode: "network_timeout", message: "third")
        XCTAssertEqual(third.stage, .downloading)
        XCTAssertEqual(third.attemptCount, 3)
        XCTAssertTrue(third.retryEligible)
        XCTAssertEqual(third.nextRetryAt, 1_015)

        let exhausted = try store.recordFailure(jobID: queued.id, errorCode: "network_timeout", message: "final")
        XCTAssertEqual(exhausted.stage, .failed)
        XCTAssertEqual(exhausted.failedStage, .downloading)
        XCTAssertEqual(exhausted.attemptCount, 4)
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

    func testSchedulerWaitsForRetryDeadlineAndRunsWithoutAnotherTrigger() async throws {
        let harness = try makeHarness()
        var clock: Int64 = 1_000
        let store = AdRemovalJobStore(database: harness.database, now: { clock })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        _ = try store.transition(jobID: queued.id, to: .downloading)
        _ = try store.recordFailure(jobID: queued.id, errorCode: "temporary", message: "retry")
        let executor = RecordingStageExecutor(store: store)
        var slept: [UInt64] = []
        let scheduler = AdRemovalPipelineScheduler(
            store: store,
            coordinator: AdRemovalCoordinator(store: store, executor: executor),
            conditions: { .init(lowPowerMode: false, seriousThermalPressure: false) },
            now: { clock },
            sleep: { seconds in
                slept.append(seconds)
                clock += Int64(seconds)
            }
        )

        await scheduler.runUntilIdle()

        XCTAssertEqual(slept, [2])
        XCTAssertEqual(try store.job(id: queued.id)?.stage, .ready)
    }

    func testEpisodeCleanupDeletesArtifactsButPreservesPodcastCorrectionsUntilUnsubscribe() throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let evidenceJob = try store.enqueue(episodeID: harness.episodeID)
        for stage in [
            AdRemovalJobStage.downloading,
            .downloaded,
            .transcribing,
            .classifying
        ] {
            _ = try store.transition(jobID: evidenceJob.id, to: stage)
        }
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
        ), jobID: evidenceJob.id)
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

    func testShowNotesServiceExcludesEnabledAdsAndPersistsLocalOrderedTimestamps() async throws {
        let harness = try makeHarness()
        try setAdRemovalEnabled(harness.database)
        let jobStore = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try jobStore.enqueue(episodeID: harness.episodeID)
        let segments = [
            AdTranscriptSegment(
                id: "segment-ad",
                index: 0,
                language: "en",
                startTime: 0,
                endTime: 20,
                text: "A sponsor message"
            ),
            AdTranscriptSegment(
                id: "segment-opening",
                index: 1,
                language: "en",
                startTime: 20.125,
                endTime: 80,
                text: "The episode begins"
            ),
            AdTranscriptSegment(
                id: "segment-topic",
                index: 2,
                language: "en",
                startTime: 125.25,
                endTime: 180,
                text: "The discussion changes topics"
            )
        ]
        try jobStore.replaceTranscriptSegments(episodeID: harness.episodeID, segments: segments)
        try jobStore.replaceSkipRanges(episodeID: harness.episodeID, ranges: [
            AdSkipRange(
                id: "range-ad",
                startSegmentID: "segment-ad",
                endSegmentID: "segment-ad",
                startTime: 0,
                endTime: 20,
                confidence: 0.99,
                reason: "sponsor message",
                classifierVersion: "test/classifier",
                promptVersion: "classifier-prompt-v1",
                createdAt: 1_000,
                disabled: false
            ),
            AdSkipRange(
                id: "range-disabled",
                startSegmentID: "segment-opening",
                endSegmentID: "segment-opening",
                startTime: 20.125,
                endTime: 80,
                confidence: 0.75,
                reason: "incorrect classification",
                classifierVersion: "test/classifier",
                promptVersion: "classifier-prompt-v1",
                createdAt: 1_000,
                disabled: true
            )
        ])
        var job = queued
        for stage in [
            AdRemovalJobStage.downloading,
            .downloaded,
            .transcribing,
            .classifying,
            .ready
        ] {
            job = try jobStore.transition(jobID: job.id, to: stage)
        }
        XCTAssertEqual(job.stage, .ready)
        let generator = RecordingShowNotesGenerator(drafts: [
            EpisodeShowNoteDraft(
                segmentID: "segment-opening",
                title: "Opening context",
                summary: "The hosts establish the central question."
            ),
            EpisodeShowNoteDraft(
                segmentID: "segment-topic",
                title: "A new direction",
                summary: "The conversation moves to the next major topic."
            )
        ])
        let service = EpisodeShowNotesService(database: harness.database, generator: generator)

        let notes = try await service.generate(episodeID: harness.episodeID)

        XCTAssertEqual(generator.receivedSegments.map(\.id), ["segment-opening", "segment-topic"])
        XCTAssertEqual(notes, [
            EpisodeShowNote(
                id: "segment-opening",
                start_time: 20.125,
                title: "Opening context",
                summary: "The hosts establish the central question."
            ),
            EpisodeShowNote(
                id: "segment-topic",
                start_time: 125.25,
                title: "A new direction",
                summary: "The conversation moves to the next major topic."
            )
        ])
        XCTAssertEqual(
            try EpisodeShowNotesStore(database: harness.database).notes(episodeID: harness.episodeID),
            notes
        )

        _ = try jobStore.disableRangeAndAddCorrection(
            episodeID: harness.episodeID,
            rangeID: "range-ad"
        )
        XCTAssertTrue(
            try EpisodeShowNotesStore(database: harness.database).notes(episodeID: harness.episodeID).isEmpty
        )
    }

    func testShowNotesServiceDoesNotSendTranscriptWhenFeatureIsDisabled() async throws {
        let harness = try makeHarness()
        let jobStore = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        var job = try jobStore.enqueue(episodeID: harness.episodeID)
        let segment = AdTranscriptSegment(
            id: "segment-opening",
            index: 0,
            language: "en",
            startTime: 12.5,
            endTime: 30,
            text: "Episode content"
        )
        try jobStore.replaceTranscriptSegments(episodeID: harness.episodeID, segments: [segment])
        for stage in [
            AdRemovalJobStage.downloading,
            .downloaded,
            .transcribing,
            .classifying,
            .ready
        ] {
            job = try jobStore.transition(jobID: job.id, to: stage)
        }
        let generator = RecordingShowNotesGenerator(drafts: [EpisodeShowNoteDraft(
            segmentID: segment.id,
            title: "Opening",
            summary: "The episode begins."
        )])
        let service = EpisodeShowNotesService(database: harness.database, generator: generator)

        do {
            _ = try await service.generate(episodeID: harness.episodeID)
            XCTFail("Expected disabled feature to block transcript egress")
        } catch let error as EpisodeShowNotesError {
            XCTAssertEqual(error, .featureDisabled)
        }
        XCTAssertTrue(generator.receivedSegments.isEmpty)
    }

    func testShowNotesServiceCoalescesConcurrentGenerationForOneEpisode() async throws {
        let harness = try makeHarness()
        try setAdRemovalEnabled(harness.database)
        let jobStore = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        var job = try jobStore.enqueue(episodeID: harness.episodeID)
        let segment = AdTranscriptSegment(
            id: "segment-opening",
            index: 0,
            language: "en",
            startTime: 12.5,
            endTime: 30,
            text: "Episode content"
        )
        try jobStore.replaceTranscriptSegments(episodeID: harness.episodeID, segments: [segment])
        for stage in [
            AdRemovalJobStage.downloading,
            .downloaded,
            .transcribing,
            .classifying,
            .ready
        ] {
            job = try jobStore.transition(jobID: job.id, to: stage)
        }
        let generator = SuspendedShowNotesGenerator(drafts: [EpisodeShowNoteDraft(
            segmentID: segment.id,
            title: "Opening",
            summary: "The episode begins."
        )])
        let service = EpisodeShowNotesService(database: harness.database, generator: generator)
        let first = Task { try await service.generate(episodeID: harness.episodeID) }
        await generator.waitUntilEntered()
        let second = Task { try await service.generate(episodeID: harness.episodeID) }
        await Task.yield()

        let callsBeforeRelease = await generator.calls()
        XCTAssertEqual(callsBeforeRelease, 1)
        await generator.release()
        let firstNotes = try await first.value
        let secondNotes = try await second.value

        XCTAssertEqual(firstNotes, secondNotes)
        let callsAfterRelease = await generator.calls()
        XCTAssertEqual(callsAfterRelease, 1)
    }

    func testShowNotesCancelEpisodeWaitsUntilCapturedGenerationObservesCancellation() async throws {
        let harness = try makeHarness()
        let segment = try prepareReadyShowNotesEpisode(harness)
        let generator = CancellationHoldingShowNotesGenerator(drafts: [EpisodeShowNoteDraft(
            segmentID: segment.id,
            title: "Opening",
            summary: "The episode begins."
        )])
        let service = EpisodeShowNotesService(database: harness.database, generator: generator)
        let generation = Task { try await service.generate(episodeID: harness.episodeID) }
        await generator.waitUntilCalls(1)
        let completion = AsyncCompletionProbe()
        let cancellation = Task {
            await service.cancel(episodeID: harness.episodeID)
            await completion.markCompleted()
        }

        await generator.waitUntilCancellations(1)
        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease)
        do {
            _ = try await service.generate(episodeID: harness.episodeID)
            XCTFail("Expected the episode cancellation tombstone to block replacement generation")
        } catch let error as EpisodeShowNotesError {
            XCTAssertEqual(error, .sourceChanged)
        }
        let callsWhileCancelling = await generator.calls()
        XCTAssertEqual(callsWhileCancelling, 1)
        await generator.releaseCancelledCall()
        await cancellation.value

        let completedAfterRelease = await completion.isCompleted()
        XCTAssertTrue(completedAfterRelease)
        do {
            _ = try await generation.value
            XCTFail("Expected generation to report cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(
            try EpisodeShowNotesStore(database: harness.database).notes(episodeID: harness.episodeID).isEmpty
        )

        let replacement = Task { try await service.generate(episodeID: harness.episodeID) }
        await generator.waitUntilCalls(2)
        await generator.releaseSecondCall()
        let replacementNotes = try await replacement.value
        XCTAssertEqual(replacementNotes.map(\.id), [segment.id])
        let callsAfterCancellation = await generator.calls()
        XCTAssertEqual(callsAfterCancellation, 2)
    }

    func testShowNotesCancelAllBlocksReplacementUntilCapturedGenerationTerminates() async throws {
        let harness = try makeHarness()
        let segment = try prepareReadyShowNotesEpisode(harness)
        let generator = CancellationHoldingShowNotesGenerator(drafts: [EpisodeShowNoteDraft(
            segmentID: segment.id,
            title: "Opening",
            summary: "The episode begins."
        )])
        let service = EpisodeShowNotesService(database: harness.database, generator: generator)
        let oldGeneration = Task { try await service.generate(episodeID: harness.episodeID) }
        await generator.waitUntilCalls(1)
        let cancellation = Task { await service.cancelAll() }
        await generator.waitUntilCancellations(1)

        do {
            _ = try await service.generate(episodeID: harness.episodeID)
            XCTFail("Expected global cancellation state to block replacement generation")
        } catch let error as EpisodeShowNotesError {
            XCTAssertEqual(error, .featureDisabled)
        }
        let callsWhileCancelling = await generator.calls()
        XCTAssertEqual(callsWhileCancelling, 1)
        await generator.releaseCancelledCall()
        await cancellation.value
        do {
            _ = try await oldGeneration.value
            XCTFail("Expected old generation to report cancellation")
        } catch is CancellationError {
            // Expected.
        }

        // Generation becomes available again after the captured task is fully
        // drained, and subsequent callers still join that replacement.
        let replacement = Task { try await service.generate(episodeID: harness.episodeID) }
        await generator.waitUntilCalls(2)
        let coalesced = Task { try await service.generate(episodeID: harness.episodeID) }
        await Task.yield()
        let callsBeforeRelease = await generator.calls()
        XCTAssertEqual(callsBeforeRelease, 2)
        await generator.releaseSecondCall()

        let replacementNotes = try await replacement.value
        let coalescedNotes = try await coalesced.value
        XCTAssertEqual(replacementNotes, coalescedNotes)
        let callsAfterRelease = await generator.calls()
        XCTAssertEqual(callsAfterRelease, 2)
    }

    func testShowNotesGenerationRejectsAnAdCorrectionMadeWhileGenerationIsRunning() async throws {
        let harness = try makeHarness()
        try setAdRemovalEnabled(harness.database)
        let jobStore = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        var job = try jobStore.enqueue(episodeID: harness.episodeID)
        let segments = [
            AdTranscriptSegment(
                id: "segment-ad",
                index: 0,
                language: "en",
                startTime: 0,
                endTime: 10,
                text: "An incorrectly classified passage"
            ),
            AdTranscriptSegment(
                id: "segment-content",
                index: 1,
                language: "en",
                startTime: 10,
                endTime: 30,
                text: "The main discussion"
            )
        ]
        try jobStore.replaceTranscriptSegments(episodeID: harness.episodeID, segments: segments)
        try jobStore.replaceSkipRanges(episodeID: harness.episodeID, ranges: [AdSkipRange(
            id: "range-ad",
            startSegmentID: "segment-ad",
            endSegmentID: "segment-ad",
            startTime: 0,
            endTime: 10,
            confidence: 0.9,
            reason: "sponsor message",
            classifierVersion: "test/classifier",
            promptVersion: "classifier-prompt-v1",
            createdAt: 1_000,
            disabled: false
        )])
        for stage in [
            AdRemovalJobStage.downloading,
            .downloaded,
            .transcribing,
            .classifying,
            .ready
        ] {
            job = try jobStore.transition(jobID: job.id, to: stage)
        }
        let generator = SuspendedShowNotesGenerator(drafts: [EpisodeShowNoteDraft(
            segmentID: "segment-content",
            title: "Discussion",
            summary: "The main discussion begins."
        )])
        let service = EpisodeShowNotesService(database: harness.database, generator: generator)
        let generation = Task { try await service.generate(episodeID: harness.episodeID) }

        await generator.waitUntilEntered()
        _ = try jobStore.disableRangeAndAddCorrection(
            episodeID: harness.episodeID,
            rangeID: "range-ad"
        )
        await generator.release()

        do {
            _ = try await generation.value
            XCTFail("Expected the source-revision fence to reject stale notes")
        } catch let error as EpisodeShowNotesError {
            XCTAssertEqual(error, .sourceChanged)
        }
        XCTAssertTrue(
            try EpisodeShowNotesStore(database: harness.database).notes(episodeID: harness.episodeID).isEmpty
        )
    }

    func testShowNotesStoreReplaceIsAtomicAndPreservesChapterOrderAndMetadata() throws {
        let harness = try makeHarness()
        let store = EpisodeShowNotesStore(database: harness.database)
        let segments = [
            AdTranscriptSegment(
                id: "segment-opening",
                index: 0,
                language: "en",
                startTime: 5.88,
                endTime: 20,
                text: "Opening context"
            ),
            AdTranscriptSegment(
                id: "segment-topic",
                index: 1,
                language: "en",
                startTime: 125.25,
                endTime: 180,
                text: "A new direction"
            )
        ]
        let original = try store.replace(
            episodeID: harness.episodeID,
            segments: segments,
            drafts: [
                EpisodeShowNoteDraft(
                    segmentID: "segment-opening",
                    title: "Opening",
                    summary: "The episode gets underway."
                ),
                EpisodeShowNoteDraft(
                    segmentID: "segment-topic",
                    title: "New topic",
                    summary: "The discussion changes direction."
                )
            ],
            modelID: "test/model-original",
            promptVersion: "prompt-original",
            createdAt: 1_234
        )

        XCTAssertEqual(original.map(\.id), ["segment-opening", "segment-topic"])
        XCTAssertEqual(original.map(\.start_time), [5.88, 125.25])
        let storedMetadata = try harness.database.query(
            """
            SELECT chapter_index, model_id, prompt_version, created_at
            FROM episode_show_notes WHERE episode_id = ? ORDER BY chapter_index
            """,
            [.int(harness.episodeID)]
        ) { statement in
            (
                Int(sqlite3_column_int64(statement, 0)),
                sqliteString(statement, 1),
                sqliteString(statement, 2),
                sqlite3_column_int64(statement, 3)
            )
        }
        XCTAssertEqual(storedMetadata.map(\.0), [0, 1])
        XCTAssertEqual(storedMetadata.map(\.1), ["test/model-original", "test/model-original"])
        XCTAssertEqual(storedMetadata.map(\.2), ["prompt-original", "prompt-original"])
        XCTAssertEqual(storedMetadata.map(\.3), [1_234, 1_234])

        XCTAssertThrowsError(try store.replace(
            episodeID: harness.episodeID,
            segments: segments,
            drafts: [
                EpisodeShowNoteDraft(
                    segmentID: "segment-opening",
                    title: "Replacement one",
                    summary: "This transaction must roll back."
                ),
                EpisodeShowNoteDraft(
                    segmentID: "segment-opening",
                    title: "Replacement duplicate",
                    summary: "The duplicate segment violates the uniqueness constraint."
                )
            ],
            modelID: "test/model-replacement",
            promptVersion: "prompt-replacement",
            createdAt: 9_999
        ))
        XCTAssertEqual(try store.notes(episodeID: harness.episodeID), original)
        XCTAssertEqual(
            try harness.database.scalarInt64(
                "SELECT COUNT(*) FROM episode_show_notes WHERE episode_id = ? AND created_at = ?",
                [.int(harness.episodeID), .int(1_234)]
            ),
            2
        )
    }

    func testEpisodeMetadataCleanupRetainsPersistedShowNotesForPlayedArchive() throws {
        let harness = try makeHarness()
        let jobStore = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        _ = try jobStore.enqueue(episodeID: harness.episodeID)
        let segment = AdTranscriptSegment(
            id: "segment-opening",
            index: 0,
            language: "en",
            startTime: 12.5,
            endTime: 30,
            text: "Episode content"
        )
        try jobStore.replaceTranscriptSegments(episodeID: harness.episodeID, segments: [segment])
        let notesStore = EpisodeShowNotesStore(database: harness.database)
        let notes = try notesStore.replace(
            episodeID: harness.episodeID,
            segments: [segment],
            drafts: [EpisodeShowNoteDraft(
                segmentID: segment.id,
                title: "Episode opening",
                summary: "The main discussion begins."
            )],
            modelID: "test/show-notes",
            promptVersion: "show-notes-prompt-v1",
            createdAt: 1_000
        )

        try jobStore.cleanupEpisode(episodeID: harness.episodeID)

        XCTAssertNil(try jobStore.job(episodeID: harness.episodeID))
        XCTAssertTrue(try jobStore.transcriptSegments(episodeID: harness.episodeID).isEmpty)
        XCTAssertEqual(try notesStore.notes(episodeID: harness.episodeID), notes)
    }

    func testShowNotesGenerationCannotWriteAfterEpisodeMetadataCleanup() async throws {
        let harness = try makeHarness()
        try setAdRemovalEnabled(harness.database)
        let jobStore = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        var job = try jobStore.enqueue(episodeID: harness.episodeID)
        let segment = AdTranscriptSegment(
            id: "segment-opening",
            index: 0,
            language: "en",
            startTime: 12.5,
            endTime: 30,
            text: "Episode content"
        )
        try jobStore.replaceTranscriptSegments(episodeID: harness.episodeID, segments: [segment])
        for stage in [
            AdRemovalJobStage.downloading,
            .downloaded,
            .transcribing,
            .classifying,
            .ready
        ] {
            job = try jobStore.transition(jobID: job.id, to: stage)
        }
        XCTAssertEqual(job.stage, .ready)
        let generator = SuspendedShowNotesGenerator(drafts: [EpisodeShowNoteDraft(
            segmentID: segment.id,
            title: "Episode opening",
            summary: "The main discussion begins."
        )])
        let service = EpisodeShowNotesService(database: harness.database, generator: generator)
        let generation = Task { try await service.generate(episodeID: harness.episodeID) }

        await generator.waitUntilEntered()
        try jobStore.cleanupEpisode(episodeID: harness.episodeID)
        await generator.release()

        do {
            _ = try await generation.value
            XCTFail("Expected cleanup to fence the stale generation")
        } catch let error as EpisodeShowNotesError {
            XCTAssertEqual(error, .notReady)
        }
        XCTAssertTrue(
            try EpisodeShowNotesStore(database: harness.database).notes(episodeID: harness.episodeID).isEmpty
        )
    }

    func testCoordinatorCommitsEachStageBeforeExecutingAndReachesReady() async throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        let executor = RecordingStageExecutor(store: store)
        let readyEpisodes = ReadyEpisodeProbe()
        let coordinator = AdRemovalCoordinator(
            store: store,
            executor: executor,
            readyHandler: { episodeID in await readyEpisodes.record(episodeID) }
        )

        let afterDownload = try await coordinator.runNextStage()
        let afterTranscription = try await coordinator.runNextStage()
        let afterClassification = try await coordinator.runNextStage()
        XCTAssertEqual(afterDownload?.stage, .downloaded)
        XCTAssertEqual(afterTranscription?.stage, .classifying)
        XCTAssertEqual(afterClassification?.stage, .ready)

        XCTAssertEqual(executor.executedStages, [.downloading, .transcribing, .classifying])
        XCTAssertEqual(executor.durableStagesSeen, [.downloading, .transcribing, .classifying])
        XCTAssertEqual(try store.job(id: queued.id)?.stage, .ready)
        let recordedReadyEpisodes = await readyEpisodes.recordedEpisodeIDs()
        XCTAssertEqual(recordedReadyEpisodes, [harness.episodeID])
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

    func testSchedulerClearsModelRequiredWhenOnDeviceModelIsAvailable() async throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        _ = try store.setBlockingReason(jobID: queued.id, reason: .modelRequired)
        let executor = RecordingStageExecutor(store: store)
        let scheduler = AdRemovalPipelineScheduler(
            store: store,
            coordinator: AdRemovalCoordinator(store: store, executor: executor),
            conditions: { .init(lowPowerMode: false, seriousThermalPressure: false) },
            isOnDeviceModelAvailable: { true }
        )

        await scheduler.runUntilIdle()

        XCTAssertEqual(try store.job(id: queued.id)?.stage, .ready)
        XCTAssertNil(try store.job(id: queued.id)?.blockingReason)
        XCTAssertEqual(executor.executedStages, [.downloading, .transcribing, .classifying])
    }

    func testSchedulerLeavesModelRequiredBlockedWhenOnDeviceModelIsUnavailable() async throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        _ = try store.setBlockingReason(jobID: queued.id, reason: .modelRequired)
        let executor = RecordingStageExecutor(store: store)
        let scheduler = AdRemovalPipelineScheduler(
            store: store,
            coordinator: AdRemovalCoordinator(store: store, executor: executor),
            conditions: { .init(lowPowerMode: false, seriousThermalPressure: false) },
            isOnDeviceModelAvailable: { false }
        )

        await scheduler.runUntilIdle()

        XCTAssertEqual(try store.job(id: queued.id)?.stage, .queued)
        XCTAssertEqual(try store.job(id: queued.id)?.blockingReason, .modelRequired)
        XCTAssertTrue(executor.executedStages.isEmpty)
    }

    func testTransientPolicyClearLeavesModelRequiredJobsBlocked() throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        _ = try store.setBlockingReason(jobID: queued.id, reason: .modelRequired)

        try store.clearTransientPolicyBlockingReasons()

        XCTAssertEqual(try store.job(id: queued.id)?.blockingReason, .modelRequired)
        XCTAssertNil(try store.nextRunnableJob())

        try store.clearBlockingReasons([.modelRequired])
        XCTAssertNil(try store.job(id: queued.id)?.blockingReason)
        XCTAssertEqual(try store.nextRunnableJob()?.id, queued.id)
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

    func testSchedulingPolicyKeepsAdRemovalRunningDuringPlayback() {
        XCTAssertNil(AdRemovalSchedulingPolicy.blockingReason(
            for: .downloading,
            conditions: .init(lowPowerMode: true, seriousThermalPressure: true)
        ))
        XCTAssertNil(AdRemovalSchedulingPolicy.blockingReason(
            for: .transcribing,
            conditions: .init(lowPowerMode: false, seriousThermalPressure: false)
        ))
        XCTAssertNil(AdRemovalSchedulingPolicy.blockingReason(
            for: .classifying,
            conditions: .init(lowPowerMode: true, seriousThermalPressure: true)
        ))
    }

    func testSchedulingPolicyOnlyPausesLocalTranscriptionForResourcePressure() {
        XCTAssertEqual(AdRemovalSchedulingPolicy.blockingReason(
            for: .transcribing,
            conditions: .init(lowPowerMode: true, seriousThermalPressure: false)
        ), .lowPower)
        XCTAssertEqual(AdRemovalSchedulingPolicy.blockingReason(
            for: .transcribing,
            conditions: .init(lowPowerMode: false, seriousThermalPressure: true)
        ), .thermalPressure)
    }

    func testSchedulerDownloadsDuringLowPowerThenResumesComputeUntilReady() async throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: harness.episodeID)
        let executor = RecordingStageExecutor(store: store)
        let coordinator = AdRemovalCoordinator(store: store, executor: executor)
        var conditions = AdRemovalRuntimeConditions(
            lowPowerMode: true,
            seriousThermalPressure: false
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

        conditions = .init(lowPowerMode: false, seriousThermalPressure: false)
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
                .init(lowPowerMode: false, seriousThermalPressure: false)
            }
        )

        await scheduler.runUntilIdle()

        XCTAssertEqual(try store.job(id: queued.id)?.stage, .queued)
        XCTAssertTrue(executor.executedStages.isEmpty)
    }

    func testConcurrentRunUntilIdleReportsBusyWhileOwnerCompletesSuccessfully() async throws {
        let harness = try makeHarness()
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        _ = try store.enqueue(episodeID: harness.episodeID)
        let executor = ControllableStageExecutor()
        let scheduler = AdRemovalPipelineScheduler(
            store: store,
            coordinator: AdRemovalCoordinator(store: store, executor: executor),
            conditions: { .init(lowPowerMode: false, seriousThermalPressure: false) }
        )

        async let firstResult = scheduler.runUntilIdle()
        await executor.waitUntilEntered()

        let secondResult = await scheduler.runUntilIdle()
        XCTAssertEqual(secondResult, .busy)

        await executor.release()
        let ownedResult = await firstResult
        XCTAssertEqual(ownedResult, .completed)
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

    private func setAdRemovalEnabled(_ database: PodsDatabase) throws {
        try database.execute(
            """
            INSERT INTO settings (key, value) VALUES ('ad_removal_enabled', 'true')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
    }

    private func prepareReadyShowNotesEpisode(_ harness: Harness) throws -> AdTranscriptSegment {
        try setAdRemovalEnabled(harness.database)
        let jobStore = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        var job = try jobStore.enqueue(episodeID: harness.episodeID)
        let segment = AdTranscriptSegment(
            id: "segment-opening",
            index: 0,
            language: "en",
            startTime: 12.5,
            endTime: 30,
            text: "Episode content"
        )
        try jobStore.replaceTranscriptSegments(episodeID: harness.episodeID, segments: [segment])
        for stage in [
            AdRemovalJobStage.downloading,
            .downloaded,
            .transcribing,
            .classifying,
            .ready
        ] {
            job = try jobStore.transition(jobID: job.id, to: stage)
        }
        XCTAssertEqual(job.stage, .ready)
        return segment
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
