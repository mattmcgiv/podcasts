// DEPRECATED as of 1 October 2026. Do not review, extend, or append to this file.
// See ios/DEPRECATED.md.

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
    private let midnightA2DP = CarBluetoothRouteDescriptor(
        uid: "aa:bb:cc:dd:ee:ff-tacl",
        name: "Midnight",
        portType: .bluetoothA2DP
    )
    private let midnightHFP = CarBluetoothRouteDescriptor(
        uid: "aa:bb:cc:dd:ee:ff-tsco",
        name: "Midnight",
        portType: .bluetoothHFP
    )
    private let airPodsHFP = CarBluetoothRouteDescriptor(
        uid: "de:ad:be:ef:00:01-tsco",
        name: "AirPods Pro",
        portType: .bluetoothHFP
    )
    private let polySpeakerphoneHFP = CarBluetoothRouteDescriptor(
        uid: "99:88:77:66:55:44-tsco",
        name: "Poly Sync 20",
        portType: .bluetoothHFP
    )
    private let jabraA2DP = CarBluetoothRouteDescriptor(
        uid: "fe:ed:fa:ce:00:11-tacl",
        name: "Jabra Elite 7",
        portType: .bluetoothA2DP
    )
    private let jabraHFP = CarBluetoothRouteDescriptor(
        uid: "fe:ed:fa:ce:00:11-tsco",
        name: "Jabra Elite 7",
        portType: .bluetoothHFP
    )
    private var midnightContext: CarBluetoothRouteContext {
        CarBluetoothRouteContext(
            knownCarDeviceKeys: [midnightA2DP.stableDeviceKey],
            handsFreeDeviceKeys: []
        )
    }
    private var jabraDualProfileContext: CarBluetoothRouteContext {
        CarBluetoothRouteContext(
            knownCarDeviceKeys: [],
            handsFreeDeviceKeys: [jabraHFP.stableDeviceKey]
        )
    }

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
        XCTAssertEqual(midnightHFP.kind, .otherBluetooth, "custom names are not intrinsically cars")
        XCTAssertEqual(midnightA2DP.kind, .otherBluetooth)
        XCTAssertEqual(airPodsHFP.kind, .headphone)
        XCTAssertEqual(polySpeakerphoneHFP.kind, .otherBluetooth)
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCar(midnightHFP))
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.isCar(
                midnightA2DP,
                context: CarBluetoothRouteContext(
                    knownCarDeviceKeys: [],
                    handsFreeDeviceKeys: [midnightHFP.stableDeviceKey]
                )
            ),
            "A2DP+HFP pairing alone must not classify an accessory as a car"
        )
        XCTAssertTrue(CarBluetoothPlaybackPolicy.isCar(midnightA2DP, context: midnightContext))
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.isCar(midnightHFP, context: midnightContext),
            "persisted enrollment applies to every profile of that MAC"
        )
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCar(midnightA2DP))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCar(jbl, context: midnightContext))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCar(airPods, context: midnightContext))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCar(polySpeakerphoneHFP))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCar(jabraA2DP, context: jabraDualProfileContext))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCar(jabraHFP, context: jabraDualProfileContext))
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
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: scheduled,
                currentRoutes: [teslaHFP],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            "Model 3 keeps HFP-only until play() opens A2DP; commit on the matching car"
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

    func testHFPOnlyPastSettleCommitsToBreakTeslaA2DPDeadlock() {
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
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: pending,
                currentRoutes: [teslaHFP],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now + CarBluetoothPlaybackPolicy.resumeSettleDelay
            ),
            "waiting for A2DP before play() deadlocks Model 3 media"
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.isMediaCapableCarRoute(teslaHFP)
        )
    }

    func testHFPThenA2DPSequenceCommitsOnHFPAndAgainOnMediaRoute() {
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
        XCTAssertTrue(
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
            isPlaying: true,
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

    func testInterruptionCarMatchAcceptsHFPOfArmedTesla() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now - 60)
        XCTAssertTrue(
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
            ),
            knownCarDeviceKeys: [teslaA2DP.stableDeviceKey]
        )
        store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
        XCTAssertEqual(store.loadKnownCarDeviceKeys(), [teslaA2DP.stableDeviceKey])

        store.clear()
        XCTAssertNil(store.load())
        XCTAssertEqual(
            store.loadKnownCarDeviceKeys(),
            [teslaA2DP.stableDeviceKey],
            "custom Tesla identity must survive stop/clear"
        )
    }

    func testKnownCarKeysSurviveEpisodeSessionClear() {
        let suite = "pods.carBluetooth.knownCars.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsCarBluetoothSessionStore(defaults: defaults)
        store.saveKnownCarDeviceKeys([midnightA2DP.stableDeviceKey])
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertEqual(store.loadKnownCarDeviceKeys(), [midnightA2DP.stableDeviceKey])
        store.saveKnownCarDeviceKeys([])
        XCTAssertEqual(store.loadKnownCarDeviceKeys(), [])
    }

    func testExplicitEnrollmentFromEmptyStoreResumesCustomTeslaAndIgnoresUnenrolledHeadset() {
        let suite = "pods.carBluetooth.enroll.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsCarBluetoothSessionStore(defaults: defaults)
        XCTAssertEqual(store.loadKnownCarDeviceKeys(), [], "fresh install has no enrolled car")

        let midnightRoutes = [midnightA2DP, midnightHFP]
        XCTAssertEqual(midnightA2DP.kind, .otherBluetooth)
        XCTAssertNil(
            CarBluetoothEnrollment.enrollableDevice(in: [airPods, airPodsHFP]),
            "headphones are never enrollable"
        )
        XCTAssertEqual(
            CarBluetoothEnrollment.enrollableDevice(in: midnightRoutes)?.stableDeviceKey,
            midnightA2DP.stableDeviceKey
        )

        guard let enrolledKeys = CarBluetoothEnrollment.enroll(routes: midnightRoutes) else {
            return XCTFail("production enroll path must accept a custom-named Tesla")
        }
        store.saveKnownCarDeviceKeys(enrolledKeys)
        XCTAssertEqual(store.loadKnownCarDeviceKeys(), [midnightA2DP.stableDeviceKey])

        let enrolledContext = CarBluetoothRouteContext(
            knownCarDeviceKeys: Set(store.loadKnownCarDeviceKeys()),
            handsFreeDeviceKeys: []
        )
        let lost = CarBluetoothPlaybackPolicy.action(
            reason: .oldDeviceUnavailable,
            previousRoutes: midnightRoutes,
            currentRoutes: [speaker],
            hasActiveContent: true,
            isPlaying: true,
            intent: nil,
            currentEpisodeID: 9,
            isLocalOutput: true,
            now: now,
            context: enrolledContext
        )
        guard case .remember(let intent) = lost else {
            return XCTFail("enrolled custom Tesla must arm on disconnect, got \(lost)")
        }
        XCTAssertEqual(intent.device.kind, .car)

        let reconnect = CarBluetoothPlaybackPolicy.action(
            reason: .newDeviceAvailable,
            previousRoutes: [speaker],
            currentRoutes: [midnightHFP],
            hasActiveContent: true,
            isPlaying: false,
            intent: intent,
            currentEpisodeID: 9,
            isLocalOutput: true,
            now: now
        )
        guard case .schedule(let scheduled) = reconnect else {
            return XCTFail("HFP reconnect must resume after explicit enrollment, got \(reconnect)")
        }
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: scheduled,
                currentRoutes: [midnightHFP],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now + CarBluetoothPlaybackPolicy.resumeSettleDelay
            )
        )

        XCTAssertNotNil(CarBluetoothEnrollment.enroll(routes: [jabraA2DP, jabraHFP]))
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .oldDeviceUnavailable,
                previousRoutes: [jabraA2DP, jabraHFP],
                currentRoutes: [speaker],
                hasActiveContent: true,
                isPlaying: true,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now,
                context: enrolledContext
            ),
            .none,
            "enrolling Midnight must not treat an un-enrolled dual-profile headset as a car"
        )
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousRoutes: [speaker],
                currentRoutes: [jabraHFP],
                hasActiveContent: true,
                isPlaying: false,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now,
                context: .empty
            ),
            .none,
            "un-enrolled dual-profile headset must not resume"
        )

        store.saveKnownCarDeviceKeys(CarBluetoothEnrollment.unenroll())
        XCTAssertEqual(store.loadKnownCarDeviceKeys(), [])
    }

    func testCustomNamedTeslaA2DPPromotesViaHandsFreeIdentity() {
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .oldDeviceUnavailable,
                previousRoutes: [midnightA2DP],
                currentRoutes: [speaker],
                hasActiveContent: true,
                isPlaying: true,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .none,
            "custom name without persisted enrollment is not a car"
        )

        let lost = CarBluetoothPlaybackPolicy.action(
            reason: .oldDeviceUnavailable,
            previousRoutes: [midnightA2DP],
            currentRoutes: [speaker],
            hasActiveContent: true,
            isPlaying: true,
            intent: nil,
            currentEpisodeID: 9,
            isLocalOutput: true,
            now: now,
            context: midnightContext
        )
        guard case .remember(let intent) = lost else {
            return XCTFail("expected remember for enrolled custom Tesla, got \(lost)")
        }
        XCTAssertTrue(intent.device.matches(midnightHFP))
        XCTAssertEqual(
            intent.device.kind,
            .car,
            "remembered identity must stay a car after enrollment context is gone"
        )

        let reconnect = CarBluetoothPlaybackPolicy.action(
            reason: .newDeviceAvailable,
            previousRoutes: [speaker],
            currentRoutes: [midnightHFP],
            hasActiveContent: true,
            isPlaying: false,
            intent: intent,
            currentEpisodeID: 9,
            isLocalOutput: true,
            now: now
        )
        guard case .schedule(let scheduled) = reconnect else {
            return XCTFail("expected schedule on custom-named Tesla HFP, got \(reconnect)")
        }
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: scheduled,
                currentRoutes: [midnightHFP],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now + CarBluetoothPlaybackPolicy.resumeSettleDelay
            )
        )
    }

    func testValidatedIntentUsesKnownCarContextForPromotedA2DP() {
        let leftover = CarBluetoothResumeIntent(device: midnightA2DP, episodeID: 9, armedAt: now)
        XCTAssertEqual(midnightA2DP.kind, .otherBluetooth)
        XCTAssertNil(
            CarBluetoothPlaybackPolicy.validatedIntent(leftover, now: now),
            "A2DP vehicle-name ports are not intrinsically cars"
        )
        XCTAssertNil(
            CarBluetoothPlaybackPolicy.validatedIntent(
                leftover,
                now: now,
                context: CarBluetoothRouteContext(
                    knownCarDeviceKeys: [],
                    handsFreeDeviceKeys: [midnightHFP.stableDeviceKey]
                )
            ),
            "A2DP+HFP pairing is not enrollment"
        )
        XCTAssertNotNil(
            CarBluetoothPlaybackPolicy.validatedIntent(leftover, now: now, context: midnightContext)
        )
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.rememberedCarDevice(midnightA2DP, context: midnightContext).kind,
            .car
        )

        let reconnectLeftover = CarBluetoothPlaybackPolicy.action(
            reason: .newDeviceAvailable,
            previousRoutes: [speaker],
            currentRoutes: [midnightHFP],
            hasActiveContent: true,
            isPlaying: false,
            intent: leftover,
            currentEpisodeID: 9,
            isLocalOutput: true,
            now: now,
            context: midnightContext
        )
        guard case .schedule = reconnectLeftover else {
            return XCTFail("known-car context must not clear a promoted A2DP latch, got \(reconnectLeftover)")
        }
    }

    func testKnownCarKeyPromotesCustomA2DPWithoutLiveHFP() {
        let known = CarBluetoothRouteContext(
            knownCarDeviceKeys: [midnightA2DP.stableDeviceKey],
            handsFreeDeviceKeys: []
        )
        let lost = CarBluetoothPlaybackPolicy.action(
            reason: .oldDeviceUnavailable,
            previousRoutes: [midnightA2DP],
            currentRoutes: [speaker],
            hasActiveContent: true,
            isPlaying: true,
            intent: nil,
            currentEpisodeID: 9,
            isLocalOutput: true,
            now: now,
            context: known
        )
        guard case .remember(let intent) = lost else {
            return XCTFail("expected remember from persisted Tesla identity, got \(lost)")
        }
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.discoveredCarDeviceKeys(
                routes: [midnightA2DP],
                context: known
            ),
            [midnightA2DP.stableDeviceKey]
        )
        XCTAssertTrue(intent.device.matches(midnightA2DP))
    }

    func testKeepAliveCoversErrandWindowButNotFullTTL() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now)
        XCTAssertTrue(CarBluetoothPlaybackPolicy.shouldKeepSessionAlive(intent: armed, now: now))
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldKeepSessionAlive(
                intent: armed,
                now: now + CarBluetoothPlaybackPolicy.resumeKeepAliveDuration
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldKeepSessionAlive(
                intent: armed,
                now: now + CarBluetoothPlaybackPolicy.resumeKeepAliveDuration + 1
            )
        )
        XCTAssertNotNil(
            CarBluetoothPlaybackPolicy.validatedIntent(
                armed,
                now: now + CarBluetoothPlaybackPolicy.resumeKeepAliveDuration + 1
            ),
            "TTL outlives keep-alive so next-morning foreground/AVRCP can still resume"
        )
        XCTAssertFalse(CarBluetoothPlaybackPolicy.shouldKeepSessionAlive(intent: nil, now: now))
    }

    func testForegroundReschedulesWhenArmedCarIsAlreadyConnected() {
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now - 60)
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldScheduleResumeOnForeground(
                intent: armed,
                currentRoutes: [teslaHFP],
                hasActiveContent: true,
                isLocalOutput: true,
                now: now
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldScheduleResumeOnForeground(
                intent: armed,
                currentRoutes: [airPods],
                hasActiveContent: true,
                isLocalOutput: true,
                now: now
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldScheduleResumeOnForeground(
                intent: armed,
                currentRoutes: [teslaHFP],
                hasActiveContent: true,
                isLocalOutput: false,
                now: now
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldScheduleResumeOnForeground(
                intent: nil,
                currentRoutes: [teslaA2DP],
                hasActiveContent: true,
                isLocalOutput: true,
                now: now
            )
        )
    }

    func testSameEpisodeHydrationPreservesResumeIntent() {
        XCTAssertTrue(
            CarBluetoothPlaybackPolicy.shouldPreserveResumeAcrossLoad(
                incomingEpisodeID: 9,
                currentEpisodeID: 9
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldPreserveResumeAcrossLoad(
                incomingEpisodeID: 10,
                currentEpisodeID: 9
            )
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldPreserveResumeAcrossLoad(
                incomingEpisodeID: 9,
                currentEpisodeID: nil
            )
        )
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now)
        let rebuilt = CarBluetoothPlaybackPolicy.applying(
            CarBluetoothPlaybackPolicy.lifecycleDecision(for: .rebuildSameEpisode),
            to: armed
        )
        XCTAssertEqual(rebuilt, armed)
    }

    func testLegacySnapshotWithoutKnownCarKeysStillDecodes() throws {
        let json = """
        {"episodeID":1,"publisherURL":"https://example.test/a.mp3","position":10,"rate":1,\
        "resumeIntent":{"device":{"uid":"aa:bb:cc:dd:ee:ff-tacl","name":"Tesla Model 3",\
        "portTypeRaw":"BluetoothA2DP"},"episodeID":1,"armedAt":\(now)}}
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(CarBluetoothSessionSnapshot.self, from: json)
        XCTAssertEqual(snapshot.knownCarDeviceKeys, [])
        XCTAssertEqual(snapshot.resumeIntent?.episodeID, 1)
    }

    func testUnknownHFPSpeakerphoneDoesNotClassifyAsCarOrArm() {
        let selfPaired = CarBluetoothRouteContext(
            knownCarDeviceKeys: [],
            handsFreeDeviceKeys: [polySpeakerphoneHFP.stableDeviceKey]
        )
        XCTAssertEqual(polySpeakerphoneHFP.kind, .otherBluetooth)
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCar(polySpeakerphoneHFP))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCar(polySpeakerphoneHFP, context: selfPaired))
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.discoveredCarDeviceKeys(
                routes: [polySpeakerphoneHFP],
                context: selfPaired
            ),
            [],
            "unknown HFP must not be enrolled as a known car"
        )
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .oldDeviceUnavailable,
                previousRoutes: [polySpeakerphoneHFP],
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
                reason: .oldDeviceUnavailable,
                previousRoutes: [polySpeakerphoneHFP],
                currentRoutes: [speaker],
                hasActiveContent: true,
                isPlaying: true,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now,
                context: selfPaired
            ),
            .none,
            "self-paired HFP speakerphone still must not arm"
        )
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousRoutes: [speaker],
                currentRoutes: [polySpeakerphoneHFP],
                hasActiveContent: true,
                isPlaying: false,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .none
        )
        let teslaArmed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now - 60)
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousRoutes: [speaker],
                currentRoutes: [polySpeakerphoneHFP],
                hasActiveContent: true,
                isPlaying: false,
                intent: teslaArmed,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            ),
            .none
        )
        XCTAssertFalse(
            CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
                scheduled: teslaArmed,
                currentRoutes: [polySpeakerphoneHFP],
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now
            )
        )
    }

    func testUnknownDualProfileHeadsetDoesNotClassifyAsCarOrArm() {
        XCTAssertEqual(jabraA2DP.kind, .otherBluetooth)
        XCTAssertEqual(jabraHFP.kind, .otherBluetooth)
        XCTAssertTrue(jabraA2DP.matches(jabraHFP))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCar(jabraA2DP, context: jabraDualProfileContext))
        XCTAssertFalse(CarBluetoothPlaybackPolicy.isCar(jabraHFP, context: jabraDualProfileContext))
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.rememberedCarDevice(jabraA2DP, context: jabraDualProfileContext).kind,
            .otherBluetooth
        )
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.discoveredCarDeviceKeys(
                routes: [jabraA2DP, jabraHFP],
                context: jabraDualProfileContext
            ),
            [],
            "A2DP+HFP pairing must not enroll an unknown headset"
        )
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .oldDeviceUnavailable,
                previousRoutes: [jabraA2DP, jabraHFP],
                currentRoutes: [speaker],
                hasActiveContent: true,
                isPlaying: true,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now,
                context: jabraDualProfileContext
            ),
            .none
        )
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousRoutes: [speaker],
                currentRoutes: [jabraHFP, jabraA2DP],
                hasActiveContent: true,
                isPlaying: false,
                intent: nil,
                currentEpisodeID: 9,
                isLocalOutput: true,
                now: now,
                context: jabraDualProfileContext
            ),
            .none
        )
    }

    func testAirPodsHFPDoesNotPromoteOrConsumeTeslaIntent() {
        XCTAssertEqual(airPodsHFP.kind, .headphone)
        XCTAssertEqual(
            CarBluetoothRouteContext.handsFreeDeviceKeys(from: [airPodsHFP, airPods]),
            []
        )
        let armed = CarBluetoothResumeIntent(device: teslaA2DP, episodeID: 9, armedAt: now - 60)
        XCTAssertEqual(
            CarBluetoothPlaybackPolicy.action(
                reason: .newDeviceAvailable,
                previousRoutes: [speaker],
                currentRoutes: [airPodsHFP],
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
}
