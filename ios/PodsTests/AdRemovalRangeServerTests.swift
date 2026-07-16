import XCTest
@testable import Pods

final class AdRemovalRangeServerTests: XCTestCase {
    private let authorization = AdRemovalStreamAuthorization(
        episodeID: 42,
        fileURL: URL(fileURLWithPath: "/tmp/episode.mp3"),
        byteCount: 100,
        token: "secret-token",
        playbackSessionID: "playback-session"
    )

    func testOnlyAuthorizedActiveEpisodeCanBeRead() {
        XCTAssertEqual(plan(target: "/episode/42?token=wrong").statusCode, 401)
        XCTAssertEqual(plan(target: "/episode/41?token=secret-token").statusCode, 404)
        XCTAssertEqual(
            AdRemovalRangeRequestPlanner.plan(
                request: .init(method: "GET", target: "/episode/42?token=secret-token", headers: [:]),
                authorization: nil
            ).statusCode,
            401
        )
    }

    func testFullGetAndHeadExposeLengthAndRangeSupport() {
        let get = plan(target: "/episode/42?token=secret-token")
        XCTAssertEqual(get.statusCode, 200)
        XCTAssertEqual(get.bodyRange, 0..<100)
        XCTAssertEqual(get.headers["Accept-Ranges"], "bytes")
        XCTAssertEqual(get.headers["Content-Length"], "100")

        let head = plan(method: "HEAD", target: "/episode/42?token=secret-token")
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertNil(head.bodyRange)
        XCTAssertEqual(head.headers["Content-Length"], "100")
    }

    func testClosedOpenAndSuffixRangesUseRFCByteSemantics() {
        let closed = plan(
            target: "/episode/42?token=secret-token",
            headers: ["Range": "bytes=10-19"]
        )
        XCTAssertEqual(closed.statusCode, 206)
        XCTAssertEqual(closed.bodyRange, 10..<20)
        XCTAssertEqual(closed.headers["Content-Range"], "bytes 10-19/100")
        XCTAssertEqual(closed.headers["Content-Length"], "10")

        XCTAssertEqual(
            plan(target: "/episode/42?token=secret-token", headers: ["Range": "bytes=90-"]).bodyRange,
            90..<100
        )
        XCTAssertEqual(
            plan(target: "/episode/42?token=secret-token", headers: ["Range": "bytes=-10"]).bodyRange,
            90..<100
        )
    }

    func testInvalidOrMultipleRangeIsRejectedWithoutBody() {
        for value in ["items=0-1", "bytes=100-101", "bytes=20-10", "bytes=0-1,3-4"] {
            let response = plan(
                target: "/episode/42?token=secret-token",
                headers: ["Range": value]
            )
            XCTAssertEqual(response.statusCode, 416, value)
            XCTAssertEqual(response.headers["Content-Range"], "bytes */100", value)
            XCTAssertNil(response.bodyRange, value)
        }
    }

    func testUnsupportedMethodIsRejected() {
        let response = plan(method: "POST", target: "/episode/42?token=secret-token")
        XCTAssertEqual(response.statusCode, 405)
        XCTAssertEqual(response.headers["Allow"], "GET, HEAD")
        XCTAssertNil(response.bodyRange)
    }

    private func plan(
        method: String = "GET",
        target: String,
        headers: [String: String] = [:]
    ) -> AdRemovalRangeResponsePlan {
        AdRemovalRangeRequestPlanner.plan(
            request: .init(method: method, target: target, headers: headers),
            authorization: authorization
        )
    }
}
