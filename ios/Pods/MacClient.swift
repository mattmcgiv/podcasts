import Foundation

/// HTTPS client for the Mac backend over Tailscale. The session cookie lives in
/// the app's own cookie store; nothing else on the phone can read it.
final class MacClient {
    static let shared = MacClient()
    static let base = URL(string: "https://sync.pods.mcgiv.dev:8443")!
    /// The backend only accepts state-changing requests from the Pods origin.
    static let origin = "https://pods.mcgiv.dev"

    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:],
                 timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "/api\(path)", relativeTo: Self.base)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SyncError.unreachable }
        guard let http = response as? HTTPURLResponse else { throw SyncError.unreachable }
        return (data, http)
    }

    /// A JSON request that maps HTTP failures to `SyncError`.
    func json<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", body: Data? = nil,
                            headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> T {
        let (data, http) = try await request(path, method: method, body: body, headers: headers, timeout: timeout)
        guard (200..<300).contains(http.statusCode) else { throw Self.failure(http.statusCode, data) }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw SyncError.message("Unsupported Mac library format.") }
    }

    static func failure(_ status: Int, _ data: Data) -> SyncError {
        if status == 401 { return .unauthorized }
        let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
        return .http(status, detail)
    }

    struct AuthStatus: Decodable { var enrolled: Bool; var session: Bool }

    func authStatus() async throws -> AuthStatus {
        try await json(AuthStatus.self, "/auth/status", timeout: 4)
    }

    /// Exchange a single-use code from `manage.py pair` for a session cookie.
    func pair(code: String) async throws {
        let body = try JSONEncoder().encode(["code": code])
        let (data, http) = try await request("/auth/pair", method: "POST", body: body)
        guard http.statusCode == 200 else {
            throw http.statusCode == 401 ? SyncError.message("That pairing code is not valid any more.") : Self.failure(http.statusCode, data)
        }
    }

    /// One verified-size byte range of a published artifact.
    func artifactRange(hash: String, start: Int, end: Int, total: Int) async throws -> Data {
        let (data, http) = try await request("/artifacts/\(hash)", headers: [
            "Range": "bytes=\(start)-\(end)", "If-Range": "\"\(hash)\"",
        ], timeout: 30)
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncError.unauthorized }
        if http.statusCode >= 500 { throw SyncError.unreachable }
        guard http.statusCode == 206,
              http.value(forHTTPHeaderField: "content-range") == "bytes \(start)-\(end)/\(total)",
              data.count == end - start + 1
        else { throw SyncError.message("Audio changed on the Mac. It will download again after the next sync.") }
        return data
    }
}
