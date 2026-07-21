import Foundation

protocol AdRemovalAudioDownloading: AnyObject {
    func download(job: AdRemovalJob, sourceURL: URL) async throws -> AdRemovalAudioArtifact
}

final class AdRemovalBackgroundDownloader: NSObject, AdRemovalAudioDownloading {
    static let sessionIdentifier = "dev.mcgiv.pods.ad-removal-audio"

    private let jobStore: AdRemovalJobStore
    private let artifactStore: AdRemovalArtifactStore
    private let storagePolicy: AdRemovalStoragePolicy
    private let diagnostics: AdRemovalDiagnostics?
    private let stateLock = NSLock()
    private var continuations: [Int: CheckedContinuation<AdRemovalAudioArtifact, Error>] = [:]
    private var results: [Int: Result<AdRemovalAudioArtifact, Error>] = [:]
    private var lastProgressBucket: [Int: Int] = [:]
    private var backgroundCompletionHandler: (() -> Void)?
    private lazy var session: URLSession = {
        let queue = OperationQueue()
        queue.name = "dev.mcgiv.pods.ad-removal-downloads"
        queue.maxConcurrentOperationCount = 1
        return URLSession(
            configuration: AdRemovalAudioDownloadPolicy.configuration(identifier: Self.sessionIdentifier),
            delegate: self,
            delegateQueue: queue
        )
    }()

    init(
        jobStore: AdRemovalJobStore,
        artifactStore: AdRemovalArtifactStore,
        storagePolicy: AdRemovalStoragePolicy,
        diagnostics: AdRemovalDiagnostics? = nil
    ) {
        self.jobStore = jobStore
        self.artifactStore = artifactStore
        self.storagePolicy = storagePolicy
        self.diagnostics = diagnostics
        super.init()
        _ = session
    }

