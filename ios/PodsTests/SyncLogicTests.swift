import XCTest
@testable import Pods

final class SyncLogicTests: XCTestCase {
    func testTimelineMapsAroundRemovedAds() {
        let t = Fixture.adCut
        XCTAssertEqual(SyncLogic.originalTime(t, processed: 50), 50)
        XCTAssertEqual(SyncLogic.originalTime(t, processed: 100), 160)
        XCTAssertEqual(SyncLogic.originalTime(t, processed: 150), 210)
        XCTAssertEqual(SyncLogic.originalTime(t, processed: 999), 300)
        XCTAssertEqual(SyncLogic.processedTime(t, original: 210), 150)
        // A position inside the removed ad lands where the episode resumes.
        XCTAssertEqual(SyncLogic.processedTime(t, original: 130), 100)
        XCTAssertEqual(SyncLogic.processedTime(t, original: 999), 240)
        XCTAssertNil(SyncLogic.originalTime(nil, processed: 5))
        XCTAssertNil(SyncLogic.processedTime([], original: 5))
    }

    func testTimelineRoundTripsOutsideAds() {
        for processed in stride(from: 0.0, to: 240, by: 7.5) {
            let original = SyncLogic.originalTime(Fixture.adCut, processed: processed)!
            XCTAssertEqual(SyncLogic.processedTime(Fixture.adCut, original: original)!, processed, accuracy: 0.0001)
        }
    }

    func testOverlayAppliesPlayedPositionAndSettings() {
        let snapshot = Fixture.snapshot([Fixture.episode(1), Fixture.episode(2, timeline: Fixture.adCut), Fixture.episode(3, played: true)])
        let view = SyncLogic.applyOverlay(snapshot, outbox: [
            Fixture.op("1", "played", .bool(true), at: 1_700_000_500_000),
            Fixture.op("2", "position", .object(["seconds": .number(1), "original_seconds": .number(210)])),
            Fixture.op("3", "played", .bool(false)),
            Fixture.op("settings", "speed", .number(2)),
            Fixture.op("settings", "notifications_cleared_through", .number(4)),
        ])
        XCTAssertEqual(view.episodes[0].played_at, 1_700_000_500)
        XCTAssertEqual(view.episodes[1].position_secs, 150, "the original-recording time wins over raw seconds")
        XCTAssertNil(view.episodes[2].played_at)
        XCTAssertEqual(view.settings["speed"], .number(2))
        XCTAssertEqual(view.settings["notifications_cleared_through"], .number(10), "never moves backwards")
        XCTAssertEqual(snapshot.episodes[0].played_at, nil, "the snapshot itself is untouched")
    }

    func testOverlayUsesRawSecondsWithoutTimeline() {
        let view = SyncLogic.applyOverlay(Fixture.snapshot([Fixture.episode(1)]),
                                          outbox: [Fixture.op("1", "position", .object(["seconds": .number(42), "original_seconds": .number(42)]))])
        XCTAssertEqual(view.episodes[0].position_secs, 42)
    }

    func testUnsubscribeHidesShowAndItsUnplayedEpisodes() {
        let snapshot = Fixture.snapshot([Fixture.episode(1, show: 1), Fixture.episode(2, show: 1, played: true), Fixture.episode(3, show: 2)])
        let view = SyncLogic.applyOverlay(snapshot, outbox: [Fixture.op("subscription", Fixture.show(1).feed_url, .bool(false))])
        XCTAssertEqual(view.shows.map(\.id), [2])
        XCTAssertEqual(view.episodes.map(\.id), [2, 3], "played history stays")
    }

    func testCoalesceKeepsNewestUnsentAndEverySentOrRejectedChange() {
        let outbox = [
            Fixture.op("1", "position", .number(1), id: "sent", sent: true),
            Fixture.op("1", "position", .number(2), id: "old"),
            Fixture.op("1", "position", .number(3), id: "new"),
            Fixture.op("2", "played", .bool(true), id: "rejected", error: "no"),
            Fixture.op("2", "played", .bool(false), id: "after-rejected"),
        ]
        XCTAssertEqual(SyncLogic.coalesce(outbox).map(\.id), ["sent", "new", "rejected", "after-rejected"])
    }

