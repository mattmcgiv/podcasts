import Foundation

enum AdRemovalPipelineError: Error, Equatable {
    case episodeAudioURLMissing
    case invalidDownloadedArtifact
    case stageNotConfigured(AdRemovalJobStage)
    case unsupportedStage(AdRemovalJobStage)
}

final class AdRemovalPipelineExecutor: AdRemovalStageExecuting {
    private let database: PodsDatabase
    private let jobStore: AdRemovalJobStore
    private let artifactStore: AdRemovalArtifactStore
    private let audioDownloader: AdRemovalAudioDownloading
    private let transcriber: AdTranscribing?
    private let classifier: AdClassifier?
    private let classificationWindowBuilder: AdClassificationWindowBuilder
    private let classifierOutputParser: AdClassifierOutputParser
    private let manifestBuilder: AdSkipManifestBuilder
    private let diagnostics: AdRemovalDiagnostics?

    init(
        database: PodsDatabase,
        jobStore: AdRemovalJobStore,
        artifactStore: AdRemovalArtifactStore,
        audioDownloader: AdRemovalAudioDownloading,
        transcriber: AdTranscribing? = nil,
        classifier: AdClassifier? = nil,
        classificationWindowBuilder: AdClassificationWindowBuilder = .init(limits: .production),
        classifierOutputParser: AdClassifierOutputParser = .init(),
        manifestBuilder: AdSkipManifestBuilder = .init(),
        diagnostics: AdRemovalDiagnostics? = nil
    ) {
        self.database = database
        self.jobStore = jobStore
        self.artifactStore = artifactStore
        self.audioDownloader = audioDownloader
        self.transcriber = transcriber
        self.classifier = classifier
        self.classificationWindowBuilder = classificationWindowBuilder
        self.classifierOutputParser = classifierOutputParser
        self.manifestBuilder = manifestBuilder
        self.diagnostics = diagnostics
    }

    func execute(stage: AdRemovalJobStage, job: AdRemovalJob) async throws {
        switch stage {
        case .downloading:
            _ = try jobStore.requirePipelineJob(
                jobID: job.id,
                episodeID: job.episodeID,
                expected: [.downloading]
            )
            guard let source = try database.query(
                "SELECT audio_url FROM episodes WHERE id = ?",
                [.int(job.episodeID)],
                map: { sqliteString($0, 0) }
            ).first,
            let sourceURL = URL(string: source),
            let scheme = sourceURL.scheme?.lowercased(),
            scheme == "https" || scheme == "http" else {
                throw AdRemovalPipelineError.episodeAudioURLMissing
            }
            let artifact = try await audioDownloader.download(job: job, sourceURL: sourceURL)
            try Task.checkCancellation()
            guard try artifactStore.validate(artifact) else {
                throw AdRemovalPipelineError.invalidDownloadedArtifact
            }
            let current = try jobStore.requirePipelineJob(
                jobID: job.id,
                episodeID: job.episodeID,
                expected: [.downloading, .downloaded]
            )
            if current.stage == .downloading {
                _ = try jobStore.recordAudioArtifact(jobID: job.id, artifact: artifact)
            } else if current.audioArtifact != artifact {
                throw AdRemovalPipelineError.invalidDownloadedArtifact
            }
        case .transcribing:
            guard let transcriber else {
                throw AdRemovalPipelineError.stageNotConfigured(stage)
            }
            guard let artifact = job.audioArtifact,
                  try artifactStore.validate(artifact) else {
                throw AdRemovalPipelineError.invalidDownloadedArtifact
            }
            let segments = try await transcriber.transcribe(
                audioURL: artifactStore.url(for: artifact.relativePath),
                episodeID: job.episodeID
            )
            try Task.checkCancellation()
            _ = try jobStore.recordTranscript(
                jobID: job.id,
                segments: segments,
                transcriberVersion: transcriber.version
            )
        case .classifying:
            guard let classifier else {
                throw AdRemovalPipelineError.stageNotConfigured(stage)
            }
            _ = try jobStore.requirePipelineJob(
                jobID: job.id,
                episodeID: job.episodeID,
                expected: [.classifying]
            )
            let segments = try jobStore.transcriptSegments(episodeID: job.episodeID)
            let corrections = try jobStore.corrections(podcastID: job.podcastID)
            let windows = try classificationWindowBuilder.makeWindows(
                segments: segments,
                corrections: corrections
            )
            let runID = UUID().uuidString.lowercased()
            var evidence: [AdClassificationEvidence] = []
            do {
                for batchStart in stride(from: 0, to: windows.count, by: 4) {
                    let batch = Array(windows[batchStart..<min(batchStart + 4, windows.count)])
                    let records = try await withThrowingTaskGroup(of: AdClassificationEvidence.self) { group in
                        for window in batch {
                            group.addTask { [self] in
                                try await classifyCloudWindow(
                                    window,
                                    classifier: classifier,
                                    job: job,
                                    runID: runID
                                )
                            }
                        }
                        var completed: [AdClassificationEvidence] = []
                        for try await record in group { completed.append(record) }
                        return completed.sorted { $0.windowIndex < $1.windowIndex }
                    }
                    for record in records {
                        try Task.checkCancellation()
                        try jobStore.recordClassificationEvidence(record, jobID: job.id)
                        evidence.append(record)
                    }
                }
                let ranges = try manifestBuilder.makeRanges(
                    segments: segments,
                    evidence: evidence,
                    descriptor: classifier.descriptor
                )
                try Task.checkCancellation()
                _ = try jobStore.completeClassification(
                    jobID: job.id,
                    runID: runID,
                    descriptor: classifier.descriptor,
                    ranges: ranges
                )
                saveClassificationSnapshot(
                    job: job,
                    segments: segments,
                    windows: windows,
                    evidence: evidence,
                    ranges: ranges
                )
                recordClassificationEvent(
                    "skip_manifest_created",
                    severity: .notice,
                    job: job,
                    fields: [
                        "range_count": String(ranges.count),
                        "merged_segment_ids": ranges.map {
                            "\($0.startSegmentID):\($0.endSegmentID)"
                        }.joined(separator: ",")
                    ]
                )
                await classifier.unload()
            } catch {
                await classifier.unload()
                throw error
            }
        case .queued, .downloaded, .ready, .failed, .cancelled:
            throw AdRemovalPipelineError.unsupportedStage(stage)
        }
    }

