import Foundation
import SQLite3

enum DeepSeekRequestKind: String, Equatable {
    case adDetection = "ad_detection"
    case showNotes = "show_notes"
}

/// Task-local episode attribution for DeepSeek telemetry.
///
/// Classification and show-note generation stay on their existing protocols;
/// the pipeline and show-notes service bind the episode before the HTTP call.
enum DeepSeekUsageAttribution {
    @TaskLocal static var episodeID: Int64?
}

enum DeepSeekAPIUsageParseResult: Equatable {
    case absent
    case invalid
    case valid(DeepSeekAPIUsage)
}

struct DeepSeekAPIUsage: Equatable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int

    /// Reads DeepSeek/OpenAI-compatible `usage` from a chat-completion body.
    static func parse(from root: [String: Any]) -> DeepSeekAPIUsageParseResult {
        guard let usage = root["usage"] as? [String: Any] else { return .absent }
        guard let inputTokens = exactNonNegativeInt(usage["prompt_tokens"]),
              let outputTokens = exactNonNegativeInt(usage["completion_tokens"]),
              let cachedInputTokens = cachedInputTokens(from: usage, inputTokens: inputTokens) else {
            return .invalid
        }
        return .valid(
            DeepSeekAPIUsage(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens
            )
        )
    }

    private static func cachedInputTokens(from usage: [String: Any], inputTokens: Int) -> Int? {
        let hit = exactNonNegativeInt(usage["prompt_cache_hit_tokens"])
        let nested = (usage["prompt_tokens_details"] as? [String: Any])
            .flatMap { exactNonNegativeInt($0["cached_tokens"]) }
        let cached: Int
        switch (hit, nested) {
        case let (hit?, nested?) where hit == nested:
            cached = hit
        case let (hit?, nil):
            cached = hit
        case let (nil, nested?):
            cached = nested
        default:
            return nil
        }
        guard cached <= inputTokens else { return nil }
        if let miss = exactNonNegativeInt(usage["prompt_cache_miss_tokens"]),
           cached + miss != inputTokens {
            return nil
        }
        return cached
    }

    /// Accepts only exact non-negative integers. Bools, fractions, and overflow are rejected.
    static func exactNonNegativeInt(_ raw: Any?) -> Int? {
        if raw is Bool { return nil }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite,
                  doubleValue >= 0,
                  doubleValue == doubleValue.rounded(.towardZero) else {
                return nil
            }
            let intValue = number.intValue
            guard Double(intValue) == doubleValue else { return nil }
            return intValue
        }
        if let value = raw as? Int {
            return value >= 0 ? value : nil
        }
        if let value = raw as? Int64 {
            return value >= 0 ? Int(value) : nil
        }
        return nil
    }
}

struct DeepSeekUsageRecord: Equatable {
    let id: Int64
    let episodeID: Int64
    let episodeKey: String
    let durationSecs: Int64?
    let requestKind: DeepSeekRequestKind
    let model: String
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let costUSD: Double?
    let createdAt: Int64
}

struct DeepSeekUsagePendingRecord: Codable, Equatable {
    let episode_id: Int64
    let episode_key: String
    let duration_secs: Int64?
    let request_kind: String
    let model: String
    let input_tokens: Int?
    let cached_input_tokens: Int?
    let output_tokens: Int?
    let cost_usd: Double?
    let created_at: Int64
}

/// Published DeepSeek chat rates in effect on and after 16 August 2026.
///
/// Peak hours are 01:00–04:00 and 06:00–10:00 UTC, Monday–Friday.
/// Off-peak rates are half of peak. Source: https://api-docs.deepseek.com/quick_start/pricing/
enum DeepSeekPricing {
    struct Rates: Equatable {
        let cacheMissPerMillion: Double
        let cacheHitPerMillion: Double
        let outputPerMillion: Double
    }

    static func isPeak(at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 || weekday == 7 {
            return false
        }
        let hour = calendar.component(.hour, from: date)
        return (hour >= 1 && hour < 4) || (hour >= 6 && hour < 10)
    }

