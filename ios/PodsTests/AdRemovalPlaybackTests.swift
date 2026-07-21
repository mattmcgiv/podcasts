import XCTest
@testable import Pods

final class AdRemovalPlaybackTests: XCTestCase {
    func testPureSkipPolicyUsesOriginalTimelineAndIgnoresDisabledOrEndedRanges() {
        let ranges = [
            range(id: "first", start: 10, end: 20),
            range(id: "disabled", start: 30, end: 40, disabled: true)
        ]

        XCTAssertEqual(
            AdRemovalSkipPolicy.decision(position: 10, ranges: ranges),
            AdRemovalSkipDecision(rangeID: "first", rangeStart: 10, rangeEnd: 20)
        )
        XCTAssertEqual(
            AdRemovalSkipPolicy.decision(position: 19.999, ranges: ranges)?.targetPosition,
            20
        )
        XCTAssertNil(AdRemovalSkipPolicy.decision(position: 20, ranges: ranges))
        XCTAssertNil(AdRemovalSkipPolicy.decision(position: 35, ranges: ranges))
        XCTAssertNil(AdRemovalSkipPolicy.decision(position: 9.999, ranges: ranges))
    }

    func testSkipSessionKeepsOnePendingActionReplacesItAndDisablesUndoRange() {
        var session = AdRemovalSkipSession(ranges: [
            range(id: "first", start: 10, end: 20),
            range(id: "second", start: 30, end: 45)
        ])

        let first = session.enter(position: 12)
        XCTAssertEqual(first?.rangeID, "first")
        session.didComplete(try! XCTUnwrap(first))
        XCTAssertEqual(session.pending?.skippedDuration, 10)
        let second = session.enter(position: 31)
        XCTAssertEqual(second?.rangeID, "second")
        // Starting another asynchronous seek must not retarget the visible Undo.
        XCTAssertEqual(session.pending?.rangeID, "first")
        session.didComplete(try! XCTUnwrap(second))
        XCTAssertEqual(session.pending?.rangeID, "second")

        session.didUndo(rangeID: "second")

        XCTAssertNil(session.pending)
        XCTAssertNil(session.enter(position: 31))
        XCTAssertEqual(session.enter(position: 12)?.rangeID, "first")
    }

    func testMacTimeUpdateEnteringEnabledRangeProducesAutomaticSkipDecision() {
        var session = AdRemovalSkipSession(ranges: [
            range(id: "opening-ad", start: 5.88, end: 129.3)
        ])

        XCTAssertNil(session.enterMacTransportEvent(type: "timeupdate", position: 5.87))
        XCTAssertEqual(
            session.enterMacTransportEvent(type: "timeupdate", position: 5.88),
            AdRemovalSkipDecision(rangeID: "opening-ad", rangeStart: 5.88, rangeEnd: 129.3)
        )
        XCTAssertNil(session.enterMacTransportEvent(type: "pause", position: 6))
    }

    func testMacAutomaticSkipSuppressesPostAcknowledgementStaleClockAndDeduplicatesRange() {
        let decision = AdRemovalSkipDecision(
            rangeID: "opening-ad",
            rangeStart: 5.88,
            rangeEnd: 129.3
        )
        let started = Date(timeIntervalSince1970: 1_000)
        var state = AdRemovalMacSkipState()
        let attempt = try! XCTUnwrap(state.begin(
            decision: decision,
            lifecycleToken: 7,
            now: started
        ))

        XCTAssertEqual(
            state.observe(position: 6, lifecycleToken: 7),
            .suppress
        )
        // A stale high clock from a superseded seek is not an acknowledgement;
        // the speaker's phone-compatible acknowledgement lands at the target.
        XCTAssertEqual(
            state.observe(position: 200, lifecycleToken: 7),
            .suppress
        )
        XCTAssertEqual(
            state.observe(position: 129.3, lifecycleToken: 7),
            .completed(attempt)
        )
        // A clock queued before the seek must stay fenced even though target ack
        // already completed the UI event.
        XCTAssertEqual(
            state.observe(position: 6.5, lifecycleToken: 7),
            .suppress
        )
        // Later monotonic progress passes through, but cannot lower the lifecycle's
        // completed-seek floor; even a very late pre-seek clock stays fenced.
        XCTAssertEqual(
            state.observe(position: 129.5, lifecycleToken: 7),
            .passThrough
        )
        XCTAssertEqual(state.observe(position: 6.5, lifecycleToken: 7), .suppress)
        XCTAssertNil(state.begin(
            decision: decision,
            lifecycleToken: 7,
            now: started.addingTimeInterval(3)
        ))
    }

