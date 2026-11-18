import CryptoKit
import XCTest
@testable import Pods

final class DownloadsTests: XCTestCase {
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testVerifyChecksEveryChunk() {
        let size = 1024
        let data = Data((0..<(size * 2 + 100)).map { UInt8($0 % 251) })
        let hashes = [data[0..<size], data[size..<size * 2], data[size * 2..<data.count]].map { digest(Data($0)) }
        XCTAssertTrue(MediaStore.verify(data, chunkSize: size, hashes: hashes))
        var flipped = data; flipped[size + 5] ^= 0xff
        XCTAssertFalse(MediaStore.verify(flipped, chunkSize: size, hashes: hashes))
        XCTAssertFalse(MediaStore.verify(data.prefix(size * 2), chunkSize: size, hashes: hashes), "a short response fails")
        XCTAssertFalse(MediaStore.verify(data + Data([1]), chunkSize: size, hashes: hashes), "trailing bytes fail")
        // A slice that does not start at index 0 still verifies.
        let offset = (Data([9, 9, 9]) + data).dropFirst(3)
        XCTAssertTrue(MediaStore.verify(offset, chunkSize: size, hashes: hashes))
    }

    func testPlanFollowsListenOrderWithinLimits() {
        let mb = 1024 * 1024
        let listen = (1...6).map { Fixture.episode($0, bytes: 100 * mb) }
        var preferences = DownloadPreferences(limit: 350 * mb, count: 50, automatic: true)
        XCTAssertEqual(Downloads.plan(listen: listen, preferences: preferences).map(\.id), [1, 2, 3])
        preferences.count = 2
        XCTAssertEqual(Downloads.plan(listen: listen, preferences: preferences).map(\.id), [1, 2])
        preferences.automatic = false
        XCTAssertEqual(Downloads.plan(listen: listen, preferences: preferences), [])
    }

    func testPlanSkipsSummaries() {
        var summary = Fixture.episode(1)
        summary.summary = true
        summary.manifest?.chunks = []
        let plan = Downloads.plan(listen: [summary, Fixture.episode(2)], preferences: DownloadPreferences())
        XCTAssertEqual(plan.map(\.id), [2])
    }

    func testTheWholeDefaultPlanFitsInOneQueue() {
        let mb = 1024 * 1024
        let preferences = DownloadPreferences()
        // Many episodes just over a segment boundary need the most segments for their size.
        for size in [50 * mb, 8 * mb + 1, 100 * mb, 1 * mb] {
            let listen = (1...200).map { Fixture.episode($0, bytes: size) }
            let segments = Downloads.plan(listen: listen, preferences: preferences)
                .map { MediaStore.Part($0.manifest!).segments }.reduce(0, +)
            XCTAssertLessThanOrEqual(segments, Downloads.queueLimit(preferences), "\(size) bytes")
        }
        XCTAssertEqual(Downloads.queueLimit(DownloadPreferences(limit: 20 * 1024 * mb, count: 100, automatic: true)), 512)
    }

    func testScheduleQueuesMissingSegmentsInListenOrderWithinBudget() {
        let mb = 1024 * 1024
        var first = MediaStore.Part(Fixture.manifest(id: 1, bytes: 20 * mb))   // 3 segments
        first.done[0] = true
        let second = MediaStore.Part(Fixture.manifest(id: 2, bytes: 9 * mb))   // 2 segments
        let third = MediaStore.Part(Fixture.manifest(id: 3, bytes: 1 * mb))    // 1 segment
        let queued: Set<Transfers.Info> = [.init(hash: first.hash, segment: 1)]
        let schedule = Downloads.schedule([first, second, third], queued: queued, budget: 3)
        let planned = schedule.start
        XCTAssertEqual(planned.map(\.info), [.init(hash: first.hash, segment: 2), .init(hash: second.hash, segment: 0),
                                             .init(hash: second.hash, segment: 1)], "done and queued segments are skipped")
        XCTAssertEqual(planned.map(\.priority), [URLSessionTask.highPriority, URLSessionTask.defaultPriority, URLSessionTask.defaultPriority])
        XCTAssertEqual(planned[0].range, first.byteRange(2))
        XCTAssertEqual(schedule.priority, [first.hash: URLSessionTask.highPriority, second.hash: URLSessionTask.defaultPriority,
                                           third.hash: URLSessionTask.lowPriority], "even episodes over the budget get a priority")
        XCTAssertEqual(Downloads.schedule([first, second, third], queued: [], budget: 10).start.last?.priority, URLSessionTask.lowPriority)
        XCTAssertEqual(Downloads.schedule([first], queued: [], budget: 0).start, [])
        // Played next now: the same queued transfers move to the front.
        let reordered = Downloads.schedule([third, first], queued: queued, budget: 0)
        XCTAssertEqual(reordered.priority[third.hash], URLSessionTask.highPriority)
        XCTAssertEqual(reordered.priority[first.hash], URLSessionTask.defaultPriority)
    }

