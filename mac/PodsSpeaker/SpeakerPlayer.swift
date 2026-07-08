import AVFoundation
import Foundation
import MediaPlayer

/// Plays podcast media on the Mac and emits transport/progress events for the phone.
final class SpeakerPlayer: ObservableObject {
    var onEvent: (([String: Any]) -> Void)?

    @Published private(set) var isPlaying = false
    @Published private(set) var nowPlayingTitle = "Pods Speaker"
    @Published private(set) var nowPlayingArtist = ""

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var requestedRate: Float = 1
    private var title: String = ""
    private var artist: String = ""
    private var episodeID: Int64?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemEnded(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
        configureRemoteCommands()
    }

    deinit {
        removeTimeObserver()
        NotificationCenter.default.removeObserver(self)
    }

    func handle(command body: [String: Any]) {
        guard let cmd = body["cmd"] as? String else { return }
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
            load(url: url, position: position, rate: rate)
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
        guard let player else { return }
        if player.rate == 0 {
            play()
        } else {
            pause()
        }
    }

    // MARK: - Playback

    private func load(url: URL, position: Double, rate: Float) {
        removeTimeObserver()
        requestedRate = rate
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.automaticallyWaitsToMinimizeStalling = true
        if position > 0 {
            player?.seek(to: CMTime(seconds: max(0, position), preferredTimescale: 600))
        }
        addTimeObserver()
        let duration = item.duration.seconds
        publishUI(playing: false)
        updateNowPlaying(position: position, duration: duration, rate: rate, paused: true)
        emit([
            "type": "loadedmetadata",
            "position": max(0, position),
            "duration": duration.isFinite && duration > 0 ? duration : 0,
            "playbackRate": rate,
            "paused": true,
        ])
    }

    private func play() {
        player?.rate = requestedRate
        publishUI(playing: true)
        updateNowPlaying(rate: requestedRate, paused: false)
        emit([
            "type": "play",
            "position": player?.currentTime().seconds ?? 0,
            "duration": player?.currentItem?.duration.seconds ?? 0,
            "playbackRate": requestedRate,
            "paused": false,
        ])
    }

    private func pause() {
        player?.pause()
        publishUI(playing: false)
        updateNowPlaying(rate: 0, paused: true)
        emit([
            "type": "pause",
            "position": player?.currentTime().seconds ?? 0,
            "duration": player?.currentItem?.duration.seconds ?? 0,
            "playbackRate": requestedRate,
            "paused": true,
        ])
    }

    private func seek(to seconds: Double) {
        let safe = max(0, seconds)
        player?.seek(to: CMTime(seconds: safe, preferredTimescale: 600))
        updateNowPlaying(position: safe)
        emit([
            "type": "timeupdate",
            "position": safe,
            "duration": player?.currentItem?.duration.seconds ?? 0,
            "playbackRate": player?.rate == 0 ? requestedRate : (player?.rate ?? requestedRate),
            "paused": player?.rate == 0,
        ])
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
        removeTimeObserver()
        player?.pause()
        player = nil
        episodeID = nil
        title = ""
        artist = ""
        publishUI(playing: false)
        clearNowPlaying()
        emit([
            "type": "pause",
            "position": 0,
            "duration": 0,
            "playbackRate": 1,
            "paused": true,
        ])
    }

    private func publishUI(playing: Bool) {
        isPlaying = playing
        nowPlayingTitle = title.isEmpty ? "Pods Speaker" : title
        nowPlayingArtist = artist
    }

    private func addTimeObserver() {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let duration = player.currentItem?.duration.seconds ?? 0
            let rate = player.rate
            self.updateNowPlaying(
                position: time.seconds,
                duration: duration,
                rate: rate == 0 ? self.requestedRate : rate,
                paused: rate == 0
            )
            self.emit([
                "type": "timeupdate",
                "position": time.seconds,
                "duration": duration.isFinite && duration > 0 ? duration : 0,
                "playbackRate": rate == 0 ? self.requestedRate : rate,
                "paused": rate == 0,
            ])
        }
    }

    private func removeTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    @objc private func itemEnded(_ notification: Notification) {
        guard let ended = notification.object as? AVPlayerItem, ended === player?.currentItem else {
            return
        }
        updateNowPlaying(rate: 0, paused: true)
        emit([
            "type": "ended",
            "position": player?.currentTime().seconds ?? 0,
            "duration": player?.currentItem?.duration.seconds ?? 0,
            "playbackRate": requestedRate,
            "paused": true,
        ])
    }

    private func emitState(type: String) {
        emit([
            "type": type,
            "position": player?.currentTime().seconds ?? 0,
            "duration": player?.currentItem?.duration.seconds ?? 0,
            "playbackRate": player?.rate == 0 ? requestedRate : (player?.rate ?? requestedRate),
            "paused": player?.rate == 0,
        ])
    }

    private func emit(_ fields: [String: Any]) {
        var payload: [String: Any] = ["v": CastProtocol.version]
        for (k, v) in fields {
            payload[k] = v
        }
        if let episodeID {
            payload["episodeId"] = episodeID
        }
        onEvent?(payload)
    }

    // MARK: - Now Playing

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
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
        let dur = duration ?? player?.currentItem?.duration.seconds ?? 0
        if dur.isFinite && dur > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = dur
        }
        let playing = !(paused ?? (player?.rate == 0))
        let r = rate ?? requestedRate
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? Double(CastProtocol.normalizedRate(r)) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
