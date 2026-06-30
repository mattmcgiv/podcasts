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

final class PodsBackend {
    private let database: PodsDatabase
    private let feedFetcher: FeedFetching

    init(database: PodsDatabase, feedFetcher: FeedFetching = URLSessionFeedFetcher()) {
        self.database = database
        self.feedFetcher = feedFetcher
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            if request.method == "OPTIONS" {
                return HTTPResponse.noContent()
            }
            guard request.path.hasPrefix("/api") else {
                throw PodsBackendError.notFound
            }
            return try await route(request)
        } catch let error as PodsBackendError {
            return HTTPResponse.error(error)
        } catch {
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
        if parts.count == 4, parts[0] == "api", parts[1] == "episodes", parts[3] == "played", let id = Int64(parts[2]) {
            if request.method == "POST" {
                try setPlayed(id: id)
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
        if path == "/api/refresh", request.method == "POST" {
            return .json(await refreshAll())
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
            return .json(try search(query: query))
        }
        if path == "/api/opml", request.method == "GET" {
            return .text(try exportOPML(), contentType: "text/xml; charset=utf-8")
        }
        if path == "/api/opml", request.method == "POST" {
            return .json(try await importOPML(request.bodyString))
        }
        throw PodsBackendError.notFound
    }

    private func recent(offset: Int64) throws -> Page<EpisodeItem> {
        let rows = try database.query(
            "\(Self.episodeItemSelect) WHERE s.played_at IS NULL AND s.archived_at IS NULL ORDER BY e.published_at DESC, e.id DESC LIMIT ? OFFSET ?",
            [.int(podsPageSize + 1), .int(offset)],
            map: Self.mapEpisodeItem
        )
        return paginate(rows, offset: offset)
    }

    private func played(offset: Int64) throws -> Page<EpisodeItem> {
        let rows = try database.query(
            "\(Self.episodeItemSelect) WHERE s.played_at IS NOT NULL ORDER BY s.played_at DESC, e.id DESC LIMIT ? OFFSET ?",
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
        try database.query("\(Self.showSelect) ORDER BY p.title COLLATE NOCASE, p.id", map: Self.mapShow)
    }

    private func fetchShow(id: Int64) throws -> Show {
        guard let show = try database.query("\(Self.showSelect) WHERE p.id = ?", [.int(id)], map: Self.mapShow).first else {
            throw PodsBackendError.notFound
        }
        return show
    }

    private func subscribe(feedURL rawURL: String) async throws -> Show {
        let feedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: feedURL), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw PodsBackendError.invalid("feed_url must be an http(s) URL")
        }
        if try database.scalarInt64("SELECT id FROM podcasts WHERE feed_url = ?", [.text(feedURL)]) != nil {
            throw PodsBackendError.conflict("already subscribed")
        }

        let feed = try RSSParser.parse(try await feedFetcher.data(for: url))
        let podcastID = try database.withTransaction { () -> Int64 in
            try database.execute("INSERT INTO podcasts (feed_url, created_at) VALUES (?, ?)", [.text(feedURL), .int(nowUnix())])
            let podcastID = database.lastInsertRowID()
            try upsertPodcastMeta(podcastID: podcastID, feed: feed)
            try upsertEpisodes(podcastID: podcastID, feed: feed)
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
            return podcastID
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
            try database.execute("DELETE FROM episodes_fts WHERE rowid IN (SELECT id FROM episodes WHERE podcast_id = ?)", [.int(id)])
            try database.execute("DELETE FROM podcasts WHERE id = ?", [.int(id)])
        }
    }

    private func episodeDetail(id: Int64) throws -> EpisodeDetail {
        let sql = """
        SELECT e.id, e.podcast_id, p.title AS podcast_title, p.image_url AS podcast_image,
        e.title, e.audio_url, e.duration_secs, e.published_at, e.image_url,
        CAST(COALESCE(s.position_secs, 0) AS REAL) AS position_secs, s.played_at,
        e.notes_html, s.archived_at
        FROM episodes e JOIN podcasts p ON p.id = e.podcast_id
        LEFT JOIN episode_state s ON s.episode_id = e.id WHERE e.id = ?
        """
        guard let detail = try database.query(sql, [.int(id)], map: Self.mapEpisodeDetail).first else {
            throw PodsBackendError.notFound
        }
        return detail
    }

    private func episodeExists(id: Int64) throws {
        guard try database.scalarInt64("SELECT id FROM episodes WHERE id = ?", [.int(id)]) != nil else {
            throw PodsBackendError.notFound
        }
    }

    private func setPlayed(id: Int64) throws {
        try episodeExists(id: id)
        let ts = nowUnix()
        try database.execute(
            """
            INSERT INTO episode_state (episode_id, played_at, updated_at) VALUES (?, ?, ?)
            ON CONFLICT (episode_id) DO UPDATE SET played_at = excluded.played_at, updated_at = excluded.updated_at
            """,
            [.int(id), .int(ts), .int(ts)]
        )
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
            sql = "\(Self.episodeItemSelect) WHERE s.played_at IS NULL AND s.archived_at IS NULL AND (e.published_at < ?1 OR (e.published_at = ?1 AND e.id < ?2)) AND ?3 = ?3 ORDER BY e.published_at DESC, e.id DESC LIMIT 1"
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
            rows = try database.query("SELECT id, feed_url FROM podcasts ORDER BY id") { statement in
                (sqlite3_column_int64(statement, 0), sqliteString(statement, 1))
            }
        } catch {
            return RefreshResult(refreshed: 0, errors: 0)
        }
        var ok = 0
        var errors = 0
        for row in rows {
            do {
                try await refreshOne(podcastID: row.0, feedURL: row.1)
                ok += 1
            } catch {
                errors += 1
            }
        }
        return RefreshResult(refreshed: ok, errors: errors)
    }

    private func refreshOne(podcastID: Int64, feedURL: String) async throws {
        guard let url = URL(string: feedURL) else {
            throw PodsBackendError.invalid("feed_url must be an http(s) URL")
        }
        let feed = try RSSParser.parse(try await feedFetcher.data(for: url))
        try database.withTransaction {
            try upsertPodcastMeta(podcastID: podcastID, feed: feed)
            try upsertEpisodes(podcastID: podcastID, feed: feed)
        }
    }

    private func search(query rawQuery: String) throws -> SearchResults {
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
        return SearchResults(directory_configured: false, podcasts: [], episodes: episodes)
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
    CAST(COALESCE(s.position_secs, 0) AS REAL) AS position_secs, s.played_at
    FROM episodes e
    JOIN podcasts p ON p.id = e.podcast_id
    LEFT JOIN episode_state s ON s.episode_id = e.id
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
            played_at: sqliteOptionalInt64(statement, 10)
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
            archived_at: sqliteOptionalInt64(statement, 12)
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
