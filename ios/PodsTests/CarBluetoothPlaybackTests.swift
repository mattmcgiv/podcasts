import AVFoundation
import XCTest
@testable import Pods

final class CarBluetoothPlaybackTests: XCTestCase {
    private let now: TimeInterval = 1_000_000
    private let teslaA2DP = CarBluetoothRouteDescriptor(
        uid: "aa:bb:cc:dd:ee:ff-tacl",
        name: "Tesla Model 3",
        portType: .bluetoothA2DP
    )
    private let teslaHFP = CarBluetoothRouteDescriptor(
        uid: "aa:bb:cc:dd:ee:ff-tsco",
        name: "Tesla Model 3",
        portType: .bluetoothHFP
    )
    private let otherTesla = CarBluetoothRouteDescriptor(
        uid: "11:22:33:44:55:66-tacl",
        name: "Tesla Model Y",
        portType: .bluetoothA2DP
    )
    private let airPods = CarBluetoothRouteDescriptor(
        uid: "de:ad:be:ef:00:01-tacl",
        name: "AirPods Pro",
        portType: .bluetoothA2DP
    )
    private let jbl = CarBluetoothRouteDescriptor(
        uid: "01:23:45:67:89:ab-tacl",
        name: "JBL Flip",
        portType: .bluetoothA2DP
    )
    private let wired = CarBluetoothRouteDescriptor(
        uid: "WiredHeadphones",
        name: "Headphones",
        portType: .headphones
    )
    private let speaker = CarBluetoothRouteDescriptor(
        uid: "Speaker",
        name: "Speaker",
        portType: .builtInSpeaker
    )

