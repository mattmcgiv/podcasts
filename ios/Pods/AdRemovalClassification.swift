import CoreFoundation
import Foundation

struct AdClassifierDescriptor: Equatable, Codable {
    let modelID: String
    let modelRevision: String
    let quantization: String
    let promptRevision: String
    let maximumContextTokens: Int
    let maximumOutputTokens: Int
    let temperature: Double
    let topP: Double

    static let qwen3OneSevenBFourBitV1 = AdClassifierDescriptor(
        modelID: "Qwen/Qwen3-1.7B-MLX-4bit",
        modelRevision: "21457c6f51ed54a7c16e988c0844db973815c137",
        quantization: "4-bit",
        promptRevision: "ad-classifier-v1",
        maximumContextTokens: 8_192,
        maximumOutputTokens: 384,
        temperature: 0,
        topP: 1
    )

    /// Apple's on-device SystemLanguageModel. Context is 4,096 tokens on iOS 26.0–26.3
    /// and larger on later system models; the window builder uses this conservative cap.
    static let appleSystemLanguageModelV1 = AdClassifierDescriptor(
        modelID: "apple/system-language-model",
        modelRevision: "on-device",
        quantization: "system",
        promptRevision: "ad-classifier-v1",
        maximumContextTokens: 4_096,
        maximumOutputTokens: 384,
        temperature: 0,
        topP: 1
    )
}

protocol AdClassifier: AnyObject {
    var descriptor: AdClassifierDescriptor { get }
    func classify(window: AdClassificationWindow) async throws -> String
    func unload() async
}

extension AdClassifier {
    func unload() async {}
}

struct AdClassificationLimits: Equatable {
    let maximumContextTokens: Int
    let reservedOutputTokens: Int
    let correctionTokenBudget: Int
    let maximumSegmentsPerWindow: Int
    let overlapSegmentCount: Int

    static let production = AdClassificationLimits(
        maximumContextTokens: AdClassifierDescriptor.appleSystemLanguageModelV1.maximumContextTokens,
        reservedOutputTokens: AdClassifierDescriptor.appleSystemLanguageModelV1.maximumOutputTokens,
        correctionTokenBudget: 1_024,
        maximumSegmentsPerWindow: 8,
        overlapSegmentCount: 2
    )

    /// Matches the overlapping window walk used by `AdClassificationWindowBuilder`.
    func totalWindows(segmentCount: Int) -> Int? {
        guard segmentCount > 0,
              maximumSegmentsPerWindow > 0,
              overlapSegmentCount >= 0,
              overlapSegmentCount < maximumSegmentsPerWindow else {
            return nil
        }
        if segmentCount <= maximumSegmentsPerWindow { return 1 }
        let step = maximumSegmentsPerWindow - overlapSegmentCount
        return 1 + (segmentCount - maximumSegmentsPerWindow + step - 1) / step
    }
}

struct AdClassificationWindow: Equatable {
    let index: Int
    let segments: [AdTranscriptSegment]
    let corrections: [AdCorrection]
    let prompt: String
    let estimatedInputTokens: Int
    let estimatedCorrectionTokens: Int
    let maximumInputTokens: Int

    var id: String { "window-\(index)" }
    var segmentIDs: [String] { segments.map(\.id) }
    var requestSegmentIDs: [String] { segments.indices.map { "s\($0)" } }
}

enum AdClassificationWindowError: Error, Equatable {
    case invalidLimits
    case noSegments
    case segmentExceedsInputBudget(String)
}

struct AdClassificationWindowBuilder {
    let limits: AdClassificationLimits

    func makeWindows(
        segments: [AdTranscriptSegment],
        corrections: [AdCorrection]
    ) throws -> [AdClassificationWindow] {
        guard limits.maximumContextTokens > 0,
              limits.reservedOutputTokens > 0,
              limits.reservedOutputTokens < limits.maximumContextTokens,
              limits.correctionTokenBudget >= 0,
              limits.maximumSegmentsPerWindow > 0,
              limits.overlapSegmentCount >= 0,
              limits.overlapSegmentCount < limits.maximumSegmentsPerWindow else {
            throw AdClassificationWindowError.invalidLimits
        }
        guard !segments.isEmpty else {
            throw AdClassificationWindowError.noSegments
        }

        let maximumInputTokens = limits.maximumContextTokens - limits.reservedOutputTokens
        var result: [AdClassificationWindow] = []
        var start = 0
        while start < segments.count {
            var selected: [AdTranscriptSegment] = []
            var candidateWindow: AdClassificationWindow?
            let maximumEnd = min(segments.count, start + limits.maximumSegmentsPerWindow)

            for end in (start + 1)...maximumEnd {
                let candidateSegments = Array(segments[start..<end])
                let candidateCorrections = selectCorrections(
                    corrections,
                    for: candidateSegments,
                    tokenBudget: limits.correctionTokenBudget
                )
                let prompt = Self.makePrompt(
                    segments: candidateSegments,
                    corrections: candidateCorrections
                )
                let estimatedInput = Self.conservativeTokenEstimate(prompt)
                if estimatedInput > maximumInputTokens {
                    break
                }
                selected = candidateSegments
                candidateWindow = AdClassificationWindow(
                    index: result.count,
                    segments: candidateSegments,
                    corrections: candidateCorrections,
                    prompt: prompt,
                    estimatedInputTokens: estimatedInput,
                    estimatedCorrectionTokens: Self.correctionTokenEstimate(candidateCorrections),
                    maximumInputTokens: maximumInputTokens
                )
            }

            guard !selected.isEmpty, let candidateWindow else {
                throw AdClassificationWindowError.segmentExceedsInputBudget(segments[start].id)
            }
            result.append(candidateWindow)
            let end = start + selected.count
            guard end < segments.count else { break }
            start = max(start + 1, end - limits.overlapSegmentCount)
        }
        return result
    }

