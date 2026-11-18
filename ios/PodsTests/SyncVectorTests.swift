import XCTest
@testable import Pods

/// The shared vectors in `client/src/offline/sync-vectors.json` also drive the browser's
/// and the Mac's tests, so the three clients keep the same sync rules.
final class SyncVectorTests: XCTestCase {
    private static let vectors: [String: Any] = {
        // Tests run in the Simulator, which can read the repository on this Mac.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../client/src/offline/sync-vectors.json").standardizedFileURL
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }()

    private func cases(_ key: String) throws -> [[String: Any]] {
        let list = try XCTUnwrap(Self.vectors[key] as? [[String: Any]], "missing \(key) vectors")
        XCTAssertFalse(list.isEmpty)
        return list
    }

    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed))
    }

    private func pairs(_ value: Any?) -> [(Double, Double)] {
        ((value as? [[Double]]) ?? []).map { ($0[0], $0[1]) }
    }

    func testTimelineMapping() throws {
        for vector in try cases("timeline") {
            let name = vector["name"] as? String ?? "?"
            let timeline = try decode([TimelineSpan].self, vector["timeline"] as Any)
            for (processed, original) in pairs(vector["to_original"]) {
                XCTAssertEqual(SyncLogic.originalTime(timeline, processed: processed), original, "\(name): processed \(processed)")
            }
            for (original, processed) in pairs(vector["to_processed"]) {
                XCTAssertEqual(SyncLogic.processedTime(timeline, original: original), processed, "\(name): original \(original)")
            }
        }
    }

    private func outbox(_ list: Any?) throws -> [Pods.Operation] {
        let items = try XCTUnwrap(list as? [[String: Any]])
        return try items.enumerated().map { index, item in
            Fixture.op(item["entity"] as? String ?? "", item["field"] as? String ?? "",
                       try decode(JSONValue.self, item["value"] ?? true), id: item["id"] as? String ?? "op-\(index)",
                       sent: item["sent"] as? Bool, error: item["error"] as? String, at: 1_700_000_000_000 + Int64(index))
        }
    }

    func testOverlay() throws {
        for vector in try cases("overlay") {
            let name = vector["name"] as? String ?? "?"
            let shows = try XCTUnwrap(vector["shows"] as? [[String: Any]]).map { show -> Show in
                var built = Fixture.show(show["id"] as? Int ?? 0)
                built.feed_url = show["feed_url"] as? String ?? ""
                return built
            }
            let episodes = try XCTUnwrap(vector["episodes"] as? [[String: Any]]).map { item -> Episode in
                let timeline = try item["timeline"].map { try decode([TimelineSpan].self, $0) }
                var episode = Fixture.episode(item["id"] as? Int ?? 0, show: item["podcast_id"] as? Int ?? 0,
                                              played: item["played"] as? Bool ?? false, timeline: timeline)
                episode.position_secs = item["position"] as? Double ?? 0
                return episode
            }
            var snapshot = Fixture.snapshot(episodes, shows: shows)
            snapshot.settings = try decode([String: JSONValue].self, vector["settings"] ?? [:])
            let result = SyncLogic.applyOverlay(snapshot, outbox: try outbox(vector["outbox"]))
            let expect = try XCTUnwrap(vector["expect"] as? [String: Any])
            XCTAssertEqual(result.shows.map(\.id), expect["shows"] as? [Int], name)
            XCTAssertEqual(result.settings, try decode([String: JSONValue].self, expect["settings"] ?? [:]), name)
            let expected = try XCTUnwrap(expect["episodes"] as? [[String: Any]])
            XCTAssertEqual(result.episodes.map(\.id), expected.map { $0["id"] as? Int ?? 0 }, name)
            for (episode, want) in zip(result.episodes, expected) {
                XCTAssertEqual(episode.played_at != nil, want["played"] as? Bool, "\(name): episode \(episode.id) played")
                XCTAssertEqual(episode.position_secs, want["position"] as? Double, "\(name): episode \(episode.id) position")
            }
        }
    }

    func testCoalesceAndNextBatch() throws {
        for vector in try cases("coalesce") {
            XCTAssertEqual(SyncLogic.coalesce(try outbox(vector["outbox"])).map(\.id), vector["expect"] as? [String], vector["name"] as? String ?? "?")
        }
        for vector in try cases("next_batch") {
            XCTAssertEqual(SyncLogic.nextBatch(try outbox(vector["outbox"])).map(\.id), vector["expect"] as? [String], vector["name"] as? String ?? "?")
        }
    }

    func testValidate() throws {
        let validate = try XCTUnwrap(Self.vectors["validate"] as? [String: Any])
        let base = try XCTUnwrap(validate["base_episode"] as? [String: Any])
        let list = try XCTUnwrap(validate["cases"] as? [[String: Any]])
        XCTAssertFalse(list.isEmpty)
        for vector in list {
            let name = vector["name"] as? String ?? "?"
            var episode = base
            for (key, value) in vector["episode_patch"] as? [String: Any] ?? [:] { episode[key] = value }
            var manifest = base["manifest"] as? [String: Any] ?? [:]
            for (key, value) in vector["manifest_patch"] as? [String: Any] ?? [:] { manifest[key] = value }
            episode["manifest"] = manifest
            let snapshot: [String: Any] = [
                "version": vector["snapshot_version"] as Any, "cursor": 0, "replace": vector["replace"] as? Bool ?? true,
                "episodes": (vector["duplicate"] as? Bool ?? false) ? [episode, episode] : [episode],
                "shows": [], "settings": [:], "versions": [:],
            ]
            let decoded = try decode(Snapshot.self, snapshot)
            if vector["valid"] as? Bool == true {
                XCTAssertNoThrow(try SyncLogic.validate(decoded), name)
            } else {
                XCTAssertThrowsError(try SyncLogic.validate(decoded), name)
            }
        }
    }
}
