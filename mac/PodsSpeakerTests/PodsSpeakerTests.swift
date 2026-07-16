import XCTest
@testable import Pods_Speaker

@MainActor
final class PodsSpeakerTests: XCTestCase {
    func testAdRemovalProtocolAndProgressCadenceAreVersionedForLiveStreaming() {
        XCTAssertEqual(CastProtocol.version, 2)
        XCTAssertEqual(SpeakerPlayer.progressReportInterval, 0.25)
    }

    func testProtocolRejectsMissingOrLegacyControlMessages() {
        XCTAssertTrue(CastProtocol.isSupported(["v": 2]))
        XCTAssertFalse(CastProtocol.isSupported([:]))
        XCTAssertFalse(CastProtocol.isSupported(["v": 1]))
    }

    func testResolvedPositionRetainsConfirmedProgressAcrossUnavailableClock() {
        XCTAssertEqual(SpeakerPlayer.resolvedPosition(candidate: .nan, lastKnown: 125), 125)
        XCTAssertEqual(SpeakerPlayer.resolvedPosition(candidate: 0, lastKnown: 125), 125)
        XCTAssertEqual(SpeakerPlayer.resolvedPosition(candidate: 126, lastKnown: 125), 126)
    }
}
