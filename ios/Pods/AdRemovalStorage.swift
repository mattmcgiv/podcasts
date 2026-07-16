import CryptoKit
import Foundation
import SQLite3

struct AdRemovalAudioArtifact: Equatable, Codable {
    let relativePath: String
    let sha256: String
    let byteCount: Int64
}

enum AdRemovalStorageError: Error, Equatable {
    case artifactLimit
    case minimumFreeSpace
    case invalidRelativePath
    case invalidFileExtension
}

enum AdRemovalDownloadError: Error, Equatable {
    case invalidHTTPStatus(Int)
    case unsupportedContentType(String)
    case missingResponse
}

struct AdRemovalStoragePolicy {
    static let tenGigabytes: Int64 = 10 * 1_000 * 1_000 * 1_000

    let artifactLimitBytes: Int64
    let minimumFreeBytes: Int64
    private let usedBytes: () throws -> Int64
    private let availableBytes: () throws -> Int64

    init(
        artifactLimitBytes: Int64 = Self.tenGigabytes,
        minimumFreeBytes: Int64 = Self.tenGigabytes,
        usedBytes: @escaping () throws -> Int64,
        availableBytes: @escaping () throws -> Int64
    ) {
        self.artifactLimitBytes = artifactLimitBytes
        self.minimumFreeBytes = minimumFreeBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }

    func authorizeLargeWrite(anticipatedBytes: Int64) throws {
        let anticipatedBytes = max(0, anticipatedBytes)
        guard try availableBytes() >= minimumFreeBytes else {
            throw AdRemovalStorageError.minimumFreeSpace
        }
        guard try usedBytes() <= artifactLimitBytes - anticipatedBytes else {
            throw AdRemovalStorageError.artifactLimit
        }
    }
}

