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

struct DeepSeekAPIUsage: Equatable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int

    /// Reads DeepSeek/OpenAI-compatible `usage` from a chat-completion body.
    /// Returns nil when the response has no usable token counts.
    static func parse(from root: [String: Any]) -> DeepSeekAPIUsage? {
        guard let usage = root["usage"] as? [String: Any] else { return nil }
        let input = intValue(usage["prompt_tokens"])
        let output = intValue(usage["completion_tokens"])
        guard input != nil || output != nil else { return nil }

        let cachedField = intValue(usage["prompt_cache_hit_tokens"])
        let cachedDetails = (usage["prompt_tokens_details"] as? [String: Any])
            .flatMap { intValue($0["cached_tokens"]) }
        let rawCached = cachedField ?? cachedDetails ?? 0
        let inputTokens = max(0, input ?? 0)
        let cached = min(max(0, rawCached), inputTokens)
        return DeepSeekAPIUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cached,
            outputTokens: max(0, output ?? 0)
        )
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let value = raw as? Int {
            return value
        }
        if let value = raw as? Int64 {
            return Int(value)
        }
        if let value = raw as? Double {
            return Int(value)
        }
        return nil
    }
}

struct DeepSeekUsageRecord: Equatable {
    let id: Int64
    let episodeID: Int64
    let requestKind: DeepSeekRequestKind
    let model: String
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let costUSD: Double
    let createdAt: Int64
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
        let uncached = Double(max(0, usage.inputTokens - usage.cachedInputTokens))
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
        usage: DeepSeekAPIUsage,
        createdAt: Date
    ) throws
}

enum DeepSeekUsageRecorder {
    /// Writes one immutable usage row when the response includes token counts.
    /// Failures are swallowed so telemetry cannot break model calls.
    static func recordIfPresent(
        store: DeepSeekUsageRecording?,
        requestKind: DeepSeekRequestKind,
        model: String,
        root: [String: Any],
        createdAt: Date = Date()
    ) {
        guard let store else { return }
        guard let episodeID = DeepSeekUsageAttribution.episodeID else { return }
        guard let usage = DeepSeekAPIUsage.parse(from: root) else { return }
        do {
            try store.record(
                episodeID: episodeID,
                requestKind: requestKind,
                model: model,
                usage: usage,
                createdAt: createdAt
            )
        } catch {
            // Billing telemetry is best-effort.
        }
    }
}

final class DeepSeekUsageStore: DeepSeekUsageRecording {
    private let database: PodsDatabase

    init(database: PodsDatabase) {
        self.database = database
    }

    func record(
        episodeID: Int64,
        requestKind: DeepSeekRequestKind,
        model: String,
        usage: DeepSeekAPIUsage,
        createdAt: Date = Date()
    ) throws {
        let cost = DeepSeekPricing.costUSD(model: model, usage: usage, at: createdAt)
        try database.execute(
            """
            INSERT INTO deepseek_usage (
                episode_id, request_kind, model,
                input_tokens, cached_input_tokens, output_tokens,
                cost_usd, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .int(episodeID),
                .text(requestKind.rawValue),
                .text(model),
                .int(Int64(usage.inputTokens)),
                .int(Int64(usage.cachedInputTokens)),
                .int(Int64(usage.outputTokens)),
                .double(cost),
                .int(Int64(createdAt.timeIntervalSince1970))
            ]
        )
    }

    func records(episodeID: Int64? = nil) throws -> [DeepSeekUsageRecord] {
        let sql: String
        let values: [SQLiteValue]
        if let episodeID {
            sql = """
                SELECT id, episode_id, request_kind, model,
                       input_tokens, cached_input_tokens, output_tokens,
                       cost_usd, created_at
                FROM deepseek_usage
                WHERE episode_id = ?
                ORDER BY id
                """
            values = [.int(episodeID)]
        } else {
            sql = """
                SELECT id, episode_id, request_kind, model,
                       input_tokens, cached_input_tokens, output_tokens,
                       cost_usd, created_at
                FROM deepseek_usage
                ORDER BY id
                """
            values = []
        }
        return try database.query(sql, values) { statement in
            DeepSeekUsageRecord(
                id: sqlite3_column_int64(statement, 0),
                episodeID: sqlite3_column_int64(statement, 1),
                requestKind: DeepSeekRequestKind(rawValue: sqliteString(statement, 2)) ?? .adDetection,
                model: sqliteString(statement, 3),
                inputTokens: Int(sqlite3_column_int64(statement, 4)),
                cachedInputTokens: Int(sqlite3_column_int64(statement, 5)),
                outputTokens: Int(sqlite3_column_int64(statement, 6)),
                costUSD: sqlite3_column_double(statement, 7),
                createdAt: sqlite3_column_int64(statement, 8)
            )
        }
    }

    func episodeTotalCost(episodeID: Int64) throws -> Double {
        try database.query(
            "SELECT COALESCE(SUM(cost_usd), 0) FROM deepseek_usage WHERE episode_id = ?",
            [.int(episodeID)]
        ) { sqlite3_column_double($0, 0) }.first ?? 0
    }

    func metrics() throws -> DeepSeekUsageMetricsPayload {
        let totals = try database.query(
            """
            SELECT
                COALESCE(SUM(cost_usd), 0),
                COALESCE(SUM(CASE WHEN request_kind = 'ad_detection' THEN cost_usd ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN request_kind = 'show_notes' THEN cost_usd ELSE 0 END), 0),
                COUNT(DISTINCT episode_id)
            FROM deepseek_usage
            """
        ) { statement in
            (
                sqlite3_column_double(statement, 0),
                sqlite3_column_double(statement, 1),
                sqlite3_column_double(statement, 2),
                sqlite3_column_int64(statement, 3)
            )
        }.first ?? (0, 0, 0, 0)

        let averagePerEpisode = totals.3 > 0 ? totals.0 / Double(totals.3) : nil

        let perMinute = try database.query(
            """
            SELECT COALESCE(SUM(episode_cost), 0), COALESCE(SUM(duration_secs), 0)
            FROM (
                SELECT
                    u.episode_id AS episode_id,
                    SUM(u.cost_usd) AS episode_cost,
                    COALESCE(
                        e.duration_secs,
                        (
                            SELECT CAST(MAX(s.end_time) AS INTEGER)
                            FROM ad_transcript_segments s
                            WHERE s.episode_id = u.episode_id
                        )
                    ) AS duration_secs
                FROM deepseek_usage u
                LEFT JOIN episodes e ON e.id = u.episode_id
                GROUP BY u.episode_id
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
            show_notes_cost_usd: totals.2
        )
    }
}