    func testQueuedTransfersFollowTheCurrentOrder() {
        let a = MediaStore.Part(Fixture.manifest(id: 1, bytes: 9 * 1024 * 1024))
        let b = MediaStore.Part(Fixture.manifest(id: 2, bytes: 9 * 1024 * 1024))
        let queued: [(info: Transfers.Info, priority: Float)] = [
            (.init(hash: a.hash, segment: 0), URLSessionTask.highPriority), (.init(hash: b.hash, segment: 0), URLSessionTask.defaultPriority),
            (.init(hash: b.hash, segment: 1), URLSessionTask.highPriority),
        ]
        // B is played next now.
        let changes = Downloads.priorityChanges(queued, Downloads.schedule([b, a], queued: Set(queued.map(\.info)), budget: 0))
        XCTAssertEqual(changes, [.init(hash: a.hash, segment: 0): URLSessionTask.defaultPriority,
                                 .init(hash: b.hash, segment: 0): URLSessionTask.highPriority], "already right: left alone")
    }

    func testRequestsLastUntilTheEpisodeIsFinishedAgain() {
        var replay = Fixture.episode(1, played: true)
        var fresh = Fixture.episode(2)
        let requests = [Downloads.Request(id: 1, played_at: replay.played_at, archived_at: nil),
                        Downloads.Request(id: 2, played_at: nil, archived_at: nil),
                        Downloads.Request(id: 3, played_at: nil, archived_at: nil)]
        var episodes = [1: replay, 2: fresh]
        XCTAssertEqual(Downloads.live(requests, episode: { episodes[$0] }).map(\.id), [1, 2], "an episode that left the library goes")
        fresh.played_at = 1_700_000_500
        replay.played_at = 1_700_000_600
        episodes = [1: replay, 2: fresh]
        XCTAssertEqual(Downloads.live(requests, episode: { episodes[$0] }), [],
                       "marked played mid-download, or played to the end again: no longer wanted")
        fresh.played_at = nil
        fresh.archived_at = 1_700_000_700
        XCTAssertEqual(Downloads.live([requests[1]], episode: { _ in fresh }), [])
    }

    @MainActor
    func testRequestsSurviveARelaunch() throws {
        let suite = "pods-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = [Downloads.Request(id: 7, played_at: nil, archived_at: nil), Downloads.Request(id: 3, played_at: 1.5, archived_at: nil)]
        Downloads.save(saved, to: defaults)
        XCTAssertEqual(Downloads(defaults: defaults).requested, saved)
        XCTAssertEqual(Downloads(defaults: UserDefaults(suiteName: "\(suite)-empty")!).requested, [])
    }

    func testLogTailStartsAtAWholeLine() {
        let data = Data("tial line\nsecond\nthird\n".utf8)
        XCTAssertEqual(DeviceLog.wholeLines(data, cut: true), "second\nthird\n")
        XCTAssertEqual(DeviceLog.wholeLines(data, cut: false), "tial line\nsecond\nthird\n")
        XCTAssertEqual(DeviceLog.wholeLines(Data("no newline".utf8), cut: true), "")
    }
}

