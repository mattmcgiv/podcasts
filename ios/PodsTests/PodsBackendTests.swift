import XCTest
import MediaPlayer
import WebKit
@testable import Pods

final class PodsBackendTests: XCTestCase {
    private final class MockFeedFetcher: ConditionalFeedFetching {
        var responses: [String: Data] = [:]
        var responseValidators: [String: FeedValidators] = [:]
        var notModifiedURLs: Set<String> = []
        private(set) var requestedURLs: [String] = []
        private(set) var requestedValidators: [FeedValidators] = []

        func data(for url: URL) async throws -> Data {
            requestedURLs.append(url.absoluteString)
            guard let data = responses[url.absoluteString] else {
                throw PodsBackendError.upstream("missing mock feed")
            }
            return data
        }

        func response(for url: URL, validators: FeedValidators) async throws -> FeedFetchResponse {
            requestedValidators.append(validators)
            if notModifiedURLs.contains(url.absoluteString) {
                return .notModified(responseValidators[url.absoluteString] ?? validators)
            }
            return .data(
                try await data(for: url),
                responseValidators[url.absoluteString] ?? FeedValidators()
            )
        }
    }

    private struct MockDirectorySearcher: PodcastDirectorySearching {
        var podcasts: [DirectoryPodcast]

        var isConfigured: Bool {
            true
        }

        func search(query: String) async throws -> [DirectoryPodcast] {
            podcasts
        }
    }

    private struct Harness {
        let backend: PodsBackend
        let fetcher: MockFeedFetcher
        let directory: URL
        let database: PodsDatabase
        let adRemovalArtifactStore: AdRemovalArtifactStore
    }

