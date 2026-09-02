import XCTest
import MediaPlayer
import WebKit
@testable import Pods

final class PodsBackendTests: XCTestCase {
    private actor CompletionProbe {
        private var completed = false

        func markCompleted() { completed = true }
        func isCompleted() -> Bool { completed }
    }

    private actor ControlledRefreshHandler {
        private var calls = 0
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func perform() async -> RefreshResult {
            calls += 1
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            return RefreshResult(refreshed: 1, errors: 0)
        }

        func waitUntilStarted() async {
            if calls > 0 { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }

        func callCount() -> Int { calls }
    }

    private actor BlockingFeedFetcher: ConditionalFeedFetching {
        private let responseData: Data
        private var started = false
        private var released = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        init(responseData: Data) {
            self.responseData = responseData
        }

        func data(for url: URL) async throws -> Data {
            await waitForRelease()
            return responseData
        }

        func response(for url: URL, validators: FeedValidators) async throws -> FeedFetchResponse {
            await waitForRelease()
            return .data(responseData, validators)
        }

        private func waitForRelease() async {
            started = true
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private actor CancellationHoldingClassificationExecutor: AdRemovalStageExecuting {
        private let store: AdRemovalJobStore
        private var entered = false
        private var cancellationObserved = false
        private var released = false
        private var staleWriteSucceeded: Bool?
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        init(store: AdRemovalJobStore) {
            self.store = store
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func waitUntilCancellationObserved() async {
            if cancellationObserved { return }
            await withCheckedContinuation { cancellationWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }

        func didPersistAfterCancellation() -> Bool? {
            staleWriteSucceeded
        }

        func execute(stage: AdRemovalJobStage, job: AdRemovalJob) async throws {
            entered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters.removeAll()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch is CancellationError {
                cancellationObserved = true
                cancellationWaiters.forEach { $0.resume() }
                cancellationWaiters.removeAll()
                if !released {
                    await withCheckedContinuation { releaseWaiters.append($0) }
                }
                do {
                    try store.recordClassificationEvidence(
                        Self.evidence(episodeID: job.episodeID),
                        jobID: job.id
                    )
                    staleWriteSucceeded = true
                } catch {
                    staleWriteSucceeded = false
                }
                throw CancellationError()
            }
        }

        private nonisolated static func evidence(episodeID: Int64) -> AdClassificationEvidence {
            AdClassificationEvidence(
                runID: "cancelled-run",
                episodeID: episodeID,
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
        }
    }

    private actor CancellationBlockingShowNotesGenerator: EpisodeShowNotesGenerating {
        nonisolated let modelID = "test/show-notes"
        nonisolated let promptVersion = "show-notes-prompt-v1"
        private var entered = false
        private var cancellationObserved = false
        private var cancellationReleased = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func hasObservedCancellation() -> Bool {
            cancellationObserved
        }

        func releaseAfterCancellation() {
            cancellationReleased = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }

        func generate(segments: [AdTranscriptSegment]) async throws -> [EpisodeShowNoteDraft] {
            entered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters.removeAll()
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch is CancellationError {
                cancellationObserved = true
                if !cancellationReleased {
                    await withCheckedContinuation { releaseWaiters.append($0) }
                }
                throw CancellationError()
            }
            guard let segment = segments.first else {
                throw EpisodeShowNotesError.noContent
            }
            return [EpisodeShowNoteDraft(
                segmentID: segment.id,
                title: "Opening",
                summary: "The episode begins."
            )]
        }
    }

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

    private final class FeedRequestCaptureURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var capturedRequest: URLRequest?

        static func reset() {
            lock.lock()
            defer { lock.unlock() }
            capturedRequest = nil
        }

        static func request() -> URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return capturedRequest
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "feeds.example"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.lock.lock()
            Self.capturedRequest = request
            Self.lock.unlock()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<rss/>".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class SchemeRetryURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var requested: [URL] = []
        private static var failSchemes: Set<String> = ["http"]

        static func reset(failSchemes: Set<String> = ["http"]) {
            lock.lock()
            defer { lock.unlock() }
            requested = []
            Self.failSchemes = failSchemes
        }

        static func requestedURLs() -> [URL] {
            lock.lock()
            defer { lock.unlock() }
            return requested
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "retry.example"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.lock.lock()
            Self.requested.append(request.url!)
            let shouldFail = Self.failSchemes.contains(request.url?.scheme ?? "")
            Self.lock.unlock()
            guard !shouldFail else {
                // Mirrors the on-device ATS violation for http feed URLs.
                let atsError = URLError(
                    URLError.Code(rawValue: -1022),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The resource could not be loaded because the App Transport Security policy requires the use of a secure connection."
                    ]
                )
                client?.urlProtocol(self, didFailWithError: atsError)
                return
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<rss/>".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
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

    private struct MockAppearanceSearcher: PodcastDirectorySearching, PersonAppearanceSearching {
        var appearances: [String: [DirectoryAppearance]]

        var isConfigured: Bool { true }

        func search(query: String) async throws -> [DirectoryPodcast] { [] }

        func searchAppearances(person: String) async throws -> [DirectoryAppearance] {
            appearances[person] ?? []
        }
    }

    private struct Harness {
        let backend: PodsBackend
        let fetcher: MockFeedFetcher
        let directory: URL
        let database: PodsDatabase
        let adRemovalArtifactStore: AdRemovalArtifactStore
    }

    private final class StubDeepSeekCredentialStore: DeepSeekCredentialStoring {
        private var apiKey: String?

        init(apiKey: String? = "test-api-key") {
            self.apiKey = apiKey
        }

        var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }
        func readAPIKey() throws -> String? { apiKey }
        func saveAPIKey(_ value: String) throws { apiKey = value }
    }

    private func makeHarness(
        directorySearcher: PodcastDirectorySearching? = nil,
        deepSeekAPIKey: String? = "test-api-key"
    ) throws -> Harness {
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
            adRemovalArtifactStore: adRemovalArtifactStore,
            deepSeekCredentialStore: StubDeepSeekCredentialStore(apiKey: deepSeekAPIKey)
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

    private func prepareClassifyingEpisode(
        _ harness: Harness,
        guid: String
    ) async throws -> (episodeID: Int64, store: AdRemovalJobStore, job: AdRemovalJob) {
        let feedURL = "https://feeds.example/\(guid).xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Cancellation Test",
            items: [("Episode", guid, "https://h.example/\(guid).mp3", Self.d1)]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])
        let episodeID = try XCTUnwrap(harness.database.scalarInt64(
            "SELECT id FROM episodes WHERE guid = ?",
            [.text(guid)]
        ))
        try harness.database.execute(
            """
            INSERT INTO settings (key, value) VALUES ('ad_removal_enabled', 'true')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        let store = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        let queued = try store.enqueue(episodeID: episodeID)
        var job = queued
        for stage in [
            AdRemovalJobStage.downloading,
            .downloaded,
            .transcribing,
            .classifying
        ] {
            job = try store.transition(jobID: queued.id, to: stage)
        }
        return (episodeID, store, job)
    }

    func testEndpointsDoNotRequireAuth() async throws {
        let harness = try makeHarness()
        let response = try await call(harness.backend, "GET", "/api/recent")
        XCTAssertEqual(response.statusCode, 200)
        let page = try decode(Page<EpisodeItem>.self, from: response)
        XCTAssertTrue(page.items.isEmpty)
    }

    func testFollowAcceptsHighConfidenceAppearanceIntoListen() async throws {
        let appearance = DirectoryAppearance(
            source_episode_key: "appearance-1",
            feed_url: "https://feeds.example/interviews.xml",
            feed_title: "Interviews",
            feed_image_url: "https://images.example/show.jpg",
            guid: "guest-1",
            title: "Balaji Srinivasan on Network States",
            description: "A full conversation with Balaji Srinivasan.",
            audio_url: "https://audio.example/guest-1.mp3",
            duration_secs: 3600,
            published_at: nowUnix(),
            image_url: "https://images.example/episode.jpg",
            evidence: "person tag: guest",
            confidence: "high"
        )
        let harness = try makeHarness(directorySearcher: MockAppearanceSearcher(appearances: ["Balaji Srinivasan": [appearance]]))

        let created = try await call(harness.backend, "POST", "/api/follows", json: ["name": "Balaji Srinivasan"])
        XCTAssertEqual(created.statusCode, 201)
        let follow = try decode(Follow.self, from: created)
        XCTAssertEqual(follow.accepted_count, 1)
        XCTAssertEqual(follow.pending_count, 0)

        let refreshed = try await call(harness.backend, "POST", "/api/follows/\(follow.id)")
        let refreshedFollow = try decode(Follow.self, from: refreshed)
        XCTAssertEqual(refreshedFollow.accepted_count, 1, "repeat checks dedupe an already accepted appearance")

        let recent = try await call(harness.backend, "GET", "/api/recent")
        let page = try decode(Page<EpisodeItem>.self, from: recent)
        XCTAssertEqual(page.items.map(\.title), [appearance.title])
        let shows = try await call(harness.backend, "GET", "/api/shows")
        let showList = try decode([Show].self, from: shows)
        XCTAssertTrue(showList.isEmpty, "appearance sources are not subscriptions")
    }

    func testFollowKeepsAmbiguousAppearanceOutOfListenUntilAccepted() async throws {
        let appearance = DirectoryAppearance(
            source_episode_key: "appearance-2",
            feed_url: "https://feeds.example/tech.xml",
            feed_title: "Tech Talk",
            feed_image_url: "",
            guid: "guest-2",
            title: "The future of Elon Musk's companies",
            description: "A discussion about Elon Musk.",
            audio_url: "https://audio.example/guest-2.mp3",
            duration_secs: nil,
            published_at: nowUnix(),
            image_url: "",
            evidence: "name in title",
            confidence: "review"
        )
        let harness = try makeHarness(directorySearcher: MockAppearanceSearcher(appearances: ["Elon Musk": [appearance]]))
        _ = try await call(harness.backend, "POST", "/api/follows", json: ["name": "Elon Musk"])

        let before = try decode(Page<EpisodeItem>.self, from: try await call(harness.backend, "GET", "/api/recent"))
        XCTAssertTrue(before.items.isEmpty)
        let candidates = try decode([FollowCandidate].self, from: try await call(harness.backend, "GET", "/api/follow-candidates"))
        XCTAssertEqual(candidates.count, 1)

        let accepted = try await call(harness.backend, "POST", "/api/follow-candidates/\(candidates[0].id)/accept")
        XCTAssertEqual(accepted.statusCode, 204)
        let after = try decode(Page<EpisodeItem>.self, from: try await call(harness.backend, "GET", "/api/recent"))
        XCTAssertEqual(after.items.map(\.title), [appearance.title])
    }

    func testFirstFollowCheckExcludesAppearancesOlderThanThirtyDays() async throws {
        let appearance = DirectoryAppearance(
            source_episode_key: "old-appearance",
            feed_url: "https://feeds.example/old.xml",
            feed_title: "Old Interviews",
            feed_image_url: "",
            guid: "old-guest",
            title: "Balaji Srinivasan interview",
            description: "A conversation with Balaji Srinivasan.",
            audio_url: "https://audio.example/old.mp3",
            duration_secs: nil,
            published_at: nowUnix() - 31 * 86_400,
            image_url: "",
            evidence: "person tag: guest",
            confidence: "high"
        )
        let harness = try makeHarness(directorySearcher: MockAppearanceSearcher(appearances: ["Balaji Srinivasan": [appearance]]))
        let response = try await call(harness.backend, "POST", "/api/follows", json: ["name": "Balaji Srinivasan"])
        XCTAssertEqual(try decode(Follow.self, from: response).accepted_count, 0)
        let recent = try await call(harness.backend, "GET", "/api/recent")
        let page = try decode(Page<EpisodeItem>.self, from: recent)
        XCTAssertTrue(page.items.isEmpty)
    }

    func testShowNotesEndpointRejectsCrossOriginBrowserRequestsBeforeGeneration() async throws {
        let harness = try makeHarness()
        let target = "/api/episodes/1/show-notes"
        let maliciousHeaders = [
            "origin": "https://attacker.example",
            "content-type": "application/json"
        ]

        let preflight = await harness.backend.handle(HTTPRequest(
            method: "OPTIONS",
            target: target,
            headers: maliciousHeaders
        ))
        XCTAssertEqual(preflight.statusCode, 403)

        let post = await harness.backend.handle(HTTPRequest(
            method: "POST",
            target: target,
            headers: maliciousHeaders,
            body: Data("{}".utf8)
        ))
        XCTAssertEqual(post.statusCode, 403)

        let missingOriginPreflight = await harness.backend.handle(HTTPRequest(
            method: "OPTIONS",
            target: target,
            headers: ["content-type": "application/json"]
        ))
        XCTAssertEqual(missingOriginPreflight.statusCode, 403)

        let missingOriginPost = await harness.backend.handle(HTTPRequest(
            method: "POST",
            target: target,
            headers: ["content-type": "application/json"],
            body: Data("{}".utf8)
        ))
        XCTAssertEqual(missingOriginPost.statusCode, 403)

        let trusted = await harness.backend.handle(HTTPRequest(
            method: "POST",
            target: target,
            headers: [
                "origin": "http://127.0.0.1:18180",
                "content-type": "application/json"
            ],
            body: Data("{}".utf8)
        ))
        XCTAssertEqual(trusted.statusCode, 404)
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

    func testMarkPlayedPersistsBeforeShowNotesCancellationAndDefersMetadataCleanup() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/show-notes-cancellation.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Show Notes Cancellation",
            items: [("Episode", "show-notes-cancel-1", "https://h.example/cancel.mp3", Self.d1)]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])
        let episodeID = try XCTUnwrap(harness.database.scalarInt64(
            "SELECT id FROM episodes WHERE guid = 'show-notes-cancel-1'"
        ))
        try harness.database.execute(
            """
            INSERT INTO settings (key, value) VALUES ('ad_removal_enabled', 'true')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        let jobStore = AdRemovalJobStore(database: harness.database, now: { 1_000 })
        var job = try jobStore.enqueue(episodeID: episodeID)
        let segment = AdTranscriptSegment(
            id: "segment-opening",
            index: 0,
            language: "en",
            startTime: 12.5,
            endTime: 30,
            text: "Episode content"
        )
        try jobStore.replaceTranscriptSegments(episodeID: episodeID, segments: [segment])
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

        let generator = CancellationBlockingShowNotesGenerator()
        let service = EpisodeShowNotesService(database: harness.database, generator: generator)
        let backend = PodsBackend(
            database: harness.database,
            feedFetcher: harness.fetcher,
            directorySearcher: DisabledPodcastDirectorySearcher(),
            adRemovalArtifactStore: harness.adRemovalArtifactStore,
            episodeShowNotesService: service
        )
        let generation = Task { try await service.generate(episodeID: episodeID) }
        await generator.waitUntilEntered()

        let markPlayed = Task {
            await backend.handle(HTTPRequest(
                method: "POST",
                target: "/api/episodes/\(episodeID)/played"
            ))
        }
        var observedCancellation = false
        for _ in 0..<200 {
            if await generator.hasObservedCancellation() {
                observedCancellation = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(observedCancellation, "mark-played must cancel active show-note generation")
        let response = await markPlayed.value
        XCTAssertEqual(response.statusCode, 204)
        let recentWhileCancellationIsBlocked = try decode(
            Page<EpisodeItem>.self,
            from: try await call(backend, "GET", "/api/recent")
        )
        XCTAssertFalse(recentWhileCancellationIsBlocked.items.contains { $0.id == episodeID })
        XCTAssertNotNil(try harness.database.scalarInt64(
            "SELECT played_at FROM episode_state WHERE episode_id = ?",
            [.int(episodeID)]
        ))
        let cancellingJob = try XCTUnwrap(jobStore.job(episodeID: episodeID))
        XCTAssertEqual(
            cancellingJob.stage,
            .cancelled,
            "mark-played must make the source unavailable while cancellation drains"
        )
        XCTAssertFalse(
            try jobStore.transcriptSegments(episodeID: episodeID).isEmpty,
            "metadata cleanup must wait until cancelled generation has terminated"
        )

        await generator.releaseAfterCancellation()
        for _ in 0..<200 {
            if try jobStore.job(episodeID: episodeID) == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(try jobStore.job(episodeID: episodeID))
        XCTAssertTrue(try jobStore.transcriptSegments(episodeID: episodeID).isEmpty)
        do {
            _ = try await generation.value
            XCTFail("Expected mark-played to cancel in-flight show-note generation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testMarkPlayedIsImmediatelyDurableWhileCleanupContinuesInBackground() async throws {
        let harness = try makeHarness()
        let prepared = try await prepareClassifyingEpisode(harness, guid: "pipeline-mark-played")
        let executor = CancellationHoldingClassificationExecutor(store: prepared.store)
        let coordinator = AdRemovalCoordinator(store: prepared.store, executor: executor)
        harness.backend.setAdRemovalCancellationRequestHandler { scope in
            await coordinator.cancel(scope)
        }
        let pipeline = Task { try await coordinator.runNextStage() }
        await executor.waitUntilEntered()

        let completion = CompletionProbe()
        let markPlayed = Task {
            let response = await harness.backend.handle(HTTPRequest(
                method: "POST",
                target: "/api/episodes/\(prepared.episodeID)/played"
            ))
            await completion.markCompleted()
            return response
        }
        await executor.waitUntilCancellationObserved()

        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertTrue(
            completedBeforeRelease,
            "mark-played must return without waiting for background pipeline cancellation"
        )
        let recentWhileCancellationIsBlocked = try decode(
            Page<EpisodeItem>.self,
            from: try await call(harness.backend, "GET", "/api/recent")
        )
        XCTAssertFalse(
            recentWhileCancellationIsBlocked.items.contains { $0.id == prepared.episodeID },
            "the user's mark-played tap must become authoritative before background cancellation finishes"
        )
        let playedWhileCancellationIsBlocked = try decode(
            Page<EpisodeItem>.self,
            from: try await call(harness.backend, "GET", "/api/played")
        )
        XCTAssertTrue(
            playedWhileCancellationIsBlocked.items.contains { $0.id == prepared.episodeID },
            "the played list must expose the durable tap while cleanup remains blocked"
        )
        XCTAssertEqual(try prepared.store.job(id: prepared.job.id)?.stage, .cancelled)
        await executor.release()

        let response = await markPlayed.value
        XCTAssertEqual(response.statusCode, 204)
        for _ in 0..<200 {
            if try prepared.store.job(id: prepared.job.id) == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let staleWriteSucceeded = await executor.didPersistAfterCancellation()
        XCTAssertEqual(staleWriteSucceeded, false)
        XCTAssertNil(try prepared.store.job(id: prepared.job.id))
        XCTAssertTrue(try prepared.store.classificationEvidence(episodeID: prepared.episodeID).isEmpty)
        do {
            _ = try await pipeline.value
            XCTFail("Expected cancelled pipeline stage")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testBackendStartupReconcilesInterruptedPlayedCleanup() async throws {
        let harness = try makeHarness()
        let prepared = try await prepareClassifyingEpisode(harness, guid: "played-cleanup-restart")
        try harness.database.withTransaction {
            try harness.database.execute(
                "UPDATE ad_removal_jobs SET stage = 'cancelled', updated_at = 2_000 WHERE episode_id = ?",
                [.int(prepared.episodeID)]
            )
            try harness.database.execute(
                """
                INSERT INTO episode_state (episode_id, played_at, updated_at) VALUES (?, 2_000, 2_000)
                ON CONFLICT (episode_id) DO UPDATE SET played_at = 2_000, updated_at = 2_000
                """,
                [.int(prepared.episodeID)]
            )
        }

        let restartedBackend = PodsBackend(
            database: harness.database,
            feedFetcher: harness.fetcher,
            directorySearcher: DisabledPodcastDirectorySearcher(),
            adRemovalArtifactStore: harness.adRemovalArtifactStore,
            recoverInterruptedPlayedCleanup: true
        )

        let played = try decode(
            Page<EpisodeItem>.self,
            from: try await call(restartedBackend, "GET", "/api/played")
        )
        XCTAssertTrue(played.items.contains { $0.id == prepared.episodeID })
        XCTAssertNil(
            try prepared.store.job(episodeID: prepared.episodeID),
            "startup must finish cleanup that was interrupted after the authoritative tap committed"
        )
    }

    func testFeatureCleanupWaitsForPipelineTerminationBeforeDeletingLateWrites() async throws {
        let harness = try makeHarness()
        let prepared = try await prepareClassifyingEpisode(harness, guid: "pipeline-full-cleanup")
        let executor = CancellationHoldingClassificationExecutor(store: prepared.store)
        let coordinator = AdRemovalCoordinator(store: prepared.store, executor: executor)
        harness.backend.setAdRemovalCancellationRequestHandler { scope in
            await coordinator.cancel(scope)
        }
        let pipeline = Task { try await coordinator.runNextStage() }
        await executor.waitUntilEntered()

        let completion = CompletionProbe()
        let cleanup = Task {
            let response = try await self.call(
                harness.backend,
                "POST",
                "/api/ad-removal/cleanup",
                json: ["confirm": "DELETE_AD_REMOVAL_DATA"]
            )
            await completion.markCompleted()
            return response
        }
        await executor.waitUntilCancellationObserved()

        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease, "cleanup returned before pipeline termination")
        XCTAssertNotNil(try prepared.store.job(id: prepared.job.id))
        await executor.release()

        let response = try await cleanup.value
        XCTAssertEqual(response.statusCode, 200)
        let lateWriteSucceeded = await executor.didPersistAfterCancellation()
        XCTAssertEqual(lateWriteSucceeded, true)
        XCTAssertNil(try prepared.store.job(id: prepared.job.id))
        XCTAssertTrue(try prepared.store.classificationEvidence(episodeID: prepared.episodeID).isEmpty)
        do {
            _ = try await pipeline.value
            XCTFail("Expected cancelled pipeline stage")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testFeatureDisableWaitsForPipelineTerminationBeforeResponding() async throws {
        let harness = try makeHarness()
        let prepared = try await prepareClassifyingEpisode(harness, guid: "pipeline-disable")
        let executor = CancellationHoldingClassificationExecutor(store: prepared.store)
        let coordinator = AdRemovalCoordinator(store: prepared.store, executor: executor)
        harness.backend.setAdRemovalCancellationRequestHandler { scope in
            await coordinator.cancel(scope)
        }
        let pipeline = Task { try await coordinator.runNextStage() }
        await executor.waitUntilEntered()

        let completion = CompletionProbe()
        let disable = Task {
            let response = await harness.backend.handle(HTTPRequest(
                method: "POST",
                target: "/api/ad-removal/disable"
            ))
            await completion.markCompleted()
            return response
        }
        await executor.waitUntilCancellationObserved()

        let completedBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(completedBeforeRelease, "disable returned before pipeline termination")
        XCTAssertEqual(
            try harness.database.query(
                "SELECT value FROM settings WHERE key = 'ad_removal_enabled'",
                map: { sqliteString($0, 0) }
            ).first,
            "false"
        )
        await executor.release()

        let response = await disable.value
        XCTAssertEqual(response.statusCode, 200)
        do {
            _ = try await pipeline.value
            XCTFail("Expected cancelled pipeline stage")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testFeatureCleanupDisablesShowNotesBeforeAwaitingRuntimeShutdown() async throws {
        let harness = try makeHarness()
        try harness.database.execute(
            """
            INSERT INTO settings (key, value) VALUES ('ad_removal_enabled', 'true')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        let shutdownObserved = expectation(description: "runtime shutdown observes closed generation gate")
        harness.backend.setAdRemovalStopRequestHandler {
            let enabled = try? harness.database.query(
                "SELECT value FROM settings WHERE key = 'ad_removal_enabled'"
            ) { sqliteString($0, 0) }.first
            XCTAssertEqual(enabled, "false")
            shutdownObserved.fulfill()
        }

        let response = try await call(
            harness.backend,
            "POST",
            "/api/ad-removal/cleanup",
            json: ["confirm": "DELETE_AD_REMOVAL_DATA"]
        )

        await fulfillment(of: [shutdownObserved], timeout: 1)
        XCTAssertEqual(response.statusCode, 200)
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
        for _ in 0..<4 {
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

    func testEpisodeDetailExposesOnlyEnabledAdMarkers() async throws {
        let harness = try makeHarness()
        let prepared = try await prepareClassifyingEpisode(harness, guid: "chapter-ad-markers")
        try prepared.store.replaceTranscriptSegments(episodeID: prepared.episodeID, segments: [
            AdTranscriptSegment(id: "segment-1", index: 0, language: "en", startTime: 42.5, endTime: 55, text: "Sponsor"),
            AdTranscriptSegment(id: "segment-2", index: 1, language: "en", startTime: 55, endTime: 68, text: "Offer"),
            AdTranscriptSegment(id: "segment-3", index: 2, language: "en", startTime: 90, endTime: 100, text: "Correction"),
            AdTranscriptSegment(id: "segment-4", index: 3, language: "en", startTime: 100, endTime: 110, text: "Editorial")
        ])
        try prepared.store.replaceSkipRanges(episodeID: prepared.episodeID, ranges: [
            AdSkipRange(
                id: "enabled-ad",
                startSegmentID: "segment-1",
                endSegmentID: "segment-2",
                startTime: 42.5,
                endTime: 68,
                confidence: 0.98,
                reason: "sponsor read",
                classifierVersion: "apple-foundation-test",
                promptVersion: "prompt-v1",
                createdAt: 1_000,
                disabled: false
            ),
            AdSkipRange(
                id: "disabled-ad",
                startSegmentID: "segment-3",
                endSegmentID: "segment-4",
                startTime: 90,
                endTime: 110,
                confidence: 0.95,
                reason: "corrected sponsor read",
                classifierVersion: "apple-foundation-test",
                promptVersion: "prompt-v1",
                createdAt: 1_000,
                disabled: true
            )
        ])
        _ = try prepared.store.transition(jobID: prepared.job.id, to: .ready)

        let detail = try decode(EpisodeDetail.self, from: try await call(
            harness.backend,
            "GET",
            "/api/episodes/\(prepared.episodeID)"
        ))
        XCTAssertEqual(detail.ad_markers, [EpisodeAdMarker(id: "enabled-ad", start_time: 42.5)])
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
        XCTAssertEqual(settings.model_repository, "deepseek-v4-pro")
        XCTAssertEqual(settings.model_revision, "api")
        XCTAssertEqual(settings.model_total_bytes, 0)
        XCTAssertEqual(settings.model_download_state, "ready")
        XCTAssertTrue(settings.cloud_classifier_configured)
        XCTAssertTrue(settings.classifier_available)
        XCTAssertNil(settings.classifier_unavailable_reason)
        XCTAssertEqual(settings.minimum_free_bytes, 10_000_000_000, "settings must report the explicit 10 GB storage-policy minimum")
        XCTAssertEqual(settings.deepseek_usage, .empty)
        XCTAssertTrue(settings.deepseek_usage.telemetry_complete)

        let enabled = try await call(
            harness.backend,
            "POST",
            "/api/ad-removal/enable",
            json: ["confirmed_bytes": 0]
        )
        XCTAssertEqual(enabled.statusCode, 202)
        settings = try decode(AdRemovalSettingsPayload.self, from: enabled)
        XCTAssertTrue(settings.enabled)
        XCTAssertNotNil(settings.enrollment_cutoff)
        XCTAssertEqual(settings.model_download_state, "ready")
        XCTAssertEqual(settings.model_revision, "api")
        XCTAssertTrue(settings.classifier_available)

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

    func testAdRemovalSettingsReportsDeepSeekUsageMetrics() async throws {
        let harness = try makeHarness()
        try harness.database.execute(
            "INSERT INTO podcasts (feed_url, title, created_at) VALUES (?, ?, ?)",
            [.text("https://example.com/usage"), .text("Usage Show"), .int(1)]
        )
        let podcastID = harness.database.lastInsertRowID()
        try harness.database.execute(
            """
            INSERT INTO episodes (podcast_id, guid, title, audio_url, duration_secs, published_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .int(podcastID),
                .text("usage-1"),
                .text("Usage 1"),
                .text("https://example.com/usage-1.mp3"),
                .int(3_600),
                .int(100)
            ]
        )
        let episodeID = harness.database.lastInsertRowID()
        let store = DeepSeekUsageStore(database: harness.database)
        let offPeak = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-17T12:00:00Z"))
        try store.record(
            episodeID: episodeID,
            requestKind: .adDetection,
            model: "deepseek-v4-pro",
            usage: DeepSeekAPIUsage(inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0),
            createdAt: offPeak
        )
        try store.record(
            episodeID: episodeID,
            requestKind: .showNotes,
            model: "deepseek-v4-pro",
            usage: DeepSeekAPIUsage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 1_000_000),
            createdAt: offPeak
        )

        let settings = try decode(AdRemovalSettingsPayload.self, from: try await call(
            harness.backend,
            "GET",
            "/api/ad-removal/settings"
        ))
        XCTAssertEqual(settings.deepseek_usage.total_cost_usd, 2.64, accuracy: 0.0000000001)
        XCTAssertEqual(
            try XCTUnwrap(settings.deepseek_usage.average_cost_per_episode_usd),
            2.64,
            accuracy: 0.0000000001
        )
        XCTAssertEqual(
            try XCTUnwrap(settings.deepseek_usage.average_cost_per_podcast_minute_usd),
            0.044,
            accuracy: 0.0000000001
        )
        XCTAssertEqual(settings.deepseek_usage.ad_detection_cost_usd, 0.66, accuracy: 0.0000000001)
        XCTAssertEqual(settings.deepseek_usage.show_notes_cost_usd, 1.98, accuracy: 0.0000000001)
        XCTAssertTrue(settings.deepseek_usage.telemetry_complete)
    }

    func testAdRemovalSettingsAndEnableRequireDeepSeekAPIKey() async throws {
        let harness = try makeHarness(deepSeekAPIKey: nil)
        let settings = try decode(AdRemovalSettingsPayload.self, from: try await call(
            harness.backend,
            "GET",
            "/api/ad-removal/settings"
        ))
        XCTAssertFalse(settings.classifier_available)
        XCTAssertFalse(settings.cloud_classifier_configured)
        XCTAssertEqual(settings.model_download_state, "api_key_required")
        XCTAssertEqual(settings.classifier_unavailable_reason, "api_key_required")

        let enabled = try await call(
            harness.backend,
            "POST",
            "/api/ad-removal/enable",
            json: ["confirmed_bytes": 0]
        )
        XCTAssertEqual(enabled.statusCode, 422)
    }

    func testAdRemovalPrepareRejectsWhenDeepSeekAPIKeyIsMissing() async throws {
        let harness = try makeHarness(deepSeekAPIKey: nil)
        let feedURL = "https://feeds.example/unavailable-prepare.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(
            show: "Unavailable",
            items: [("Episode", "prep-1", "https://h.example/prep.mp3", Self.d1)]
        ).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])
        let episodeID = try XCTUnwrap(harness.database.scalarInt64(
            "SELECT id FROM episodes WHERE guid = 'prep-1'"
        ))

        let prepared = try await call(
            harness.backend,
            "POST",
            "/api/episodes/\(episodeID)/ad-removal/prepare"
        )
        XCTAssertEqual(prepared.statusCode, 422)
        XCTAssertNil(try AdRemovalJobStore(database: harness.database).job(episodeID: episodeID))
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
        let pipelineRequested = expectation(description: "pipeline requested")
        pipelineRequested.expectedFulfillmentCount = 3
        let runtimeStopped = expectation(description: "runtime stopped")
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
            json: ["confirmed_bytes": 0]
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

        await fulfillment(of: [pipelineRequested, runtimeStopped], timeout: 1)
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
            adRemovalDiagnostics: diagnostics,
            deepSeekCredentialStore: StubDeepSeekCredentialStore()
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
        XCTAssertEqual(settings.model_download_state, "ready")
        XCTAssertEqual(settings.model_downloaded_bytes, 0)
        XCTAssertEqual(settings.model_repository, "deepseek-v4-pro")
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
        let queued = try store.enqueue(episodeID: episode.id)
        let job = try store.transition(jobID: queued.id, to: .downloading)
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
        for _ in 0..<200 {
            let jobRemoved = try store.job(episodeID: episode.id) == nil
            let cleanupDrained = try harness.database.scalarInt64(
                "SELECT COUNT(*) FROM ad_artifact_cleanup"
            ) == 0
            if jobRemoved && cleanupDrained { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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

    func testNativeCoordinatorRefreshesEveryTimeTheAppEntersForeground() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/a.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(show: "Alpha", items: [
            ("Episode", "g1", "https://h.example/1.mp3", Self.d1)
        ]).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])

        let coordinator = FeedRefreshCoordinator(backend: harness.backend)
        _ = await coordinator.refreshWhenForegrounded()
        _ = await coordinator.refreshWhenForegrounded()

        XCTAssertEqual(harness.fetcher.requestedURLs.count, 3)
        let status = try decode(RefreshStatus.self, from: try await call(harness.backend, "GET", "/api/refresh-status"))
        XCTAssertEqual(status.last_source, "foreground")
        XCTAssertNotNil(status.last_success_at)
    }

    func testDeferredLaunchActivationRefreshesFeedsAndPersistsCompletionThroughLoopbackAPI() async throws {
        let harness = try makeHarness()
        let feedURL = "https://feeds.example/launch.xml"
        harness.fetcher.responses[feedURL] = Data(Self.rss(show: "Launch", items: [
            ("Episode", "launch-1", "https://h.example/launch-1.mp3", Self.d1)
        ]).utf8)
        _ = try await call(harness.backend, "POST", "/api/shows", json: ["feed_url": feedURL])

        let lifecycle = await MainActor.run { ForegroundFeedRefreshLifecycle() }
        let coordinator = FeedRefreshCoordinator(backend: harness.backend)
        harness.backend.setRefreshRequestHandler { source in
            await coordinator.refreshNow(source: source)
        }

        // This is the app-launch ordering that previously dropped refreshes:
        // UIKit reports activation before the backend coordinator is installed.
        await MainActor.run {
            lifecycle.applicationDidBecomeActive()
            lifecycle.install { await coordinator.refreshWhenForegrounded() }
        }

        let server = PodsLocalServer(backend: harness.backend, staticAssets: nil, port: 18183)
        try server.start()
        defer { server.stop() }

        let statusURL = URL(string: "http://127.0.0.1:18183/api/refresh-status")!
        var status = RefreshStatus.empty
        for _ in 0..<100 {
            let (data, response) = try await URLSession.shared.data(from: statusURL)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            status = try JSONDecoder().decode(RefreshStatus.self, from: data)
            if status.last_success_at != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(harness.fetcher.requestedURLs, [feedURL, feedURL])
        XCTAssertEqual(status.last_source, "foreground")
        XCTAssertNotNil(status.last_attempt_at)
        XCTAssertNotNil(status.last_success_at)
        XCTAssertEqual(status.last_refreshed, 1)
        XCTAssertEqual(status.last_errors, 0)
    }

    func testLifecycleCoalescesDuplicateColdStartActivationIntoOneRefresh() async throws {
        let lifecycle = await MainActor.run { ForegroundFeedRefreshLifecycle() }
        let handler = ControlledRefreshHandler()
        await MainActor.run {
            lifecycle.install { await handler.perform() }
            lifecycle.applicationDidBecomeActive()
        }
        await handler.waitUntilStarted()
        await MainActor.run {
            lifecycle.applicationDidBecomeActive()
        }
        await handler.release()
        try await Task.sleep(nanoseconds: 50_000_000)

        let callCount = await handler.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testRefreshStatusReportsAnActiveRefreshUntilItPersistsCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodsRefreshStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try PodsDatabase(url: directory.appendingPathComponent("test.sqlite"))
        let feedURL = "https://feeds.example/status.xml"
        try database.execute(
            "INSERT INTO podcasts (feed_url, created_at) VALUES (?, 1)",
            [.text(feedURL)]
        )
        let fetcher = BlockingFeedFetcher(responseData: Data(Self.rss(show: "Status", items: []).utf8))
        let backend = PodsBackend(
            database: database,
            feedFetcher: fetcher,
            directorySearcher: DisabledPodcastDirectorySearcher()
        )

        let refresh = Task { await backend.performRefresh(source: .foreground) }
        await fetcher.waitUntilStarted()
        XCTAssertTrue(backend.refreshStatus().is_refreshing)

        await fetcher.release()
        _ = await refresh.value
        XCTAssertFalse(backend.refreshStatus().is_refreshing)
    }

    func testLoopbackRefreshStatusReportsAnActiveRefreshUntilCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodsLoopbackRefreshStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try PodsDatabase(url: directory.appendingPathComponent("test.sqlite"))
        let feedURL = "https://feeds.example/loopback-status.xml"
        try database.execute(
            "INSERT INTO podcasts (feed_url, created_at) VALUES (?, 1)",
            [.text(feedURL)]
        )
        let fetcher = BlockingFeedFetcher(responseData: Data(Self.rss(show: "Loopback", items: []).utf8))
        let backend = PodsBackend(
            database: database,
            feedFetcher: fetcher,
            directorySearcher: DisabledPodcastDirectorySearcher()
        )
        let server = PodsLocalServer(backend: backend, staticAssets: nil, port: 18184)
        try server.start()
        defer { server.stop() }

        let refresh = Task { await backend.performRefresh(source: .foreground) }
        await fetcher.waitUntilStarted()

        let statusURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18184/api/refresh-status"))
        let (activeData, activeResponse) = try await URLSession.shared.data(from: statusURL)
        XCTAssertEqual((activeResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(try JSONDecoder().decode(RefreshStatus.self, from: activeData).is_refreshing)

        await fetcher.release()
        _ = await refresh.value

        let (completedData, completedResponse) = try await URLSession.shared.data(from: statusURL)
        XCTAssertEqual((completedResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(try JSONDecoder().decode(RefreshStatus.self, from: completedData).is_refreshing)
    }

    func testBackendStartupClosesAnInterruptedRefreshAttemptForRetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodsInterruptedRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try PodsDatabase(url: directory.appendingPathComponent("test.sqlite"))
        try database.execute(
            """
            INSERT INTO feed_refresh_state (id, last_attempt_at, last_source, last_refreshed, last_errors)
            VALUES (1, 100, 'foreground', 0, 0)
            """
        )
        try database.execute(
            """
            INSERT INTO feed_refresh_attempts (source, started_at, outcome)
            VALUES ('foreground', 100, 'running')
            """
        )

        let backend = PodsBackend(
            database: database,
            feedFetcher: MockFeedFetcher(),
            directorySearcher: DisabledPodcastDirectorySearcher()
        )

        let recovered = try database.query(
            "SELECT finished_at, refreshed, errors, outcome FROM feed_refresh_attempts"
        ) { statement in
            (
                sqliteOptionalInt64(statement, 0),
                sqliteOptionalInt64(statement, 1),
                sqliteOptionalInt64(statement, 2),
                sqliteString(statement, 3)
            )
        }
        XCTAssertEqual(recovered.count, 1)
        XCTAssertNotNil(recovered[0].0)
        XCTAssertEqual(recovered[0].1, 0)
        XCTAssertEqual(recovered[0].2, 1)
        XCTAssertEqual(recovered[0].3, "interrupted")

        let status = backend.refreshStatus()
        XCTAssertEqual(status.last_source, "foreground")
        XCTAssertEqual(status.last_errors, 1)
    }

    func testFeedFetcherUsesBoundedTimeoutForEveryPublisherRequest() async throws {
        FeedRequestCaptureURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedRequestCaptureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let fetcher = URLSessionFeedFetcher(session: session, requestTimeout: 12)

        _ = try await fetcher.response(
            for: try XCTUnwrap(URL(string: "https://feeds.example/slow.xml")),
            validators: FeedValidators()
        )

        XCTAssertEqual(FeedRequestCaptureURLProtocol.request()?.timeoutInterval, 12)
    }

    func testFeedFetcherRetriesHTTPFeedOverHTTPSWhenTheFirstFetchFails() async throws {
        SchemeRetryURLProtocol.reset(failSchemes: ["http"])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SchemeRetryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let fetcher = URLSessionFeedFetcher(session: session, requestTimeout: 12)

        let response = try await fetcher.response(
            for: try XCTUnwrap(URL(string: "http://retry.example/feed.xml")),
            validators: FeedValidators()
        )

        guard case .data(let data, _) = response else {
            return XCTFail("expected feed data after the https retry")
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "<rss/>")
        XCTAssertEqual(
            SchemeRetryURLProtocol.requestedURLs().map(\.absoluteString),
            ["http://retry.example/feed.xml", "https://retry.example/feed.xml"]
        )
    }

    func testFeedFetcherDoesNotRetryWhenTheListedFeedIsAlreadyHTTPS() async throws {
        SchemeRetryURLProtocol.reset(failSchemes: ["https"])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SchemeRetryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let fetcher = URLSessionFeedFetcher(session: session, requestTimeout: 12)

        do {
            _ = try await fetcher.response(
                for: try XCTUnwrap(URL(string: "https://retry.example/feed.xml")),
                validators: FeedValidators()
            )
            XCTFail("expected the https failure to propagate")
        } catch {
            // Expected: https failures are not retried against themselves.
        }
        XCTAssertEqual(
            SchemeRetryURLProtocol.requestedURLs().map(\.absoluteString),
            ["https://retry.example/feed.xml"]
        )
    }

    func testFeedFetcherDoesNotRetryWhenTheHTTPFeedSucceeds() async throws {
        SchemeRetryURLProtocol.reset(failSchemes: [])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SchemeRetryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let fetcher = URLSessionFeedFetcher(session: session, requestTimeout: 12)

        _ = try await fetcher.response(
            for: try XCTUnwrap(URL(string: "http://retry.example/feed.xml")),
            validators: FeedValidators()
        )

        XCTAssertEqual(
            SchemeRetryURLProtocol.requestedURLs().map(\.absoluteString),
            ["http://retry.example/feed.xml"]
        )
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
            last_errors: 0,
            is_refreshing: false
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
            last_errors: 1,
            is_refreshing: false
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
        let beforeExpiry = try XCTUnwrap(formatter.date(from: "2026-08-17T23:59:58Z"))
        let afterExpiry = try XCTUnwrap(formatter.date(from: "2026-08-18T00:00:00Z"))

        XCTAssertEqual(PodsTemporaryDebugLog.expiryISO8601, "2026-08-17T23:59:59Z")
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
        XCTAssertEqual(playing[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.5)
        XCTAssertEqual(
            playing[MPNowPlayingInfoPropertyMediaType] as? NSNumber,
            NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue)
        )
        XCTAssertEqual(playing[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, false)

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

    /// Fakes the MediaPlayer command-registration boundary (skip + Tesla scrubber).
    private final class FakeRemoteForwardCommandRegistrar: RemoteForwardCommandRegistering {
        private(set) var nextTrackHandler: (() -> MPRemoteCommandHandlerStatus)?
        private(set) var previousTrackHandler: (() -> MPRemoteCommandHandlerStatus)?
        private(set) var skipForwardHandler: ((TimeInterval) -> MPRemoteCommandHandlerStatus)?
        private(set) var skipBackwardHandler: ((TimeInterval) -> MPRemoteCommandHandlerStatus)?
        private(set) var skipForwardPreferredIntervals: [NSNumber]?
        private(set) var skipBackwardPreferredIntervals: [NSNumber]?
        private(set) var seekHandler: ((TimeInterval) -> MPRemoteCommandHandlerStatus)?

        func registerNextTrackCommand(handler: @escaping () -> MPRemoteCommandHandlerStatus) {
            nextTrackHandler = handler
        }

        func registerPreviousTrackCommand(handler: @escaping () -> MPRemoteCommandHandlerStatus) {
            previousTrackHandler = handler
        }

        func registerSkipForwardCommand(
            preferredIntervals: [NSNumber],
            handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
        ) {
            skipForwardPreferredIntervals = preferredIntervals
            skipForwardHandler = handler
        }

        func registerSkipBackwardCommand(
            preferredIntervals: [NSNumber],
            handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
        ) {
            skipBackwardPreferredIntervals = preferredIntervals
            skipBackwardHandler = handler
        }

        func registerChangePlaybackPositionCommand(
            handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
        ) {
            seekHandler = handler
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

    func testRemoteCommandBindingPreviousTrackPassesNegativeThirtySecondInterval() throws {
        let registrar = FakeRemoteForwardCommandRegistrar()
        var capturedIntervals: [TimeInterval] = []

        RemoteForwardCommandBinding.install(
            on: registrar,
            forwardSkip: { interval in
                capturedIntervals.append(interval)
                return .success
            }
        )

        let status = try XCTUnwrap(registrar.previousTrackHandler)()

        XCTAssertEqual(status, .success)
        XCTAssertEqual(capturedIntervals, [-30])
    }

    func testRemoteCommandBindingSkipBackwardNegatesEventInterval() throws {
        let registrar = FakeRemoteForwardCommandRegistrar()
        var capturedIntervals: [TimeInterval] = []

        RemoteForwardCommandBinding.install(
            on: registrar,
            forwardSkip: { interval in
                capturedIntervals.append(interval)
                return .success
            }
        )

        XCTAssertEqual(registrar.skipBackwardPreferredIntervals, [NSNumber(value: 30)])
        let status = try XCTUnwrap(registrar.skipBackwardHandler)(30)

        XCTAssertEqual(status, .success)
        XCTAssertEqual(capturedIntervals, [-30])
    }

    func testRemoteSeekBindingPassesScrubberPosition() throws {
        let registrar = FakeRemoteForwardCommandRegistrar()
        var capturedPositions: [TimeInterval] = []

        RemoteForwardCommandBinding.installSeek(
            on: registrar,
            seekTo: { position in
                capturedPositions.append(position)
                return .success
            }
        )

        let status = try XCTUnwrap(registrar.seekHandler)(123.5)

        XCTAssertEqual(status, .success)
        XCTAssertEqual(capturedPositions, [123.5])
    }

    func testRemotePlaybackPositionHandlerSeeksAndClamps() {
        var seekTargets: [Double] = []

        let ok = RemotePlaybackPositionHandler.handle(
            hasActiveContent: true,
            position: 90,
            knownDuration: 1_000,
            absoluteSeek: { seekTargets.append($0) }
        )
        XCTAssertEqual(ok, .success)
        XCTAssertEqual(seekTargets, [90])

        seekTargets = []
        let clamped = RemotePlaybackPositionHandler.handle(
            hasActiveContent: true,
            position: 2_000,
            knownDuration: 600,
            absoluteSeek: { seekTargets.append($0) }
        )
        XCTAssertEqual(clamped, .success)
        XCTAssertEqual(seekTargets, [600])

        seekTargets = []
        let empty = RemotePlaybackPositionHandler.handle(
            hasActiveContent: false,
            position: 90,
            knownDuration: 1_000,
            absoluteSeek: { seekTargets.append($0) }
        )
        XCTAssertEqual(empty, .noActionableNowPlayingItem)
        XCTAssertEqual(seekTargets, [])
    }

    func testRemoteForwardSkipSeeksBackwardForNegativeInterval() {
        var seekTargets: [Double] = []

        let status = RemoteForwardSkipHandler.handle(
            hasActiveContent: true,
            currentPosition: 40,
            knownDuration: 1_000,
            interval: -30,
            absoluteSeek: { seekTargets.append($0) }
        )

        XCTAssertEqual(status, .success)
        XCTAssertEqual(seekTargets, [10])
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
