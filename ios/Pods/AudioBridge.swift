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

final class AudioBridge: NSObject, WKScriptMessageHandler {
    static let shared = AudioBridge()

    var progressRecorder: PlaybackProgressRecording?

    private weak var webView: WKWebView?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var currentId: Int = 0
    private var currentEpisodeID: Int64?
    private var lastRecordedEpisodeID: Int64?
    private var lastRecordedPosition: Double?
    private var requestedRate: Float = 1
    private var shouldResumeAfterInterruption = false
    private var nowPlayingMetadata: NowPlayingMetadata?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingArtworkURL: URL?
    private var nowPlayingArtworkTask: URLSessionDataTask?
    private var nowPlayingPosition: Double = 0
    private var nowPlayingDuration: Double = 0
    private var nowPlayingRate: Float = 1
    private var nowPlayingPaused = true
    private let progressRecordStrideSeconds: Double = 5

    private var output: PlaybackOutput = .local
    /// User's chosen sink. Distinct from connection liveness — stays `.mac` while we reconnect.
    private var preferredOutput: PlaybackOutput = .local
    private var lastSrc: String?
    private var pendingPlayAfterCastConnect = false
    private var castWired = false
    /// Silent local loop so iOS keeps us alive while Mac is the exclusive audio sink.
    private var castKeepAlivePlayer: AVAudioPlayer?