    private func makeHarness(directorySearcher: PodcastDirectorySearching? = nil) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodsBackendTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try PodsDatabase(url: directory.appendingPathComponent("test.sqlite"))
        let adRemovalArtifactStore = try AdRemovalArtifactStore(
            rootURL: directory.appendingPathComponent("AdRemoval", isDirectory: true)
        )
        let fetcher = MockFeedFetcher()
        let backend = PodsBackend(
            database: database,
            feedFetcher: fetcher,
            directorySearcher: directorySearcher ?? DisabledPodcastDirectorySearcher(),
            adRemovalArtifactStore: adRemovalArtifactStore
        )
        return Harness(
            backend: backend,
            fetcher: fetcher,
            directory: directory,
            database: database,
            adRemovalArtifactStore: adRemovalArtifactStore
        )
    }

    private func call(
        _ backend: PodsBackend,
        _ method: String,
        _ target: String,
        json: Any? = nil,
        text: String? = nil
    ) async throws -> HTTPResponse {
        let body: Data
        if let json {
            body = try JSONSerialization.data(withJSONObject: json)
        } else if let text {
            body = Data(text.utf8)
        } else {
            body = Data()
        }
        return await backend.handle(HTTPRequest(method: method, target: target, body: body))
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        try JSONDecoder().decode(type, from: response.body)
    }

    private func value(_ response: HTTPResponse) throws -> Any {
        try JSONSerialization.jsonObject(with: response.body)
    }

    func testEndpointsDoNotRequireAuth() async throws {
        let harness = try makeHarness()
        let response = try await call(harness.backend, "GET", "/api/recent")
        XCTAssertEqual(response.statusCode, 200)
        let page = try decode(Page<EpisodeItem>.self, from: response)
        XCTAssertTrue(page.items.isEmpty)
    }

    func testSubscribeBackfillsNewestTwoAndListsRecent() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/a.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Alpha",
            items: [
                ("Ep1", "g1", "https://h.example/1.mp3", Self.d1),
                ("Ep2", "g2", "https://h.example/2.mp3", Self.d2),
                ("Ep3", "g3", "https://h.example/3.mp3", Self.d3),
                ("Ep4", "g4", "https://h.example/4.mp3", Self.d4)
            ]
        ).utf8)

        let subscribe = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])
        XCTAssertEqual(subscribe.statusCode, 201)
        let show = try decode(Show.self, from: subscribe)
        XCTAssertEqual(show.title, "Alpha")
        XCTAssertEqual(show.episode_count, 4)
        XCTAssertEqual(show.unplayed_count, 2)

        let recent = try decode(Page<EpisodeItem>.self, from: try await call(harness.backend, "GET", "/api/recent"))
        XCTAssertEqual(recent.items.map(\.title), ["Ep4", "Ep3"])
        XCTAssertNil(recent.next_offset)

        let duplicate = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])
        XCTAssertEqual(duplicate.statusCode, 409)

        let badURL = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": "ftp://x"])
        XCTAssertEqual(badURL.statusCode, 422)

        let shows = try decode([Show].self, from: try await call(harness.backend, "GET", "/api/shows"))
        XCTAssertEqual(shows.count, 1)
        let detail = try decode(ShowDetail.self, from: try await call(harness.backend, "GET", "/api/shows/\(shows[0].id)"))
        XCTAssertEqual(detail.episodes.items.count, 4)
        let missing = try await call(harness.backend, "GET", "/api/shows/9999")
        XCTAssertEqual(missing.statusCode, 404)
    }

    func testSubscribeEnrollsOnlyVisibleEpisodesAndWakesAdRemovalScheduler() async throws {
        let harness = try makeHarness()
        try harness.database.execute(
            "INSERT INTO settings (key, value) VALUES ('ad_removal_enabled', 'true') ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        )
        let schedulerRequested = expectation(description: "ad-removal scheduler requested")
        harness.backend.setAdRemovalRunRequestHandler { schedulerRequested.fulfill() }
        let feedURL = "https://feeds.example/ad-removal-subscribe.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Ad Removal Subscribe",
            items: [
                ("Ep1", "ar1", "https://h.example/ar1.mp3", Self.d1),
                ("Ep2", "ar2", "https://h.example/ar2.mp3", Self.d2),
                ("Ep3", "ar3", "https://h.example/ar3.mp3", Self.d3),
                ("Ep4", "ar4", "https://h.example/ar4.mp3", Self.d4),
            ]
        ).utf8)

        let response = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])
        XCTAssertEqual(response.statusCode, 201)
        await fulfillment(of: [schedulerRequested], timeout: 1)
        let enrolledTitles = try harness.database.query(
            "SELECT e.title FROM ad_removal_jobs j JOIN episodes e ON e.id = j.episode_id ORDER BY e.published_at",
            map: { sqliteString($0, 0) }
        )
        XCTAssertEqual(enrolledTitles, ["Ep3", "Ep4"])
    }

    func testPlayedPositionSettingsAndNextRoundTrip() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/a.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Alpha",
            items: [
                ("Ep1", "g1", "https://h.example/1.mp3", Self.d1),
                ("Ep2", "g2", "https://h.example/2.mp3", Self.d2),
                ("Ep3", "g3", "https://h.example/3.mp3", Self.d3)
            ]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])

        let recent = try decode(Page<EpisodeItem>.self, from: try await call(harness.backend, "GET", "/api/recent"))
        let ep3 = recent.items[0].id
        let ep2 = recent.items[1].id

        let nextRecent = try decode(EpisodeItem?.self, from: try await call(harness.backend, "GET", "/api/next?after=\(ep3)&context=recent"))
        XCTAssertEqual(nextRecent?.id, ep2)
        let nextShow = try decode(EpisodeItem?.self, from: try await call(harness.backend, "GET", "/api/next?after=\(ep2)&context=show"))
        XCTAssertEqual(nextShow?.id, ep3)

        let markPlayed = try await call(harness.backend, "POST", "/api/episodes/\(ep3)/played")
        XCTAssertEqual(markPlayed.statusCode, 204)
        let played = try decode(Page<EpisodeItem>.self, from: try await call(harness.backend, "GET", "/api/played"))
        XCTAssertEqual(played.items.first?.id, ep3)
        let unmarkPlayed = try await call(harness.backend, "DELETE", "/api/episodes/\(ep3)/played")
        XCTAssertEqual(unmarkPlayed.statusCode, 204)

        let setPosition = try await call(harness.backend, "PUT", "/api/episodes/\(ep2)/position", json: ["seconds": 42.5])
        XCTAssertEqual(setPosition.statusCode, 204)
        let detail = try decode(EpisodeDetail.self, from: try await call(harness.backend, "GET", "/api/episodes/\(ep2)"))
        XCTAssertEqual(detail.position_secs, 42.5)
        XCTAssertTrue(detail.notes_html.contains("Notes for Ep2"))

        let settings = try decode(SettingsPayload.self, from: try await call(harness.backend, "GET", "/api/settings"))
        XCTAssertEqual(settings, SettingsPayload(speed: 1.0, autoplay: true))
        let saveSettings = try await call(harness.backend, "PUT", "/api/settings", json: ["speed": 2.5, "autoplay": false])
        XCTAssertEqual(saveSettings.statusCode, 204)
        let saved = try decode(SettingsPayload.self, from: try await call(harness.backend, "GET", "/api/settings"))
        XCTAssertEqual(saved, SettingsPayload(speed: 2.5, autoplay: false))
        let invalidSettings = try await call(harness.backend, "PUT", "/api/settings", json: ["speed": 9.9, "autoplay": true])
        XCTAssertEqual(invalidSettings.statusCode, 422)
    }

    func testEpisodeAdRemovalStatePrepareAndRetryRoundTrip() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/ad-state.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Ad State",
            items: [("Episode", "ad-state-1", "https://h.example/ad-state.mp3", Self.d1)]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])

        let recentResponse = try await call(harness.backend, "GET", "/api/recent")
        let episode = try XCTUnwrap(try decode(Page<EpisodeItem>.self, from: recentResponse).items.first)
        XCTAssertEqual(episode.ad_removal_state, "unfiltered")
        XCTAssertEqual(episode.ad_removal_action, "prepare")
        XCTAssertNil(episode.ad_removal_stage, "no job yet exposes nil stage")
        XCTAssertNil(episode.ad_removal_blocking_reason, "no job yet exposes nil blocking reason")

        let prepared = try await call(
            harness.backend,
            "POST",
            "/api/episodes/\(episode.id)/ad-removal/prepare"
        )
        XCTAssertEqual(prepared.statusCode, 202)
        var detail = try decode(EpisodeDetail.self, from: try await call(
            harness.backend,
            "GET",
            "/api/episodes/\(episode.id)"
        ))
        XCTAssertEqual(detail.ad_removal_state, "preparing")
        XCTAssertNil(detail.ad_removal_action)
        XCTAssertEqual(detail.ad_removal_stage, "queued", "freshly enqueued job reports exact queued stage")
        XCTAssertNil(detail.ad_removal_blocking_reason)

        let store = AdRemovalJobStore(database: harness.database, retryBackoff: { _ in 0 })
        let job = try XCTUnwrap(try store.job(episodeID: episode.id))
        _ = try store.transition(jobID: job.id, to: .downloading)
        let blocked = try store.setBlockingReason(jobID: job.id, reason: .storageLimit)
        XCTAssertEqual(blocked.blockingReason, .storageLimit)
        detail = try decode(EpisodeDetail.self, from: try await call(
            harness.backend,
            "GET",
            "/api/episodes/\(episode.id)"
        ))
        XCTAssertEqual(detail.ad_removal_stage, "downloading", "downloading stage is exposed exactly")
        XCTAssertEqual(detail.ad_removal_blocking_reason, "storage_limit", "storage_limit blocking reason is exposed")
        _ = try store.setBlockingReason(jobID: job.id, reason: nil)
        for _ in 0..<3 {
            _ = try store.recordFailure(jobID: job.id, errorCode: "test", message: "failed")
        }
        detail = try decode(EpisodeDetail.self, from: try await call(
            harness.backend,
            "GET",
            "/api/episodes/\(episode.id)"
        ))
        XCTAssertEqual(detail.ad_removal_state, "failed")
        XCTAssertEqual(detail.ad_removal_action, "retry")
        XCTAssertEqual(detail.ad_removal_stage, "failed", "failed stage is exposed exactly")
        XCTAssertNil(detail.ad_removal_blocking_reason)

        let retried = try await call(
            harness.backend,
            "POST",
            "/api/episodes/\(episode.id)/ad-removal/retry"
        )
        XCTAssertEqual(retried.statusCode, 202)
        detail = try decode(EpisodeDetail.self, from: try await call(
            harness.backend,
            "GET",
            "/api/episodes/\(episode.id)"
        ))
        XCTAssertEqual(detail.ad_removal_state, "preparing")
        XCTAssertNil(detail.ad_removal_action)
    }

    func testAdRemovalStatusesReturnsLightweightOrderedRecordsForExistingEpisodes() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/statuses.xml"
        // Three episodes; the subscription backfill keeps only the newest two in
        // Listen (the oldest is archived). The two recent episodes are the ones
        // the batch endpoint is meant to serve.
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Statuses",
            items: [
                ("Ep A", "status-a", "https://h.example/a.mp3", Self.d1),
                ("Ep B", "status-b", "https://h.example/b.mp3", Self.d2),
                ("Ep C", "status-c", "https://h.example/c.mp3", Self.d3),
            ]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])

        let recent = try decode(Page<EpisodeItem>.self, from: try await call(harness.backend, "GET", "/api/recent"))
        // The two newest episodes (B and C) remain in Listen; the oldest (A) is archived.
        let episodes = recent.items.sorted { $0.id < $1.id }
        XCTAssertEqual(episodes.count, 2, "newest two episodes are kept in Listen")
        let bID = episodes[0].id
        let cID = episodes[1].id

        // Enqueue a job for B so it reports a preparing stage; leave C unfiltered.
        _ = try await call(harness.backend, "POST", "/api/episodes/\(bID)/ad-removal/prepare")
        let store = AdRemovalJobStore(database: harness.database, retryBackoff: { _ in 0 })
        let bJob = try XCTUnwrap(try store.job(episodeID: bID))
        _ = try store.transition(jobID: bJob.id, to: .downloading)
        _ = try store.setBlockingReason(jobID: bJob.id, reason: .storageLimit)

        // Request in a deliberately non-sorted, deduplicated order including a
        // non-existent id and an archived id. Existing recent records must come
        // back in REQUESTED order, missing/non-recent ids are omitted, and
        // duplicates collapse to one record.
        let archivedID = try XCTUnwrap(try harness.database.scalarInt64("SELECT id FROM episodes WHERE title = 'Ep A'"))
        let requestedIDs = [cID, bID, cID, 9_999_999, archivedID]
        let target = "/api/ad-removal/statuses?episode_ids=\(requestedIDs.map(String.init).joined(separator: ","))"
        let response = try await call(harness.backend, "GET", target)
        XCTAssertEqual(response.statusCode, 200)
        let payload = try decode(AdRemovalStatusesPayload.self, from: response)

        // Deduplicated requested order, minus the non-existent id. The archived
        // episode still exists in the episodes table, so it is returned too —
        // preserving requested order across all existing ids.
        let expectedOrder = [cID, bID, archivedID]
        XCTAssertEqual(payload.items.map { $0.id }, expectedOrder, "records preserve requested order and omit missing ids")

        let byID = Dictionary(uniqueKeysWithValues: payload.items.map { ($0.id, $0) })
        XCTAssertEqual(byID[bID]?.ad_removal_state, "preparing")
        XCTAssertNil(byID[bID]?.ad_removal_action)
        XCTAssertEqual(byID[bID]?.ad_removal_stage, "downloading")
        XCTAssertEqual(byID[bID]?.ad_removal_blocking_reason, "storage_limit")

        XCTAssertEqual(byID[cID]?.ad_removal_state, "unfiltered")
        XCTAssertEqual(byID[cID]?.ad_removal_action, "prepare")
        XCTAssertNil(byID[cID]?.ad_removal_stage)
        XCTAssertNil(byID[cID]?.ad_removal_blocking_reason)

        // Lightweight: the response must not contain notes_html anywhere.
        let raw = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertFalse(raw.contains("notes_html"), "batch statuses must not serialize notes_html")
    }

    func testAdRemovalStatusesRejectsMalformedEmptyNonPositiveAndOverLimitInput() async throws {
        let harness = try makeHarness()

        // Missing query parameter entirely.
        let missing = try await call(harness.backend, "GET", "/api/ad-removal/statuses")
        XCTAssertEqual(missing.statusCode, 422)

        // Empty value.
        let empty = try await call(harness.backend, "GET", "/api/ad-removal/statuses?episode_ids=")
        XCTAssertEqual(empty.statusCode, 422)

        // Non-numeric token.
        let nonNumeric = try await call(harness.backend, "GET", "/api/ad-removal/statuses?episode_ids=abc")
        XCTAssertEqual(nonNumeric.statusCode, 422)

        // Mixed valid + non-numeric token.
        let mixed = try await call(harness.backend, "GET", "/api/ad-removal/statuses?episode_ids=1,abc")
        XCTAssertEqual(mixed.statusCode, 422)

        // Malformed CSV with an empty interior token. The default split would
        // silently omit the empty field and accept this as [1, 2].
        let emptyInterior = try await call(harness.backend, "GET", "/api/ad-removal/statuses?episode_ids=1,,2")
        XCTAssertEqual(emptyInterior.statusCode, 422)

        // Trailing comma yields a trailing empty token.
        let trailingComma = try await call(harness.backend, "GET", "/api/ad-removal/statuses?episode_ids=1,")
        XCTAssertEqual(trailingComma.statusCode, 422)

        // Leading comma yields a leading empty token.
        let leadingComma = try await call(harness.backend, "GET", "/api/ad-removal/statuses?episode_ids=,1")
        XCTAssertEqual(leadingComma.statusCode, 422)

        // Whitespace-only token is not a valid integer.
        let whitespaceToken = try await call(harness.backend, "GET", "/api/ad-removal/statuses?episode_ids=1, ,2")
        XCTAssertEqual(whitespaceToken.statusCode, 422)

        // Non-positive id.
        let zero = try await call(harness.backend, "GET", "/api/ad-removal/statuses?episode_ids=0")
        XCTAssertEqual(zero.statusCode, 422)
        let negative = try await call(harness.backend, "GET", "/api/ad-removal/statuses?episode_ids=-5")
        XCTAssertEqual(negative.statusCode, 422)

        // Over the 50-id limit (51 unique ids).
        let tooMany = (1...51).map(String.init).joined(separator: ",")
        let overLimit = try await call(harness.backend, "GET", "/api/ad-removal/statuses?episode_ids=\(tooMany)")
        XCTAssertEqual(overLimit.statusCode, 422)

        // Exactly 50 unique ids is accepted (no episodes exist, so empty items).
        let exactlyFifty = (1...50).map(String.init).joined(separator: ",")
        let atLimit = try await call(harness.backend, "GET", "/api/ad-removal/statuses?episode_ids=\(exactlyFifty)")
        XCTAssertEqual(atLimit.statusCode, 200)
        let atLimitPayload = try decode(AdRemovalStatusesPayload.self, from: atLimit)
        XCTAssertTrue(atLimitPayload.items.isEmpty)
    }

    func testAdRemovalEnableConsentCutoffAndNewEpisodeEnrollment() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/enrollment.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Enrollment",
            items: [("Existing", "existing", "https://h.example/existing.mp3", Self.d1)]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])

        var settings = try decode(AdRemovalSettingsPayload.self, from: try await call(
            harness.backend,
            "GET",
            "/api/ad-removal/settings"
        ))
        XCTAssertFalse(settings.enabled)
        XCTAssertNil(settings.enrollment_cutoff)
        XCTAssertEqual(settings.model_revision, AdModelManifest.qwen3OneSevenBFourBitV1.revision)
        XCTAssertEqual(settings.model_total_bytes, AdModelManifest.qwen3OneSevenBFourBitV1.totalByteCount)
        XCTAssertEqual(settings.minimum_free_bytes, 10_000_000_000, "settings must report the explicit 10 GB storage-policy minimum")

        try harness.database.execute(
            "INSERT INTO settings (key, value) VALUES ('ad_removal_model_download_state', 'ready'), ('ad_removal_model_downloaded_bytes', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(String(AdModelManifest.qwen3OneSevenBFourBitV1.totalByteCount))]
        )
        settings = try decode(AdRemovalSettingsPayload.self, from: try await call(
            harness.backend,
            "GET",
            "/api/ad-removal/settings"
        ))
        XCTAssertEqual(settings.model_downloaded_bytes, 0, "ready state must reflect files actually present")
        try harness.database.execute(
            "UPDATE settings SET value = 'not_downloaded' WHERE key = 'ad_removal_model_download_state'"
        )
        try harness.database.execute(
            "UPDATE settings SET value = '0' WHERE key = 'ad_removal_model_downloaded_bytes'"
        )

        let wrongConsent = try await call(
            harness.backend,
            "POST",
            "/api/ad-removal/enable",
            json: ["confirmed_bytes": 1]
        )
        XCTAssertEqual(wrongConsent.statusCode, 422)

        let enabled = try await call(
            harness.backend,
            "POST",
            "/api/ad-removal/enable",
            json: ["confirmed_bytes": AdModelManifest.qwen3OneSevenBFourBitV1.totalByteCount]
        )
        XCTAssertEqual(enabled.statusCode, 202)
        settings = try decode(AdRemovalSettingsPayload.self, from: enabled)
        XCTAssertTrue(settings.enabled)
        XCTAssertNotNil(settings.enrollment_cutoff)
        XCTAssertEqual(settings.model_download_state, "consented")

        let existingID = try XCTUnwrap(harness.database.scalarInt64(
            "SELECT id FROM episodes WHERE guid = 'existing'"
        ))
        XCTAssertNil(try AdRemovalJobStore(database: harness.database).job(episodeID: existingID))

        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Enrollment",
            items: [
                ("Existing", "existing", "https://h.example/existing.mp3", Self.d1),
                ("New", "new", "https://h.example/new.mp3", Self.d2),
            ]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/refresh")
        let newID = try XCTUnwrap(harness.database.scalarInt64(
            "SELECT id FROM episodes WHERE guid = 'new'"
        ))
        XCTAssertEqual(
            try AdRemovalJobStore(database: harness.database).job(episodeID: newID)?.stage,
            .queued
        )

        let disabled = try await call(harness.backend, "POST", "/api/ad-removal/disable")
        XCTAssertEqual(disabled.statusCode, 200)
        XCTAssertFalse(try decode(AdRemovalSettingsPayload.self, from: disabled).enabled)
    }

    func testAdRemovalLifecycleHandlersWakeAndStopRuntimeWork() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/runtime-hooks.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Runtime Hooks",
            items: [("Episode", "runtime-1", "https://h.example/runtime.mp3", Self.d1)]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])
        let episodeID = try XCTUnwrap(harness.database.scalarInt64(
            "SELECT id FROM episodes WHERE guid = 'runtime-1'"
        ))
        let modelRequested = expectation(description: "pinned model requested")
        let pipelineRequested = expectation(description: "pipeline requested")
        pipelineRequested.expectedFulfillmentCount = 2
        let runtimeStopped = expectation(description: "runtime stopped")
        harness.backend.setAdRemovalModelDownloadRequestHandler { manifest in
            XCTAssertEqual(manifest, .qwen3OneSevenBFourBitV1)
            modelRequested.fulfill()
        }
        harness.backend.setAdRemovalRunRequestHandler {
            pipelineRequested.fulfill()
        }
        harness.backend.setAdRemovalStopRequestHandler {
            runtimeStopped.fulfill()
        }

        _ = try await call(
            harness.backend,
            "POST",
            "/api/ad-removal/enable",
            json: ["confirmed_bytes": AdModelManifest.qwen3OneSevenBFourBitV1.totalByteCount]
        )
        _ = try await call(
            harness.backend,
            "POST",
            "/api/episodes/\(episodeID)/ad-removal/prepare"
        )
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Runtime Hooks",
            items: [
                ("Episode", "runtime-1", "https://h.example/runtime.mp3", Self.d1),
                ("New Episode", "runtime-2", "https://h.example/runtime-2.mp3", Self.d2),
            ]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/refresh")
        _ = try await call(harness.backend, "POST", "/api/ad-removal/disable")

        await fulfillment(of: [modelRequested, pipelineRequested, runtimeStopped], timeout: 1)
    }

    func testAdRemovalSettingsCanResetCorrectionsExportDiagnosticsAndDeleteFeatureData() async throws {
        let harness = try makeHarness()
        let diagnostics = try AdRemovalDiagnostics(configuration: .init(
            rootDirectory: harness.directory.appendingPathComponent("Diagnostics", isDirectory: true),
            appVersion: "1.0",
            buildVersion: "1"
        ))
        let backend = PodsBackend(
            database: harness.database,
            feedFetcher: harness.fetcher,
            directorySearcher: DisabledPodcastDirectorySearcher(),
            adRemovalArtifactStore: harness.adRemovalArtifactStore,
            adRemovalDiagnostics: diagnostics
        )
        let feedURL = "https://feeds.example/data-controls.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Data Controls",
            items: [("Episode", "data-1", "https://h.example/data.mp3", Self.d1)]
        ).utf8)
        _ = try await call(backend, "POST", "/api/shows", json: ["feed_url": feedURL])
        let episodeID = try XCTUnwrap(harness.database.scalarInt64(
            "SELECT id FROM episodes WHERE guid = 'data-1'"
        ))
        let podcastID = try XCTUnwrap(harness.database.scalarInt64(
            "SELECT podcast_id FROM episodes WHERE id = ?",
            [.int(episodeID)]
        ))
        let store = AdRemovalJobStore(database: harness.database)
        _ = try store.enqueue(episodeID: episodeID)
        _ = try store.addCorrection(
            podcastID: podcastID,
            sourceEpisodeID: episodeID,
            transcriptWindow: "Editorial segment",
            classificationContext: "false positive",
            classifierVersion: "test",
            promptVersion: "test"
        )
        let episodeMarker = harness.adRemovalArtifactStore.rootURL
            .appendingPathComponent("episodes/orphan/marker.bin")
        let modelMarker = harness.adRemovalArtifactStore.rootURL
            .appendingPathComponent("models/revision/marker.bin")
        try FileManager.default.createDirectory(
            at: episodeMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("episode".utf8).write(to: episodeMarker)
        try Data("model".utf8).write(to: modelMarker)
        try diagnostics.record(eventName: "export_probe", severity: .notice)

        let reset = try await call(
            backend,
            "POST",
            "/api/ad-removal/corrections/\(podcastID)/reset"
        )
        XCTAssertEqual(reset.statusCode, 200)
        XCTAssertTrue(try store.corrections(podcastID: podcastID).isEmpty)

        let exported = try await call(backend, "GET", "/api/ad-removal/diagnostics/export")
        XCTAssertEqual(exported.statusCode, 200)
        XCTAssertEqual(exported.headers["content-type"], "application/zip")
        XCTAssertEqual(Array(exported.body.prefix(4)), [0x50, 0x4b, 0x03, 0x04])

        let cleared = try await call(backend, "POST", "/api/ad-removal/diagnostics/clear")
        XCTAssertEqual(cleared.statusCode, 204)
        XCTAssertTrue(try diagnostics.readPersistedEvents().isEmpty)

        let unconfirmed = try await call(backend, "POST", "/api/ad-removal/cleanup", json: [:])
        XCTAssertEqual(unconfirmed.statusCode, 422)
        let cleaned = try await call(
            backend,
            "POST",
            "/api/ad-removal/cleanup",
            json: ["confirm": "DELETE_AD_REMOVAL_DATA"]
        )
        XCTAssertEqual(cleaned.statusCode, 200)
        XCTAssertNil(try store.job(episodeID: episodeID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: episodeMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelMarker.path))
        let settings = try decode(AdRemovalSettingsPayload.self, from: cleaned)
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.model_download_state, "not_downloaded")
        XCTAssertEqual(settings.model_downloaded_bytes, 0)
    }

    func testPlayedCleanupRemovesEpisodeAdArtifactsButUnsubscribeOwnsPodcastCorrections() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/ad-cleanup.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Cleanup Show",
            items: [("Cleanup Episode", "cleanup-1", "https://h.example/cleanup.mp3", Self.d1)]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])
        let recentResponse = try await call(harness.backend, "GET", "/api/recent")
        let recent = try decode(Page<EpisodeItem>.self, from: recentResponse)
        let episode = try XCTUnwrap(recent.items.first)
        let podcastID = episode.podcast_id
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let job = try store.enqueue(episodeID: episode.id)
        let temporaryAudio = harness.directory.appendingPathComponent("downloaded-audio.tmp")
        try Data("downloaded audio".utf8).write(to: temporaryAudio)
        let audioArtifact = try harness.adRemovalArtifactStore.installDownloadedAudio(
            from: temporaryAudio,
            episodeID: episode.id,
            fileExtension: "mp3"
        )
        _ = try store.recordAudioArtifact(jobID: job.id, artifact: audioArtifact)
        let resumePath = try harness.adRemovalArtifactStore.writeResumeData(Data("resume".utf8), jobID: job.id)
        _ = try store.recordDownloadResumePath(jobID: job.id, relativePath: resumePath)
        try store.replaceTranscriptSegments(episodeID: episode.id, segments: [
            AdTranscriptSegment(
                id: "segment-0",
                index: 0,
                language: "en",
                startTime: 10,
                endTime: 20,
                text: "Advertisement"
            )
        ])
        try store.replaceSkipRanges(episodeID: episode.id, ranges: [
            AdSkipRange(
                id: "range-0",
                startSegmentID: "segment-0",
                endSegmentID: "segment-0",
                startTime: 10,
                endTime: 20,
                confidence: 0.99,
                reason: "promotion",
                classifierVersion: "test-model",
                promptVersion: "test-prompt",
                createdAt: 1_000,
                disabled: false
            )
        ])
        _ = try store.addCorrection(
            podcastID: podcastID,
            sourceEpisodeID: episode.id,
            transcriptWindow: "Not an ad",
            classificationContext: "undo",
            classifierVersion: "test-model",
            promptVersion: "test-prompt"
        )

        let played = try await call(harness.backend, "POST", "/api/episodes/\(episode.id)/played")
        XCTAssertEqual(played.statusCode, 204)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try harness.adRemovalArtifactStore.url(for: audioArtifact.relativePath).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try harness.adRemovalArtifactStore.url(for: resumePath).path
        ))
        XCTAssertEqual(try harness.database.scalarInt64("SELECT COUNT(*) FROM ad_artifact_cleanup"), 0)
        XCTAssertNil(try store.job(episodeID: episode.id))
        XCTAssertTrue(try store.transcriptSegments(episodeID: episode.id).isEmpty)
        XCTAssertTrue(try store.skipRanges(episodeID: episode.id).isEmpty)
        XCTAssertEqual(try store.corrections(podcastID: podcastID).count, 1)

        let unsubscribed = try await call(harness.backend, "DELETE", "/api/shows/\(podcastID)")
        XCTAssertEqual(unsubscribed.statusCode, 204)
        XCTAssertTrue(try store.corrections(podcastID: podcastID).isEmpty)
    }

    func testNativePlaybackProgressRecordingUpdatesEpisodePosition() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/a.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Alpha",
            items: [
                ("Long Listen", "g1", "https://h.example/1.mp3", Self.d1)
            ]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])
        let recent = try decode(Page<EpisodeItem>.self, from: try await call(harness.backend, "GET", "/api/recent"))
        let episodeID = try XCTUnwrap(recent.items.first?.id)

        harness.backend.recordPlaybackProgress(episodeID: episodeID, seconds: 4_200)

        let detail = try decode(EpisodeDetail.self, from: try await call(harness.backend, "GET", "/api/episodes/\(episodeID)"))
        XCTAssertEqual(detail.position_secs, 4_200)
    }

    func testSearchRefreshOpmlAndUnsubscribe() async throws {
        let harness = try makeHarness()
        let urlA = "https://feeds.example/a.xml"
        let urlB = "https://feeds.example/b.xml"
        harness.fetcher.responses[urlA] = Data(Self.rss(show: "Alpha", items: [
            ("Quantum Entanglement Special", "g1", "https://h.example/1.mp3", Self.d1)
        ]).utf8)
        harness.fetcher.responses[urlB] = Data(Self.rss(show: "Beta", items: [
            ("Beta Ep", "g1", "https://h.example/b1.mp3", Self.d2)
        ]).utf8)

        let alpha = try decode(Show.self, from: try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": urlA]))

        let search = try decode(SearchResults.self, from: try await call(harness.backend, "GET", "/api/search?q=quantum"))
        XCTAssertFalse(search.directory_configured)
        XCTAssertTrue(search.podcasts.isEmpty)
        XCTAssertEqual(search.episodes.first?.title, "Quantum Entanglement Special")
        let emptySearch = try await call(harness.backend, "GET", "/api/search?q=%20")
        XCTAssertEqual(emptySearch.statusCode, 422)

        let exported = try await call(harness.backend, "GET", "/api/opml")
        XCTAssertEqual(exported.statusCode, 200)
        XCTAssertTrue(String(data: exported.body, encoding: .utf8)?.contains("Alpha") == true)

        let opml = """
        <opml version="2.0"><body>
          <outline type="rss" text="Alpha" xmlUrl="\(urlA)"/>
          <outline type="rss" text="Beta" xmlUrl="\(urlB)"/>
          <outline type="rss" text="Bogus" xmlUrl="https://feeds.example/missing.xml"/>
        </body></opml>
        """
        let imported = try decode(OPMLImportResult.self, from: try await call(harness.backend, "POST", "/api/opml", text: opml))
        XCTAssertEqual(imported, OPMLImportResult(imported: 1, skipped: 1, failed: 1))
        let invalidOPML = try await call(harness.backend, "POST", "/api/opml", text: "not opml")
        XCTAssertEqual(invalidOPML.statusCode, 422)

        harness.fetcher.responses[urlA] = Data(Self.rss(show: "Alpha", items: [
            ("Quantum Entanglement Special", "g1", "https://h.example/1.mp3", Self.d1),
            ("New Ep", "g2", "https://h.example/2.mp3", Self.d3)
        ]).utf8)
        let refreshed = try decode(RefreshResult.self, from: try await call(harness.backend, "POST", "/api/refresh"))
        XCTAssertEqual(refreshed, RefreshResult(refreshed: 2, errors: 0))
        let recent = try decode(Page<EpisodeItem>.self, from: try await call(harness.backend, "GET", "/api/recent"))
        XCTAssertEqual(recent.items.first?.title, "New Ep")

        let deleteAlpha = try await call(harness.backend, "DELETE", "/api/shows/\(alpha.id)")
        XCTAssertEqual(deleteAlpha.statusCode, 204)
        let afterDelete = try decode(Page<EpisodeItem>.self, from: try await call(harness.backend, "GET", "/api/recent"))
        XCTAssertFalse(afterDelete.items.contains { $0.podcast_title == "Alpha" })
        let deleteAgain = try await call(harness.backend, "DELETE", "/api/shows/\(alpha.id)")
        XCTAssertEqual(deleteAgain.statusCode, 404)
    }

    func testNativeCoordinatorRefreshesAStaleQueueOnceAndRecordsTheForegroundRun() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/a.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(show: "Alpha", items: [
            ("Episode", "g1", "https://h.example/1.mp3", Self.d1)
        ]).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])

        let coordinator = FeedRefreshCoordinator(backend: harness.backend)
        harness.backend.setRefreshRequestHandler { source in
            await coordinator.refreshNow(source: source)
        }

        let refreshed = await coordinator.refreshIfDue()
        XCTAssertEqual(refreshed, RefreshResult(refreshed: 1, errors: 0))
        XCTAssertEqual(harness.fetcher.requestedURLs.count, 2)

        let status = try decode(RefreshStatus.self, from: try await call(harness.backend, "GET", "/api/refresh-status"))
        XCTAssertEqual(status.last_source, "foreground")
        XCTAssertNotNil(status.last_attempt_at)
        XCTAssertNotNil(status.last_success_at)
        XCTAssertEqual(status.last_refreshed, 1)
        XCTAssertEqual(status.last_errors, 0)

        let freshResult = await coordinator.refreshIfDue()
        XCTAssertNil(freshResult)
        XCTAssertEqual(harness.fetcher.requestedURLs.count, 2)
    }

    func testManualRefreshUsesTheNativeCoordinatorAndOverridesTheFreshnessWindow() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/a.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(show: "Alpha", items: [
            ("Episode", "g1", "https://h.example/1.mp3", Self.d1)
        ]).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])

        let coordinator = FeedRefreshCoordinator(backend: harness.backend)
        harness.backend.setRefreshRequestHandler { source in
            await coordinator.refreshNow(source: source)
        }
        _ = await coordinator.refreshIfDue()

        let response = try decode(RefreshResult.self, from: try await call(harness.backend, "POST", "/api/refresh"))
        XCTAssertEqual(response, RefreshResult(refreshed: 1, errors: 0))
        XCTAssertEqual(harness.fetcher.requestedURLs.count, 3)

        let status = try decode(RefreshStatus.self, from: try await call(harness.backend, "GET", "/api/refresh-status"))
        XCTAssertEqual(status.last_source, "manual")
    }

    func testRefreshPolicyRequestsAtMostOneAutomaticPassEveryTwelveHours() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let lastSuccess = Int64(now.addingTimeInterval(-5 * 60 * 60).timeIntervalSince1970)
        let status = RefreshStatus(
            last_attempt_at: lastSuccess,
            last_success_at: lastSuccess,
            last_source: "foreground",
            last_refreshed: 1,
            last_errors: 0
        )

        XCTAssertFalse(FeedRefreshPolicy.isForegroundRefreshDue(status: status, now: now))
        XCTAssertEqual(
            FeedRefreshPolicy.nextBackgroundRefreshDate(status: status, now: now),
            Date(timeIntervalSince1970: TimeInterval(lastSuccess) + FeedRefreshPolicy.automaticInterval)
        )
    }

    func testRefreshPolicyBacksOffForTwoHoursAfterAnAutomaticFailure() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let lastAttempt = Int64(now.addingTimeInterval(-30 * 60).timeIntervalSince1970)
        let status = RefreshStatus(
            last_attempt_at: lastAttempt,
            last_success_at: Int64(now.addingTimeInterval(-13 * 60 * 60).timeIntervalSince1970),
            last_source: "foreground",
            last_refreshed: 2,
            last_errors: 1
        )

        XCTAssertFalse(FeedRefreshPolicy.isForegroundRefreshDue(status: status, now: now))
        XCTAssertEqual(
            FeedRefreshPolicy.nextBackgroundRefreshDate(status: status, now: now),
            Date(timeIntervalSince1970: TimeInterval(lastAttempt) + FeedRefreshPolicy.retryInterval)
        )
    }

    func testRefreshUsesStoredHTTPValidatorsAndCountsNotModifiedAsAHealthyFeed() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/a.xml"
        let validators = FeedValidators(eTag: "\"version-1\"", lastModified: "Wed, 01 Jul 2026 00:00:00 GMT")
        harness.fetcher.responses[feedURL] = Data(Self.rss(show: "Alpha", items: [
            ("Episode", "g1", "https://h.example/1.mp3", Self.d1)
        ]).utf8)
        harness.fetcher.responseValidators[feedURL] = validators

        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])
        harness.fetcher.notModifiedURLs.insert(feedURL)

        let refreshed = try decode(RefreshResult.self, from: try await call(harness.backend, "POST", "/api/refresh"))
        XCTAssertEqual(refreshed, RefreshResult(refreshed: 1, errors: 0))
        XCTAssertEqual(harness.fetcher.requestedValidators.last, validators)
    }

    func testSearchIncludesConfiguredDirectoryResults() async throws {
        let subscribedURL = "https://feeds.example/subscribed.xml"
        let harness = try makeHarness(directorySearcher: MockDirectorySearcher(podcasts: [
            DirectoryPodcast(
                title: "Already Saved",
                author: "Known Author",
                feed_url: subscribedURL,
                image_url: "https://img.example/saved.jpg",
                description: "Saved show",
                subscribed: false
            ),
            DirectoryPodcast(
                title: "Fresh Find",
                author: "New Author",
                feed_url: "https://feeds.example/fresh.xml",
                image_url: "https://img.example/fresh.jpg",
                description: "New show",
                subscribed: false
            )
        ]))
        harness.fetcher.responses[subscribedURL] = Data(Self.rss(show: "Already Saved", items: [
            ("Intro", "saved-1", "https://h.example/saved-1.mp3", Self.d1)
        ]).utf8)
        _ = try decode(Show.self, from: try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": subscribedURL]))

        let search = try decode(SearchResults.self, from: try await call(harness.backend, "GET", "/api/search?q=software"))

        XCTAssertTrue(search.directory_configured)
        XCTAssertEqual(search.podcasts.map(\.title), ["Already Saved", "Fresh Find"])
        XCTAssertEqual(search.podcasts.map(\.subscribed), [true, false])
    }

    func testShowSearchIsScopedToOneShow() async throws {
        let harness = try makeHarness()
        let urlA = "https://feeds.example/a.xml"
        let urlB = "https://feeds.example/b.xml"
        harness.fetcher.responses[urlA] = Data(Self.rss(show: "Alpha", items: [
            ("Quantum Entanglement Special", "a1", "https://h.example/a1.mp3", Self.d1),
            ("Ordinary Alpha", "a2", "https://h.example/a2.mp3", Self.d2)
        ]).utf8)
        harness.fetcher.responses[urlB] = Data(Self.rss(show: "Beta", items: [
            ("Quantum Beta", "b1", "https://h.example/b1.mp3", Self.d3)
        ]).utf8)

        let alpha = try decode(Show.self, from: try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": urlA]))
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": urlB])

        let search = try decode(Page<EpisodeItem>.self, from: try await call(harness.backend, "GET", "/api/shows/\(alpha.id)/search?q=quant"))
        XCTAssertEqual(search.items.map(\.title), ["Quantum Entanglement Special"])
        XCTAssertNil(search.next_offset)

        let emptyQuery = try await call(harness.backend, "GET", "/api/shows/\(alpha.id)/search?q=%20")
        XCTAssertEqual(emptyQuery.statusCode, 422)
        let missingShow = try await call(harness.backend, "GET", "/api/shows/424242/search?q=quant")
        XCTAssertEqual(missingShow.statusCode, 404)
    }

    func testLocalServerServesHTTP() async throws {
        let harness = try makeHarness()
        let webRoot = harness.directory.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(
            at: webRoot.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("""
        <!doctype html>
        <div id="root"></div>
        <script type="module" src="./assets/app.js"></script>
        """.utf8).write(to: webRoot.appendingPathComponent("index.html"))
        try Data("document.body.dataset.loaded = 'yes';".utf8)
            .write(to: webRoot.appendingPathComponent("assets/app.js"))

        let server = PodsLocalServer(
            backend: harness.backend,
            staticAssets: PodsStaticAssets(root: webRoot),
            port: 18181
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)

        let rootURL = URL(string: "http://127.0.0.1:18181/")!
        let (htmlData, htmlResponse) = try await URLSession.shared.data(from: rootURL)
        XCTAssertEqual((htmlResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(
            (htmlResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-pods-local-server"),
            "1"
        )
        XCTAssertTrue(String(data: htmlData, encoding: .utf8)?.contains("./assets/app.js") == true)
        XCTAssertEqual(
            (htmlResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-security-policy"),
            PodsStaticAssets.contentSecurityPolicy
        )
        XCTAssertTrue(PodsStaticAssets.contentSecurityPolicy.contains("default-src 'none'"))
        XCTAssertTrue(PodsStaticAssets.contentSecurityPolicy.contains("script-src 'self'"))
        XCTAssertTrue(PodsStaticAssets.contentSecurityPolicy.contains("script-src-attr 'none'"))
        XCTAssertTrue(PodsStaticAssets.contentSecurityPolicy.contains("style-src-attr 'unsafe-inline'"))
        XCTAssertTrue(PodsStaticAssets.contentSecurityPolicy.contains("connect-src 'self'"))
        XCTAssertFalse(PodsStaticAssets.contentSecurityPolicy.contains("script-src 'unsafe-inline'"))

        let assetURL = URL(string: "http://127.0.0.1:18181/assets/app.js")!
        let (_, assetResponse) = try await URLSession.shared.data(from: assetURL)
        XCTAssertEqual((assetResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type"), "text/javascript; charset=utf-8")
        XCTAssertEqual(
            (assetResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-security-policy"),
            PodsStaticAssets.contentSecurityPolicy
        )

        let apiURL = URL(string: "http://127.0.0.1:18181/api/recent")!
        let (apiData, apiResponse) = try await URLSession.shared.data(from: apiURL)
        XCTAssertEqual((apiResponse as? HTTPURLResponse)?.statusCode, 200)
        let page = try JSONDecoder().decode(Page<EpisodeItem>.self, from: apiData)
        XCTAssertTrue(page.items.isEmpty)
    }

    func testLocalServerRejectsInvalidContentLengthsWithoutOverflow() {
        for value in ["-1", "not-a-number", String(Int.max), "5000000"] {
            let data = Data("POST /api/test HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n".utf8)
            switch PodsLocalServer.parseRequest(data) {
            case .invalid:
                break
            case .incomplete, .complete:
                XCTFail("content-length \(value) must be rejected")
            }
        }

        let empty = Data("GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
        switch PodsLocalServer.parseRequest(empty) {
        case .complete(let request):
            XCTAssertTrue(request.body.isEmpty)
        case .incomplete, .invalid:
            XCTFail("a valid empty request must parse")
        }
    }

    func testLocalServerEnsureReadyRestartsAfterListenerStops() async throws {
        let harness = try makeHarness()
        let webRoot = harness.directory.appendingPathComponent("RecoveryWeb", isDirectory: true)
        try FileManager.default.createDirectory(at: webRoot, withIntermediateDirectories: true)
        try Data("<!doctype html><p>recovered</p>".utf8)
            .write(to: webRoot.appendingPathComponent("index.html"))

        let server = PodsLocalServer(
            backend: harness.backend,
            staticAssets: PodsStaticAssets(root: webRoot),
            port: 18182
        )
        defer { server.stop() }

        try await server.ensureReady()
        let rootURL = URL(string: "http://127.0.0.1:18182/")!
        let (initialData, initialResponse) = try await URLSession.shared.data(from: rootURL)
        XCTAssertEqual((initialResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: initialData, encoding: .utf8), "<!doctype html><p>recovered</p>")

        server.stop()

        try await server.ensureReady()
        let (recoveredData, recoveredResponse) = try await URLSession.shared.data(from: rootURL)
        XCTAssertEqual((recoveredResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: recoveredData, encoding: .utf8), "<!doctype html><p>recovered</p>")
    }

    func testBootstrapReplacesEmptyLiveDatabaseFromSeed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodsBootstrapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let liveURL = directory.appendingPathComponent("live.sqlite")
        let seedURL = directory.appendingPathComponent("seed.sqlite")

        _ = try PodsDatabase(url: liveURL)
        try makeSeedDatabase(at: seedURL, title: "Seeded")

        try DatabaseBootstrap.prepare(liveURL: liveURL, seedURL: seedURL)

        let database = try PodsDatabase(url: liveURL)
        XCTAssertEqual(try database.scalarInt64("SELECT COUNT(*) FROM podcasts"), 1)
        XCTAssertEqual(try database.query("SELECT title FROM podcasts", map: { sqliteString($0, 0) }), ["Seeded"])
    }

    func testBootstrapPreservesNonEmptyLiveDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodsBootstrapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let liveURL = directory.appendingPathComponent("live.sqlite")
        let seedURL = directory.appendingPathComponent("seed.sqlite")

        try makeSeedDatabase(at: liveURL, title: "Live")
        try makeSeedDatabase(at: seedURL, title: "Seeded")

        try DatabaseBootstrap.prepare(liveURL: liveURL, seedURL: seedURL)

        let database = try PodsDatabase(url: liveURL)
        XCTAssertEqual(try database.scalarInt64("SELECT COUNT(*) FROM podcasts"), 1)
        XCTAssertEqual(try database.query("SELECT title FROM podcasts", map: { sqliteString($0, 0) }), ["Live"])
    }

    func testTemporaryDebugLogExpiresAfterThreeDays() throws {
        let formatter = ISO8601DateFormatter()
        let beforeExpiry = try XCTUnwrap(formatter.date(from: "2026-07-04T23:59:58Z"))
        let afterExpiry = try XCTUnwrap(formatter.date(from: "2026-07-05T00:00:00Z"))

        XCTAssertEqual(PodsTemporaryDebugLog.expiryISO8601, "2026-07-04T23:59:59Z")
        XCTAssertTrue(PodsTemporaryDebugLog.isEnabled(now: beforeExpiry))
        XCTAssertFalse(PodsTemporaryDebugLog.isEnabled(now: afterExpiry))
    }

    func testPositiveDurationRejectsZeroAndNonFinite() {
        XCTAssertNil(AudioBridge.positiveDuration(nil))
        XCTAssertNil(AudioBridge.positiveDuration(0))
        XCTAssertNil(AudioBridge.positiveDuration(-1))
        XCTAssertNil(AudioBridge.positiveDuration(.nan))
        XCTAssertNil(AudioBridge.positiveDuration(.infinity))
        XCTAssertEqual(AudioBridge.positiveDuration(1234), 1234)
    }

    func testPlaybackProgressPolicyRejectsNonFiniteAndRegressions() {
        // Fresh episode: any finite non-negative position is eligible.
        XCTAssertTrue(PlaybackProgressPolicy.shouldPersist(
            position: 0,
            lastRecordedPosition: nil,
            force: false,
            allowRegress: false,
            strideSeconds: 5
        ))
        XCTAssertTrue(PlaybackProgressPolicy.shouldPersist(
            position: 12,
            lastRecordedPosition: nil,
            force: false,
            allowRegress: false,
            strideSeconds: 5
        ))

        // Glitch zeros / NaN from cast stop or pre-seek clock must not wipe progress.
        XCTAssertFalse(PlaybackProgressPolicy.shouldPersist(
            position: .nan,
            lastRecordedPosition: 1_800,
            force: true,
            allowRegress: false,
            strideSeconds: 5
        ))
        XCTAssertFalse(PlaybackProgressPolicy.shouldPersist(
            position: 0,
            lastRecordedPosition: 1_800,
            force: true,
            allowRegress: false,
            strideSeconds: 5
        ))
        XCTAssertFalse(PlaybackProgressPolicy.shouldPersist(
            position: 1_700,
            lastRecordedPosition: 1_800,
            force: true,
            allowRegress: false,
            strideSeconds: 5
        ))

        // Explicit seek (scrub / skip-back) may move backwards.
        XCTAssertTrue(PlaybackProgressPolicy.shouldPersist(
            position: 1_700,
            lastRecordedPosition: 1_800,
            force: true,
            allowRegress: true,
            strideSeconds: 5
        ))

        // Normal stride throttling when not forced.
        XCTAssertFalse(PlaybackProgressPolicy.shouldPersist(
            position: 1_802,
            lastRecordedPosition: 1_800,
            force: false,
            allowRegress: false,
            strideSeconds: 5
        ))
        XCTAssertTrue(PlaybackProgressPolicy.shouldPersist(
            position: 1_806,
            lastRecordedPosition: 1_800,
            force: false,
            allowRegress: false,
            strideSeconds: 5
        ))
        // Cast path forces frequent writes once advancing.
        XCTAssertTrue(PlaybackProgressPolicy.shouldPersist(
            position: 1_801,
            lastRecordedPosition: 1_800,
            force: true,
            allowRegress: false,
            strideSeconds: 5
        ))
    }

    func testFailedMacStreamReloadsOnlyAfterFailure() {
        XCTAssertTrue(PlaybackProgressPolicy.shouldReloadMacSource(sourceFailed: true))
        XCTAssertFalse(PlaybackProgressPolicy.shouldReloadMacSource(sourceFailed: false))
    }

    func testAdRemovalPlaybackActivityRequiresAnEpisodeAndActivePlayIntent() {
        XCTAssertTrue(PlaybackProgressPolicy.isEpisodePlaybackActive(
            episodeID: 42,
            paused: false
        ))
        XCTAssertFalse(PlaybackProgressPolicy.isEpisodePlaybackActive(
            episodeID: 42,
            paused: true
        ))
        XCTAssertFalse(PlaybackProgressPolicy.isEpisodePlaybackActive(
            episodeID: nil,
            paused: false
        ))
    }

    func testCastKeepAliveRunsOnlyWhileMacIsPreferredOutput() {
        // While casting, the phone stops local AVPlayer. Without a keep-alive audio
        // session, iOS suspends the app when locked and progress stops saving.
        XCTAssertTrue(PlaybackProgressPolicy.shouldRunCastKeepAlive(preferredOutputIsMac: true))
        XCTAssertFalse(PlaybackProgressPolicy.shouldRunCastKeepAlive(preferredOutputIsMac: false))
    }

    func testMacSourceReplacementPreservesPlayIntent() {
        // While Mac is preferred and playback is active, replacing the episode must
        // autoplay on Mac when connected — not fall idle waiting for a second command
        // that can be lost across reconnect.
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldAutoplayMacSourceReplacement(
                wasPlaying: true,
                connected: true
            )
        )
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldAutoplayMacSourceReplacement(
                wasPlaying: true,
                connected: false
            )
        )
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldAutoplayMacSourceReplacement(
                wasPlaying: false,
                connected: true
            )
        )
        // Disconnected + was playing: remember play intent for the reconnect path.
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldPendMacPlayAfterConnect(
                wasPlaying: true,
                connected: false,
                playRequested: false
            )
        )
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldPendMacPlayAfterConnect(
                wasPlaying: false,
                connected: false,
                playRequested: false
            )
        )
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldPendMacPlayAfterConnect(
                wasPlaying: false,
                connected: false,
                playRequested: true
            )
        )
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldPendMacPlayAfterConnect(
                wasPlaying: true,
                connected: true,
                playRequested: false
            )
        )
        // nowPlaying paused flag must reflect intended play across replacement.
        XCTAssertFalse(
            PlaybackProgressPolicy.macSourceReplacementPaused(
                wasPlaying: true,
                pendingPlayAfterConnect: false
            )
        )
        XCTAssertFalse(
            PlaybackProgressPolicy.macSourceReplacementPaused(
                wasPlaying: false,
                pendingPlayAfterConnect: true
            )
        )
        XCTAssertTrue(
            PlaybackProgressPolicy.macSourceReplacementPaused(
                wasPlaying: false,
                pendingPlayAfterConnect: false
            )
        )
    }

    func testMacCastIsSelectableWhenDiscoveredOrConnected() {
        XCTAssertFalse(PlaybackProgressPolicy.isMacCastSelectable(available: false, connected: false))
        XCTAssertTrue(PlaybackProgressPolicy.isMacCastSelectable(available: true, connected: false))
        XCTAssertTrue(PlaybackProgressPolicy.isMacCastSelectable(available: false, connected: true))
        XCTAssertTrue(PlaybackProgressPolicy.isMacCastSelectable(available: true, connected: true))
    }

    func testEpisodeTaggedTransportRejectsStaleIdentity() {
        // Untagged events stay accepted (browser / legacy Mac payloads).
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldAcceptEpisodeTaggedEvent(
                eventEpisodeID: nil,
                currentEpisodeID: 2
            )
        )
        // Matching tag applies to the loaded episode.
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldAcceptEpisodeTaggedEvent(
                eventEpisodeID: 2,
                currentEpisodeID: 2
            )
        )
        // Explicit tag for a prior episode must not mutate transport or emit ended.
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldAcceptEpisodeTaggedEvent(
                eventEpisodeID: 1,
                currentEpisodeID: 2
            )
        )
        // Tagged event with no loaded episode is not attributable — reject.
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldAcceptEpisodeTaggedEvent(
                eventEpisodeID: 1,
                currentEpisodeID: nil
            )
        )
    }

    func testLocalPlayerItemEndedRequiresCurrentItemIdentity() {
        // Two distinct objects: a replaced item must not count as the current item.
        let previous = NSObject()
        let current = NSObject()
        XCTAssertTrue(PlaybackProgressPolicy.isSameObject(current, current))
        XCTAssertFalse(PlaybackProgressPolicy.isSameObject(previous, current))
        XCTAssertFalse(PlaybackProgressPolicy.isSameObject(nil, current))
        XCTAssertFalse(PlaybackProgressPolicy.isSameObject(current, nil))
        XCTAssertFalse(PlaybackProgressPolicy.isSameObject(nil, nil))
    }

    func testTransportPositionPrefersLastKnownOverInvalidClock() {
        // Mac stop / pre-seek AVPlayer clocks must not report 0 when we already know better.
        XCTAssertEqual(
            PlaybackProgressPolicy.resolvedTransportPosition(
                candidate: .nan,
                lastKnown: 1_234
            ),
            1_234
        )
        XCTAssertEqual(
            PlaybackProgressPolicy.resolvedTransportPosition(
                candidate: 0,
                lastKnown: 1_234
            ),
            1_234
        )
        XCTAssertEqual(
            PlaybackProgressPolicy.resolvedTransportPosition(
                candidate: 1_250,
                lastKnown: 1_234
            ),
            1_250
        )
        XCTAssertEqual(
            PlaybackProgressPolicy.resolvedTransportPosition(
                candidate: 0,
                lastKnown: 0
            ),
            0
        )
    }

    func testSilentKeepAliveWavIsValidRIFF() {
        let data = PlaybackProgressPolicy.silentKeepAliveWavData()
        XCTAssertGreaterThan(data.count, 44)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
    }

    func testNowPlayingInfoIncludesEpisodeMetadataAndPlaybackState() throws {
        let metadata = try XCTUnwrap(AudioBridge.metadata(from: [
            "title": "Episode Title",
            "artist": "Show Title",
            "artwork": "/api/artwork/episodes/4",
            "duration": NSNumber(value: 1234)
        ]))

        XCTAssertEqual(metadata.title, "Episode Title")
        XCTAssertEqual(metadata.artist, "Show Title")
        XCTAssertEqual(metadata.artworkURL?.absoluteString, "http://127.0.0.1:18180/api/artwork/episodes/4")
        XCTAssertEqual(metadata.duration, 1234)

        let playing = AudioBridge.nowPlayingInfo(
            metadata: metadata,
            position: 42,
            duration: 0,
            playbackRate: 1.5,
            paused: false
        )
        XCTAssertEqual(playing[MPMediaItemPropertyTitle] as? String, "Episode Title")
        XCTAssertEqual(playing[MPMediaItemPropertyArtist] as? String, "Show Title")
        XCTAssertEqual(playing[MPMediaItemPropertyPlaybackDuration] as? Double, 1234)
        XCTAssertEqual(playing[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
        XCTAssertEqual(playing[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)

        let paused = AudioBridge.nowPlayingInfo(
            metadata: metadata,
            position: 42,
            duration: 0,
            playbackRate: 1.5,
            paused: true
        )
        XCTAssertEqual(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    }

    // MARK: - Remote command forward skip (car Next Track / Skip Forward)

    /// Fakes only the forward MediaPlayer command-registration boundary.
    private final class FakeRemoteForwardCommandRegistrar: RemoteForwardCommandRegistering {
        private(set) var nextTrackHandler: (() -> MPRemoteCommandHandlerStatus)?
        private(set) var skipForwardHandler: ((TimeInterval) -> MPRemoteCommandHandlerStatus)?
        private(set) var skipForwardPreferredIntervals: [NSNumber]?

        func registerNextTrackCommand(handler: @escaping () -> MPRemoteCommandHandlerStatus) {
            nextTrackHandler = handler
        }

        func registerSkipForwardCommand(
            preferredIntervals: [NSNumber],
            handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
        ) {
            skipForwardPreferredIntervals = preferredIntervals
            skipForwardHandler = handler
        }
    }

    // MARK: RemoteForwardSkipHandler (pure command-handler seam)

    func testRemoteForwardSkipSeeksAbsoluteTarget() {
        var seekTargets: [Double] = []

        let status = RemoteForwardSkipHandler.handle(
            hasActiveContent: true,
            currentPosition: 100,
            knownDuration: 1_000,
            interval: 30,
            absoluteSeek: { seekTargets.append($0) }
        )

        XCTAssertEqual(status, .success)
        XCTAssertEqual(seekTargets, [130])
    }

    func testRemoteForwardSkipWithNoActiveContentReturnsNoActionableItem() {
        var seekTargets: [Double] = []

        let status = RemoteForwardSkipHandler.handle(
            hasActiveContent: false,
            currentPosition: 100,
            knownDuration: 1_000,
            interval: 30,
            absoluteSeek: { seekTargets.append($0) }
        )

        XCTAssertEqual(status, .noActionableNowPlayingItem)
        XCTAssertEqual(seekTargets, [])
    }

    func testRemoteForwardSkipClampsToKnownDuration() {
        var seekTargets: [Double] = []

        let status = RemoteForwardSkipHandler.handle(
            hasActiveContent: true,
            currentPosition: 590,
            knownDuration: 600,
            interval: 30,
            absoluteSeek: { seekTargets.append($0) }
        )

        XCTAssertEqual(status, .success)
        XCTAssertEqual(seekTargets, [600])
    }

    // MARK: RemoteForwardCommandBinding (forward-only registrar installation seam)

    func testRemoteCommandBindingNextTrackPassesThirtySecondInterval() throws {
        let registrar = FakeRemoteForwardCommandRegistrar()
        var capturedIntervals: [TimeInterval] = []

        RemoteForwardCommandBinding.install(
            on: registrar,
            forwardSkip: { interval in
                capturedIntervals.append(interval)
                return .success
            }
        )

        let status = try XCTUnwrap(registrar.nextTrackHandler)()

        XCTAssertEqual(status, .success)
        XCTAssertEqual(capturedIntervals, [30])
    }

    func testRemoteCommandBindingSkipForwardAdvertisesIntervalAndPassesEventInterval() throws {
        let registrar = FakeRemoteForwardCommandRegistrar()
        var capturedIntervals: [TimeInterval] = []

        RemoteForwardCommandBinding.install(
            on: registrar,
            forwardSkip: { interval in
                capturedIntervals.append(interval)
                return .success
            }
        )

        XCTAssertEqual(registrar.skipForwardPreferredIntervals, [NSNumber(value: 30)])
        let status = try XCTUnwrap(registrar.skipForwardHandler)(45)

        XCTAssertEqual(status, .success)
        XCTAssertEqual(capturedIntervals, [45])
    }

    private static let d1 = "Mon, 06 Jan 2025 00:00:00 GMT"
    private static let d2 = "Tue, 07 Jan 2025 00:00:00 GMT"
    private static let d3 = "Wed, 08 Jan 2025 00:00:00 GMT"
    private static let d4 = "Thu, 09 Jan 2025 00:00:00 GMT"

    private static func rss(show: String, items: [(String, String, String, String)]) -> String {
        var body = "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>\(show)</title><description>About \(show)</description>"
        for (title, guid, url, date) in items {
            body += """
            <item><title>\(title)</title><guid>\(guid)</guid><pubDate>\(date)</pubDate>
            <description>&lt;p&gt;Notes for \(title)&lt;/p&gt;</description>
            <enclosure url="\(url)" type="audio/mpeg" length="123"/></item>
            """
        }
        body += "</channel></rss>"
        return body
    }

    private func makeSeedDatabase(at url: URL, title: String) throws {
        let database = try PodsDatabase(url: url)
        try database.execute(
            """
            INSERT INTO podcasts (id, feed_url, title, created_at)
            VALUES (1, ?, ?, 1)
            """,
            [.text("https://feeds.example/\(title).xml"), .text(title)]
        )
        try database.execute(
            """
            INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at)
            VALUES (1, 1, 'g1', 'Episode', 'https://h.example/1.mp3', 1)
            """
        )
        try database.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)")
    }
}

@MainActor
final class PodsWebViewRecoveryTests: XCTestCase {
    func testBootDocumentTokenIdentifiesOnlyTheCurrentLoopbackDocument() throws {
        let root = try XCTUnwrap(URL(string: "http://127.0.0.1:18180/?ui=progress-v1"))
        let current = try XCTUnwrap(PodsBootDocument.url(rootURL: root, token: "attempt-2"))

        XCTAssertTrue(PodsBootDocument.matches(current, rootURL: root, token: "attempt-2"))
        XCTAssertFalse(PodsBootDocument.matches(current, rootURL: root, token: "attempt-1"))
        XCTAssertFalse(
            PodsBootDocument.matches(
                URL(string: "https://example.com/?pods_boot=attempt-2"),
                rootURL: root,
                token: "attempt-2"
            )
        )
        XCTAssertEqual(URLComponents(url: current, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "ui", value: "progress-v1"),
            URLQueryItem(name: "pods_boot", value: "attempt-2")
        ])
    }

    private final class FakeWebView: PodsWebViewLoading {
        var url: URL?
        var loadedURLs: [URL] = []
        var evaluatedScripts: [String] = []
        var nextEvaluationResult: Any?
        var nextEvaluationError: Error?

        func load(_ request: URLRequest) -> WKNavigation? {
            if let url = request.url {
                loadedURLs.append(url)
                self.url = url
            }
            return nil
        }

        func reload() -> WKNavigation? {
            nil
        }

        func evaluateJavaScript(
            _ javaScriptString: String,
            completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil
        ) {
            evaluatedScripts.append(javaScriptString)
            completionHandler?(nextEvaluationResult, nextEvaluationError)
        }
    }

    /// Deterministic delayed-work seam: captures scheduled closures so tests can run them without real time.
    @MainActor
    private final class ManualScheduler {
        private(set) var scheduledCount = 0
        private(set) var cancelCount = 0
        private var pending: [@MainActor () -> Void] = []

        func schedule(_ work: @escaping @MainActor () -> Void) -> () -> Void {
            scheduledCount += 1
            let index = pending.count
            pending.append(work)
            return { [weak self] in
                guard let self else {
                    return
                }
                self.cancelCount += 1
                if index < self.pending.count {
                    self.pending[index] = {}
                }
            }
        }

        func runAllPending() {
            let works = pending
            pending.removeAll()
            for work in works {
                work()
            }
        }
    }

    private let localRootURL = URL(string: "http://127.0.0.1:18180/")!

    private func makeRecovery(
        scheduler: ManualScheduler
    ) -> PodsWebViewRecovery {
        PodsWebViewRecovery(rootURL: localRootURL, scheduleDelayedWork: scheduler.schedule)
    }

    private func makeRenderedWebView() -> FakeWebView {
        let webView = FakeWebView()
        webView.url = localRootURL
        webView.nextEvaluationResult = true
        return webView
    }

    func testActivationPolicyDoesNotRestartAnActiveBootRecovery() {
        XCTAssertEqual(
            PodsWebViewActivationPolicy.action(
                state: .recovering,
                recoveryAttempt: 1,
                maximumAttempts: 3
            ),
            .none
        )
        XCTAssertEqual(
            PodsWebViewActivationPolicy.action(
                state: .waitingForUI,
                recoveryAttempt: 1,
                maximumAttempts: 3
            ),
            .none
        )
        XCTAssertEqual(
            PodsWebViewActivationPolicy.action(
                state: .ready,
                recoveryAttempt: 0,
                maximumAttempts: 3
            ),
            .verifyReadyUI
        )
    }

    func testUIHealthCheckTimeoutRejectsItsLateCallback() {
        let scheduler = ManualScheduler()
        let fence = PodsWebViewHealthCheckFence(scheduleTimeout: scheduler.schedule)
        let webView = NSObject()
        var timeoutCount = 0
        let attempt = fence.begin(
            token: "boot-1",
            webViewID: ObjectIdentifier(webView),
            onTimeout: { timeoutCount += 1 }
        )

        scheduler.runAllPending()

        XCTAssertEqual(timeoutCount, 1)
        XCTAssertFalse(
            fence.accept(
                attempt,
                currentToken: "boot-1",
                currentWebViewID: ObjectIdentifier(webView)
            )
        )
    }

    func testUIHealthCheckRejectsReplacedWebViewAndCancelsAcceptedTimeout() {
        let scheduler = ManualScheduler()
        let fence = PodsWebViewHealthCheckFence(scheduleTimeout: scheduler.schedule)
        let oldWebView = NSObject()
        let currentWebView = NSObject()
        var timeoutCount = 0
        let staleAttempt = fence.begin(
            token: "boot-1",
            webViewID: ObjectIdentifier(oldWebView),
            onTimeout: { timeoutCount += 1 }
        )
        let currentAttempt = fence.begin(
            token: "boot-2",
            webViewID: ObjectIdentifier(currentWebView),
            onTimeout: { timeoutCount += 1 }
        )

        XCTAssertFalse(
            fence.accept(
                staleAttempt,
                currentToken: "boot-2",
                currentWebViewID: ObjectIdentifier(currentWebView)
            )
        )
        XCTAssertTrue(
            fence.accept(
                currentAttempt,
                currentToken: "boot-2",
                currentWebViewID: ObjectIdentifier(currentWebView)
            )
        )
        scheduler.runAllPending()
        XCTAssertEqual(timeoutCount, 0)
    }

    func testWebContentTerminationReloadsLocalRoot() {
        let recovery = PodsWebViewRecovery(rootURL: localRootURL)
        let webView = FakeWebView()

        recovery.recoverFromWebContentTermination(webView)

        XCTAssertEqual(webView.loadedURLs, [localRootURL])
    }

    func testForegroundRecoveryReloadsWhenRootIsEmpty() {
        let recovery = PodsWebViewRecovery(rootURL: localRootURL)
        let webView = FakeWebView()
        webView.url = localRootURL
        webView.nextEvaluationResult = false

        recovery.reloadIfContentMissing(webView)

        XCTAssertEqual(webView.loadedURLs, [localRootURL])
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
    }

    func testForegroundRecoveryKeepsRenderedRoot() {
        let recovery = PodsWebViewRecovery(rootURL: localRootURL)
        let webView = FakeWebView()
        webView.url = localRootURL
        webView.nextEvaluationResult = true

        recovery.reloadIfContentMissing(webView)

        XCTAssertTrue(webView.loadedURLs.isEmpty)
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
    }

    func testActivationChecksRootImmediatelyAndSchedulesOneDelayedRecheck() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let webView = makeRenderedWebView()

        recovery.handleActivation(webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 1, "activation must health-check immediately")
        XCTAssertEqual(scheduler.scheduledCount, 1, "activation must schedule exactly one delayed recheck")

        scheduler.runAllPending()

        XCTAssertEqual(webView.evaluatedScripts.count, 2, "delayed recheck must run a second health check")
        XCTAssertTrue(webView.loadedURLs.isEmpty)
    }

    func testRepeatedActivationCancelsPriorDelayedWork() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let webView = makeRenderedWebView()

        recovery.handleActivation(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        recovery.handleActivation(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 2, "second activation checks immediately again")
        XCTAssertEqual(scheduler.scheduledCount, 2, "second activation schedules a replacement delayed recheck")
        XCTAssertEqual(scheduler.cancelCount, 1, "prior delayed work must be cancelled before rescheduling")

        scheduler.runAllPending()

        // Only the replacement delayed work should perform a health check (cancelled work is a no-op).
        XCTAssertEqual(webView.evaluatedScripts.count, 3)
    }

    /// Models the production race: DispatchWorkItem has already fired and enqueued its
    /// MainActor Task, so cancel only records intent and cannot suppress the captured callback.
    private final class NonCooperativeScheduler {
        private(set) var scheduledCount = 0
        private(set) var cancelCount = 0
        private var pending: [() -> Void] = []

        func schedule(_ work: @escaping () -> Void) -> () -> Void {
            scheduledCount += 1
            pending.append(work)
            return { [weak self] in
                self?.cancelCount += 1
                // Intentionally do not suppress the captured callback — race already lost.
            }
        }

        func runAllPending() {
            let works = pending
            pending.removeAll()
            for work in works {
                work()
            }
        }
    }

    func testReplacedActivationIgnoresStaleDelayedCallbackAfterLostCancelRace() {
        let scheduler = NonCooperativeScheduler()
        let recovery = PodsWebViewRecovery(
            rootURL: localRootURL,
            scheduleDelayedWork: scheduler.schedule
        )
        let webView = makeRenderedWebView()

        recovery.handleActivation(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        recovery.handleActivation(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 2, "second activation checks immediately again")
        XCTAssertEqual(scheduler.scheduledCount, 2, "second activation schedules a replacement delayed recheck")
        XCTAssertEqual(scheduler.cancelCount, 1, "prior delayed work must still be cancelled for cleanup")

        // Both callbacks fire (cancel lost the race). Only the newest recovery may health-check.
        scheduler.runAllPending()

        XCTAssertEqual(
            webView.evaluatedScripts.count,
            3,
            "stale delayed recovery must no-op even when scheduler cancel loses the race"
        )
    }

    func testCancelPendingRecoveryPreventsDelayedWork() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let webView = makeRenderedWebView()

        recovery.handleActivation(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        recovery.cancelPendingRecovery()
        XCTAssertEqual(scheduler.cancelCount, 1)

        scheduler.runAllPending()

        XCTAssertEqual(
            webView.evaluatedScripts.count,
            1,
            "cancelled delayed recheck must not perform another health check"
        )
    }

    func testLifecycleAppearActivatesRecovery() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let lifecycle = PodsWebViewRecoveryLifecycle(recovery: recovery)
        let webView = makeRenderedWebView()

        lifecycle.handleAppear(webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 1, "appear must activate an immediate health check")
        XCTAssertEqual(scheduler.scheduledCount, 1, "appear must schedule one delayed recheck")

        scheduler.runAllPending()

        XCTAssertEqual(webView.evaluatedScripts.count, 2, "appear-scheduled delayed recheck must run")
    }

    func testLifecycleDisappearCancelsPendingRecovery() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let lifecycle = PodsWebViewRecoveryLifecycle(recovery: recovery)
        let webView = makeRenderedWebView()

        lifecycle.handleAppear(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        lifecycle.handleDisappear()
        XCTAssertEqual(scheduler.cancelCount, 1, "disappear must cancel pending delayed recovery")

        scheduler.runAllPending()

        XCTAssertEqual(
            webView.evaluatedScripts.count,
            1,
            "cancelled delayed recheck after disappear must not run"
        )
    }

    func testLifecycleBecomeActiveActivatesRecoveryAfterDisappear() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let lifecycle = PodsWebViewRecoveryLifecycle(recovery: recovery)
        let webView = makeRenderedWebView()

        lifecycle.handleAppear(webView)
        lifecycle.handleDisappear()
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertEqual(scheduler.cancelCount, 1)

        lifecycle.handleBecomeActive(webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 2, "become-active must re-activate recovery")
        XCTAssertEqual(scheduler.scheduledCount, 2, "become-active must schedule a fresh delayed recheck")
    }

    func testBootRecoveryDoesNotDeclareReadyUntilServerAndReactAreReady() async {
        var ensureCalls = 0
        var loadCalls = 0
        var states: [PodsWebViewBootRecovery.State] = []
        let recovery = PodsWebViewBootRecovery(
            ensureServerReady: {
                ensureCalls += 1
            },
            loadRoot: {
                loadCalls += 1
            },
            stateDidChange: { state in
                states.append(state)
            }
        )

        await recovery.recover(reason: "web-content-terminated")

        XCTAssertEqual(ensureCalls, 1)
        XCTAssertEqual(loadCalls, 1)
        XCTAssertEqual(recovery.state, .waitingForUI)
        XCTAssertEqual(states, [.recovering, .waitingForUI])

        recovery.markUIReady()

        XCTAssertEqual(recovery.state, .ready)
        XCTAssertEqual(states, [.recovering, .waitingForUI, .ready])
    }

    func testBootRecoveryKeepsNativeFailureStateWhenServerCannotRecover() async {
        struct Refused: LocalizedError {
            var errorDescription: String? { "connection refused" }
        }
        var loadCalls = 0
        let recovery = PodsWebViewBootRecovery(
            ensureServerReady: {
                throw Refused()
            },
            loadRoot: {
                loadCalls += 1
            }
        )

        await recovery.recover(reason: "foreground")

        XCTAssertEqual(loadCalls, 0)
        XCTAssertEqual(recovery.state, .failed("connection refused"))
    }
}
