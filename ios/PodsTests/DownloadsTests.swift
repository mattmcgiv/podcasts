import CryptoKit
import XCTest
@testable import Pods

final class DownloadsTests: XCTestCase {
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testVerifyChecksEveryChunk() {
        let size = 1024
        let data = Data((0..<(size * 2 + 100)).map { UInt8($0 % 251) })
        let hashes = [data[0..<size], data[size..<size * 2], data[size * 2..<data.count]].map { digest(Data($0)) }
        XCTAssertTrue(Downloads.verify(data, chunkSize: size, hashes: hashes))
        var flipped = data; flipped[size + 5] ^= 0xff
        XCTAssertFalse(Downloads.verify(flipped, chunkSize: size, hashes: hashes))
        XCTAssertFalse(Downloads.verify(data.prefix(size * 2), chunkSize: size, hashes: hashes), "a short response fails")
        XCTAssertFalse(Downloads.verify(data + Data([1]), chunkSize: size, hashes: hashes), "trailing bytes fail")
        // A slice that does not start at index 0 still verifies.
        let offset = (Data([9, 9, 9]) + data).dropFirst(3)
        XCTAssertTrue(Downloads.verify(offset, chunkSize: size, hashes: hashes))
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