    private override init() {
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
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            PodsLog("Pods audio session setup failed: \(error)")
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
            load(
                id: id,
                url: url,
                episodeID: Self.int64Value(body["episodeId"]) ?? Self.int64Value(body["episode_id"]),
                position: Self.doubleValue(body["position"]) ?? 0,
                rate: Self.normalizedRate(Self.floatValue(body["rate"]) ?? 1)
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
            pause(id: id)
        case "seek":
            let seconds = Self.doubleValue(body["seconds"]) ?? 0
            seek(id: id, seconds: seconds)
        case "rate":
            let rate = Self.normalizedRate(Self.floatValue(body["rate"]) ?? 1)
            setRate(id: id, rate: rate)
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
        preferredOutput = next
        let position = nowPlayingPosition
        let wasPlaying = !nowPlayingPaused
        let rate = requestedRate

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
                guard status.connected else { return }
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
        guard let lastSrc else { return }
        // Exclusive: tear down local again in case anything recreated it.
        stopLocalPlayer(record: false)
        output = .mac
        var body: [String: Any] = [
            "cmd": "load",
            "src": lastSrc,
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
        CastSession.shared.sendCommand(body)
        if autoplay {
            CastSession.shared.sendCommand(["cmd": "play"])
            updateNowPlaying(position: position, rate: rate, paused: false)
            emit(type: "play", id: currentId, position: position, playbackRate: rate, paused: false)
        } else {
            updateNowPlaying(position: position, rate: rate, paused: true)
        }
    }

    private func handleCastEvent(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        if type == "castDisconnected" {
            // Keep progress durable. Do NOT auto-start local while user still wants Mac —
            // that caused dual playback when Mac kept playing after a flaky TCP drop.
            recordCurrentProgress(force: true)
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
            emit(type: "ended", id: currentId, position: position, duration: duration, playbackRate: rate ?? requestedRate, paused: true)
        case "state":
            if let position {
                recordPlaybackProgress(position: position, force: true, allowRegress: false)
            }
            emit(type: "state", id: currentId, position: position, duration: duration, playbackRate: rate ?? requestedRate, paused: paused)
        default:
            break
        }
    }

    // MARK: - Transport

    private func load(id: Int, url: URL, episodeID: Int64?, position: Double, rate: Float) {
        lastSrc = url.absoluteString
        currentEpisodeID = episodeID
        lastRecordedEpisodeID = nil
        lastRecordedPosition = nil
        requestedRate = rate
        nowPlayingPosition = max(0, position)

        if preferredOutput == .mac || output == .mac {
            preferredOutput = .mac
            output = .mac
            stopLocalPlayer(record: false)
            updateCastKeepAlive()
            if !CastSession.shared.currentStatus.connected {
                pendingPlayAfterCastConnect = !nowPlayingPaused
                CastSession.shared.connectToFirstAvailable()
            }
            // pushLoadToMac owns the Mac load + optional autoplay and exclusive local stop.
            pushLoadToMac(position: position, rate: rate, autoplay: false)
            updateNowPlaying(position: position, rate: rate, paused: true)
            emit(
                type: "loadedmetadata",
                id: id,
                position: position,
                duration: Self.positiveDuration(nowPlayingDuration),
                playbackRate: rate,
                paused: true
            )
            return
        }

        updateCastKeepAlive()
        loadLocal(id: id, url: url, episodeID: episodeID, position: position, rate: rate)
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
    }

    private func play(id: Int) {
        if preferredOutput == .mac || output == .mac {
            preferredOutput = .mac
            output = .mac
            stopLocalPlayer(record: false)
            updateCastKeepAlive()
            if !CastSession.shared.currentStatus.connected {
                pendingPlayAfterCastConnect = true
                CastSession.shared.connectToFirstAvailable()
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
        configureSession()
        player?.rate = requestedRate
        updateNowPlaying(rate: requestedRate, paused: false)
        emit(type: "play", id: id, playbackRate: requestedRate, paused: false)
    }

    private func pause(id: Int) {
        if preferredOutput == .mac || output == .mac {
            CastSession.shared.sendCommand(["cmd": "pause"])
            recordCurrentProgress(force: true)
            updateNowPlaying(rate: 0, paused: true)
            emitPlaybackState(type: "pause", id: id, paused: true)
            return
        }
        player?.pause()
        recordCurrentProgress(force: true)
        updateNowPlaying(rate: 0, paused: true)
        emitPlaybackState(type: "pause", id: id, paused: true)
    }

    private func seek(id: Int, seconds: Double) {
        let safe = max(0, seconds)
        nowPlayingPosition = safe
        if preferredOutput == .mac || output == .mac {
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

    private func setRate(id: Int, rate: Float) {
        requestedRate = rate
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
        lastRecordedEpisodeID = nil
        lastRecordedPosition = nil
        lastSrc = nil
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
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            // Only local clock writes progress when not casting.
            guard self.output == .local else { return }
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
            self.recordPlaybackProgress(position: time.seconds)
        }
    }

    private func removeTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    @objc private func playerItemEnded(_ notification: Notification) {
        guard output == .local else { return }
        recordCurrentProgress(force: true)
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
            shouldResumeAfterInterruption = player?.rate ?? 0 > 0
            player?.pause()
            recordCurrentProgress(force: true)
            updateNowPlaying(rate: 0, paused: true)
            emitPlaybackState(type: "pause", id: currentId, paused: true)
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if shouldResumeAfterInterruption && options.contains(.shouldResume) {
                configureSession()
                player?.rate = requestedRate
                updateNowPlaying(rate: requestedRate, paused: false)
                emit(type: "play", id: currentId, playbackRate: requestedRate, paused: false)
            }
            shouldResumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    @objc private func audioRouteChanged(_ notification: Notification) {
        guard output == .local else { return }
        let itemDuration = player?.currentItem?.duration.seconds
        updateNowPlaying(
            position: player?.currentTime().seconds ?? 0,
            duration: itemDuration,
            rate: player?.rate ?? requestedRate,
            paused: player?.rate == 0
        )
        let resolved = Self.positiveDuration(itemDuration) ?? Self.positiveDuration(nowPlayingDuration)
        emit(
            type: "state",
            id: currentId,
            position: player?.currentTime().seconds ?? 0,
            duration: resolved,
            playbackRate: player?.rate ?? 1,
            paused: player?.rate == 0
        )
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            self.play(id: self.currentId)
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            self.pause(id: self.currentId)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            if self.nowPlayingPaused {
                self.play(id: self.currentId)
            } else {
                self.pause(id: self.currentId)
            }
            return .success
        }
    }

    private func recordCurrentProgress(force: Bool = false) {
        recordPlaybackProgress(position: nowPlayingPosition, force: force, allowRegress: false)
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
    }

    // MARK: - Cast keep-alive (prevents iOS suspend while Mac plays)

    private func updateCastKeepAlive() {
        if PlaybackProgressPolicy.shouldRunCastKeepAlive(preferredOutputIsMac: preferredOutput == .mac) {
            startCastKeepAliveIfNeeded()
        } else {
            stopCastKeepAlive()
        }
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
        guard preferredOutput == .mac else { return }
        updateCastKeepAlive()
        if CastSession.shared.currentStatus.connected {
            // Pull latest Mac clock after any suspension gap.
            CastSession.shared.sendCommand(["cmd": "ping"])
        } else {
            CastSession.shared.connectToFirstAvailable()
        }
    }

    private func setNowPlayingMetadata(_ metadata: NowPlayingMetadata?) {
        nowPlayingMetadata = metadata
        if metadata?.artworkURL != nowPlayingArtworkURL {
            nowPlayingArtwork = nil
            loadNowPlayingArtwork(from: metadata?.artworkURL)
        }
        updateNowPlaying()
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

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.PodsAudioBridge && window.PodsAudioBridge.emit(\(json));")
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