    private func selectCorrections(
        _ corrections: [AdCorrection],
        for segments: [AdTranscriptSegment],
        tokenBudget: Int
    ) -> [AdCorrection] {
        guard tokenBudget > 0 else { return [] }
        let transcriptTerms = Self.terms(in: segments.map(\.text).joined(separator: " "))
        let ranked = corrections
            .filter(\.active)
            .map { correction in
                (
                    correction: correction,
                    relevance: transcriptTerms.intersection(Self.terms(in: correction.transcriptWindow)).count
                )
            }
            .filter { $0.relevance > 0 }
            .sorted {
                if $0.relevance != $1.relevance { return $0.relevance > $1.relevance }
                if $0.correction.createdAt != $1.correction.createdAt {
                    return $0.correction.createdAt > $1.correction.createdAt
                }
                return $0.correction.id < $1.correction.id
            }

        var selected: [AdCorrection] = []
        for candidate in ranked {
            let proposed = selected + [candidate.correction]
            if Self.correctionTokenEstimate(proposed) <= tokenBudget {
                selected = proposed
            }
        }
        return selected
    }

    private static func makePrompt(
        segments: [AdTranscriptSegment],
        corrections: [AdCorrection]
    ) -> String {
        let correctionText = corrections.isEmpty
            ? "(none)"
            : corrections.map {
                "CORRECTION \($0.id): \($0.transcriptWindow) | context: \($0.classificationContext)"
            }.joined(separator: "\n")
        let transcriptText = segments.enumerated().map { offset, segment in
            "SEGMENT s\(offset) [\(Self.time(segment.startTime))-\(Self.time(segment.endTime))]: \(segment.text)"
        }.joined(separator: "\n")
        return """
        You classify podcast transcript segments as ad or content.
        Use text only. Do not reason aloud. Treat corrections as strong but soft examples of content.
        Return exactly one compact JSON object and no markdown or commentary.
        The root must contain only \"labels\". Each label must contain only segment_id,
        classification (\"ad\" or \"content\"), confidence (0 through 1), and a reason of at most 8 words.
        Return exactly one label for every supplied segment identifier. Never create identifiers or timestamps.

        FALSE-POSITIVE CORRECTIONS:
        \(correctionText)

        TRANSCRIPT:
        \(transcriptText)
        """
    }

    private static func conservativeTokenEstimate(_ text: String) -> Int {
        // Byte count is a deterministic upper bound for byte-fallback tokenizers.
        text.utf8.count
    }

    private static func correctionTokenEstimate(_ corrections: [AdCorrection]) -> Int {
        corrections.reduce(0) { partial, correction in
            partial + conservativeTokenEstimate(
                "\(correction.id)|\(correction.transcriptWindow)|\(correction.classificationContext)"
            )
        }
    }