    func testSupersedingBackwardMacSeekFencesOldAutomaticClocksUntilSettled() {
        var fence = AdRemovalMacSupersedingSeekFence(targetPosition: 5.88)

        XCTAssertEqual(fence.observe(position: 129.3), .suppress)
        XCTAssertEqual(fence.observe(position: 5.88), .acknowledged)
        // The immediate target acknowledgement can precede an older periodic clock.
        XCTAssertEqual(fence.observe(position: 129.55), .suppress)
        XCTAssertEqual(fence.observe(position: 6.1), .settled)
    }

    func testMacAutomaticSkipTimeoutRetriesWithoutAClockAndRejectsStaleCallbacks() {
        let decision = AdRemovalSkipDecision(
            rangeID: "opening-ad",
            rangeStart: 5.88,
            rangeEnd: 129.3
        )
        let started = Date(timeIntervalSince1970: 1_000)
        var state = AdRemovalMacSkipState()
        let first = try! XCTUnwrap(state.begin(
            decision: decision,
            lifecycleToken: 3,
            now: started
        ))

        // This is the same transition used by AudioBridge's independent main-queue
        // retry work item; no transport observation is required.
        let firstRetry = state.retry(
            attemptToken: first.token,
            lifecycleToken: 3,
            now: started.addingTimeInterval(2),
            maximumAttempts: 3
        )
        guard case .retry(let retry) = firstRetry else {
            return XCTFail("Expected first no-clock timeout to retry")
        }
        XCTAssertEqual(retry.attemptNumber, 2)
        XCTAssertEqual(retry.startedAt, first.startedAt)
        XCTAssertFalse(state.acceptsDelivery(
            attemptToken: first.token,
            lifecycleToken: 3
        ))
        XCTAssertTrue(state.acceptsDelivery(
            attemptToken: retry.token,
            lifecycleToken: 3
        ))
        XCTAssertEqual(state.retry(
            attemptToken: first.token,
            lifecycleToken: 3,
            now: started.addingTimeInterval(4),
            maximumAttempts: 3
        ), .ignored)

        let secondRetry = state.retry(
            attemptToken: retry.token,
            lifecycleToken: 3,
            now: started.addingTimeInterval(4),
            maximumAttempts: 3
        )
        guard case .retry(let lastAttempt) = secondRetry else {
            return XCTFail("Expected second no-clock timeout to retry")
        }
        XCTAssertEqual(lastAttempt.attemptNumber, 3)
        XCTAssertEqual(state.retry(
            attemptToken: lastAttempt.token,
            lifecycleToken: 3,
            now: started.addingTimeInterval(6),
            maximumAttempts: 3
        ), .exhausted(lastAttempt))
        XCTAssertNil(state.inFlight)
        // Terminal failure blocks another cycle for the same range until a
        // lifecycle invalidation (seek/reconnect/load) occurs.
        XCTAssertNil(state.begin(
            decision: decision,
            lifecycleToken: 3,
            now: started.addingTimeInterval(7)
        ))
    }

    func testMacAutomaticSkipDropInvalidationAndReconnectStartFreshLifecycle() {
        let decision = AdRemovalSkipDecision(
            rangeID: "opening-ad",
            rangeStart: 5.88,
            rangeEnd: 129.3
        )
        let started = Date(timeIntervalSince1970: 1_000)
        var state = AdRemovalMacSkipState()
        let dropped = try! XCTUnwrap(state.begin(
            decision: decision,
            lifecycleToken: 11,
            now: started
        ))
        XCTAssertTrue(state.acceptsDelivery(
            attemptToken: dropped.token,
            lifecycleToken: 11
        ))

        // Cast disconnect/error invalidates the attempt and its timer token.
        state.invalidate()
        XCTAssertFalse(state.acceptsDelivery(
            attemptToken: dropped.token,
            lifecycleToken: 11
        ))
        XCTAssertEqual(state.retry(
            attemptToken: dropped.token,
            lifecycleToken: 11,
            now: started.addingTimeInterval(2),
            maximumAttempts: 3
        ), .ignored)

        // Once CastSession reconnects, a new timeupdate can begin a fresh attempt.
        let reconnected = try! XCTUnwrap(state.begin(
            decision: decision,
            lifecycleToken: 12,
            now: started.addingTimeInterval(3)
        ))
        XCTAssertNotEqual(reconnected.token, dropped.token)
        XCTAssertEqual(reconnected.attemptNumber, 1)
    }

