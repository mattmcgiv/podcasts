import Foundation
import OSLog

enum AdRemovalDiagnosticsComponent: String, Codable {
    case iphone
    case mac

    fileprivate var applicationSupportFolder: String {
        switch self {
        case .iphone: "Pods"
        case .mac: "PodsSpeaker"
        }
    }
}

enum AdRemovalPlaybackSession {
    static let payloadKey = "playbackSessionId"

    static func makeID() -> String {
        UUID().uuidString.lowercased()
    }

    static func attaching(sessionID: String, to payload: [String: Any]) -> [String: Any] {
        var correlated = payload
        correlated[payloadKey] = sessionID
        return correlated
    }

    static func sessionID(from payload: [String: Any]) -> String? {
        guard let value = payload[payloadKey] as? String, !value.isEmpty else { return nil }
        return value
    }
}

enum AdRemovalDiagnosticSeverity: String, Codable, CaseIterable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .error
        case .error: .error
        case .fault: .fault
        }
    }
}

struct AdRemovalDiagnosticContext: Codable, Equatable {
    var jobID: String?
    var episodeID: Int64?
    var podcastID: Int64?
    var stage: String?
    var attempt: Int?
    var playbackSessionID: String?

    init(
        jobID: String? = nil,
        episodeID: Int64? = nil,
        podcastID: Int64? = nil,
        stage: String? = nil,
        attempt: Int? = nil,
        playbackSessionID: String? = nil
    ) {
        self.jobID = jobID
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.stage = stage
        self.attempt = attempt
        self.playbackSessionID = playbackSessionID
    }
}

struct AdRemovalDiagnosticEvent: Codable, Equatable {
    let timestamp: String
    let eventName: String
    let severity: AdRemovalDiagnosticSeverity
    let component: AdRemovalDiagnosticsComponent
    let appVersion: String
    let buildVersion: String
    let context: AdRemovalDiagnosticContext
    let fields: [String: String]
}

struct AdRemovalDiagnosticTranscriptSegment: Codable, Equatable {
    let id: String
    let startTime: Double
    let endTime: Double
    let text: String
}

struct AdRemovalDiagnosticSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let createdAt: Date
    let jobID: String
    let episodeID: Int64
    let podcastID: Int64?
    let transcriptSegments: [AdRemovalDiagnosticTranscriptSegment]
    let classifierPrompt: String
    let classifierInput: String
    let selectedCorrectionExamples: [String]
    let rawClassifierOutput: String
    let schemaValidationResult: String
    let finalLabels: [String: String]
    let skipManifest: String
}

struct AdRemovalDiagnosticsExportManifest: Codable, Equatable {
    let formatVersion: Int
    let createdAt: String
    let appVersion: String
    let buildVersion: String
    let stateSummary: [String: String]
    let schemaVersions: [String: String]
    let logFiles: [String]
    let snapshotFiles: [String]
}

final class AdRemovalDiagnostics: @unchecked Sendable {
    struct Configuration {
        let rootDirectory: URL
        let maximumLogFileBytes: Int
        let retainedLogFileCount: Int
        let retainedSnapshotCount: Int
        let component: AdRemovalDiagnosticsComponent
        let appVersion: String
        let buildVersion: String

        init(
            rootDirectory: URL,
            maximumLogFileBytes: Int = 10 * 1_024 * 1_024,
            retainedLogFileCount: Int = 5,
            retainedSnapshotCount: Int = 10,
            component: AdRemovalDiagnosticsComponent = .iphone,
            appVersion: String,
            buildVersion: String
        ) {
            self.rootDirectory = rootDirectory
            self.maximumLogFileBytes = maximumLogFileBytes
            self.retainedLogFileCount = retainedLogFileCount
            self.retainedSnapshotCount = retainedSnapshotCount
            self.component = component
            self.appVersion = appVersion
            self.buildVersion = buildVersion
        }
    }

    private static let sensitiveKeyFragments = [
        "authorization", "bearer", "cookie", "credential", "password", "secret", "token", "api_key", "apikey"
    ]

