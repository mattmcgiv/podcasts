import Foundation
import FoundationModels

/// Snapshot of `SystemLanguageModel.default.availability` for Settings, enable, and tests.
struct AppleOnDeviceModelAvailability: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        case deviceNotEligible = "device_not_eligible"
        case appleIntelligenceNotEnabled = "apple_intelligence_not_enabled"
        case modelNotReady = "model_not_ready"
        case unknown
    }

    let available: Bool
    let reason: Reason?

    static let available = AppleOnDeviceModelAvailability(available: true, reason: nil)

    static func unavailable(_ reason: Reason) -> AppleOnDeviceModelAvailability {
        AppleOnDeviceModelAvailability(available: false, reason: reason)
    }

    /// Values consumed by Settings as `model_download_state`.
    var downloadState: String {
        guard !available else { return "ready" }
        switch reason {
        case .modelNotReady:
            return "downloading"
        case .appleIntelligenceNotEnabled:
            return "apple_intelligence_disabled"
        case .deviceNotEligible:
            return "device_not_eligible"
        case .unknown, nil:
            return "unavailable"
        }
    }

    var enableError: String {
        switch reason {
        case .deviceNotEligible:
            return "Apple Intelligence is not available on this iPhone, so ad finding cannot be enabled."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in iPhone Settings to enable on-device ad finding."
        case .modelNotReady:
            return "Apple Intelligence is still downloading. Wait until it is ready, then enable ad finding."
        case .unknown, nil:
            return "Apple Intelligence is not ready, so ad finding cannot be enabled."
        }
    }

    static func from(systemAvailability: SystemLanguageModel.Availability) -> AppleOnDeviceModelAvailability {
        switch systemAvailability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady:
                return .unavailable(.modelNotReady)
            @unknown default:
                return .unavailable(.unknown)
            }
        @unknown default:
            return .unavailable(.unknown)
        }
    }
}

protocol AppleOnDeviceModelAvailabilityReading: AnyObject {
    func currentAvailability() -> AppleOnDeviceModelAvailability
}

final class SystemLanguageModelAvailabilityReader: AppleOnDeviceModelAvailabilityReading {
    func currentAvailability() -> AppleOnDeviceModelAvailability {
        AppleOnDeviceModelAvailability.from(systemAvailability: SystemLanguageModel.default.availability)
    }
}

/// Watches on-device model availability so jobs paused as `model_required` can resume.
///
/// A live transition back to `.available` is enough while the app is foregrounded.
/// After backgrounding, availability can flap without a poll, so foreground
/// activation also recovers whenever the model is available *now*.
final class AppleOnDeviceModelAvailabilityObserver: @unchecked Sendable {
    static let pollingInterval: TimeInterval = 5

    private let reader: AppleOnDeviceModelAvailabilityReading
    private let becameAvailable: () -> Void
    private let lock = NSLock()
    private var lastAvailability: AppleOnDeviceModelAvailability
    private var timer: Timer?

    init(
        reader: AppleOnDeviceModelAvailabilityReading,
        becameAvailable: @escaping () -> Void
    ) {
        self.reader = reader
        self.becameAvailable = becameAvailable
        self.lastAvailability = reader.currentAvailability()
    }

    deinit {
        timer?.invalidate()
    }

    /// Returns `true` when availability just transitioned back to available.
    @discardableResult
    func poll() -> Bool {
        lock.lock()
        let previous = lastAvailability
        let current = reader.currentAvailability()
        lastAvailability = current
        lock.unlock()
        let transitioned = !previous.available && current.available
        if transitioned {
            becameAvailable()
        }
        return transitioned
    }

    /// Recovers leftover `model_required` jobs when the model is available now,
    /// even if no unavailable → available transition was observed.
    @discardableResult
    func recoverIfCurrentlyAvailable() -> Bool {
        lock.lock()
        let current = reader.currentAvailability()
        lastAvailability = current
        lock.unlock()
        guard current.available else { return false }
        becameAvailable()
        return true
    }

