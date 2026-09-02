import Foundation
import Security

protocol DeepSeekCredentialStoring: AnyObject {
    var hasAPIKey: Bool { get }
    func readAPIKey() throws -> String?
    func saveAPIKey(_ value: String) throws
}

final class DeepSeekKeychainStore: DeepSeekCredentialStoring {
    private let service = "dev.mcgiv.pods.deepseek"
    private let account = "api-key"

    var hasAPIKey: Bool {
        guard let value = try? readAPIKey() else { return false }
        return !value.isEmpty
    }

    func readAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw DeepSeekClassifierError.keychain(status)
        }
        return value
    }

    func saveAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeepSeekClassifierError.missingAPIKey }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw DeepSeekClassifierError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw DeepSeekClassifierError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum DeepSeekClassifierError: Error, Equatable {
    case missingAPIKey
    case invalidResponse
    case httpStatus(Int)
    case keychain(OSStatus)
}

final class DeepSeekAdClassifier: AdClassifier {
    static let modelID = "deepseek-v4-pro"

    struct Transport {
        let send: (URLRequest) async throws -> (Data, HTTPURLResponse)

        init(_ send: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse)) {
            self.send = send
        }

        static let live = Transport { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DeepSeekClassifierError.invalidResponse }
            return (data, http)
        }
    }

    let descriptor = AdClassifierDescriptor(
        modelID: DeepSeekAdClassifier.modelID,
        modelRevision: "api",
        quantization: "cloud",
        promptRevision: "ad-classifier-v2",
        maximumContextTokens: 1_000_000,
        maximumOutputTokens: 8_192,
        temperature: 0,
        topP: 1
    )

    private let apiKey: () throws -> String?
    private let transport: Transport
    private let diagnostics: AdRemovalDiagnostics?
    private let usageStore: DeepSeekUsageRecording?

    init(
        credentialStore: DeepSeekCredentialStoring,
        transport: Transport = .live,
        diagnostics: AdRemovalDiagnostics? = nil,
        usageStore: DeepSeekUsageRecording? = nil
    ) {
        apiKey = { try credentialStore.readAPIKey() }
        self.transport = transport
        self.diagnostics = diagnostics
        self.usageStore = usageStore
    }

    convenience init(
        apiKey: String,
        transport: Transport,
        diagnostics: AdRemovalDiagnostics? = nil,
        usageStore: DeepSeekUsageRecording? = nil
    ) {
        self.init(
            apiKey: { apiKey },
            transport: transport,
            diagnostics: diagnostics,
            usageStore: usageStore
        )
    }

    private init(
        apiKey: @escaping () throws -> String?,
        transport: Transport,
        diagnostics: AdRemovalDiagnostics?,
        usageStore: DeepSeekUsageRecording?
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.diagnostics = diagnostics
        self.usageStore = usageStore
    }

    func classify(window: AdClassificationWindow) async throws -> String {
        guard let key = try apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw AdRemovalPipelinePause(reason: .modelRequired)
        }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.modelID,
            "messages": [["role": "user", "content": window.prompt]],
            "thinking": ["type": "disabled"],
            "response_format": ["type": "json_object"],
            "max_tokens": descriptor.maximumOutputTokens,
            "stream": false
        ])
        let started = Date()
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw DeepSeekClassifierError.httpStatus(response.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeepSeekClassifierError.invalidResponse
        }
        DeepSeekUsageRecorder.recordIfPresent(
            store: usageStore,
            requestKind: .adDetection,
            model: Self.modelID,
            root: root,
            createdAt: started
        )
        guard let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw DeepSeekClassifierError.invalidResponse
        }
        try? diagnostics?.record(
            eventName: "classifier_window_generated",
            severity: .info,
            fields: [
                "window_id": window.id,
                "segment_count": String(window.segments.count),
                "input_token_upper_bound": String(window.estimatedInputTokens),
                "output_byte_count": String(content.utf8.count),
                "correction_count": String(window.corrections.count),
                "latency_ms": String(Int(Date().timeIntervalSince(started) * 1_000)),
                "provider": "deepseek"
            ]
        )
        return content
    }
}