    static func rates(model: String, at date: Date) -> Rates {
        let peak = isPeak(at: date)
        switch model {
        case "deepseek-v4-flash", "deepseek-v4-flash-vision-exp":
            return peak
                ? Rates(cacheMissPerMillion: 0.44, cacheHitPerMillion: 0.014, outputPerMillion: 1.32)
                : Rates(cacheMissPerMillion: 0.22, cacheHitPerMillion: 0.007, outputPerMillion: 0.66)
        default:
            return peak
                ? Rates(cacheMissPerMillion: 1.32, cacheHitPerMillion: 0.044, outputPerMillion: 3.96)
                : Rates(cacheMissPerMillion: 0.66, cacheHitPerMillion: 0.022, outputPerMillion: 1.98)
        }
    }

    static func costUSD(model: String, usage: DeepSeekAPIUsage, at date: Date) -> Double {
        let rates = rates(model: model, at: date)
        let cached = Double(usage.cachedInputTokens)
        let uncached = Double(usage.inputTokens - usage.cachedInputTokens)
        let output = Double(usage.outputTokens)
        return (uncached * rates.cacheMissPerMillion
            + cached * rates.cacheHitPerMillion
            + output * rates.outputPerMillion) / 1_000_000
    }
}

protocol DeepSeekUsageRecording: AnyObject {
    func record(
        episodeID: Int64,
        requestKind: DeepSeekRequestKind,
        model: String,
        usage: DeepSeekAPIUsage?,
        createdAt: Date
    ) throws
}

enum DeepSeekUsageRecorder {
    /// Writes one immutable usage row when the response includes a `usage` object.
    /// Invalid usage is stored as unpriced. Persistence failures never fail the model call.
    static func recordIfPresent(
        store: DeepSeekUsageRecording?,
        requestKind: DeepSeekRequestKind,
        model: String,
        root: [String: Any],
        createdAt: Date = Date()
    ) {
        guard let store else { return }
        guard let episodeID = DeepSeekUsageAttribution.episodeID else { return }
        let usage: DeepSeekAPIUsage?
        switch DeepSeekAPIUsage.parse(from: root) {
        case .absent:
            return
        case .invalid:
            usage = nil
        case .valid(let parsed):
            usage = parsed
        }
        do {
            try store.record(
                episodeID: episodeID,
                requestKind: requestKind,
                model: model,
                usage: usage,
                createdAt: createdAt
            )
        } catch {
            // The store already attempted a durable fallback. Model work must continue.
        }
    }
}

protocol DeepSeekUsageLedging: AnyObject {
    func append(_ record: DeepSeekUsagePendingRecord) throws
    func load() throws -> [DeepSeekUsagePendingRecord]
    func replace(_ records: [DeepSeekUsagePendingRecord]) throws
}