    func testBatchSendsOneChangePerFieldAndHoldsRejectedFields() {
        let outbox = [
            Fixture.op("1", "position", .number(1), id: "a", sent: true),
            Fixture.op("1", "position", .number(2), id: "b"),
            Fixture.op("2", "played", .bool(true), id: "c", error: "refused"),
            Fixture.op("2", "played", .bool(false), id: "d"),
            Fixture.op("settings", "speed", .number(2), id: "e"),
        ]
        XCTAssertEqual(SyncLogic.nextBatch(outbox).map(\.id), ["a", "e"])
        XCTAssertEqual(SyncLogic.nextBatch(outbox, limit: 1).map(\.id), ["a"])
    }

    func testValidateRejectsMalformedEpisodes() throws {
        XCTAssertNoThrow(try SyncLogic.validate(Fixture.snapshot([Fixture.episode(1), Fixture.episode(2)])))
        XCTAssertThrowsError(try SyncLogic.validate(Fixture.snapshot([Fixture.episode(1), Fixture.episode(1)])))
        var badCount = Fixture.episode(1); badCount.manifest!.chunks.removeLast()
        XCTAssertThrowsError(try SyncLogic.validate(Fixture.snapshot([badCount])))
        var badHash = Fixture.episode(1); badHash.manifest!.hash = "../../etc/passwd"
        XCTAssertThrowsError(try SyncLogic.validate(Fixture.snapshot([badHash])))
        var wrongEpisode = Fixture.episode(1); wrongEpisode.manifest!.episode_id = 9
        XCTAssertThrowsError(try SyncLogic.validate(Fixture.snapshot([wrongEpisode])))
        var noManifest = Fixture.episode(1); noManifest.manifest = nil
        XCTAssertThrowsError(try SyncLogic.validate(Fixture.snapshot([noManifest])))
        var unknown = Fixture.snapshot([]); unknown.version = 3
        XCTAssertThrowsError(try SyncLogic.validate(unknown))
    }

    func testHashCheck() {
        XCTAssertTrue(SyncLogic.isHash(Fixture.hash(7)))
        XCTAssertFalse(SyncLogic.isHash(Fixture.hash(7).uppercased().replacingOccurrences(of: "0", with: "A")))
        XCTAssertFalse(SyncLogic.isHash(String(Fixture.hash(7).dropLast())))
    }

    func testNextPrefersLaterDownloadedUnplayedEpisode() {
        let list = [Fixture.episode(1, show: 1), Fixture.episode(2, show: 2), Fixture.episode(3, show: 1, played: true),
                    Fixture.episode(4, show: 1), Fixture.episode(5, show: 1)]
        let downloaded: Set<Int> = [1, 2, 4]
        let isDownloaded = { (e: Episode) in downloaded.contains(e.id) }
        XCTAssertEqual(SyncLogic.next(after: list[0], in: list, sameShowOnly: false, isDownloaded: isDownloaded)?.id, 2)
        XCTAssertEqual(SyncLogic.next(after: list[0], in: list, sameShowOnly: true, isDownloaded: isDownloaded)?.id, 4)
        XCTAssertEqual(SyncLogic.next(after: list[3], in: list, sameShowOnly: false, isDownloaded: isDownloaded)?.id, 1, "wraps to the top")
        XCTAssertNil(SyncLogic.next(after: list[1], in: list, sameShowOnly: true, isDownloaded: isDownloaded))
    }

    func testOperationEncodesTheBrowserWireShape() throws {
        let data = try JSONEncoder().encode(JSONValue.object(["seconds": .number(12), "artifact_hash": .string("x"), "flag": .bool(true), "none": .null]))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["seconds"] as? Double, 12)
        XCTAssertEqual(object["artifact_hash"] as? String, "x")
        XCTAssertEqual(object["flag"] as? Bool, true)
        XCTAssertTrue(object["none"] is NSNull)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8)), .bool(true), "bools stay bools")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data("1".utf8)), .number(1))
    }
}