    func testAutomaticSkipLifecycleRejectsCompletionAfterPlaybackChanges() {
        var lifecycle = AdRemovalSkipLifecycle()
        let oldPlayback = lifecycle.generation

        XCTAssertTrue(lifecycle.accepts(oldPlayback))
        lifecycle.invalidate()

        XCTAssertFalse(lifecycle.accepts(oldPlayback))
        XCTAssertTrue(lifecycle.accepts(lifecycle.generation))
    }

    func testPreparedPlaybackUsesValidatedDownloadedBytesAndFallsBackWhenIncompleteOrCorrupt() throws {
        let harness = try makeReadyHarness()
        let provider = AdRemovalPlaybackStore(
            database: harness.database,
            jobStore: harness.jobStore,
            artifactStore: harness.artifactStore
        )

        let prepared = try XCTUnwrap(provider.downloadedEpisode(episodeID: harness.episodeID))
        XCTAssertTrue(prepared.audioURL.isFileURL)
        XCTAssertTrue(prepared.manifestReady)
        XCTAssertEqual(prepared.ranges, [harness.range])
        XCTAssertEqual(prepared.originalDuration, 40)

        try Data("corrupt".utf8).write(to: prepared.audioURL, options: .atomic)
        XCTAssertNil(try provider.downloadedEpisode(episodeID: harness.episodeID))

        let secondEpisodeID = try insertEpisode(database: harness.database, guid: "episode-2")
        _ = try harness.jobStore.enqueue(episodeID: secondEpisodeID)
        XCTAssertNil(try provider.downloadedEpisode(episodeID: secondEpisodeID))
    }

    func testPlaybackSourcesPreferDownloadedBytesBeforeManifestAndNeverSendFileURLToMac() throws {
        let harness = try makeReadyHarness()
        let downloaded = AdRemovalDownloadedEpisode(
            episodeID: harness.episodeID,
            podcastID: harness.podcastID,
            audioURL: URL(fileURLWithPath: "/private/audio.mp3"),
            originalDuration: 40,
            ranges: [],
            manifestReady: false
        )
        let publisher = try XCTUnwrap(URL(string: "https://publisher.example/episode.mp3"))
        let authenticatedStream = try XCTUnwrap(
            URL(string: "http://192.168.1.2:9000/episode/1?token=secret")
        )

        XCTAssertEqual(
            AdRemovalPlaybackSourcePolicy.localSource(publisher: publisher, downloaded: downloaded),
            downloaded.audioURL
        )
        XCTAssertNil(
            AdRemovalPlaybackSourcePolicy.macSource(
                publisher: publisher,
                downloaded: downloaded,
                authenticatedStream: nil
            )
        )
        XCTAssertEqual(
            AdRemovalPlaybackSourcePolicy.macSource(
                publisher: publisher,
                downloaded: downloaded,
                authenticatedStream: authenticatedStream
            ),
            authenticatedStream
        )
        XCTAssertEqual(
            AdRemovalPlaybackSourcePolicy.macSource(
                publisher: publisher,
                downloaded: nil,
                authenticatedStream: nil
            ),
            publisher
        )
    }

