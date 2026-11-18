import Foundation

/// HTTPS client for the Mac backend over Tailscale. The session cookie lives in
/// the app's own cookie store; nothing else on the phone can read it.
final class MacClient {
    static let shared = MacClient()
    static let base = URL(string: "https://sync.pods.mcgiv.dev:8443")!
    /// The app names itself instead of borrowing the website's Origin. The Mac turns
    /// away a mismatched Origin and accepts requests that carry none.
    static let userAgent: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Pods-iOS/\(version) (\(build); iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion))"
    }()

    static func identify(_ request: inout URLRequest) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ios", forHTTPHeaderField: "x-pods-client")
    }

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
        Self.identify(&request)
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
}
