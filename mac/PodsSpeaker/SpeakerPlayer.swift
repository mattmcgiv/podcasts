import AVFoundation
import Foundation
import MediaPlayer

/// Plays podcast media on the Mac and emits transport/progress events for the phone.
///
/// All player/UI mutations stay on the main actor. Remote-command and AVFoundation
/// callbacks are hopped to main — updating `@Published` off-main has crashed this app.
@MainActor
final class SpeakerPlayer: ObservableObject {
    var onEvent: (([String: Any]) -> Void)?

    @Published private(set) var isPlaying = false
    @Published private(set) var nowPlayingTitle = "Pods Speaker"
    @Published private(set) var nowPlayingArtist = ""

    private var player: AVPlayer?
    private var observedPlayer: AVPlayer?
    private var timeObserver: Any?
    private var requestedRate: Float = 1
    private var title: String = ""
    private var artist: String = ""
    private var episodeID: Int64?
    private var metadataDuration: Double = 0
    private var lastKnownPosition: Double = 0
    private var isStopping = false
    private var loadGeneration: UInt64 = 0
    private var playbackSessionID: String?
    private let diagnostics: AdRemovalDiagnostics?

    /// Last finite playback position, for disconnect/stop events that must not report 0.
    var currentPositionSeconds: Double {
        if let seconds = player?.currentTime().seconds, seconds.isFinite {
            return max(0, seconds)
        }
        return lastKnownPosition.isFinite ? max(0, lastKnownPosition) : 0
    }

