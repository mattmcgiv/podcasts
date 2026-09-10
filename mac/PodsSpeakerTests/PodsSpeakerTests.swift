import XCTest
import SQLite3
@testable import Pods_Speaker

@MainActor
final class PodsSpeakerTests: XCTestCase {
    func testPipelinePresentationKeepsPausedRowsAndCollapsesRemainingQueue() {
        func episode(_ id: Int, stage: String, error: String? = nil) -> PipelineEpisode {
            PipelineEpisode(id: String(id), episodeId: id, title: "Episode", podcastTitle: "Show", stage: stage,
                            blockingReason: nil, lastErrorMessage: error, completedUnits: nil, totalUnits: nil)
        }
        let items = [episode(1, stage: "transcribing", error: "memory_busy"),
                     episode(2, stage: "classifying"), episode(3, stage: "transcribing", error: "memory_busy"),
                     episode(4, stage: "queued"), episode(5, stage: "blocked"),
                     episode(6, stage: "transcribing", error: "memory_busy")]
        let presentation = PipelinePresentation(items: items)
        XCTAssertEqual(presentation.featured.map(\.episodeId), [2, 1, 3])
        XCTAssertEqual(presentation.remaining.map(\.episodeId), [4, 6])
        XCTAssertEqual(items[0].displayStage, "Transcribing · paused for memory")
        XCTAssertTrue(presentation.featured.allSatisfy { $0.progress == nil })
    }

    func testPipelineProgressAndWaitingAreHonest() throws {
        func episode(_ stage: String, error: String? = nil, completed: Int? = nil, total: Int? = nil) -> PipelineEpisode {
            PipelineEpisode(id: "1", episodeId: 1, title: "Episode", podcastTitle: "Podcast", stage: stage,
                            blockingReason: nil, lastErrorMessage: error, completedUnits: completed, totalUnits: total)
        }
        XCTAssertNil(episode("transcribing").progress)
        XCTAssertNil(episode("classifying", completed: 3, total: 2).progress)
        XCTAssertNil(episode("classifying", completed: 0, total: 0).progress)
        XCTAssertEqual(episode("classifying", completed: 2, total: 4).progress, 0.5)
        XCTAssertTrue(episode("transcribing", error: "memory_busy").isWaiting)
        XCTAssertTrue(episode("retry").isWaiting)
        XCTAssertTrue(episode("blocked", error: "invalid audio").needsAttention)
        XCTAssertFalse(episode("transcribing").needsAttention)
    }

    func testPipelineRepositoryReadsSnapshotWithoutChangingDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let fixture = """
            CREATE TABLE podcasts(id INTEGER, title TEXT);
            CREATE TABLE episodes(id INTEGER, podcast_id INTEGER, title TEXT, published_at INTEGER);
            CREATE TABLE browser_jobs(episode_id INTEGER, stage TEXT, error TEXT, priority INTEGER);
            CREATE VIEW browser_pending_jobs AS SELECT * FROM browser_jobs WHERE stage!='ready';
            INSERT INTO podcasts VALUES(1,'Show');
            INSERT INTO episodes VALUES(1,1,'Active',1),(2,1,'Blocked',2),(3,1,'Done',3);
            INSERT INTO browser_jobs VALUES(1,'transcribing','memory_busy',0),(2,'blocked','invalid audio',0),(3,'ready',NULL,0);
            """
        XCTAssertEqual(sqlite3_exec(database, fixture, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: url)
        let items = try PipelineRepository(databaseURL: url).snapshot()
        XCTAssertEqual(items.map(\.title), ["Active", "Blocked"])
        XCTAssertTrue(items[0].isWaiting)
        XCTAssertEqual(items[1].attentionLabel, "invalid audio")
        XCTAssertNil(items[0].progress)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "ALTER TABLE browser_jobs ADD COLUMN completed_units INTEGER; ALTER TABLE browser_jobs ADD COLUMN total_units INTEGER; UPDATE browser_jobs SET completed_units=180000,total_units=240000 WHERE episode_id=1;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let migrated = try PipelineRepository(databaseURL: url).snapshot()
        XCTAssertEqual(migrated[0].progress, 0.75)
    }

    func testPipelineRepositoryDoesNotCreateMissingDatabase() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).sqlite")
        XCTAssertThrowsError(try PipelineRepository(databaseURL: url).snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

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
