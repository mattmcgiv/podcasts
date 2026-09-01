import AVFoundation
import MediaPlayer
import UIKit
import WebKit

struct NowPlayingMetadata: Equatable {
    let title: String
    let artist: String
    let artworkURL: URL?
    let duration: Double?
}

enum PlaybackOutput: String {
    case local
    case mac
}

struct PlaybackSpeedDiagnosticObservation: Equatable {
    let correlationID: String
    let requestedRate: Float
}

struct PlaybackSpeedDiagnosticTracker {
    private var pending: PlaybackSpeedDiagnosticObservation?

    mutating func begin(correlationID: String, requestedRate: Float) {
        pending = .init(correlationID: correlationID, requestedRate: requestedRate)
    }

    mutating func takeObservation() -> PlaybackSpeedDiagnosticObservation? {
        defer { pending = nil }
        return pending
    }
}

/// Package-internal seam for car / lock-screen MediaPlayer remote-command
/// registration (Next/Previous, Skip Forward/Back, scrubber). Production uses
/// `SystemRemoteForwardCommandRegistrar`; tests inject a fake that captures
/// handlers. Play/Pause/Toggle stay on `MPRemoteCommandCenter` directly.
protocol RemoteForwardCommandRegistering: AnyObject {
    func registerNextTrackCommand(handler: @escaping () -> MPRemoteCommandHandlerStatus)
    func registerPreviousTrackCommand(handler: @escaping () -> MPRemoteCommandHandlerStatus)
    func registerSkipForwardCommand(
        preferredIntervals: [NSNumber],
        handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
    )
    func registerSkipBackwardCommand(
        preferredIntervals: [NSNumber],
        handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
    )
    func registerChangePlaybackPositionCommand(
        handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
    )
}

final class SystemRemoteForwardCommandRegistrar: RemoteForwardCommandRegistering {
    private let center = MPRemoteCommandCenter.shared()

    func registerNextTrackCommand(handler: @escaping () -> MPRemoteCommandHandlerStatus) {
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { _ in handler() }
    }

    func registerPreviousTrackCommand(handler: @escaping () -> MPRemoteCommandHandlerStatus) {
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { _ in handler() }
    }

    func registerSkipForwardCommand(
        preferredIntervals: [NSNumber],
        handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
    ) {
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = preferredIntervals
        center.skipForwardCommand.addTarget { event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            return handler(skipEvent.interval)
        }
    }

    func registerSkipBackwardCommand(
        preferredIntervals: [NSNumber],
        handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
    ) {
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = preferredIntervals
        center.skipBackwardCommand.addTarget { event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            return handler(skipEvent.interval)
        }
    }

    func registerChangePlaybackPositionCommand(
        handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
    ) {
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { event in
            guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return handler(seekEvent.positionTime)
        }
    }
}

/// Pure forward-skip policy for car/accessory remote commands.
/// Does only the injected absolute-seek effect (preserves play/pause).
enum RemoteForwardSkipHandler {
    static func handle(
        hasActiveContent: Bool,
        currentPosition: Double,
        knownDuration: Double?,
        interval: TimeInterval,
        absoluteSeek: (Double) -> Void
    ) -> MPRemoteCommandHandlerStatus {
        guard hasActiveContent else {
            return .noActionableNowPlayingItem
        }

        var target = currentPosition + interval
        if let duration = knownDuration, duration.isFinite, duration > 0 {
            target = min(target, duration)
        }
        target = max(0, target)
        absoluteSeek(target)
        return .success
    }
}

/// Installs Tesla / lock-screen skip handlers (Next/Previous, Skip ±30s).
enum RemoteForwardCommandBinding {
    static let forwardSkipPreferredInterval: TimeInterval = 30

    static func install(
        on registrar: RemoteForwardCommandRegistering,
        forwardSkip: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
    ) {
        registrar.registerNextTrackCommand {
            forwardSkip(forwardSkipPreferredInterval)
        }
        registrar.registerPreviousTrackCommand {
            forwardSkip(-forwardSkipPreferredInterval)
        }
        registrar.registerSkipForwardCommand(
            preferredIntervals: [NSNumber(value: forwardSkipPreferredInterval)]
        ) { interval in
            forwardSkip(interval)
        }
        registrar.registerSkipBackwardCommand(
            preferredIntervals: [NSNumber(value: forwardSkipPreferredInterval)]
        ) { interval in
            // Skip-back events are positive intervals; seek backward.
            forwardSkip(-abs(interval))
        }
    }

    static func installSeek(
        on registrar: RemoteForwardCommandRegistering,
        seekTo: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
    ) {
        registrar.registerChangePlaybackPositionCommand(handler: seekTo)
    }
}

final class AudioBridge: NSObject, WKScriptMessageHandler {
    static let shared = AudioBridge()

    var progressRecorder: PlaybackProgressRecording?
    var diagnostics: AdRemovalDiagnostics?
    var adRemovalPlaybackProvider: AdRemovalPlaybackProviding?
    var adRemovalRangeServer: AdRemovalRangeServing?

    private weak var webView: WKWebView?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var currentId: Int = 0
    private var currentEpisodeID: Int64?
    private var playbackSessionID: String?
    private var lastRecordedEpisodeID: Int64?
    private var lastRecordedPosition: Double?
    private var requestedRate: Float = 1
    private var speedDiagnosticTracker = PlaybackSpeedDiagnosticTracker()
    private var shouldResumeAfterInterruption = false
    /// Armed car-device resume. Nil unless a classified car was lost while playing.
    private var carBluetoothResumeIntent: CarBluetoothResumeIntent?
    /// Bumped to supersede an in-flight settle callback.
    private var carBluetoothResumeGeneration: UInt64 = 0
    private var carBluetoothResumeWorkItem: DispatchWorkItem?
    private let carBluetoothSessionStore: CarBluetoothSessionStoring
    /// Tesla vehicles are often renamed; remember MAC keys seen as a car/HFP unit.
    private var knownCarDeviceKeys: [String] = []
    private var nowPlayingMetadata: NowPlayingMetadata?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingArtworkURL: URL?
    private var nowPlayingArtworkTask: URLSessionDataTask?
    private var nowPlayingPosition: Double = 0
    private var nowPlayingDuration: Double = 0
    private var nowPlayingRate: Float = 1
    private var nowPlayingPaused = true
    private var lastReportedPlaybackActivity = false
    private let progressRecordStrideSeconds: Double = 5
    private var downloadedEpisode: AdRemovalDownloadedEpisode?
    private var publisherURL: URL?
    private var macStreamURL: URL?
    private var adRemovalSkipSession = AdRemovalSkipSession()
    private var automaticSkipInFlight = false
    private var automaticSkipLifecycle = AdRemovalSkipLifecycle()
    private var macAutomaticSkipState = AdRemovalMacSkipState()
    private var macSupersedingSeekFence: AdRemovalMacSupersedingSeekFence?
    private var macAutomaticSkipRetryWorkItem: DispatchWorkItem?
    private let macAutomaticSkipRetryDelay: TimeInterval = 2
    private let macAutomaticSkipMaximumAttempts = 3

    private var output: PlaybackOutput = .local
    /// User's chosen sink. Distinct from connection liveness — stays `.mac` while we reconnect.
    private var preferredOutput: PlaybackOutput = .local
    private var lastSrc: String?
    private var pendingPlayAfterCastConnect = false
    private var macSourceFailed = false
    private var castWired = false
    /// Silent local loop so iOS keeps us alive while Mac is the exclusive audio sink.
    private var castKeepAlivePlayer: AVAudioPlayer?

    private override init() {
        carBluetoothSessionStore = UserDefaultsCarBluetoothSessionStore()
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemEnded(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        configureRemoteCommands()
        restorePersistedCarBluetoothSession()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        wireCastSessionIfNeeded()
        CastSession.shared.startBrowsing()
        emitCastStatus(CastSession.shared.currentStatus)
    }

    func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Long-form spoken audio is Apple's podcast/car-Bluetooth policy:
            // Tesla (no CarPlay) picks this session up over A2DP + AVRCP.
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
            } catch {
                PodsLog("Pods audio session setup failed: \(error)")
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? Int,
              let command = body["command"] as? String else {
            return
        }
        currentId = id

        switch command {
        case "load":
            guard let src = body["src"] as? String, let url = URL(string: src) else { return }
            let episodeID = Self.int64Value(body["episodeId"]) ?? Self.int64Value(body["episode_id"])
            let sameEpisode = CarBluetoothPlaybackPolicy.shouldPreserveResumeAcrossLoad(
                incomingEpisodeID: episodeID,
                currentEpisodeID: currentEpisodeID
            )
            load(
                id: id,
                url: url,
                episodeID: episodeID,
                position: Self.doubleValue(body["position"]) ?? 0,
                rate: Self.normalizedRate(Self.floatValue(body["rate"]) ?? 1),
                clearsCarResume: !sameEpisode
            )
        case "metadata":
            setNowPlayingMetadata(Self.metadata(from: body))
            if output == .mac, let lastSrc, let url = URL(string: lastSrc) {
                // Refresh Mac now-playing metadata via a silent reload of current position is heavy;
                // metadata is included on the next load. Keep local now playing in sync.
                _ = url
            }
        case "play":
            play(id: id)
        case "pause":
            pause(id: id, userInitiated: true)
        case "seek":
            let seconds = Self.doubleValue(body["seconds"]) ?? 0
            seek(id: id, seconds: seconds)
        case "undoAdSkip":
            undoPendingAdSkip(id: id)
        case "rate":
            let rate = Self.normalizedRate(Self.floatValue(body["rate"]) ?? 1)
            let correlationID = body["correlationId"] as? String
            if let correlationID {
                PodsLog("speed_bridge_received correlation_id=\(correlationID) requested_rate=\(rate) player_id=\(id)")
            }
            setRate(id: id, rate: rate, correlationID: correlationID)
        case "stop":
            stop(id: id)
        case "castConnect":
            setOutput(.mac, id: id, resume: true)
        case "castDisconnect":
            setOutput(.local, id: id, resume: true)
        case "castStatus":
            emitCastStatus(CastSession.shared.currentStatus)
        default:
            break
        }
    }

