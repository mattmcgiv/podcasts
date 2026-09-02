import XCTest
@testable import Pods

final class DeepSeekUsageTests: XCTestCase {
    private final class MemoryUsageStore: DeepSeekUsageRecording {
        private(set) var records: [(
            episodeID: Int64,
            requestKind: DeepSeekRequestKind,
            model: String,
            usage: DeepSeekAPIUsage?,
            createdAt: Date
        )] = []

        func record(
            episodeID: Int64,
            requestKind: DeepSeekRequestKind,
            model: String,
            usage: DeepSeekAPIUsage?,
            createdAt: Date
        ) throws {
            records.append((episodeID, requestKind, model, usage, createdAt))
        }
    }

    private final class ThrowingUsageStore: DeepSeekUsageRecording {
        func record(
            episodeID: Int64,
            requestKind: DeepSeekRequestKind,
            model: String,
            usage: DeepSeekAPIUsage?,
            createdAt: Date
        ) throws {
            throw DeepSeekClassifierError.invalidResponse
        }
    }

    private final class StubCredentialStore: DeepSeekCredentialStoring {
        var hasAPIKey: Bool { true }
        func readAPIKey() throws -> String? { "test-api-key" }
        func saveAPIKey(_ value: String) throws {}
    }

    func testParseUsageReadsDeepSeekTokenFields() {
        XCTAssertEqual(
            DeepSeekAPIUsage.parse(from: [
                "usage": [
                    "prompt_tokens": 1_000,
                    "completion_tokens": 50,
                    "total_tokens": 1_050,
                    "prompt_cache_hit_tokens": 100,
                    "prompt_cache_miss_tokens": 900
                ]
            ]),
            .valid(DeepSeekAPIUsage(inputTokens: 1_000, cachedInputTokens: 100, outputTokens: 50))
        )
    }

    func testParseUsageReadsNestedCachedTokensAndRejectsIncompleteObjects() {
        XCTAssertEqual(
            DeepSeekAPIUsage.parse(from: [
                "usage": [
                    "prompt_tokens": 80,
                    "completion_tokens": 10,
                    "prompt_tokens_details": ["cached_tokens": 20]
                ]
            ]),
            .valid(DeepSeekAPIUsage(inputTokens: 80, cachedInputTokens: 20, outputTokens: 10))
        )
        XCTAssertEqual(DeepSeekAPIUsage.parse(from: ["choices": []]), .absent)
        XCTAssertEqual(DeepSeekAPIUsage.parse(from: ["usage": ["total_tokens": 12]]), .invalid)
        XCTAssertEqual(
            DeepSeekAPIUsage.parse(from: [
                "usage": ["prompt_tokens": 80, "completion_tokens": 10]
            ]),
            .invalid
        )
        XCTAssertEqual(
            DeepSeekAPIUsage.parse(from: [
                "usage": [
                    "prompt_tokens": 80.5,
                    "completion_tokens": 10,
                    "prompt_cache_hit_tokens": 0
                ]
            ]),
            .invalid
        )
        XCTAssertEqual(
            DeepSeekAPIUsage.parse(from: [
                "usage": [
                    "prompt_tokens": -1,
                    "completion_tokens": 10,
                    "prompt_cache_hit_tokens": 0
                ]
            ]),
            .invalid
        )
        XCTAssertEqual(
            DeepSeekAPIUsage.parse(from: [
                "usage": [
                    "prompt_tokens": 80,
                    "completion_tokens": 10,
                    "prompt_cache_hit_tokens": 100
                ]
            ]),
            .invalid
        )
        XCTAssertEqual(
            DeepSeekAPIUsage.parse(from: [
                "usage": [
                    "prompt_tokens": 80,
                    "completion_tokens": 10,
                    "prompt_cache_hit_tokens": 10,
                    "prompt_cache_miss_tokens": 20
                ]
            ]),
            .invalid
        )
        XCTAssertEqual(
            DeepSeekAPIUsage.parse(from: [
                "usage": [
                    "prompt_tokens": true,
                    "completion_tokens": 10,
                    "prompt_cache_hit_tokens": 0
                ]
            ]),
            .invalid
        )
    }

