import AVFoundation
import CoreMedia
import Foundation
import Speech

protocol AdTranscribing: AnyObject {
    var version: String { get }
    func transcribe(audioURL: URL, episodeID: Int64) async throws -> [AdTranscriptSegment]
}

enum AdRemovalTranscriptionError: Error, Equatable, CustomNSError {
    case invalidSegment
    case speechTranscriberUnavailable
    case englishLocaleUnsupported
    case speechModelUnavailable
    case noFinalizedResults

    static let errorDomain = "Pods.AdRemovalTranscriptionError"

    var errorCode: Int {
        switch self {
        case .invalidSegment: 1
        case .speechTranscriberUnavailable: 2
        case .englishLocaleUnsupported: 3
        case .speechModelUnavailable: 4
        case .noFinalizedResults: 5
        }
    }

    var errorUserInfo: [String: Any] {
        let description: String
        switch self {
        case .invalidSegment:
            description = "Speech analysis returned an invalid transcript segment."
        case .speechTranscriberUnavailable:
            description = "On-device speech transcription is unavailable."
        case .englishLocaleUnsupported:
            description = "The installed speech transcriber does not support English."
        case .speechModelUnavailable:
            description = "The required on-device speech model is unavailable."
        case .noFinalizedResults:
            description = "Speech analysis completed without any usable finalized transcript segments."
        }
        return [NSLocalizedDescriptionKey: description]
    }
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

struct AdTranscriptResultAccumulator {
    let language: String
    private(set) var segments: [AdTranscriptSegment] = []
    private(set) var observedFinalResultCount = 0
    private(set) var rejectedFinalResultCount = 0

    mutating func consume(
        isFinal: Bool,
        startTime: Double,
        endTime: Double,
        text: String
    ) {
        guard isFinal else { return }
        observedFinalResultCount += 1
        do {
            segments.append(try AdTranscriptSegmentFactory.make(
                index: segments.count,
                language: language,
                startTime: startTime,
                endTime: endTime,
                text: text
            ))
        } catch {
            rejectedFinalResultCount += 1
        }
    }
}

@available(iOS 26.0, *)
final class AppleSpeechAnalyzerTranscriber: AdTranscribing {
    let version = "apple-speechanalyzer-en-v2"
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
        let resultTask = Task { () throws -> AdTranscriptResultAccumulator in
            var accumulator = AdTranscriptResultAccumulator(language: locale.identifier)
            for try await result in transcriber.results {
                accumulator.consume(
                    isFinal: result.isFinal,
                    startTime: CMTimeGetSeconds(result.range.start),
                    endTime: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)),
                    text: String(result.text.characters)
                )
            }
            return accumulator
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
            let result = try await resultTask.value
            await SpeechModels.endRetention()
            if result.rejectedFinalResultCount > 0 {
                record(
                    eventName: "transcription_results_rejected",
                    severity: .warning,
                    episodeID: episodeID,
                    fields: [
                        "observed_final_result_count": String(result.observedFinalResultCount),
                        "rejected_final_result_count": String(result.rejectedFinalResultCount)
                    ]
                )
            }
            guard !result.segments.isEmpty else {
                record(
                    eventName: "transcription_no_usable_results",
                    severity: .error,
                    episodeID: episodeID,
                    fields: [
                        "observed_final_result_count": String(result.observedFinalResultCount),
                        "rejected_final_result_count": String(result.rejectedFinalResultCount)
                    ]
                )
                throw AdRemovalTranscriptionError.noFinalizedResults
            }
            record(
                eventName: "transcription_completed",
                severity: .notice,
                episodeID: episodeID,
                fields: ["finalized_segment_count": String(result.segments.count)]
            )
            return result.segments
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