final class MediaStoreTests: XCTestCase {
    private var folder: URL!
    private var store: MediaStore!
    private let chunk = 1024 * 1024

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
        store = MediaStore(directory: folder)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A real artifact of `chunks` chunks (the last one short) and its manifest.
    private func artifact(chunks: Int) -> (Data, Manifest) {
        let bytes = (chunks - 1) * chunk + 1000
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 11) })
        let hashes = stride(from: 0, to: bytes, by: chunk).map { digest(data[$0..<min($0 + chunk, bytes)]) }
        let manifest = Manifest(version: 1, episode_id: 1, hash: digest(data), source_hash: nil, bytes: bytes, duration: 60,
                                chunk_size: chunk, chunks: hashes, timeline: nil, media: nil)
        return (data, manifest)
    }

    private func transfer(_ data: Data, _ range: ClosedRange<Int>) throws -> URL {
        // Outside the media folder, like the system's own download location.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID().uuidString).tmp")
        try Data(data[range]).write(to: url)
        return url
    }

    func testSegmentsAssembleInAnyOrderIntoAVerifiedFile() throws {
        let (data, manifest) = artifact(chunks: 2 * MediaStore.segmentChunks + 1)
        let part = store.prepare(manifest)
        XCTAssertEqual(part.segments, 3)
        XCTAssertEqual(part.byteRange(0), 0...(MediaStore.segmentChunks * chunk - 1))
        XCTAssertEqual(part.byteRange(2).upperBound, manifest.bytes - 1)
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 2, from: transfer(data, part.byteRange(2))), .segment)
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 0, from: transfer(data, part.byteRange(0))), .segment)
        XCTAssertEqual(store.part(manifest.hash)?.receivedBytes, part.byteRange(0).count + part.byteRange(2).count)
        XCTAssertTrue(store.inventory().complete.isEmpty, "nothing is playable until every segment is in")
        // A repeated segment changes nothing.
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 0, from: transfer(data, part.byteRange(0))), .segment)
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 1, from: transfer(data, part.byteRange(1))), .complete)
        XCTAssertEqual(store.inventory().complete, [manifest.hash])
        XCTAssertEqual(try Data(contentsOf: store.finalURL(manifest.hash, "m4a")), data)
        XCTAssertNil(store.part(manifest.hash))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.partURL(manifest.hash).path))
    }

    func testCorruptOrShortTransfersAreRefused() throws {
        let (data, manifest) = artifact(chunks: 3)
        let part = store.prepare(manifest)
        var corrupt = data
        corrupt[10] ^= 0xff
        XCTAssertThrowsError(try store.store(hash: manifest.hash, segment: 0, from: transfer(corrupt, part.byteRange(0))))
        XCTAssertThrowsError(try store.store(hash: manifest.hash, segment: 0, from: transfer(data, 0...100)))
        XCTAssertEqual(store.part(manifest.hash)?.done, [false])
        XCTAssertTrue(store.inventory().complete.isEmpty)
    }

    func testRemovedOrUnknownEpisodesAreStale() throws {
        let (data, manifest) = artifact(chunks: 3)
        let part = store.prepare(manifest)
        let file = try transfer(data, part.byteRange(0))
        store.sweep(keep: [])
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 0, from: file), .stale)
        XCTAssertEqual(try store.store(hash: String(repeating: "e", count: 64), segment: 0, from: file), .stale)
        XCTAssertTrue(store.inventory().complete.isEmpty)
    }

    func testPrepareKeepsMatchingStateAndRestartsChangedManifests() throws {
        let (data, manifest) = artifact(chunks: MediaStore.segmentChunks + 1)
        let part = store.prepare(manifest)
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 0, from: transfer(data, part.byteRange(0))), .segment)
        XCTAssertEqual(store.prepare(manifest).done, [true, false])
        var changed = manifest
        changed.chunks[0] = String(repeating: "0", count: 64)
        XCTAssertEqual(store.prepare(changed).done, [false, false])
    }

    func testSweepKeepsWantedFilesAndDropsUntrustedLeftovers() throws {
        let keep = String(repeating: "a", count: 64), drop = String(repeating: "b", count: 64), legacy = String(repeating: "c", count: 64)
        try Data([1]).write(to: store.finalURL(keep, "m4a"))
        try Data([1]).write(to: store.stateURL(keep))
        try Data([1]).write(to: store.finalURL(drop, "mp4"))
        try Data([1]).write(to: store.partURL(legacy))
        store.sweep(keep: [keep, legacy])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["\(keep).m4a"],
                       "unwanted files, a part without state, and state for a finished file all go")
        store.removeAll(except: nil)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testFinishedFilesAreNeverReplacedByLeftoverState() throws {
        let (data, manifest) = artifact(chunks: MediaStore.segmentChunks + 1)
        let part = store.prepare(manifest)
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 0, from: transfer(data, part.byteRange(0))), .segment)
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 1, from: transfer(data, part.byteRange(1))), .complete)
        // As if the app died between finishing the file and removing its state.
        try JSONEncoder().encode(part).write(to: store.stateURL(manifest.hash))
        XCTAssertNil(store.part(manifest.hash), "state next to a finished file is not trusted")
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 1, from: transfer(data, part.byteRange(1))), .stale)
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 0, from: transfer(data, part.byteRange(0))), .stale)
        XCTAssertEqual(try Data(contentsOf: store.finalURL(manifest.hash, "m4a")), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.partURL(manifest.hash).path))
    }

    func testStateClaimingMissingSegmentsStartsOver() throws {
        let (data, manifest) = artifact(chunks: 2 * MediaStore.segmentChunks + 1)
        let part = store.prepare(manifest)
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 0, from: transfer(data, part.byteRange(0))), .segment)
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 2, from: transfer(data, part.byteRange(2))), .segment)
        // An interrupted removal took the partial file but left its state.
        try FileManager.default.removeItem(at: store.partURL(manifest.hash))
        XCTAssertNil(store.part(manifest.hash))
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 1, from: transfer(data, part.byteRange(1))), .stale)
        XCTAssertEqual(store.prepare(manifest).done, [false, false, false], "it starts over instead of assembling holes")
        // A partial file shorter than its furthest finished segment is not trusted either.
        let fresh = store.prepare(manifest)
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 2, from: transfer(data, fresh.byteRange(2))), .segment)
        let handle = try FileHandle(forWritingTo: store.partURL(manifest.hash))
        try handle.truncate(atOffset: UInt64(fresh.byteRange(1).upperBound))
        try handle.close()
        XCTAssertNil(store.part(manifest.hash))
    }

    func testAWriteThatRacedARestartIsDropped() throws {
        let (data, manifest) = artifact(chunks: MediaStore.segmentChunks + 1)
        let part = store.prepare(manifest)
        // The main actor removes the episode and starts it over while this segment is written.
        let shared = store!
        store.afterWrite = { shared.sweep(keep: []); _ = shared.prepare(manifest) }
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 0, from: transfer(data, part.byteRange(0))), .stale)
        store.afterWrite = nil
        let restarted = try XCTUnwrap(store.part(manifest.hash))
        XCTAssertNotEqual(restarted.generation, part.generation)
        XCTAssertEqual(restarted.done, [false, false], "the racing write is not counted")
        XCTAssertEqual(try store.store(hash: manifest.hash, segment: 0, from: transfer(data, part.byteRange(0))), .segment)
        XCTAssertEqual(store.part(manifest.hash)?.done, [true, false])
    }

    func testTransferOutcomesFromResponseToStorage() throws {
        let (data, manifest) = artifact(chunks: MediaStore.segmentChunks + 1)
        let part = store.prepare(manifest)
        let range = part.byteRange(0)
        let info = Transfers.Info(hash: manifest.hash, segment: 0)
        let good = "bytes \(range.lowerBound)-\(range.upperBound)/\(manifest.bytes)"
        func process(_ status: Int, _ contentRange: String?, _ file: URL, _ info: Transfers.Info = info) -> Transfers.Outcome {
            Transfers.process(info, status: status, contentRange: contentRange, location: file, store: store)
        }
        XCTAssertEqual(process(401, nil, try transfer(data, range)), .unauthorized)
        guard case .failed = process(206, "bytes 0-9/\(manifest.bytes)", try transfer(data, range)) else { return XCTFail("wrong range") }
        var corrupt = data; corrupt[3] ^= 0xff
        guard case .failed = process(206, good, try transfer(corrupt, range)) else { return XCTFail("corrupt data") }
        XCTAssertEqual(store.part(manifest.hash)?.done, [false, false], "nothing failed was recorded")
        XCTAssertEqual(process(206, good, try transfer(data, range)), .stored(complete: false))
        let last = part.byteRange(1)
        XCTAssertEqual(process(206, "bytes \(last.lowerBound)-\(last.upperBound)/\(manifest.bytes)", try transfer(data, last),
                               .init(hash: manifest.hash, segment: 1)), .stored(complete: true))
        XCTAssertEqual(process(206, good, try transfer(data, range)), .stale, "a finished episode takes no more data")
        XCTAssertEqual(try Data(contentsOf: store.finalURL(manifest.hash, "m4a")), data)
    }

    func testResponsesAreClassifiedBeforeAnythingIsWritten() {
        let range = 0...99
        XCTAssertNil(Transfers.classify(status: 206, contentRange: "bytes 0-99/500", expected: range, total: 500))
        XCTAssertEqual(Transfers.classify(status: 401, contentRange: nil, expected: range, total: 500), .unauthorized)
        XCTAssertEqual(Transfers.classify(status: 403, contentRange: nil, expected: range, total: 500), .unauthorized)
        XCTAssertEqual(Transfers.classify(status: 502, contentRange: nil, expected: range, total: 500), .unreachable)
        XCTAssertEqual(Transfers.classify(status: 206, contentRange: "bytes 0-99/500", expected: nil, total: nil), .stale)
        guard case .failed = Transfers.classify(status: 206, contentRange: "bytes 0-99/600", expected: range, total: 500) else {
            return XCTFail("a different artifact length must fail")
        }
        guard case .failed = Transfers.classify(status: 200, contentRange: nil, expected: range, total: 500) else {
            return XCTFail("a whole new file (If-Range mismatch) must fail")
        }
    }
}