    func testUndoAtomicallyDisablesRangeAndCreatesPodcastScopedCorrectionWithContext() throws {
        let harness = try makeReadyHarness()
        let provider = AdRemovalPlaybackStore(
            database: harness.database,
            jobStore: harness.jobStore,
            artifactStore: harness.artifactStore
        )

        let result = try provider.undoSkip(episodeID: harness.episodeID, rangeID: harness.range.id)

        XCTAssertEqual(result.seekPosition, harness.range.startTime)
        XCTAssertEqual(result.disabledRangeID, harness.range.id)
        XCTAssertTrue(try XCTUnwrap(
            harness.jobStore.skipRanges(episodeID: harness.episodeID).first
        ).disabled)
        let corrections = try harness.jobStore.corrections(podcastID: harness.podcastID)
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections[0].podcastID, harness.podcastID)
        XCTAssertTrue(corrections[0].transcriptWindow.contains("Editorial lead-in"))
        XCTAssertTrue(corrections[0].transcriptWindow.contains("Sponsor call to action"))
        XCTAssertTrue(corrections[0].transcriptWindow.contains("Interview resumes"))
        XCTAssertTrue(corrections[0].classificationContext.contains(harness.range.id))
    }

    private struct Harness {
        let database: PodsDatabase
        let jobStore: AdRemovalJobStore
        let artifactStore: AdRemovalArtifactStore
        let podcastID: Int64
        let episodeID: Int64
        let range: AdSkipRange
    }

    private func makeReadyHarness() throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdRemovalPlaybackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try PodsDatabase(url: directory.appendingPathComponent("test.sqlite"))
        try database.execute(
            "INSERT INTO podcasts (feed_url, title, created_at) VALUES (?, ?, ?)",
            [.text("https://example.com/feed"), .text("Example"), .int(1)]
        )
        let podcastID = database.lastInsertRowID()
        let episodeID = try insertEpisode(database: database, guid: "episode-1", podcastID: podcastID)
        let artifactStore = try AdRemovalArtifactStore(rootURL: directory.appendingPathComponent("AdRemoval"))
        let downloaded = directory.appendingPathComponent("audio.tmp")
        try Data("exact downloaded audio".utf8).write(to: downloaded)
        let artifact = try artifactStore.installDownloadedAudio(
            from: downloaded,
            episodeID: episodeID,
            fileExtension: "mp3"
        )
        let jobStore = AdRemovalJobStore(database: database, now: { 1_000 })
        let job = try jobStore.enqueue(episodeID: episodeID)
        _ = try jobStore.transition(jobID: job.id, to: .downloading)
        _ = try jobStore.recordAudioArtifact(jobID: job.id, artifact: artifact)
        _ = try jobStore.transition(jobID: job.id, to: .downloaded)
        _ = try jobStore.transition(jobID: job.id, to: .transcribing)
        let segments = [
            AdTranscriptSegment(id: "segment-0", index: 0, language: "en-US", startTime: 0, endTime: 10, text: "Editorial lead-in"),
            AdTranscriptSegment(id: "segment-1", index: 1, language: "en-US", startTime: 10, endTime: 20, text: "Sponsor call to action"),
            AdTranscriptSegment(id: "segment-2", index: 2, language: "en-US", startTime: 20, endTime: 30, text: "Use the promo code"),
            AdTranscriptSegment(id: "segment-3", index: 3, language: "en-US", startTime: 30, endTime: 40, text: "Interview resumes")
        ]
        _ = try jobStore.recordTranscript(jobID: job.id, segments: segments, transcriberVersion: "speech-v1")
        _ = try jobStore.transition(jobID: job.id, to: .classifying)
        let range = AdSkipRange(
            id: "ad-segment-1--segment-2",
            startSegmentID: "segment-1",
            endSegmentID: "segment-2",
            startTime: 10,
            endTime: 30,
            confidence: 0.91,
            reason: "sponsor offer",
            classifierVersion: "test/model@revision-1",
            promptVersion: "prompt-v1",
            createdAt: 1_000,
            disabled: false
        )
        try jobStore.replaceSkipRanges(episodeID: episodeID, ranges: [range])
        _ = try jobStore.transition(jobID: job.id, to: .ready)
        return Harness(
            database: database,
            jobStore: jobStore,
            artifactStore: artifactStore,
            podcastID: podcastID,
            episodeID: episodeID,
            range: range
        )
    }

    private func insertEpisode(
        database: PodsDatabase,
        guid: String,
        podcastID: Int64? = nil
    ) throws -> Int64 {
        let resolvedPodcastID = try podcastID ?? XCTUnwrap(
            database.scalarInt64("SELECT id FROM podcasts ORDER BY id LIMIT 1")
        )
        try database.execute(
            "INSERT INTO episodes (podcast_id, guid, title, audio_url, duration_secs, published_at) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .int(resolvedPodcastID),
                .text(guid),
                .text("Episode"),
                .text("https://example.com/\(guid).mp3"),
                .int(40),
                .int(100)
            ]
        )
        return database.lastInsertRowID()
    }

    private func range(id: String, start: Double, end: Double, disabled: Bool = false) -> AdSkipRange {
        AdSkipRange(
            id: id,
            startSegmentID: "start",
            endSegmentID: "end",
            startTime: start,
            endTime: end,
            confidence: 0.9,
            reason: "ad",
            classifierVersion: "classifier",
            promptVersion: "prompt",
            createdAt: 1,
            disabled: disabled
        )
    }
}

final class PlaybackSpeedDiagnosticsTests: XCTestCase {
    func testObservationConsumesThePendingCorrelationOnlyOnce() {
        var tracker = PlaybackSpeedDiagnosticTracker()
        tracker.begin(correlationID: "speed-123", requestedRate: 2.5)

        XCTAssertEqual(tracker.takeObservation()?.correlationID, "speed-123")
        XCTAssertNil(tracker.takeObservation())
    }

    func testTemporaryDiagnosticLogRemainsEnabledForSpeedInvestigation() throws {
        let investigationDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")
        )
        XCTAssertTrue(PodsTemporaryDebugLog.isEnabled(now: investigationDate))
    }
}
