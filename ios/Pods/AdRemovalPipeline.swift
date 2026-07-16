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

    init(
        database: PodsDatabase,
        jobStore: AdRemovalJobStore,
        artifactStore: AdRemovalArtifactStore,
        audioDownloader: AdRemovalAudioDownloading,
        transcriber: AdTranscribing? = nil
    ) {
        self.database = database
        self.jobStore = jobStore
        self.artifactStore = artifactStore
        self.audioDownloader = audioDownloader
        self.transcriber = transcriber
    }

    func execute(stage: AdRemovalJobStage, job: AdRemovalJob) async throws {
        switch stage {
        case .downloading:
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
            guard try artifactStore.validate(artifact) else {
                throw AdRemovalPipelineError.invalidDownloadedArtifact
            }
            _ = try jobStore.recordAudioArtifact(jobID: job.id, artifact: artifact)
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
            _ = try jobStore.recordTranscript(
                jobID: job.id,
                segments: segments,
                transcriberVersion: transcriber.version
            )
        case .classifying:
            throw AdRemovalPipelineError.stageNotConfigured(stage)
        case .queued, .downloaded, .ready, .failed, .cancelled:
            throw AdRemovalPipelineError.unsupportedStage(stage)
        }
    }
}
