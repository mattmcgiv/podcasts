// DEPRECATED as of 1 October 2026. Do not review, extend, or append to this file.
// See ios/DEPRECATED.md.

import Foundation
import OSLog

private let podsLogger = Logger(subsystem: "dev.mcgiv.pods", category: "app")
private let podsDebugLogger = Logger(subsystem: "dev.mcgiv.pods", category: "temporary-debug")

func PodsLog(_ message: String) {
    podsLogger.notice("\(message, privacy: .public)")
    PodsTemporaryDebugLog.write(level: "notice", message: message)
}

func PodsDebugLog(_ message: String) {
    guard PodsTemporaryDebugLog.isEnabled() else {
        return
    }
    podsDebugLogger.notice("[debug expires \(PodsTemporaryDebugLog.expiryISO8601, privacy: .public)] \(message, privacy: .public)")
    PodsTemporaryDebugLog.write(level: "debug", message: message)
}

enum PodsTemporaryDebugLog {
    static let expiryISO8601 = "2026-08-17T23:59:59Z"

    private static let maxFileBytes: UInt64 = 5 * 1024 * 1024
    private static let queue = DispatchQueue(label: "dev.mcgiv.pods.temporary-debug-log")
    private static let expiryDate: Date = {
        ISO8601DateFormatter().date(from: expiryISO8601) ?? .distantPast
    }()

    static func isEnabled(now: Date = Date()) -> Bool {
        now <= expiryDate
    }

    static func write(level: String, message: String, now: Date = Date()) {
        guard isEnabled(now: now) else {
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: now)
        let line = "\(timestamp) \(level) \(message)\n"
        let data = Data(line.utf8)
        queue.async {
            do {
                let url = try Self.logURL()
                let fileManager = FileManager.default
                if !fileManager.fileExists(atPath: url.path) {
                    fileManager.createFile(atPath: url.path, contents: nil)
                }
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let size = attributes[.size] as? UInt64 ?? 0
                if size + UInt64(data.count) > Self.maxFileBytes {
                    try Data().write(to: url, options: .atomic)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } catch {
                podsDebugLogger.error("temporary debug file write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func logURL() throws -> URL {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Pods", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("debug.log")
    }
}