    private let configuration: Configuration
    private let logDirectory: URL
    private let snapshotDirectory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "dev.mcgiv.pods", category: "ad-removal")

    init(configuration: Configuration) throws {
        guard configuration.maximumLogFileBytes > 0,
              configuration.retainedLogFileCount > 0,
              configuration.retainedSnapshotCount > 0 else {
            throw DiagnosticsError.invalidConfiguration
        }
        self.configuration = configuration
        logDirectory = configuration.rootDirectory.appendingPathComponent("logs", isDirectory: true)
        snapshotDirectory = configuration.rootDirectory.appendingPathComponent("snapshots", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
    }

    static func applicationDefault(
        component: AdRemovalDiagnosticsComponent,
        applicationSupportDirectory: URL? = nil,
        appVersion: String? = nil,
        buildVersion: String? = nil,
        bundle: Bundle = .main
    ) throws -> AdRemovalDiagnostics {
        let supportDirectory: URL
        if let applicationSupportDirectory {
            supportDirectory = applicationSupportDirectory
        } else {
            supportDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let info = bundle.infoDictionary ?? [:]
        return try AdRemovalDiagnostics(configuration: .init(
            rootDirectory: supportDirectory
                .appendingPathComponent(component.applicationSupportFolder, isDirectory: true)
                .appendingPathComponent("AdRemovalDiagnostics", isDirectory: true),
            component: component,
            appVersion: appVersion ?? (info["CFBundleShortVersionString"] as? String ?? "unknown"),
            buildVersion: buildVersion ?? (info["CFBundleVersion"] as? String ?? "unknown")
        ))
    }

    func record(
        eventName: String,
        severity: AdRemovalDiagnosticSeverity,
        context: AdRemovalDiagnosticContext = .init(),
        fields: [String: String] = [:],
        now: Date = Date()
    ) throws {
        let event = AdRemovalDiagnosticEvent(
            timestamp: Self.timestamp(from: now),
            eventName: Self.redactText(eventName),
            severity: severity,
            component: configuration.component,
            appVersion: configuration.appVersion,
            buildVersion: configuration.buildVersion,
            context: Self.redacted(context),
            fields: Self.redacted(fields)
        )
        let encoded: Data = try lock.withLock {
            let encoded = try encoder.encode(event)
            var line = encoded
            line.append(0x0A)
            let current = logURL(index: 0)
            let existingBytes = Self.fileSize(at: current)
            if existingBytes > 0, existingBytes + line.count > configuration.maximumLogFileBytes {
                try rotate()
            }
            if !FileManager.default.fileExists(atPath: current.path) {
                FileManager.default.createFile(atPath: current.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            return encoded
        }

        if let rendered = String(data: encoded, encoding: .utf8) {
            logger.log(level: severity.osLogType, "\(rendered, privacy: .public)")
        }
    }

    func logFileURLs() -> [URL] {
        lock.withLock { logFileURLsLocked() }
    }

    func readPersistedEvents() throws -> [AdRemovalDiagnosticEvent] {
        try lock.withLock {
            var events: [AdRemovalDiagnosticEvent] = []
            for url in (0..<configuration.retainedLogFileCount).reversed().map(logURL(index:)) {
                guard let data = FileManager.default.contents(atPath: url.path) else { continue }
                for line in data.split(separator: 0x0A) where !line.isEmpty {
                    events.append(try decoder.decode(AdRemovalDiagnosticEvent.self, from: Data(line)))
                }
            }
            return events
        }
    }

    func saveSnapshot(_ snapshot: AdRemovalDiagnosticSnapshot) throws {
        try lock.withLock {
            let redacted = Self.redacted(snapshot)
            let data = try encoder.encode(redacted)
            try data.write(to: snapshotURL(for: redacted), options: [.atomic])
            try enforceSnapshotRetentionLocked()
        }
    }

    func snapshotFileURLs() -> [URL] {
        lock.withLock { snapshotFileURLsLocked() }
    }

    func readSnapshots() throws -> [AdRemovalDiagnosticSnapshot] {
        try lock.withLock { try readSnapshotsLocked() }
    }

    func makeExportManifest(
        stateSummary: [String: String],
        schemaVersions: [String: String],
        now: Date = Date()
    ) -> AdRemovalDiagnosticsExportManifest {
        lock.withLock {
            makeExportManifestLocked(
                stateSummary: stateSummary,
                schemaVersions: schemaVersions,
                now: now
            )
        }
    }

    func exportArchive(
        to directory: URL,
        stateSummary: [String: String],
        schemaVersions: [String: String],
        now: Date = Date()
    ) throws -> URL {
        let archiveData: Data = try lock.withLock {
            let manifest = makeExportManifestLocked(
                stateSummary: stateSummary,
                schemaVersions: schemaVersions,
                now: now
            )
            var entries: [DiagnosticsZipEntry] = [
                DiagnosticsZipEntry(name: "manifest.json", data: try encoder.encode(manifest)),
                DiagnosticsZipEntry(name: "state-summary.json", data: try encoder.encode(stateSummary))
            ]
            entries.append(contentsOf: try logFileURLsLocked().map {
                DiagnosticsZipEntry(
                    name: "\(configuration.component.rawValue)/logs/\($0.lastPathComponent)",
                    data: try Data(contentsOf: $0)
                )
            })
            entries.append(contentsOf: try snapshotFileURLsLocked().map {
                DiagnosticsZipEntry(
                    name: "\(configuration.component.rawValue)/snapshots/\($0.lastPathComponent)",
                    data: try Data(contentsOf: $0)
                )
            })
            return try DiagnosticsZipArchive.make(entries: entries)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent(
            "pods-ad-removal-diagnostics-\(Self.fileTimestamp(from: now)).zip"
        )
        try archiveData.write(to: archiveURL, options: [.atomic])
        return archiveURL
    }

    func clear() throws {
        try lock.withLock {
            let fileManager = FileManager.default
            for directory in [logDirectory, snapshotDirectory] {
                if fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
    }

    private func logFileURLsLocked() -> [URL] {
        (0..<configuration.retainedLogFileCount)
            .map(logURL(index:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func makeExportManifestLocked(
        stateSummary: [String: String],
        schemaVersions: [String: String],
        now: Date
    ) -> AdRemovalDiagnosticsExportManifest {
        AdRemovalDiagnosticsExportManifest(
            formatVersion: 1,
            createdAt: Self.timestamp(from: now),
            appVersion: configuration.appVersion,
            buildVersion: configuration.buildVersion,
            stateSummary: Self.redacted(stateSummary),
            schemaVersions: Self.redacted(schemaVersions),
            logFiles: logFileURLsLocked().map { "\(configuration.component.rawValue)/logs/\($0.lastPathComponent)" },
            snapshotFiles: snapshotFileURLsLocked().map { "\(configuration.component.rawValue)/snapshots/\($0.lastPathComponent)" }
        )
    }

    private func snapshotFileURLsLocked() -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: snapshotDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { url in
            url.pathExtension == "json" && ((try? url.resourceValues(forKeys: keys).isRegularFile) ?? false)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readSnapshotsLocked() throws -> [AdRemovalDiagnosticSnapshot] {
        try snapshotFileURLsLocked()
            .map { try decoder.decode(AdRemovalDiagnosticSnapshot.self, from: Data(contentsOf: $0)) }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.jobID < $1.jobID }
                return $0.createdAt < $1.createdAt
            }
    }

    private func enforceSnapshotRetentionLocked() throws {
        let snapshots = try readSnapshotsLocked()
        guard snapshots.count > configuration.retainedSnapshotCount else { return }
        for snapshot in snapshots.prefix(snapshots.count - configuration.retainedSnapshotCount) {
            let url = snapshotURL(for: snapshot)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func snapshotURL(for snapshot: AdRemovalDiagnosticSnapshot) -> URL {
        let milliseconds = Int64((snapshot.createdAt.timeIntervalSince1970 * 1_000).rounded())
        let safeJobID = snapshot.jobID
            .unicodeScalars
            .map { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) ? String($0) : "_" }
            .joined()
        return snapshotDirectory.appendingPathComponent(
            String(format: "%020lld-%@.json", milliseconds, safeJobID)
        )
    }

    private func rotate() throws {
        let fileManager = FileManager.default
        let oldest = logURL(index: configuration.retainedLogFileCount - 1)
        if fileManager.fileExists(atPath: oldest.path) {
            try fileManager.removeItem(at: oldest)
        }
        guard configuration.retainedLogFileCount > 1 else {
            let current = logURL(index: 0)
            if fileManager.fileExists(atPath: current.path) {
                try fileManager.removeItem(at: current)
            }
            return
        }
        for index in stride(from: configuration.retainedLogFileCount - 2, through: 0, by: -1) {
            let source = logURL(index: index)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(at: source, to: logURL(index: index + 1))
        }
    }

    private func logURL(index: Int) -> URL {
        logDirectory.appendingPathComponent(String(format: "ad-removal-%02d.jsonl", index))
    }

    private static func fileSize(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private static func redacted(_ context: AdRemovalDiagnosticContext) -> AdRemovalDiagnosticContext {
        AdRemovalDiagnosticContext(
            jobID: context.jobID.map(redactText),
            episodeID: context.episodeID,
            podcastID: context.podcastID,
            stage: context.stage.map(redactText),
            attempt: context.attempt,
            playbackSessionID: context.playbackSessionID.map(redactText)
        )
    }

    private static func redacted(_ fields: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { key, value in
            let normalizedKey = key.lowercased()
            if sensitiveKeyFragments.contains(where: normalizedKey.contains) {
                return (key, "[REDACTED]")
            }
            if let strippedURL = strippedURL(value) {
                return (key, strippedURL)
            }
            return (key, redactText(value))
        })
    }

    private static func redacted(_ snapshot: AdRemovalDiagnosticSnapshot) -> AdRemovalDiagnosticSnapshot {
        AdRemovalDiagnosticSnapshot(
            schemaVersion: snapshot.schemaVersion,
            createdAt: snapshot.createdAt,
            jobID: redactText(snapshot.jobID),
            episodeID: snapshot.episodeID,
            podcastID: snapshot.podcastID,
            transcriptSegments: snapshot.transcriptSegments.map {
                AdRemovalDiagnosticTranscriptSegment(
                    id: redactText($0.id),
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: redactSnapshotText($0.text)
                )
            },
            classifierPrompt: redactSnapshotText(snapshot.classifierPrompt),
            classifierInput: redactSnapshotText(snapshot.classifierInput),
            selectedCorrectionExamples: snapshot.selectedCorrectionExamples.map(redactSnapshotText),
            rawClassifierOutput: redactSnapshotText(snapshot.rawClassifierOutput),
            schemaValidationResult: redactSnapshotText(snapshot.schemaValidationResult),
            finalLabels: Dictionary(uniqueKeysWithValues: snapshot.finalLabels.map {
                (redactText($0.key), redactSnapshotText($0.value))
            }),
            skipManifest: redactSnapshotText(snapshot.skipManifest)
        )
    }

    private static func redactSnapshotText(_ value: String) -> String {
        strippedURL(value) ?? redactText(value)
    }

    private static func strippedURL(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        return components.string
    }

    private static func redactText(_ value: String) -> String {
        var result = value
        let patterns = [
            "(?i)bearer\\s+[^\\s,;]+",
            "(?i)(token|secret|password|api[_-]?key)=([^&\\s]+)"
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: "[REDACTED]")
        }
        return result
    }

    private static func timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func fileTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    enum DiagnosticsError: Error {
        case invalidConfiguration
    }
}

private struct DiagnosticsZipEntry {
    let name: String
    let data: Data
}

private enum DiagnosticsZipArchive {
    private struct CentralEntry {
        let name: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    static func make(entries: [DiagnosticsZipEntry]) throws -> Data {
        var archive = Data()
        var centralEntries: [CentralEntry] = []

        for entry in entries {
            let name = Data(entry.name.utf8)
            guard name.count <= Int(UInt16.max),
                  entry.data.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max) else {
                throw ZipError.archiveTooLarge
            }
            let size = UInt32(entry.data.count)
            let checksum = crc32(entry.data)
            let offset = UInt32(archive.count)

            archive.appendLittleEndian(UInt32(0x04034b50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(checksum)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(UInt16(name.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(name)
            archive.append(entry.data)
            centralEntries.append(.init(
                name: name,
                crc32: checksum,
                size: size,
                localHeaderOffset: offset
            ))
        }

        guard archive.count <= Int(UInt32.max), centralEntries.count <= Int(UInt16.max) else {
            throw ZipError.archiveTooLarge
        }
        let centralOffset = UInt32(archive.count)
        for entry in centralEntries {
            archive.appendLittleEndian(UInt32(0x02014b50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(entry.crc32)
            archive.appendLittleEndian(entry.size)
            archive.appendLittleEndian(entry.size)
            archive.appendLittleEndian(UInt16(entry.name.count))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt32(0))
            archive.appendLittleEndian(entry.localHeaderOffset)
            archive.append(entry.name)
        }

        guard archive.count <= Int(UInt32.max) else { throw ZipError.archiveTooLarge }
        let centralSize = UInt32(archive.count) - centralOffset
        let count = UInt16(centralEntries.count)
        archive.appendLittleEndian(UInt32(0x06054b50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(count)
        archive.appendLittleEndian(count)
        archive.appendLittleEndian(centralSize)
        archive.appendLittleEndian(centralOffset)
        archive.appendLittleEndian(UInt16(0))
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ 0xffff_ffff
    }

    private enum ZipError: Error {
        case archiveTooLarge
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
