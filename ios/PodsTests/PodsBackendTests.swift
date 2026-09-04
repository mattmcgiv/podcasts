// DEPRECATED as of 1 October 2026. Do not review, extend, or append to this file.
// See ios/DEPRECATED.md.

import AVFoundation
import XCTest
import MediaPlayer
import WebKit
@testable import Pods

final class PodsShellTests: XCTestCase {
    func testTemporaryDebugLogExpiresAfterThreeDays() throws {
        let formatter = ISO8601DateFormatter()
        let beforeExpiry = try XCTUnwrap(formatter.date(from: "2026-08-17T23:59:58Z"))
        let afterExpiry = try XCTUnwrap(formatter.date(from: "2026-08-18T00:00:00Z"))

        XCTAssertEqual(PodsTemporaryDebugLog.expiryISO8601, "2026-08-17T23:59:59Z")
        XCTAssertTrue(PodsTemporaryDebugLog.isEnabled(now: beforeExpiry))
        XCTAssertFalse(PodsTemporaryDebugLog.isEnabled(now: afterExpiry))
    }

    func testPositiveDurationRejectsZeroAndNonFinite() {
        XCTAssertNil(AudioBridge.positiveDuration(nil))
        XCTAssertNil(AudioBridge.positiveDuration(0))
        XCTAssertNil(AudioBridge.positiveDuration(-1))
        XCTAssertNil(AudioBridge.positiveDuration(.nan))
        XCTAssertNil(AudioBridge.positiveDuration(.infinity))
        XCTAssertEqual(AudioBridge.positiveDuration(1234), 1234)
    }

    func testPlaybackProgressPolicyRejectsNonFiniteAndRegressions() {
        // Fresh episode: any finite non-negative position is eligible.
        XCTAssertTrue(PlaybackProgressPolicy.shouldPersist(
            position: 0,
            lastRecordedPosition: nil,
            force: false,
            allowRegress: false,
            strideSeconds: 5
        ))
        XCTAssertTrue(PlaybackProgressPolicy.shouldPersist(
            position: 12,
            lastRecordedPosition: nil,
            force: false,
            allowRegress: false,
            strideSeconds: 5
        ))

        // Glitch zeros / NaN from cast stop or pre-seek clock must not wipe progress.
        XCTAssertFalse(PlaybackProgressPolicy.shouldPersist(
            position: .nan,
            lastRecordedPosition: 1_800,
            force: true,
            allowRegress: false,
            strideSeconds: 5
        ))
        XCTAssertFalse(PlaybackProgressPolicy.shouldPersist(
            position: 0,
            lastRecordedPosition: 1_800,
            force: true,
            allowRegress: false,
            strideSeconds: 5
        ))
        XCTAssertFalse(PlaybackProgressPolicy.shouldPersist(
            position: 1_700,
            lastRecordedPosition: 1_800,
            force: true,
            allowRegress: false,
            strideSeconds: 5
        ))

        // Explicit seek (scrub / skip-back) may move backwards.
        XCTAssertTrue(PlaybackProgressPolicy.shouldPersist(
            position: 1_700,
            lastRecordedPosition: 1_800,
            force: true,
            allowRegress: true,
            strideSeconds: 5
        ))

        // Normal stride throttling when not forced.
        XCTAssertFalse(PlaybackProgressPolicy.shouldPersist(
            position: 1_802,
            lastRecordedPosition: 1_800,
            force: false,
            allowRegress: false,
            strideSeconds: 5
        ))
        XCTAssertTrue(PlaybackProgressPolicy.shouldPersist(
            position: 1_806,
            lastRecordedPosition: 1_800,
            force: false,
            allowRegress: false,
            strideSeconds: 5
        ))
        // Cast path forces frequent writes once advancing.
        XCTAssertTrue(PlaybackProgressPolicy.shouldPersist(
            position: 1_801,
            lastRecordedPosition: 1_800,
            force: true,
            allowRegress: false,
            strideSeconds: 5
        ))
    }

    func testFailedMacStreamReloadsOnlyAfterFailure() {
        XCTAssertTrue(PlaybackProgressPolicy.shouldReloadMacSource(sourceFailed: true))
        XCTAssertFalse(PlaybackProgressPolicy.shouldReloadMacSource(sourceFailed: false))
    }