    init(diagnostics: AdRemovalDiagnostics? = nil) {
        self.diagnostics = diagnostics
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemEnded(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemFailed(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: nil
        )
        configureRemoteCommands()
    }

    deinit {
        // Best-effort; MainActor deinit cannot always touch actor state safely on older SDKs.
        // Observer removal also happens in stop()/load().
        NotificationCenter.default.removeObserver(self)
    }

    func handle(command body: [String: Any]) {
        guard let cmd = body["cmd"] as? String else { return }
        if cmd == "load" {
            playbackSessionID = AdRemovalPlaybackSession.sessionID(from: body)
        }
        recordDiagnostic(
            eventName: "mac_playback_command",
            severity: .debug,
            fields: ["command": cmd]
        )
        switch cmd {
        case "load":
            guard let src = body["src"] as? String, let url = URL(string: src) else { return }
            let position = CastProtocol.doubleValue(body["position"]) ?? 0
            let rate = CastProtocol.normalizedRate(CastProtocol.floatValue(body["rate"]) ?? 1)
            episodeID = CastProtocol.int64Value(body["episodeId"]) ?? CastProtocol.int64Value(body["episode_id"])
            title = body["title"] as? String ?? ""
            artist = body["artist"] as? String ?? ""
            nowPlayingTitle = title.isEmpty ? "Pods Speaker" : title
            nowPlayingArtist = artist
            let metadataDuration = CastProtocol.doubleValue(body["duration"])
            if position.isFinite, position >= 0 {
                lastKnownPosition = position
            }
            load(url: url, position: position, rate: rate, metadataDuration: metadataDuration)
        case "play":
            play()
        case "pause":
            pause()
        case "seek":
            let seconds = CastProtocol.doubleValue(body["seconds"]) ?? 0
            seek(to: seconds)
        case "rate":
            let rate = CastProtocol.normalizedRate(CastProtocol.floatValue(body["rate"]) ?? 1)
            setRate(rate)
        case "stop":
            stop()
        case "ping":
            emitState(type: "state")
        default:
            break
        }
    }

    func togglePlayPause() {
        guard player != nil else { return }
        if player?.rate == 0 {
            play()
        } else {
            pause()
        }
    }

    // MARK: - Playback

    private func load(url: URL, position: Double, rate: Float, metadataDuration: Double? = nil) {
        isStopping = false
        loadGeneration &+= 1
        let generation = loadGeneration

        removeTimeObserver()
        requestedRate = rate
        if let metadataDuration, metadataDuration.isFinite, metadataDuration > 0 {
            self.metadataDuration = metadataDuration
        } else {
            self.metadataDuration = 0
        }

        // Tear down previous item fully before replacing the player.
        if let existing = player {
            existing.pause()
            existing.rate = 0
            existing.replaceCurrentItem(with: nil)
        }

        let item = AVPlayerItem(url: url)
        recordDiagnostic(
            eventName: "mac_player_source_load",
            severity: .notice,
            fields: ["request_url": url.absoluteString, "position": "\(max(0, position))"]
        )
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        player = newPlayer

        if position > 0 {
            let seekTime = CMTime(seconds: max(0, position), preferredTimescale: 600)
            newPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        // Only attach observer if this load is still current.
        guard generation == loadGeneration, player === newPlayer else { return }
        addTimeObserver(for: newPlayer, generation: generation)

        let duration = Self.positiveDuration(item.duration.seconds) ?? Self.positiveDuration(self.metadataDuration)
        publishUI(playing: false)
        updateNowPlaying(position: position, duration: duration, rate: rate, paused: true)
        var payload: [String: Any] = [
            "type": "loadedmetadata",
            "position": max(0, position),
            "playbackRate": rate,
            "paused": true,
        ]
        if let d = duration {
            payload["duration"] = d
        }
        emit(payload)
    }

    private func play() {
        guard !isStopping, let player else { return }
        player.rate = requestedRate
        publishUI(playing: true)
        updateNowPlaying(rate: requestedRate, paused: false)
        emit(transportEvent(
            type: "play",
            position: player.currentTime().seconds,
            duration: currentDuration(),
            playbackRate: requestedRate,
            paused: false
        ))
    }

    private func pause() {
        guard let player else { return }
        player.pause()
        publishUI(playing: false)
        updateNowPlaying(rate: 0, paused: true)
        emit(transportEvent(
            type: "pause",
            position: player.currentTime().seconds,
            duration: currentDuration(),
            playbackRate: requestedRate,
            paused: true
        ))
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let safe = max(0, seconds)
        // Intentional scrub — update last known before emit so near-zero seeks are not treated as glitches.
        lastKnownPosition = safe
        player.seek(to: CMTime(seconds: safe, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying(position: safe)
        emit(transportEvent(
            type: "timeupdate",
            position: safe,
            duration: currentDuration(),
            playbackRate: player.rate == 0 ? requestedRate : player.rate,
            paused: player.rate == 0
        ))
    }

    private func setRate(_ rate: Float) {
        requestedRate = rate
        if let player, player.rate != 0 {
            player.rate = rate
            updateNowPlaying(rate: rate, paused: false)
        } else {
            updateNowPlaying(rate: rate)
        }
        emitState(type: "state")
    }

    private func stop() {
        if isStopping { return }
        isStopping = true
        loadGeneration &+= 1

        // Capture real progress before teardown so the phone does not persist a glitch zero.
        let stopPosition = currentPositionSeconds
        let stopDuration = currentDuration()
        let stopEpisodeID = episodeID
        lastKnownPosition = stopPosition

        removeTimeObserver()
        if let player {
            player.pause()
            player.rate = 0
            player.replaceCurrentItem(with: nil)
        }
        player = nil
        episodeID = stopEpisodeID
        title = ""
        artist = ""
        metadataDuration = 0
        publishUI(playing: false)
        clearNowPlaying()
        var payload: [String: Any] = [
            "type": "pause",
            "position": stopPosition,
            "playbackRate": 1.0,
            "paused": true,
        ]
        if let stopDuration {
            payload["duration"] = stopDuration
        }
        emit(payload)
        episodeID = nil
        isStopping = false
    }

    private func publishUI(playing: Bool) {
        isPlaying = playing
        nowPlayingTitle = title.isEmpty ? "Pods Speaker" : title
        nowPlayingArtist = artist
    }

    private func currentDuration() -> Double? {
        Self.positiveDuration(player?.currentItem?.duration.seconds)
            ?? Self.positiveDuration(metadataDuration)
    }

    private func addTimeObserver(for player: AVPlayer, generation: UInt64) {
        removeTimeObserver()
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.loadGeneration else { return }
                guard self.player === player, self.observedPlayer === player else { return }
                guard !self.isStopping else { return }

                let duration = self.currentDuration()
                let rate = player.rate
                let position = time.seconds
                self.updateNowPlaying(
                    position: position,
                    duration: duration,
                    rate: rate == 0 ? self.requestedRate : rate,
                    paused: rate == 0
                )
                self.emit(self.transportEvent(
                    type: "timeupdate",
                    position: position,
                    duration: duration,
                    playbackRate: rate == 0 ? self.requestedRate : rate,
                    paused: rate == 0
                ))
            }
        }
    }

    private func removeTimeObserver() {
        // Must remove from the *same* AVPlayer that added the observer; wrong player raises.
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        } else if let timeObserver, let player {
            // Fallback for older state.
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observedPlayer = nil
    }

    @objc private func itemEnded(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let ended = notification.object as? AVPlayerItem,
                  ended === self.player?.currentItem else {
                return
            }
            self.publishUI(playing: false)
            self.updateNowPlaying(rate: 0, paused: true)
            self.emit(self.transportEvent(
                type: "ended",
                position: self.player?.currentTime().seconds ?? 0,
                duration: self.currentDuration(),
                playbackRate: self.requestedRate,
                paused: true
            ))
        }
    }

    @objc private func itemFailed(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let failed = notification.object as? AVPlayerItem,
                  failed === self.player?.currentItem else {
                return
            }
            let message = failed.error?.localizedDescription ?? "playback failed"
            self.publishUI(playing: false)
            self.updateNowPlaying(rate: 0, paused: true)
            self.emit([
                "type": "error",
                "message": message,
                "position": self.player?.currentTime().seconds ?? 0,
                "paused": true,
            ])
        }
    }