    func testCostUsesPublishedPeakAndOffPeakRates() throws {
        let usage = DeepSeekAPIUsage(inputTokens: 1_000, cachedInputTokens: 100, outputTokens: 50)
        let offPeak = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-17T12:00:00Z"))
        let peak = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-17T07:00:00Z"))
        let weekendPeakHours = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-15T07:00:00Z"))

        XCTAssertFalse(DeepSeekPricing.isPeak(at: offPeak))
        XCTAssertTrue(DeepSeekPricing.isPeak(at: peak))
        XCTAssertFalse(DeepSeekPricing.isPeak(at: weekendPeakHours))

        XCTAssertEqual(
            DeepSeekPricing.costUSD(model: "deepseek-v4-pro", usage: usage, at: offPeak),
            0.0006952,
            accuracy: 0.0000000001
        )
        XCTAssertEqual(
            DeepSeekPricing.costUSD(model: "deepseek-v4-pro", usage: usage, at: peak),
            0.0013904,
            accuracy: 0.0000000001
        )
    }

    func testStoreRecordsAreImmutableAndEpisodeTotalsSumRequests() throws {
        let harness = try makeDatabase()
        let store = DeepSeekUsageStore(database: harness.database)
        let offPeak = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-17T12:00:00Z"))
        let usage = DeepSeekAPIUsage(inputTokens: 1_000, cachedInputTokens: 100, outputTokens: 50)

        try store.record(
            episodeID: harness.episodeID,
            requestKind: .adDetection,
            model: "deepseek-v4-pro",
            usage: usage,
            createdAt: offPeak
        )
        try store.record(
            episodeID: harness.episodeID,
            requestKind: .adDetection,
            model: "deepseek-v4-pro",
            usage: usage,
            createdAt: offPeak
        )
        try store.record(
            episodeID: harness.episodeID,
            requestKind: .showNotes,
            model: "deepseek-v4-pro",
            usage: DeepSeekAPIUsage(inputTokens: 2_000, cachedInputTokens: 0, outputTokens: 100),
            createdAt: offPeak
        )

        let records = try store.records(episodeID: harness.episodeID)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.requestKind), [.adDetection, .adDetection, .showNotes])
        XCTAssertEqual(
            try store.episodeTotalCost(episodeID: harness.episodeID),
            records.compactMap(\.costUSD).reduce(0, +)
        )
        XCTAssertEqual(try store.episodeTotalCost(episodeID: harness.episodeID), 0.0029084, accuracy: 0.0000000001)
        XCTAssertTrue(try store.metrics().telemetry_complete)
        XCTAssertEqual(
            records.map(\.episodeKey),
            Array(repeating: DeepSeekUsageStore.episodeKey(feedURL: "https://example.com/feed", guid: "episode-1"), count: 3)
        )
    }

    func testMetricsComputeAveragesAndCostPerPodcastMinute() throws {
        let harness = try makeDatabase(durationSecs: 3_600)
        let secondID = try insertEpisode(
            database: harness.database,
            podcastID: harness.podcastID,
            guid: "episode-2",
            durationSecs: 1_800
        )
        let store = DeepSeekUsageStore(database: harness.database)
        let offPeak = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-17T12:00:00Z"))

        try store.record(
            episodeID: harness.episodeID,
            requestKind: .adDetection,
            model: "deepseek-v4-pro",
            usage: DeepSeekAPIUsage(inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0),
            createdAt: offPeak
        )
        try store.record(
            episodeID: secondID,
            requestKind: .showNotes,
            model: "deepseek-v4-pro",
            usage: DeepSeekAPIUsage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 1_000_000),
            createdAt: offPeak
        )

        let metrics = try store.metrics()
        XCTAssertEqual(metrics.total_cost_usd, 2.64, accuracy: 0.0000000001)
        XCTAssertEqual(try XCTUnwrap(metrics.average_cost_per_episode_usd), 1.32, accuracy: 0.0000000001)
        XCTAssertEqual(try XCTUnwrap(metrics.average_cost_per_podcast_minute_usd), 0.0293333333, accuracy: 0.0000001)
        XCTAssertEqual(metrics.ad_detection_cost_usd, 0.66, accuracy: 0.0000000001)
        XCTAssertEqual(metrics.show_notes_cost_usd, 1.98, accuracy: 0.0000000001)
        XCTAssertTrue(metrics.telemetry_complete)
    }

    func testMetricsFallBackToTranscriptDurationAndSkipEpisodesWithoutMinutes() throws {
        let harness = try makeDatabase(durationSecs: nil)
        try harness.database.execute(
            """
            INSERT INTO ad_transcript_segments
                (episode_id, segment_id, segment_index, language, start_time, end_time, text)
            VALUES (?, 's0', 0, 'en', 0, 120, 'hello')
            """,
            [.int(harness.episodeID)]
        )
        let missingDurationID = try insertEpisode(
            database: harness.database,
            podcastID: harness.podcastID,
            guid: "no-duration",
            durationSecs: nil
        )
        let store = DeepSeekUsageStore(database: harness.database)
        let offPeak = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-17T12:00:00Z"))
        try store.record(
            episodeID: harness.episodeID,
            requestKind: .adDetection,
            model: "deepseek-v4-pro",
            usage: DeepSeekAPIUsage(inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0),
            createdAt: offPeak
        )
        try store.record(
            episodeID: missingDurationID,
            requestKind: .showNotes,
            model: "deepseek-v4-pro",
            usage: DeepSeekAPIUsage(inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0),
            createdAt: offPeak
        )

        let metrics = try store.metrics()
        XCTAssertEqual(metrics.total_cost_usd, 1.32, accuracy: 0.0000000001)
        XCTAssertEqual(try XCTUnwrap(metrics.average_cost_per_episode_usd), 0.66, accuracy: 0.0000000001)
        XCTAssertEqual(try XCTUnwrap(metrics.average_cost_per_podcast_minute_usd), 0.33, accuracy: 0.0000000001)
        XCTAssertEqual(metrics.show_notes_cost_usd, 0.66, accuracy: 0.0000000001)
        XCTAssertTrue(metrics.telemetry_complete)
    }

    func testSuccessfulClassifierCallRecordsUsage() async throws {
        let store = MemoryUsageStore()
        let classifier = DeepSeekAdClassifier(
            apiKey: "secret",
            transport: .json(Self.completionJSON(content: #"{"labels":[]}"#, usage: Self.sampleUsage)),
            usageStore: store
        )

        let output = try await DeepSeekUsageAttribution.$episodeID.withValue(42) {
            try await classifier.classify(window: Self.window)
        }

        XCTAssertEqual(output, #"{"labels":[]}"#)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.episodeID, 42)
        XCTAssertEqual(store.records.first?.requestKind, .adDetection)
        XCTAssertEqual(store.records.first?.model, "deepseek-v4-pro")
        XCTAssertEqual(
            store.records.first?.usage,
            DeepSeekAPIUsage(inputTokens: 1_000, cachedInputTokens: 100, outputTokens: 50)
        )
    }

    func testRetriesCreateSeparateUsageRecords() async throws {
        let store = MemoryUsageStore()
        var remaining = 2
        let transport = DeepSeekAdClassifier.Transport { request in
            remaining -= 1
            return (
                Data(Self.completionJSON(content: #"{"labels":[]}"#, usage: Self.sampleUsage).utf8),
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/json"]
                )!
            )
        }
        let classifier = DeepSeekAdClassifier(apiKey: "secret", transport: transport, usageStore: store)

        _ = try await DeepSeekUsageAttribution.$episodeID.withValue(7) {
            try await classifier.classify(window: Self.window)
        }
        _ = try await DeepSeekUsageAttribution.$episodeID.withValue(7) {
            try await classifier.classify(window: Self.window)
        }

        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.records.map(\.episodeID), [7, 7])
        XCTAssertEqual(remaining, 0)
    }

    func testRejectedModelOutputStillRecordsUsage() async throws {
        let store = MemoryUsageStore()
        let classifier = DeepSeekAdClassifier(
            apiKey: "secret",
            transport: .json(Self.completionJSON(content: nil, usage: Self.sampleUsage)),
            usageStore: store
        )

        do {
            _ = try await DeepSeekUsageAttribution.$episodeID.withValue(9) {
                try await classifier.classify(window: Self.window)
            }
            XCTFail("Expected rejected classifier output")
        } catch let error as DeepSeekClassifierError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.episodeID, 9)
    }

    func testRejectedShowNotesStillRecordUsage() async throws {
        let store = MemoryUsageStore()
        let generator = DeepSeekEpisodeShowNotesGenerator(
            credentialStore: StubCredentialStore(),
            transport: .json(
                Self.completionJSON(
                    content: #"{"chapters":[]}"#,
                    usage: Self.sampleUsage,
                    finishReason: "stop"
                )
            ),
            usageStore: store
        )

        do {
            _ = try await DeepSeekUsageAttribution.$episodeID.withValue(11) {
                try await generator.generate(segments: Self.segments)
            }
            XCTFail("Expected rejected show-note output")
        } catch let error as EpisodeShowNotesError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.requestKind, .showNotes)
        XCTAssertEqual(store.records.first?.episodeID, 11)
    }

    func testMissingUsageDataDoesNotCreateARecord() async throws {
        let store = MemoryUsageStore()
        let classifier = DeepSeekAdClassifier(
            apiKey: "secret",
            transport: .json(Self.completionJSON(content: #"{"labels":[]}"#, usage: nil)),
            usageStore: store
        )
        let generator = DeepSeekEpisodeShowNotesGenerator(
            credentialStore: StubCredentialStore(),
            transport: .json(
                Self.completionJSON(
                    content: #"{"chapters":[{"segment_id":"s0","title":"Opening","summary":"The host says hello to the listener."}]}"#,
                    usage: nil,
                    finishReason: "stop"
                )
            ),
            usageStore: store
        )

        _ = try await DeepSeekUsageAttribution.$episodeID.withValue(3) {
            try await classifier.classify(window: Self.window)
        }
        let notes = try await DeepSeekUsageAttribution.$episodeID.withValue(3) {
            try await generator.generate(segments: Self.segments)
        }

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(notes.count, 1)
    }

    func testUsageStoreFailureDoesNotBreakModelCalls() async throws {
        let classifier = DeepSeekAdClassifier(
            apiKey: "secret",
            transport: .json(Self.completionJSON(content: #"{"labels":[]}"#, usage: Self.sampleUsage)),
            usageStore: ThrowingUsageStore()
        )
        let generator = DeepSeekEpisodeShowNotesGenerator(
            credentialStore: StubCredentialStore(),
            transport: .json(
                Self.completionJSON(
                    content: #"{"chapters":[{"segment_id":"s0","title":"Opening","summary":"The host says hello to the listener."}]}"#,
                    usage: Self.sampleUsage,
                    finishReason: "stop"
                )
            ),
            usageStore: ThrowingUsageStore()
        )

        let output = try await DeepSeekUsageAttribution.$episodeID.withValue(5) {
            try await classifier.classify(window: Self.window)
        }
        let notes = try await DeepSeekUsageAttribution.$episodeID.withValue(5) {
            try await generator.generate(segments: Self.segments)
        }

        XCTAssertEqual(output, #"{"labels":[]}"#)
        XCTAssertEqual(notes.map(\.title), ["Opening"])
    }

    func testSuccessfulShowNotesCallRecordsUsage() async throws {
        let store = MemoryUsageStore()
        let generator = DeepSeekEpisodeShowNotesGenerator(
            credentialStore: StubCredentialStore(),
            transport: .json(
                Self.completionJSON(
                    content: #"{"chapters":[{"segment_id":"s0","title":"Opening","summary":"The host says hello to the listener."}]}"#,
                    usage: Self.sampleUsage,
                    finishReason: "stop"
                )
            ),
            usageStore: store
        )

        _ = try await DeepSeekUsageAttribution.$episodeID.withValue(8) {
            try await generator.generate(segments: Self.segments)
        }

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.requestKind, .showNotes)
        XCTAssertEqual(store.records.first?.episodeID, 8)
    }

    func testInvalidUsageIsStoredUnpricedAndMarksTelemetryIncomplete() throws {
        let harness = try makeDatabase()
        let store = DeepSeekUsageStore(database: harness.database)
        try DeepSeekUsageAttribution.$episodeID.withValue(harness.episodeID) {
            DeepSeekUsageRecorder.recordIfPresent(
                store: store,
                requestKind: .adDetection,
                model: "deepseek-v4-pro",
                root: ["usage": ["prompt_tokens": 80, "completion_tokens": 10]],
                createdAt: Date()
            )
        }

        let records = try store.records(episodeID: harness.episodeID)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.costUSD)
        XCTAssertNil(records.first?.inputTokens)
        XCTAssertEqual(try store.episodeTotalCost(episodeID: harness.episodeID), 0)
        XCTAssertFalse(try store.metrics().telemetry_complete)
    }

    func testSnapshotDurationSurvivesEpisodeIDReuse() throws {
        let harness = try makeDatabase(durationSecs: 3_600)
        let store = DeepSeekUsageStore(database: harness.database)
        let offPeak = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-17T12:00:00Z"))
        try store.record(
            episodeID: harness.episodeID,
            requestKind: .adDetection,
            model: "deepseek-v4-pro",
            usage: DeepSeekAPIUsage(inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0),
            createdAt: offPeak
        )
        try harness.database.execute("DELETE FROM episodes WHERE id = ?", [.int(harness.episodeID)])
        try harness.database.execute(
            """
            INSERT INTO episodes (id, podcast_id, guid, title, audio_url, duration_secs, published_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .int(harness.episodeID),
                .int(harness.podcastID),
                .text("unrelated-reuse"),
                .text("Unrelated"),
                .text("https://example.com/unrelated.mp3"),
                .int(60),
                .int(200)
            ]
        )

        let metrics = try store.metrics()
        XCTAssertEqual(metrics.total_cost_usd, 0.66, accuracy: 0.0000000001)
        XCTAssertEqual(try XCTUnwrap(metrics.average_cost_per_podcast_minute_usd), 0.011, accuracy: 0.0000000001)
        let records = try store.records()
        XCTAssertEqual(records.first?.durationSecs, 3_600)
        XCTAssertEqual(
            records.first?.episodeKey,
            DeepSeekUsageStore.episodeKey(feedURL: "https://example.com/feed", guid: "episode-1")
        )
    }

    func testFailedInsertFallsBackToLedgerAndReconciles() throws {
        let harness = try makeDatabase()
        let fallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepseek-fallback-\(UUID().uuidString).jsonl")
        let store = DeepSeekUsageStore(database: harness.database, fallbackURL: fallbackURL)
        let offPeak = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-17T12:00:00Z"))
        store.failNextInsert = true
        try store.record(
            episodeID: harness.episodeID,
            requestKind: .showNotes,
            model: "deepseek-v4-pro",
            usage: DeepSeekAPIUsage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 1_000_000),
            createdAt: offPeak
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackURL.path))
        XCTAssertEqual(
            try harness.database.scalarInt64("SELECT COUNT(*) FROM deepseek_usage") ?? 0,
            0
        )

        let metrics = try store.metrics()
        XCTAssertEqual(metrics.total_cost_usd, 1.98, accuracy: 0.0000000001)
        XCTAssertTrue(metrics.telemetry_complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackURL.path))
        XCTAssertEqual(try store.records(episodeID: harness.episodeID).count, 1)
    }

    func testLostWriteWithoutFallbackMarksTelemetryIncomplete() throws {
        let harness = try makeDatabase()
        let store = DeepSeekUsageStore(database: harness.database)
        store.failNextInsert = true
        do {
            try store.record(
                episodeID: harness.episodeID,
                requestKind: .adDetection,
                model: "deepseek-v4-pro",
                usage: DeepSeekAPIUsage(inputTokens: 10, cachedInputTokens: 0, outputTokens: 1),
                createdAt: Date()
            )
            XCTFail("Expected the failed insert to throw after the fallback is unavailable")
        } catch {
            XCTAssertTrue(String(describing: error).contains("deepseek usage insert failed"))
        }
        let metrics = try store.metrics()
        XCTAssertEqual(metrics.total_cost_usd, 0)
        XCTAssertFalse(metrics.telemetry_complete)
    }

    func testInvalidClassifierUsageStillRecordsAnUnpricedRow() async throws {
        let store = MemoryUsageStore()
        let classifier = DeepSeekAdClassifier(
            apiKey: "secret",
            transport: .json(
                Self.completionJSON(
                    content: #"{"labels":[]}"#,
                    usage: ["prompt_tokens": 12]
                )
            ),
            usageStore: store
        )

        _ = try await DeepSeekUsageAttribution.$episodeID.withValue(4) {
            try await classifier.classify(window: Self.window)
        }

        XCTAssertEqual(store.records.count, 1)
        XCTAssertNil(store.records.first?.usage)
    }

    func testReconcileAfterReplaceFailureDoesNotDoubleCount() throws {
        let harness = try makeDatabase()
        let ledger = ControllableLedger()
        let store = DeepSeekUsageStore(database: harness.database, ledger: ledger)
        let offPeak = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-17T12:00:00Z"))
        store.failNextInsert = true
        try store.record(
            episodeID: harness.episodeID,
            requestKind: .adDetection,
            model: "deepseek-v4-pro",
            usage: DeepSeekAPIUsage(inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0),
            createdAt: offPeak
        )
        XCTAssertEqual(try ledger.load().count, 1)

        ledger.failNextReplace = true
        _ = try store.metrics()
        XCTAssertEqual(try harness.database.scalarInt64("SELECT COUNT(*) FROM deepseek_usage"), 1)
        XCTAssertEqual(try ledger.load().count, 1, "a replace failure must leave the line in the ledger")

        let metrics = try store.metrics()
        XCTAssertEqual(try harness.database.scalarInt64("SELECT COUNT(*) FROM deepseek_usage"), 1)
        XCTAssertEqual(metrics.total_cost_usd, 0.66, accuracy: 0.0000000001)
        XCTAssertTrue(try ledger.load().isEmpty)
        XCTAssertEqual(Set(try store.records().map(\.recordID)).count, 1)
    }

    func testAppendRacingReconcileKeepsEachBilledRequestOnce() throws {
        let harness = try makeDatabase()
        let ledger = ControllableLedger()
        let store = DeepSeekUsageStore(database: harness.database, ledger: ledger)
        let offPeak = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-17T12:00:00Z"))
        store.failNextInsert = true
        try store.record(
            episodeID: harness.episodeID,
            requestKind: .adDetection,
            model: "deepseek-v4-pro",
            usage: DeepSeekAPIUsage(inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0),
            createdAt: offPeak
        )

        let appendFinished = expectation(description: "append waiting on reconcile finished")
        store.afterLedgerLoad = {
            store.afterLedgerLoad = nil
            // Start an append that would be wiped by replace([]) if it were
            // allowed to run between load and replace without the ledger lock.
            DispatchQueue.global().async {
                store.failNextInsert = true
                try? store.record(
                    episodeID: harness.episodeID,
                    requestKind: .showNotes,
                    model: "deepseek-v4-pro",
                    usage: DeepSeekAPIUsage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 1_000_000),
                    createdAt: offPeak
                )
                appendFinished.fulfill()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        _ = try store.metrics()
        wait(for: [appendFinished], timeout: 5)

        let metrics = try store.metrics()
        let rows = try store.records()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.recordID)).count, 2)
        XCTAssertEqual(metrics.total_cost_usd, 2.64, accuracy: 0.0000000001)
        XCTAssertEqual(metrics.ad_detection_cost_usd, 0.66, accuracy: 0.0000000001)
        XCTAssertEqual(metrics.show_notes_cost_usd, 1.98, accuracy: 0.0000000001)
        XCTAssertTrue(try ledger.load().isEmpty)
    }

    func testLegacyLedgerLineWithoutRecordIDReconcilesIdempotently() throws {
        let harness = try makeDatabase()
        let ledger = ControllableLedger()
        let store = DeepSeekUsageStore(database: harness.database, ledger: ledger)
        let episodeKey = DeepSeekUsageStore.episodeKey(
            feedURL: "https://example.com/feed",
            guid: "episode-1"
        )
        let payload: [String: Any] = [
            "episode_id": harness.episodeID,
            "episode_key": episodeKey,
            "duration_secs": 3600,
            "request_kind": "ad_detection",
            "model": "deepseek-v4-pro",
            "input_tokens": 1_000_000,
            "cached_input_tokens": 0,
            "output_tokens": 0,
            "cost_usd": 0.66,
            "created_at": 1_755_432_000
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        let first = try JSONDecoder().decode(DeepSeekUsagePendingRecord.self, from: json)
        let second = try JSONDecoder().decode(DeepSeekUsagePendingRecord.self, from: json)
        XCTAssertFalse(first.record_id.isEmpty)
        XCTAssertEqual(first.record_id, second.record_id)
        try ledger.append(first)

        ledger.failNextReplace = true
        _ = try store.metrics()
        XCTAssertEqual(try harness.database.scalarInt64("SELECT COUNT(*) FROM deepseek_usage"), 1)
        XCTAssertEqual(try ledger.load().count, 1)

        let metrics = try store.metrics()
        XCTAssertEqual(try harness.database.scalarInt64("SELECT COUNT(*) FROM deepseek_usage"), 1)
        XCTAssertEqual(metrics.total_cost_usd, 0.66, accuracy: 0.0000000001)
        XCTAssertTrue(try ledger.load().isEmpty)
        XCTAssertEqual(try store.records().map(\.recordID), [first.record_id])
    }

    private final class ControllableLedger: DeepSeekUsageLedging {
        private var items: [DeepSeekUsagePendingRecord] = []
        var failNextReplace = false

        func append(_ record: DeepSeekUsagePendingRecord) throws {
            items.append(record)
        }

        func load() throws -> [DeepSeekUsagePendingRecord] {
            items
        }

        func replace(_ records: [DeepSeekUsagePendingRecord]) throws {
            if failNextReplace {
                failNextReplace = false
                throw PodsBackendError.database("ledger replace failed")
            }
            items = records
        }
    }

    private struct DatabaseHarness {
        let database: PodsDatabase
        let podcastID: Int64
        let episodeID: Int64
    }

    private func makeDatabase(durationSecs: Int64? = 3_600) throws -> DatabaseHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try PodsDatabase(url: directory.appendingPathComponent("test.sqlite"))
        try database.execute(
            "INSERT INTO podcasts (feed_url, title, created_at) VALUES (?, ?, ?)",
            [.text("https://example.com/feed"), .text("Example"), .int(1)]
        )
        let podcastID = database.lastInsertRowID()
        let episodeID = try insertEpisode(
            database: database,
            podcastID: podcastID,
            guid: "episode-1",
            durationSecs: durationSecs
        )
        return DatabaseHarness(database: database, podcastID: podcastID, episodeID: episodeID)
    }

    private func insertEpisode(
        database: PodsDatabase,
        podcastID: Int64,
        guid: String,
        durationSecs: Int64?
    ) throws -> Int64 {
        try database.execute(
            """
            INSERT INTO episodes (podcast_id, guid, title, audio_url, duration_secs, published_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .int(podcastID),
                .text(guid),
                .text(guid),
                .text("https://example.com/\(guid).mp3"),
                durationSecs.map { .int($0) } ?? .null,
                .int(100)
            ]
        )
        return database.lastInsertRowID()
    }

    private static let window = AdClassificationWindow(
        index: 0,
        segments: [],
        corrections: [],
        prompt: "classify this",
        estimatedInputTokens: 3,
        estimatedCorrectionTokens: 0,
        maximumInputTokens: 8_000
    )

    private static let segments = [
        AdTranscriptSegment(
            id: "seg-1",
            index: 0,
            language: "en",
            startTime: 0,
            endTime: 12,
            text: "Hello from the show"
        )
    ]

    private static let sampleUsage: [String: Any] = [
        "prompt_tokens": 1_000,
        "completion_tokens": 50,
        "prompt_cache_hit_tokens": 100
    ]

    private static func completionJSON(
        content: String?,
        usage: [String: Any]?,
        finishReason: String = "stop"
    ) -> String {
        var choice: [String: Any] = ["finish_reason": finishReason]
        if let content {
            choice["message"] = ["content": content]
        }
        var root: [String: Any] = ["choices": [choice]]
        if let usage {
            root["usage"] = usage
        }
        let data = try! JSONSerialization.data(withJSONObject: root)
        return String(data: data, encoding: .utf8)!
    }
}

private extension DeepSeekAdClassifier.Transport {
    static func json(_ body: String) -> DeepSeekAdClassifier.Transport {
        DeepSeekAdClassifier.Transport { request in
            (
                Data(body.utf8),
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/json"]
                )!
            )
        }
    }
}

private extension DeepSeekEpisodeShowNotesGenerator.Transport {
    static func json(_ body: String) -> DeepSeekEpisodeShowNotesGenerator.Transport {
        DeepSeekEpisodeShowNotesGenerator.Transport { request in
            (
                Data(body.utf8),
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["content-type": "application/json"]
                )!
            )
        }
    }
}