    func testAdRemovalPlaybackActivityRequiresAnEpisodeAndActivePlayIntent() {
        XCTAssertTrue(PlaybackProgressPolicy.isEpisodePlaybackActive(
            episodeID: 42,
            paused: false
        ))
        XCTAssertFalse(PlaybackProgressPolicy.isEpisodePlaybackActive(
            episodeID: 42,
            paused: true
        ))
        XCTAssertFalse(PlaybackProgressPolicy.isEpisodePlaybackActive(
            episodeID: nil,
            paused: false
        ))
    }

    func testCastKeepAliveRunsOnlyWhileMacIsPreferredOutput() {
        // While casting, the phone stops local AVPlayer. Without a keep-alive audio
        // session, iOS suspends the app when locked and progress stops saving.
        XCTAssertTrue(PlaybackProgressPolicy.shouldRunCastKeepAlive(preferredOutputIsMac: true))
        XCTAssertFalse(PlaybackProgressPolicy.shouldRunCastKeepAlive(preferredOutputIsMac: false))
    }

    func testMacSourceReplacementPreservesPlayIntent() {
        // While Mac is preferred and playback is active, replacing the episode must
        // autoplay on Mac when connected — not fall idle waiting for a second command
        // that can be lost across reconnect.
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldAutoplayMacSourceReplacement(
                wasPlaying: true,
                connected: true
            )
        )
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldAutoplayMacSourceReplacement(
                wasPlaying: true,
                connected: false
            )
        )
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldAutoplayMacSourceReplacement(
                wasPlaying: false,
                connected: true
            )
        )
        // Disconnected + was playing: remember play intent for the reconnect path.
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldPendMacPlayAfterConnect(
                wasPlaying: true,
                connected: false,
                playRequested: false
            )
        )
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldPendMacPlayAfterConnect(
                wasPlaying: false,
                connected: false,
                playRequested: false
            )
        )
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldPendMacPlayAfterConnect(
                wasPlaying: false,
                connected: false,
                playRequested: true
            )
        )
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldPendMacPlayAfterConnect(
                wasPlaying: true,
                connected: true,
                playRequested: false
            )
        )
        // nowPlaying paused flag must reflect intended play across replacement.
        XCTAssertFalse(
            PlaybackProgressPolicy.macSourceReplacementPaused(
                wasPlaying: true,
                pendingPlayAfterConnect: false
            )
        )
        XCTAssertFalse(
            PlaybackProgressPolicy.macSourceReplacementPaused(
                wasPlaying: false,
                pendingPlayAfterConnect: true
            )
        )
        XCTAssertTrue(
            PlaybackProgressPolicy.macSourceReplacementPaused(
                wasPlaying: false,
                pendingPlayAfterConnect: false
            )
        )
    }

    func testMacCastIsSelectableWhenDiscoveredOrConnected() {
        XCTAssertFalse(PlaybackProgressPolicy.isMacCastSelectable(available: false, connected: false))
        XCTAssertTrue(PlaybackProgressPolicy.isMacCastSelectable(available: true, connected: false))
        XCTAssertTrue(PlaybackProgressPolicy.isMacCastSelectable(available: false, connected: true))
        XCTAssertTrue(PlaybackProgressPolicy.isMacCastSelectable(available: true, connected: true))
    }

    func testEpisodeTaggedTransportRejectsStaleIdentity() {
        // Untagged events stay accepted (browser / legacy Mac payloads).
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldAcceptEpisodeTaggedEvent(
                eventEpisodeID: nil,
                currentEpisodeID: 2
            )
        )
        // Matching tag applies to the loaded episode.
        XCTAssertTrue(
            PlaybackProgressPolicy.shouldAcceptEpisodeTaggedEvent(
                eventEpisodeID: 2,
                currentEpisodeID: 2
            )
        )
        // Explicit tag for a prior episode must not mutate transport or emit ended.
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldAcceptEpisodeTaggedEvent(
                eventEpisodeID: 1,
                currentEpisodeID: 2
            )
        )
        // Tagged event with no loaded episode is not attributable — reject.
        XCTAssertFalse(
            PlaybackProgressPolicy.shouldAcceptEpisodeTaggedEvent(
                eventEpisodeID: 1,
                currentEpisodeID: nil
            )
        )
    }

    func testLocalPlayerItemEndedRequiresCurrentItemIdentity() {
        // Two distinct objects: a replaced item must not count as the current item.
        let previous = NSObject()
        let current = NSObject()
        XCTAssertTrue(PlaybackProgressPolicy.isSameObject(current, current))
        XCTAssertFalse(PlaybackProgressPolicy.isSameObject(previous, current))
        XCTAssertFalse(PlaybackProgressPolicy.isSameObject(nil, current))
        XCTAssertFalse(PlaybackProgressPolicy.isSameObject(current, nil))
        XCTAssertFalse(PlaybackProgressPolicy.isSameObject(nil, nil))
    }

    func testTransportPositionPrefersLastKnownOverInvalidClock() {
        // Mac stop / pre-seek AVPlayer clocks must not report 0 when we already know better.
        XCTAssertEqual(
            PlaybackProgressPolicy.resolvedTransportPosition(
                candidate: .nan,
                lastKnown: 1_234
            ),
            1_234
        )
        XCTAssertEqual(
            PlaybackProgressPolicy.resolvedTransportPosition(
                candidate: 0,
                lastKnown: 1_234
            ),
            1_234
        )
        XCTAssertEqual(
            PlaybackProgressPolicy.resolvedTransportPosition(
                candidate: 1_250,
                lastKnown: 1_234
            ),
            1_250
        )
        XCTAssertEqual(
            PlaybackProgressPolicy.resolvedTransportPosition(
                candidate: 0,
                lastKnown: 0
            ),
            0
        )
    }

    func testSilentKeepAliveWavIsValidRIFF() {
        let data = PlaybackProgressPolicy.silentKeepAliveWavData()
        XCTAssertGreaterThan(data.count, 44)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
    }

    func testNowPlayingInfoIncludesEpisodeMetadataAndPlaybackState() throws {
        let metadata = try XCTUnwrap(AudioBridge.metadata(from: [
            "title": "Episode Title",
            "artist": "Show Title",
            "artwork": "/api/artwork/episodes/4",
            "duration": NSNumber(value: 1234)
        ]))

        XCTAssertEqual(metadata.title, "Episode Title")
        XCTAssertEqual(metadata.artist, "Show Title")
        XCTAssertEqual(metadata.artworkURL?.absoluteString, "http://127.0.0.1:18180/api/artwork/episodes/4")
        XCTAssertEqual(metadata.duration, 1234)

        let playing = AudioBridge.nowPlayingInfo(
            metadata: metadata,
            position: 42,
            duration: 0,
            playbackRate: 1.5,
            paused: false
        )
        XCTAssertEqual(playing[MPMediaItemPropertyTitle] as? String, "Episode Title")
        XCTAssertEqual(playing[MPMediaItemPropertyArtist] as? String, "Show Title")
        XCTAssertEqual(playing[MPMediaItemPropertyPlaybackDuration] as? Double, 1234)
        XCTAssertEqual(playing[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
        XCTAssertEqual(playing[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
        XCTAssertEqual(playing[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.5)
        XCTAssertEqual(
            playing[MPNowPlayingInfoPropertyMediaType] as? NSNumber,
            NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue)
        )
        XCTAssertEqual(playing[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, false)

        let paused = AudioBridge.nowPlayingInfo(
            metadata: metadata,
            position: 42,
            duration: 0,
            playbackRate: 1.5,
            paused: true
        )
        XCTAssertEqual(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    }

    // MARK: - Remote command forward skip (car Next Track / Skip Forward)

    /// Fakes the MediaPlayer command-registration boundary (skip + Tesla scrubber).
    private final class FakeRemoteForwardCommandRegistrar: RemoteForwardCommandRegistering {
        private(set) var nextTrackHandler: (() -> MPRemoteCommandHandlerStatus)?
        private(set) var previousTrackHandler: (() -> MPRemoteCommandHandlerStatus)?
        private(set) var skipForwardHandler: ((TimeInterval) -> MPRemoteCommandHandlerStatus)?
        private(set) var skipBackwardHandler: ((TimeInterval) -> MPRemoteCommandHandlerStatus)?
        private(set) var skipForwardPreferredIntervals: [NSNumber]?
        private(set) var skipBackwardPreferredIntervals: [NSNumber]?
        private(set) var seekHandler: ((TimeInterval) -> MPRemoteCommandHandlerStatus)?

        func registerNextTrackCommand(handler: @escaping () -> MPRemoteCommandHandlerStatus) {
            nextTrackHandler = handler
        }

        func registerPreviousTrackCommand(handler: @escaping () -> MPRemoteCommandHandlerStatus) {
            previousTrackHandler = handler
        }

        func registerSkipForwardCommand(
            preferredIntervals: [NSNumber],
            handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
        ) {
            skipForwardPreferredIntervals = preferredIntervals
            skipForwardHandler = handler
        }

        func registerSkipBackwardCommand(
            preferredIntervals: [NSNumber],
            handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
        ) {
            skipBackwardPreferredIntervals = preferredIntervals
            skipBackwardHandler = handler
        }

        func registerChangePlaybackPositionCommand(
            handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
        ) {
            seekHandler = handler
        }
    }

    // MARK: RemoteForwardSkipHandler (pure command-handler seam)

    func testRemoteForwardSkipSeeksAbsoluteTarget() {
        var seekTargets: [Double] = []

        let status = RemoteForwardSkipHandler.handle(
            hasActiveContent: true,
            currentPosition: 100,
            knownDuration: 1_000,
            interval: 30,
            absoluteSeek: { seekTargets.append($0) }
        )

        XCTAssertEqual(status, .success)
        XCTAssertEqual(seekTargets, [130])
    }

    func testRemoteForwardSkipWithNoActiveContentReturnsNoActionableItem() {
        var seekTargets: [Double] = []

        let status = RemoteForwardSkipHandler.handle(
            hasActiveContent: false,
            currentPosition: 100,
            knownDuration: 1_000,
            interval: 30,
            absoluteSeek: { seekTargets.append($0) }
        )

        XCTAssertEqual(status, .noActionableNowPlayingItem)
        XCTAssertEqual(seekTargets, [])
    }

    func testRemoteForwardSkipClampsToKnownDuration() {
        var seekTargets: [Double] = []

        let status = RemoteForwardSkipHandler.handle(
            hasActiveContent: true,
            currentPosition: 590,
            knownDuration: 600,
            interval: 30,
            absoluteSeek: { seekTargets.append($0) }
        )

        XCTAssertEqual(status, .success)
        XCTAssertEqual(seekTargets, [600])
    }

    // MARK: RemoteForwardCommandBinding (forward-only registrar installation seam)

    func testRemoteCommandBindingNextTrackPassesThirtySecondInterval() throws {
        let registrar = FakeRemoteForwardCommandRegistrar()
        var capturedIntervals: [TimeInterval] = []

        RemoteForwardCommandBinding.install(
            on: registrar,
            forwardSkip: { interval in
                capturedIntervals.append(interval)
                return .success
            }
        )

        let status = try XCTUnwrap(registrar.nextTrackHandler)()

        XCTAssertEqual(status, .success)
        XCTAssertEqual(capturedIntervals, [30])
    }

    func testRemoteCommandBindingSkipForwardAdvertisesIntervalAndPassesEventInterval() throws {
        let registrar = FakeRemoteForwardCommandRegistrar()
        var capturedIntervals: [TimeInterval] = []

        RemoteForwardCommandBinding.install(
            on: registrar,
            forwardSkip: { interval in
                capturedIntervals.append(interval)
                return .success
            }
        )

        XCTAssertEqual(registrar.skipForwardPreferredIntervals, [NSNumber(value: 30)])
        let status = try XCTUnwrap(registrar.skipForwardHandler)(45)

        XCTAssertEqual(status, .success)
        XCTAssertEqual(capturedIntervals, [45])
    }

    func testRemoteCommandBindingPreviousTrackPassesNegativeThirtySecondInterval() throws {
        let registrar = FakeRemoteForwardCommandRegistrar()
        var capturedIntervals: [TimeInterval] = []

        RemoteForwardCommandBinding.install(
            on: registrar,
            forwardSkip: { interval in
                capturedIntervals.append(interval)
                return .success
            }
        )

        let status = try XCTUnwrap(registrar.previousTrackHandler)()

        XCTAssertEqual(status, .success)
        XCTAssertEqual(capturedIntervals, [-30])
    }

    func testRemoteCommandBindingSkipBackwardNegatesEventInterval() throws {
        let registrar = FakeRemoteForwardCommandRegistrar()
        var capturedIntervals: [TimeInterval] = []

        RemoteForwardCommandBinding.install(
            on: registrar,
            forwardSkip: { interval in
                capturedIntervals.append(interval)
                return .success
            }
        )

        XCTAssertEqual(registrar.skipBackwardPreferredIntervals, [NSNumber(value: 30)])
        let status = try XCTUnwrap(registrar.skipBackwardHandler)(30)

        XCTAssertEqual(status, .success)
        XCTAssertEqual(capturedIntervals, [-30])
    }

    func testRemoteSeekBindingPassesScrubberPosition() throws {
        let registrar = FakeRemoteForwardCommandRegistrar()
        var capturedPositions: [TimeInterval] = []

        RemoteForwardCommandBinding.installSeek(
            on: registrar,
            seekTo: { position in
                capturedPositions.append(position)
                return .success
            }
        )

        let status = try XCTUnwrap(registrar.seekHandler)(123.5)

        XCTAssertEqual(status, .success)
        XCTAssertEqual(capturedPositions, [123.5])
    }

    func testRemotePlaybackPositionHandlerSeeksAndClamps() {
        var seekTargets: [Double] = []

        let ok = RemotePlaybackPositionHandler.handle(
            hasActiveContent: true,
            position: 90,
            knownDuration: 1_000,
            absoluteSeek: { seekTargets.append($0) }
        )
        XCTAssertEqual(ok, .success)
        XCTAssertEqual(seekTargets, [90])

        seekTargets = []
        let clamped = RemotePlaybackPositionHandler.handle(
            hasActiveContent: true,
            position: 2_000,
            knownDuration: 600,
            absoluteSeek: { seekTargets.append($0) }
        )
        XCTAssertEqual(clamped, .success)
        XCTAssertEqual(seekTargets, [600])

        seekTargets = []
        let empty = RemotePlaybackPositionHandler.handle(
            hasActiveContent: false,
            position: 90,
            knownDuration: 1_000,
            absoluteSeek: { seekTargets.append($0) }
        )
        XCTAssertEqual(empty, .noActionableNowPlayingItem)
        XCTAssertEqual(seekTargets, [])
    }

    func testRemoteForwardSkipSeeksBackwardForNegativeInterval() {
        var seekTargets: [Double] = []

        let status = RemoteForwardSkipHandler.handle(
            hasActiveContent: true,
            currentPosition: 40,
            knownDuration: 1_000,
            interval: -30,
            absoluteSeek: { seekTargets.append($0) }
        )

        XCTAssertEqual(status, .success)
        XCTAssertEqual(seekTargets, [10])
    }

    private static let d1 = "Mon, 06 Jan 2025 00:00:00 GMT"
    private static let d2 = "Tue, 07 Jan 2025 00:00:00 GMT"
    private static let d3 = "Wed, 08 Jan 2025 00:00:00 GMT"
    private static let d4 = "Thu, 09 Jan 2025 00:00:00 GMT"

    private static func rss(show: String, items: [(String, String, String, String)]) -> String {
        var body = "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>\(show)</title><description>About \(show)</description>"
        for (title, guid, url, date) in items {
            body += """
            <item><title>\(title)</title><guid>\(guid)</guid><pubDate>\(date)</pubDate>
            <description>&lt;p&gt;Notes for \(title)&lt;/p&gt;</description>
            <enclosure url="\(url)" type="audio/mpeg" length="123"/></item>
            """
        }
        body += "</channel></rss>"
        return body
    }

    private func makeSeedDatabase(at url: URL, title: String) throws {
        let database = try PodsDatabase(url: url)
        try database.execute(
            """
            INSERT INTO podcasts (id, feed_url, title, created_at)
            VALUES (1, ?, ?, 1)
            """,
            [.text("https://feeds.example/\(title).xml"), .text(title)]
        )
        try database.execute(
            """
            INSERT INTO episodes (id, podcast_id, guid, title, audio_url, published_at)
            VALUES (1, 1, 'g1', 'Episode', 'https://h.example/1.mp3', 1)
            """
        )
        try database.execute("INSERT INTO episode_state (episode_id, updated_at) VALUES (1, 1)")
    }
}

@MainActor
final class PodsWebViewRecoveryTests: XCTestCase {
    func testBootDocumentTokenIdentifiesOnlyTheCurrentLoopbackDocument() throws {
        let root = try XCTUnwrap(URL(string: "http://127.0.0.1:18180/?ui=progress-v1"))
        let current = try XCTUnwrap(PodsBootDocument.url(rootURL: root, token: "attempt-2"))

        XCTAssertTrue(PodsBootDocument.matches(current, rootURL: root, token: "attempt-2"))
        XCTAssertFalse(PodsBootDocument.matches(current, rootURL: root, token: "attempt-1"))
        XCTAssertFalse(
            PodsBootDocument.matches(
                URL(string: "https://example.com/?pods_boot=attempt-2"),
                rootURL: root,
                token: "attempt-2"
            )
        )
        XCTAssertEqual(URLComponents(url: current, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "ui", value: "progress-v1"),
            URLQueryItem(name: "pods_boot", value: "attempt-2")
        ])
    }

    private final class FakeWebView: PodsWebViewLoading {
        var url: URL?
        var loadedURLs: [URL] = []
        var evaluatedScripts: [String] = []
        var nextEvaluationResult: Any?
        var nextEvaluationError: Error?

        func load(_ request: URLRequest) -> WKNavigation? {
            if let url = request.url {
                loadedURLs.append(url)
                self.url = url
            }
            return nil
        }

        func reload() -> WKNavigation? {
            nil
        }

        func evaluateJavaScript(
            _ javaScriptString: String,
            completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil
        ) {
            evaluatedScripts.append(javaScriptString)
            completionHandler?(nextEvaluationResult, nextEvaluationError)
        }
    }

    /// Deterministic delayed-work seam: captures scheduled closures so tests can run them without real time.
    @MainActor
    private final class ManualScheduler {
        private(set) var scheduledCount = 0
        private(set) var cancelCount = 0
        private var pending: [@MainActor () -> Void] = []

        func schedule(_ work: @escaping @MainActor () -> Void) -> () -> Void {
            scheduledCount += 1
            let index = pending.count
            pending.append(work)
            return { [weak self] in
                guard let self else {
                    return
                }
                self.cancelCount += 1
                if index < self.pending.count {
                    self.pending[index] = {}
                }
            }
        }

        func runAllPending() {
            let works = pending
            pending.removeAll()
            for work in works {
                work()
            }
        }
    }

    private let localRootURL = URL(string: "http://127.0.0.1:18180/")!

    private func makeRecovery(
        scheduler: ManualScheduler
    ) -> PodsWebViewRecovery {
        PodsWebViewRecovery(rootURL: localRootURL, scheduleDelayedWork: scheduler.schedule)
    }

    private func makeRenderedWebView() -> FakeWebView {
        let webView = FakeWebView()
        webView.url = localRootURL
        webView.nextEvaluationResult = true
        return webView
    }

    func testActivationPolicyDoesNotRestartAnActiveBootRecovery() {
        XCTAssertEqual(
            PodsWebViewActivationPolicy.action(
                state: .recovering,
                recoveryAttempt: 1,
                maximumAttempts: 3
            ),
            .none
        )
        XCTAssertEqual(
            PodsWebViewActivationPolicy.action(
                state: .waitingForUI,
                recoveryAttempt: 1,
                maximumAttempts: 3
            ),
            .none
        )
        XCTAssertEqual(
            PodsWebViewActivationPolicy.action(
                state: .ready,
                recoveryAttempt: 0,
                maximumAttempts: 3
            ),
            .verifyReadyUI
        )
    }

    func testUIHealthCheckTimeoutRejectsItsLateCallback() {
        let scheduler = ManualScheduler()
        let fence = PodsWebViewHealthCheckFence(scheduleTimeout: scheduler.schedule)
        let webView = NSObject()
        var timeoutCount = 0
        let attempt = fence.begin(
            token: "boot-1",
            webViewID: ObjectIdentifier(webView),
            onTimeout: { timeoutCount += 1 }
        )

        scheduler.runAllPending()

        XCTAssertEqual(timeoutCount, 1)
        XCTAssertFalse(
            fence.accept(
                attempt,
                currentToken: "boot-1",
                currentWebViewID: ObjectIdentifier(webView)
            )
        )
    }

    func testUIHealthCheckRejectsReplacedWebViewAndCancelsAcceptedTimeout() {
        let scheduler = ManualScheduler()
        let fence = PodsWebViewHealthCheckFence(scheduleTimeout: scheduler.schedule)
        let oldWebView = NSObject()
        let currentWebView = NSObject()
        var timeoutCount = 0
        let staleAttempt = fence.begin(
            token: "boot-1",
            webViewID: ObjectIdentifier(oldWebView),
            onTimeout: { timeoutCount += 1 }
        )
        let currentAttempt = fence.begin(
            token: "boot-2",
            webViewID: ObjectIdentifier(currentWebView),
            onTimeout: { timeoutCount += 1 }
        )

        XCTAssertFalse(
            fence.accept(
                staleAttempt,
                currentToken: "boot-2",
                currentWebViewID: ObjectIdentifier(currentWebView)
            )
        )
        XCTAssertTrue(
            fence.accept(
                currentAttempt,
                currentToken: "boot-2",
                currentWebViewID: ObjectIdentifier(currentWebView)
            )
        )
        scheduler.runAllPending()
        XCTAssertEqual(timeoutCount, 0)
    }

    func testWebContentTerminationReloadsLocalRoot() {
        let recovery = PodsWebViewRecovery(rootURL: localRootURL)
        let webView = FakeWebView()

        recovery.recoverFromWebContentTermination(webView)

        XCTAssertEqual(webView.loadedURLs, [localRootURL])
    }

    func testForegroundRecoveryReloadsWhenRootIsEmpty() {
        let recovery = PodsWebViewRecovery(rootURL: localRootURL)
        let webView = FakeWebView()
        webView.url = localRootURL
        webView.nextEvaluationResult = false

        recovery.reloadIfContentMissing(webView)

        XCTAssertEqual(webView.loadedURLs, [localRootURL])
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
    }

    func testForegroundRecoveryKeepsRenderedRoot() {
        let recovery = PodsWebViewRecovery(rootURL: localRootURL)
        let webView = FakeWebView()
        webView.url = localRootURL
        webView.nextEvaluationResult = true

        recovery.reloadIfContentMissing(webView)

        XCTAssertTrue(webView.loadedURLs.isEmpty)
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
    }

    func testActivationChecksRootImmediatelyAndSchedulesOneDelayedRecheck() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let webView = makeRenderedWebView()

        recovery.handleActivation(webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 1, "activation must health-check immediately")
        XCTAssertEqual(scheduler.scheduledCount, 1, "activation must schedule exactly one delayed recheck")

        scheduler.runAllPending()

        XCTAssertEqual(webView.evaluatedScripts.count, 2, "delayed recheck must run a second health check")
        XCTAssertTrue(webView.loadedURLs.isEmpty)
    }

    func testRepeatedActivationCancelsPriorDelayedWork() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let webView = makeRenderedWebView()

        recovery.handleActivation(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        recovery.handleActivation(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 2, "second activation checks immediately again")
        XCTAssertEqual(scheduler.scheduledCount, 2, "second activation schedules a replacement delayed recheck")
        XCTAssertEqual(scheduler.cancelCount, 1, "prior delayed work must be cancelled before rescheduling")

        scheduler.runAllPending()

        // Only the replacement delayed work should perform a health check (cancelled work is a no-op).
        XCTAssertEqual(webView.evaluatedScripts.count, 3)
    }

    /// Models the production race: DispatchWorkItem has already fired and enqueued its
    /// MainActor Task, so cancel only records intent and cannot suppress the captured callback.
    private final class NonCooperativeScheduler {
        private(set) var scheduledCount = 0
        private(set) var cancelCount = 0
        private var pending: [() -> Void] = []

        func schedule(_ work: @escaping () -> Void) -> () -> Void {
            scheduledCount += 1
            pending.append(work)
            return { [weak self] in
                self?.cancelCount += 1
                // Intentionally do not suppress the captured callback — race already lost.
            }
        }

        func runAllPending() {
            let works = pending
            pending.removeAll()
            for work in works {
                work()
            }
        }
    }

    func testReplacedActivationIgnoresStaleDelayedCallbackAfterLostCancelRace() {
        let scheduler = NonCooperativeScheduler()
        let recovery = PodsWebViewRecovery(
            rootURL: localRootURL,
            scheduleDelayedWork: scheduler.schedule
        )
        let webView = makeRenderedWebView()

        recovery.handleActivation(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        recovery.handleActivation(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 2, "second activation checks immediately again")
        XCTAssertEqual(scheduler.scheduledCount, 2, "second activation schedules a replacement delayed recheck")
        XCTAssertEqual(scheduler.cancelCount, 1, "prior delayed work must still be cancelled for cleanup")

        // Both callbacks fire (cancel lost the race). Only the newest recovery may health-check.
        scheduler.runAllPending()

        XCTAssertEqual(
            webView.evaluatedScripts.count,
            3,
            "stale delayed recovery must no-op even when scheduler cancel loses the race"
        )
    }

    func testCancelPendingRecoveryPreventsDelayedWork() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let webView = makeRenderedWebView()

        recovery.handleActivation(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        recovery.cancelPendingRecovery()
        XCTAssertEqual(scheduler.cancelCount, 1)

        scheduler.runAllPending()

        XCTAssertEqual(
            webView.evaluatedScripts.count,
            1,
            "cancelled delayed recheck must not perform another health check"
        )
    }

    func testLifecycleAppearActivatesRecovery() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let lifecycle = PodsWebViewRecoveryLifecycle(recovery: recovery)
        let webView = makeRenderedWebView()

        lifecycle.handleAppear(webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 1, "appear must activate an immediate health check")
        XCTAssertEqual(scheduler.scheduledCount, 1, "appear must schedule one delayed recheck")

        scheduler.runAllPending()

        XCTAssertEqual(webView.evaluatedScripts.count, 2, "appear-scheduled delayed recheck must run")
    }

    func testLifecycleDisappearCancelsPendingRecovery() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let lifecycle = PodsWebViewRecoveryLifecycle(recovery: recovery)
        let webView = makeRenderedWebView()

        lifecycle.handleAppear(webView)
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        lifecycle.handleDisappear()
        XCTAssertEqual(scheduler.cancelCount, 1, "disappear must cancel pending delayed recovery")

        scheduler.runAllPending()

        XCTAssertEqual(
            webView.evaluatedScripts.count,
            1,
            "cancelled delayed recheck after disappear must not run"
        )
    }

    func testLifecycleBecomeActiveActivatesRecoveryAfterDisappear() {
        let scheduler = ManualScheduler()
        let recovery = makeRecovery(scheduler: scheduler)
        let lifecycle = PodsWebViewRecoveryLifecycle(recovery: recovery)
        let webView = makeRenderedWebView()

        lifecycle.handleAppear(webView)
        lifecycle.handleDisappear()
        XCTAssertEqual(webView.evaluatedScripts.count, 1)
        XCTAssertEqual(scheduler.cancelCount, 1)

        lifecycle.handleBecomeActive(webView)

        XCTAssertEqual(webView.evaluatedScripts.count, 2, "become-active must re-activate recovery")
        XCTAssertEqual(scheduler.scheduledCount, 2, "become-active must schedule a fresh delayed recheck")
    }

    func testBootRecoveryDoesNotDeclareReadyUntilServerAndReactAreReady() async {
        var ensureCalls = 0
        var loadCalls = 0
        var states: [PodsWebViewBootRecovery.State] = []
        let recovery = PodsWebViewBootRecovery(
            ensureServerReady: {
                ensureCalls += 1
            },
            loadRoot: {
                loadCalls += 1
            },
            stateDidChange: { state in
                states.append(state)
            }
        )

        await recovery.recover(reason: "web-content-terminated")

        XCTAssertEqual(ensureCalls, 1)
        XCTAssertEqual(loadCalls, 1)
        XCTAssertEqual(recovery.state, .waitingForUI)
        XCTAssertEqual(states, [.recovering, .waitingForUI])

        recovery.markUIReady()

        XCTAssertEqual(recovery.state, .ready)
        XCTAssertEqual(states, [.recovering, .waitingForUI, .ready])
    }

    func testBootRecoveryKeepsNativeFailureStateWhenServerCannotRecover() async {
        struct Refused: LocalizedError {
            var errorDescription: String? { "connection refused" }
        }
        var loadCalls = 0
        let recovery = PodsWebViewBootRecovery(
            ensureServerReady: {
                throw Refused()
            },
            loadRoot: {
                loadCalls += 1
            }
        )

        await recovery.recover(reason: "foreground")

        XCTAssertEqual(loadCalls, 0)
        XCTAssertEqual(recovery.state, .failed("connection refused"))
    }
}
