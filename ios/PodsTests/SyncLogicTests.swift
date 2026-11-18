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

    private func summarized(_ episode: Episode) -> Episode {
        var summary = episode
        summary.summary = true
        summary.notes_html = ""
        summary.show_notes = []
        summary.manifest?.chunks = []
        return summary
    }

    func testDetailFillsOnlyWhatASummaryLeavesOut() throws {
        var full = Fixture.episode(1, played: true)
        full.notes_html = "<p>Notes</p>"
        full.show_notes = [ShowNote(id: "n0", start_time: 0, title: "Intro", summary: "")]
        full.position_secs = 10
        // Newer play state arrived in a pull while the detail was loading.
        var summary = summarized(full)
        summary.position_secs = 400
        summary.played_at = 1_700_000_900
        let filled = try XCTUnwrap(SyncLogic.filled(summary, with: full))
        XCTAssertFalse(filled.isSummary)
        XCTAssertEqual(filled.manifest?.chunks, full.manifest?.chunks)
        XCTAssertEqual(filled.notes_html, "<p>Notes</p>")
        XCTAssertEqual(filled.show_notes?.first?.title, "Intro")
        XCTAssertEqual(filled.position_secs, 400)
        XCTAssertEqual(filled.played_at, 1_700_000_900)
        XCTAssertTrue(SyncLogic.isPublished(filled, compact: false))
        XCTAssertEqual(filled.local_detail, true)
        // A republished episode (another file) is not mixed with the old detail.
        var republished = summary
        republished.manifest?.hash = Fixture.hash(99)
        republished.audio_url = "/_media/\(Fixture.hash(99)).m4a"
        XCTAssertNil(SyncLogic.filled(republished, with: full))
        XCTAssertNil(SyncLogic.filled(full, with: full), "only a summary is filled")
    }

    func testPullsKeepFetchedDetailWhileTheFileIsTheSame() throws {
        let original = Fixture.episode(1, played: true)
        let fetched = try XCTUnwrap(SyncLogic.filled(summarized(original), with: original))
        // Sent in full while unplayed, then finished: nothing to keep, it shrinks.
        let finished = Fixture.episode(2, played: true), other = Fixture.episode(3, played: true)
        var previous = Fixture.snapshot([fetched, finished, summarized(other)])
        previous.version = 2
        var incoming = Fixture.snapshot([summarized(original), summarized(finished), summarized(other)])
        incoming.version = 2
        let kept = SyncLogic.keepingDetail(incoming, from: previous)
        XCTAssertFalse(kept.episodes[0].isSummary)
        XCTAssertEqual(kept.episodes[0].manifest?.chunks, original.manifest?.chunks)
        XCTAssertTrue(kept.episodes[1].isSummary, "only detail this device asked for is kept")
        XCTAssertTrue(kept.episodes[2].isSummary)
        XCTAssertNoThrow(try SyncLogic.validate(kept))
        XCTAssertEqual(SyncLogic.keepingDetail(incoming, from: nil), incoming)
    }

    func testAnUnplayedSummaryAsksForAFullPull() {
        var summary = summarized(Fixture.episode(1, played: true))
        XCTAssertFalse(SyncLogic.needsFullRecords(Fixture.snapshot([summary])))
        summary.played_at = nil
        XCTAssertTrue(SyncLogic.needsFullRecords(Fixture.snapshot([summary])))
        XCTAssertFalse(SyncLogic.needsFullRecords(Fixture.snapshot([Fixture.episode(1)])))
        XCTAssertFalse(SyncLogic.needsFullRecords(nil))
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