    func testDeviceKindSeparatesTeslaFromAirPodsAndSpeakers() {
        XCTAssertEqual(teslaA2DP.kind, .car)
        XCTAssertEqual(teslaHFP.kind, .car)
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.deviceKind(portType: .carAudio, name: "Car"),
            .car
        )
        XCTAssertEqual(airPods.kind, .headphone)
        XCTAssertEqual(wired.kind, .headphone)
        XCTAssertEqual(jbl.kind, .otherBluetooth)
        XCTAssertEqual(speaker.kind, .notBluetooth)
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.deviceKind(portType: .bluetoothA2DP, name: "Beats Solo"),
            .headphone
        )
    }

    func testTeslaHFPAndA2DPShareStableIdentity() {
        XCTAssertEqual(teslaA2DP.stableDeviceKey, "aa:bb:cc:dd:ee:ff")
        XCTAssertTrue(teslaA2DP.matches(teslaHFP))
        XCTAssertFalse(teslaA2DP.matches(otherTesla))
        XCTAssertFalse(teslaA2DP.matches(airPods))
        XCTAssertFalse(airPods.matches(jbl))
    }

    func testLosingTeslaWhilePlayingRemembersThatCarAndEpisode() {
        let action = CarBluetoothPlaybackPolicy.action(
            reason: .oldDeviceUnavailable,
            previousRoutes: [teslaA2DP],
            currentRoutes: [speaker],
            hasActiveContent: true,
            isPlaying: true,
            intent: nil,
            currentEpisodeID: 9,
            isLocalOutput: true,
            now: now
        )
        guard case .remember(let intent) = action else {
            return XCTFail("expected remember, got \(action)")
        }
        XCTAssertTrue(intent.device.matches(teslaA2DP))
        XCTAssertEqual(intent.episodeID, 9)
        XCTAssertEqual(intent.armedAt, now)
    }

    func testLosingAirPodsA2DPDoesNotRememberResume() {
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .oldDeviceUnavailable,
                previousRoutes: [airPods],
                currentRoutes: [speaker],
                hasActiveContent: true,
                isPlaying: true,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .none
        )
    }

    func testLosingUnknownSpeakerDoesNotRememberResume() {
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .oldDeviceUnavailable,
                previousRoutes: [jbl],
                currentRoutes: [speaker],
                hasActiveContent: true,
                isPlaying: true,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .none
        )
    }

    func testLosingWiredHeadphonesDoesNotRememberResume() {
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .oldDeviceUnavailable,
                previousRoutes: [wired],
                currentRoutes: [speaker],
                hasActiveContent: true,
                isPlaying: true,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .none
        )
    }

    func testTeslaReconnectWithMatchingIdentitySchedulesArmedEpisode() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now - 60)
        let action = CarBluetoothPlaybackPolicy.action(
            reason: .newDeviceAvailable,
            previousRoutes: [speaker],
            currentRoutes: [teslaHFP],
            hasActiveContent: true,
            isPlaying: false,
            intent: armed,
            currentEpisodeID: 9,
            isLocalOutput: true,
            now: now
        )
        guard case .schedule(let scheduled) = action else {
            return XCTFail("expected schedule, got \(action)")
        }
        XCTAssertTrue(scheduled.device.matches(teslaHFP))
        XCTAssertEqual(scheduled.episodeID, 9)
        XCTAssertEqual(scheduled.armedAt, armed.armedAt)
    }

    func testAirPodsConnectDoesNotConsumeTeslaIntent() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now - 60)
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousRoutes: [speaker],
                currentRoutes: [airPods],
                hasActiveContent: true,
                isPlaying: false,
                intent: armed,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .none
        )
    }

    func testDifferentCarDoesNotConsumeTeslaIntent() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now - 60)
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousRoutes: [speaker],
                currentRoutes: [otherTesla],
                hasActiveContent: true,
                isPlaying: false,
                intent: armed,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .none
        )
    }

    func testTeslaConnectWithoutArmedIntentDoesNotAutostart() {
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousRoutes: [speaker],
                currentRoutes: [teslaA2DP],
                hasActiveContent: true,
                isPlaying: false,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .none
        )
    }

    func testPlayingOntoAppearingTeslaSchedulesThatCar() {
        let action = CarBluetoothPlaybackPolicy.action(
            reason: .newDeviceAvailable,
            previousRoutes: [speaker],
            currentRoutes: [teslaA2DP],
            hasActiveContent: true,
            isPlaying: true,
            intent: nil,
            currentEpisodeID: 4,
            isLocalOutput: true,
            now: now
        )
        guard case .schedule(let scheduled) = action else {
            return XCTFail("expected schedule, got \(action)")
        }
        XCTAssertTrue(scheduled.device.matches(teslaA2DP))
        XCTAssertEqual(scheduled.episodeID, 4)
    }

    func testExpiredIntentClearsInsteadOfScheduling() {
        let expired = CarBluetoothResumeIntent(
            device: teslaA2DP,
            episodeID: 9,
            armedAt: now - CarBluetoothPlaybackPolicy.resumeIntentTTL - 1
        )
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousRoutes: [speaker],
                currentRoutes: [teslaA2DP],
                hasActiveContent: true,
                isPlaying: false,
                intent: expired,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .clear
        )
        XCTAssertNil(CarBluetoothPlaybackPolicy.validatedIntent(expired, now: now))
    }

    func testLegacySnapshotWithoutIdentityDoesNotValidate() {
        let snapshot = CarBluetoothSessionSnapshot(
            episodeID: 1,
            publisherURL: "https://example.test/a.mp3",
            position: 10,
            rate: 1,
            title: "A",
            artist: "B",
            artworkURL: nil,
            duration: 100,
            resumeIntent: nil
        )
        XCTAssertNil(CarBluetoothPlaybackPolicy.validatedIntent(snapshot.resumeIntent, now: now))
    }

    func testMacCastOutputNeverAutoResumesOnPhoneRouteChange() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now)
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousRoutes: [speaker],
                currentRoutes: [teslaA2DP],
                hasActiveContent: true,
                isPlaying: true,
                intent: armed,
                currentEpisodeID: 9,
                isLocalOutput: false,
                now: now
            ),
            .none
        )
    }

    func testCommitRequiresMatchingCarIdentityAndSameEpisode() {
        let scheduled = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now - 10)
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: scheduled,
                currentRoutes: [teslaA2DP],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: scheduled,
                currentRoutes: [airPods],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: scheduled,
                currentRoutes: [teslaA2DP],
                currentEpisodeID: 10,
                isLocalOutput: true,
                now: now
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: scheduled,
                currentRoutes: [teslaA2DP],
                currentEpisodeID: 9,
                isLocalOutput: false,
                now: now
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: scheduled,
                currentRoutes: [teslaHFP],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            "HFP-only after settle is the handshake, not the stereo"
        )
        let expired = CarBluetoothResumeIntent(
            device: teslaA2DP,
            episodeID: 9,
            armedAt: now - CarBluetoothPlaybackPolicy.resumeIntentTTL - 5
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: expired,
                currentRoutes: [teslaA2DP],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            )
        )
    }

    func testHFPOnlyPastSettleDoesNotCommit() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now - 60)
        let scheduled = CarBluetoothPlaybackPolicy.action(
            reason: .newDeviceAvailable,
            previousRoutes: [speaker],
            currentRoutes: [teslaHFP],
            hasActiveContent: true,
            isPlaying: false,
            intent: armed,
            currentEpisodeID: 9,
            isLocalOutput: true,
            now: now
        )
        guard case .schedule(let pending) = scheduled else {
            return XCTFail("HFP may start the settle timer, got \(scheduled)")
        }
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: pending,
                currentRoutes: [teslaHFP],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now + CarBluetoothPlaybackPolicy.resumeSettleDelay
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.isMediaCapableCarRoute(teslaHFP)
        )
    }

    func testHFPThenA2DPSequenceCommitsOnlyAfterMediaRoute() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now - 60)
        let hfp = CarBluetoothPlaybackPolicy.action(
            reason: .newDeviceAvailable,
            previousRoutes: [speaker],
            currentRoutes: [teslaHFP],
            hasActiveContent: true,
            isPlaying: false,
            intent: armed,
            currentEpisodeID: 9,
            isLocalOutput: true,
            now: now
        )
        guard case .schedule(let afterHFP) = hfp else {
            return XCTFail("expected schedule on Tesla HFP identity, got \(hfp)")
        }
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: afterHFP,
                currentRoutes: [teslaHFP],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now + CarBluetoothPlaybackPolicy.resumeSettleDelay
            )
        )

        let a2dp = CarBluetoothPlaybackPolicy.action(
            reason: .routeConfigurationChange,
            previousRoutes: [teslaHFP],
            currentRoutes: [teslaHFP, teslaA2DP],
            hasActiveContent: true,
            isPlaying: false,
            intent: afterHFP,
            currentEpisodeID: 9,
            isLocalOutput: true,
            now: now + CarBluetoothPlaybackPolicy.resumeSettleDelay
        )
        guard case .schedule(let afterA2DP) = a2dp else {
            return XCTFail("expected reschedule once A2DP is up, got \(a2dp)")
        }
        XCTAssertTrue(CarBluetoothPlaybackPolicy.isMediaCapableCarRoute(teslaA2DP))
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: afterA2DP,
                currentRoutes: [teslaHFP, teslaA2DP],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now + (2 * CarBluetoothPlaybackPolicy.resumeSettleDelay)
            )
        )
    }

    func testInterruptionCarMatchRequiresMediaCapableRoute() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now - 60)
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.currentCarMatchesIntent(
                routes: [teslaHFP],
                intent: armed,
                now: now
            )
        )
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.currentCarMatchesIntent(
                routes: [teslaHFP, teslaA2DP],
                intent: armed,
                now: now
            )
        )
    }

    func testInterruptionResumeDoesNotTreatGenericBluetoothAsCar() {
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldResumeAfterInterruption(
                shouldResumeOption: true,
                wasPlayingBeforeInterruption: true,
                currentCarMatchesArmedIntent: false,
                isLocalOutput: true
            )
        )
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldResumeAfterInterruption(
                shouldResumeOption: false,
                wasPlayingBeforeInterruption: true,
                currentCarMatchesArmedIntent: true,
                isLocalOutput: true
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldResumeAfterInterruption(
                shouldResumeOption: false,
                wasPlayingBeforeInterruption: true,
                currentCarMatchesArmedIntent: false,
                isLocalOutput: true
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldResumeAfterInterruption(
                shouldResumeOption: true,
                wasPlayingBeforeInterruption: true,
                currentCarMatchesArmedIntent: true,
                isLocalOutput: false
            )
        )
    }

    func testAirPodsA2DPReconnectAfterListeningDoesNotAutostart() {
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .oldDeviceUnavailable,
                previousRoutes: [airPods],
                currentRoutes: [speaker],
                hasActiveContent: true,
                isPlaying: true,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .none
        )
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousRoutes: [speaker],
                currentRoutes: [airPods],
                hasActiveContent: true,
                isPlaying: false,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .none
        )
    }

    func testLifecycleClearsStaleIntentOnLoadSinkPauseAndExpiry() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now)
        let clearing: [CarBluetoothPlaybackPolicy.LifecycleEvent] = [
            .userLoad, .sinkChanged, .userPause, .stop, .ended, .expired
        ]
        for event in clearing {
            let decision = CarBluetoothPlaybackPolicy.lifecycleDecision(for: event)
            XCTAssertEqual(decision, .init(clearIntent: true, cancelPending: true), "\(event)")
            XCTAssertNil(CarBluetoothPlaybackPolicy.applying(decision, to: armed), "\(event)")
        }
    }

    func testLifecycleManualPlayAndRebuildOnlyCancelPendingCallback() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now)
        for event: CarBluetoothPlaybackPolicy.LifecycleEvent in [.manualPlay, .rebuildSameEpisode] {
            let decision = CarBluetoothPlaybackPolicy.lifecycleDecision(for: event)
            XCTAssertEqual(decision, .init(clearIntent: false, cancelPending: true), "\(event)")
            XCTAssertEqual(CarBluetoothPlaybackPolicy.applying(decision, to: armed), armed, "\(event)")
        }
    }

    func testLegacyResumeWhenCarConnectsSnapshotDoesNotArmWithoutIdentity() throws {
        let json = """
        {"episodeID":1,"publisherURL":"https://example.test/a.mp3","position":10,"rate":1,\
        "resumeWhenCarConnects":true}
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(CarBluetoothSessionSnapshot.self, from: json)
        XCTAssertNil(snapshot.resumeIntent)
        XCTAssertNil(CarBluetoothPlaybackPolicy.validatedIntent(snapshot.resumeIntent, now: now))
    }

    func testSessionStoreRoundTripsIntentSnapshot() {
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
            resumeIntent: CarBluetoothResumeIntent(
                device: teslaA2DP,
                episodeID: 42,
                armedAt: now
            )
        )
        store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)

        store.clear()
        XCTAssertNil(store.load())
    }
}