    private func classifyCloudWindow(
        _ window: AdClassificationWindow,
        classifier: AdClassifier,
        job: AdRemovalJob,
        runID: String
    ) async throws -> AdClassificationEvidence {
        let delays: [UInt64] = [2, 5, 15]
        for attempt in 0...delays.count {
            try Task.checkCancellation()
            do {
                let rawOutput = try await classifier.classify(window: window)
                let requestLabels = try classifierOutputParser.parse(
                    rawOutput,
                    expectedSegmentIDs: window.requestSegmentIDs
                )
                let labels = requestLabels.enumerated().map { offset, label in
                    AdClassifierLabel(
                        segmentID: window.segmentIDs[offset],
                        classification: label.classification,
                        confidence: label.confidence,
                        reason: label.reason
                    )
                }
                let adCount = labels.filter { $0.classification == .advertisement }.count
                recordClassificationEvent(
                    "classifier_output_validated",
                    severity: .info,
                    job: job,
                    fields: [
                        "window_id": window.id,
                        "window_attempt": String(attempt + 1),
                        "label_count": String(labels.count),
                        "ad_label_count": String(adCount),
                        "content_label_count": String(labels.count - adCount)
                    ]
                )
                return AdClassificationEvidence(
                    runID: runID,
                    episodeID: job.episodeID,
                    windowIndex: window.index,
                    segmentIDs: window.segmentIDs,
                    correctionIDs: window.corrections.map(\.id),
                    prompt: window.prompt,
                    rawOutput: rawOutput,
                    schemaValid: true,
                    validationError: nil,
                    labels: labels,
                    descriptor: classifier.descriptor,
                    createdAt: Int64(Date().timeIntervalSince1970)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recordClassificationEvent(
                    "classifier_window_retry",
                    severity: attempt < delays.count ? .warning : .error,
                    job: job,
                    fields: [
                        "window_id": window.id,
                        "window_attempt": String(attempt + 1),
                        "error": String(describing: error)
                    ]
                )
                guard attempt < delays.count else { throw error }
                try await Task.sleep(for: .seconds(delays[attempt]))
            }
        }
        throw CancellationError()
    }

    private func saveClassificationSnapshot(
        job: AdRemovalJob,
        segments: [AdTranscriptSegment],
        windows: [AdClassificationWindow],
        evidence: [AdClassificationEvidence],
        ranges: [AdSkipRange]
    ) {
        guard let diagnostics else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = (try? encoder.encode(ranges)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        var finalLabels: [String: String] = [:]
        for label in evidence.flatMap(\.labels) {
            finalLabels[label.segmentID] = "\(label.classification.rawValue)|\(label.confidence)|\(label.reason)"
        }
        let validation = evidence.allSatisfy(\.schemaValid)
            ? "valid: \(evidence.count) window(s)"
            : "invalid: \(evidence.compactMap(\.validationError).joined(separator: "; "))"
        try? diagnostics.saveSnapshot(AdRemovalDiagnosticSnapshot(
            schemaVersion: 1,
            createdAt: Date(),
            jobID: job.id,
            episodeID: job.episodeID,
            podcastID: job.podcastID,
            transcriptSegments: segments.map {
                AdRemovalDiagnosticTranscriptSegment(
                    id: $0.id,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text
                )
            },
            classifierPrompt: windows.map(\.prompt).joined(separator: "\n\n--- NEXT WINDOW ---\n\n"),
            classifierInput: windows.map {
                "\($0.id)|segments=\($0.segmentIDs.joined(separator: ","))|input=\($0.estimatedInputTokens)"
            }.joined(separator: "\n"),
            selectedCorrectionExamples: windows.flatMap(\.corrections).map {
                "\($0.id): \($0.transcriptWindow) | \($0.classificationContext)"
            },
            rawClassifierOutput: evidence.map(\.rawOutput).joined(separator: "\n\n--- NEXT OUTPUT ---\n\n"),
            schemaValidationResult: validation,
            finalLabels: finalLabels,
            skipManifest: manifest
        ))
    }

    private func recordClassificationEvent(
        _ eventName: String,
        severity: AdRemovalDiagnosticSeverity,
        job: AdRemovalJob,
        fields: [String: String]
    ) {
        try? diagnostics?.record(
            eventName: eventName,
            severity: severity,
            context: .init(
                jobID: job.id,
                episodeID: job.episodeID,
                podcastID: job.podcastID,
                stage: AdRemovalJobStage.classifying.rawValue,
                attempt: job.attemptCount + 1
            ),
            fields: fields
        )
    }
}
