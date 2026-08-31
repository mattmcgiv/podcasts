import AVFoundation
import XCTest
@testable import Pods

final class CarBluetoothPlaybackTests: XCTestCase {
    func testCarBluetoothPortsIncludeTeslaA2DPAndHFPButNotBuiltInSpeaker() {
        XCTAssertTrue(CarBluetoothPlaybackPolicy.isCarBluetoothPort(.bluetoothA2DP))
        XCTAssertTrue(CarBluetoothPlaybackPolicy.isCarBluetoothPort(.bluetoothHFP))
        XCTAssertTrue(CarBluetoothPlaybackPolicy.isCarBluetoothPort(.bluetoothLE))
        XCTAssertTrue(CarBluetoothPlaybackPolicy.isCarBluetoothPort(.carAudio))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCarBluetoothPort(.builtInSpeaker))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCarBluetoothPort(.headphones))
    }

    func testPreferredCarMediaIsA2DPOrCarAudioNotHFPAlone() {
        XCTAssertTrue(CarBluetoothPlaybackPolicy.routeIsPreferredCarMedia([.bluetoothA2DP]))
        XCTAssertTrue(CarBluetoothPlaybackPolicy.routeIsPreferredCarMedia([.bluetoothHFP, .bluetoothA2DP]))
        XCTAssertTrue(CarBluetoothPlaybackPolicy.routeIsPreferredCarMedia([.carAudio]))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.routeIsPreferredCarMedia([.bluetoothHFP]))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.routeIsPreferredCarMedia([.builtInSpeaker]))
    }

    func testLosingCarBluetoothWhilePlayingRemembersResume() {
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .oldDeviceUnavailable,
                previousHadCarBluetooth: true,
                currentHasCarBluetooth: false,
                hasActiveContent: true,
                isPlaying: true,
                resumeWhenCarConnects: false,
                isLocalOutput: true
            ),
            .rememberResume
        )
    }

    func testLosingHeadphonesDoesNotRememberResume() {
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .oldDeviceUnavailable,
                previousHadCarBluetooth: false,
                currentHasCarBluetooth: false,
                hasActiveContent: true,
                isPlaying: true,
                resumeWhenCarConnects: false,
                isLocalOutput: true
            ),
            .none
        )
    }

    func testCarBluetoothConnectResumesWhenIntentIsSet() {
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousHadCarBluetooth: false,
                currentHasCarBluetooth: true,
                hasActiveContent: true,
                isPlaying: false,
                resumeWhenCarConnects: true,
                isLocalOutput: true
            ),
            .scheduleResume
        )
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .routeConfigurationChange,
                previousHadCarBluetooth: true,
                currentHasCarBluetooth: true,
                hasActiveContent: true,
                isPlaying: true,
                resumeWhenCarConnects: true,
                isLocalOutput: true
            ),
            .scheduleResume
        )
    }

    func testCarBluetoothConnectDoesNotAutostartWithoutIntentOrContent() {
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousHadCarBluetooth: false,
                currentHasCarBluetooth: true,
                hasActiveContent: true,
                isPlaying: false,
                resumeWhenCarConnects: false,
                isLocalOutput: true
            ),
            .none
        )
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousHadCarBluetooth: false,
                currentHasCarBluetooth: true,
                hasActiveContent: false,
                isPlaying: false,
                resumeWhenCarConnects: true,
                isLocalOutput: true
            ),
            .none
        )
    }

    func testMacCastOutputNeverAutoResumesOnPhoneRouteChange() {
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousHadCarBluetooth: false,
                currentHasCarBluetooth: true,
                hasActiveContent: true,
                isPlaying: true,
                resumeWhenCarConnects: true,
                isLocalOutput: false
            ),
            .none
        )
    }

    func testScheduledResumeCommitsOnAnyCarBluetoothAfterSettle() {
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                currentHasCarBluetooth: true,
                hasActiveContent: true,
                isLocalOutput: true
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                currentHasCarBluetooth: false,
                hasActiveContent: true,
                isLocalOutput: true
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                currentHasCarBluetooth: true,
                hasActiveContent: false,
                isLocalOutput: true
            )
        )
    }

    func testInterruptionResumeHonorsShouldResumeAndTeslaA2DPWithoutFlag() {
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldResumeAfterInterruption(
                shouldResumeOption: true,
                currentIsPreferredCarMedia: false,
                wasPlayingBeforeInterruption: true,
                resumeWhenCarConnects: false,
                isLocalOutput: true
            )
        )
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldResumeAfterInterruption(
                shouldResumeOption: false,
                currentIsPreferredCarMedia: true,
                wasPlayingBeforeInterruption: true,
                resumeWhenCarConnects: false,
                isLocalOutput: true
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldResumeAfterInterruption(
                shouldResumeOption: false,
                currentIsPreferredCarMedia: false,
                wasPlayingBeforeInterruption: true,
                resumeWhenCarConnects: true,
                isLocalOutput: true
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldResumeAfterInterruption(
                shouldResumeOption: true,
                currentIsPreferredCarMedia: true,
                wasPlayingBeforeInterruption: true,
                resumeWhenCarConnects: true,
                isLocalOutput: false
            )
        )
    }

    func testResumeIntentClearsOnUserPauseAndStop() {
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.nextResumeIntent(
                current: false,
                userInitiatedPause: false,
                startedPlaying: true,
                clearedSession: false
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.nextResumeIntent(
                current: true,
                userInitiatedPause: true,
                startedPlaying: false,
                clearedSession: false
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.nextResumeIntent(
                current: true,
                userInitiatedPause: false,
                startedPlaying: false,
                clearedSession: true
            )
        )
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.nextResumeIntent(
                current: true,
                userInitiatedPause: false,
                startedPlaying: false,
                clearedSession: false
            )
        )
    }

    func testSessionStoreRoundTripsSnapshot() {
        let suite = "pods.carBluetooth.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsCarBluetoothSessionStore(defaults: defaults)
        XCTAssertNil(store.load())

        let snapshot = CarBluetoothSessionSnapshot(
            episodeID: 42,
            publisherURL: "https://example.test/ep.mp3",
            position: 123.5,
            rate: 1.5,
            title: "Episode",
            artist: "Show",
            artworkURL: "http://127.0.0.1:18180/art",
            duration: 3600,
            resumeWhenCarConnects: true
        )
        store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)

        store.clear()
        XCTAssertNil(store.load())
    }
}
