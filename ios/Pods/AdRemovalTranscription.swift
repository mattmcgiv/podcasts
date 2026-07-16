import AVFoundation
import CoreMedia
import Foundation
import Speech

protocol AdTranscribing: AnyObject {
    var version: String { get }
    func transcribe(audioURL: URL, episodeID: Int64) async throws -> [AdTranscriptSegment]
}

enum AdRemovalTranscriptionError: Error, Equatable {
    case invalidSegment
    case speechTranscriberUnavailable
    case englishLocaleUnsupported
    case speechModelUnavailable
    case noFinalizedResults
}

enum AdTranscriptSegmentFactory {
    static func make(
        index: Int,
        language: String,
        startTime: Double,
        endTime: Double,
        text: String
    ) throws -> AdTranscriptSegment {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard index >= 0,
              !language.isEmpty,
              startTime.isFinite,
              endTime.isFinite,
              startTime >= 0,
              endTime > startTime,
              !text.isEmpty else {
            throw AdRemovalTranscriptionError.invalidSegment
        }
        let startMilliseconds = Int64((startTime * 1_000).rounded())
        let endMilliseconds = Int64((endTime * 1_000).rounded())
        return AdTranscriptSegment(
            id: String(
                format: "segment-%06d-%09lld-%09lld",
                index,
                startMilliseconds,
                endMilliseconds
            ),
            index: index,
            language: language,
            startTime: startTime,
            endTime: endTime,
            text: text
        )
    }
}

@available(iOS 26.0, *)
final class AppleSpeechAnalyzerTranscriber: AdTranscribing {
    let version = "apple-speechanalyzer-en-v1"
    private let diagnostics: AdRemovalDiagnostics?

    init(diagnostics: AdRemovalDiagnostics? = nil) {
        self.diagnostics = diagnostics
    }

    func transcribe(audioURL: URL, episodeID: Int64) async throws -> [AdTranscriptSegment] {
        guard SpeechTranscriber.isAvailable else {
            throw AdRemovalTranscriptionError.speechTranscriberUnavailable
        }
        let requestedLocale = Locale(identifier: "en-US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AdRemovalTranscriptionError.englishLocaleUnsupported
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await ensureModel(for: transcriber, locale: locale, episodeID: episodeID)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultTask = Task { () throws -> [AdTranscriptSegment] in
            var segments: [AdTranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                segments.append(try AdTranscriptSegmentFactory.make(
                    index: segments.count,
                    language: locale.identifier,
                    startTime: CMTimeGetSeconds(result.range.start),
                    endTime: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)),
                    text: String(result.text.characters)
                ))
            }
            return segments
        }

        record(
            eventName: "transcription_started",
            severity: .notice,
            episodeID: episodeID,
            fields: ["transcriber_version": version, "locale": locale.identifier]
        )
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let segments = try await resultTask.value
            await SpeechModels.endRetention()
            guard !segments.isEmpty else {
                throw AdRemovalTranscriptionError.noFinalizedResults
            }
            record(
                eventName: "transcription_completed",
                severity: .notice,
                episodeID: episodeID,
                fields: ["finalized_segment_count": String(segments.count)]
            )
            return segments
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            await SpeechModels.endRetention()
            throw error
        }
    }

    private func ensureModel(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        episodeID: Int64
    ) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        record(
            eventName: "speech_model_status",
            severity: .info,
            episodeID: episodeID,
            fields: ["status": String(describing: status), "locale": locale.identifier]
        )
        switch status {
        case .installed:
            break
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) else {
                throw AdRemovalTranscriptionError.speechModelUnavailable
            }
            try await request.downloadAndInstall()
        case .unsupported:
            throw AdRemovalTranscriptionError.speechModelUnavailable
        @unknown default:
            throw AdRemovalTranscriptionError.speechModelUnavailable
        }
        _ = try await AssetInventory.reserve(locale: locale)
    }

    private func record(
        eventName: String,
        severity: AdRemovalDiagnosticSeverity,
        episodeID: Int64,
        fields: [String: String]
    ) {
        try? diagnostics?.record(
            eventName: eventName,
            severity: severity,
            context: AdRemovalDiagnosticContext(
                episodeID: episodeID,
                stage: AdRemovalJobStage.transcribing.rawValue
            ),
            fields: fields
        )
    }
}
