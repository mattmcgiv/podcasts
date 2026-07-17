import CryptoKit
import Foundation

struct AdModelFile: Equatable, Codable {
    let relativePath: String
    let byteCount: Int64
    let sha256: String
}

struct AdModelManifest: Equatable, Codable {
    let repository: String
    let revision: String
    let files: [AdModelFile]

    var totalByteCount: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    static let qwen3OneSevenBFourBitV1 = AdModelManifest(
        repository: "Qwen/Qwen3-1.7B-MLX-4bit",
        revision: "21457c6f51ed54a7c16e988c0844db973815c137",
        files: [
            AdModelFile(
                relativePath: "config.json",
                byteCount: 988,
                sha256: "4e95bb0b083bf4847aacc08e67c5d59410f45fff6f43889d6ff400511c243fa5"
            ),
            AdModelFile(
                relativePath: "merges.txt",
                byteCount: 1_671_853,
                sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
            ),
            AdModelFile(
                relativePath: "model.safetensors",
                byteCount: 914_316_100,
                sha256: "42e688d626b3e144bf721af7517a82f3ea7e97bb5764fef1c89942bf9165072a"
            ),
            AdModelFile(
                relativePath: "model.safetensors.index.json",
                byteCount: 49_731,
                sha256: "dae65ea418d2d8ea25e72d0b1f5b1d0a12633c1f46ca2c5ca97903bbcc3a6ce2"
            ),
            AdModelFile(
                relativePath: "tokenizer.json",
                byteCount: 11_422_654,
                sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
            ),
            AdModelFile(
                relativePath: "tokenizer_config.json",
                byteCount: 8_311,
                sha256: "5fdfe1416aaa323832d52c5bd8624a6e9bba3e9acc6ca8104f017abc775e2368"
            ),
            AdModelFile(
                relativePath: "vocab.json",
                byteCount: 2_776_833,
                sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
            )
        ]
    )
}

enum AdModelAssetError: Error, Equatable {
    case invalidManifest
    case invalidPath(String)
    case missingFile(String)
    case byteCountMismatch(String)
    case checksumMismatch(String)
    case consentMismatch
}

enum AdModelDownloadPolicy {
    static func configuration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    static func authorize(manifest: AdModelManifest, confirmedByteCount: Int64) throws {
        guard confirmedByteCount == manifest.totalByteCount else {
            throw AdModelAssetError.consentMismatch
        }
    }

    static func remoteURL(for file: AdModelFile, manifest: AdModelManifest) throws -> URL {
        let repositoryComponents = manifest.repository.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard repositoryComponents.count == 2,
              repositoryComponents.allSatisfy({ AdModelAssetStore.isSafeRepositoryComponent(String($0)) }),
              AdModelAssetStore.isSafeComponent(manifest.revision),
              AdModelAssetStore.isSafe(relativePath: file.relativePath),
              manifest.files.contains(file),
              var url = URL(string: "https://huggingface.co") else {
            throw AdModelAssetError.invalidManifest
        }
        for component in repositoryComponents.map(String.init)
            + ["resolve", manifest.revision]
            + file.relativePath.split(separator: "/").map(String.init) {
            url.appendPathComponent(component)
        }
        return url.appending(queryItems: [URLQueryItem(name: "download", value: "true")])
    }
}

enum AdModelDownloadPlan {
    static func pendingFiles(
        manifest: AdModelManifest,
        assetStore: AdModelAssetStore
    ) throws -> [AdModelFile] {
        try manifest.files.filter { try !assetStore.isValidated(file: $0, manifest: manifest) }
    }
}

enum AdModelTaskCompletionPolicy {
    static func shouldScheduleNext(fileValidated: Bool, completionError: Error?) -> Bool {
        fileValidated && completionError == nil
    }

    static func shouldRecordFailure(error: Error, cancellationRequested: Bool) -> Bool {
        let nsError = error as NSError
        return !(cancellationRequested
            && nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled)
    }
}