    private static func terms(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func time(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

enum AdClassifierClassification: String, Equatable, Codable {
    case advertisement = "ad"
    case content
}

struct AdClassifierLabel: Equatable, Codable {
    let segmentID: String
    let classification: AdClassifierClassification
    let confidence: Double
    let reason: String
}

struct AdClassificationEvidence: Equatable {
    let runID: String
    let episodeID: Int64
    let windowIndex: Int
    let segmentIDs: [String]
    let correctionIDs: [String]
    let prompt: String
    let rawOutput: String
    let schemaValid: Bool
    let validationError: String?
    let labels: [AdClassifierLabel]
    let descriptor: AdClassifierDescriptor
    let createdAt: Int64
}

enum AdClassifierOutputError: Error, Equatable {
    case malformedJSON
    case invalidSchema
    case unknownSegment(String)
    case duplicateSegment(String)
    case missingSegment(String)
    case invalidClassification(String)
    case invalidConfidence(String)
    case invalidReason(String)
}

struct AdClassifierOutputParser {
    func parse(_ rawOutput: String, expectedSegmentIDs: [String]) throws -> [AdClassifierLabel] {
        let normalized = normalize(rawOutput)
        guard let data = normalized.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else {
            throw AdClassifierOutputError.malformedJSON
        }
        guard Set(object.keys) == ["labels"],
              let rawLabels = object["labels"] as? [[String: Any]] else {
            throw AdClassifierOutputError.invalidSchema
        }

        let expected = Set(expectedSegmentIDs)
        guard expected.count == expectedSegmentIDs.count else {
            throw AdClassifierOutputError.invalidSchema
        }
        var labelsByID: [String: AdClassifierLabel] = [:]
        for rawLabel in rawLabels {
            guard Set(rawLabel.keys) == ["segment_id", "classification", "confidence", "reason"],
                  let segmentID = rawLabel["segment_id"] as? String,
                  let rawClassification = rawLabel["classification"] as? String,
                  let confidenceNumber = rawLabel["confidence"] as? NSNumber,
                  CFGetTypeID(confidenceNumber) != CFBooleanGetTypeID(),
                  let reason = rawLabel["reason"] as? String else {
                throw AdClassifierOutputError.invalidSchema
            }
            guard expected.contains(segmentID) else {
                throw AdClassifierOutputError.unknownSegment(segmentID)
            }
            guard labelsByID[segmentID] == nil else {
                throw AdClassifierOutputError.duplicateSegment(segmentID)
            }
            guard let classification = AdClassifierClassification(rawValue: rawClassification) else {
                throw AdClassifierOutputError.invalidClassification(segmentID)
            }
            let confidence = confidenceNumber.doubleValue
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw AdClassifierOutputError.invalidConfidence(segmentID)
            }
            let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedReason.isEmpty, trimmedReason.count <= 240 else {
                throw AdClassifierOutputError.invalidReason(segmentID)
            }
            labelsByID[segmentID] = AdClassifierLabel(
                segmentID: segmentID,
                classification: classification,
                confidence: confidence,
                reason: trimmedReason
            )
        }

        for segmentID in expectedSegmentIDs where labelsByID[segmentID] == nil {
            throw AdClassifierOutputError.missingSegment(segmentID)
        }
        return expectedSegmentIDs.compactMap { labelsByID[$0] }
    }

    private func normalize(_ rawOutput: String) -> String {
        var candidate = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```"), candidate.hasSuffix("```") {
            let firstNewline = candidate.firstIndex(of: "\n")
            if let firstNewline {
                let language = candidate[candidate.index(candidate.startIndex, offsetBy: 3)..<firstNewline]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if language.isEmpty || language == "json" {
                    candidate = String(candidate[candidate.index(after: firstNewline)..<candidate.index(candidate.endIndex, offsetBy: -3)])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        if let data = candidate.data(using: .utf8),
           let wrapped = try? JSONDecoder().decode(String.self, from: data) {
            candidate = wrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return candidate
    }
}

enum AdSkipManifestError: Error, Equatable {
    case invalidThreshold
    case missingLabel(String)
}

struct AdSkipManifestBuilder {
    let advertisementThreshold: Double
    let now: () -> Int64

    init(
        advertisementThreshold: Double = 0.55,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.advertisementThreshold = advertisementThreshold
        self.now = now
    }

    func makeRanges(
        segments: [AdTranscriptSegment],
        evidence: [AdClassificationEvidence],
        descriptor: AdClassifierDescriptor
    ) throws -> [AdSkipRange] {
        guard advertisementThreshold.isFinite,
              (0...1).contains(advertisementThreshold) else {
            throw AdSkipManifestError.invalidThreshold
        }
        let observations = Dictionary(grouping: evidence.flatMap(\.labels), by: \.segmentID)
        var selectedAdvertisements: [(AdTranscriptSegment, AdClassifierLabel)] = []
        for segment in segments {
            guard let labels = observations[segment.id], !labels.isEmpty else {
                throw AdSkipManifestError.missingLabel(segment.id)
            }
            let strongestAdvertisement = labels
                .filter { $0.classification == .advertisement }
                .max { $0.confidence < $1.confidence }
            if let strongestAdvertisement,
               strongestAdvertisement.confidence >= advertisementThreshold {
                selectedAdvertisements.append((segment, strongestAdvertisement))
            }
        }

        let classifierVersion = "\(descriptor.modelID)@\(descriptor.modelRevision)"
        var ranges: [AdSkipRange] = []
        var cursor = 0
        while cursor < selectedAdvertisements.count {
            var group = [selectedAdvertisements[cursor]]
            cursor += 1
            while cursor < selectedAdvertisements.count,
                  selectedAdvertisements[cursor].0.index == group.last!.0.index + 1 {
                group.append(selectedAdvertisements[cursor])
                cursor += 1
            }
            let first = group[0]
            let last = group[group.count - 1]
            let reasons = group.map { $0.1.reason }.reduce(into: [String]()) { result, reason in
                if !result.contains(reason) { result.append(reason) }
            }
            let joinedReason = reasons.joined(separator: "; ")
            let reason = String(joinedReason.prefix(240))
            ranges.append(AdSkipRange(
                id: "ad-\(first.0.id)--\(last.0.id)",
                startSegmentID: first.0.id,
                endSegmentID: last.0.id,
                startTime: first.0.startTime,
                endTime: last.0.endTime,
                confidence: group.map { $0.1.confidence }.min() ?? advertisementThreshold,
                reason: reason,
                classifierVersion: classifierVersion,
                promptVersion: descriptor.promptRevision,
                createdAt: now(),
                disabled: false
            ))
        }
        return ranges
    }
}