final class RemindersTests: XCTestCase {
    func testRemindersFallThirtySixAndSixHoursBeforeExpiry() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let early = Reminders.plan(expiry: expiry, now: expiry.addingTimeInterval(-3 * 86400))
        XCTAssertEqual(early.map(\.id), Reminders.identifiers)
        XCTAssertEqual(early.map(\.at), [expiry.addingTimeInterval(-36 * 3600), expiry.addingTimeInterval(-6 * 3600)])
        XCTAssertEqual(Reminders.plan(expiry: expiry, now: expiry.addingTimeInterval(-24 * 3600)).map(\.id), [Reminders.identifiers[1]])
        XCTAssertEqual(Reminders.plan(expiry: expiry, now: expiry.addingTimeInterval(-3600)), [])
    }
}

final class FormatAndCarTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(Format.clock(0), "0:00")
        XCTAssertEqual(Format.clock(65.9), "1:05")
        XCTAssertEqual(Format.clock(3725), "1:02:05")
        XCTAssertEqual(Format.clock(.nan), "0:00")
        XCTAssertEqual(Format.speed(1.5), "1.5×")
        XCTAssertEqual(Format.speed(2), "2×")
    }

    func testOnlyUnmistakableCarNamesAutoResume() {
        XCTAssertTrue(CarResume.looksLikeCar("Tesla Model 3"))
        XCTAssertTrue(CarResume.looksLikeCar("Model Y"))
        XCTAssertFalse(CarResume.looksLikeCar("Matt's AirPods Pro"))
        XCTAssertFalse(CarResume.looksLikeCar("Beats Studio Buds"))
        XCTAssertFalse(CarResume.looksLikeCar("Kitchen speaker"))
        XCTAssertFalse(CarResume.looksLikeCar("Sync"), "generic names need the user to mark them")
    }

    func testSimulatorBuildHasNoSigningExpiry() {
        XCTAssertNil(Signing.expiry)
    }
}