enum AdModelExistingTaskPolicy {
    static func shouldCancelExistingTasks(downloadState: String) -> Bool {
        downloadState == "failed"
    }
}

final class AdModelAssetStore {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try excludeFromBackup(self.rootURL)
    }

    convenience init(artifactStore: AdRemovalArtifactStore, fileManager: FileManager = .default) throws {
        try self.init(
            rootURL: artifactStore.rootURL.appendingPathComponent("models", isDirectory: true),
            fileManager: fileManager
        )
    }

    func modelDirectory(for manifest: AdModelManifest) -> URL {
        rootURL.appendingPathComponent(manifest.revision, isDirectory: true)
    }

    func fileURL(for file: AdModelFile, manifest: AdModelManifest) throws -> URL {
        guard Self.isSafeComponent(manifest.revision), Self.isSafe(relativePath: file.relativePath) else {
            throw AdModelAssetError.invalidPath(file.relativePath)
        }
        let directory = modelDirectory(for: manifest).standardizedFileURL
        let candidate = directory.appendingPathComponent(file.relativePath).standardizedFileURL
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw AdModelAssetError.invalidPath(file.relativePath)
        }
        return candidate
    }

    func verify(manifest: AdModelManifest) throws {
        guard !manifest.repository.isEmpty,
              Self.isSafeComponent(manifest.revision),
              !manifest.files.isEmpty,
              Set(manifest.files.map(\.relativePath)).count == manifest.files.count else {
            throw AdModelAssetError.invalidManifest
        }
        for file in manifest.files {
            guard file.byteCount > 0,
                  file.sha256.count == 64,
                  file.sha256.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
                  }) else {
                throw AdModelAssetError.invalidManifest
            }
            let url = try fileURL(for: file, manifest: manifest)
            guard fileManager.fileExists(atPath: url.path) else {
                throw AdModelAssetError.missingFile(file.relativePath)
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? -1
            guard size == file.byteCount else {
                throw AdModelAssetError.byteCountMismatch(file.relativePath)
            }
            guard try sha256(of: url) == file.sha256 else {
                throw AdModelAssetError.checksumMismatch(file.relativePath)
            }
        }
    }

    func isValidated(file: AdModelFile, manifest: AdModelManifest) throws -> Bool {
        guard manifest.files.contains(file) else {
            throw AdModelAssetError.invalidPath(file.relativePath)
        }
        let url = try fileURL(for: file, manifest: manifest)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? -1
        guard size == file.byteCount else { return false }
        return try sha256(of: url) == file.sha256
    }

    @discardableResult
    func activate(manifest: AdModelManifest, database: PodsDatabase) throws -> URL {
        try verify(manifest: manifest)
        let checksumData = try JSONEncoder().encode(manifest.files)
        let checksumJSON = String(decoding: checksumData, as: UTF8.self)
        try database.withTransaction {
            let values: [(String, String)] = [
                ("ad_removal_model_repository", manifest.repository),
                ("ad_removal_model_revision", manifest.revision),
                ("ad_removal_model_checksums", checksumJSON),
                ("ad_removal_model_byte_count", String(manifest.totalByteCount)),
                ("ad_removal_model_download_state", "ready")
            ]
            for (key, value) in values {
                try database.execute(
                    """
                    INSERT INTO settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    [.text(key), .text(value)]
                )
            }
        }
        return modelDirectory(for: manifest)
    }

    func installForTesting(_ data: Data, at relativePath: String, manifest: AdModelManifest) throws {
        guard let file = manifest.files.first(where: { $0.relativePath == relativePath }) else {
            throw AdModelAssetError.invalidPath(relativePath)
        }
        let url = try fileURL(for: file, manifest: manifest)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try excludeFromBackup(url)
    }

    @discardableResult
    func installDownloadedFile(
        from temporaryURL: URL,
        file: AdModelFile,
        manifest: AdModelManifest
    ) throws -> URL {
        guard manifest.files.contains(file) else {
            throw AdModelAssetError.invalidPath(file.relativePath)
        }
        let sourceSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? -1
        guard sourceSize == file.byteCount else {
            throw AdModelAssetError.byteCountMismatch(file.relativePath)
        }
        guard try sha256(of: temporaryURL) == file.sha256 else {
            throw AdModelAssetError.checksumMismatch(file.relativePath)
        }

        let destination = try fileURL(for: file, manifest: manifest)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).incoming")
        do {
            try fileManager.copyItem(at: temporaryURL, to: staging)
            try excludeFromBackup(staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            try excludeFromBackup(destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func downloadedByteCount(manifest: AdModelManifest) throws -> Int64 {
        try manifest.files.reduce(Int64(0)) { total, file in
            let url = try fileURL(for: file, manifest: manifest)
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return total + Int64(size ?? 0)
        }
    }

    func removeAll() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try excludeFromBackup(rootURL)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // Drain Foundation's autoreleased file-read buffer per chunk so live
            // memory stays bounded for files much larger than process memory.
            let data = try autoreleasepool { try handle.read(upToCount: 1_048_576) ?? Data() }
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isSafe(relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\") else {
            return false
        }
        return relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
    }

    static func isSafeRepositoryComponent(_ value: String) -> Bool {
        guard value != "." && value != ".." else { return false }
        return !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

enum AdModelBackgroundDownloadError: Error {
    case unexpectedTask
    case missingResponse
    case httpStatus(Int)
}

final class AdModelBackgroundDownloader: NSObject {
    static let sessionIdentifier = "dev.mcgiv.pods.ad-removal-model"

    private let database: PodsDatabase
    private let assetStore: AdModelAssetStore
    private let manifest: AdModelManifest
    private let diagnostics: AdRemovalDiagnostics?
    private let stateLock = NSLock()
    private var backgroundCompletionHandler: (() -> Void)?
    private var scheduling = false
    private var cancellationRequested = false
    private var validatedTaskIdentifiers: Set<Int> = []
    private var ignoredCancellationTaskIdentifiers: Set<Int> = []
    private var lastProgressBucket: [Int: Int] = [:]
    var modelReadyHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let queue = OperationQueue()
        queue.name = "dev.mcgiv.pods.ad-removal-model-download"
        queue.maxConcurrentOperationCount = 1
        return URLSession(
            configuration: AdModelDownloadPolicy.configuration(identifier: Self.sessionIdentifier),
            delegate: self,
            delegateQueue: queue
        )
    }()

    init(
        database: PodsDatabase,
        assetStore: AdModelAssetStore,
        manifest: AdModelManifest = .qwen3OneSevenBFourBitV1,
        diagnostics: AdRemovalDiagnostics? = nil
    ) {
        self.database = database
        self.assetStore = assetStore
        self.manifest = manifest
        self.diagnostics = diagnostics
        super.init()
        _ = session
    }

    func start(requestedManifest: AdModelManifest) async {
        record(
            eventName: "model_download_start_requested",
            severity: .info,
            fields: [
                "requested_revision": requestedManifest.revision,
                "active_revision": manifest.revision
            ]
        )
        guard requestedManifest == manifest else {
            record(
                eventName: "model_download_manifest_rejected",
                severity: .error,
                fields: ["requested_revision": requestedManifest.revision]
            )
            return
        }
        stateLock.lock()
        cancellationRequested = false
        guard !scheduling else {
            stateLock.unlock()
            record(
                eventName: "model_download_start_ignored",
                severity: .info,
                fields: ["reason": "already_scheduling"]
            )
            return
        }
        scheduling = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            scheduling = false
            stateLock.unlock()
        }

        do {
            let pending = try AdModelDownloadPlan.pendingFiles(manifest: manifest, assetStore: assetStore)
            record(
                eventName: "model_download_pending_evaluated",
                severity: .info,
                fields: ["pending_count": String(pending.count)]
            )
            if pending.isEmpty {
                try assetStore.activate(manifest: manifest, database: database)
                try setState("ready", downloadedBytes: manifest.totalByteCount, error: nil)
                record(
                    eventName: "model_download_ready",
                    severity: .notice,
                    fields: [
                        "revision": manifest.revision,
                        "byte_count": String(manifest.totalByteCount)
                    ]
                )
                DispatchQueue.main.async { [weak self] in self?.modelReadyHandler?() }
                return
            }

            let existingTasks = await session.allTasks.filter {
                $0.taskDescription.flatMap(fileForTaskDescription) != nil
            }
            record(
                eventName: "model_download_existing_tasks_evaluated",
                severity: .info,
                fields: ["task_count": String(existingTasks.count)]
            )
            if !existingTasks.isEmpty {
                let state = (try? downloadState()) ?? ""
                if AdModelExistingTaskPolicy.shouldCancelExistingTasks(downloadState: state) {
                    stateLock.lock()
                    for task in existingTasks {
                        ignoredCancellationTaskIdentifiers.insert(task.taskIdentifier)
                    }
                    stateLock.unlock()
                    for task in existingTasks {
                        task.cancel()
                    }
                    record(
                        eventName: "model_download_stale_tasks_cancelled",
                        severity: .warning,
                        fields: ["task_count": String(existingTasks.count), "prior_state": state]
                    )
                } else {
                    try setState(
                        "downloading",
                        downloadedBytes: try assetStore.downloadedByteCount(manifest: manifest),
                        error: nil
                    )
                    return
                }
            }

            let file = pending[0]
            var request = URLRequest(url: try AdModelDownloadPolicy.remoteURL(for: file, manifest: manifest))
            request.timeoutInterval = 60 * 60
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let task = session.downloadTask(with: request)
            task.taskDescription = file.relativePath
            try setState(
                "downloading",
                downloadedBytes: try assetStore.downloadedByteCount(manifest: manifest),
                error: nil
            )
            record(
                eventName: "model_download_started",
                severity: .notice,
                fields: [
                    "relative_path": file.relativePath,
                    "expected_bytes": String(file.byteCount),
                    "revision": manifest.revision,
                    "wifi_only": "true"
                ]
            )
            task.resume()
        } catch {
            markFailed(error, fields: ["source": "start"])
        }
    }

    private func downloadState() throws -> String {
        try database.query(
            "SELECT value FROM settings WHERE key = 'ad_removal_model_download_state'",
            map: { sqliteString($0, 0) }
        ).first ?? ""
    }

    func cancel() async {
        stateLock.lock()
        cancellationRequested = true
        stateLock.unlock()
        for task in await session.allTasks {
            task.cancel()
        }
        try? setState(
            "consented",
            downloadedBytes: try assetStore.downloadedByteCount(manifest: manifest),
            error: nil
        )
        record(eventName: "model_download_cancelled", severity: .notice)
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == Self.sessionIdentifier else { return false }
        stateLock.lock()
        backgroundCompletionHandler = completionHandler
        stateLock.unlock()
        _ = session
        return true
    }

    private func fileForTaskDescription(_ description: String) -> AdModelFile? {
        manifest.files.first { $0.relativePath == description }
    }

    private func setState(_ state: String, downloadedBytes: Int64, error: Error?) throws {
        let nsError = error.map { $0 as NSError }
        let values: [(String, String)] = [
            ("ad_removal_model_download_state", state),
            ("ad_removal_model_downloaded_bytes", String(downloadedBytes)),
            ("ad_removal_model_download_error", nsError.map { "\($0.domain):\($0.code)" } ?? "")
        ]
        try database.withTransaction {
            for (key, value) in values {
                try database.execute(
                    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [.text(key), .text(value)]
                )
            }
        }
    }

    private func markFailed(_ error: Error, fields extraFields: [String: String] = [:]) {
        let downloaded = (try? assetStore.downloadedByteCount(manifest: manifest)) ?? 0
        try? setState("failed", downloadedBytes: downloaded, error: error)
        let nsError = error as NSError
        var fields = extraFields
        fields["error_domain"] = nsError.domain
        fields["error_code"] = String(nsError.code)
        record(
            eventName: "model_download_failed",
            severity: .error,
            fields: fields
        )
    }

    private func record(
        eventName: String,
        severity: AdRemovalDiagnosticSeverity,
        fields: [String: String] = [:]
    ) {
        try? diagnostics?.record(eventName: eventName, severity: severity, fields: fields)
    }
}

extension AdModelBackgroundDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let file = downloadTask.taskDescription.flatMap(fileForTaskDescription) else {
            markFailed(AdModelBackgroundDownloadError.unexpectedTask, fields: ["source": "did_finish"])
            return
        }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            markFailed(
                AdModelBackgroundDownloadError.missingResponse,
                fields: ["source": "did_finish", "relative_path": file.relativePath]
            )
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            markFailed(
                AdModelBackgroundDownloadError.httpStatus(response.statusCode),
                fields: [
                    "source": "did_finish",
                    "relative_path": file.relativePath,
                    "http_status": String(response.statusCode)
                ]
            )
            return
        }
        do {
            _ = try assetStore.installDownloadedFile(from: location, file: file, manifest: manifest)
            record(
                eventName: "model_download_file_validated",
                severity: .notice,
                fields: ["relative_path": file.relativePath, "byte_count": String(file.byteCount)]
            )
            stateLock.lock()
            validatedTaskIdentifiers.insert(downloadTask.taskIdentifier)
            stateLock.unlock()
        } catch {
            markFailed(error, fields: ["source": "did_finish", "relative_path": file.relativePath])
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
              let file = downloadTask.taskDescription.flatMap(fileForTaskDescription) else { return }
        let percent = Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100)
        let bucket = min(100, max(0, percent / 5 * 5))
        stateLock.lock()
        let prior = lastProgressBucket[downloadTask.taskIdentifier]
        if prior != bucket { lastProgressBucket[downloadTask.taskIdentifier] = bucket }
        stateLock.unlock()
        guard prior != bucket else { return }
        let installedBytes = (try? assetStore.downloadedByteCount(manifest: manifest)) ?? 0
        try? setState("downloading", downloadedBytes: installedBytes + totalBytesWritten, error: nil)
        record(
            eventName: "model_download_progress",
            severity: .info,
            fields: [
                "relative_path": file.relativePath,
                "percent": String(bucket),
                "received_bytes": String(totalBytesWritten),
                "expected_bytes": String(totalBytesExpectedToWrite)
            ]
        )
    }
}

extension AdModelBackgroundDownloader: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        lastProgressBucket.removeValue(forKey: task.taskIdentifier)
        let fileValidated = validatedTaskIdentifiers.remove(task.taskIdentifier) != nil
        let ignoredCancellation = ignoredCancellationTaskIdentifiers.remove(task.taskIdentifier) != nil
        let wasCancellationRequested = cancellationRequested
        stateLock.unlock()
        if let error {
            let nsError = error as NSError
            if ignoredCancellation,
               nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled {
                return
            }
            if AdModelTaskCompletionPolicy.shouldRecordFailure(
                error: error,
                cancellationRequested: wasCancellationRequested
            ) {
                var fields = ["source": "did_complete"]
                if let relativePath = task.taskDescription {
                    fields["relative_path"] = relativePath
                }
                markFailed(error, fields: fields)
            }
            return
        }
        if AdModelTaskCompletionPolicy.shouldScheduleNext(
            fileValidated: fileValidated,
            completionError: error
        ) {
            Task { [weak self] in
                guard let self else { return }
                await self.start(requestedManifest: self.manifest)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateLock.lock()
        let completion = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        stateLock.unlock()
        DispatchQueue.main.async { completion?() }
    }
}
