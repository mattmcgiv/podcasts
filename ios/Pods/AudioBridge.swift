import AVFoundation
import MediaPlayer
import WebKit

final class AudioBridge: NSObject, WKScriptMessageHandler {
    static let shared = AudioBridge()

    private weak var webView: WKWebView?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var currentId: Int = 0
    private var shouldResumeAfterInterruption = false

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
        configureRemoteCommands()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
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
            load(id: id, url: url, position: body["position"] as? Double ?? 0, rate: body["rate"] as? Float ?? 1)
        case "play":
            configureSession()
            player?.play()
            emit(type: "play", id: id)
        case "pause":
            player?.pause()
            emit(type: "pause", id: id)
        case "seek":
            let seconds = body["seconds"] as? Double ?? 0
            player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        case "rate":
            let rate = body["rate"] as? Float ?? 1
            player?.rate = rate
        case "stop":
            stop(id: id)
        default:
            break
        }
    }

    private func load(id: Int, url: URL, position: Double, rate: Float) {
        removeTimeObserver()
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.automaticallyWaitsToMinimizeStalling = true
        player?.rate = rate
        if position > 0 {
            player?.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        }
        addTimeObserver(id: id)
        emit(type: "loadedmetadata", id: id, position: position, duration: item.asset.duration.seconds, playbackRate: rate)
    }

    private func stop(id: Int) {
        removeTimeObserver()
        player?.pause()
        player = nil
        emit(type: "pause", id: id, position: 0, duration: 0)
    }

    private func addTimeObserver(id: Int) {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.emit(
                type: "timeupdate",
                id: id,
                position: time.seconds,
                duration: player.currentItem?.duration.seconds ?? 0,
                playbackRate: player.rate,
                paused: player.rate == 0
            )
        }
    }

    private func removeTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    @objc private func playerItemEnded(_ notification: Notification) {
        emit(type: "ended", id: currentId, paused: true)
    }

    @objc private func audioInterrupted(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        switch type {
        case .began:
            shouldResumeAfterInterruption = player?.rate ?? 0 > 0
            player?.pause()
            emit(type: "pause", id: currentId, paused: true)
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if shouldResumeAfterInterruption && options.contains(.shouldResume) {
                configureSession()
                player?.play()
                emit(type: "play", id: currentId, paused: false)
            }
            shouldResumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    @objc private func audioRouteChanged(_ notification: Notification) {
        emit(
            type: "state",
            id: currentId,
            position: player?.currentTime().seconds ?? 0,
            duration: player?.currentItem?.duration.seconds ?? 0,
            playbackRate: player?.rate ?? 1,
            paused: player?.rate == 0
        )
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            self?.emit(type: "play", id: self?.currentId ?? 0, paused: false)
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            self?.emit(type: "pause", id: self?.currentId ?? 0, paused: true)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .noSuchContent }
            if player.rate == 0 {
                player.play()
                self.emit(type: "play", id: self.currentId, paused: false)
            } else {
                player.pause()
                self.emit(type: "pause", id: self.currentId, paused: true)
            }
            return .success
        }
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
        if let duration, duration.isFinite { payload["duration"] = max(0, duration) }
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
}