final class DeepSeekUsageFileLedger: DeepSeekUsageLedging {
    let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func append(_ record: DeepSeekUsagePendingRecord) throws {
        let line = try JSONEncoder().encode(record) + Data([0x0A])
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try line.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    func load() throws -> [DeepSeekUsagePendingRecord] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return try JSONDecoder().decode(DeepSeekUsagePendingRecord.self, from: Data(trimmed.utf8))
        }
    }

    func replace(_ records: [DeepSeekUsagePendingRecord]) throws {
        if records.isEmpty {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        let data = try records.reduce(into: Data()) { data, record in
            data.append(try JSONEncoder().encode(record))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }
}

final class DeepSeekUsageStore: DeepSeekUsageRecording {
    static let incompleteSettingsKey = "deepseek_usage_incomplete"
    static let fallbackFileName = "deepseek-usage-fallback.jsonl"

    private let database: PodsDatabase
    private let ledger: DeepSeekUsageLedging?
    private let lock = NSLock()

    /// Test seam: the next `record` insert into SQLite fails once.
    var failNextInsert = false

    init(database: PodsDatabase, ledger: DeepSeekUsageLedging? = nil) {
        self.database = database
        self.ledger = ledger
    }

    convenience init(database: PodsDatabase, fallbackURL: URL) {
        self.init(database: database, ledger: DeepSeekUsageFileLedger(url: fallbackURL))
    }

    static func applicationDefaultFallbackURL() throws -> URL {
        try DatabaseBootstrap.applicationSupportDirectory().appendingPathComponent(fallbackFileName)
    }

    func record(
        episodeID: Int64,
        requestKind: DeepSeekRequestKind,
        model: String,
        usage: DeepSeekAPIUsage?,
        createdAt: Date = Date()
    ) throws {
        let identity = resolveIdentity(episodeID: episodeID)
        let pending = DeepSeekUsagePendingRecord(
            episode_id: episodeID,
            episode_key: identity.episodeKey,
            duration_secs: identity.durationSecs,
            request_kind: requestKind.rawValue,
            model: model,
            input_tokens: usage.map(\.inputTokens),
            cached_input_tokens: usage.map(\.cachedInputTokens),
            output_tokens: usage.map(\.outputTokens),
            cost_usd: usage.map { DeepSeekPricing.costUSD(model: model, usage: $0, at: createdAt) },
            created_at: Int64(createdAt.timeIntervalSince1970)
        )
        do {
            try insert(pending)
        } catch {
            do {
                guard let ledger else { throw error }
                try ledger.append(pending)
            } catch {
                try? markIncomplete()
                throw error
            }
        }
    }

    func records(episodeID: Int64? = nil) throws -> [DeepSeekUsageRecord] {
        try reconcileLedger()
        let sql: String
        let values: [SQLiteValue]
        if let episodeID {
            sql = """
                SELECT id, episode_id, episode_key, duration_secs, request_kind, model,
                       input_tokens, cached_input_tokens, output_tokens,
                       cost_usd, created_at
                FROM deepseek_usage
                WHERE episode_id = ?
                ORDER BY id
                """
            values = [.int(episodeID)]
        } else {
            sql = """
                SELECT id, episode_id, episode_key, duration_secs, request_kind, model,
                       input_tokens, cached_input_tokens, output_tokens,
                       cost_usd, created_at
                FROM deepseek_usage
                ORDER BY id
                """
            values = []
        }
        return try database.query(sql, values, map: Self.mapRecord)
    }

    func episodeTotalCost(episodeID: Int64) throws -> Double {
        try reconcileLedger()
        let key = resolveIdentity(episodeID: episodeID).episodeKey
        return try database.query(
            """
            SELECT COALESCE(SUM(cost_usd), 0)
            FROM deepseek_usage
            WHERE episode_key = ?
            """,
            [.text(key)]
        ) { sqlite3_column_double($0, 0) }.first ?? 0
    }

    func metrics() throws -> DeepSeekUsageMetricsPayload {
        try reconcileLedger()
        let leftover: Int
        do {
            leftover = try ledger?.load().count ?? 0
        } catch {
            leftover = 1
        }
        let totals = try database.query(
            """
            SELECT
                COALESCE(SUM(CASE WHEN cost_usd IS NOT NULL THEN cost_usd END), 0),
                COALESCE(SUM(CASE WHEN request_kind = 'ad_detection' THEN cost_usd ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN request_kind = 'show_notes' THEN cost_usd ELSE 0 END), 0),
                COUNT(DISTINCT CASE WHEN cost_usd IS NOT NULL THEN episode_key END),
                COALESCE(SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END), 0)
            FROM deepseek_usage
            """
        ) { statement in
            (
                sqlite3_column_double(statement, 0),
                sqlite3_column_double(statement, 1),
                sqlite3_column_double(statement, 2),
                sqlite3_column_int64(statement, 3),
                sqlite3_column_int64(statement, 4)
            )
        }.first ?? (0, 0, 0, 0, 0)

        let averagePerEpisode = totals.3 > 0 ? totals.0 / Double(totals.3) : nil

        let perMinute = try database.query(
            """
            SELECT COALESCE(SUM(episode_cost), 0), COALESCE(SUM(duration_secs), 0)
            FROM (
                SELECT
                    episode_key,
                    SUM(cost_usd) AS episode_cost,
                    MAX(duration_secs) AS duration_secs
                FROM deepseek_usage
                WHERE cost_usd IS NOT NULL
                GROUP BY episode_key
            )
            WHERE duration_secs IS NOT NULL AND duration_secs > 0
            """
        ) { statement in
            (sqlite3_column_double(statement, 0), sqlite3_column_int64(statement, 1))
        }.first ?? (0, 0)

        let averagePerMinute: Double?
        if perMinute.1 > 0 {
            averagePerMinute = perMinute.0 / (Double(perMinute.1) / 60.0)
        } else {
            averagePerMinute = nil
        }

        return DeepSeekUsageMetricsPayload(
            total_cost_usd: totals.0,
            average_cost_per_episode_usd: averagePerEpisode,
            average_cost_per_podcast_minute_usd: averagePerMinute,
            ad_detection_cost_usd: totals.1,
            show_notes_cost_usd: totals.2,
            telemetry_complete: leftover == 0 && totals.4 == 0 && !incompleteFlag
        )
    }

    private var incompleteFlag: Bool {
        (try? database.query(
            "SELECT value FROM settings WHERE key = ?",
            [.text(Self.incompleteSettingsKey)]
        ) { sqliteString($0, 0) }.first) == "true"
    }

    private func insert(_ record: DeepSeekUsagePendingRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        if failNextInsert {
            failNextInsert = false
            throw PodsBackendError.database("deepseek usage insert failed")
        }
        try database.execute(
            """
            INSERT INTO deepseek_usage (
                episode_id, episode_key, duration_secs, request_kind, model,
                input_tokens, cached_input_tokens, output_tokens,
                cost_usd, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .int(record.episode_id),
                .text(record.episode_key),
                record.duration_secs.map { .int($0) } ?? .null,
                .text(record.request_kind),
                .text(record.model),
                record.input_tokens.map { .int(Int64($0)) } ?? .null,
                record.cached_input_tokens.map { .int(Int64($0)) } ?? .null,
                record.output_tokens.map { .int(Int64($0)) } ?? .null,
                record.cost_usd.map { .double($0) } ?? .null,
                .int(record.created_at)
            ]
        )
    }

    private func reconcileLedger() throws {
        guard let ledger else { return }
        let pending: [DeepSeekUsagePendingRecord]
        do {
            pending = try ledger.load()
        } catch {
            try markIncomplete()
            return
        }
        guard !pending.isEmpty else { return }
        var remaining: [DeepSeekUsagePendingRecord] = []
        for record in pending {
            do {
                try insert(record)
            } catch {
                remaining.append(record)
            }
        }
        do {
            try ledger.replace(remaining)
        } catch {
            try markIncomplete()
            return
        }
        if !remaining.isEmpty {
            try markIncomplete()
        }
    }

    private func markIncomplete() throws {
        try database.execute(
            """
            INSERT INTO settings (key, value) VALUES (?, 'true')
            ON CONFLICT(key) DO UPDATE SET value = 'true'
            """,
            [.text(Self.incompleteSettingsKey)]
        )
    }

    private struct EpisodeIdentity {
        let episodeKey: String
        let durationSecs: Int64?
    }

    private func resolveIdentity(episodeID: Int64) -> EpisodeIdentity {
        let row = try? database.query(
            """
            SELECT p.feed_url, e.guid, e.duration_secs
            FROM episodes e
            JOIN podcasts p ON p.id = e.podcast_id
            WHERE e.id = ?
            """,
            [.int(episodeID)]
        ) { statement in
            (
                sqliteString(statement, 0),
                sqliteString(statement, 1),
                sqliteOptionalInt64(statement, 2)
            )
        }.first
        let transcriptDuration = (try? database.query(
            """
            SELECT CAST(MAX(end_time) AS INTEGER)
            FROM ad_transcript_segments
            WHERE episode_id = ?
            """,
            [.int(episodeID)]
        ) { sqliteOptionalInt64($0, 0) }.first) ?? nil
        guard let row else {
            return EpisodeIdentity(
                episodeKey: "episode-id:\(episodeID)",
                durationSecs: transcriptDuration.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        let duration = row.2.flatMap { $0 > 0 ? $0 : nil }
            ?? transcriptDuration.flatMap { $0 > 0 ? $0 : nil }
        return EpisodeIdentity(
            episodeKey: Self.episodeKey(feedURL: row.0, guid: row.1),
            durationSecs: duration
        )
    }

    static func episodeKey(feedURL: String, guid: String) -> String {
        "\(feedURL)\u{1F}\(guid)"
    }

    private static func mapRecord(_ statement: OpaquePointer?) -> DeepSeekUsageRecord {
        DeepSeekUsageRecord(
            id: sqlite3_column_int64(statement, 0),
            episodeID: sqlite3_column_int64(statement, 1),
            episodeKey: sqliteString(statement, 2),
            durationSecs: sqliteOptionalInt64(statement, 3),
            requestKind: DeepSeekRequestKind(rawValue: sqliteString(statement, 4)) ?? .adDetection,
            model: sqliteString(statement, 5),
            inputTokens: sqliteOptionalInt64(statement, 6).map(Int.init),
            cachedInputTokens: sqliteOptionalInt64(statement, 7).map(Int.init),
            outputTokens: sqliteOptionalInt64(statement, 8).map(Int.init),
            costUSD: sqlite3_column_type(statement, 9) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 9),
            createdAt: sqlite3_column_int64(statement, 10)
        )
    }
}