    // MARK: - Output switching

    private func setOutput(_ next: PlaybackOutput, id: Int, resume: Bool) {
        invalidateAutomaticSkip()
        applyCarResumeLifecycle(.sinkChanged)
        persistCarBluetoothSession()
        preferredOutput = next
        let position = nowPlayingPosition
        let wasPlaying = !nowPlayingPaused
        let rate = requestedRate
        recordDiagnostic(
            eventName: "playback_output_selected",
            severity: .notice,
            fields: ["output": next.rawValue, "resume": resume ? "true" : "false"]
        )

        if next == .mac {
            // Exclusive sink: local must never keep playing while Mac is chosen.
            pendingPlayAfterCastConnect = resume && wasPlaying
            stopLocalPlayer(record: true)
            output = .mac
            nowPlayingPaused = !(resume && wasPlaying)
            updateCastKeepAlive()
            if CastSession.shared.currentStatus.connected {
                pushLoadToMac(position: position, rate: rate, autoplay: pendingPlayAfterCastConnect)
                pendingPlayAfterCastConnect = false
            } else {
                CastSession.shared.connectToFirstAvailable()
            }
            // Belt-and-suspenders: ensure nothing local restarted during connect.
            stopLocalPlayer(record: false)
            emitCastStatus(CastSession.shared.currentStatus)
            return
        }

        // Switch back to local — stop Mac first, then only this device plays.
        recordCurrentProgress(force: true)
        pendingPlayAfterCastConnect = false
        CastSession.shared.disconnect(sendStop: true)
        output = .local
        updateCastKeepAlive()
        stopLocalPlayer(record: false)
        if resume, let lastSrc, let url = URL(string: lastSrc) {
            loadLocal(id: id, url: url, episodeID: currentEpisodeID, position: position, rate: rate)
            if wasPlaying {
                playLocal(id: id)
            }
        }
        emitCastStatus(CastSession.shared.currentStatus)
    }

    private func wireCastSessionIfNeeded() {
        guard !castWired else { return }
        castWired = true
        CastSession.shared.onStatusChange = { [weak self] status in
            guard let self else { return }
            // Always hop to main — status callbacks should already be main, but be strict.
            let apply = {
                self.emitCastStatus(status)
                guard self.preferredOutput == .mac else {
                    self.updateCastKeepAlive()
                    return
                }
                self.updateCastKeepAlive()
                guard status.connected else {
                    self.invalidateAutomaticSkip()
                    return
                }
                // Never leave local episode audio running once Mac is reachable.
                self.stopLocalPlayer(record: false)
                self.output = .mac
                if self.pendingPlayAfterCastConnect || self.lastSrc != nil {
                    let shouldPlay = self.pendingPlayAfterCastConnect || !self.nowPlayingPaused
                    self.pushLoadToMac(
                        position: self.nowPlayingPosition,
                        rate: self.requestedRate,
                        autoplay: shouldPlay
                    )
                    self.pendingPlayAfterCastConnect = false
                }
            }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }
        CastSession.shared.onEvent = { [weak self] event in
            // Cast I/O is on a background queue; all player/UI/DB work stays on main.
            DispatchQueue.main.async {
                self?.handleCastEvent(event)
            }
        }
    }

    private func pushLoadToMac(position: Double, rate: Float, autoplay: Bool) {
        guard preferredOutput == .mac else { return }
        guard let publisherURL,
              let source = AdRemovalPlaybackSourcePolicy.macSource(
                publisher: publisherURL,
                downloaded: downloadedEpisode,
                authenticatedStream: resolveMacStreamURL()
              ) else {
            var unavailable = CastSession.shared.currentStatus
            unavailable.error = "Prepared audio is not reachable from this Mac. Keep Pods open and try again."
            emitCastStatus(unavailable)
            updateNowPlaying(paused: true)
            recordDiagnostic(eventName: "mac_prepared_stream_unavailable", severity: .warning)
            return
        }
        // Exclusive: tear down local again in case anything recreated it.
        stopLocalPlayer(record: false)
        output = .mac
        var body: [String: Any] = [
            "cmd": "load",
            "src": source.absoluteString,
            "position": max(0, position),
            "rate": rate,
        ]
        if let currentEpisodeID {
            body["episodeId"] = currentEpisodeID
        }
        if let metadata = nowPlayingMetadata {
            body["title"] = metadata.title
            body["artist"] = metadata.artist
            if let artwork = metadata.artworkURL?.absoluteString {
                body["artwork"] = artwork
            }
            if let duration = metadata.duration, duration > 0 {
                body["duration"] = duration
            }
        } else if nowPlayingDuration > 0 {
            body["duration"] = nowPlayingDuration
        }
        if let playbackSessionID {
            body = AdRemovalPlaybackSession.attaching(sessionID: playbackSessionID, to: body)
        }
        CastSession.shared.sendCommand(body)
        macSourceFailed = false
        recordDiagnostic(
            eventName: "mac_source_load_sent",
            severity: .info,
            fields: [
                "source": downloadedEpisode == nil ? "publisher" : "authenticated_phone_stream",
                "position": "\(max(0, position))",
                "autoplay": autoplay ? "true" : "false"
            ]
        )
        if autoplay {
            CastSession.shared.sendCommand(["cmd": "play"])
            updateNowPlaying(position: position, rate: rate, paused: false)
            emit(type: "play", id: currentId, position: position, playbackRate: rate, paused: false)
        } else {
            updateNowPlaying(position: position, rate: rate, paused: true)
        }
    }

    private func authorizeMacStream(for downloaded: AdRemovalDownloadedEpisode) -> URL? {
        guard let playbackSessionID else { return nil }
        return adRemovalRangeServer?.authorize(
            fileURL: downloaded.audioURL,
            episodeID: downloaded.episodeID,
            playbackSessionID: playbackSessionID
        )
    }

    private func resolveMacStreamURL() -> URL? {
        guard let downloadedEpisode else { return nil }
        if let macStreamURL { return macStreamURL }
        let refreshed = authorizeMacStream(for: downloadedEpisode)
        macStreamURL = refreshed
        return refreshed
    }