    func download(job: AdRemovalJob, sourceURL: URL) async throws -> AdRemovalAudioArtifact {
        if let artifact = job.audioArtifact, try artifactStore.validate(artifact) {
            return artifact
        }
        do {
            try storagePolicy.authorizeLargeWrite(anticipatedBytes: 0)
        } catch let error as AdRemovalStorageError {
            try? diagnostics?.record(
                eventName: "storage_policy_block",
                severity: .notice,
                context: context(for: job),
                fields: ["reason": String(describing: error)]
            )
            throw AdRemovalPipelinePause(reason: .storageLimit)
        }

        let existingTask = await session.allTasks
            .compactMap { $0 as? URLSessionDownloadTask }
            .first { $0.taskDescription == job.id }

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task: URLSessionDownloadTask
                    if let existingTask {
                        task = existingTask
                        record(eventName: "audio_download_restored", severity: .notice, job: job)
                    } else if let resumePath = job.downloadResumeRelativePath,
                              let resumeData = try? artifactStore.resumeData(relativePath: resumePath) {
                        task = session.downloadTask(withResumeData: resumeData)
                        task.taskDescription = job.id
                        record(eventName: "audio_download_resume_data_restored", severity: .notice, job: job)
                    } else {
                        var request = URLRequest(url: sourceURL)
                        request.setValue("audio/*, application/octet-stream", forHTTPHeaderField: "Accept")
                        request.timeoutInterval = 120
                        task = session.downloadTask(with: request)
                        task.taskDescription = job.id
                        record(
                            eventName: "audio_download_request_decision",
                            severity: .notice,
                            job: job,
                            fields: [
                                "allows_cellular": "true",
                                "source_origin": Self.origin(of: sourceURL)
                            ]
                        )
                    }
                    register(continuation: continuation, for: task.taskIdentifier)
                    task.resume()
                }
            } onCancel: {
                Task { [weak self] in
                    guard let self else { return }
                    let tasks = await self.session.allTasks
                    for case let task as URLSessionDownloadTask in tasks where task.taskDescription == job.id {
                        let resumeData = await task.cancelByProducingResumeData()
                        self.persistResumeData(resumeData, for: job)
                    }
                }
            }
        } catch is AdRemovalStorageError {
            throw AdRemovalPipelinePause(reason: .storageLimit)
        }
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == Self.sessionIdentifier else { return false }
        stateLock.lock()
        backgroundCompletionHandler = completionHandler
        stateLock.unlock()
        _ = session
        return true
    }

    private func register(
        continuation: CheckedContinuation<AdRemovalAudioArtifact, Error>,
        for taskIdentifier: Int
    ) {
        stateLock.lock()
        continuations[taskIdentifier] = continuation
        let completed = results.removeValue(forKey: taskIdentifier)
        stateLock.unlock()
        if let completed {
            continuation.resume(with: completed)
        }
    }

    private func store(result: Result<AdRemovalAudioArtifact, Error>, for taskIdentifier: Int) {
        stateLock.lock()
        let continuation = continuations.removeValue(forKey: taskIdentifier)
        if continuation == nil {
            results[taskIdentifier] = result
        }
        lastProgressBucket.removeValue(forKey: taskIdentifier)
        stateLock.unlock()
        continuation?.resume(with: result)
    }

    private func persistResumeData(_ data: Data?, for job: AdRemovalJob) {
        guard let data, !data.isEmpty else { return }
        var writtenPath: String?
        do {
            let relativePath = try artifactStore.writeResumeData(data, jobID: job.id)
            writtenPath = relativePath
            _ = try jobStore.recordDownloadResumePath(jobID: job.id, relativePath: relativePath)
            record(
                eventName: "audio_download_resume_data_saved",
                severity: .notice,
                job: job,
                fields: ["byte_count": String(data.count)]
            )
        } catch {
            if let writtenPath {
                try? artifactStore.removeArtifact(relativePath: writtenPath)
            }
            record(
                eventName: "audio_download_resume_data_save_failed",
                severity: .error,
                job: job
            )
        }
    }

    private func job(for task: URLSessionTask) -> AdRemovalJob? {
        guard let jobID = task.taskDescription else { return nil }
        return try? jobStore.job(id: jobID)
    }

    private func context(for job: AdRemovalJob) -> AdRemovalDiagnosticContext {
        AdRemovalDiagnosticContext(
            jobID: job.id,
            episodeID: job.episodeID,
            podcastID: job.podcastID,
            stage: AdRemovalJobStage.downloading.rawValue,
            attempt: job.attemptCount + 1
        )
    }

    private func record(
        eventName: String,
        severity: AdRemovalDiagnosticSeverity,
        job: AdRemovalJob,
        fields: [String: String] = [:]
    ) {
        try? diagnostics?.record(
            eventName: eventName,
            severity: severity,
            context: context(for: job),
            fields: fields
        )
    }

    private static func origin(of url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else { return "unknown" }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

extension AdRemovalBackgroundDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let job = job(for: downloadTask) else {
            store(result: .failure(AdRemovalJobStoreError.jobNotFound), for: downloadTask.taskIdentifier)
            return
        }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            store(result: .failure(AdRemovalDownloadError.missingResponse), for: downloadTask.taskIdentifier)
            return
        }
        do {
            let finalizer = AdRemovalDownloadFinalizer(
                jobStore: jobStore,
                artifactStore: artifactStore,
                storagePolicy: storagePolicy,
                diagnostics: diagnostics
            )
            let artifact = try finalizer.finalize(
                temporaryURL: location,
                response: response,
                job: job
            )
            if let resumePath = job.downloadResumeRelativePath {
                try? artifactStore.removeArtifact(relativePath: resumePath)
                _ = try? jobStore.recordDownloadResumePath(jobID: job.id, relativePath: nil)
            }
            store(result: .success(artifact), for: downloadTask.taskIdentifier)
        } catch let error as AdRemovalStorageError {
            _ = try? jobStore.setBlockingReason(jobID: job.id, reason: .storageLimit)
            store(result: .failure(error), for: downloadTask.taskIdentifier)
        } catch {
            store(result: .failure(error), for: downloadTask.taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let job = job(for: downloadTask) else { return }
        let percent = Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100)
        let bucket = min(100, max(0, percent / 10 * 10))
        stateLock.lock()
        let prior = lastProgressBucket[downloadTask.taskIdentifier]
        if prior != bucket { lastProgressBucket[downloadTask.taskIdentifier] = bucket }
        stateLock.unlock()
        guard prior != bucket else { return }
        record(
            eventName: "audio_download_progress",
            severity: .info,
            job: job,
            fields: [
                "percent": String(bucket),
                "received_bytes": String(totalBytesWritten),
                "expected_bytes": String(totalBytesExpectedToWrite)
            ]
        )
    }
}

extension AdRemovalBackgroundDownloader: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        guard let job = job(for: task) else {
            store(result: .failure(error), for: task.taskIdentifier)
            return
        }
        let nsError = error as NSError
        persistResumeData(nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, for: job)
        record(
            eventName: "audio_download_transport_failure",
            severity: .error,
            job: job,
            fields: ["error_domain": nsError.domain, "error_code": String(nsError.code)]
        )
        store(result: .failure(error), for: task.taskIdentifier)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateLock.lock()
        let completion = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        stateLock.unlock()
        DispatchQueue.main.async { completion?() }
    }
}
