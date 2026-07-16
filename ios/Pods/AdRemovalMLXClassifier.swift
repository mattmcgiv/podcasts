import Foundation
import MLXLLM
import MLXLMCommon

final class MLXQwenAdClassifier: AdClassifier {
    let descriptor: AdClassifierDescriptor
    let includesVisionInput = false
    let enablesThinking = false

    private let assetStore: AdModelAssetStore
    private let manifest: AdModelManifest
    private let diagnostics: AdRemovalDiagnostics?
    private var container: ModelContainer?
    private var verifiedForProcess = false

    init(
        assetStore: AdModelAssetStore,
        manifest: AdModelManifest = .qwen35FourBitV1,
        diagnostics: AdRemovalDiagnostics? = nil
    ) {
        self.assetStore = assetStore
        self.manifest = manifest
        self.diagnostics = diagnostics
        self.descriptor = AdClassifierDescriptor(
            modelID: manifest.repository,
            modelRevision: manifest.revision,
            quantization: "4-bit",
            promptRevision: "ad-classifier-v1",
            maximumContextTokens: 8_192,
            maximumOutputTokens: 1_024,
            temperature: 0,
            topP: 1
        )
    }

    func classify(window: AdClassificationWindow) async throws -> String {
        let model = try await loadModelIfNeeded()
        let parameters = GenerateParameters(
            maxTokens: descriptor.maximumOutputTokens,
            temperature: Float(descriptor.temperature),
            topP: Float(descriptor.topP)
        )
        let session = ChatSession(
            model,
            generateParameters: parameters,
            additionalContext: ["enable_thinking": false]
        )
        let started = Date()
        do {
            let output = try await session.respond(to: window.prompt)
            try? diagnostics?.record(
                eventName: "classifier_window_generated",
                severity: .info,
                fields: [
                    "window_id": window.id,
                    "segment_count": String(window.segments.count),
                    "input_token_upper_bound": String(window.estimatedInputTokens),
                    "output_byte_count": String(output.utf8.count),
                    "correction_count": String(window.corrections.count),
                    "latency_ms": String(Int(Date().timeIntervalSince(started) * 1_000))
                ]
            )
            return output
        } catch {
            let nsError = error as NSError
            try? diagnostics?.record(
                eventName: "classifier_window_failed",
                severity: .error,
                fields: [
                    "window_id": window.id,
                    "error_domain": nsError.domain,
                    "error_code": String(nsError.code)
                ]
            )
            throw error
        }
    }

    func unload() async {
        guard container != nil else { return }
        container = nil
        try? diagnostics?.record(
            eventName: "classifier_model_unloaded",
            severity: .notice,
            fields: ["model_revision": manifest.revision]
        )
    }

    private func loadModelIfNeeded() async throws -> ModelContainer {
        if let container { return container }
        do {
            if !verifiedForProcess {
                try assetStore.verify(manifest: manifest)
                verifiedForProcess = true
            }
        } catch {
            try? diagnostics?.record(
                eventName: "classifier_model_required",
                severity: .notice,
                fields: ["model_revision": manifest.revision]
            )
            throw AdRemovalPipelinePause(reason: .modelRequired)
        }
        try? diagnostics?.record(
            eventName: "classifier_model_load_started",
            severity: .notice,
            fields: [
                "model_revision": manifest.revision,
                "quantization": descriptor.quantization,
                "vision_enabled": "false",
                "thinking_enabled": "false"
            ]
        )
        let loaded = try await loadModelContainer(
            directory: assetStore.modelDirectory(for: manifest)
        )
        container = loaded
        try? diagnostics?.record(
            eventName: "classifier_model_load_finished",
            severity: .notice,
            fields: ["model_revision": manifest.revision]
        )
        return loaded
    }
}