    private func emitState(type: String) {
        emit(transportEvent(
            type: type,
            position: player?.currentTime().seconds ?? 0,
            duration: currentDuration(),
            playbackRate: player?.rate == 0 ? requestedRate : (player?.rate ?? requestedRate),
            paused: player?.rate == 0
        ))
    }

    private func transportEvent(
        type: String,
        position: Double,
        duration: Double?,
        playbackRate: Float,
        paused: Bool
    ) -> [String: Any] {
        let resolved = Self.resolvedPosition(candidate: position, lastKnown: lastKnownPosition)
        if resolved.isFinite {
            lastKnownPosition = resolved
        }
        var payload: [String: Any] = [
            "type": type,
            "position": resolved,
            "playbackRate": Double(playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1),
            "paused": paused,
        ]
        if let d = Self.positiveDuration(duration) {
            payload["duration"] = d
        }
        return payload
    }

    /// Prefer last known progress over invalid / sudden-zero clocks (pre-seek, teardown).
    static func resolvedPosition(candidate: Double, lastKnown: Double) -> Double {
        let known = lastKnown.isFinite ? max(0, lastKnown) : 0
        guard candidate.isFinite else {
            return known
        }
        let safe = max(0, candidate)
        if safe < 1, known > 1 {
            return known
        }
        return safe
    }

    /// Duration suitable for the phone player: finite and strictly greater than zero.
    private static func positiveDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func emit(_ fields: [String: Any]) {
        var payload: [String: Any] = ["v": CastProtocol.version]
        for (k, v) in fields {
            payload[k] = v
        }
        if let episodeID {
            // JSONSerialization is happiest with NSNumber-friendly ints.
            payload["episodeId"] = NSNumber(value: episodeID)
        }
        if let playbackSessionID {
            payload = AdRemovalPlaybackSession.attaching(sessionID: playbackSessionID, to: payload)
        }
        let eventType = fields["type"] as? String ?? "unknown"
        recordDiagnostic(
            eventName: "mac_playback_event",
            severity: eventType == "error" ? .error : .debug,
            fields: [
                "event_type": eventType,
                "position": CastProtocol.doubleValue(fields["position"]).map { String($0) } ?? "unknown"
            ]
        )
        onEvent?(payload)
    }

    private func recordDiagnostic(
        eventName: String,
        severity: AdRemovalDiagnosticSeverity,
        fields: [String: String] = [:]
    ) {
        try? diagnostics?.record(
            eventName: eventName,
            severity: severity,
            context: .init(episodeID: episodeID, playbackSessionID: playbackSessionID),
            fields: fields
        )
    }

    // MARK: - Now Playing

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.play()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.pause()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.togglePlayPause()
            }
            return .success
        }
    }

    private func updateNowPlaying(
        position: Double? = nil,
        duration: Double? = nil,
        rate: Float? = nil,
        paused: Bool? = nil
    ) {
        var info: [String: Any] = [:]
        if !title.isEmpty {
            info[MPMediaItemPropertyTitle] = title
        }
        if !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        let pos = position ?? player?.currentTime().seconds ?? 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = pos.isFinite ? max(0, pos) : 0
        let rawDur = duration ?? player?.currentItem?.duration.seconds ?? metadataDuration
        if let d = Self.positiveDuration(rawDur) {
            info[MPMediaItemPropertyPlaybackDuration] = d
        }
        let playing = !(paused ?? (player?.rate == 0))
        let r = rate ?? requestedRate
        let safeRate = r.isFinite && r > 0 ? r : 1
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? Double(safeRate) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