    private func handleCastEvent(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        if let eventSessionID = AdRemovalPlaybackSession.sessionID(from: event),
           eventSessionID != playbackSessionID {
            recordDiagnostic(
                eventName: "stale_mac_event_rejected",
                severity: .warning,
                fields: ["event_type": type]
            )
            return
        }
        if type == "castDisconnected" {
            // Keep progress durable. Do NOT auto-start local while user still wants Mac —
            // that caused dual playback when Mac kept playing after a flaky TCP drop.
            recordCurrentProgress(force: true)
            invalidateAutomaticSkip()
            if preferredOutput == .mac {
                output = .mac
                stopLocalPlayer(record: false)
                updateCastKeepAlive()
                // Best-effort reconnect; Mac side stops audio on disconnect.
                CastSession.shared.connectToFirstAvailable()
            } else {
                output = .local
                updateCastKeepAlive()
            }
            emitCastStatus(CastSession.shared.currentStatus)
            return
        }
        if type == "castConnected" {
            emitCastStatus(CastSession.shared.currentStatus)
            return
        }

        // Progress / transport from Mac only while Mac is the chosen sink.
        guard preferredOutput == .mac else { return }

        // Reject explicitly tagged events for a different episode *before* mutating
        // transport or re-emitting — never relabel a stale Mac event as the new load.
        let eventEpisodeID = Self.int64Value(event["episodeId"]) ?? Self.int64Value(event["episode_id"])
        guard PlaybackProgressPolicy.shouldAcceptEpisodeTaggedEvent(
            eventEpisodeID: eventEpisodeID,
            currentEpisodeID: currentEpisodeID
        ) else {
            return
        }

        output = .mac
        // Exclusive sink: ignore any residual episode player (keep-alive is separate).
        stopLocalPlayer(record: false)
        updateCastKeepAlive()

        let rawPosition = Self.doubleValue(event["position"])
        let position = rawPosition.map {
            PlaybackProgressPolicy.resolvedTransportPosition(candidate: $0, lastKnown: nowPlayingPosition)
        }
        let duration = Self.doubleValue(event["duration"])
        let rate = Self.floatValue(event["playbackRate"]).map(Self.normalizedRate)
        let paused = event["paused"] as? Bool
        recordDiagnostic(
            eventName: "mac_transport_event",
            severity: .debug,
            fields: [
                "event_type": type,
                "position": position.map { String($0) } ?? "unknown",
                "paused": paused.map { $0 ? "true" : "false" } ?? "unknown"
            ]
        )

        // Decide before mutating the phone-side clock. This keeps a queued pre-seek
        // Mac timeupdate from regressing now-playing state after the target was seen.
        if type == "timeupdate", let position {
            if var fence = macSupersedingSeekFence {
                switch fence.observe(position: position) {
                case .suppress:
                    macSupersedingSeekFence = fence
                    return
                case .acknowledged:
                    macSupersedingSeekFence = fence
                case .settled:
                    macSupersedingSeekFence = nil
                }
            }
            if applyAutomaticSkipIfNeeded(
                id: currentId,
                position: position,
                macTransportEventType: type
            ) {
                return
            }
        }

        if let position {
            nowPlayingPosition = max(0, position)
        }
        if let duration, duration > 0 {
            nowPlayingDuration = duration
        }
        if let rate {
            nowPlayingRate = rate
            requestedRate = rate
        }
        if let paused {
            nowPlayingPaused = paused
        }

        updateNowPlaying(
            position: position,
            duration: duration,
            rate: rate,
            paused: paused
        )

        switch type {
        case "timeupdate":
            if let position {
                // Cast path: persist frequently so phone progress stays in lockstep with Mac.
                // allowRegress false so stop/pre-seek zeros cannot wipe minutes of progress.
                recordPlaybackProgress(position: position, force: true, allowRegress: false)
            }
            emit(
                type: "timeupdate",
                id: currentId,
                position: position ?? nowPlayingPosition,
                duration: Self.positiveDuration(duration) ?? Self.positiveDuration(nowPlayingDuration),
                playbackRate: rate ?? requestedRate,
                paused: paused ?? nowPlayingPaused
            )
        case "play":
            // Mac started — ensure phone episode player is silent (keep-alive stays).
            stopLocalPlayer(record: false)
            updateCastKeepAlive()
            emit(type: "play", id: currentId, position: position, duration: duration, playbackRate: rate ?? requestedRate, paused: false)
        case "pause":
            if let position {
                recordPlaybackProgress(position: position, force: true, allowRegress: false)
            } else {
                recordCurrentProgress(force: true)
            }
            emit(type: "pause", id: currentId, position: position ?? nowPlayingPosition, duration: duration ?? nowPlayingDuration, playbackRate: rate ?? requestedRate, paused: true)
        case "loadedmetadata":
            macSourceFailed = false
            emit(
                type: "loadedmetadata",
                id: currentId,
                position: position,
                duration: Self.positiveDuration(duration) ?? Self.positiveDuration(nowPlayingDuration),
                playbackRate: rate ?? requestedRate,
                paused: paused ?? true
            )
        case "ended":
            recordCurrentProgress(force: true)
            applyCarResumeLifecycle(.ended)
            persistCarBluetoothSession()
            updateCastKeepAlive()
            emit(type: "ended", id: currentId, position: position, duration: duration, playbackRate: rate ?? requestedRate, paused: true)
        case "state":
            if let position {
                recordPlaybackProgress(position: position, force: true, allowRegress: false)
            }
            emit(type: "state", id: currentId, position: position, duration: duration, playbackRate: rate ?? requestedRate, paused: paused)
        case "error":
            invalidateAutomaticSkip()
            macSourceFailed = true
            nowPlayingPaused = true
            if let position {
                recordPlaybackProgress(position: position, force: true, allowRegress: false)
            }
            updateNowPlaying(position: position, rate: 0, paused: true)
            var failed = CastSession.shared.currentStatus
            failed.error = event["message"] as? String ?? "The iPhone audio stream is unavailable."
            emitCastStatus(failed)
            emit(type: "pause", id: currentId, position: position ?? nowPlayingPosition, playbackRate: requestedRate, paused: true)
            recordDiagnostic(eventName: "mac_stream_unavailable", severity: .warning)
        default:
            break
        }
    }

    // MARK: - Transport

    private func load(
        id: Int,
        url: URL,
        episodeID: Int64?,
        position: Double,
        rate: Float,
        clearsCarResume: Bool = true
    ) {
        let restorePlayback = !clearsCarResume && (!nowPlayingPaused || (player?.rate ?? 0) > 0)
        applyCarResumeLifecycle(clearsCarResume ? .userLoad : .rebuildSameEpisode)
        playbackSessionID = AdRemovalPlaybackSession.makeID()
        currentEpisodeID = episodeID
        publisherURL = url
        downloadedEpisode = nil
        macStreamURL = nil
        macSourceFailed = false
        adRemovalRangeServer?.revoke()
        adRemovalSkipSession.clear()
        invalidateAutomaticSkip()
        if let episodeID, let adRemovalPlaybackProvider {
            do {
                if let downloaded = try adRemovalPlaybackProvider.downloadedEpisode(episodeID: episodeID) {
                    downloadedEpisode = downloaded
                    if downloaded.manifestReady {
                        adRemovalSkipSession.replaceRanges(downloaded.ranges)
                    }
                    macStreamURL = authorizeMacStream(for: downloaded)
                }
            } catch {
                recordDiagnostic(
                    eventName: "prepared_playback_source_rejected",
                    severity: .warning,
                    fields: ["error": String(describing: error)]
                )
            }
        }
        let selectedURL = AdRemovalPlaybackSourcePolicy.localSource(
            publisher: url,
            downloaded: downloadedEpisode
        )
        lastSrc = selectedURL.absoluteString
        lastRecordedEpisodeID = nil
        lastRecordedPosition = nil
        requestedRate = rate
        nowPlayingPosition = max(0, position)
        recordDiagnostic(
            eventName: "playback_source_selection",
            severity: .notice,
            fields: [
                "request_url": selectedURL.isFileURL ? "local-prepared-audio" : url.absoluteString,
                "source": downloadedEpisode == nil ? "publisher" : "downloaded_local",
                "manifest_ready": downloadedEpisode?.manifestReady == true ? "true" : "false",
                "output": preferredOutput.rawValue,
                "position": "\(max(0, position))"
            ]
        )

        if preferredOutput == .mac || output == .mac {
            preferredOutput = .mac
            output = .mac
            stopLocalPlayer(record: false)
            updateCastKeepAlive()
            let wasPlaying = !nowPlayingPaused
            let connected = CastSession.shared.currentStatus.connected
            // Assign (not only set-true) so a connected replacement clears a stale reconnect flag.
            pendingPlayAfterCastConnect = PlaybackProgressPolicy.shouldPendMacPlayAfterConnect(
                wasPlaying: wasPlaying,
                connected: connected,
                playRequested: false
            )
            if !connected {
                CastSession.shared.connectToFirstAvailable()
            }
            // Preserve play intent on Mac: autoplay when still connected; else pend for reconnect.
            let autoplay = PlaybackProgressPolicy.shouldAutoplayMacSourceReplacement(
                wasPlaying: wasPlaying,
                connected: connected
            )
            pushLoadToMac(position: position, rate: rate, autoplay: autoplay)
            let paused = PlaybackProgressPolicy.macSourceReplacementPaused(
                wasPlaying: wasPlaying,
                pendingPlayAfterConnect: pendingPlayAfterCastConnect
            )
            updateNowPlaying(position: position, rate: rate, paused: paused)
            persistCarBluetoothSession()
            emit(
                type: "loadedmetadata",
                id: id,
                position: position,
                duration: Self.positiveDuration(nowPlayingDuration),
                playbackRate: rate,
                paused: paused
            )
            return
        }

        updateCastKeepAlive()
        loadLocal(id: id, url: selectedURL, episodeID: episodeID, position: position, rate: rate)
        persistCarBluetoothSession()
        if restorePlayback {
            playLocal(id: id)
        } else if !clearsCarResume {
            attemptCarBluetoothResumeFromCurrentRoute()
        }
    }

    private func loadLocal(id: Int, url: URL, episodeID: Int64?, position: Double, rate: Float) {
        removeTimeObserver()
        currentEpisodeID = episodeID
        requestedRate = rate
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.automaticallyWaitsToMinimizeStalling = true
        if position > 0 {
            player?.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        }
        addTimeObserver(id: id)
        let initialDuration = item.duration.seconds
        updateNowPlaying(position: position, duration: initialDuration, rate: rate, paused: true)
        // After updateNowPlaying, prefer AV duration, else metadata-backed nowPlayingDuration.
        let resolved = Self.positiveDuration(initialDuration) ?? Self.positiveDuration(nowPlayingDuration)
        emit(type: "loadedmetadata", id: id, position: position, duration: resolved, playbackRate: rate, paused: true)
        _ = applyAutomaticSkipIfNeeded(id: id, position: position)
    }

