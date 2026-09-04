// DEPRECATED as of 1 October 2026. Do not review, extend, or append to this file.
// See ios/DEPRECATED.md.

import Foundation

struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.target = target
        self.headers = headers
        self.body = body
    }
}

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    static func jsonObject(_ value: [String: String], statusCode: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: data
        )
    }

    static func noContent() -> HTTPResponse {
        HTTPResponse(statusCode: 204, headers: [:], body: Data())
    }

    static func error(_ message: String, statusCode: Int = 422) -> HTTPResponse {
        jsonObject(["error": message], statusCode: statusCode)
    }
}

protocol PodsRequestHandling: AnyObject {
    func handle(_ request: HTTPRequest) async -> HTTPResponse
}

protocol PlaybackProgressRecording: AnyObject {
    func recordPlaybackProgress(episodeID: Int64, seconds: Double)
}
