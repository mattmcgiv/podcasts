import XCTest
import MediaPlayer
import WebKit
@testable import Pods

final class PodsBackendTests: XCTestCase {
    private final class MockFeedFetcher: FeedFetching {
        var responses: [String: Data] = [:]

        func data(for url: URL) async throws -> Data {
            guard let data = responses[url.absoluteString] else {
                throw PodsBackendError.upstream("missing mock feed")
            }
            return data
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
    }

    private func makeHarness(directorySearcher: PodcastDirectorySearching? = nil) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodsBackendTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try PodsDatabase(url: directory.appendingPathComponent("test.sqlite"))
        let fetcher = MockFeedFetcher()
        let backend = PodsBackend(
            database: database,
            feedFetcher: fetcher,
            directorySearcher: directorySearcher ?? DisabledPodcastDirectorySearcher()
        )
        return Harness(backend: backend, fetcher: fetcher, directory: directory)
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
        XCTAssertTrue(String(data: htmlData, encoding: .utf8)?.contains("./assets/app.js") == true)

        let assetURL = URL(string: "http://127.0.0.1:18181/assets/app.js")!
        let (_, assetResponse) = try await URLSession.shared.data(from: assetURL)
        XCTAssertEqual((assetResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type"), "text/javascript; charset=utf-8")

        let apiURL = URL(string: "http://127.0.0.1:18181/api/recent")!
        let (apiData, apiResponse) = try await URLSession.shared.data(from: apiURL)
        XCTAssertEqual((apiResponse as? HTTPURLResponse)?.statusCode, 200)
        let page = try JSONDecoder().decode(Page<EpisodeItem>.self, from: apiData)
        XCTAssertTrue(page.items.isEmpty)
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

    private let localRootURL = URL(string: "http://127.0.0.1:18180/")!

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
}
