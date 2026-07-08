import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseBootstrap {
    static let databaseFileName = "pods.sqlite"
    static let seedFileName = "pods-seed"
    static let seedExtension = "sqlite"

    static func applicationSupportDirectory() throws -> URL {
        let url = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Pods", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func liveDatabaseURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent(databaseFileName)
    }

    @discardableResult
    static func prepare(fileManager: FileManager = .default, bundle: Bundle = .main) throws -> URL {
        let liveURL = try liveDatabaseURL()
        let seedURL = bundle.url(forResource: seedFileName, withExtension: seedExtension, subdirectory: "SeedData")
        PodsDebugLog("Database bootstrap live=\(liveURL.path) seed=\(seedURL?.path ?? "none")")
        return try prepare(liveURL: liveURL, seedURL: seedURL, fileManager: fileManager)
    }

    @discardableResult
    static func prepare(liveURL: URL, seedURL: URL?, fileManager: FileManager = .default) throws -> URL {
        if !fileManager.fileExists(atPath: liveURL.path) {
            if let seedURL {
                PodsDebugLog("Database bootstrap copying seed database")
                try fileManager.copyItem(at: seedURL, to: liveURL)
            } else {
                PodsDebugLog("Database bootstrap has no live database and no seed; schema will be created")
            }
        }
        if fileManager.fileExists(atPath: liveURL.path) {
            do {
                try validateSchema(at: liveURL)
                if try shouldReplaceEmptyLiveDatabase(liveURL: liveURL, seedURL: seedURL) {
                    PodsLog("Pods database is empty; restoring bundled seed database")
                    try replaceDatabase(at: liveURL, with: seedURL, fileManager: fileManager)
                    try validateSchema(at: liveURL)
                }
            } catch {
                if let seedURL {
                    PodsLog("Pods database is invalid; restoring bundled seed database")
                    try replaceDatabase(at: liveURL, with: seedURL, fileManager: fileManager)
                    try validateSchema(at: liveURL)
                } else {
                    throw error
                }
            }
        }
        return liveURL
    }

    static func validateSchema(at url: URL) throws {
        var db: OpaquePointer?
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            defer { sqlite3_close(db) }
            throw BootstrapError.openFailed
        }
        defer { sqlite3_close(db) }

        let requiredTables = ["podcasts", "episodes", "episode_state", "settings", "episodes_fts"]
        for table in requiredTables {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT name FROM sqlite_master WHERE name = ? LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw BootstrapError.schemaInvalid
            }
            sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw BootstrapError.missingTable(table)
            }
        }
    }

    private static func shouldReplaceEmptyLiveDatabase(liveURL: URL, seedURL: URL?) throws -> Bool {
        guard let seedURL else {
            return false
        }
        return try podcastCount(at: liveURL) == 0 && podcastCount(at: seedURL) > 0
    }

    private static func replaceDatabase(at liveURL: URL, with seedURL: URL?, fileManager: FileManager) throws {
        guard let seedURL else {
            return
        }
        for url in sidecarURLs(for: liveURL) {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        try fileManager.copyItem(at: seedURL, to: liveURL)
        let seedWAL = URL(fileURLWithPath: seedURL.path + "-wal")
        let seedSHM = URL(fileURLWithPath: seedURL.path + "-shm")
        if fileManager.fileExists(atPath: seedWAL.path) {
            try fileManager.copyItem(at: seedWAL, to: URL(fileURLWithPath: liveURL.path + "-wal"))
        }
        if fileManager.fileExists(atPath: seedSHM.path) {
            try fileManager.copyItem(at: seedSHM, to: URL(fileURLWithPath: liveURL.path + "-shm"))
        }
    }

    private static func sidecarURLs(for url: URL) -> [URL] {
        [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm")
        ]
    }

    private static func podcastCount(at url: URL) throws -> Int64 {
        var db: OpaquePointer?
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            defer { sqlite3_close(db) }
            throw BootstrapError.openFailed
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM podcasts", -1, &statement, nil) == SQLITE_OK else {
            throw BootstrapError.schemaInvalid
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw BootstrapError.schemaInvalid
        }
        return sqlite3_column_int64(statement, 0)
    }
}

enum BootstrapError: Error, CustomStringConvertible {
    case openFailed
    case schemaInvalid
    case missingTable(String)

    var description: String {
        switch self {
        case .openFailed:
            return "could not open Pods database"
        case .schemaInvalid:
            return "Pods database schema could not be inspected"
        case .missingTable(let table):
            return "Pods database is missing required table \(table)"
        }
    }
}