final class AdRemovalArtifactStore {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try excludeFromBackup(self.rootURL)
    }

    static func applicationDefault(fileManager: FileManager = .default) throws -> AdRemovalArtifactStore {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try AdRemovalArtifactStore(
            rootURL: support.appendingPathComponent("AdRemoval", isDirectory: true),
            fileManager: fileManager
        )
    }

    func installDownloadedAudio(
        from temporaryURL: URL,
        episodeID: Int64,
        fileExtension: String
    ) throws -> AdRemovalAudioArtifact {
        guard episodeID > 0 else { throw AdRemovalStorageError.invalidRelativePath }
        let normalizedExtension = fileExtension.lowercased()
        let allowed = CharacterSet.alphanumerics
        guard !normalizedExtension.isEmpty,
              normalizedExtension.count <= 10,
              normalizedExtension.unicodeScalars.allSatisfy(allowed.contains) else {
            throw AdRemovalStorageError.invalidFileExtension
        }

        let byteCount = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        let checksum = try sha256(of: temporaryURL)
        let relativePath = "episodes/\(episodeID)/audio.\(normalizedExtension)"
        let destination = try url(for: relativePath)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup(directory)

        let staging = directory.appendingPathComponent(".audio-\(UUID().uuidString.lowercased()).incoming")
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.moveItem(at: temporaryURL, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        try excludeFromBackup(destination)
        return AdRemovalAudioArtifact(
            relativePath: relativePath,
            sha256: checksum,
            byteCount: byteCount
        )
    }

    func url(for relativePath: String) throws -> URL {
        guard Self.isValid(relativePath: relativePath) else {
            throw AdRemovalStorageError.invalidRelativePath
        }
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw AdRemovalStorageError.invalidRelativePath
        }
        return candidate
    }

    func validate(_ artifact: AdRemovalAudioArtifact) throws -> Bool {
        let fileURL = try url(for: artifact.relativePath)
        guard fileManager.fileExists(atPath: fileURL.path),
              (try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? -1) == artifact.byteCount else {
            return false
        }
        return try sha256(of: fileURL) == artifact.sha256
    }

    func removeArtifact(relativePath: String) throws {
        let fileURL = try url(for: relativePath)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        let episodeDirectory = fileURL.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: episodeDirectory.path).isEmpty) == true {
            try? fileManager.removeItem(at: episodeDirectory)
        }
    }

    func writeResumeData(_ data: Data, jobID: String) throws -> String {
        guard UUID(uuidString: jobID) != nil else {
            throw AdRemovalStorageError.invalidRelativePath
        }
        let relativePath = "resume/\(jobID.lowercased()).resume"
        let fileURL = try url(for: relativePath)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        try excludeFromBackup(fileURL)
        return relativePath
    }

    func resumeData(relativePath: String) throws -> Data {
        guard relativePath.hasPrefix("resume/") else {
            throw AdRemovalStorageError.invalidRelativePath
        }
        return try Data(contentsOf: url(for: relativePath))
    }

    func episodeArtifactBytes() throws -> Int64 {
        let episodes = rootURL.appendingPathComponent("episodes", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: episodes,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    func availableCapacity() throws -> Int64 {
        let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func removeAllEpisodeArtifacts() throws {
        for name in ["episodes", "resume"] {
            let directory = rootURL.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    static func isValid(relativePath: String) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else { return false }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

enum AdRemovalAudioDownloadPolicy {
    static func configuration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }
}

struct AdRemovalDownloadFinalizer {
    let jobStore: AdRemovalJobStore
    let artifactStore: AdRemovalArtifactStore
    let storagePolicy: AdRemovalStoragePolicy
    var diagnostics: AdRemovalDiagnostics?

    func finalize(
        temporaryURL: URL,
        response: HTTPURLResponse,
        job: AdRemovalJob
    ) throws -> AdRemovalAudioArtifact {
        guard (200..<300).contains(response.statusCode) else {
            throw AdRemovalDownloadError.invalidHTTPStatus(response.statusCode)
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first.map(String.init)?.lowercased() ?? ""
        guard contentType.hasPrefix("audio/") || contentType == "application/octet-stream" || contentType.isEmpty else {
            throw AdRemovalDownloadError.unsupportedContentType(contentType)
        }
        let byteCount = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        try storagePolicy.authorizeLargeWrite(anticipatedBytes: byteCount)
        let fileExtension = Self.fileExtension(contentType: contentType, responseURL: response.url)
        let artifact = try artifactStore.installDownloadedAudio(
            from: temporaryURL,
            episodeID: job.episodeID,
            fileExtension: fileExtension
        )
        _ = try jobStore.recordAudioArtifact(jobID: job.id, artifact: artifact)
        _ = try jobStore.transition(jobID: job.id, to: .downloaded)
        try? diagnostics?.record(
            eventName: "audio_download_completed",
            severity: .notice,
            context: AdRemovalDiagnosticContext(
                jobID: job.id,
                episodeID: job.episodeID,
                podcastID: job.podcastID,
                stage: AdRemovalJobStage.downloading.rawValue
            ),
            fields: [
                "status_code": String(response.statusCode),
                "content_type": contentType,
                "byte_count": String(artifact.byteCount),
                "sha256": artifact.sha256
            ]
        )
        return artifact
    }

    private static func fileExtension(contentType: String, responseURL: URL?) -> String {
        switch contentType {
        case "audio/mpeg", "audio/mp3":
            return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a":
            return "m4a"
        case "audio/aac":
            return "aac"
        case "audio/ogg":
            return "ogg"
        case "audio/wav", "audio/x-wav":
            return "wav"
        default:
            let candidate = responseURL?.pathExtension.lowercased() ?? ""
            let allowed = CharacterSet.alphanumerics
            if !candidate.isEmpty,
               candidate.count <= 10,
               candidate.unicodeScalars.allSatisfy(allowed.contains) {
                return candidate
            }
            return "audio"
        }
    }
}

final class AdRemovalFileCleanup {
    private let database: PodsDatabase
    private let artifactStore: AdRemovalArtifactStore
    private let diagnostics: AdRemovalDiagnostics?

    init(
        database: PodsDatabase,
        artifactStore: AdRemovalArtifactStore,
        diagnostics: AdRemovalDiagnostics? = nil
    ) {
        self.database = database
        self.artifactStore = artifactStore
        self.diagnostics = diagnostics
    }

    @discardableResult
    func drain() throws -> Int {
        let pending = try database.query(
            "SELECT relative_path, attempt_count FROM ad_artifact_cleanup ORDER BY created_at, relative_path"
        ) { statement in
            (path: sqliteString(statement, 0), attempt: Int(sqlite3_column_int64(statement, 1)))
        }
        var removed = 0
        for item in pending {
            do {
                try artifactStore.removeArtifact(relativePath: item.path)
                try database.execute(
                    "DELETE FROM ad_artifact_cleanup WHERE relative_path = ?",
                    [.text(item.path)]
                )
                removed += 1
                try? diagnostics?.record(
                    eventName: "artifact_cleanup_result",
                    severity: .info,
                    fields: ["result": "removed", "attempt": String(item.attempt + 1)]
                )
            } catch {
                try database.execute(
                    """
                    UPDATE ad_artifact_cleanup
                    SET attempt_count = attempt_count + 1, last_error = ?
                    WHERE relative_path = ?
                    """,
                    [.text((error as NSError).localizedDescription), .text(item.path)]
                )
                try? diagnostics?.record(
                    eventName: "artifact_cleanup_result",
                    severity: .error,
                    fields: ["result": "retry_pending", "attempt": String(item.attempt + 1)]
                )
            }
        }
        return removed
    }
}
