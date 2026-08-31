import Foundation
import SQLite3

struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.target = target
        self.headers = headers
        self.body = body
    }

    var components: URLComponents {
        URLComponents(string: target.hasPrefix("http") ? target : "http://localhost\(target)")
            ?? URLComponents()
    }

    var path: String {
        components.path
    }

    func query(_ name: String) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }

    var bodyString: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    static func json<T: Encodable>(_ value: T, statusCode: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: data
        )
    }

    static func text(_ value: String, statusCode: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: ["content-type": contentType],
            body: Data(value.utf8)
        )
    }

    static func noContent() -> HTTPResponse {
        HTTPResponse(statusCode: 204, headers: [:], body: Data())
    }

    static func error(_ error: PodsBackendError) -> HTTPResponse {
        HTTPResponse.json(["error": error.description], statusCode: error.statusCode)
    }
}

protocol PlaybackProgressRecording: AnyObject {
    func recordPlaybackProgress(episodeID: Int64, seconds: Double)
}

final class PodsBackend: PlaybackProgressRecording {
    private let database: PodsDatabase
    private let feedFetcher: FeedFetching
    private let directorySearcher: PodcastDirectorySearching
    private let adRemovalFileCleanup: AdRemovalFileCleanup?
    private let adRemovalArtifactStore: AdRemovalArtifactStore?
    private let adRemovalDiagnostics: AdRemovalDiagnostics?
    private let onDeviceModelAvailability: AppleOnDeviceModelAvailabilityReading
    private let episodeShowNotesStore: EpisodeShowNotesStore
    private let episodeShowNotesService: EpisodeShowNotesService?
    private var refreshRequestHandler: ((RefreshSource) async -> RefreshResult)?
    private var adRemovalRunRequestHandler: (() async -> Void)?
    private var adRemovalModelDownloadRequestHandler: ((AdModelManifest) async -> Void)?
    private var adRemovalStopRequestHandler: (() async -> Void)?
    private var adRemovalCancellationRequestHandler: ((AdRemovalPipelineCancellationScope) async -> Void)?

    init(
        database: PodsDatabase,
        feedFetcher: FeedFetching = URLSessionFeedFetcher(),
        directorySearcher: PodcastDirectorySearching = PodcastIndexClient.fromBundle() ?? DisabledPodcastDirectorySearcher(),
        adRemovalArtifactStore: AdRemovalArtifactStore? = nil,
        adRemovalDiagnostics: AdRemovalDiagnostics? = nil,
        onDeviceModelAvailability: AppleOnDeviceModelAvailabilityReading = SystemLanguageModelAvailabilityReader(),
        episodeShowNotesService: EpisodeShowNotesService? = nil,
        recoverInterruptedPlayedCleanup: Bool = false
    ) {
        self.database = database
        self.feedFetcher = feedFetcher
        self.directorySearcher = directorySearcher
        self.adRemovalArtifactStore = adRemovalArtifactStore
        self.adRemovalDiagnostics = adRemovalDiagnostics
        self.onDeviceModelAvailability = onDeviceModelAvailability
        self.episodeShowNotesStore = EpisodeShowNotesStore(database: database)
        self.episodeShowNotesService = episodeShowNotesService
        self.adRemovalFileCleanup = adRemovalArtifactStore.map {
            AdRemovalFileCleanup(database: database, artifactStore: $0)
        }
        recoverInterruptedRefreshAttempts()
        if recoverInterruptedPlayedCleanup {
            recoverInterruptedPlayedCleanupAfterColdStart()
        }
    }

    func recordPlaybackProgress(episodeID: Int64, seconds: Double) {
        do {
            try setPosition(id: episodeID, seconds: seconds)
        } catch {
            PodsLog("Pods playback progress record failed episodeID=\(episodeID) seconds=\(seconds): \(error)")
        }
    }

    /// Installed by the app lifecycle after the native coordinator exists.
    /// Tests and standalone backend use retain a direct, audited fallback.
    func setRefreshRequestHandler(_ handler: @escaping (RefreshSource) async -> RefreshResult) {
        refreshRequestHandler = handler
    }

    func setAdRemovalRunRequestHandler(_ handler: @escaping () async -> Void) {
        adRemovalRunRequestHandler = handler
    }

    func setAdRemovalModelDownloadRequestHandler(
        _ handler: @escaping (AdModelManifest) async -> Void
    ) {
        adRemovalModelDownloadRequestHandler = handler
    }

    func setAdRemovalStopRequestHandler(_ handler: @escaping () async -> Void) {
        adRemovalStopRequestHandler = handler
    }

    func setAdRemovalCancellationRequestHandler(
        _ handler: @escaping (AdRemovalPipelineCancellationScope) async -> Void
    ) {
        adRemovalCancellationRequestHandler = handler
    }

    func refreshStatus() -> RefreshStatus {
        do {
            let isRefreshing = try database.scalarInt64(
                "SELECT 1 FROM feed_refresh_attempts WHERE outcome = 'running' LIMIT 1"
            ) != nil
            return try database.query(
                "SELECT last_attempt_at, last_success_at, last_source, last_refreshed, last_errors FROM feed_refresh_state WHERE id = 1"
            ) { statement in
                RefreshStatus(
                    last_attempt_at: sqliteOptionalInt64(statement, 0),
                    last_success_at: sqliteOptionalInt64(statement, 1),
                    last_source: sqliteOptionalString(statement, 2),
                    last_refreshed: Int(sqlite3_column_int64(statement, 3)),
                    last_errors: Int(sqlite3_column_int64(statement, 4)),
                    is_refreshing: isRefreshing
                )
            }.first ?? .empty
        } catch {
            PodsLog("Pods refresh status read failed: \(error)")
            return .empty
        }
    }

    func performRefresh(source: RefreshSource) async -> RefreshResult {
        let startedAt = nowUnix()
        let attemptID = recordRefreshAttempt(source: source, startedAt: startedAt)
        NotificationCenter.default.post(name: .podsFeedRefreshStateChanged, object: nil)
        let result = await refreshAll()
        let finishedAt = nowUnix()
        recordRefreshCompletion(
            source: source,
            startedAt: startedAt,
            finishedAt: finishedAt,
            result: result,
            attemptID: attemptID
        )
        PodsLog("Pods feed refresh source=\(source.rawValue) refreshed=\(result.refreshed) errors=\(result.errors)")
        NotificationCenter.default.post(name: .podsFeedRefreshStateChanged, object: nil)
        NotificationCenter.default.post(name: .podsFeedRefreshCompleted, object: nil)
        if (try? settingValues()["ad_removal_enabled"]) == "true",
           let adRemovalRunRequestHandler {
            Task { await adRemovalRunRequestHandler() }
        }
        return result
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        PodsDebugLog("Backend request method=\(request.method) target=\(request.target)")
        do {
            if request.method == "OPTIONS" {
                if Self.isShowNotesRequest(request), !Self.hasTrustedBrowserOrigin(request) {
                    throw PodsBackendError.forbidden("untrusted request origin")
                }
                return HTTPResponse.noContent()
            }
            guard request.path.hasPrefix("/api") else {
                throw PodsBackendError.notFound
            }
            return try await route(request)
        } catch let error as PodsBackendError {
            PodsDebugLog("Backend handled error method=\(request.method) target=\(request.target) status=\(error.statusCode) error=\(error.description)")
            return HTTPResponse.error(error)
        } catch {
            PodsDebugLog("Backend unexpected error method=\(request.method) target=\(request.target) error=\(error.localizedDescription)")
            return HTTPResponse.error(.upstream(error.localizedDescription))
        }
    }

