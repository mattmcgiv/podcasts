import Foundation

@_silgen_name("pods_backend_prepare")
private func pods_backend_prepare(_ live: UnsafePointer<CChar>, _ seed: UnsafePointer<CChar>?) -> Int32

@_silgen_name("pods_backend_open")
private func pods_backend_open(_ path: UnsafePointer<CChar>) -> OpaquePointer?

@_silgen_name("pods_backend_configure")
private func pods_backend_configure(_ handle: OpaquePointer?, _ json: UnsafePointer<CChar>) -> Int32

@_silgen_name("pods_backend_close")
private func pods_backend_close(_ handle: OpaquePointer?)

@_silgen_name("pods_backend_handle")
private func pods_backend_handle(
    _ handle: OpaquePointer?,
    _ method: UnsafePointer<CChar>,
    _ target: UnsafePointer<CChar>,
    _ headers: UnsafePointer<CChar>?,
    _ body: UnsafePointer<UInt8>?,
    _ bodyLen: Int,
    _ outStatus: UnsafeMutablePointer<Int32>,
    _ outLen: UnsafeMutablePointer<Int>
) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("pods_backend_free")
private func pods_backend_free(_ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int)

enum RustBackendError: Error {
    case openFailed
    case prepareFailed
}

final class RustBackend: PodsRequestHandling, PlaybackProgressRecording {
    private let handle: OpaquePointer

    static func prepare(liveURL: URL, seedURL: URL?) throws {
        let live = liveURL.path
        let status: Int32 = live.withCString { livePtr in
            if let seedURL {
                return seedURL.path.withCString { seedPtr in
                    pods_backend_prepare(livePtr, seedPtr)
                }
            }
            return pods_backend_prepare(livePtr, nil)
        }
        if status != 0 {
            throw RustBackendError.prepareFailed
        }
    }

    init(databasePath: String) throws {
        guard let handle = databasePath.withCString({ pods_backend_open($0) }) else {
            throw RustBackendError.openFailed
        }
        self.handle = handle
        if let config = Self.podcastIndexConfigJSON() {
            _ = config.withCString { pods_backend_configure(handle, $0) }
        }
    }

    private static func podcastIndexConfigJSON() -> String? {
        guard let url = Bundle.main.url(forResource: "PodcastIndexCredentials", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        let key = (values["PODCASTINDEX_KEY"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = (values["PODCASTINDEX_SECRET"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (values["PODCASTINDEX_BASE_URL"] as? String ?? "https://api.podcastindex.org/api/1.0")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !secret.isEmpty else {
            return nil
        }
        let payload: [String: String] = [
            "podcastindex_key": key,
            "podcastindex_secret": secret,
            "podcastindex_base_url": base
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: encoded, encoding: .utf8) else {
            return nil
        }
        return json
    }

    deinit {
        pods_backend_close(handle)
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        var status: Int32 = 500
        var len: Int = 0
        let headerBlob = request.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        let ptr = request.method.withCString { method in
            request.target.withCString { target in
                headerBlob.withCString { headers in
                    request.body.withUnsafeBytes { raw in
                        let bodyPtr = raw.bindMemory(to: UInt8.self).baseAddress
                        return pods_backend_handle(
                            handle,
                            method,
                            target,
                            headers,
                            bodyPtr,
                            request.body.count,
                            &status,
                            &len
                        )
                    }
                }
            }
        }
        defer {
            if let ptr {
                pods_backend_free(ptr, len)
            }
        }
        guard let ptr else {
            return .error("rust backend returned no body", statusCode: 500)
        }
        let bytes = Data(bytes: ptr, count: len)
        var headers: [String: String] = [:]
        var body = bytes
        if let split = bytes.range(of: Data("\n\n".utf8)) {
            let headerText = String(data: bytes[..<split.lowerBound], encoding: .utf8) ?? ""
            for line in headerText.split(separator: "\n") {
                if let colon = line.firstIndex(of: ":") {
                    let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[name] = String(value)
                }
            }
            body = bytes[split.upperBound...]
        }
        return HTTPResponse(statusCode: Int(status), headers: headers, body: body)
    }

    func recordPlaybackProgress(episodeID: Int64, seconds: Double) {
        let payload = "{\"seconds\":\(seconds)}"
        let request = HTTPRequest(
            method: "PUT",
            target: "/api/episodes/\(episodeID)/position",
            headers: ["content-type": "application/json"],
            body: Data(payload.utf8)
        )
        Task { _ = await handle(request) }
    }
}