    private func play(id: Int) {
        if preferredOutput == .mac || output == .mac {
            preferredOutput = .mac
            output = .mac
            stopLocalPlayer(record: false)
            updateCastKeepAlive()
            let connected = CastSession.shared.currentStatus.connected
            if PlaybackProgressPolicy.shouldPendMacPlayAfterConnect(
                wasPlaying: false,
                connected: connected,
                playRequested: true
            ) {
                pendingPlayAfterCastConnect = true
                // Keep logical play intent while the cast link comes back.
                updateNowPlaying(rate: requestedRate, paused: false)
                CastSession.shared.connectToFirstAvailable()
                return
            }
            pendingPlayAfterCastConnect = false
            if PlaybackProgressPolicy.shouldReloadMacSource(sourceFailed: macSourceFailed) {
                pushLoadToMac(position: nowPlayingPosition, rate: requestedRate, autoplay: true)
                return
            }
            CastSession.shared.sendCommand(["cmd": "play"])
            updateNowPlaying(rate: requestedRate, paused: false)
            emit(type: "play", id: id, playbackRate: requestedRate, paused: false)
            return
        }
        playLocal(id: id)
    }

    private func playLocal(id: Int) {
        // Never start local audio while the user has chosen Mac.
        guard preferredOutput == .local else {
            stopLocalPlayer(record: false)
            return
        }
        ensureLocalPlayer(id: id)
        if let player {
            let position = player.currentTime().seconds
            if position.isFinite {
                _ = applyAutomaticSkipIfNeeded(id: id, position: position)
            }
        }
        configureSession()
        player?.rate = requestedRate
        applyCarResumeLifecycle(.manualPlay)
        updateNowPlaying(rate: requestedRate, paused: false)
        persistCarBluetoothSession()
        updateCastKeepAlive()
        emit(type: "play", id: id, playbackRate: requestedRate, paused: false)
    }

    /// Rebuild AVPlayer from the last publisher URL when Tesla/AVRCP play
    /// arrives after iOS tore the item down (or after a persisted restore).
    private func ensureLocalPlayer(id: Int) {
        if player?.currentItem != nil { return }
        if let publisherURL {
            load(
                id: id,
                url: publisherURL,
                episodeID: currentEpisodeID,
                position: nowPlayingPosition,
                rate: requestedRate,
                clearsCarResume: false
            )
            return
        }
        if let lastSrc, let url = URL(string: lastSrc) {
            loadLocal(id: id, url: url, episodeID: currentEpisodeID, position: nowPlayingPosition, rate: requestedRate)
        }
    }

    private func pause(id: Int, userInitiated: Bool = true) {
        if userInitiated {
            applyCarResumeLifecycle(.userPause)
        }
        if preferredOutput == .mac || output == .mac {
            CastSession.shared.sendCommand(["cmd": "pause"])
            recordCurrentProgress(force: true)
            updateNowPlaying(rate: 0, paused: true)
            persistCarBluetoothSession()
            emitPlaybackState(type: "pause", id: id, paused: true)
            return
        }
        player?.pause()
        recordCurrentProgress(force: true)
        updateNowPlaying(rate: 0, paused: true)
        persistCarBluetoothSession()
        updateCastKeepAlive()
        emitPlaybackState(type: "pause", id: id, paused: true)
    }

    private func seek(id: Int, seconds: Double) {
        let safe = max(0, seconds)
        // A user seek supersedes any asynchronous automatic seek completion.
        invalidateAutomaticSkip()
        if applyAutomaticSkipIfNeeded(id: id, position: safe) {
            return
        }
        nowPlayingPosition = safe
        if preferredOutput == .mac || output == .mac {
            macSupersedingSeekFence = AdRemovalMacSupersedingSeekFence(
                targetPosition: safe
            )
            CastSession.shared.sendCommand(["cmd": "seek", "seconds": safe])
            updateNowPlaying(position: safe)
            recordPlaybackProgress(position: safe, force: true, allowRegress: true)
            emit(
                type: "timeupdate",
                id: id,
                position: safe,
                duration: Self.positiveDuration(nowPlayingDuration),
                playbackRate: requestedRate,
                paused: nowPlayingPaused
            )
            return
        }
        player?.seek(to: CMTime(seconds: safe, preferredTimescale: 600))
        updateNowPlaying(position: safe)
        recordPlaybackProgress(position: safe, force: true, allowRegress: true)
    }

    private func setRate(id: Int, rate: Float, correlationID: String? = nil) {
        requestedRate = rate
        if let correlationID {
            speedDiagnosticTracker.begin(correlationID: correlationID, requestedRate: rate)
            let actualRate = player?.rate ?? 0
            let timeControlStatus = player.map { Self.timeControlStatusName($0.timeControlStatus) } ?? "no_player"
            PodsLog(
                "speed_apply_attempt correlation_id=\(correlationID) requested_rate=\(rate) actual_rate=\(actualRate) " +
                "time_control_status=\(timeControlStatus) logical_paused=\(nowPlayingPaused) output=\(output.rawValue)"
            )
        }
        if preferredOutput == .mac || output == .mac {
            CastSession.shared.sendCommand(["cmd": "rate", "rate": rate])
            if !nowPlayingPaused {
                updateNowPlaying(rate: rate, paused: false)
            } else {
                updateNowPlaying(rate: rate)
            }
            return
        }
        if let player, player.rate != 0 {
            player.rate = rate
            updateNowPlaying(rate: rate, paused: false)
        } else {
            updateNowPlaying(rate: rate)
        }
    }

    private func stop(id: Int) {
        recordCurrentProgress(force: true)
        if preferredOutput == .mac || output == .mac {
            CastSession.shared.sendCommand(["cmd": "stop"])
        }
        preferredOutput = .local
        output = .local
        pendingPlayAfterCastConnect = false
        updateCastKeepAlive()
        stopLocalPlayer(record: false)
        currentEpisodeID = nil
        downloadedEpisode = nil
        publisherURL = nil
        macStreamURL = nil
        macSourceFailed = false
        adRemovalRangeServer?.revoke()
        adRemovalSkipSession.clear()
        invalidateAutomaticSkip()
        playbackSessionID = nil
        lastRecordedEpisodeID = nil
        lastRecordedPosition = nil
        lastSrc = nil
        applyCarResumeLifecycle(.stop)
        carBluetoothSessionStore.clear()
        updateCastKeepAlive()
        clearNowPlaying()
        emit(type: "pause", id: id, position: 0, duration: 0)
    }

    private func stopLocalPlayer(record: Bool) {
        if record {
            // Prefer live local clock when still available.
            if let player, output == .local {
                let seconds = player.currentTime().seconds
                if seconds.isFinite {
                    nowPlayingPosition = max(0, seconds)
                }
            }
            recordCurrentProgress(force: true)
        }
        removeTimeObserver()
        if let player {
            player.pause()
            player.rate = 0
            player.replaceCurrentItem(with: nil)
        }
        player = nil
    }