    private func route(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.path
        let parts = path.split(separator: "/").map(String.init)

        if path == "/api/recent", request.method == "GET" {
            return .json(try recent(offset: request.offset))
        }
        if path == "/api/played", request.method == "GET" {
            return .json(try played(offset: request.offset))
        }
        if path == "/api/shows", request.method == "GET" {
            return .json(try shows())
        }
        if path == "/api/follows", request.method == "GET" {
            return .json(try follows())
        }
        if path == "/api/follows", request.method == "POST" {
            let body = try request.jsonObject()
            guard let name = body["name"] as? String else { throw PodsBackendError.invalid("name is required") }
            return .json(try await createFollow(name: name, aliases: body["aliases"] as? [String] ?? []), statusCode: 201)
        }
        if path == "/api/follow-candidates", request.method == "GET" {
            return .json(try followCandidates())
        }
        if parts.count == 3, parts[0] == "api", parts[1] == "follows", let id = Int64(parts[2]) {
            if request.method == "DELETE" { try deleteFollow(id: id); return .noContent() }
            if request.method == "POST" { return .json(try await refreshFollow(id: id)) }
        }
        if parts.count == 4, parts[0] == "api", parts[1] == "follow-candidates", let id = Int64(parts[2]) {
            if parts[3] == "accept", request.method == "POST" { try acceptFollowCandidate(id: id); return .noContent() }
            if parts[3] == "reject", request.method == "POST" { try rejectFollowCandidate(id: id); return .noContent() }
        }
        if path == "/api/shows", request.method == "POST" {
            let body = try request.jsonObject()
            guard let feedURL = body["feed_url"] as? String else {
                throw PodsBackendError.invalid("feed_url is required")
            }
            return .json(try await subscribe(feedURL: feedURL), statusCode: 201)
        }
        if parts.count == 3, parts[0] == "api", parts[1] == "shows", let id = Int64(parts[2]) {
            if request.method == "GET" {
                return .json(try showDetail(id: id, offset: request.offset))
            }
            if request.method == "DELETE" {
                try unsubscribe(id: id)
                return .noContent()
            }
        }
        if parts.count == 4,
           parts[0] == "api",
           parts[1] == "shows",
           parts[3] == "search",
           let id = Int64(parts[2]),
           request.method == "GET" {
            guard let query = request.query("q") else {
                throw PodsBackendError.invalid("q must not be empty")
            }
            return .json(try showSearch(id: id, query: query))
        }
        if parts.count == 3, parts[0] == "api", parts[1] == "episodes", let id = Int64(parts[2]), request.method == "GET" {
            return .json(try episodeDetail(id: id))
        }
        if parts.count == 4,
           parts[0] == "api",
           parts[1] == "episodes",
           parts[3] == "show-notes",
           let id = Int64(parts[2]),
           request.method == "POST" {
            guard Self.hasTrustedBrowserOrigin(request) else {
                throw PodsBackendError.forbidden("untrusted request origin")
            }
            guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
                throw PodsBackendError.invalid("application/json is required")
            }
            guard let episodeShowNotesService else { throw PodsBackendError.notFound }
            do {
                return .json(try await episodeShowNotesService.generate(episodeID: id))
            } catch EpisodeShowNotesError.noTranscript {
                throw PodsBackendError.conflict("episode transcript is not available")
            } catch EpisodeShowNotesError.notReady {
                throw PodsBackendError.conflict("episode ad removal is not ready")
            } catch EpisodeShowNotesError.noContent {
                throw PodsBackendError.conflict("episode has no content segments")
            } catch EpisodeShowNotesError.featureDisabled {
                throw PodsBackendError.conflict("ad removal is disabled")
            } catch EpisodeShowNotesError.sourceChanged {
                throw PodsBackendError.conflict("episode transcript changed; retry show notes")
            } catch EpisodeShowNotesError.transcriptTooLarge {
                throw PodsBackendError.conflict("episode transcript is too large for show notes")
            }
        }
        if parts.count == 4, parts[0] == "api", parts[1] == "episodes", parts[3] == "played", let id = Int64(parts[2]) {
            if request.method == "POST" {
                try await setPlayed(id: id)
                return .noContent()
            }
            if request.method == "DELETE" {
                try clearPlayed(id: id)
                return .noContent()
            }
        }
        if parts.count == 4, parts[0] == "api", parts[1] == "episodes", parts[3] == "position", let id = Int64(parts[2]), request.method == "PUT" {
            let body = try request.jsonObject()
            guard let seconds = body["seconds"] as? Double ?? (body["seconds"] as? NSNumber)?.doubleValue else {
                throw PodsBackendError.invalid("seconds must be >= 0")
            }
            try setPosition(id: id, seconds: seconds)
            return .noContent()
        }
        if parts.count == 5,
           parts[0] == "api",
           parts[1] == "episodes",
           parts[3] == "ad-removal",
           let id = Int64(parts[2]),
           request.method == "POST" {
            let job: AdRemovalJob
            if parts[4] == "prepare" {
                job = try prepareAdRemoval(id: id)
            } else if parts[4] == "retry" {
                job = try retryAdRemoval(id: id)
            } else {
                throw PodsBackendError.notFound
            }
            if let adRemovalRunRequestHandler {
                Task { await adRemovalRunRequestHandler() }
            }
            return .json(["stage": job.stage.rawValue], statusCode: 202)
        }
        if path == "/api/ad-removal/settings", request.method == "GET" {
            return .json(try adRemovalSettings())
        }
        if path == "/api/ad-removal/statuses", request.method == "GET" {
            return .json(try adRemovalStatuses(request: request))
        }
        if path == "/api/ad-removal/enable", request.method == "POST" {
            let body = try request.jsonObject()
            guard let confirmedBytes = (body["confirmed_bytes"] as? NSNumber)?.int64Value else {
                throw PodsBackendError.invalid("confirmed_bytes is required")
            }
            let settings = try enableAdRemoval(confirmedBytes: confirmedBytes)
            if let adRemovalRunRequestHandler { Task { await adRemovalRunRequestHandler() } }
            return .json(settings, statusCode: 202)
        }
        if path == "/api/ad-removal/disable", request.method == "POST" {
            try setSetting(key: "ad_removal_enabled", value: "false")
            await cancelAdRemovalPipeline(.all)
            await episodeShowNotesService?.cancelAll()
            try? adRemovalDiagnostics?.record(eventName: "feature_disabled", severity: .notice)
            return .json(try adRemovalSettings())
        }
        if parts.count == 5,
           parts[0] == "api",
           parts[1] == "ad-removal",
           parts[2] == "corrections",
           let podcastID = Int64(parts[3]),
           parts[4] == "reset",
           request.method == "POST" {
            try resetAdRemovalCorrections(podcastID: podcastID)
            return .json(try adRemovalSettings())
        }
        if path == "/api/ad-removal/diagnostics/export", request.method == "GET" {
            return try exportAdRemovalDiagnostics()
        }
        if path == "/api/ad-removal/diagnostics/clear", request.method == "POST" {
            guard let adRemovalDiagnostics else { throw PodsBackendError.notFound }
            try adRemovalDiagnostics.clear()
            return .noContent()
        }
        if path == "/api/ad-removal/cleanup", request.method == "POST" {
            let body = try request.jsonObject()
            guard body["confirm"] as? String == "DELETE_AD_REMOVAL_DATA" else {
                throw PodsBackendError.invalid("destructive cleanup confirmation does not match")
            }
            // Close the generation gate before any awaited shutdown work. The
            // cleanup endpoint ultimately removes this setting, but without
            // this write a concurrent request could start another transcript
            // upload after cancelAll drains and before metadata is deleted.
            try setSetting(key: "ad_removal_enabled", value: "false")
            await cancelAdRemovalPipeline(.all)
            await episodeShowNotesService?.cancelAll()
            try cleanupAdRemovalData()
            return .json(try adRemovalSettings())
        }
        if path == "/api/settings", request.method == "GET" {
            return .json(try settings())
        }
        if path == "/api/settings", request.method == "PUT" {
            let body = try request.jsonObject()
            guard let speed = body["speed"] as? Double ?? (body["speed"] as? NSNumber)?.doubleValue,
                  let autoplay = body["autoplay"] as? Bool else {
                throw PodsBackendError.invalid("invalid settings")
            }
            try saveSettings(SettingsPayload(speed: speed, autoplay: autoplay))
            return .noContent()
        }
        if path == "/api/refresh-status", request.method == "GET" {
            return .json(refreshStatus())
        }
        if path == "/api/refresh", request.method == "POST" {
            if let refreshRequestHandler {
                return .json(await refreshRequestHandler(.manual))
            }
            return .json(await performRefresh(source: .manual))
        }
        if path == "/api/next", request.method == "GET" {
            guard let afterRaw = request.query("after"), let after = Int64(afterRaw) else {
                throw PodsBackendError.invalid("after is required")
            }
            return .json(try next(after: after, context: request.query("context") ?? "recent"))
        }
        if path == "/api/search", request.method == "GET" {
            guard let query = request.query("q") else {
                throw PodsBackendError.invalid("q must not be empty")
            }
            return .json(try await search(query: query))
        }
        if path == "/api/opml", request.method == "GET" {
            return .text(try exportOPML(), contentType: "text/xml; charset=utf-8")
        }
        if path == "/api/opml", request.method == "POST" {
            return .json(try await importOPML(request.bodyString))
        }
        throw PodsBackendError.notFound
    }

    private static func isShowNotesRequest(_ request: HTTPRequest) -> Bool {
        let parts = request.path.split(separator: "/")
        return parts.count == 4
            && parts[0] == "api"
            && parts[1] == "episodes"
            && Int64(parts[2]) != nil
            && parts[3] == "show-notes"
    }

    private static func hasTrustedBrowserOrigin(_ request: HTTPRequest) -> Bool {
        request.headers["origin"] == "http://127.0.0.1:18180"
    }

    private func recent(offset: Int64) throws -> Page<EpisodeItem> {
        let rows = try database.query(
            "\(Self.episodeItemSelect) WHERE s.played_at IS NULL AND s.archived_at IS NULL AND \(Self.inListenPredicate) ORDER BY e.published_at DESC, e.id DESC LIMIT ? OFFSET ?",
            [.int(podsPageSize + 1), .int(offset)],
            map: Self.mapEpisodeItem
        )
        return paginate(rows, offset: offset)
    }

    private func played(offset: Int64) throws -> Page<EpisodeItem> {
        let rows = try database.query(
            "\(Self.episodeItemSelect) WHERE s.played_at IS NOT NULL AND \(Self.inListenPredicate) ORDER BY s.played_at DESC, e.id DESC LIMIT ? OFFSET ?",
            [.int(podsPageSize + 1), .int(offset)],
            map: Self.mapEpisodeItem
        )
        return paginate(rows, offset: offset)
    }

    private func paginate<T: Codable>(_ rows: [T], offset: Int64) -> Page<T> {
        if Int64(rows.count) > podsPageSize {
            return Page(items: Array(rows.prefix(Int(podsPageSize))), next_offset: offset + podsPageSize)
        }
        return Page(items: rows, next_offset: nil)
    }

    private func shows() throws -> [Show] {
        try database.query("\(Self.showSelect) WHERE p.is_subscribed = 1 ORDER BY p.title COLLATE NOCASE, p.id", map: Self.mapShow)
    }

    private func fetchShow(id: Int64) throws -> Show {
        guard let show = try database.query("\(Self.showSelect) WHERE p.id = ? AND p.is_subscribed = 1", [.int(id)], map: Self.mapShow).first else {
            throw PodsBackendError.notFound
        }
        return show
    }

    private func subscribe(feedURL rawURL: String) async throws -> Show {
        let feedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: feedURL), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw PodsBackendError.invalid("feed_url must be an http(s) URL")
        }
        let existingPodcastID = try database.scalarInt64("SELECT id FROM podcasts WHERE feed_url = ?", [.text(feedURL)])
        if let existingPodcastID,
           try database.scalarInt64("SELECT is_subscribed FROM podcasts WHERE id = ?", [.int(existingPodcastID)]) == 1 {
            throw PodsBackendError.conflict("already subscribed")
        }

        let fetched = try await fetchFeed(url, validators: FeedValidators())
        guard case let .data(data, validators) = fetched else {
            throw PodsBackendError.upstream("feed returned HTTP 304 during subscription")
        }
        let feed = try RSSParser.parse(data)
        let podcastID = try database.withTransaction { () -> Int64 in
            let podcastID: Int64
            if let existingPodcastID {
                podcastID = existingPodcastID
                try database.execute("UPDATE podcasts SET is_subscribed = 1 WHERE id = ?", [.int(podcastID)])
            } else {
                try database.execute("INSERT INTO podcasts (feed_url, created_at) VALUES (?, ?)", [.text(feedURL), .int(nowUnix())])
                podcastID = database.lastInsertRowID()
            }
            try upsertPodcastMeta(podcastID: podcastID, feed: feed)
            try upsertEpisodes(podcastID: podcastID, feed: feed)
            try saveFeedValidators(podcastID: podcastID, validators: validators)
            let ts = nowUnix()
            try database.execute(
                """
                INSERT INTO episode_state (episode_id, archived_at, updated_at)
                SELECT id, ?, ? FROM episodes WHERE podcast_id = ?
                ORDER BY published_at DESC, id DESC LIMIT -1 OFFSET 2
                ON CONFLICT (episode_id) DO UPDATE SET archived_at = excluded.archived_at, updated_at = excluded.updated_at
                """,
                [.int(ts), .int(ts), .int(podcastID)]
            )
            try AdRemovalJobStore.cleanupArchivedEpisodeMetadata(
                in: database,
                podcastID: podcastID,
                now: ts
            )
            return podcastID
        }
        if (try? settingValues()["ad_removal_enabled"]) == "true",
           let adRemovalRunRequestHandler {
            Task { await adRemovalRunRequestHandler() }
        }
        return try fetchShow(id: podcastID)
    }

    private func showDetail(id: Int64, offset: Int64) throws -> ShowDetail {
        let show = try fetchShow(id: id)
        let rows = try database.query(
            "\(Self.episodeItemSelect) WHERE e.podcast_id = ? ORDER BY e.published_at DESC, e.id DESC LIMIT ? OFFSET ?",
            [.int(id), .int(podsPageSize + 1), .int(offset)],
            map: Self.mapEpisodeItem
        )
        return ShowDetail(show: show, episodes: paginate(rows, offset: offset))
    }

    private func showSearch(id: Int64, query rawQuery: String) throws -> Page<EpisodeItem> {
        _ = try fetchShow(id: id)
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw PodsBackendError.invalid("q must not be empty")
        }
        let matchExpression = ftsQuery(query)
        let sql = """
        \(Self.episodeItemSelect) WHERE e.podcast_id = ? AND e.id IN
        (SELECT rowid FROM episodes_fts WHERE episodes_fts MATCH ? ORDER BY rank LIMIT ?)
        ORDER BY e.published_at DESC, e.id DESC
        """
        let rows = (try? database.query(
            sql,
            [.int(id), .text(matchExpression), .int(podsPageSize)],
            map: Self.mapEpisodeItem
        )) ?? []
        return Page(items: rows, next_offset: nil)
    }

    private func unsubscribe(id: Int64) throws {
        _ = try fetchShow(id: id)
        try database.withTransaction {
            try AdRemovalJobStore.enqueuePodcastArtifactCleanup(in: database, podcastID: id)
            try database.execute("DELETE FROM episodes_fts WHERE rowid IN (SELECT id FROM episodes WHERE podcast_id = ?)", [.int(id)])
            try database.execute("DELETE FROM podcasts WHERE id = ?", [.int(id)])
        }
        try adRemovalFileCleanup?.drain()
    }

    private func follows() throws -> [Follow] {
        try database.query(
            """
            SELECT f.id, f.name, f.aliases_json, f.last_checked_at,
              (SELECT COUNT(*) FROM follow_candidates c WHERE c.follow_id = f.id AND c.status = 'pending'),
              (SELECT COUNT(*) FROM follow_candidates c WHERE c.follow_id = f.id AND c.status = 'accepted')
            FROM follows f ORDER BY f.name COLLATE NOCASE, f.id
            """,
            map: Self.mapFollow
        )
    }

    private func createFollow(name rawName: String, aliases rawAliases: [String]) async throws -> Follow {
        guard directorySearcher is PersonAppearanceSearching else {
            throw PodsBackendError.upstream("Podcast Index appearance search is unavailable")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { throw PodsBackendError.invalid("name must be at least 2 characters") }
        let aliases = Self.cleanAliases(rawAliases, name: name)
        let aliasesJSON = String(data: try JSONEncoder().encode(aliases), encoding: .utf8)!
        let id = try database.withTransaction { () -> Int64 in
            if try database.scalarInt64("SELECT id FROM follows WHERE name = ?", [.text(name)]) != nil {
                throw PodsBackendError.conflict("already following \(name)")
            }
            try database.execute(
                "INSERT INTO follows (name, aliases_json, created_at) VALUES (?, ?, ?)",
                [.text(name), .text(aliasesJSON), .int(nowUnix())]
            )
            return database.lastInsertRowID()
        }
        return try await refreshFollow(id: id)
    }

    private func deleteFollow(id: Int64) throws {
        guard try database.scalarInt64("SELECT id FROM follows WHERE id = ?", [.int(id)]) != nil else {
            throw PodsBackendError.notFound
        }
        try database.execute("DELETE FROM follows WHERE id = ?", [.int(id)])
    }

    private func followCandidates() throws -> [FollowCandidate] {
        try database.query(
            """
            SELECT c.id, c.follow_id, c.source_episode_key, c.feed_url, c.feed_title, c.feed_image_url,
              c.guid, c.title, c.description, c.audio_url, c.duration_secs, c.published_at, c.image_url,
              c.evidence, c.confidence
            FROM follow_candidates c WHERE c.status = 'pending'
            ORDER BY c.published_at DESC, c.id DESC
            """,
            map: Self.mapFollowCandidate
        )
    }

    private func refreshFollow(id: Int64) async throws -> Follow {
        guard let follow = try follows().first(where: { $0.id == id }) else { throw PodsBackendError.notFound }
        guard let searcher = directorySearcher as? PersonAppearanceSearching else {
            throw PodsBackendError.upstream("Podcast Index appearance search is unavailable")
        }
        // An initial setup is intentionally bounded. A follow is for new
        // appearances, not an unbounded historical discovery import.
        let lookbackDays: Int64 = follow.last_checked_at == nil ? 30 : 7
        let cutoff = nowUnix() - lookbackDays * 86_400
        for name in [follow.name] + follow.aliases {
            for appearance in try await searcher.searchAppearances(person: name) {
                guard appearance.published_at >= cutoff else { continue }
                let candidateID = try storeFollowCandidate(followID: id, appearance: appearance)
                if appearance.confidence == "high", let candidateID {
                    try acceptFollowCandidate(id: candidateID)
                }
            }
        }
        try database.execute("UPDATE follows SET last_checked_at = ? WHERE id = ?", [.int(nowUnix()), .int(id)])
        guard let updated = try follows().first(where: { $0.id == id }) else { throw PodsBackendError.notFound }
        return updated
    }

    private func refreshFollowsAfterFeedRefresh() async {
        guard directorySearcher is PersonAppearanceSearching else { return }
        let ids = (try? database.query("SELECT id FROM follows ORDER BY id") { sqlite3_column_int64($0, 0) }) ?? []
        for id in ids {
            do {
                _ = try await refreshFollow(id: id)
            } catch {
                PodsDebugLog("Follow refresh failed followID=\(id) error=\(error.localizedDescription)")
            }
        }
    }

    private func storeFollowCandidate(followID: Int64, appearance: DirectoryAppearance) throws -> Int64? {
        if try database.scalarInt64(
            "SELECT id FROM follow_candidates WHERE follow_id = ? AND (source_episode_key = ? OR (feed_url = ? AND guid = ?))",
            [.int(followID), .text(appearance.source_episode_key), .text(appearance.feed_url), .text(appearance.guid)]
        ) != nil { return nil }
        try database.execute(
            """
            INSERT INTO follow_candidates (follow_id, source_episode_key, feed_url, feed_title, feed_image_url, guid, title, description, audio_url, duration_secs, published_at, image_url, evidence, confidence, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.int(followID), .text(appearance.source_episode_key), .text(appearance.feed_url), .text(appearance.feed_title), .text(appearance.feed_image_url), .text(appearance.guid), .text(appearance.title), .text(appearance.description), .text(appearance.audio_url), appearance.duration_secs.map(SQLiteValue.int) ?? .null, .int(appearance.published_at), .text(appearance.image_url), .text(appearance.evidence), .text(appearance.confidence), .int(nowUnix())]
        )
        return database.lastInsertRowID()
    }

    private func acceptFollowCandidate(id: Int64) throws {
        let candidates = try database.query(
            """
            SELECT c.id, c.follow_id, c.source_episode_key, c.feed_url, c.feed_title, c.feed_image_url,
              c.guid, c.title, c.description, c.audio_url, c.duration_secs, c.published_at, c.image_url,
              c.evidence, c.confidence
            FROM follow_candidates c WHERE c.id = ? AND c.status = 'pending'
            """, [.int(id)], map: Self.mapFollowCandidate
        )
        guard let candidate = candidates.first else { throw PodsBackendError.notFound }
        try database.withTransaction {
            let a = candidate.appearance
            let podcastID: Int64
            if let existing = try database.scalarInt64("SELECT id FROM podcasts WHERE feed_url = ?", [.text(a.feed_url)]) {
                podcastID = existing
            } else {
                try database.execute(
                    "INSERT INTO podcasts (feed_url, title, description, image_url, is_subscribed, created_at) VALUES (?, ?, ?, ?, 0, ?)",
                    [.text(a.feed_url), .text(a.feed_title), .text(""), .text(a.feed_image_url), .int(nowUnix())]
                )
                podcastID = database.lastInsertRowID()
            }
            try database.execute(
                """
                INSERT INTO episodes (podcast_id, guid, title, notes_html, audio_url, duration_secs, published_at, image_url)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(podcast_id, guid) DO UPDATE SET title=excluded.title, notes_html=excluded.notes_html, audio_url=excluded.audio_url, duration_secs=excluded.duration_secs, published_at=excluded.published_at, image_url=excluded.image_url
                """,
                [.int(podcastID), .text(a.guid), .text(a.title), .text(a.description), .text(a.audio_url), a.duration_secs.map(SQLiteValue.int) ?? .null, .int(a.published_at), .text(a.image_url)]
            )
            guard let episodeID = try database.scalarInt64("SELECT id FROM episodes WHERE podcast_id = ? AND guid = ?", [.int(podcastID), .text(a.guid)]) else {
                throw PodsBackendError.database("could not load accepted appearance")
            }
            try database.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (?, ?) ON CONFLICT(episode_id) DO NOTHING", [.int(episodeID), .int(nowUnix())])
            try database.execute("INSERT OR IGNORE INTO follow_episodes (follow_id, episode_id) VALUES (?, ?)", [.int(candidate.follow_id), .int(episodeID)])
            try database.execute("UPDATE follow_candidates SET status = 'accepted' WHERE id = ?", [.int(id)])
            try database.execute("DELETE FROM episodes_fts WHERE rowid = ?", [.int(episodeID)])
            try database.execute("INSERT INTO episodes_fts (rowid, title, notes) VALUES (?, ?, ?)", [.int(episodeID), .text(a.title), .text(stripHTML(a.description))])
        }
        NotificationCenter.default.post(name: .podsFeedRefreshCompleted, object: nil)
    }

    private func rejectFollowCandidate(id: Int64) throws {
        try database.execute("UPDATE follow_candidates SET status = 'rejected' WHERE id = ? AND status = 'pending'", [.int(id)])
    }

    private func episodeDetail(id: Int64) throws -> EpisodeDetail {
        let sql = """
        SELECT e.id, e.podcast_id, p.title AS podcast_title, p.image_url AS podcast_image,
        e.title, e.audio_url, e.duration_secs, e.published_at, e.image_url,
        CAST(COALESCE(s.position_secs, 0) AS REAL) AS position_secs, s.played_at,
        e.notes_html, s.archived_at,
        CASE
            WHEN j.stage = 'ready' THEN 'ad-free'
            WHEN j.stage = 'failed' THEN 'failed'
            WHEN j.id IS NULL OR j.stage = 'cancelled' THEN 'unfiltered'
            ELSE 'preparing'
        END AS ad_removal_state,
        CASE
            WHEN j.stage = 'failed' THEN 'retry'
            WHEN j.id IS NULL OR j.stage = 'cancelled' THEN 'prepare'
            ELSE NULL
        END AS ad_removal_action,
        j.stage AS ad_removal_stage,
        j.blocking_reason AS ad_removal_blocking_reason,
        CASE WHEN j.stage = 'classifying' THEN (
            SELECT COUNT(*) FROM ad_classification_windows w
            WHERE w.episode_id = e.id AND w.schema_valid = 1
              AND w.run_id = (
                  SELECT latest.run_id FROM ad_classification_windows latest
                  WHERE latest.episode_id = e.id
                  ORDER BY latest.created_at DESC LIMIT 1
              )
        ) ELSE NULL END AS completed_windows,
        CASE WHEN j.stage = 'classifying' THEN (
            CASE
                WHEN (SELECT COUNT(*) FROM ad_transcript_segments s WHERE s.episode_id = e.id) = 0 THEN NULL
                WHEN (SELECT COUNT(*) FROM ad_transcript_segments s WHERE s.episode_id = e.id) <= 8 THEN 1
                ELSE 1 + ((SELECT COUNT(*) FROM ad_transcript_segments s WHERE s.episode_id = e.id) - 8 + 5) / 6
            END
        ) ELSE NULL END AS total_windows
        FROM episodes e JOIN podcasts p ON p.id = e.podcast_id
        LEFT JOIN episode_state s ON s.episode_id = e.id
        LEFT JOIN ad_removal_jobs j ON j.episode_id = e.id
        WHERE e.id = ?
        """
        guard var detail = try database.query(sql, [.int(id)], map: Self.mapEpisodeDetail).first else {
            throw PodsBackendError.notFound
        }
        detail.show_notes = try episodeShowNotesStore.notes(episodeID: id)
        if detail.ad_removal_stage == AdRemovalJobStage.ready.rawValue {
            detail.ad_markers = try AdRemovalJobStore(database: database)
                .skipRanges(episodeID: id)
                .filter { !$0.disabled && $0.startTime.isFinite && $0.startTime >= 0 }
                .map { EpisodeAdMarker(id: $0.id, start_time: $0.startTime) }
        }
        return detail
    }

    private func episodeExists(id: Int64) throws {
        guard try database.scalarInt64("SELECT id FROM episodes WHERE id = ?", [.int(id)]) != nil else {
            throw PodsBackendError.notFound
        }
    }

    private func requireOnDeviceClassifierAvailable() throws {
        let availability = onDeviceModelAvailability.currentAvailability()
        guard availability.available else {
            throw PodsBackendError.invalid(availability.enableError)
        }
    }

    private func prepareAdRemoval(id: Int64) throws -> AdRemovalJob {
        try requireOnDeviceClassifierAvailable()
        try episodeExists(id: id)
        let store = AdRemovalJobStore(database: database)
        if let existing = try store.job(episodeID: id) {
            if existing.stage == .failed {
                throw PodsBackendError.conflict("failed preparation must be retried")
            }
            return existing
        }
        return try store.enqueue(episodeID: id)
    }

    private func retryAdRemoval(id: Int64) throws -> AdRemovalJob {
        try requireOnDeviceClassifierAvailable()
        try episodeExists(id: id)
        let store = AdRemovalJobStore(database: database)
        guard let existing = try store.job(episodeID: id) else {
            throw PodsBackendError.notFound
        }
        guard existing.stage == .failed else {
            throw PodsBackendError.conflict("preparation has not failed")
        }
        return try store.retry(jobID: existing.id)
    }

    private func adRemovalSettings() throws -> AdRemovalSettingsPayload {
        let values = try settingValues()
        let corrections = try database.query(
            """
            SELECT p.id, p.title, COUNT(c.id)
            FROM podcasts p
            JOIN ad_corrections c ON c.podcast_id = p.id AND c.active = 1
            GROUP BY p.id, p.title
            ORDER BY p.title COLLATE NOCASE, p.id
            """
        ) { statement in
            AdRemovalCorrectionCountPayload(
                podcast_id: sqlite3_column_int64(statement, 0),
                podcast_title: sqliteString(statement, 1),
                count: sqlite3_column_int64(statement, 2)
            )
        }
        let descriptor = AdClassifierDescriptor.appleSystemLanguageModelV1
        let availability = onDeviceModelAvailability.currentAvailability()
        return AdRemovalSettingsPayload(
            enabled: values["ad_removal_enabled"] == "true",
            enrollment_cutoff: values["ad_removal_enrollment_cutoff"].flatMap(Int64.init),
            cloud_classifier_configured: availability.available,
            model_repository: descriptor.modelID,
            model_revision: descriptor.modelRevision,
            model_total_bytes: 0,
            model_downloaded_bytes: 0,
            model_download_state: availability.downloadState,
            classifier_available: availability.available,
            classifier_unavailable_reason: availability.reason?.rawValue,
            episode_storage_bytes: (try adRemovalArtifactStore?.episodeArtifactBytes()) ?? 0,
            episode_storage_limit_bytes: AdRemovalStoragePolicy.tenGigabytes,
            minimum_free_bytes: AdRemovalStoragePolicy.tenGigabytes,
            device_available_bytes: (try adRemovalArtifactStore?.availableCapacity()) ?? 0,
            corrections: corrections
        )
    }

    /// Bounded, lightweight batch ad-removal status for the Listen view. Accepts
    /// at most 50 unique positive episode ids via `episode_ids` (comma-separated),
    /// preserves the deduplicated requested order, omits non-existent ids, and
    /// returns only the ad-removal status fields — never `notes_html`.
    private func adRemovalStatuses(request: HTTPRequest) throws -> AdRemovalStatusesPayload {
        let raw = request.query("episode_ids") ?? ""
        guard !raw.isEmpty else {
            throw PodsBackendError.invalid("episode_ids must not be empty")
        }
        var ids: [Int64] = []
        var seen = Set<Int64>()
        // Preserve empty subsequences so malformed CSV like `1,,2`, `1,`, and
        // `,1` is rejected instead of silently accepted by omitting empties.
        for token in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw PodsBackendError.invalid("episode_ids must not contain empty tokens")
            }
            guard let id = Int64(trimmed) else {
                throw PodsBackendError.invalid("episode_ids must be comma-separated integers")
            }
            guard id > 0 else {
                throw PodsBackendError.invalid("episode_ids must be positive")
            }
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        guard ids.count <= 50 else {
            throw PodsBackendError.invalid("episode_ids must contain at most 50 unique ids")
        }
        guard !ids.isEmpty else {
            throw PodsBackendError.invalid("episode_ids must not be empty")
        }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let sql = """
        SELECT e.id,
        CASE
            WHEN j.stage = 'ready' THEN 'ad-free'
            WHEN j.stage = 'failed' THEN 'failed'
            WHEN j.id IS NULL OR j.stage = 'cancelled' THEN 'unfiltered'
            ELSE 'preparing'
        END AS ad_removal_state,
        CASE
            WHEN j.stage = 'failed' THEN 'retry'
            WHEN j.id IS NULL OR j.stage = 'cancelled' THEN 'prepare'
            ELSE NULL
        END AS ad_removal_action,
        j.stage AS ad_removal_stage,
        j.blocking_reason AS ad_removal_blocking_reason,
        CASE WHEN j.stage = 'classifying' THEN (
            SELECT COUNT(*) FROM ad_classification_windows w
            WHERE w.episode_id = e.id AND w.schema_valid = 1
              AND w.run_id = (
                  SELECT latest.run_id FROM ad_classification_windows latest
                  WHERE latest.episode_id = e.id
                  ORDER BY latest.created_at DESC LIMIT 1
              )
        ) ELSE NULL END AS completed_windows,
        CASE WHEN j.stage = 'classifying' THEN (
            CASE
                WHEN (SELECT COUNT(*) FROM ad_transcript_segments s WHERE s.episode_id = e.id) = 0 THEN NULL
                WHEN (SELECT COUNT(*) FROM ad_transcript_segments s WHERE s.episode_id = e.id) <= 8 THEN 1
                ELSE 1 + ((SELECT COUNT(*) FROM ad_transcript_segments s WHERE s.episode_id = e.id) - 8 + 5) / 6
            END
        ) ELSE NULL END AS total_windows
        FROM episodes e
        LEFT JOIN ad_removal_jobs j ON j.episode_id = e.id
        WHERE e.id IN (\(placeholders))
        """
        let values = ids.map { SQLiteValue.int($0) }
        let byID = try Dictionary(uniqueKeysWithValues: database.query(sql, values) { statement in
            (
                sqlite3_column_int64(statement, 0),
                AdRemovalStatusItem(
                    id: sqlite3_column_int64(statement, 0),
                    ad_removal_state: sqliteString(statement, 1),
                    ad_removal_action: sqliteOptionalString(statement, 2),
                    ad_removal_stage: sqliteOptionalString(statement, 3),
                    ad_removal_blocking_reason: sqliteOptionalString(statement, 4),
                    ad_removal_completed_windows: sqliteOptionalInt64(statement, 5),
                    ad_removal_total_windows: sqliteOptionalInt64(statement, 6)
                )
            )
        })
        // Preserve deduplicated requested order, omitting non-existent ids.
        let items = ids.compactMap { byID[$0] }
        return AdRemovalStatusesPayload(items: items)
    }

    private func enableAdRemoval(confirmedBytes: Int64) throws -> AdRemovalSettingsPayload {
        // confirmed_bytes remains in the API for older clients. The on-device
        // Apple Intelligence model is OS-managed, so no download consent is required.
        _ = confirmedBytes
        let availability = onDeviceModelAvailability.currentAvailability()
        guard availability.available else {
            throw PodsBackendError.invalid(availability.enableError)
        }
        let values = try settingValues()
        let cutoff = values["ad_removal_enrollment_cutoff"] ?? String(nowUnix())
        let descriptor = AdClassifierDescriptor.appleSystemLanguageModelV1
        try database.withTransaction {
            try setSetting(key: "ad_removal_enabled", value: "true")
            try setSetting(key: "ad_removal_enrollment_cutoff", value: cutoff)
            try setSetting(key: "ad_removal_model_repository", value: descriptor.modelID)
            try setSetting(key: "ad_removal_model_revision", value: descriptor.modelRevision)
            try setSetting(key: "ad_removal_model_download_state", value: "ready")
        }
        try? adRemovalDiagnostics?.record(
            eventName: "feature_enabled",
            severity: .notice,
            fields: [
                "cutoff": cutoff,
                "classifier": descriptor.modelID
            ]
        )
        return try adRemovalSettings()
    }

    private func settingValues() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try database.query("SELECT key, value FROM settings") {
            (sqliteString($0, 0), sqliteString($0, 1))
        })
    }

    private func setSetting(key: String, value: String) throws {
        try database.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)]
        )
    }

    private func resetAdRemovalCorrections(podcastID: Int64) throws {
        guard (try database.scalarInt64("SELECT COUNT(*) FROM podcasts WHERE id = ?", [.int(podcastID)])) ?? 0 > 0 else {
            throw PodsBackendError.notFound
        }
        try AdRemovalJobStore(database: database).resetCorrections(podcastID: podcastID)
        try? adRemovalDiagnostics?.record(
            eventName: "corrections_reset",
            severity: .notice,
            fields: ["podcast_id": String(podcastID)]
        )
    }

    private func exportAdRemovalDiagnostics() throws -> HTTPResponse {
        guard let adRemovalDiagnostics else { throw PodsBackendError.notFound }
        let values = try settingValues()
        let stateSummary = [
            "enabled": values["ad_removal_enabled"] ?? "false",
            "model_revision": values["ad_removal_model_revision"] ?? "none",
            "model_download_state": values["ad_removal_model_download_state"] ?? "not_downloaded",
            "queued_jobs": String((try database.scalarInt64(
                "SELECT COUNT(*) FROM ad_removal_jobs WHERE stage NOT IN ('ready', 'failed', 'cancelled')"
            )) ?? 0),
            "ready_jobs": String((try database.scalarInt64(
                "SELECT COUNT(*) FROM ad_removal_jobs WHERE stage = 'ready'"
            )) ?? 0),
            "failed_jobs": String((try database.scalarInt64(
                "SELECT COUNT(*) FROM ad_removal_jobs WHERE stage = 'failed'"
            )) ?? 0)
        ]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodsAdRemovalDiagnosticExports", isDirectory: true)
        let archive = try adRemovalDiagnostics.exportArchive(
            to: directory,
            stateSummary: stateSummary,
            schemaVersions: [
                "database": "1",
                "classifier_output": "1",
                "skip_manifest": "1",
                "model_revision": AdModelManifest.qwen3OneSevenBFourBitV1.revision
            ]
        )
        defer { try? FileManager.default.removeItem(at: archive) }
        return HTTPResponse(
            statusCode: 200,
            headers: [
                "content-type": "application/zip",
                "content-disposition": "attachment; filename=\"\(archive.lastPathComponent)\""
            ],
            body: try Data(contentsOf: archive)
        )
    }

    private func cleanupAdRemovalData() throws {
        guard let adRemovalArtifactStore else { throw PodsBackendError.notFound }
        let modelStore = try AdModelAssetStore(artifactStore: adRemovalArtifactStore)
        try? adRemovalDiagnostics?.record(eventName: "feature_cleanup_started", severity: .notice)
        try modelStore.removeAll()
        let store = AdRemovalJobStore(database: database)
        try store.cleanupAllFeatureMetadata()
        try adRemovalFileCleanup?.drain()
        try adRemovalArtifactStore.removeAllEpisodeArtifacts()
        try? adRemovalDiagnostics?.record(eventName: "feature_cleanup_finished", severity: .notice)
    }

    private func setPlayed(id: Int64) async throws {
        try episodeExists(id: id)
        let ts = nowUnix()
        // The user's tap is authoritative. Persist both the played state and
        // the pipeline tombstone in one transaction before starting any work
        // that can suspend. Reads and app restarts must observe the tap even if
        // cancellation is slow or the process is terminated during cleanup.
        try database.withTransaction {
            try database.execute(
                """
                UPDATE ad_removal_jobs
                SET stage = 'cancelled', blocking_reason = NULL, updated_at = ?
                WHERE episode_id = ?
                """,
                [.int(ts), .int(id)]
            )
            try database.execute(
                """
                INSERT INTO episode_state (episode_id, played_at, updated_at) VALUES (?, ?, ?)
                ON CONFLICT (episode_id) DO UPDATE SET played_at = excluded.played_at, updated_at = excluded.updated_at
                """,
                [.int(id), .int(ts), .int(ts)]
            )
        }

        // Cancellation and artifact cleanup are deliberately detached from the
        // HTTP response. The cancelled job is a durable restart marker; init
        // reconciles it if this task is interrupted by process termination.
        Task { [weak self] in
            await self?.finishPlayedCleanup(id: id)
        }
    }

    private func finishPlayedCleanup(id: Int64) async {
        // Workers can still hold episode input in memory. Drain them before
        // deleting durable sources so a cancelled worker cannot write late.
        await cancelAdRemovalPipeline(.episode(id))
        await episodeShowNotesService?.cancel(episodeID: id)
        do {
            try database.withTransaction {
                try AdRemovalJobStore.cleanupEpisodeMetadata(in: database, episodeID: id)
            }
            try adRemovalFileCleanup?.drain()
        } catch {
            PodsLog("Pods played-episode background cleanup failed episodeID=\(id): \(error)")
        }
        if let adRemovalRunRequestHandler {
            await adRemovalRunRequestHandler()
        }
    }

    /// A process can be terminated after the played-state transaction commits
    /// but before its background cancellation finishes. No old worker survives
    /// a relaunch, so stale metadata for played episodes is safe to reconcile
    /// synchronously before the scheduler is allowed to resume.
    private func recoverInterruptedPlayedCleanupAfterColdStart() {
        do {
            let episodeIDs = try database.query(
                """
                SELECT j.episode_id
                FROM ad_removal_jobs j
                JOIN episode_state s ON s.episode_id = j.episode_id
                WHERE s.played_at IS NOT NULL
                ORDER BY j.episode_id
                """,
                map: { sqlite3_column_int64($0, 0) }
            )
            guard !episodeIDs.isEmpty else { return }
            try database.withTransaction {
                for episodeID in episodeIDs {
                    try AdRemovalJobStore.cleanupEpisodeMetadata(in: database, episodeID: episodeID)
                }
            }
            try adRemovalFileCleanup?.drain()
            PodsLog("Pods recovered played-episode cleanup count=\(episodeIDs.count)")
        } catch {
            PodsLog("Pods played-episode cleanup recovery failed: \(error)")
        }
    }

    private func cancelAdRemovalPipeline(_ scope: AdRemovalPipelineCancellationScope) async {
        if let adRemovalCancellationRequestHandler {
            await adRemovalCancellationRequestHandler(scope)
        } else if scope == .all, let adRemovalStopRequestHandler {
            // Compatibility for tests/standalone backend users that install
            // only the historical all-work stop hook.
            await adRemovalStopRequestHandler()
        }
    }

    private func clearPlayed(id: Int64) throws {
        try episodeExists(id: id)
        try database.execute(
            "UPDATE episode_state SET played_at = NULL, archived_at = NULL, updated_at = ? WHERE episode_id = ?",
            [.int(nowUnix()), .int(id)]
        )
    }

    private func setPosition(id: Int64, seconds: Double) throws {
        guard seconds.isFinite && seconds >= 0 else {
            throw PodsBackendError.invalid("seconds must be >= 0")
        }
        try episodeExists(id: id)
        try database.execute(
            """
            INSERT INTO episode_state (episode_id, position_secs, updated_at) VALUES (?, ?, ?)
            ON CONFLICT (episode_id) DO UPDATE SET position_secs = excluded.position_secs, updated_at = excluded.updated_at
            """,
            [.int(id), .double(seconds), .int(nowUnix())]
        )
    }

    private func next(after: Int64, context: String) throws -> EpisodeItem? {
        guard let cur = try database.query("SELECT published_at, podcast_id FROM episodes WHERE id = ?", [.int(after)], map: { statement in
            (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
        }).first else {
            throw PodsBackendError.notFound
        }
        let sql: String
        if context == "show" {
            sql = "\(Self.episodeItemSelect) WHERE s.played_at IS NULL AND s.archived_at IS NULL AND e.podcast_id = ?3 AND (e.published_at > ?1 OR (e.published_at = ?1 AND e.id > ?2)) ORDER BY e.published_at ASC, e.id ASC LIMIT 1"
        } else {
            sql = "\(Self.episodeItemSelect) WHERE s.played_at IS NULL AND s.archived_at IS NULL AND \(Self.inListenPredicate) AND (e.published_at < ?1 OR (e.published_at = ?1 AND e.id < ?2)) AND ?3 = ?3 ORDER BY e.published_at DESC, e.id DESC LIMIT 1"
        }
        return try database.query(sql, [.int(cur.0), .int(after), .int(cur.1)], map: Self.mapEpisodeItem).first
    }

    private func settings() throws -> SettingsPayload {
        let rows = try database.query("SELECT key, value FROM settings") { statement in
            (sqliteString(statement, 0), sqliteString(statement, 1))
        }
        var speed = 1.0
        var autoplay = true
        for row in rows {
            if row.0 == "speed" {
                speed = Double(row.1) ?? 1.0
            } else if row.0 == "autoplay" {
                autoplay = row.1 != "false"
            }
        }
        return SettingsPayload(speed: speed, autoplay: autoplay)
    }

    private func saveSettings(_ settings: SettingsPayload) throws {
        guard (0.5...3.0).contains(settings.speed) else {
            throw PodsBackendError.invalid("speed must be between 0.5 and 3.0")
        }
        try database.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            [.text("speed"), .text(String(settings.speed))]
        )
        try database.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            [.text("autoplay"), .text(settings.autoplay ? "true" : "false")]
        )
    }

    private func refreshAll() async -> RefreshResult {
        let rows: [(Int64, String)]
        do {
            rows = try database.query("SELECT id, feed_url FROM podcasts WHERE is_subscribed = 1 ORDER BY id") { statement in
                (sqlite3_column_int64(statement, 0), sqliteString(statement, 1))
            }
        } catch {
            return RefreshResult(refreshed: 0, errors: 0)
        }
        var ok = 0
        var errors = 0
        for (index, row) in rows.enumerated() {
            if Task.isCancelled {
                errors += rows.count - index
                break
            }
            do {
                try await refreshOne(podcastID: row.0, feedURL: row.1)
                ok += 1
            } catch {
                if Task.isCancelled {
                    errors += rows.count - index
                    break
                }
                PodsDebugLog("Refresh failed podcastID=\(row.0) error=\(error.localizedDescription)")
                errors += 1
            }
        }
        PodsDebugLog("Refresh finished ok=\(ok) errors=\(errors)")
        await refreshFollowsAfterFeedRefresh()
        return RefreshResult(refreshed: ok, errors: errors)
    }

    private func recordRefreshAttempt(source: RefreshSource, startedAt: Int64) -> Int64? {
        do {
            return try database.withTransaction {
                try database.execute(
                    """
                    INSERT INTO feed_refresh_state (id, last_attempt_at, last_source, last_refreshed, last_errors)
                    VALUES (1, ?, ?, 0, 0)
                    ON CONFLICT(id) DO UPDATE SET last_attempt_at = excluded.last_attempt_at, last_source = excluded.last_source
                    """,
                    [.int(startedAt), .text(source.rawValue)]
                )
                try database.execute(
                    """
                    INSERT INTO feed_refresh_attempts (source, started_at, outcome)
                    VALUES (?, ?, 'running')
                    """,
                    [.text(source.rawValue), .int(startedAt)]
                )
                return database.lastInsertRowID()
            }
        } catch {
            PodsLog("Pods refresh attempt record failed: \(error)")
            return nil
        }
    }

    private func recordRefreshCompletion(
        source: RefreshSource,
        startedAt: Int64,
        finishedAt: Int64,
        result: RefreshResult,
        attemptID: Int64?
    ) {
        do {
            try database.withTransaction {
                try database.execute(
                    """
                    UPDATE feed_refresh_state
                    SET last_success_at = CASE WHEN ? = 0 THEN ? ELSE last_success_at END,
                        last_source = ?, last_refreshed = ?, last_errors = ?
                    WHERE id = 1
                    """,
                    [.int(Int64(result.errors)), .int(finishedAt), .text(source.rawValue), .int(Int64(result.refreshed)), .int(Int64(result.errors))]
                )
                try database.execute(
                    "INSERT INTO feed_refresh_runs (source, started_at, finished_at, refreshed, errors) VALUES (?, ?, ?, ?, ?)",
                    [.text(source.rawValue), .int(startedAt), .int(finishedAt), .int(Int64(result.refreshed)), .int(Int64(result.errors))]
                )
                if let attemptID {
                    try database.execute(
                        """
                        UPDATE feed_refresh_attempts
                        SET finished_at = ?, refreshed = ?, errors = ?, outcome = ?
                        WHERE id = ? AND outcome = 'running'
                        """,
                        [
                            .int(finishedAt),
                            .int(Int64(result.refreshed)),
                            .int(Int64(result.errors)),
                            .text(result.errors == 0 ? "completed" : "completed_with_errors"),
                            .int(attemptID)
                        ]
                    )
                }
            }
        } catch {
            PodsLog("Pods refresh completion record failed: \(error)")
        }
    }

    private func recoverInterruptedRefreshAttempts(now: Int64 = nowUnix()) {
        do {
            let interruptedSource = try database.query(
                """
                SELECT source FROM feed_refresh_attempts
                WHERE outcome = 'running'
                ORDER BY id DESC
                LIMIT 1
                """
            ) { sqliteString($0, 0) }.first
            guard let interruptedSource else { return }

            try database.withTransaction {
                try database.execute(
                    """
                    UPDATE feed_refresh_attempts
                    SET finished_at = ?, refreshed = 0, errors = 1, outcome = 'interrupted'
                    WHERE outcome = 'running'
                    """,
                    [.int(now)]
                )
                try database.execute(
                    """
                    INSERT INTO feed_refresh_state (id, last_attempt_at, last_source, last_refreshed, last_errors)
                    VALUES (1, ?, ?, 0, 1)
                    ON CONFLICT(id) DO UPDATE SET
                        last_source = excluded.last_source,
                        last_refreshed = excluded.last_refreshed,
                        last_errors = excluded.last_errors
                    """,
                    [.int(now), .text(interruptedSource)]
                )
            }
            PodsLog("Pods recovered an interrupted feed refresh source=\(interruptedSource)")
        } catch {
            PodsLog("Pods interrupted refresh recovery failed: \(error)")
        }
    }

    private func refreshOne(podcastID: Int64, feedURL: String) async throws {
        guard let url = URL(string: feedURL) else {
            throw PodsBackendError.invalid("feed_url must be an http(s) URL")
        }
        PodsDebugLog("Refresh starting podcastID=\(podcastID) url=\(url.absoluteString)")
        let validators = try feedValidators(podcastID: podcastID)
        switch try await fetchFeed(url, validators: validators) {
        case .notModified(let updatedValidators):
            try database.withTransaction {
                try markFeedFetched(podcastID: podcastID)
                try saveFeedValidators(podcastID: podcastID, validators: updatedValidators)
            }
            PodsDebugLog("Refresh not modified podcastID=\(podcastID)")
        case .data(let data, let updatedValidators):
            let feed = try RSSParser.parse(data)
            try database.withTransaction {
                try upsertPodcastMeta(podcastID: podcastID, feed: feed)
                let newCount = try upsertEpisodes(podcastID: podcastID, feed: feed)
                try saveFeedValidators(podcastID: podcastID, validators: updatedValidators)
                PodsDebugLog("Refresh stored podcastID=\(podcastID) newEpisodes=\(newCount)")
            }
        }
    }

    private func fetchFeed(_ url: URL, validators: FeedValidators) async throws -> FeedFetchResponse {
        if let conditionalFetcher = feedFetcher as? ConditionalFeedFetching {
            return try await conditionalFetcher.response(for: url, validators: validators)
        }
        return .data(try await feedFetcher.data(for: url), validators)
    }

    private func feedValidators(podcastID: Int64) throws -> FeedValidators {
        try database.query(
            "SELECT etag, last_modified FROM feed_http_cache WHERE podcast_id = ?",
            [.int(podcastID)]
        ) { statement in
            FeedValidators(
                eTag: sqliteOptionalString(statement, 0),
                lastModified: sqliteOptionalString(statement, 1)
            )
        }.first ?? FeedValidators()
    }

    private func saveFeedValidators(podcastID: Int64, validators: FeedValidators) throws {
        try database.execute(
            """
            INSERT INTO feed_http_cache (podcast_id, etag, last_modified) VALUES (?, ?, ?)
            ON CONFLICT(podcast_id) DO UPDATE SET etag = excluded.etag, last_modified = excluded.last_modified
            """,
            [
                .int(podcastID),
                validators.eTag.map(SQLiteValue.text) ?? .null,
                validators.lastModified.map(SQLiteValue.text) ?? .null
            ]
        )
    }

    private func markFeedFetched(podcastID: Int64) throws {
        try database.execute(
            "UPDATE podcasts SET last_fetched_at = ? WHERE id = ?",
            [.int(nowUnix()), .int(podcastID)]
        )
    }

    private func search(query rawQuery: String) async throws -> SearchResults {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw PodsBackendError.invalid("q must not be empty")
        }
        let matchExpression = ftsQuery(query)
        let sql = """
        \(Self.episodeItemSelect) WHERE e.id IN
        (SELECT rowid FROM episodes_fts WHERE episodes_fts MATCH ? ORDER BY rank LIMIT 30)
        ORDER BY e.published_at DESC
        """
        let episodes = (try? database.query(sql, [.text(matchExpression)], map: Self.mapEpisodeItem)) ?? []
        let podcasts: [DirectoryPodcast]
        if directorySearcher.isConfigured {
            let subscribedFeeds = try Set(database.query("SELECT feed_url FROM podcasts WHERE is_subscribed = 1", map: { sqliteString($0, 0) }))
            podcasts = try await directorySearcher.search(query: query).map { podcast in
                DirectoryPodcast(
                    title: podcast.title,
                    author: podcast.author,
                    feed_url: podcast.feed_url,
                    image_url: podcast.image_url,
                    description: podcast.description,
                    subscribed: subscribedFeeds.contains(podcast.feed_url)
                )
            }
        } else {
            podcasts = []
        }
        return SearchResults(directory_configured: directorySearcher.isConfigured, podcasts: podcasts, episodes: episodes)
    }

    private func exportOPML() throws -> String {
        let rows = try database.query("SELECT title, feed_url FROM podcasts ORDER BY title COLLATE NOCASE") { statement in
            (title: sqliteString(statement, 0), feedURL: sqliteString(statement, 1))
        }
        return PodsOPML.render(rows)
    }

    private func importOPML(_ xml: String) async throws -> OPMLImportResult {
        let urls = PodsOPML.parse(xml)
        if urls.isEmpty {
            throw PodsBackendError.invalid("no feeds found in OPML")
        }
        var imported = 0
        var skipped = 0
        var failed = 0
        for url in urls {
            do {
                _ = try await subscribe(feedURL: url)
                imported += 1
            } catch PodsBackendError.conflict(_) {
                skipped += 1
            } catch {
                failed += 1
            }
        }
        return OPMLImportResult(imported: imported, skipped: skipped, failed: failed)
    }

    private func upsertPodcastMeta(podcastID: Int64, feed: ParsedFeed) throws {
        try database.execute(
            """
            UPDATE podcasts SET title = ?, description = ?, image_url = ?, site_url = ?, last_fetched_at = ? WHERE id = ?
            """,
            [.text(feed.title), .text(feed.description), .text(feed.imageURL), .text(feed.siteURL), .int(nowUnix()), .int(podcastID)]
        )
    }

    @discardableResult
    private func upsertEpisodes(podcastID: Int64, feed: ParsedFeed) throws -> Int {
        var newCount = 0
        for episode in feed.episodes {
            let existing = try database.scalarInt64(
                "SELECT id FROM episodes WHERE podcast_id = ? AND guid = ?",
                [.int(podcastID), .text(episode.guid)]
            )
            let episodeID: Int64
            if let existing {
                try database.execute(
                    """
                    UPDATE episodes SET title = ?, notes_html = ?, audio_url = ?, duration_secs = ?, published_at = ?, image_url = ? WHERE id = ?
                    """,
                    [
                        .text(episode.title),
                        .text(episode.notesHTML),
                        .text(episode.audioURL),
                        episode.durationSecs.map(SQLiteValue.int) ?? .null,
                        .int(episode.publishedAt),
                        .text(episode.imageURL),
                        .int(existing)
                    ]
                )
                episodeID = existing
            } else {
                try database.execute(
                    """
                    INSERT INTO episodes (podcast_id, guid, title, notes_html, audio_url, duration_secs, published_at, image_url)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .int(podcastID),
                        .text(episode.guid),
                        .text(episode.title),
                        .text(episode.notesHTML),
                        .text(episode.audioURL),
                        episode.durationSecs.map(SQLiteValue.int) ?? .null,
                        .int(episode.publishedAt),
                        .text(episode.imageURL)
                    ]
                )
                episodeID = database.lastInsertRowID()
                newCount += 1
                if try settingValues()["ad_removal_enabled"] == "true" {
                    _ = try AdRemovalJobStore(database: database).enqueue(episodeID: episodeID)
                }
            }
            try database.execute("DELETE FROM episodes_fts WHERE rowid = ?", [.int(episodeID)])
            try database.execute(
                "INSERT INTO episodes_fts (rowid, title, notes) VALUES (?, ?, ?)",
                [.int(episodeID), .text(episode.title), .text(stripHTML(episode.notesHTML))]
            )
        }
        return newCount
    }

    private func ftsQuery(_ value: String) -> String {
        let tokens = value.split { $0.isWhitespace }.map { token in
            "\"\(String(token).replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        guard let last = tokens.last else {
            return ""
        }
        var parts = Array(tokens.dropLast())
        parts.append("\(last)*")
        return parts.joined(separator: " ")
    }

    private static let episodeItemSelect = """
    SELECT e.id, e.podcast_id, p.title AS podcast_title, p.image_url AS podcast_image,
    e.title, e.audio_url, e.duration_secs, e.published_at, e.image_url,
    CAST(COALESCE(s.position_secs, 0) AS REAL) AS position_secs, s.played_at,
    CASE
        WHEN j.stage = 'ready' THEN 'ad-free'
        WHEN j.stage = 'failed' THEN 'failed'
        WHEN j.id IS NULL OR j.stage = 'cancelled' THEN 'unfiltered'
        ELSE 'preparing'
    END AS ad_removal_state,
    CASE
        WHEN j.stage = 'failed' THEN 'retry'
        WHEN j.id IS NULL OR j.stage = 'cancelled' THEN 'prepare'
        ELSE NULL
    END AS ad_removal_action,
    j.stage AS ad_removal_stage,
    j.blocking_reason AS ad_removal_blocking_reason
    FROM episodes e
    JOIN podcasts p ON p.id = e.podcast_id
    LEFT JOIN episode_state s ON s.episode_id = e.id
    LEFT JOIN ad_removal_jobs j ON j.episode_id = e.id
    """

    private static let inListenPredicate = """
    (p.is_subscribed = 1 OR EXISTS (SELECT 1 FROM follow_episodes fe WHERE fe.episode_id = e.id))
    """

    private static let showSelect = """
    SELECT p.id, p.feed_url, p.title, p.description, p.image_url, p.site_url,
    (SELECT COUNT(*) FROM episodes e WHERE e.podcast_id = p.id) AS episode_count,
    (SELECT COUNT(*) FROM episodes e LEFT JOIN episode_state s ON s.episode_id = e.id
        WHERE e.podcast_id = p.id AND s.played_at IS NULL AND s.archived_at IS NULL) AS unplayed_count
    FROM podcasts p
    """

    private static func mapEpisodeItem(_ statement: OpaquePointer?) -> EpisodeItem {
        EpisodeItem(
            id: sqlite3_column_int64(statement, 0),
            podcast_id: sqlite3_column_int64(statement, 1),
            podcast_title: sqliteString(statement, 2),
            podcast_image: sqliteString(statement, 3),
            title: sqliteString(statement, 4),
            audio_url: sqliteString(statement, 5),
            duration_secs: sqliteOptionalInt64(statement, 6),
            published_at: sqlite3_column_int64(statement, 7),
            image_url: sqliteString(statement, 8),
            position_secs: sqlite3_column_double(statement, 9),
            played_at: sqliteOptionalInt64(statement, 10),
            ad_removal_state: sqliteString(statement, 11),
            ad_removal_action: sqliteOptionalString(statement, 12),
            ad_removal_stage: sqliteOptionalString(statement, 13),
            ad_removal_blocking_reason: sqliteOptionalString(statement, 14)
        )
    }

    private static func mapEpisodeDetail(_ statement: OpaquePointer?) -> EpisodeDetail {
        EpisodeDetail(
            id: sqlite3_column_int64(statement, 0),
            podcast_id: sqlite3_column_int64(statement, 1),
            podcast_title: sqliteString(statement, 2),
            podcast_image: sqliteString(statement, 3),
            title: sqliteString(statement, 4),
            audio_url: sqliteString(statement, 5),
            duration_secs: sqliteOptionalInt64(statement, 6),
            published_at: sqlite3_column_int64(statement, 7),
            image_url: sqliteString(statement, 8),
            position_secs: sqlite3_column_double(statement, 9),
            played_at: sqliteOptionalInt64(statement, 10),
            notes_html: sqliteString(statement, 11),
            archived_at: sqliteOptionalInt64(statement, 12),
            ad_removal_state: sqliteString(statement, 13),
            ad_removal_action: sqliteOptionalString(statement, 14),
            ad_removal_stage: sqliteOptionalString(statement, 15),
            ad_removal_blocking_reason: sqliteOptionalString(statement, 16)
        )
    }

    private static func mapShow(_ statement: OpaquePointer?) -> Show {
        Show(
            id: sqlite3_column_int64(statement, 0),
            feed_url: sqliteString(statement, 1),
            title: sqliteString(statement, 2),
            description: sqliteString(statement, 3),
            image_url: sqliteString(statement, 4),
            site_url: sqliteString(statement, 5),
            episode_count: sqlite3_column_int64(statement, 6),
            unplayed_count: sqlite3_column_int64(statement, 7)
        )
    }

    private static func mapFollow(_ statement: OpaquePointer?) -> Follow {
        let aliases = (try? JSONDecoder().decode([String].self, from: Data(sqliteString(statement, 2).utf8))) ?? []
        return Follow(
            id: sqlite3_column_int64(statement, 0),
            name: sqliteString(statement, 1),
            aliases: aliases,
            last_checked_at: sqliteOptionalInt64(statement, 3),
            pending_count: sqlite3_column_int64(statement, 4),
            accepted_count: sqlite3_column_int64(statement, 5)
        )
    }

    private static func mapFollowCandidate(_ statement: OpaquePointer?) -> FollowCandidate {
        FollowCandidate(
            id: sqlite3_column_int64(statement, 0),
            follow_id: sqlite3_column_int64(statement, 1),
            appearance: DirectoryAppearance(
                source_episode_key: sqliteString(statement, 2),
                feed_url: sqliteString(statement, 3),
                feed_title: sqliteString(statement, 4),
                feed_image_url: sqliteString(statement, 5),
                guid: sqliteString(statement, 6),
                title: sqliteString(statement, 7),
                description: sqliteString(statement, 8),
                audio_url: sqliteString(statement, 9),
                duration_secs: sqliteOptionalInt64(statement, 10),
                published_at: sqlite3_column_int64(statement, 11),
                image_url: sqliteString(statement, 12),
                evidence: sqliteString(statement, 13),
                confidence: sqliteString(statement, 14)
            )
        )
    }

    private static func cleanAliases(_ rawAliases: [String], name: String) -> [String] {
        var seen = Set<String>()
        return rawAliases.compactMap { alias in
            let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2, value.caseInsensitiveCompare(name) != .orderedSame else { return nil }
            guard seen.insert(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted else { return nil }
            return value
        }
    }
}

private extension HTTPRequest {
    var offset: Int64 {
        max(0, Int64(query("offset") ?? "0") ?? 0)
    }

    func jsonObject() throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: body)
        guard let object = value as? [String: Any] else {
            throw PodsBackendError.invalid("expected JSON object")
        }
        return object
    }
}
