import XCTest
@testable import Pods

final class AdRemovalTranscriptionTests: XCTestCase {
    private final class UnusedDownloader: AdRemovalAudioDownloading {
        func download(job: AdRemovalJob, sourceURL: URL) async throws -> AdRemovalAudioArtifact {
            throw AdRemovalPipelineError.unsupportedStage(.downloading)
        }
    }

    private final class FakeTranscriber: AdTranscribing {
        let version = "fake-transcriber-v1"
        var result: Result<[AdTranscriptSegment], Error>
        private(set) var requestedAudioURL: URL?

        init(result: Result<[AdTranscriptSegment], Error>) {
            self.result = result
        }

        func transcribe(audioURL: URL, episodeID: Int64) async throws -> [AdTranscriptSegment] {
            requestedAudioURL = audioURL
            return try result.get()
        }
    }

    func testPipelinePersistsFinalizedSegmentsAndVersionBeforeClassification() async throws {
        let harness = try makeHarness()
        let segments = [
            AdTranscriptSegment(
                id: "segment-000000-000010000-000014000",
                index: 0,
                language: "en-US",
                startTime: 10,
                endTime: 14,
                text: "This episode is brought to you by Example."
            ),
            AdTranscriptSegment(
                id: "segment-000001-000014000-000019000",
                index: 1,
                language: "en-US",
                startTime: 14,
                endTime: 19,
                text: "Use offer code PODS."
            )
        ]
        let transcriber = FakeTranscriber(result: .success(segments))
        let executor = AdRemovalPipelineExecutor(
            database: harness.database,
            jobStore: harness.jobStore,
            artifactStore: harness.artifactStore,
            audioDownloader: UnusedDownloader(),
            transcriber: transcriber
        )
        let coordinator = AdRemovalCoordinator(store: harness.jobStore, executor: executor)

        let completed = try await coordinator.runNextStage()

        XCTAssertEqual(completed?.stage, .classifying)
        XCTAssertEqual(try harness.jobStore.transcriptSegments(episodeID: harness.episodeID), segments)
        XCTAssertEqual(try harness.jobStore.job(id: harness.job.id)?.transcriberVersion, "fake-transcriber-v1")
        XCTAssertEqual(try harness.jobStore.job(id: harness.job.id)?.transcribedAt, 1_000)
        XCTAssertEqual(transcriber.requestedAudioURL, try harness.artifactStore.url(for: harness.artifact.relativePath))
    }

    func testCoordinatorCancellationLeavesTranscribingStageRestartableWithoutConsumingRetry() async throws {
        let harness = try makeHarness()
        let transcriber = FakeTranscriber(result: .failure(CancellationError()))
        let executor = AdRemovalPipelineExecutor(
            database: harness.database,
            jobStore: harness.jobStore,
            artifactStore: harness.artifactStore,
            audioDownloader: UnusedDownloader(),
            transcriber: transcriber
        )
        let coordinator = AdRemovalCoordinator(store: harness.jobStore, executor: executor)

        do {
            _ = try await coordinator.runNextStage()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected expiration/cancellation boundary.
        }

        let persisted = try harness.jobStore.job(id: harness.job.id)
        XCTAssertEqual(persisted?.stage, .transcribing)
        XCTAssertEqual(persisted?.attemptCount, 0)
        XCTAssertNil(persisted?.lastErrorCode)
        XCTAssertEqual(try harness.jobStore.nextRunnableJob()?.id, harness.job.id)
    }

    func testSegmentFactoryProducesStableOriginalTimelineIdentifiers() throws {
        let first = try AdTranscriptSegmentFactory.make(
            index: 7,
            language: "en-US",
            startTime: 12.3454,
            endTime: 18.9016,
            text: "  Finalized transcript text.  "
        )
        let repeated = try AdTranscriptSegmentFactory.make(
            index: 7,
            language: "en-US",
            startTime: 12.3454,
            endTime: 18.9016,
            text: "  Finalized transcript text.  "
        )

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.id, "segment-000007-000012345-000018902")
        XCTAssertEqual(first.text, "Finalized transcript text.")
        XCTAssertThrowsError(try AdTranscriptSegmentFactory.make(
            index: 0,
            language: "en-US",
            startTime: 5,
            endTime: 4,
            text: "invalid"
        ))
    }

    func testResultAccumulatorKeepsValidFinalizedSegmentsWhenAnotherResultIsInvalid() throws {
        var accumulator = AdTranscriptResultAccumulator(language: "en-US")

        accumulator.consume(isFinal: false, startTime: 0, endTime: 1, text: "Draft")
        accumulator.consume(isFinal: true, startTime: 10, endTime: 14, text: "Valid segment")
        accumulator.consume(isFinal: true, startTime: 14, endTime: 14, text: "Invalid range")

        XCTAssertEqual(accumulator.segments.count, 1)
        XCTAssertEqual(accumulator.segments.first?.text, "Valid segment")
        XCTAssertEqual(accumulator.observedFinalResultCount, 2)
        XCTAssertEqual(accumulator.rejectedFinalResultCount, 1)
    }

    func testTranscriptionErrorsExposeStableSpecificNSErrorCodes() {
        let errors: [(AdRemovalTranscriptionError, Int)] = [
            (.invalidSegment, 1),
            (.speechTranscriberUnavailable, 2),
            (.englishLocaleUnsupported, 3),
            (.speechModelUnavailable, 4),
            (.noFinalizedResults, 5)
        ]

        for (error, expectedCode) in errors {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "Pods.AdRemovalTranscriptionError")
            XCTAssertEqual(nsError.code, expectedCode)
            XCTAssertFalse(nsError.localizedDescription.isEmpty)
        }
    }

    private struct Harness {
        let database: PodsDatabase
        let jobStore: AdRemovalJobStore
        let artifactStore: AdRemovalArtifactStore
        let episodeID: Int64
        let job: AdRemovalJob
        let artifact: AdRemovalAudioArtifact
    }

    private func makeHarness() throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
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
        let episodeID = database.lastInsertRowID()
        let artifactStore = try AdRemovalArtifactStore(rootURL: directory.appendingPathComponent("AdRemoval"))
        let temporaryAudio = directory.appendingPathComponent("audio.tmp")
        try Data("audio".utf8).write(to: temporaryAudio)
        let artifact = try artifactStore.installDownloadedAudio(
            from: temporaryAudio,
            episodeID: episodeID,
            fileExtension: "mp3"
        )
        let jobStore = AdRemovalJobStore(database: database, now: { 1_000 })
        let queued = try jobStore.enqueue(episodeID: episodeID)
        _ = try jobStore.transition(jobID: queued.id, to: .downloading)
        _ = try jobStore.recordAudioArtifact(jobID: queued.id, artifact: artifact)
        let job = try jobStore.transition(jobID: queued.id, to: .downloaded)
        return Harness(
            database: database,
            jobStore: jobStore,
            artifactStore: artifactStore,
            episodeID: episodeID,
            job: job,
            artifact: artifact
        )
    }
}