    /// Foreground path: resume polling, then recover if the model is available now.
    @discardableResult
    func handleForegroundActivation() -> Bool {
        startPolling()
        return recoverIfCurrentlyAvailable()
    }

    func startPolling(
        interval: TimeInterval = AppleOnDeviceModelAvailabilityObserver.pollingInterval
    ) {
        stopPolling()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            _ = self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

protocol AppleOnDevicePromptResponding: AnyObject {
    var isAvailable: Bool { get }
    func respond(to prompt: String) async throws -> String
}

enum AppleFoundationModelError: Error, Equatable {
    case unavailable
    case emptyResponse
}

enum AppleOnDeviceTask: Equatable {
    case classifyAds
    case generateShowNotes
}

@Generable
struct AppleAdClassificationPayload {
    var labels: [AppleAdClassificationLabel]

    init(labels: [AppleAdClassificationLabel]) {
        self.labels = labels
    }
}

@Generable
struct AppleAdClassificationLabel {
    var segmentID: String
    var classification: AppleAdClassificationKind
    var confidence: Double
    var reason: String

    init(segmentID: String, classification: AppleAdClassificationKind, confidence: Double, reason: String) {
        self.segmentID = segmentID
        self.classification = classification
        self.confidence = confidence
        self.reason = reason
    }
}

@Generable
enum AppleAdClassificationKind: Equatable {
    case ad
    case content
}

@Generable
struct AppleShowNotesPayload {
    var chapters: [AppleShowNoteChapter]
}

@Generable
struct AppleShowNoteChapter {
    var segmentID: String
    var title: String
    var summary: String
}

enum AppleAdClassificationJSON {
    static func encode(_ payload: AppleAdClassificationPayload) throws -> String {
        let labels: [[String: Any]] = payload.labels.map { label in
            [
                "segment_id": label.segmentID,
                "classification": label.classification == .ad ? "ad" : "content",
                "confidence": label.confidence,
                "reason": label.reason
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["labels": labels])
        guard let json = String(data: data, encoding: .utf8), !json.isEmpty else {
            throw AppleFoundationModelError.emptyResponse
        }
        return json
    }
}

enum AppleShowNotesJSON {
    static func encode(_ payload: AppleShowNotesPayload) throws -> String {
        let chapters: [[String: Any]] = payload.chapters.map { chapter in
            [
                "segment_id": chapter.segmentID,
                "title": chapter.title,
                "summary": chapter.summary
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["chapters": chapters])
        guard let json = String(data: data, encoding: .utf8), !json.isEmpty else {
            throw AppleFoundationModelError.emptyResponse
        }
        return json
    }
}

/// Live adapter for Apple's on-device SystemLanguageModel (Foundation Models).
/// Each call uses a fresh session so classification windows do not share context.
final class AppleSystemLanguageModelResponder: AppleOnDevicePromptResponding {
    let task: AppleOnDeviceTask

    init(task: AppleOnDeviceTask) {
        self.task = task
    }

    var isAvailable: Bool {
        AppleOnDeviceModelAvailability.from(
            systemAvailability: SystemLanguageModel.default.availability
        ).available
    }

    func respond(to prompt: String) async throws -> String {
        let model = SystemLanguageModel.default
        let availability = AppleOnDeviceModelAvailability.from(systemAvailability: model.availability)
        guard availability.available else {
            throw AppleFoundationModelError.unavailable
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(
            temperature: 0,
            maximumResponseTokens: maximumResponseTokens
        )
        switch task {
        case .classifyAds:
            let response = try await session.respond(
                to: prompt,
                generating: AppleAdClassificationPayload.self,
                options: options
            )
            return try AppleAdClassificationJSON.encode(response.content)
        case .generateShowNotes:
            let response = try await session.respond(
                to: prompt,
                generating: AppleShowNotesPayload.self,
                options: options
            )
            return try AppleShowNotesJSON.encode(response.content)
        }
    }

    private var instructions: String {
        switch task {
        case .classifyAds:
            return """
            You classify podcast transcript segments as advertising or editorial content.
            Use text only. Treat corrections as strong but soft examples of content.
            Return exactly one label for every supplied segment identifier.
            Never invent identifiers or timestamps.
            """
        case .generateShowNotes:
            return EpisodeShowNotesPrompt.systemMessage
        }
    }

    private var maximumResponseTokens: Int {
        switch task {
        case .classifyAds:
            return AdClassifierDescriptor.appleSystemLanguageModelV1.maximumOutputTokens
        case .generateShowNotes:
            return 1_024
        }
    }
}

final class AppleFoundationAdClassifier: AdClassifier {
    let descriptor = AdClassifierDescriptor.appleSystemLanguageModelV1

    private let responder: AppleOnDevicePromptResponding
    private let diagnostics: AdRemovalDiagnostics?

    init(
        responder: AppleOnDevicePromptResponding = AppleSystemLanguageModelResponder(task: .classifyAds),
        diagnostics: AdRemovalDiagnostics? = nil
    ) {
        self.responder = responder
        self.diagnostics = diagnostics
    }

    func classify(window: AdClassificationWindow) async throws -> String {
        guard responder.isAvailable else {
            throw AdRemovalPipelinePause(reason: .modelRequired)
        }
        let started = Date()
        let output: String
        do {
            output = try await responder.respond(to: window.prompt)
        } catch AppleFoundationModelError.unavailable {
            throw AdRemovalPipelinePause(reason: .modelRequired)
        }
        try? diagnostics?.record(
            eventName: "classifier_window_generated",
            severity: .info,
            fields: [
                "window_id": window.id,
                "segment_count": String(window.segments.count),
                "input_token_upper_bound": String(window.estimatedInputTokens),
                "output_byte_count": String(output.utf8.count),
                "correction_count": String(window.corrections.count),
                "latency_ms": String(Int(Date().timeIntervalSince(started) * 1_000)),
                "provider": "apple-foundation-models"
            ]
        )
        return output
    }
}

final class AppleFoundationEpisodeShowNotesGenerator: EpisodeShowNotesGenerating {
    static let maximumPromptBytes = 8_000

    let modelID = AdClassifierDescriptor.appleSystemLanguageModelV1.modelID
    let promptVersion = "episode-show-notes-v1"

    private let responder: AppleOnDevicePromptResponding
    private let parser = EpisodeShowNotesResponseParser()
    private let diagnostics: AdRemovalDiagnostics?

    init(
        responder: AppleOnDevicePromptResponding = AppleSystemLanguageModelResponder(task: .generateShowNotes),
        diagnostics: AdRemovalDiagnostics? = nil
    ) {
        self.responder = responder
        self.diagnostics = diagnostics
    }

    func generate(segments: [AdTranscriptSegment]) async throws -> [EpisodeShowNoteDraft] {
        guard !segments.isEmpty else { throw EpisodeShowNotesError.noContent }
        guard responder.isAvailable else {
            throw AppleFoundationModelError.unavailable
        }
        let fitted = try EpisodeShowNotesPrompt.makeFitting(
            segments: segments,
            maximumBytes: Self.maximumPromptBytes
        )
        let started = Date()
        let raw = try await responder.respond(to: fitted.prompt)
        let notes = try parser.parse(raw, segments: fitted.segments)
        try? diagnostics?.record(
            eventName: "episode_show_notes_generated",
            severity: .notice,
            fields: [
                "chapter_count": String(notes.count),
                "segment_count": String(fitted.segments.count),
                "omitted_segment_count": String(segments.count - fitted.segments.count),
                "latency_ms": String(Int(Date().timeIntervalSince(started) * 1_000)),
                "provider": "apple-foundation-models"
            ]
        )
        return notes
    }
}