    private func addTimeObserver(id: Int) {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            // Only local clock writes progress when not casting.
            guard self.output == .local else { return }
            guard !self.applyAutomaticSkipIfNeeded(id: id, position: time.seconds) else { return }
            let itemDuration = player.currentItem?.duration.seconds
            self.updateNowPlaying(
                position: time.seconds,
                duration: itemDuration,
                rate: player.rate == 0 ? self.requestedRate : player.rate,
                paused: player.rate == 0
            )
            let resolved = Self.positiveDuration(itemDuration) ?? Self.positiveDuration(self.nowPlayingDuration)
            self.emit(
                type: "timeupdate",
                id: id,
                position: time.seconds,
                duration: resolved,
                playbackRate: player.rate,
                paused: player.rate == 0
            )
            self.logPendingSpeedObservation(actualRate: player.rate, source: "local_time_observer")
            self.recordPlaybackProgress(position: time.seconds)
        }
    }

    private func logPendingSpeedObservation(actualRate: Float, source: String) {
        guard let observation = speedDiagnosticTracker.takeObservation() else { return }
        PodsLog(
            "speed_apply_observed correlation_id=\(observation.correlationID) requested_rate=\(observation.requestedRate) " +
            "actual_rate=\(actualRate) source=\(source)"
        )
    }

    private static func timeControlStatusName(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        case .playing: return "playing"
        @unknown default: return "unknown"
        }
    }

    @discardableResult
    private func applyAutomaticSkipIfNeeded(
        id: Int,
        position: Double,
        macTransportEventType: String? = nil
    ) -> Bool {
        if output == .mac || preferredOutput == .mac {
            return applyMacAutomaticSkipIfNeeded(
                id: id,
                position: position,
                transportEventType: macTransportEventType
            )
        }

        guard !automaticSkipInFlight,
              downloadedEpisode?.manifestReady == true,
              player != nil else {
            return false
        }
        let decision = adRemovalSkipSession.enter(position: position)
        guard let decision else { return false }
        automaticSkipInFlight = true
        let lifecycleToken = automaticSkipLifecycle.generation
        let started = Date()
        recordDiagnostic(
            eventName: "playback_ad_range_entered",
            severity: .notice,
            fields: [
                "range_id": decision.rangeID,
                "original_position": String(position),
                "seek_target": String(decision.targetPosition),
                "output": output.rawValue
            ]
        )

        if let player {
            player.seek(
                to: CMTime(seconds: decision.targetPosition, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                completionHandler: { [weak self] succeeded in
                    self?.finishAutomaticSkip(
                        id: id,
                        decision: decision,
                        started: started,
                        lifecycleToken: lifecycleToken,
                        succeeded: succeeded
                    )
                }
            )
        } else {
            finishAutomaticSkip(
                id: id,
                decision: decision,
                started: started,
                lifecycleToken: lifecycleToken,
                succeeded: false
            )
            return false
        }
        return true
    }

    private func applyMacAutomaticSkipIfNeeded(
        id: Int,
        position: Double,
        transportEventType: String?
    ) -> Bool {
        guard downloadedEpisode?.manifestReady == true,
              !macSourceFailed,
              CastSession.shared.currentStatus.connected,
              transportEventType == nil || transportEventType == "timeupdate" else {
            return false
        }
        let lifecycleToken = automaticSkipLifecycle.generation
        switch macAutomaticSkipState.observe(
            position: position,
            lifecycleToken: lifecycleToken
        ) {
        case .suppress:
            return true
        case .completed(let attempt):
            cancelMacAutomaticSkipRetry()
            finishAutomaticSkip(
                id: id,
                decision: attempt.decision,
                started: attempt.startedAt,
                lifecycleToken: attempt.lifecycleToken,
                succeeded: true
            )
            return false
        case .passThrough:
            break
        }

        let decision: AdRemovalSkipDecision?
        if let transportEventType {
            decision = adRemovalSkipSession.enterMacTransportEvent(
                type: transportEventType,
                position: position
            )
        } else {
            decision = adRemovalSkipSession.enter(position: position)
        }
        guard let decision,
              let attempt = macAutomaticSkipState.begin(
                  decision: decision,
                  lifecycleToken: lifecycleToken,
                  now: Date()
              ) else {
            return false
        }
        recordDiagnostic(
            eventName: "playback_ad_range_entered",
            severity: .notice,
            fields: [
                "range_id": decision.rangeID,
                "original_position": String(position),
                "seek_target": String(decision.targetPosition),
                "output": output.rawValue
            ]
        )
        sendMacAutomaticSkipAttempt(id: id, attempt: attempt)
        return true
    }

    private func sendMacAutomaticSkipAttempt(id: Int, attempt: AdRemovalMacSkipAttempt) {
        scheduleMacAutomaticSkipRetry(id: id, attempt: attempt)
        CastSession.shared.sendCommand([
            "cmd": "seek",
            "seconds": attempt.decision.targetPosition
        ]) { [weak self] succeeded in
            guard let self,
                  self.automaticSkipLifecycle.accepts(attempt.lifecycleToken),
                  self.macAutomaticSkipState.acceptsDelivery(
                      attemptToken: attempt.token,
                      lifecycleToken: attempt.lifecycleToken
                  ),
                  !succeeded else {
                return
            }
            self.recordDiagnostic(
                eventName: "playback_ad_seek_send_failed",
                severity: .warning,
                fields: [
                    "range_id": attempt.decision.rangeID,
                    "attempt": String(attempt.attemptNumber)
                ]
            )
        }
    }

    private func scheduleMacAutomaticSkipRetry(id: Int, attempt: AdRemovalMacSkipAttempt) {
        cancelMacAutomaticSkipRetry()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.automaticSkipLifecycle.accepts(attempt.lifecycleToken) else {
                return
            }
            guard CastSession.shared.currentStatus.connected else {
                self.invalidateAutomaticSkip()
                return
            }
            let transition = self.macAutomaticSkipState.retry(
                attemptToken: attempt.token,
                lifecycleToken: attempt.lifecycleToken,
                now: Date(),
                maximumAttempts: self.macAutomaticSkipMaximumAttempts
            )
            switch transition {
            case .ignored:
                return
            case .exhausted(let failed):
                self.macAutomaticSkipRetryWorkItem = nil
                self.recordDiagnostic(
                    eventName: "playback_ad_seek_failed",
                    severity: .warning,
                    fields: [
                        "range_id": failed.decision.rangeID,
                        "attempts": String(failed.attemptNumber),
                        "reason": "mac_ack_timeout"
                    ]
                )
            case .retry(let retry):
                self.recordDiagnostic(
                    eventName: "playback_ad_seek_retry",
                    severity: .warning,
                    fields: [
                        "range_id": retry.decision.rangeID,
                        "attempt": String(retry.attemptNumber)
                    ]
                )
                self.sendMacAutomaticSkipAttempt(id: id, attempt: retry)
            }
        }
        macAutomaticSkipRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + macAutomaticSkipRetryDelay,
            execute: workItem
        )
    }

    private func cancelMacAutomaticSkipRetry() {
        macAutomaticSkipRetryWorkItem?.cancel()
        macAutomaticSkipRetryWorkItem = nil
    }

    private func finishAutomaticSkip(
        id: Int,
        decision: AdRemovalSkipDecision,
        started: Date,
        lifecycleToken: UInt64,
        succeeded: Bool
    ) {
        guard automaticSkipLifecycle.accepts(lifecycleToken) else { return }
        automaticSkipInFlight = false
        guard succeeded else {
            recordDiagnostic(
                eventName: "playback_ad_seek_failed",
                severity: .warning,
                fields: ["range_id": decision.rangeID]
            )
            return
        }
        adRemovalSkipSession.didComplete(decision)
        nowPlayingPosition = decision.targetPosition
        updateNowPlaying(position: decision.targetPosition)
        recordPlaybackProgress(
            position: decision.targetPosition,
            force: true,
            allowRegress: false
        )
        emitAdRemovalEvent(type: "adSkip", id: id, decision: decision)
        recordDiagnostic(
            eventName: "playback_ad_seek_completed",
            severity: .notice,
            fields: [
                "range_id": decision.rangeID,
                "latency_ms": String(Int(Date().timeIntervalSince(started) * 1_000))
            ]
        )
    }

    private func invalidateAutomaticSkip() {
        automaticSkipLifecycle.invalidate()
        automaticSkipInFlight = false
        macAutomaticSkipState.invalidate()
        macSupersedingSeekFence = nil
        cancelMacAutomaticSkipRetry()
    }

    private func undoPendingAdSkip(id: Int) {
        guard let decision = adRemovalSkipSession.pending,
              let episodeID = currentEpisodeID,
              let adRemovalPlaybackProvider else {
            return
        }
        do {
            let result = try adRemovalPlaybackProvider.undoSkip(
                episodeID: episodeID,
                rangeID: decision.rangeID
            )
            adRemovalSkipSession.didUndo(rangeID: result.disabledRangeID)
            invalidateAutomaticSkip()
            nowPlayingPosition = result.seekPosition
            if output == .mac || preferredOutput == .mac {
                macSupersedingSeekFence = AdRemovalMacSupersedingSeekFence(
                    targetPosition: result.seekPosition
                )
                CastSession.shared.sendCommand(["cmd": "seek", "seconds": result.seekPosition])
            } else {
                player?.seek(
                    to: CMTime(seconds: result.seekPosition, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            updateNowPlaying(position: result.seekPosition)
            recordPlaybackProgress(position: result.seekPosition, force: true, allowRegress: true)
            emitAdRemovalEvent(
                type: "adSkipUndone",
                id: id,
                decision: decision,
                position: result.seekPosition
            )
            recordDiagnostic(
                eventName: "playback_ad_skip_undone",
                severity: .notice,
                fields: [
                    "range_id": result.disabledRangeID,
                    "correction_id": result.correction.id
                ]
            )
        } catch {
            recordDiagnostic(
                eventName: "playback_ad_skip_undo_failed",
                severity: .error,
                fields: ["error": String(describing: error)]
            )
        }
    }

    private func emitAdRemovalEvent(
        type: String,
        id: Int,
        decision: AdRemovalSkipDecision,
        position: Double? = nil
    ) {
        var payload: [String: Any] = [
            "type": type,
            "id": id,
            "rangeId": decision.rangeID,
            "rangeStart": decision.rangeStart,
            "rangeEnd": decision.rangeEnd,
            "skippedDuration": decision.skippedDuration,
            "position": position ?? decision.targetPosition
        ]
        if let currentEpisodeID {
            payload["episodeId"] = currentEpisodeID
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.PodsAudioBridge && window.PodsAudioBridge.emit(\(json));")
        }
    }

    private func removeTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    @objc private func playerItemEnded(_ notification: Notification) {
        let episodeLabel = currentEpisodeID.map(String.init) ?? "none"
        guard output == .local else {
            PodsLog("playback_native_ended_ignored reason=non_local output=\(output.rawValue) episode_id=\(episodeLabel) player_id=\(currentId)")
            return
        }
        // Only the *current* AVPlayer item may complete — a replaced item's end
        // notification must not mark/skip the newly loaded episode.
        let endedItem = notification.object as AnyObject?
        let currentItem = player?.currentItem as AnyObject?
        guard PlaybackProgressPolicy.isSameObject(endedItem, currentItem) else {
            PodsLog("playback_native_ended_ignored reason=stale_item episode_id=\(episodeLabel) player_id=\(currentId)")
            return
        }
        PodsLog("playback_native_ended_observed episode_id=\(episodeLabel) player_id=\(currentId)")
        recordCurrentProgress(force: true)
        applyCarResumeLifecycle(.ended)
        persistCarBluetoothSession()
        updateCastKeepAlive()
        emit(type: "ended", id: currentId, paused: true)
    }

    @objc private func audioInterrupted(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        // While casting, only the silent keep-alive uses the phone audio session.
        if preferredOutput == .mac || output == .mac {
            switch type {
            case .began:
                recordCurrentProgress(force: true)
            case .ended:
                updateCastKeepAlive()
                if CastSession.shared.currentStatus.connected {
                    CastSession.shared.sendCommand(["cmd": "ping"])
                }
            @unknown default:
                break
            }
            return
        }

        switch type {
        case .began:
            shouldResumeAfterInterruption = player?.rate ?? 0 > 0 || !nowPlayingPaused
            pause(id: currentId, userInitiated: false)
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            let currentRoutes = Self.routeDescriptors(AVAudioSession.sharedInstance().currentRoute)
            let context = currentCarRouteContext(outputs: currentRoutes)
            if CarBluetoothPlaybackPolicy.shouldResumeAfterInterruption(
                shouldResumeOption: options.contains(.shouldResume),
                wasPlayingBeforeInterruption: shouldResumeAfterInterruption,
                currentCarMatchesArmedIntent: CarBluetoothPlaybackPolicy.currentCarMatchesIntent(
                    routes: currentRoutes,
                    intent: carBluetoothResumeIntent,
                    now: Date().timeIntervalSince1970,
                    context: context
                ),
                isLocalOutput: preferredOutput == .local
            ) {
                play(id: currentId)
            }
            shouldResumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    @objc private func audioRouteChanged(_ notification: Notification) {
        guard output == .local else { return }
        let info = notification.userInfo
        let rawReason = info?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown
        let previousRoute = info?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let previousRoutes = Self.routeDescriptors(previousRoute)
        let currentRoutes = Self.routeDescriptors(AVAudioSession.sharedInstance().currentRoute)
        let context = currentCarRouteContext(outputs: currentRoutes + previousRoutes)
        rememberCarIdentities(from: currentRoutes + previousRoutes, context: context)
        let hasContent = currentEpisodeID != nil || lastSrc != nil || publisherURL != nil
        let isPlaying = !nowPlayingPaused || (player?.rate ?? 0) > 0
        let now = Date().timeIntervalSince1970

        let action = CarBluetoothPlaybackPolicy.action(
            reason: reason,
            previousRoutes: previousRoutes,
            currentRoutes: currentRoutes,
            hasActiveContent: hasContent,
            isPlaying: isPlaying,
            intent: carBluetoothResumeIntent,
            currentEpisodeID: currentEpisodeID,
            isLocalOutput: preferredOutput == .local,
            now: now,
            context: context
        )
        PodsLog(
            "Pods car-resume reason=\(reason.rawValue) action=\(String(describing: action)) " +
            "current=\(currentRoutes.map { "\($0.name)/\($0.portTypeRaw)" }.joined(separator: ","))"
        )
        switch action {
        case .remember(let intent):
            carBluetoothResumeIntent = intent
            persistCarBluetoothSession()
            if isPlaying {
                pause(id: currentId, userInitiated: false)
            }
            updateCastKeepAlive()
        case .schedule(let intent):
            carBluetoothResumeIntent = intent
            persistCarBluetoothSession()
            scheduleCarBluetoothResume(intent)
            updateCastKeepAlive()
        case .clear:
            applyCarResumeLifecycle(.expired)
            persistCarBluetoothSession()
            updateCastKeepAlive()
        case .none:
            break
        }

        let itemDuration = player?.currentItem?.duration.seconds
        updateNowPlaying(
            position: player?.currentTime().seconds ?? nowPlayingPosition,
            duration: itemDuration,
            rate: player?.rate ?? requestedRate,
            paused: (player?.rate ?? 0) == 0 && nowPlayingPaused
        )
        let resolved = Self.positiveDuration(itemDuration) ?? Self.positiveDuration(nowPlayingDuration)
        emit(
            type: "state",
            id: currentId,
            position: player?.currentTime().seconds ?? nowPlayingPosition,
            duration: resolved,
            playbackRate: player?.rate ?? requestedRate,
            paused: (player?.rate ?? 0) == 0 && nowPlayingPaused
        )
    }

    private func scheduleCarBluetoothResume(_ intent: CarBluetoothResumeIntent) {
        carBluetoothResumeWorkItem?.cancel()
        carBluetoothResumeGeneration += 1
        let generation = carBluetoothResumeGeneration
        let work = DispatchWorkItem { [weak self] in
            self?.commitScheduledCarBluetoothResume(generation: generation, scheduled: intent)
        }
        carBluetoothResumeWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CarBluetoothPlaybackPolicy.resumeSettleDelay,
            execute: work
        )
    }

    private func applyCarResumeLifecycle(_ event: CarBluetoothPlaybackPolicy.LifecycleEvent) {
        let decision = CarBluetoothPlaybackPolicy.lifecycleDecision(for: event)
        if decision.cancelPending {
            cancelScheduledCarBluetoothResume()
        }
        carBluetoothResumeIntent = CarBluetoothPlaybackPolicy.applying(
            decision,
            to: carBluetoothResumeIntent
        )
    }

    private func cancelScheduledCarBluetoothResume() {
        carBluetoothResumeGeneration += 1
        carBluetoothResumeWorkItem?.cancel()
        carBluetoothResumeWorkItem = nil
    }

    private func commitScheduledCarBluetoothResume(
        generation: UInt64,
        scheduled: CarBluetoothResumeIntent
    ) {
        guard generation == carBluetoothResumeGeneration else { return }
        carBluetoothResumeWorkItem = nil
        guard preferredOutput == .local else { return }
        let currentRoutes = Self.routeDescriptors(AVAudioSession.sharedInstance().currentRoute)
        let context = currentCarRouteContext(outputs: currentRoutes)
        rememberCarIdentities(from: currentRoutes, context: context)
        guard CarBluetoothPlaybackPolicy.shouldCommitScheduledResume(
            scheduled: scheduled,
            currentRoutes: currentRoutes,
            currentEpisodeID: currentEpisodeID,
            isLocalOutput: true,
            now: Date().timeIntervalSince1970,
            context: context
        ) else {
            PodsLog(
                "Pods car-resume commit deferred current=\(currentRoutes.map { "\($0.name)/\($0.portTypeRaw)" }.joined(separator: ","))"
            )
            return
        }
        PodsLog("Pods car-resume commit play episode_id=\(currentEpisodeID.map(String.init) ?? "none")")
        play(id: currentId)
    }

    private func currentCarRouteContext(
        outputs: [CarBluetoothRouteDescriptor]
    ) -> CarBluetoothRouteContext {
        let inputs = AVAudioSession.sharedInstance().availableInputs?.map {
            CarBluetoothRouteDescriptor($0)
        } ?? []
        return CarBluetoothRouteContext(
            knownCarDeviceKeys: Set(knownCarDeviceKeys),
            handsFreeDeviceKeys: CarBluetoothRouteContext.handsFreeDeviceKeys(from: outputs + inputs)
        )
    }

    private func rememberCarIdentities(
        from routes: [CarBluetoothRouteDescriptor],
        context: CarBluetoothRouteContext
    ) {
        knownCarDeviceKeys = CarBluetoothPlaybackPolicy.discoveredCarDeviceKeys(
            routes: routes,
            context: context
        )
        carBluetoothSessionStore.saveKnownCarDeviceKeys(knownCarDeviceKeys)
    }

    private func attemptCarBluetoothResumeFromCurrentRoute() {
        guard preferredOutput == .local else { return }
        let now = Date().timeIntervalSince1970
        let currentRoutes = Self.routeDescriptors(AVAudioSession.sharedInstance().currentRoute)
        let context = currentCarRouteContext(outputs: currentRoutes)
        rememberCarIdentities(from: currentRoutes, context: context)
        guard CarBluetoothPlaybackPolicy.shouldScheduleResumeOnForeground(
            intent: carBluetoothResumeIntent,
            currentRoutes: currentRoutes,
            hasActiveContent: hasPlayableContent,
            isLocalOutput: true,
            now: now,
            context: context
        ) else {
            return
        }
        guard let intent = carBluetoothResumeIntent else { return }
        PodsLog("Pods car-resume foreground/hydrate schedule episode_id=\(intent.episodeID.map(String.init) ?? "none")")
        scheduleCarBluetoothResume(intent)
    }

    private static func routeDescriptors(_ route: AVAudioSessionRouteDescription?) -> [CarBluetoothRouteDescriptor] {
        route?.outputs.map { CarBluetoothRouteDescriptor($0) } ?? []
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            guard self.hasPlayableContent else { return .noActionableNowPlayingItem }
            self.play(id: self.currentId)
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            self.pause(id: self.currentId, userInitiated: true)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            guard self.hasPlayableContent else { return .noActionableNowPlayingItem }
            if self.nowPlayingPaused {
                self.play(id: self.currentId)
            } else {
                self.pause(id: self.currentId, userInitiated: true)
            }
            return .success
        }
        configureForwardRemoteCommands(using: SystemRemoteForwardCommandRegistrar())
    }

    private var hasPlayableContent: Bool {
        currentEpisodeID != nil || lastSrc != nil || publisherURL != nil
    }

    /// Install Next/Previous, skip, and Tesla scrubber through the registrar seam.
    private func configureForwardRemoteCommands(using registrar: RemoteForwardCommandRegistering) {
        RemoteForwardCommandBinding.install(
            on: registrar,
            forwardSkip: { [weak self] interval in
                guard let self else { return .noSuchContent }
                return self.handleRemoteForwardSkip(interval: interval)
            }
        )
        RemoteForwardCommandBinding.installSeek(
            on: registrar,
            seekTo: { [weak self] position in
                guard let self else { return .noSuchContent }
                return self.handleRemotePlaybackPosition(position)
            }
        )
    }

    /// Car/accessory forward skip: snapshot live state, then pure absolute-seek policy.
    @discardableResult
    private func handleRemoteForwardSkip(interval: TimeInterval) -> MPRemoteCommandHandlerStatus {
        let hasActiveContent = currentEpisodeID != nil

        let currentPosition: Double
        if preferredOutput == .mac || output == .mac {
            currentPosition = nowPlayingPosition
        } else if let live = player?.currentTime().seconds, live.isFinite {
            currentPosition = max(0, live)
        } else {
            currentPosition = nowPlayingPosition
        }

        let liveDuration = (output == .local) ? player?.currentItem?.duration.seconds : nil
        let knownDuration = Self.positiveDuration(liveDuration) ?? Self.positiveDuration(nowPlayingDuration)

        return RemoteForwardSkipHandler.handle(
            hasActiveContent: hasActiveContent,
            currentPosition: currentPosition,
            knownDuration: knownDuration,
            interval: interval,
            absoluteSeek: { [weak self] target in
                guard let self else { return }
                self.seek(id: self.currentId, seconds: target)
            }
        )
    }

    @discardableResult
    private func handleRemotePlaybackPosition(_ position: TimeInterval) -> MPRemoteCommandHandlerStatus {
        let knownDuration = Self.positiveDuration(nowPlayingDuration)
            ?? Self.positiveDuration(player?.currentItem?.duration.seconds)
        return RemotePlaybackPositionHandler.handle(
            hasActiveContent: currentEpisodeID != nil || lastSrc != nil || publisherURL != nil,
            position: position,
            knownDuration: knownDuration,
            absoluteSeek: { [weak self] target in
                guard let self else { return }
                self.seek(id: self.currentId, seconds: target)
            }
        )
    }

    private func recordCurrentProgress(force: Bool = false) {
        recordPlaybackProgress(position: nowPlayingPosition, force: force, allowRegress: false)
    }

    private func recordDiagnostic(
        eventName: String,
        severity: AdRemovalDiagnosticSeverity,
        fields: [String: String] = [:]
    ) {
        try? diagnostics?.record(
            eventName: eventName,
            severity: severity,
            context: .init(
                episodeID: currentEpisodeID,
                playbackSessionID: playbackSessionID
            ),
            fields: fields
        )
    }

    private func recordPlaybackProgress(position: Double, force: Bool = false, allowRegress: Bool = false) {
        guard let currentEpisodeID else {
            return
        }
        let lastForEpisode = lastRecordedEpisodeID == currentEpisodeID ? lastRecordedPosition : nil
        guard PlaybackProgressPolicy.shouldPersist(
            position: position,
            lastRecordedPosition: lastForEpisode,
            force: force,
            allowRegress: allowRegress,
            strideSeconds: progressRecordStrideSeconds
        ) else {
            return
        }
        progressRecorder?.recordPlaybackProgress(episodeID: currentEpisodeID, seconds: position)
        lastRecordedEpisodeID = currentEpisodeID
        lastRecordedPosition = position
        nowPlayingPosition = position
        persistCarBluetoothSession()
    }

    // MARK: - Cast keep-alive (prevents iOS suspend while Mac plays)

    private func updateCastKeepAlive() {
        if PlaybackProgressPolicy.shouldRunCastKeepAlive(preferredOutputIsMac: preferredOutput == .mac)
            || shouldRunCarResumeKeepAlive() {
            startCastKeepAliveIfNeeded()
        } else {
            stopCastKeepAlive()
        }
    }

    private func shouldRunCarResumeKeepAlive() -> Bool {
        preferredOutput == .local
            && nowPlayingPaused
            && (player?.rate ?? 0) == 0
            && CarBluetoothPlaybackPolicy.shouldKeepSessionAlive(
                intent: carBluetoothResumeIntent,
                now: Date().timeIntervalSince1970,
                context: currentCarRouteContext(
                    outputs: Self.routeDescriptors(AVAudioSession.sharedInstance().currentRoute)
                )
            )
    }

    private func startCastKeepAliveIfNeeded() {
        if let castKeepAlivePlayer, castKeepAlivePlayer.isPlaying {
            return
        }
        configureSession()
        do {
            let player = try AVAudioPlayer(data: PlaybackProgressPolicy.silentKeepAliveWavData())
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            if player.play() {
                castKeepAlivePlayer = player
                PodsLog("Pods cast keep-alive started")
            } else {
                PodsLog("Pods cast keep-alive failed to start playback")
            }
        } catch {
            PodsLog("Pods cast keep-alive setup failed: \(error)")
        }
    }

    private func stopCastKeepAlive() {
        guard castKeepAlivePlayer != nil else { return }
        castKeepAlivePlayer?.stop()
        castKeepAlivePlayer = nil
        PodsLog("Pods cast keep-alive stopped")
    }

    @objc private func appDidBecomeActive() {
        // Re-browse so a Mac that launched (or recovered) while we were suspended shows up.
        CastSession.shared.refreshBrowsing()
        emitCastStatus(CastSession.shared.currentStatus)
        if preferredOutput == .mac {
            updateCastKeepAlive()
            if CastSession.shared.currentStatus.connected {
                // Pull latest Mac clock after any suspension gap.
                CastSession.shared.sendCommand(["cmd": "ping"])
            } else {
                CastSession.shared.connectToFirstAvailable()
            }
            return
        }
        configureSession()
        attemptCarBluetoothResumeFromCurrentRoute()
        updateCastKeepAlive()
    }

    private func setNowPlayingMetadata(_ metadata: NowPlayingMetadata?) {
        nowPlayingMetadata = metadata
        if metadata?.artworkURL != nowPlayingArtworkURL {
            nowPlayingArtwork = nil
            loadNowPlayingArtwork(from: metadata?.artworkURL)
        }
        updateNowPlaying()
        persistCarBluetoothSession()
    }

    private func persistCarBluetoothSession() {
        guard let episodeID = currentEpisodeID, let publisherURL else { return }
        let now = Date().timeIntervalSince1970
        let context = currentCarRouteContext(
            outputs: Self.routeDescriptors(AVAudioSession.sharedInstance().currentRoute)
        )
        carBluetoothResumeIntent = CarBluetoothPlaybackPolicy.validatedIntent(
            carBluetoothResumeIntent,
            now: now,
            context: context
        )
        let snapshot = CarBluetoothSessionSnapshot(
            episodeID: episodeID,
            publisherURL: publisherURL.absoluteString,
            position: nowPlayingPosition,
            rate: requestedRate,
            title: nowPlayingMetadata?.title,
            artist: nowPlayingMetadata?.artist,
            artworkURL: nowPlayingMetadata?.artworkURL?.absoluteString,
            duration: Self.positiveDuration(nowPlayingDuration) ?? nowPlayingMetadata?.duration,
            resumeIntent: CarBluetoothPlaybackPolicy.validatedIntent(
                carBluetoothResumeIntent,
                now: now,
                context: context
            ),
            knownCarDeviceKeys: knownCarDeviceKeys
        )
        carBluetoothSessionStore.save(snapshot)
    }

    private func restorePersistedCarBluetoothSession() {
        knownCarDeviceKeys = carBluetoothSessionStore.loadKnownCarDeviceKeys()
        guard let snapshot = carBluetoothSessionStore.load(),
              let url = URL(string: snapshot.publisherURL) else {
            return
        }
        let now = Date().timeIntervalSince1970
        currentEpisodeID = snapshot.episodeID
        publisherURL = url
        lastSrc = snapshot.publisherURL
        requestedRate = Self.normalizedRate(snapshot.rate)
        nowPlayingPosition = max(0, snapshot.position)
        nowPlayingDuration = snapshot.duration ?? 0
        nowPlayingRate = requestedRate
        if !snapshot.knownCarDeviceKeys.isEmpty {
            knownCarDeviceKeys = snapshot.knownCarDeviceKeys
        }
        let restoreContext = CarBluetoothRouteContext(
            knownCarDeviceKeys: Set(knownCarDeviceKeys),
            handsFreeDeviceKeys: []
        )
        carBluetoothResumeIntent = CarBluetoothPlaybackPolicy.validatedIntent(
            snapshot.resumeIntent,
            now: now,
            context: restoreContext
        )
        let title = snapshot.title ?? ""
        if !title.isEmpty {
            nowPlayingMetadata = NowPlayingMetadata(
                title: title,
                artist: snapshot.artist ?? "",
                artworkURL: snapshot.artworkURL.flatMap { URL(string: $0) },
                duration: snapshot.duration
            )
            if let artwork = snapshot.artworkURL, let artworkURL = URL(string: artwork) {
                loadNowPlayingArtwork(from: artworkURL)
            }
        }
        updateNowPlaying(
            position: snapshot.position,
            duration: snapshot.duration,
            rate: requestedRate,
            paused: true
        )
        let currentRoutes = Self.routeDescriptors(AVAudioSession.sharedInstance().currentRoute)
        let context = currentCarRouteContext(outputs: currentRoutes)
        rememberCarIdentities(from: currentRoutes, context: context)
        if let intent = carBluetoothResumeIntent,
           CarBluetoothPlaybackPolicy.currentCarMatchesIntent(
               routes: currentRoutes,
               intent: intent,
               now: now,
               context: context
           ) {
            scheduleCarBluetoothResume(intent)
        } else if snapshot.resumeIntent != nil, carBluetoothResumeIntent == nil {
            persistCarBluetoothSession()
        }
        updateCastKeepAlive()
        PodsLog(
            "Pods restored car-bluetooth session episode_id=\(snapshot.episodeID) " +
            "position=\(snapshot.position) resume=\(carBluetoothResumeIntent != nil)"
        )
    }

    private func updateNowPlaying(
        position: Double? = nil,
        duration: Double? = nil,
        rate: Float? = nil,
        paused: Bool? = nil
    ) {
        if let position, position.isFinite {
            nowPlayingPosition = max(0, position)
        }
        if let duration, duration.isFinite, duration > 0 {
            nowPlayingDuration = duration
        } else if nowPlayingDuration <= 0, let metadataDuration = nowPlayingMetadata?.duration, metadataDuration > 0 {
            nowPlayingDuration = metadataDuration
        }
        if let rate, rate.isFinite {
            nowPlayingRate = Self.normalizedRate(rate)
        }
        if let paused {
            nowPlayingPaused = paused
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.nowPlayingInfo(
            metadata: nowPlayingMetadata,
            position: nowPlayingPosition,
            duration: nowPlayingDuration,
            playbackRate: nowPlayingRate,
            paused: nowPlayingPaused,
            artwork: nowPlayingArtwork
        )
        MPNowPlayingInfoCenter.default().playbackState = nowPlayingPaused ? .paused : .playing
        reportPlaybackActivityIfChanged()
    }

    private func clearNowPlaying() {
        nowPlayingArtworkTask?.cancel()
        nowPlayingArtworkTask = nil
        nowPlayingMetadata = nil
        nowPlayingArtwork = nil
        nowPlayingArtworkURL = nil
        nowPlayingPosition = 0
        nowPlayingDuration = 0
        nowPlayingRate = 1
        nowPlayingPaused = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        reportPlaybackActivityIfChanged()
    }

    var isEpisodePlaybackActive: Bool {
        PlaybackProgressPolicy.isEpisodePlaybackActive(
            episodeID: currentEpisodeID,
            paused: nowPlayingPaused
        )
    }

    private func reportPlaybackActivityIfChanged() {
        let active = isEpisodePlaybackActive
        guard active != lastReportedPlaybackActivity else { return }
        lastReportedPlaybackActivity = active
        recordDiagnostic(
            eventName: "playback_activity_changed",
            severity: .info,
            fields: ["active": active ? "true" : "false"]
        )
    }

    private func loadNowPlayingArtwork(from url: URL?) {
        nowPlayingArtworkTask?.cancel()
        nowPlayingArtworkTask = nil
        nowPlayingArtworkURL = url
        guard let url else {
            return
        }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else {
                return
            }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            DispatchQueue.main.async {
                guard let self, self.nowPlayingArtworkURL == url else {
                    return
                }
                self.nowPlayingArtwork = artwork
                self.updateNowPlaying()
            }
        }
        nowPlayingArtworkTask = task
        task.resume()
    }

    private func emit(
        type: String,
        id: Int,
        position: Double? = nil,
        duration: Double? = nil,
        playbackRate: Float? = nil,
        paused: Bool? = nil
    ) {
        var payload: [String: Any] = ["type": type, "id": id]
        if let position, position.isFinite { payload["position"] = position }
        // Only send a known positive duration; 0/NaN would wipe feed length in the web player.
        if let duration = Self.positiveDuration(duration) { payload["duration"] = duration }
        if let playbackRate, playbackRate.isFinite { payload["playbackRate"] = playbackRate }
        if let paused { payload["paused"] = paused }
        // Carry loaded episode identity so JS can drop stale transport/ended after switch.
        if let currentEpisodeID {
            payload["episodeId"] = currentEpisodeID
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            if type == "ended" {
                let episodeLabel = currentEpisodeID.map(String.init) ?? "none"
                PodsLog("playback_ended_bridge_failed reason=serialization episode_id=\(episodeLabel) player_id=\(id)")
            }
            return
        }
        let episodeLabel: String
        if let episodeID = payload["episodeId"] {
            episodeLabel = String(describing: episodeID)
        } else {
            episodeLabel = "none"
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let webView = self.webView else {
                if type == "ended" {
                    PodsLog("playback_ended_bridge_failed reason=webview_unavailable episode_id=\(episodeLabel) player_id=\(id)")
                }
                return
            }
            webView.evaluateJavaScript("Boolean(window.PodsAudioBridge && window.PodsAudioBridge.emit(\(json)))") { _, error in
                guard type == "ended" else { return }
                if let error {
                    PodsLog("playback_ended_bridge_failed reason=evaluate_javascript episode_id=\(episodeLabel) player_id=\(id) error=\(error.localizedDescription)")
                } else {
                    PodsLog("playback_ended_bridge_delivered episode_id=\(episodeLabel) player_id=\(id)")
                }
            }
        }
    }

    private func emitPlaybackState(type: String, id: Int, paused: Bool) {
        let itemDuration = output == .local ? player?.currentItem?.duration.seconds : nil
        let resolved =
            Self.positiveDuration(itemDuration)
            ?? Self.positiveDuration(nowPlayingDuration)
        emit(
            type: type,
            id: id,
            position: output == .local ? (player?.currentTime().seconds ?? nowPlayingPosition) : nowPlayingPosition,
            duration: resolved,
            playbackRate: requestedRate,
            paused: paused
        )
    }

    /// Duration suitable for the JS player: finite and strictly greater than zero.
    static func positiveDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func emitCastStatus(_ status: CastStatus) {
        var payload: [String: Any] = [
            "type": "cast",
            "id": currentId,
            "output": output.rawValue,
        ]
        for (k, v) in status.jsObject {
            payload[k] = v
        }
        // Also mirror under cast key for the JS engine.
        payload["cast"] = status.jsObject.merging(["output": output.rawValue]) { _, new in new }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.PodsAudioBridge && window.PodsAudioBridge.emit(\(json));")
        }
    }

    static func metadata(from body: [String: Any]) -> NowPlayingMetadata? {
        guard let title = body["title"] as? String, !title.isEmpty else {
            return nil
        }
        let artist = body["artist"] as? String ?? ""
        let duration = doubleValue(body["duration"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return NowPlayingMetadata(
            title: title,
            artist: artist,
            artworkURL: artworkURL(body["artwork"] as? String),
            duration: duration
        )
    }

    static func nowPlayingInfo(
        metadata: NowPlayingMetadata?,
        position: Double,
        duration: Double,
        playbackRate: Float,
        paused: Bool,
        artwork: MPMediaItemArtwork? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [:]
        if let title = metadata?.title, !title.isEmpty {
            info[MPMediaItemPropertyTitle] = title
        }
        if let artist = metadata?.artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        let safePosition = position.isFinite ? max(0, position) : 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = safePosition
        let metadataDuration = metadata?.duration ?? 0
        let safeDuration = duration.isFinite && duration > 0 ? duration : metadataDuration
        if safeDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = safeDuration
        }
        let safeRate = normalizedRate(playbackRate)
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0.0 : Double(safeRate)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(safeRate)
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        return info
    }

    private static func artworkURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return URL(string: value, relativeTo: URL(string: "http://127.0.0.1:18180"))?.absoluteURL
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        return nil
    }

    private static func floatValue(_ value: Any?) -> Float? {
        if let value = value as? Float {
            return value
        }
        if let value = value as? Double {
            return Float(value)
        }
        if let value = value as? NSNumber {
            return value.floatValue
        }
        return nil
    }

    private static func normalizedRate(_ value: Float) -> Float {
        value.isFinite && value > 0 ? value : 1
    }
}
